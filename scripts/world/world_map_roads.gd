class_name WorldMapRoads
extends WorldMapGround
## Part 4 of 6 of WorldMap (see world_map.gd): the road network, solved as one graph and carved into the heights.
## The six parts form one inheritance chain, so every caller still writes `WorldMap.name`.

## Carve every path into a genuinely walkable corridor.
##
## Diffusion smoothing was not enough — it left a 1.66 gradient (59 degrees) on the
## forest road. Instead: sample the path's own elevation profile, smooth and
## SLOPE-LIMIT that 1-D profile, then blend the terrain toward it inside a corridor.
## This makes walkability a property of the data rather than something to hope for.
const PATH_MAX_GRADE: float = 0.26  # ~15 degrees, comfortable to walk and to ride
const PATH_HALF_WIDTH: float = 3.2  # fully conformed
const PATH_SHOULDER: float = 21.0  # blends out to natural terrain
const PATH_WELD: float = 5.0  # samples closer than this, from different roads, are one junction


func _carve_path_corridors() -> void:
	# Level the settled ground FIRST, then cut the roads through it. The roads are
	# anchored to the plateau height, so the two agree where they meet.
	_relevel(P_VILLAGE, 30.0, 52.0, 12.6)
	_relevel(P_FIELDS, 24.0, 44.0, 9.4)

	# The road network is solved as ONE graph, not path by path. Solving each path
	# independently and blending the corridors afterwards lifted the forest road by
	# ~0.5 m where the ruins spur branched off it, producing a 0.72 grade at the
	# junction that neither path's own profile contained.
	var built := _road_chains()
	var chains: Array = built[0]
	var profs: Array = built[1]
	var buckets := _weld_buckets(chains)
	_relax_profiles(chains, profs, buckets)
	var acc := _splat_chains(chains, profs)
	_apply_corridors(acc[0], acc[1], acc[2])


## Every road as a run of points about 2 m apart with the terrain height under each, the
## ends pinned to the plateau of the place they start or finish at.
func _road_chains() -> Array:
	var chains: Array = []  # Array[Array[Vector2]]
	var profs: Array = []  # Array[PackedFloat32Array]
	var anchors := {
		P_VILLAGE: 12.6,
		P_FIELDS: 9.4,
		P_SHRINE: _raw_height(P_SHRINE.x, P_SHRINE.y),
		P_RUINS: _raw_height(P_RUINS.x, P_RUINS.y) - 2.0,
		P_FOREST_CAMP: _raw_height(P_FOREST_CAMP.x, P_FOREST_CAMP.y),
	}

	for poly in _paths:
		var pts: Array[Vector2] = []
		for i in range(poly.size() - 1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i + 1]
			var steps := int(maxf(1.0, a.distance_to(b) / 2.0))
			for st in range(steps):
				pts.append(a.lerp(b, float(st) / float(steps)))
		pts.append(poly[poly.size() - 1])
		if pts.size() < 3:
			continue
		var prof := PackedFloat32Array()
		prof.resize(pts.size())
		for i in range(pts.size()):
			prof[i] = height_at(pts[i].x, pts[i].y)
		for a_pos in anchors:
			if pts[0].distance_to(a_pos) < 3.0:
				prof[0] = anchors[a_pos]
			if pts[pts.size() - 1].distance_to(a_pos) < 3.0:
				prof[pts.size() - 1] = anchors[a_pos]
		chains.append(pts)
		profs.append(prof)
	return [chains, profs]


## Spatial hash of every sample so coincident junction nodes can be welded.
func _weld_buckets(chains: Array) -> Dictionary:
	var buckets := {}
	for ci in range(chains.size()):
		var pts: Array = chains[ci]
		for i in range(pts.size()):
			var p: Vector2 = pts[i]
			var key := Vector2i(int(floor(p.x / PATH_WELD)), int(floor(p.y / PATH_WELD)))
			if not buckets.has(key):
				buckets[key] = []
			buckets[key].append(Vector2i(ci, i))
	return buckets


