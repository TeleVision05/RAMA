class_name WorldMapGround
extends WorldMapField
## Part 3 of 6 of WorldMap (see world_map.gd): smoothing, levelling, biome classification and baked shading.
## The six parts form one inheritance chain, so every caller still writes `WorldMap.name`.

## Round off the peaks. Raw ridged noise is far sharper than any real eroded range,
## and at 8 m LOD those spikes alias into a shimmering comb on the horizon.
func _smooth_high_ground() -> void:
	var blurred := _box_blur(heights, 3, 2)
	var blurred2 := _box_blur(heights, 9, 1)
	for i in range(GRID * GRID):
		var h: float = heights[i]
		if h < 58.0:
			continue
		var t: float = clampf((h - 58.0) / 60.0, 0.0, 1.0)
		var target: float = lerpf(blurred[i], blurred2[i], t * 0.6)
		heights[i] = lerpf(h, target, 0.55 + 0.35 * t)


func _relevel(centre: Vector2, inner: float, outer: float, target: float) -> void:
	var r := int(ceil(outer / CELL))
	var cgx := int(round((centre.x + HALF) / CELL))
	var cgz := int(round((centre.y + HALF) / CELL))
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var gx := cgx + dx
			var gz := cgz + dz
			if gx < 0 or gz < 0 or gx >= GRID or gz >= GRID:
				continue
			var j := gz * GRID + gx
			var wx := -HALF + float(gx) * CELL
			var wz := -HALF + float(gz) * CELL
			var p := Vector2(wx, wz)
			var d := p.distance_to(centre)
			d += _n_hill.get_noise_2d(p.x * 1.9, p.y * 1.9) * (outer - inner) * 0.7
			d += _n_base.get_noise_2d(p.x * 3.3, p.y * 3.3) * (outer - inner) * 0.28
			if d >= outer:
				continue
			var t: float = 1.0 - clampf(inverse_lerp(inner, outer, d), 0.0, 1.0)
			t = t * t * (3.0 - 2.0 * t)
			# Never let levelled ground fill the river: the paddy-field terrace used to
			# push the bed 1.7 m above its own water surface.
			var hw := _river_half_width(p)
			if _df_river[j] < hw + 8.0:
				t *= smoothstep(hw - 2.0, hw + 8.0, _df_river[j])
			var tgt := target + _n_detail.get_noise_2d(p.x * 0.6, p.y * 0.6) * 0.25
			heights[j] = lerpf(heights[j], tgt, t)


func _classify() -> void:
	for gz in range(GRID):
		var z := -HALF + float(gz) * CELL
		for gx in range(GRID):
			var x := -HALF + float(gx) * CELL
			var i := gz * GRID + gx
			var p := Vector2(x, z)
			var h: float = heights[i]
			var slope := _slope_at_index(gx, gz)
			var wy: float = _df_river_wy[i]
			var rd: float = _df_river[i]
			var hw := _river_half_width(p)
			var b: int = Biome.MEADOW

			if rd < hw + 1.0 and h < wy - 0.2:
				b = Biome.RIVERBED
			elif rd < hw + 12.0 and h < wy + 2.4:
				b = Biome.SAND
			elif h > 96.0 or (slope > 0.72 and h > 56.0):
				b = Biome.MOUNTAIN
			elif slope > 0.62:
				b = Biome.ROCK
			elif p.distance_to(P_VILLAGE) < 62.0:
				b = Biome.VILLAGE
			elif p.distance_to(P_FIELDS) < 54.0:
				b = Biome.FIELD
			elif _forest_density_raw(p) > 0.42:
				b = Biome.FOREST

			if path_mask[i] > 0.45:
				b = Biome.PATH
			biomes[i] = b


