class_name WorldMapField
extends WorldMapBase
## Part 2 of 6 of WorldMap (see world_map.gd): the raw height function and every public query on the baked map.
## The six parts form one inheritance chain, so every caller still writes `WorldMap.name`.

# --- Height field ----------------------------------------------------------
## Raw continuous terrain height before river carving and flattening.
func _raw_height(x: float, z: float) -> float:
	var wx := x + _n_warp.get_noise_2d(x, z) * 46.0
	var wz := z + _n_warp.get_noise_2d(x + 1000.0, z - 1000.0) * 46.0

	# Base land deliberately sits well ABOVE the river so the only wet ground is the
	# channel itself. An earlier version put the land at 8 m against a water line of 6 m
	# and drowned 15% of the map.
	var h := 26.0
	h += _n_base.get_noise_2d(wx, wz) * 15.0
	h += _n_hill.get_noise_2d(wx, wz) * 7.0
	h += _n_detail.get_noise_2d(x, z) * 1.1

	# Northern foothills rising into an impassable ridge.
	var north := clampf(inverse_lerp(-120.0, -384.0, z), 0.0, 1.0)
	h += pow(north, 1.85) * 130.0
	# One broad ridge line plus a smaller secondary crest. Sampling the ridged noise at
	# a long wavelength keeps the range reading as a RANGE; the earlier short-wavelength
	# version produced isolated spikes.
	var ridge: float = _n_rock.get_noise_2d(x * 0.42, z * 0.42) * 0.5 + 0.5
	var ridge2: float = _n_rock.get_noise_2d(x * 1.05 + 900.0, z * 1.05) * 0.5 + 0.5
	h += pow(north, 2.3) * (ridge * 96.0 + ridge2 * 26.0)

	# Eastern and western rims keep the playable bowl readable and hem the player in
	# without an invisible wall.
	var ex := clampf(inverse_lerp(240.0, 384.0, absf(x)), 0.0, 1.0)
	h += pow(ex, 2.0) * 70.0
	var south := clampf(inverse_lerp(250.0, 384.0, z), 0.0, 1.0)
	h += pow(south, 2.2) * 46.0

	# The shrine knoll: a distinct rocky hill.
	h += _bump(Vector2(x, z), P_SHRINE, 96.0, 30.0, 1.75)
	# A smaller lookout spur.
	h += _bump(Vector2(x, z), P_LOOKOUT, 78.0, 20.0, 1.7)
	# Badland mesas in the south-east.
	var bd: float = _falloff(Vector2(x, z).distance_to(P_BADLANDS), 130.0)
	h += bd * (_n_rock.get_noise_2d(x * 2.1 + 400.0, z * 2.1) * 0.5 + 0.5) * 34.0

	return h


static func _bump(p: Vector2, centre: Vector2, radius: float, amp: float, power: float) -> float:
	var d: float = p.distance_to(centre)
	if d >= radius:
		return 0.0
	var t: float = 1.0 - d / radius
	return pow(t, power) * amp


## Where the forest wants to be, before any per-tree jitter. Also used by the
## foliage scatter so the biome map and the actual trees always agree.
func _forest_density_raw(p: Vector2) -> float:
	# Dense in the west/south-west, thinning eastward toward the shrine.
	var west: float = clampf(inverse_lerp(120.0, -240.0, p.x), 0.0, 1.0)
	var d: float = west * 0.85
	d += _n_hill.get_noise_2d(p.x * 0.9 + 5000.0, p.y * 0.9) * 0.35
	d += 0.12
	# Clearings around built places and along the river bank.
	d -= _falloff(p.distance_to(P_VILLAGE), 92.0) * 1.4
	d -= _falloff(p.distance_to(P_FIELDS), 76.0) * 1.4
	d -= _falloff(p.distance_to(P_RUINS), 44.0) * 1.1
	d -= _falloff(p.distance_to(P_SHRINE), 60.0) * 1.0
	d -= _falloff(p.distance_to(P_FOREST_CAMP), 26.0) * 1.0
	return clampf(d, 0.0, 1.0)


## Bilinearly interpolated terrain height at world XZ. THE canonical ground query.
func height_at(x: float, z: float) -> float:
	var fx: float = clampf((x + HALF) / CELL, 0.0, float(GRID - 1) - 0.001)
	var fz: float = clampf((z + HALF) / CELL, 0.0, float(GRID - 1) - 0.001)
	var gx := int(fx)
	var gz := int(fz)
	var tx := fx - float(gx)
	var tz := fz - float(gz)
	var h00: float = heights[_idx(gx, gz)]
	var h10: float = heights[_idx(gx + 1, gz)]
	var h01: float = heights[_idx(gx, gz + 1)]
	var h11: float = heights[_idx(gx + 1, gz + 1)]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func height_at_v(p: Vector2) -> float:
	return height_at(p.x, p.y)


## Ground position as a Vector3, ready to place a prop on.
func ground(x: float, z: float) -> Vector3:
	return Vector3(x, height_at(x, z), z)


func ground_v(p: Vector2) -> Vector3:
	return Vector3(p.x, height_at(p.x, p.y), p.y)


func normal_at(x: float, z: float) -> Vector3:
	var e := 0.9
	var hl := height_at(x - e, z)
	var hr := height_at(x + e, z)
	var hd := height_at(x, z - e)
	var hu := height_at(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


## 0 = flat, 1 = vertical.
func slope_at(x: float, z: float) -> float:
	return 1.0 - normal_at(x, z).y


func _slope_at_index(gx: int, gz: int) -> float:
	var hl: float = heights[_idx(gx - 1, gz)]
	var hr: float = heights[_idx(gx + 1, gz)]
	var hd: float = heights[_idx(gx, gz - 1)]
	var hu: float = heights[_idx(gx, gz + 1)]
	return 1.0 - Vector3(hl - hr, 2.0 * CELL, hd - hu).normalized().y


func biome_at(x: float, z: float) -> int:
	var gx := int(round((x + HALF) / CELL))
	var gz := int(round((z + HALF) / CELL))
	return biomes[_idx(gx, gz)]


func path_at(x: float, z: float) -> float:
	var gx := int(round((x + HALF) / CELL))
	var gz := int(round((z + HALF) / CELL))
	return path_mask[_idx(gx, gz)]


func wet_at(x: float, z: float) -> float:
	var gx := int(round((x + HALF) / CELL))
	var gz := int(round((z + HALF) / CELL))
	return wet_mask[_idx(gx, gz)]


## Local water surface height at XZ (the river's surface near the channel).
func water_y_at(x: float, z: float) -> float:
	return _sample_field(_df_river_wy, Vector2(x, z))


## True only where the ground is genuinely submerged by the river.
func is_underwater(x: float, z: float) -> bool:
	var p := Vector2(x, z)
	return river_dist(p) < _river_half_width(p) + 1.0 and height_at(x, z) < water_y_at(x, z)


## Depth of water at XZ (0 on dry land).
func water_depth_at(x: float, z: float) -> float:
	var p := Vector2(x, z)
	if river_dist(p) > _river_half_width(p) + 3.0:
		return 0.0
	return maxf(0.0, water_y_at(x, z) - height_at(x, z))


func forest_density(p: Vector2) -> float:
	return _forest_density_raw(p)


func in_bounds(x: float, z: float) -> bool:
	return absf(x) < HALF - 2.0 and absf(z) < HALF - 2.0


func river_points() -> Array[Vector2]:
	return _river


func paths() -> Array:
	return _paths