## Smooth along each chain, weld junctions to a common height, then clamp the grade.
## Repeating the three lets a change at a junction propagate outward.
func _relax_profiles(chains: Array, profs: Array, buckets: Dictionary) -> void:
	for _round in range(10):
		for ci in range(chains.size()):
			var prof: PackedFloat32Array = profs[ci]
			var src := prof.duplicate()
			for i in range(1, prof.size() - 1):
				prof[i] = (src[i - 1] + src[i] * 6.0 + src[i + 1]) * 0.125

		for key in buckets:
			var members: Array = buckets[key]
			if members.size() < 2:
				continue
			# Only weld samples that are genuinely on top of each other.
			for a in range(members.size()):
				var ma: Vector2i = members[a]
				var pa: Vector2 = chains[ma.x][ma.y]
				for b in range(a + 1, members.size()):
					var mb: Vector2i = members[b]
					if mb.x == ma.x:
						continue
					var pb: Vector2 = chains[mb.x][mb.y]
					if pa.distance_to(pb) > PATH_WELD:
						continue
					var pra: PackedFloat32Array = profs[ma.x]
					var prb: PackedFloat32Array = profs[mb.x]
					var avg: float = (pra[ma.y] + prb[mb.y]) * 0.5
					pra[ma.y] = avg
					prb[mb.y] = avg

		for ci in range(chains.size()):
			var pts: Array = chains[ci]
			var prof: PackedFloat32Array = profs[ci]
			for _it in range(240):
				var changed := false
				for i in range(1, prof.size()):
					var seg: float = maxf(0.25, pts[i].distance_to(pts[i - 1]))
					var lim: float = PATH_MAX_GRADE * seg
					if prof[i] - prof[i - 1] > lim:
						prof[i] = prof[i - 1] + lim
						changed = true
					elif prof[i - 1] - prof[i] > lim:
						prof[i - 1] = prof[i] + lim
						changed = true
				if not changed:
					break


## Splat every chain into three accumulation buffers: height times weight, weight, and
## how strongly the terrain conforms. Returns [acc_h, acc_w, acc_b].
func _splat_chains(chains: Array, profs: Array) -> Array:
	var n := GRID * GRID
	var acc_h := PackedFloat32Array()
	acc_h.resize(n)
	var acc_w := PackedFloat32Array()
	acc_w.resize(n)
	var acc_b := PackedFloat32Array()  # how strongly the terrain conforms
	acc_b.resize(n)
	var r := int(ceil(PATH_SHOULDER / CELL))
	for ci in range(chains.size()):
		var pts: Array = chains[ci]
		var prof: PackedFloat32Array = profs[ci]
		for i in range(pts.size()):
			var c: Vector2 = pts[i]
			var target: float = prof[i]
			var cgx := int(round((c.x + HALF) / CELL))
			var cgz := int(round((c.y + HALF) / CELL))
			for dz in range(-r, r + 1):
				for dx in range(-r, r + 1):
					var gx := cgx + dx
					var gz := cgz + dz
					if gx < 0 or gz < 0 or gx >= GRID or gz >= GRID:
						continue
					var j := gz * GRID + gx
					var d := Vector2(-HALF + float(gx) * CELL, -HALF + float(gz) * CELL).distance_to(c)
					if d > PATH_SHOULDER:
						continue
					# Sharply peaked weight: the nearest chain dominates its own
					# centreline instead of being dragged by a neighbouring road.
					var blend: float = 1.0 - smoothstep(PATH_HALF_WIDTH, PATH_SHOULDER, d)
					if blend < 0.002:
						continue
					# Peaked weight for arbitration only: whichever road is nearest wins
					# the HEIGHT, while the CONFORM amount stays a wide, soft ramp.
					var w: float = pow(blend, 5.0) + 0.0005
					acc_h[j] += target * w
					acc_w[j] += w
					acc_b[j] = maxf(acc_b[j], blend)
	return [acc_h, acc_w, acc_b]


## Apply the accumulated corridors to the heights, once.
func _apply_corridors(acc_h: PackedFloat32Array, acc_w: PackedFloat32Array, acc_b: PackedFloat32Array) -> void:
	var n := GRID * GRID
	for j in range(n):
		var w: float = acc_w[j]
		if w <= 0.0008:
			continue
		var tgt: float = acc_h[j] / w
		var wx := -HALF + float(j % GRID) * CELL
		var wz := -HALF + float(j / GRID) * CELL
		# Where a road crosses the river it becomes a FORD: the bed stays just under
		# the water so the player wades across instead of walking on the surface.
		var hw := _river_half_width(Vector2(wx, wz))
		if _df_river[j] < hw + 2.0:
			tgt = minf(tgt, _df_river_wy[j] - 0.55)
		var k: float = clampf(acc_b[j], 0.0, 1.0)
		heights[j] = lerpf(heights[j], tgt, k * k * (3.0 - 2.0 * k))
		# The graded shoulder is 21 m wide; the TRODDEN surface is not. Dirt comes from
		# the road's own distance field, set during the bake, not from the grading.
