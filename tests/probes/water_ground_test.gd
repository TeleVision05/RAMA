extends SceneTree
## GROUNDING AUDIT for RiverWater. Headless.
##
##   tools/gd.sh test tests/water_ground_test.gd
##
## Everything this system places has to agree with WorldMap. Four independent checks,
## each of which can fail on its own:
##
##   1. HEIGHT      every water vertex sits on the surface the map says is there
##                  (`water_y_at` for the ribbon, the resolved level for a pool).
##   2. FLOATING    no water triangle is drawn ABOVE dry ground - that is the "sheet of
##                  blue plastic on the grass" failure. Rasterised, not sampled at
##                  vertices, because the interior of a big triangle is where it hides.
##   3. HOLES       everywhere the map says there is standing water inside the channel,
##                  some water triangle actually covers it.
##   4. SOLIDS      built props (the kerb) are planted: foot at or under the ground,
##                  top above it. Emitters sit at the water they belong to.
##
## Tolerances are stated as constants so a failure says how far out it was, not just
## that it failed.

# The check on the ribbon is SIGNED, and the asymmetry is the point. `water_y_at` is a
# nearest-seed field that varies across a wide section - 0.9 m between the centreline and
# the rim of the plunge basin - so a cross-section held flat (as a water surface must be)
# cannot equal it everywhere. Sitting BELOW the field is harmless: the water is simply a
# little shallower than the map assumed and the bed is still under it. Sitting ABOVE it is
# the fault, because that is water standing proud of the bank the terrain was carved to.
const H_TOL: float = 0.25  # m the ribbon may sit ABOVE the map's own water surface
const FLOAT_TOL: float = 0.12  # m of water standing over ground the map calls dry
const CELL: float = 1.0  # m, coverage raster
const HOLE_DEPTH: float = 0.40  # map depth that must be covered by geometry

var map: WorldMap
var fails: Array[String] = []
var checks: int = 0


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(false)
	map = world.map

	var water := RiverWater.new()
	water.name = "Water"
	world.add_child(water)
	var t0 := Time.get_ticks_usec()
	water.setup(map, world.sky)
	var setup_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	# global_transform is only valid once the nodes are actually in the tree; in a
	# --script SceneTree that is not true until the first frame has been pumped.
	await process_frame

	print("\n=== RiverWater grounding audit ===")
	_inventory(water, setup_ms)
	var cover := _height_and_float(water)
	_holes(cover)
	_solids(water)
	_queries(water)

	_well(water)

	print("\n--- %d checks, %d failures ---" % [checks, fails.size()])
	for f in fails:
		print("  FAIL  " + f)
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)