## Running-sum box blur, O(cells) for any radius. Repeated box blurs approximate a
## Gaussian; doing it with per-pass 3-taps would have needed ~70 passes for radius 12.
func _box_blur(src: PackedFloat32Array, radius: int, passes: int) -> PackedFloat32Array:
	var a := src.duplicate()
	var b := PackedFloat32Array()
	b.resize(GRID * GRID)
	var inv := 1.0 / float(radius * 2 + 1)
	for _p in range(passes):
		for gz in range(GRID):
			var row := gz * GRID
			var acc := 0.0
			for k in range(-radius, radius + 1):
				acc += a[row + clampi(k, 0, GRID - 1)]
			for gx in range(GRID):
				b[row + gx] = acc * inv
				acc -= a[row + clampi(gx - radius, 0, GRID - 1)]
				acc += a[row + clampi(gx + radius + 1, 0, GRID - 1)]
		for gx in range(GRID):
			var acc2 := 0.0
			for k in range(-radius, radius + 1):
				acc2 += b[clampi(k, 0, GRID - 1) * GRID + gx]
			for gz in range(GRID):
				a[gz * GRID + gx] = acc2 * inv
				acc2 -= b[clampi(gz - radius, 0, GRID - 1) * GRID + gx]
				acc2 += b[clampi(gz + radius + 1, 0, GRID - 1) * GRID + gx]
	return a


## Bake ambient occlusion and ground-layer weights once, into the cached map.
func _bake_shading() -> void:
	var n := GRID * GRID
	# AO from the difference between the terrain and blurred copies of itself at two
	# scales: hollows and cliff bases sit below their local mean and go dark, ridges
	# sit above and stay bright.
	var near := _box_blur(heights, 5, 2)
	var far := _box_blur(heights, 22, 2)
	ao = PackedByteArray()
	ao.resize(n)
	layer = PackedByteArray()
	layer.resize(n * 4)

	for gz in range(GRID):
		var z := -HALF + float(gz) * CELL
		for gx in range(GRID):
			var i := gz * GRID + gx
			var x := -HALF + float(gx) * CELL
			var h: float = heights[i]
			var o: float = 1.0 + (h - near[i]) * 0.16 + (h - far[i]) * 0.030
			ao[i] = int(clampf(o, 0.30, 1.0) * 255.0)

			var slope := _slope_at_index(gx, gz)
			var b: int = biomes[i]
			var wy: float = _df_river_wy[i]
			var rock: float = smoothstep(0.30, 0.62, slope)
			if b == Biome.MOUNTAIN:
				rock = maxf(rock, smoothstep(0.16, 0.42, slope) * 0.9 + 0.1)
			var sand: float = clampf(1.0 - (h - wy) / 3.2, 0.0, 1.0) * clampf(1.5 - _df_river[i] / 20.0, 0.0, 1.0)
			if b == Biome.RIVERBED:
				sand = 1.0
			var dirt: float = clampf(path_mask[i] * 1.15, 0.0, 1.0)
			if b == Biome.VILLAGE:
				# Worn ground concentrated around the square and broken up by noise, so
				# the settlement does not read as one flat disc of mud.
				var vd: float = 1.0 - clampf(Vector2(x, z).distance_to(P_VILLAGE) / 58.0, 0.0, 1.0)
				var patch: float = _n_base.get_noise_2d(x * 4.0, z * 4.0) * 0.5 + 0.5
				dirt = maxf(dirt, pow(vd, 2.4) * (0.08 + patch * 0.22))
			elif b == Biome.FIELD:
				var fd: float = 1.0 - clampf(Vector2(x, z).distance_to(P_FIELDS) / 46.0, 0.0, 1.0)
				dirt = maxf(dirt, pow(fd, 1.5) * 0.32)
			var forest := 0.0
			if b == Biome.FOREST:
				forest = clampf(_forest_density_raw(Vector2(x, z)) * 1.35, 0.0, 0.76)
			forest *= (1.0 - dirt) * (1.0 - rock)
			sand = clampf(sand * (1.0 - rock * 0.8), 0.0, 1.0)
			dirt = clampf(dirt * (1.0 - rock * 0.7), 0.0, 1.0)
			var j := i * 4
			layer[j] = int(dirt * 255.0)
			layer[j + 1] = int(forest * 255.0)
			layer[j + 2] = int(rock * 255.0)
			layer[j + 3] = int(sand * 255.0)
