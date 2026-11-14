extends SceneTree
## Where the ground-cover streamer's time goes, split by stage. The first integration
## measured a 73 ms mean per focus update against the card version's 11 ms, and the
## obvious suspect (the candidate loop) was not the whole story.


func _init() -> void:
	var m := WorldMap.load_or_bake()
	var veg := Vegetation.new()
	get_root().add_child(veg)
	veg.setup(m)

	var c := Vector2i(-5, 1)
	var t0 := Time.get_ticks_usec()
	var g: Array = veg._sample_grid(float(c.x) * 20.0, float(c.y) * 20.0)
	var t1 := Time.get_ticks_usec()
	print("sample_grid   %6.2f ms  (%d nodes)" % [(t1 - t0) / 1000.0, g.size()])

	# Mirror tests/vegetation_test.gd: thirteen IMMEDIATE full-window builds scattered
	# across the map first, then the walk. The walk was measured at 73 ms a step there
	# and 3.6 ms here, and the only difference is this preamble.
	for s in [
		Vector2(-196, -34),
		Vector2(-244, 40),
		Vector2(-127, 71),
		Vector2(-8, 44),
		Vector2(-96, 12),
		Vector2(96, -150),
		Vector2(168, 122),
		Vector2(-168, -104)
	]:
		veg.update_focus(Vector3(s.x, m.height_at(s.x, s.y) + 1.8, s.y), true)
	print("after preamble: cells %d child nodes %d" % [veg._grass_cells.size(), veg.get_child_count()])

	# Walk the focus the way the game does and split the update.
	var a := Vector3(-240.0, 0.0, -60.0)
	var b := Vector3(-60.0, 0.0, 60.0)
	var worst := 0.0
	var acc := 0.0
	var drain_acc := 0.0
	var band_acc := 0.0
	var free_acc := 0.0
	var built := 0
	for i in range(40):
		var p := a.lerp(b, float(i) / 39.0)
		p.y = m.height_at(p.x, p.z) + 1.8
		var n0 := veg._grass_cells.size()
		var s0 := Time.get_ticks_usec()
		TreeBuilder.set_lod_focus(p)
		veg._rebuild_near(p)
		var s1 := Time.get_ticks_usec()
		veg._update_grass(p, false)
		var s2 := Time.get_ticks_usec()
		var ms := (s2 - s1) / 1000.0
		band_acc += (s1 - s0) / 1000.0
		acc += ms
		worst = maxf(worst, ms)
		built += maxi(0, veg._grass_cells.size() - n0)
	print(
		(
			"walk: grass mean %6.2f ms worst %6.2f | trees mean %6.2f ms | cells built %d | nodes %d"
			% [acc / 40.0, worst, band_acc / 40.0, built, veg.get_child_count()]
		)
	)
	band_acc = 0.0

	# Time the pieces on a fresh set of cells.
	var cells: Array = []
	for i in range(6):
		cells.append(Vector2i(20 + i, -14))
	cells = [Vector2i(-5, 1), Vector2i(-6, 2), Vector2i(-7, 1), Vector2i(-5, 3), Vector2i(-6, 0), Vector2i(-4, 2)]
	for cc in cells:
		var u0 := Time.get_ticks_usec()
		var wip := veg._start_cell(cc)
		veg._work_cell(wip, 0x7FFFFFFF)
		var rec: Dictionary = veg._finish_cell(wip)
		var u1 := Time.get_ticks_usec()
		veg._apply_band(cc, rec, 0)
		var u2 := Time.get_ticks_usec()
		veg._free_cell(rec)
		var u3 := Time.get_ticks_usec()
		drain_acc += (u1 - u0) / 1000.0
		band_acc += (u2 - u1) / 1000.0
		free_acc += (u3 - u2) / 1000.0
	print("per cell: build %5.2f ms | apply band0 %5.2f ms | free %5.2f ms" % [drain_acc / 6.0, band_acc / 6.0, free_acc / 6.0])

	# GROUNDING. Every instance origin must sit on map.height_at, and the instance's up
	# axis must lean toward the surface normal. Read from the buffer that was written,
	# not from the MultiMesh: under the dummy renderer get_instance_transform() returns
	# identity for every instance and an audit that trusts it checks nothing.
	var worst_dy := 0.0
	var worst_tilt := 0.0
	var tilt_sum := 0.0
	var checked := 0
	var flat := 0
	var leaning := 0
	var sloped := 0
	for i in range(140):
		var cc := Vector2i(-14 + (i % 14), -6 + (i / 14))
		var wp := veg._start_cell(cc)
		veg._work_cell(wp, 0x7FFFFFFF)
		var rec2: Dictionary = veg._finish_cell(wp)
		for li in range(3):
			var lay: Dictionary = rec2.layers[li]
			var buf: PackedFloat32Array = lay.buf
			for k in range(int(lay.n)):
				var o := k * 16
				var org := Vector3(buf[o + 3], buf[o + 7], buf[o + 11])
				var upv := Vector3(buf[o + 1], buf[o + 5], buf[o + 9]).normalized()
				var gy: float = m.height_at(org.x, org.z)
				worst_dy = maxf(worst_dy, absf(org.y - gy))
				var nrm := m.normal_at(org.x, org.z)
				var want := (Vector3.UP * 0.45 + nrm * 0.55).normalized()
				var err := rad_to_deg(upv.angle_to(want))
				worst_tilt = maxf(worst_tilt, err)
				tilt_sum += err
				if upv.dot(Vector3.UP) > 0.99999:
					flat += 1
				# On ground that is actually sloped the tuft has to be off plumb, or the
				# lean is not happening at all and the mean error would still look fine.
				if nrm.y < 0.985:
					sloped += 1
					if upv.dot(Vector3.UP) < 0.9995:
						leaning += 1
				checked += 1
		veg._free_cell(rec2)
	print(
		(
			"grounding: %d inst | worst |y-height_at| %.4f m | lean err mean %.2f worst %.2f deg | on slopes %d/%d lean"
			% [checked, worst_dy, tilt_sum / maxf(float(checked), 1.0), worst_tilt, leaning, sloped]
		)
	)
	var ok := checked > 20000 and worst_dy < 0.05 and tilt_sum / float(checked) < 2.0 and float(leaning) > 0.98 * float(sloped)
	print("RESULT: " + ("PASS" if ok else "FAIL"))
	quit()