func _ok(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		fails.append(msg)


# --- inventory --------------------------------------------------------------
func _inventory(water: Node3D, setup_ms: float) -> void:
	var tris := 0
	var verts := 0
	var meshes := 0
	var mm_inst := 0
	var parts := 0
	var nodes := 0
	for n in _walk(water):
		nodes += 1
		if n is MeshInstance3D:
			meshes += 1
			var m: Mesh = (n as MeshInstance3D).mesh
			if m:
				for s in range(m.get_surface_count()):
					var a: Array = m.surface_get_arrays(s)
					verts += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
					var idx: Variant = a[Mesh.ARRAY_INDEX]
					if idx != null:
						tris += (idx as PackedInt32Array).size() / 3
					else:
						tris += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		elif n is MultiMeshInstance3D:
			var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
			if mm:
				mm_inst += mm.instance_count
		elif n is GPUParticles3D:
			parts += (n as GPUParticles3D).amount
	print("[inv] setup() %.1f ms | %d nodes | %d MeshInstance3D | %d tris | %d verts" % [setup_ms, nodes, meshes, tris, verts])
	print("[inv] MultiMesh instances %d | GPUParticles amount %d" % [mm_inst, parts])


func _walk(n: Node) -> Array[Node]:
	var out: Array[Node] = []
	for c in n.get_children():
		out.append(c)
		out.append_array(_walk(c))
	return out


# --- 1 + 2: vertex height, and rasterised floating water --------------------
## Returns the coverage raster: key = cell index, value = highest water surface y there.
func _height_and_float(water: Node3D) -> Dictionary:
	var cover := {}
	# The falls sheet is deliberately near-vertical, so projected down onto XZ it "stands"
	# tens of metres over the gorge wall. It counts for coverage but not for floating.
	var flat := {}
	for child in water.get_children():
		if not (child is MeshInstance3D):
			continue
		var mi: MeshInstance3D = child
		var nm: String = mi.name
		var is_river: bool = nm.begins_with("River")
		var is_pool: bool = nm == "GrovePond" or nm == "WellPool"
		var is_falls: bool = nm == "Waterfall"
		if not (is_river or is_pool or is_falls):
			continue  # the kerb is a solid, handled in _solids.
		var xf := mi.global_transform
		var arr: Array = mi.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]

		# 1. HEIGHT. The falls sheet is near-vertical, so its own vertices sit tens of
		# metres above the water surface sampled at their x/z; only the flat sheets can
		# be checked this way.
		var worst := -1e9  # worst ABOVE the field (the fault)
		var under := 0.0  # worst BELOW it (context only)
		var worst_v := Vector3.ZERO
		var off := 0
		var level := 0.0
		if is_pool:
			# Match the pool by where it actually IS, not by a constant: both pond centres
			# are resolved from the terrain at build time and neither equals its seed.
			var mc: Vector3 = mi.global_transform * mi.mesh.get_aabb().get_center()
			var best := 1e9
			for p in water.pools():
				var d2: float = (p.c as Vector2).distance_to(Vector2(mc.x, mc.z))
				if d2 < best:
					best = d2
					level = p.level
		for lv in v if not is_falls else PackedVector3Array():
			var p3: Vector3 = xf * lv
			var want: float = map.water_y_at(p3.x, p3.z) if is_river else level
			# The outer rim of every sheet is deliberately dipped a few cm and tucked
			# under the bank; only standing proud of it is a fault.
			var d: float = p3.y - want
			if d > worst:
				worst = d
				worst_v = p3
			under = minf(under, d)
			if d > H_TOL:
				off += 1
		if not is_falls:
			print(
				(
					"[height] %-12s %d verts, worst ABOVE the map surface %+.3f m, worst below %+.3f m, %d over %.2f m"
					% [nm, v.size(), worst, under, off, H_TOL]
				)
			)
			_ok(
				off == 0,
				(
					"%s: %d verts stand more than %.2f m ABOVE the map's water surface (worst %.2f m at %.1f, %.1f, %.1f)"
					% [nm, off, H_TOL, worst, worst_v.x, worst_v.y, worst_v.z]
				)
			)

		# 2. FLOATING - rasterise every triangle, not just its corners.
		var i := 0
		while i < idx.size():
			var a: Vector3 = xf * v[idx[i]]
			var b: Vector3 = xf * v[idx[i + 1]]
			var c: Vector3 = xf * v[idx[i + 2]]
			_raster(a, b, c, cover)
			if not is_falls:
				_raster(a, b, c, flat)
			i += 3

	# What "floating water" actually looks like: a sheet whose EDGE hangs over ground
	# that is lower than the surface, so the terrain is visible running underneath the
	# rim. That is a SPILL test on the boundary of the coverage raster, not a test on the
	# interior - the interior of any pond legitimately stands above its own bed.
	#
	# (`water_depth_at` is no use for this: it returns 0 beyond `half_width + 3`, so it
	# calls the outer 6 m of the marched ribbon dry, and it knows nothing about the ponds
	# at all. It is reported below only as context.)
	var spill := 0
	var worst_spill := 0.0
	var worst_at := Vector2.ZERO
	var outside := 0
	var edge_cells := 0
	var offenders: Array = []
	for k in flat:
		var xz: Vector2 = _unkey(k)
		var surf: float = flat[k]
		if not map.in_bounds(xz.x, xz.y):
			continue
		if map.water_depth_at(xz.x, xz.y) <= 0.01 and surf - map.height_at(xz.x, xz.y) > FLOAT_TOL:
			outside += 1
		var boundary := false
		var worst_here := 0.0
		for d in [Vector2(CELL, 0.0), Vector2(-CELL, 0.0), Vector2(0.0, CELL), Vector2(0.0, -CELL)]:
			var q: Vector2 = xz + d
			if not map.in_bounds(q.x, q.y):
				continue
			# `cover`, not `flat`: where the flat ribbon butts up against the falls sheet the
			# joint is covered by geometry, it is just not FLAT geometry.
			if cover.has(_key(int(floor(q.x / CELL)), int(floor(q.y / CELL)))):
				continue
			boundary = true
			# Dry ground next to the sheet must be at or above the sheet, or the water is
			# hanging over a drop.
			worst_here = maxf(worst_here, surf - map.height_at(q.x, q.y))
		if not boundary:
			continue
		edge_cells += 1
		if worst_here > FLOAT_TOL:
			spill += 1
			offenders.append([worst_here, xz])
			if worst_here > worst_spill:
				worst_spill = worst_here
				worst_at = xz
	print(
		(
			"[float] %d covered cells (%d flat, %d of them rim) | %d standing over cells the map's river corridor excludes"
			% [cover.size(), flat.size(), edge_cells, outside]
		)
	)
	print(
		"[float] %d rim cells hang more than %.2f m over lower dry ground (worst %.2f m at %s)" % [spill, FLOAT_TOL, worst_spill, worst_at]
	)
	offenders.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	for i in range(mini(8, offenders.size())):
		print("[float]   worst #%d  %.2f m at %s" % [i + 1, offenders[i][0], offenders[i][1]])
	var pct_spill: float = 100.0 * float(spill) / maxf(float(edge_cells), 1.0)
	_ok(
		pct_spill < 4.0,
		"%.1f%% of the water rim (%d cells) hangs over lower ground - worst %.2f m at %s" % [pct_spill, spill, worst_spill, worst_at]
	)
	return cover


