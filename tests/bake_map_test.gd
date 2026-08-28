extends SceneTree
## Headless diagnostic: bake the WorldMap, assert it is sane, and render a top-down
## map so the layout can actually be looked at instead of guessed about.


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var m := WorldMap.new()
	m._bake()
	var bake_ms := Time.get_ticks_msec() - t0
	print("bake: %d ms  grid=%d^2 (%d cells)" % [bake_ms, WorldMap.GRID, WorldMap.GRID * WorldMap.GRID])

	# --- statistics --------------------------------------------------------
	var lo := 1e9
	var hi := -1e9
	var sum := 0.0
	for h in m.heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
		sum += h
	print("height: min=%.2f max=%.2f mean=%.2f" % [lo, hi, sum / float(m.heights.size())])

	var names := ["RIVERBED", "SAND", "MEADOW", "FOREST", "ROCK", "MOUNTAIN", "FIELD", "VILLAGE", "PATH"]
	var counts := {}
	for b in m.biomes:
		counts[b] = counts.get(b, 0) + 1
	var total := float(m.biomes.size())
	for i in range(names.size()):
		print("  %-9s %5.2f%%" % [names[i], 100.0 * float(counts.get(i, 0)) / total])

	# --- assertions --------------------------------------------------------
	var fails: Array[String] = []
	if hi < 100.0:
		fails.append("mountains too low (max %.1f)" % hi)
	var vh := m.height_at(WorldMap.P_VILLAGE.x, WorldMap.P_VILLAGE.y)
	if vh < m.water_y_at(WorldMap.P_VILLAGE.x, WorldMap.P_VILLAGE.y) + 2.0:
		fails.append("village at %.2f is at/below the river surface" % vh)
	# The village must be BUILDABLE. What matters is local gradient (can a hut stand
	# here, can an NPC walk here), not absolute range - roads legitimately descend off
	# the terrace, which an earlier range-based check wrongly flagged.
	var vworst := 0.0
	var vsteep := 0
	var vn := 0
	for a in range(-20, 21, 2):
		for b in range(-20, 21, 2):
			var g := m.slope_at(WorldMap.P_VILLAGE.x + a, WorldMap.P_VILLAGE.y + b)
			vworst = maxf(vworst, g)
			vn += 1
			if g > 0.22:
				vsteep += 1
	print("village: worst slope %.3f, %d/%d cells steeper than 0.22  (base %.2f)" % [vworst, vsteep, vn, vh])
	if float(vsteep) / float(vn) > 0.12:
		fails.append("village too broken up: %d/%d steep cells" % [vsteep, vn])

	# The paths must be walkable - no cliff steps along them.
	var worst_step := 0.0
	var worst_at := Vector2.ZERO
	var steep_list: Array = []
	for poly in m.paths():
		for i in range(poly.size() - 1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i + 1]
			var steps := int(a.distance_to(b) / 2.0) + 1
			var prev := m.height_at(a.x, a.y)
			for s in range(1, steps + 1):
				var p: Vector2 = a.lerp(b, float(s) / float(steps))
				var h := m.height_at(p.x, p.y)
				var d := absf(h - prev) / 2.0
				if d > worst_step:
					worst_step = d
					worst_at = p
				if d > 0.34:
					steep_list.append([d, p, prev, h])
				prev = h
	print("steepest path gradient: %.2f  at %s  (%d samples over 0.34)" % [worst_step, worst_at, steep_list.size()])
	steep_list.sort_custom(func(x, y): return x[0] > y[0])
	for k in range(mini(6, steep_list.size())):
		print(
			(
				"    grade %.2f at %s  %.2f -> %.2f"
				% [steep_list[k][0], steep_list[k][1], steep_list[k][2], steep_list[k][3]]
			)
		)
	if worst_step > 0.42:
		fails.append("path too steep (%.2f) near %s" % [worst_step, worst_at])

	# The river must actually be below the water line along its course.
	# The river must be submerged along its whole course, judged against the LOCAL
	# water surface (it descends ~45 m from the falls to the south-west exit).
	var dry := 0
	var shallow := 0
	var rp := m.river_points()
	var n_s := 0
	for i in range(0, rp.size(), 4):
		if not m.in_bounds(rp[i].x, rp[i].y):
			continue  # the course leaves the map at the south-west corner
		n_s += 1
		var depth := m.water_y_at(rp[i].x, rp[i].y) - m.height_at(rp[i].x, rp[i].y)
		if depth <= 0.0:
			dry += 1
			print(
				(
					"    dry at %s  ground=%.2f water=%.2f"
					% [rp[i], m.height_at(rp[i].x, rp[i].y), m.water_y_at(rp[i].x, rp[i].y)]
				)
			)
		elif depth < 1.2:
			shallow += 1
	print("river: %d dry, %d shallow (<1.2 m) of %d samples" % [dry, shallow, n_s])
	if dry > 0:
		fails.append("%d river samples are above their own water surface" % dry)

	# Shrine must be well above the surrounding ground.
	var sh := m.height_at(WorldMap.P_SHRINE.x, WorldMap.P_SHRINE.y)
	var around := 0.0
	for a in range(8):
		var ang := TAU * float(a) / 8.0
		around += m.height_at(WorldMap.P_SHRINE.x + cos(ang) * 70.0, WorldMap.P_SHRINE.y + sin(ang) * 70.0)
	around /= 8.0
	print("shrine knoll: top=%.2f  surrounds=%.2f  prominence=%.2f" % [sh, around, sh - around])
	if sh - around < 10.0:
		fails.append("shrine knoll has no prominence (%.2f)" % (sh - around))

	_render_maps(m)

	if fails.is_empty():
		print("\nRESULT: PASS")
	else:
		print("\nRESULT: FAIL")
		for f in fails:
			print("  ! " + f)
	quit(0 if fails.is_empty() else 1)


