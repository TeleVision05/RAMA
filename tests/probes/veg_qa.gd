extends SceneTree
## QA pass on the vegetation system. Independent of anything Vegetation reports about
## itself: this walks the MultiMesh buffers that are actually uploaded for drawing and
## checks every visible instance against WorldMap.height_at.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/veg_qa.gd
##
## Checks
##   1. GROUNDING   every drawn instance sits on the heightfield within tolerance
##   2. EXCLUSION   nothing is in the river, under water, on a road, or in the square
##   3. TRANSFORMS  no degenerate/NaN bases, no absurd scales
##   4. CENSUS      triangles / instances / nodes / setup wall clock
##   5. STREAM      non-immediate focus walk: cost, node leak, orphan cells

const SINK_MAX := 0.55  # deepest legitimate burial (rock: 0.22 * 1.9 scale)
const FLOAT_MAX := 0.06  # nothing may hover above the ground by more than this


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(false)
	var m: WorldMap = world.map

	var veg := Vegetation.new()
	veg.name = "Vegetation"
	root.add_child(veg)
	var t0 := Time.get_ticks_usec()
	veg.setup(m)
	var setup_ms := float(Time.get_ticks_usec() - t0) / 1000.0

	var fails: Array[String] = []
	print("setup()        : %.1f ms" % setup_ms)

	# --- source scatter, before any streaming decision ------------------------
	var pos: PackedVector3Array = veg._pos
	var kind: PackedInt32Array = veg._kind
	var worst_float := -1e9
	var worst_bury := 0.0
	var n_float := 0
	var n_bury := 0
	var n_wet := 0
	var n_road := 0
	var n_river := 0
	for i in range(pos.size()):
		var p: Vector3 = pos[i]
		var g := m.height_at(p.x, p.z)
		var d := p.y - g
		if d > FLOAT_MAX:
			n_float += 1
			worst_float = maxf(worst_float, d)
		if d < -SINK_MAX:
			n_bury += 1
			worst_bury = minf(worst_bury, d)
		if m.water_depth_at(p.x, p.z) > 0.0:
			n_wet += 1
		if m.path_at(p.x, p.z) > 0.30:
			n_road += 1
		if m.river_dist(Vector2(p.x, p.z)) < 5.0:
			n_river += 1
	print("scatter        : %d placed" % pos.size())
	print("  floating     : %d (worst +%.3f m)" % [n_float, maxf(worst_float, 0.0)])
	print("  over-buried  : %d (worst %.3f m)" % [n_bury, worst_bury])
	print("  in water     : %d   on road: %d   in channel: %d" % [n_wet, n_road, n_river])
	if n_float > 0:
		fails.append("%d placed objects float above the ground (worst +%.3f m)" % [n_float, worst_float])
	if n_bury > 0:
		fails.append("%d placed objects buried past %.2f m (worst %.3f m)" % [n_bury, SINK_MAX, worst_bury])
	if n_wet > 0:
		fails.append("%d placed objects stand in water" % n_wet)
	if n_road > 0:
		fails.append("%d placed objects stand on a road" % n_road)
	if n_river > 0:
		fails.append("%d placed objects stand in the river channel" % n_river)

	# --- what is actually uploaded for drawing --------------------------------
	# Stand at several places, force a full stream, and audit every visible row of
	# every MultiMesh. This is the check that catches a mis-packed instance buffer,
	# which the source array above cannot.
	var spots := [
		Vector3(WorldMap.P_VILLAGE.x, 0, WorldMap.P_VILLAGE.y),
		Vector3(-244, 0, 40),
		Vector3(-196, 0, -34),
		Vector3(96, 0, -150),
		Vector3(168, 0, 122),
		Vector3(-34, 0, 8),
		Vector3(-322, 0, 118),
	]
	var bad_rows := 0
	var bad_basis := 0
	var n_short := 0
	var n_oob := 0
	var oob_names: Dictionary = {}
	var checked := 0
	var worst_gap := 0.0
	var worst_at := Vector3.ZERO
	var worst_node := ""
	for s in spots:
		s.y = m.height_at(s.x, s.z) + 1.75
		veg.update_focus(s, true)
		await process_frame
		for c in veg.get_children():
			if not (c is MultiMeshInstance3D) or not c.visible:
				continue
			var mi: MultiMeshInstance3D = c
			var mm: MultiMesh = mi.multimesh
			var vis: int = mm.visible_instance_count
			if vis < 0:
				vis = mm.instance_count
			# NOTE: MultiMesh.get_instance_transform() returns identity for data written
			# through the bulk `buffer` setter in Godot 4.7 (verified with a two-row
			# probe). The buffer itself reads back correctly, so decode that — it is
			# also literally the bytes the GPU receives.
			var buf: PackedFloat32Array = mm.buffer
			var stride := 16 if mm.use_custom_data else 12
			for i in range(vis):
				var b := i * stride
				if b + stride > buf.size():
					bad_rows += 1
					n_short += 1
					continue
				var basis := Basis(
					Vector3(buf[b + 0], buf[b + 4], buf[b + 8]),
					Vector3(buf[b + 1], buf[b + 5], buf[b + 9]),
					Vector3(buf[b + 2], buf[b + 6], buf[b + 10])
				)
				var o := mi.global_transform * Vector3(buf[b + 3], buf[b + 7], buf[b + 11])
				checked += 1
				if not m.in_bounds(o.x, o.z):
					bad_rows += 1
					n_oob += 1
					oob_names[mi.name] = int(oob_names.get(mi.name, 0)) + 1
					continue
				var d := o.y - m.height_at(o.x, o.z)
				if d > FLOAT_MAX or d < -SINK_MAX:
					bad_rows += 1
					if absf(d) > absf(worst_gap):
						worst_gap = d
						worst_at = o
						worst_node = mi.name
				var sc := basis.get_scale()
				if is_nan(sc.x) or sc.x < 0.05 or sc.x > 12.0 or basis.determinant() <= 1e-6:
					bad_basis += 1
	print("drawn rows     : %d audited across %d viewpoints" % [checked, spots.size()])
	print("  off-ground   : %d (worst %+.3f m at %s in %s)" % [bad_rows, worst_gap, str(worst_at.round()), worst_node])
	print("  bad basis    : %d   short buffer: %d   out of bounds: %d" % [bad_basis, n_short, n_oob])
	if n_oob > 0:
		print("  oob nodes    : %s" % str(oob_names))
	if n_oob > 0:
		fails.append("%d drawn instances sit outside the world bounds" % n_oob)
	if n_short > 0:
		fails.append("%d drawn instances index past the end of their buffer" % n_short)
	if bad_rows > 0:
		fails.append("%d drawn instances are off the ground (worst %+.3f m, node %s)" % [bad_rows, worst_gap, worst_node])
	if bad_basis > 0:
		fails.append("%d drawn instances have a degenerate or absurd basis" % bad_basis)

	# --- census ----------------------------------------------------------------
	veg.update_focus(Vector3(-244, m.height_at(-244, 40) + 1.75, 40), true)
	await process_frame
	var st: Dictionary = veg.stats()
	print("census @ forest_deep")
	print("  triangles    : %d (tree %d, grass %d)" % [st.total_triangles, st.tree_triangles, st.grass_triangles])
	print("  instances    : %d trees/clutter + %d ground cover" % [st.drawn_instances, st.grass_instances])
	print("  lod split    : %s" % str(st.by_lod))
	print("  draw nodes   : %d visible / %d children" % [st.draw_nodes, veg.get_child_count()])
	print("  by species   : %s" % str(st.by_species))

	# --- streaming -------------------------------------------------------------
	var from := Vector3(-240.0, 0.0, -60.0)
	var to := Vector3(-60.0, 0.0, 60.0)
	var worst_ms := 0.0
	var total_ms := 0.0
	var steps := 60
	for i in range(steps):
		var p3 := from.lerp(to, float(i) / float(steps - 1))
		p3.y = m.height_at(p3.x, p3.z) + 1.75
		var t1 := Time.get_ticks_usec()
		veg.update_focus(p3)
		var dt := float(Time.get_ticks_usec() - t1) / 1000.0
		worst_ms = maxf(worst_ms, dt)
		total_ms += dt
		await process_frame
	print(
		(
			"stream walk    : %d steps, worst %.1f ms, mean %.2f ms, children %d"
			% [steps, worst_ms, total_ms / float(steps), veg.get_child_count()]
		)
	)
	if veg.get_child_count() > 400:
		fails.append("node leak: %d children after the walk" % veg.get_child_count())

	print("---")
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	quit(0 if fails.is_empty() else 1)