func _key(cx: int, cz: int) -> int:
	return (cx + 4096) * 100000 + (cz + 4096)


func _unkey(k: int) -> Vector2:
	@warning_ignore("integer_division")
	var cx: int = int(k / 100000) - 4096
	var cz: int = (k % 100000) - 4096
	return Vector2(float(cx) * CELL + CELL * 0.5, float(cz) * CELL + CELL * 0.5)


## Rasterise one triangle into the XZ coverage grid, keeping the highest surface.
func _raster(a: Vector3, b: Vector3, c: Vector3, cover: Dictionary) -> void:
	var ax := a.x
	var az := a.z
	var bx := b.x
	var bz := b.z
	var cx := c.x
	var cz := c.z
	var lo_x: int = int(floor(minf(ax, minf(bx, cx)) / CELL))
	var hi_x: int = int(floor(maxf(ax, maxf(bx, cx)) / CELL))
	var lo_z: int = int(floor(minf(az, minf(bz, cz)) / CELL))
	var hi_z: int = int(floor(maxf(az, maxf(bz, cz)) / CELL))
	var den: float = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
	if absf(den) < 1e-9:
		return
	for gz in range(lo_z, hi_z + 1):
		for gx in range(lo_x, hi_x + 1):
			var px: float = float(gx) * CELL + CELL * 0.5
			var pz: float = float(gz) * CELL + CELL * 0.5
			var w0: float = ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / den
			var w1: float = ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / den
			var w2: float = 1.0 - w0 - w1
			if w0 < -0.001 or w1 < -0.001 or w2 < -0.001:
				continue
			var y: float = w0 * a.y + w1 * b.y + w2 * c.y
			var k: int = _key(gx, gz)
			if not cover.has(k) or y > float(cover[k]):
				cover[k] = y


# --- 3: holes in the ribbon -------------------------------------------------
func _holes(cover: Dictionary) -> void:
	var want := 0
	var missing := 0
	var falls_missing := 0
	var worst := 0.0
	var worst_at := Vector2.ZERO
	var z: float = -WorldMap.HALF + 2.0
	while z < WorldMap.HALF - 2.0:
		var x: float = -WorldMap.HALF + 2.0
		while x < WorldMap.HALF - 2.0:
			var d: float = map.water_depth_at(x, z)
			if d > HOLE_DEPTH and map.river_dist(Vector2(x, z)) < RiverWater.half_width(Vector2(x, z)):
				want += 1
				var k: int = _key(int(floor(x / CELL)), int(floor(z / CELL)))
				if not cover.has(k):
					missing += 1
					if z > -206.0 and z < -178.0:
						falls_missing += 1
					if d > worst:
						worst = d
						worst_at = Vector2(x, z)
			x += CELL
		z += CELL
	var pct: float = 100.0 * float(missing) / maxf(float(want), 1.0)
	print(
		(
			"[holes] %d channel cells deeper than %.2f m; %d uncovered (%.1f%%), worst %.2f m at %s"
			% [want, HOLE_DEPTH, missing, pct, worst, worst_at]
		)
	)
	print(
		(
			"[holes] of those, %d uncovered lie in the falls gorge (z -206..-178), where the" % falls_missing
			+ " water is a vertical sheet, not a flat one"
		)
	)
	_ok(pct < 3.0, "%.1f%% of the submerged channel has no water geometry over it" % pct)