func _render_maps(m: WorldMap) -> void:
	var G := WorldMap.GRID
	var img := Image.create(G, G, false, Image.FORMAT_RGB8)
	var bio := Image.create(G, G, false, Image.FORMAT_RGB8)
	var lo := 1e9
	var hi := -1e9
	for h in m.heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)

	var BC := [
		Color(0.13, 0.24, 0.36),
		Color(0.83, 0.75, 0.55),
		Color(0.42, 0.55, 0.26),
		Color(0.13, 0.31, 0.16),
		Color(0.48, 0.45, 0.40),
		Color(0.66, 0.64, 0.62),
		Color(0.62, 0.58, 0.24),
		Color(0.70, 0.45, 0.28),
		Color(0.55, 0.42, 0.28),
	]
	for gz in range(G):
		for gx in range(G):
			var i := gz * G + gx
			var h: float = m.heights[i]
			var t: float = clampf((h - lo) / (hi - lo), 0.0, 1.0)
			# Hypsometric ramp with a hillshade so relief is readable.
			var c: Color
			if m.water_depth_at(gx - WorldMap.HALF, gz - WorldMap.HALF) > 0.02:
				c = Color(0.10, 0.26, 0.40)
			else:
				c = Color(0.25, 0.42, 0.20).lerp(Color(0.80, 0.74, 0.62), clampf(t * 1.7, 0.0, 1.0))
				if t > 0.62:
					c = c.lerp(Color(0.92, 0.92, 0.95), (t - 0.62) / 0.38)
			var hl: float = m.heights[m._idx(gx - 1, gz)]
			var hr: float = m.heights[m._idx(gx + 1, gz)]
			var hd: float = m.heights[m._idx(gx, gz - 1)]
			var hu: float = m.heights[m._idx(gx, gz + 1)]
			var n := Vector3(hl - hr, 2.0, hd - hu).normalized()
			var shade: float = clampf(n.dot(Vector3(0.4, 0.78, -0.48).normalized()) * 1.25, 0.25, 1.35)
			img.set_pixel(gx, gz, c * shade)
			bio.set_pixel(gx, gz, BC[m.biomes[i]])

	# Overlay river + paths + POIs on the biome map.
	for p in m.river_points():
		_dot(bio, m, p, 1, Color(0.2, 0.75, 1.0))
	for poly in m.paths():
		for i in range(poly.size() - 1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i + 1]
			var steps := int(a.distance_to(b))
			for s in range(steps):
				_dot(bio, m, a.lerp(b, float(s) / float(steps)), 1, Color(1, 0.85, 0.3))
	for poi in [
		WorldMap.P_VILLAGE,
		WorldMap.P_SHRINE,
		WorldMap.P_RUINS,
		WorldMap.P_WATERFALL,
		WorldMap.P_FORD,
		WorldMap.P_FOREST_CAMP,
		WorldMap.P_HIDDEN_GROVE,
		WorldMap.P_BADLANDS,
		WorldMap.P_FIELDS,
		WorldMap.P_LOOKOUT
	]:
		_dot(bio, m, poi, 5, Color(1, 0.1, 0.1))
		_dot(img, m, poi, 5, Color(1, 0.1, 0.1))

	img.save_png("res://build/map_height.png")
	bio.save_png("res://build/map_biome.png")
	print("wrote build/map_height.png and build/map_biome.png")


func _dot(img: Image, _m: WorldMap, p: Vector2, r: int, c: Color) -> void:
	var gx := int((p.x + WorldMap.HALF) / WorldMap.CELL)
	var gz := int((p.y + WorldMap.HALF) / WorldMap.CELL)
	for a in range(-r, r + 1):
		for b in range(-r, r + 1):
			var x := gx + a
			var z := gz + b
			if x >= 0 and z >= 0 and x < img.get_width() and z < img.get_height():
				img.set_pixel(x, z, c)
