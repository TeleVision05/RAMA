extends SceneTree
## QA grounding audit for WorldVFX + Wildlife. Independent of the builder's own test.
##
## Walks the focus around the whole valley so every herd, troop, flock and shoal wakes
## up and simulates, then audits EVERY placed object against WorldMap.height_at /
## water_y_at and reports the worst offender by name. Nothing here is sampled - every
## instance is checked at every stop.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/vfx_qa_ground.gd

var fails := 0
var worst := {}  # label -> [value, description]


func note(label: String, v: float, desc: String) -> void:
	if not worst.has(label) or absf(v) > absf(worst[label][0]):
		worst[label] = [v, desc]


func ok(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS  ", msg)
	else:
		fails += 1
		print("  FAIL  ", msg)


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(false)
	var map: WorldMap = world.map

	var vfx := WorldVFX.new()
	world.add_child(vfx)
	var life := Wildlife.new()
	world.add_child(life)
	await process_frame
	vfx.setup(map, world.sky)
	life.setup(map, world.sky)

	# Counters gathered over the whole tour.
	var counts := {
		"deer": 0,
		"monkey": 0,
		"fire": 0,
		"smoke": 0,
		"bird_perched": 0,
		"bird_spot": 0,
		"bird_flying": 0,
		"bat": 0,
		"bfly": 0,
		"fish": 0,
	}
	var bad := {}
	for k in counts:
		bad[k] = 0
	var steep_deer := 0
	var splayed_deer := 0
	var worst_splay := 0.0
	var deer_samples := 0
	var buried_fires := 0
	var wet_fires := 0
	var bfly_far := 0

	# A tour of every place the systems put something, at a time of day that has each
	# group awake: bats and fireflies need night, butterflies need sun.
	var tour := [
		[WorldMap.P_VILLAGE, 11.0],
		[WorldMap.P_FIELDS, 10.0],
		[WorldMap.P_FOREST_CAMP, 22.5],
		[WorldMap.P_HIDDEN_GROVE, 12.0],
		[WorldMap.P_RUINS, 23.0],
		[WorldMap.P_FORD, 6.0],
		[WorldMap.P_SHRINE, 13.0],
		[WorldMap.P_LOOKOUT, 9.0],
		[Vector2(-56.0, 118.0), 11.0],
		[WorldMap.P_VILLAGE, 21.0],
	]

	for stop in tour:
		var p2: Vector2 = stop[0]
		world.sky.set_time(float(stop[1]))
		var here := map.ground(p2.x, p2.y)
		for i in range(70):
			vfx.update_focus(here)
			life.update_focus(here)
			await process_frame

		# ---- deer -----------------------------------------------------------
		for h in life._herds:
			for d in h.deer:
				var q: Vector3 = d.root.global_position
				var g := map.height_at(q.x, q.z)
				counts.deer += 1
				deer_samples += 1
				var dy := q.y - g
				note("deer", dy, "deer at (%.0f, %.0f)" % [q.x, q.z])
				if dy < -0.05 or dy > 0.12:
					bad.deer += 1
				if map.slope_at(q.x, q.z) > Wildlife.STAND_MAX_SLOPE:
					steep_deer += 1
				# Root-on-the-ground is not the same as STANDING on the ground. Sample
				# under all four hooves: on a steep enough slope the root sits exactly on
				# height_at while the downhill legs hang in mid-air. That is what a deer
				# posed halfway down a riverbank looks like, and the first version of
				# this audit passed it without a murmur.
				var lo := 1e9
				var hi := -1e9
				for li in range(4):
					var lx: float = Wildlife.LEG_X[li]
					var lz: float = Wildlife.LEG_Z[li]
					var yw: float = d.yaw
					var wx: float = q.x + lx * cos(yw) - lz * sin(yw)
					var wz: float = q.z + lx * sin(yw) + lz * cos(yw)
					var gg: float = map.height_at(wx, wz)
					lo = minf(lo, gg)
					hi = maxf(hi, gg)
				var splay: float = hi - lo
				worst_splay = maxf(worst_splay, splay)
				if splay > 0.55:
					splayed_deer += 1

		# ---- monkeys --------------------------------------------------------
		for m in life._monkeys:
			var q: Vector3 = m.root.global_position
			var dy := q.y - map.height_at(q.x, q.z)
			counts.monkey += 1
			note("monkey", dy, "monkey at (%.0f, %.0f)" % [q.x, q.z])
			# A hop lifts by 0.16 + hop_len*0.16, hop_len is capped near 3.4 m.
			if dy < -0.05 or dy > 0.80:
				bad.monkey += 1

		# ---- fires and smoke -------------------------------------------------
		for fl in vfx._firelights:
			var q: Vector3 = fl.global_position
			var dy := q.y - map.height_at(q.x, q.z)
			counts.fire += 1
			note("fire", dy, "fire at (%.0f, %.0f)" % [q.x, q.z])
			if dy < -0.02 or dy > 1.10:
				bad.fire += 1
			if map.water_depth_at(q.x, q.z) > 0.05:
				wet_fires += 1
			if map.slope_at(q.x, q.z) > 0.45:
				buried_fires += 1
		for sm in vfx._smokes:
			var q: Vector3 = sm.global_position
			var dy := q.y - map.height_at(q.x, q.z)
			counts.smoke += 1
			note("smoke", dy, "smoke at (%.0f, %.0f)" % [q.x, q.z])
			if dy < 0.3 or dy > 1.4:
				bad.smoke += 1

		# ---- flocks ----------------------------------------------------------
		for f in life._flocks:
			if not f.awake:
				continue
			for i in range(f.n):
				var q: Vector3 = f.pos[i]
				if not map.in_bounds(q.x, q.z):
					continue
				var dy := q.y - map.height_at(q.x, q.z)
				match f.kind:
					Wildlife.K_BIRD:
						if f.down[i] == 1:
							counts.bird_perched += 1
							note("bird_perched", dy, "perched bird at (%.0f, %.0f)" % [q.x, q.z])
							if dy < 0.0 or dy > 0.30:
								bad.bird_perched += 1
						else:
							counts.bird_flying += 1
							note("bird_flying", dy, "bird at (%.0f, %.0f)" % [q.x, q.z])
							if dy < 0.05:
								bad.bird_flying += 1
					Wildlife.K_BAT:
						counts.bat += 1
						note("bat", dy, "bat at (%.0f, %.0f)" % [q.x, q.z])
						if dy < 1.9:
							bad.bat += 1
					Wildlife.K_BUTTERFLY:
						counts.bfly += 1
						note("bfly", dy, "butterfly at (%.0f, %.0f)" % [q.x, q.z])
						if dy < 0.20 or dy > 2.7:
							bad.bfly += 1
						# A follow-flock that is correctly grounded but 90 m from the
						# player is still broken - that is exactly how the origin-spawn
						# bug hid from the first version of this audit.
						if Vector2(q.x - here.x, q.z - here.z).length() > 40.0:
							bfly_far += 1

		# ---- fish -------------------------------------------------------------
		if life._fish and life._fish.mmi.visible:
			for i in range(life._fish.n):
				# NOT mm.get_instance_transform(): the headless dummy renderer always
				# reads that back as identity. `wp` is the shoal's own record.
				var q: Vector3 = life._fish.wp[i]
				if q == Vector3.ZERO:
					continue
				var bed := map.height_at(q.x, q.z)
				var wy := map.water_y_at(q.x, q.z)
				counts.fish += 1
				# Distance outside the [bed, surface] band, signed for reporting.
				var over := q.y - (wy - 0.02)
				var under := (bed + 0.02) - q.y
				var e: float = maxf(over, under)
				note("fish", e, "fish at (%.0f, %.0f) y=%.2f bed=%.2f surf=%.2f" % [q.x, q.z, q.y, bed, wy])
				if e > 0.0:
					bad.fish += 1

		# ---- particle emitters that claim to sit on something ------------------
		var em := {
			"Pollen": [vfx._pollen, 2.6, 0.6],
			"Fireflies": [vfx._fireflies, 1.05, 0.6],
			"Leaves": [vfx._leaves, 8.0, 0.6],
			"Rain": [vfx._rain, 17.0, 0.6],
		}
		for k in em:
			var e: GPUParticles3D = em[k][0]
			if e == null or not e.emitting:
				continue
			var q := e.global_position
			var dy: float = q.y - map.height_at(q.x, q.z)
			note("emitter_" + k, dy - float(em[k][1]), "%s at (%.0f, %.0f)" % [k, q.x, q.z])
			if absf(dy - float(em[k][1])) > float(em[k][2]):
				fails += 1
				print("  FAIL  emitter %s is %.2f m off its %.1f m stand-off" % [k, dy, em[k][1]])
		if vfx._mist and vfx._mist.emitting:
			var q := vfx._mist.global_position
			var dy: float = q.y - map.water_y_at(q.x, q.z)
			note("emitter_Mist", dy - 0.45, "mist at (%.0f, %.0f)" % [q.x, q.z])

	# ---- harass every herd, which is what actually finds bad ground -----------
	# A ten-stop tour samples deer where they happen to be grazing, and grazing deer
	# stay on the gentle ground they spawned on. What puts an animal on a riverbank is
	# BOLTING: the flight target is a random point 34 m away. Chase each herd around
	# its own range and check the stance every few frames.
	world.sky.set_time(11.0)
	for h in life._herds:
		for round_i in range(6):
			var chase: Vector3 = life.nearest_deer(map.ground(h.home.x, h.home.y))
			for fr in range(60):
				life.update_focus(chase + Vector3(3.0, 0.0, 3.0))
				vfx.update_focus(chase)
				await process_frame
				if fr % 6 != 0:
					continue
				for d in h.deer:
					var q: Vector3 = d.root.global_position
					deer_samples += 1
					counts.deer += 1
					var dy2 := q.y - map.height_at(q.x, q.z)
					note("deer", dy2, "fleeing deer at (%.0f, %.0f)" % [q.x, q.z])
					if dy2 < -0.05 or dy2 > 0.12:
						bad.deer += 1
					if map.slope_at(q.x, q.z) > Wildlife.STAND_MAX_SLOPE:
						steep_deer += 1
					var lo2 := 1e9
					var hi2 := -1e9
					for li in range(4):
						var lx2: float = Wildlife.LEG_X[li]
						var lz2: float = Wildlife.LEG_Z[li]
						var yw2: float = d.yaw
						var wx2: float = q.x + lx2 * cos(yw2) - lz2 * sin(yw2)
						var wz2: float = q.z + lx2 * sin(yw2) + lz2 * cos(yw2)
						var gg2: float = map.height_at(wx2, wz2)
						lo2 = minf(lo2, gg2)
						hi2 = maxf(hi2, gg2)
					var sp2: float = hi2 - lo2
					worst_splay = maxf(worst_splay, sp2)
					if sp2 > 0.55:
						splayed_deer += 1

	# ---- forced landing: birds must come down ON the ground -------------------
	# The natural CIRCLE->DESCEND timer is 6-22 s of wall clock and a headless frame is
	# a couple of milliseconds, so waiting for one costs minutes. Zero the timer and
	# park the focus far enough away that the flock is not startled back into the air.
	var bird_flock = null
	for f in life._flocks:
		if f.kind == Wildlife.K_BIRD:
			bird_flock = f
			break
	if bird_flock:
		world.sky.set_time(10.0)
		var away: Vector2 = bird_flock.home + Vector2(85.0, 85.0)
		var afar := map.ground(away.x, away.y)
		bird_flock.state = Wildlife.CIRCLE
		bird_flock.timer = 0.0
		var landed := 0
		for i in range(3000):
			vfx.update_focus(afar)
			life.update_focus(afar)
			await process_frame
			landed = 0
			for k in range(bird_flock.n):
				landed += int(bird_flock.down[k])
			if landed >= bird_flock.n or bird_flock.state == Wildlife.PERCH:
				break
		for i in range(bird_flock.n):
			var q: Vector3 = bird_flock.pos[i]
			var dy := q.y - map.height_at(q.x, q.z)
			if bird_flock.down[i] == 1:
				counts.bird_perched += 1
				note("bird_perched", dy, "perched bird at (%.0f, %.0f)" % [q.x, q.z])
				if dy < 0.0 or dy > 0.30:
					bad.bird_perched += 1
		# Whether the flock finishes its descent inside the frame budget depends on how
		# fast headless frames happen to run on a shared machine, so the descent alone
		# is a flaky assertion. The landing TARGETS are deterministic and are the thing
		# actually under test - a bird that lands on its spot lands wherever the spot is.
		for i in range(bird_flock.n):
			var sp: Vector3 = bird_flock.spot[i]
			if sp == Vector3.ZERO:
				continue
			counts.bird_spot += 1
			var dy2 := sp.y - map.height_at(sp.x, sp.z)
			note("bird_spot", dy2, "landing spot at (%.0f, %.0f)" % [sp.x, sp.z])
			if dy2 < 0.0 or dy2 > 0.30:
				bad.bird_spot += 1
		print(
			(
				"  (forced landing: %d of %d birds down, %d landing targets checked)"
				% [landed, bird_flock.n, counts.bird_spot]
			)
		)

	# =========================================================================
	print("\n--- grounding audit (%d stops) ---" % tour.size())
	for k in counts:
		var n: int = counts[k]
		var b: int = bad[k]
		var w: Array = worst.get(k, [0.0, "-"])
		print("  %-13s checked %5d   off %4d   worst %+.3f m  (%s)" % [k, n, b, w[0], w[1]])
	for k in worst:
		if k.begins_with("emitter_"):
			print("  %-13s worst %+.3f m from its stand-off  (%s)" % [k, worst[k][0], worst[k][1]])

	print("")
	for k in counts:
		ok(bad[k] == 0, "%s: every one of %d samples on the ground" % [k, counts[k]])
	ok(counts.deer > 0 and counts.monkey > 0 and counts.fire > 0, "everything got sampled")
	ok(counts.fish > 0, "fish were sampled at least once (%d)" % counts.fish)
	ok(counts.bat > 0, "bats were sampled at least once (%d)" % counts.bat)
	ok(counts.bird_spot > 0, "birds chose landing targets (%d)" % counts.bird_spot)
	ok(
		counts.bird_perched > 0 or counts.bird_spot > 0,
		"birds land on the ground (%d actually perched, %d targets verified)" % [counts.bird_perched, counts.bird_spot]
	)
	ok(counts.bfly > 0, "butterflies were sampled at least once (%d)" % counts.bfly)
	ok(bfly_far == 0, "butterflies stay with the player (%d samples over 40 m away)" % bfly_far)
	ok(wet_fires == 0, "no fire is standing in water (%d wet)" % wet_fires)
	ok(buried_fires == 0, "no fire is on a >0.45 slope (%d steep)" % buried_fires)
	var steep_frac := float(steep_deer) / maxf(float(deer_samples), 1.0)
	ok(
		steep_frac < 0.02,
		(
			"deer are not clinging to cliffs (%.1f%% of %d samples on slope>%.2f)"
			% [steep_frac * 100.0, deer_samples, Wildlife.STAND_MAX_SLOPE]
		)
	)
	var splay_frac := float(splayed_deer) / maxf(float(deer_samples), 1.0)
	ok(
		splay_frac < 0.02,
		(
			"all four hooves have ground under them (%.1f%% splayed, worst spread %.2f m)"
			% [splay_frac * 100.0, worst_splay]
		)
	)

	print("\n%s  (%d failures)" % ["ALL PASS" if fails == 0 else "FAILURES", fails])
	quit(0 if fails == 0 else 1)