# --- 4: solids and emitters -------------------------------------------------
func _solids(water: Node3D) -> void:
	for child in water.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).name.ends_with("Kerb"):
			var mi: MeshInstance3D = child
			var xf := mi.global_transform
			var arr: Array = mi.mesh.surface_get_arrays(0)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var foot := 1e9
			var top := -1e9
			var gap := -1e9  # worst gap between the lowest rim vertex and its ground
			for lv in v:
				var p: Vector3 = xf * lv
				var g: float = map.height_at(p.x, p.z)
				foot = minf(foot, p.y - g)
				top = maxf(top, p.y - g)
				gap = maxf(gap, minf(p.y - g, 0.0))
			print("[solid] %-10s foot %.2f m under ground, top %.2f m above" % [mi.name, -foot, top])
			_ok(foot < -0.05, "%s floats: its lowest vertex is %.2f m ABOVE the ground" % [mi.name, foot])
			_ok(top > 0.05, "%s is buried: nothing of it stands above the ground" % mi.name)
		elif child is GPUParticles3D:
			var gp: GPUParticles3D = child
			var p: Vector3 = gp.global_position
			var surf: float = water.water_height_at(p.x, p.z)
			var g: float = map.height_at(p.x, p.z)
			print("[solid] %-10s at (%.1f, %.1f, %.1f); ground %.2f, water %.2f" % [gp.name, p.x, p.y, p.z, g, surf])
			_ok(surf > RiverWater.NO_WATER * 0.5, "%s emits over dry land at (%.1f, %.1f)" % [gp.name, p.x, p.z])
			_ok(p.y > g - 0.5 and p.y < g + 25.0, "%s sits %.1f m off the ground at its own x/z" % [gp.name, p.y - g])


# --- the public query surface ----------------------------------------------
func _queries(water: Node3D) -> void:
	# The query API is the contract the player controller wades and swims against, so it
	# has to agree with the geometry, not just with itself.
	var probes := [
		WorldMap.P_FORD, Vector2(34.0, -184.0), Vector2(-150.0, 140.0), WorldMap.P_VILLAGE, WorldMap.P_SHRINE, RiverWater.WELL_POOL
	]
	for q in probes:
		var wy: float = water.water_height_at(q.x, q.y)
		var dep: float = water.water_depth_at(q.x, q.y)
		var wet: bool = wy > RiverWater.NO_WATER * 0.5
		print("[query] %-16s water=%s depth=%.2f  map_depth=%.2f" % [q, ("%.2f" % wy) if wet else "dry", dep, map.water_depth_at(q.x, q.y)])
		if map.water_depth_at(q.x, q.y) > 0.5:
			_ok(wet, "the map says %s is under %.2f m of water but water_height_at says dry" % [q, map.water_depth_at(q.x, q.y)])
		if map.water_depth_at(q.x, q.y) < 0.01 and not _near_pool(water, q):
			_ok(not wet, "water_height_at says %s is wet but the map says it is dry land" % q)


## The washing tank has to stand beside the village well, and the well belongs to
## Settlement. RiverWater cannot see it at build time (Game builds the water first), so
## the constant it falls back to is the thing that can rot - and it did: it was 14.6 m
## out, leaving a stone tank alone in the middle of the square. This is the check that
## catches that drift, by building the real settlement and measuring.
func _well(water: Node3D) -> void:
	if not ClassDB.class_exists("Settlement") and not _has_class("Settlement"):
		print("[well] no Settlement class in this project; skipped")
		return
	var scr: Script = load("res://scripts/world/settlement.gd")
	var st: Node3D = scr.new()
	st.name = "Settlement"
	water.get_parent().add_child(st)
	st.setup(map)
	var well := Vector2.INF
	for poi in st.points_of_interest():
		if String(poi.get("name", "")).to_lower().contains("well"):
			var p: Vector3 = poi["position"]
			well = Vector2(p.x, p.z)
	if well == Vector2.INF:
		print("[well] Settlement published no well POI; skipped")
		return
	var tank := Vector2.INF
	for c in water.get_children():
		if c is MeshInstance3D and String(c.name) == "WellKerb":
			var ab: AABB = (c as MeshInstance3D).get_aabb()
			tank = Vector2(ab.get_center().x, ab.get_center().z)
	var d: float = well.distance_to(tank)
	print("[well] settlement well at %s, washing tank at %s, %.2f m apart" % [well, tank, d])
	_ok(d < 6.0, "the washing tank is %.1f m from the village well at %s" % [d, well])


func _has_class(cls: String) -> bool:
	for e in ProjectSettings.get_global_class_list():
		if String(e.get("class", "")) == cls:
			return true
	return false


func _near_pool(water: Node3D, q: Vector2) -> bool:
	for p in water.pools():
		if q.distance_to(p.c as Vector2) <= float(p.r) + 1.0:
			return true
	return false
