class_name WorldMapBake
extends WorldMapRoads
## Part 5 of 6 of WorldMap (see world_map.gd): the bake itself, pass by pass.
## The six parts form one inheritance chain, so every caller still writes `WorldMap.name`.

func _bake() -> void:
	var n := GRID * GRID
	heights = PackedFloat32Array()
	heights.resize(n)
	biomes = PackedByteArray()
	biomes.resize(n)
	path_mask = PackedFloat32Array()
	path_mask.resize(n)
	wet_mask = PackedFloat32Array()
	wet_mask.resize(n)

	# Heights of the flatten targets, resolved once rather than per cell.
	var h_ruins := _raw_height(P_RUINS.x, P_RUINS.y) - 2.0
	var h_camp := _raw_height(P_FOREST_CAMP.x, P_FOREST_CAMP.y)
	var h_shrine := _raw_height(P_SHRINE.x, P_SHRINE.y)

	# Pass 1 — raw height, then carve the river valley and flatten the settlements.
	for gz in range(GRID):
		if gz % 16 == 0:
			_report(0.12 + 0.60 * float(gz) / float(GRID), "Carving the river valley")
		var z := -HALF + float(gz) * CELL
		for gx in range(GRID):
			var x := -HALF + float(gx) * CELL
			var i := gz * GRID + gx
			var p := Vector2(x, z)
			var h := _raw_height(x, z)

			# --- Flat ground for the built places --------------------------
			# These run BEFORE the river carve on purpose. When they ran after, the
			# village's flatten disc filled the channel and left 16 river samples
			# sitting above their own water surface.
			h = _flatten(h, p, P_VILLAGE, 50.0, 84.0, 12.6)
			h = _flatten(h, p, P_FIELDS, 40.0, 68.0, 9.4)
			h = _flatten(h, p, P_RUINS, 30.0, 48.0, h_ruins)
			h = _flatten(h, p, P_FOREST_CAMP, 22.0, 36.0, h_camp)
			h = _flatten(h, p, P_HIDDEN_GROVE, 34.0, 56.0, 30.0)
			h = _flatten(h, p, P_SHRINE, 15.0, 26.0, h_shrine)

			# --- River valley ---------------------------------------------
			# The ground near the river is defined RELATIVE to the local water surface,
			# not to an absolute sea level. That is what lets the river descend 45 m
			# across the map, fall over a cliff, and still always hold water.
			var rd: float = _df_river[i]
			var wy: float = _df_river_wy[i]
			var hw := _river_half_width(p)
			h = _carve_river_valley(h, p, rd, wy, hw)

			path_mask[i] = _falloff(_df_path[i], 4.2)
			heights[i] = h
			wet_mask[i] = clampf(1.0 - (rd - hw) / 26.0, 0.0, 1.0)

	# Pass 2 — smooth the path corridors so they are actually walkable, and
	# soften the flatten seams.
	_report(0.74, "Smoothing the roads")
	_smooth_high_ground()
	_carve_path_corridors()
	_report(0.86, "Marking forest, field and bank")
	_classify()
	_report(0.93, "Shading the hollows")
	_bake_shading()


## Pull the ground toward the river's own profile: a U-shaped bed, a sand bank and a
## terrace, blended back into the natural terrain with distance. `rd` is the distance to
## the centreline, `wy` the water height there and `hw` the half-width of the channel.
func _carve_river_valley(h: float, p: Vector2, rd: float, wy: float, hw: float) -> float:
	if rd >= hw + 54.0:
		return h
	var x: float = p.x
	var z: float = p.y
	# Perturb the distance used for the BANKS (never for the submerged bed,
	# which must stay strictly below the water surface). Without this the
	# gorge below the falls was a perfectly straight wall and the valley
	# sides were visibly concentric.
	var rdn: float = rd
	if rd > hw:
		rdn = (rd + _n_hill.get_noise_2d(x * 2.6, z * 2.6) * 8.0 + _n_detail.get_noise_2d(x * 1.1, z * 1.1) * 2.6)
		rdn = maxf(rdn, hw + 0.05)
	var carved: float
	if rd <= hw:
		# U-shaped submerged bed.
		var u: float = rd / hw
		carved = wy - lerpf(4.2, 0.35, pow(u, 1.6))
	elif rdn <= hw + 9.0:
		# Sand/shingle bank rising gently out of the water.
		var u2: float = (rdn - hw) / 9.0
		carved = lerpf(wy - 0.35, wy + 1.5, smoothstep(0.0, 1.0, u2))
	else:
		# Terrace climbing away from the bank.
		var u3: float = rdn - hw - 9.0
		carved = wy + 1.5 + u3 * 0.42 - u3 * u3 * 0.0042
	# Keep some of the natural terrain's character inside the valley so the
	# banks are not a perfectly swept ramp.
	carved += _n_detail.get_noise_2d(x * 0.8, z * 0.8) * 0.7
	# Blend from fully-carved near the channel out to natural terrain. A wide
	# band here produced visible Voronoi fans radiating from the centreline.
	var w: float = 1.0 - smoothstep(hw + 14.0, hw + 54.0, rd)
	h = lerpf(h, carved, w * w * (3.0 - 2.0 * w))
	return h


## Blend the terrain toward a flat target over an IRREGULAR footprint. A plain radial
## falloff produced obvious circular craters on the map, which read as engine artifacts
## rather than landscape, so the radius is warped by noise and the edge is wide and soft.
func _flatten(h: float, p: Vector2, centre: Vector2, inner: float, outer: float, target: float) -> float:
	var d: float = p.distance_to(centre)
	var band := outer - inner
	# Warp the boundary so the footprint has bays and spurs.
	d += _n_hill.get_noise_2d((p.x + centre.x) * 1.9, (p.y + centre.y) * 1.9) * band * 0.85
	d += _n_base.get_noise_2d(p.x * 3.1 + centre.y, p.y * 3.1 - centre.x) * band * 0.40
	d += _n_detail.get_noise_2d(p.x * 0.35 + centre.x, p.y * 0.35) * band * 0.16
	if d >= outer:
		return h
	var t: float = 1.0 - clampf(inverse_lerp(inner, outer, d), 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)
	t = t * t * (3.0 - 2.0 * t)
	# The target itself gets a whisper of relief so settled ground is not a pancake.
	var tgt := target + _n_detail.get_noise_2d(p.x * 0.6, p.y * 0.6) * 0.35
	return lerpf(h, tgt, t)
