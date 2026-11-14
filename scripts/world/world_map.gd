class_name WorldMap
extends RefCounted
## THE authoritative model of the Vale of Panchavati.
##
## Every other system — terrain meshing, foliage scatter, prop placement, NPC spawns,
## navigation, water, audio zones — queries THIS. Nothing is allowed to invent its own
## idea of where the ground is. That single rule is what keeps the world coherent and
## stops props floating or sinking.
##
## Layout (world spans WORLD_SIZE metres, centred on the origin):
##   N   rising foothills -> impassable mountain ridge backdrop
##   NE->SW  the river Godavari, carved valley, waterfall in the north
##   S bank  the village of Panchavati on a flat river terrace, fields to its south
##   E   the shrine knoll, a rocky hill with a carved stone shrine on top
##   W/SW  deep forest, dark and dense, where the rakshasas are
##   NW  ruins in a clearing
##   SE  eroded rock badlands
##   far W  a hidden grove behind a rock arch

const WORLD_SIZE: float = 768.0
const HALF: float = WORLD_SIZE * 0.5
const CELL: float = 1.0  # heightfield resolution, metres
const GRID: int = int(WORLD_SIZE / CELL) + 1  # 769 samples per side

const WATER_LEVEL: float = 6.0
const SEED: int = 0x5241_4D41  # "RAMA"

# --- Biome ids -------------------------------------------------------------
enum Biome { RIVERBED, SAND, MEADOW, FOREST, ROCK, MOUNTAIN, FIELD, VILLAGE, PATH }

# --- Named places. Positions are XZ; Y is resolved from the heightfield. ----
const P_VILLAGE := Vector2(-120.0, 44.0)
const P_SHRINE := Vector2(158.0, -66.0)
const P_RUINS := Vector2(-168.0, -148.0)
const P_WATERFALL := Vector2(38.0, -196.0)
const P_FORD := Vector2(-34.0, 8.0)
const P_FOREST_CAMP := Vector2(-196.0, -34.0)
const P_HIDDEN_GROVE := Vector2(-322.0, 118.0)
const P_BADLANDS := Vector2(214.0, 178.0)
const P_FIELDS := Vector2(-92.0, 6.0)
const P_LOOKOUT := Vector2(96.0, -150.0)

var heights: PackedFloat32Array  # GRID*GRID, metres
var biomes: PackedByteArray  # GRID*GRID, Biome
var path_mask: PackedFloat32Array  # GRID*GRID, 0..1 how "trodden path" a cell is
var wet_mask: PackedFloat32Array  # GRID*GRID, 0..1 proximity to water (damp ground)

## Baked per-cell shading data, so meshing a chunk is pure array reads. Computing AO
## and layer weights per vertex at mesh time cost 95 ms for a single LOD0 chunk, which
## is a visible hitch every time the player crosses an LOD boundary.
var ao: PackedByteArray  # GRID*GRID, sky occlusion 0..255
var layer: PackedByteArray  # GRID*GRID*4, [dirt, forest, rock, sand]

var _river: Array[Vector2] = []  # river centreline control points, NE -> SW
var _paths: Array = []  # Array[Array[Vector2]] of path polylines

# Precomputed distance fields (metres). Built with a two-pass chamfer transform so a
# bake is O(cells) instead of O(cells * curve-points) — the difference between a
# ~0.4 s bake and a ~90 s one, which matters because this runs on every iteration.
var _df_river: PackedFloat32Array
var _df_path: PackedFloat32Array
## Water surface height propagated outward from the river. A single flat water plane
## cannot work here: the Godavari drops ~30 m from the falls to the south-west exit,
## so every water query is local to the nearest point of the course.
var _df_river_wy: PackedFloat32Array
var _river_wy: PackedFloat32Array  # per-centreline-point water height

const _BIG: float = 1.0e9

var _n_base: FastNoiseLite
var _n_hill: FastNoiseLite
var _n_detail: FastNoiseLite
var _n_warp: FastNoiseLite
var _n_rock: FastNoiseLite

const CACHE_PATH := "user://worldmap.cache"
const CACHE_MAGIC := 0x524D4150  # 'RMAP'
const CACHE_VERSION := 13


# ---------------------------------------------------------------------------
## Called as the map is prepared: progress(fraction 0..1, plain-language step). The
## loading screen sets this; it stays empty in tests and tools.
static var progress: Callable = Callable()


static func _report(frac: float, text: String) -> void:
	if progress.is_valid():
		progress.call(clampf(frac, 0.0, 1.0), text)


## Build the map, using the on-disk cache when it matches this generator. A missing,
## truncated or stale cache is not an error: the map is simply baked again (about ten
## seconds) and the cache rewritten. `cache_path` exists so a test can aim at a copy.
static func load_or_bake(verbose: bool = false, cache_path: String = CACHE_PATH) -> WorldMap:
	_report(0.0, "Surveying the vale")
	var m := WorldMap.new()
	if m._try_load_cache(cache_path):
		if verbose:
			print("[worldmap] loaded cache")
		_report(1.0, "Terrain ready")
		return m
	var t0 := Time.get_ticks_msec()
	_report(0.12, "Shaping the land for the first time. This only happens once")
	m._bake()
	if verbose:
		print("[worldmap] baked in %d ms" % (Time.get_ticks_msec() - t0))
	m._save_cache(cache_path)
	_report(1.0, "Terrain ready")
	return m


static func _source_fingerprint() -> String:
	var md5 := FileAccess.get_md5("res://scripts/world/world_map.gd")
	return md5 if md5 != "" else "v%d" % CACHE_VERSION


func _try_load_cache(path: String = CACHE_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	# Every field after the header has a known size, so a file of the wrong length is a
	# truncated or foreign file: reject it before reading, rather than half-filling arrays.
	var fingerprint := _source_fingerprint()
	var n := GRID * GRID
	var header := 4 + 4 + 4 + fingerprint.to_utf8_buffer().size()
	if f.get_length() != header + n * 4 * 6 + n * 2 + n * 4:
		push_warning("[worldmap] cache has an unexpected size; baking again")
		return false
	if f.get_32() != CACHE_MAGIC or f.get_32() != CACHE_VERSION:
		return false
	if f.get_pascal_string() != fingerprint:
		return false
	heights = f.get_buffer(n * 4).to_float32_array()
	path_mask = f.get_buffer(n * 4).to_float32_array()
	wet_mask = f.get_buffer(n * 4).to_float32_array()
	_df_river = f.get_buffer(n * 4).to_float32_array()
	_df_river_wy = f.get_buffer(n * 4).to_float32_array()
	_df_path = f.get_buffer(n * 4).to_float32_array()
	biomes = f.get_buffer(n)
	ao = f.get_buffer(n)
	layer = f.get_buffer(n * 4)
	return heights.size() == n and biomes.size() == n and ao.size() == n and layer.size() == n * 4


func _save_cache(path: String = CACHE_PATH) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[worldmap] could not write cache")
		return
	f.store_32(CACHE_MAGIC)
	f.store_32(CACHE_VERSION)
	f.store_pascal_string(_source_fingerprint())
	f.store_buffer(heights.to_byte_array())
	f.store_buffer(path_mask.to_byte_array())
	f.store_buffer(wet_mask.to_byte_array())
	f.store_buffer(_df_river.to_byte_array())
	f.store_buffer(_df_river_wy.to_byte_array())
	f.store_buffer(_df_path.to_byte_array())
	f.store_buffer(biomes)
	f.store_buffer(ao)
	f.store_buffer(layer)


func _init() -> void:
	_make_noise()
	_build_river()
	_build_paths()
	_build_distance_fields()


func _make_noise() -> void:
	_n_base = FastNoiseLite.new()
	_n_base.seed = SEED
	_n_base.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_base.frequency = 0.0016
	_n_base.fractal_octaves = 5
	_n_base.fractal_lacunarity = 2.05
	_n_base.fractal_gain = 0.48

	_n_hill = FastNoiseLite.new()
	_n_hill.seed = SEED + 17
	_n_hill.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_hill.frequency = 0.0055
	_n_hill.fractal_octaves = 4
	_n_hill.fractal_gain = 0.5

	_n_detail = FastNoiseLite.new()
	_n_detail.seed = SEED + 41
	_n_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_detail.frequency = 0.031
	_n_detail.fractal_octaves = 3
	_n_detail.fractal_gain = 0.45

	_n_warp = FastNoiseLite.new()
	_n_warp.seed = SEED + 91
	_n_warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_warp.frequency = 0.0032
	_n_warp.fractal_octaves = 2

	# Ridged noise for rock outcrops and the mountain wall.
	_n_rock = FastNoiseLite.new()
	_n_rock.seed = SEED + 233
	_n_rock.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_rock.frequency = 0.0075
	_n_rock.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_n_rock.fractal_octaves = 3
	_n_rock.fractal_gain = 0.40


# --- The river -------------------------------------------------------------
func _build_river() -> void:
	# A hand-authored centreline: enters at the north (waterfall), swings through the
	# middle past the village, exits south-west. Hand-authored beats noise here because
	# the river is the spine the whole composition hangs off.
	var pts := [
		Vector2(60.0, -390.0),
		Vector2(46.0, -300.0),
		Vector2(38.0, -216.0),
		Vector2(34.0, -186.0),  # waterfall plunge pool is just below this
		Vector2(20.0, -140.0),
		Vector2(-2.0, -84.0),
		Vector2(-18.0, -36.0),
		Vector2(-34.0, 8.0),  # the ford
		Vector2(-58.0, 52.0),
		Vector2(-96.0, 96.0),
		Vector2(-150.0, 140.0),
		Vector2(-232.0, 196.0),
		Vector2(-330.0, 268.0),
		Vector2(-420.0, 340.0),
	]
	# Resample the polyline into dense points so distance queries are smooth.
	_river.clear()
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var steps := int(maxf(2.0, a.distance_to(b) / 3.0))
		for s in range(steps):
			var t := float(s) / float(steps)
			# Catmull-Rom-ish smoothing using neighbours for a natural meander.
			var p0: Vector2 = pts[maxi(i - 1, 0)]
			var p3: Vector2 = pts[mini(i + 2, pts.size() - 1)]
			_river.append(_catmull(p0, a, b, p3, t))
	_river.append(pts[pts.size() - 1])


static func _catmull(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


## Distance in metres from p to the river centreline. Reads the baked field.
func river_dist(p: Vector2) -> float:
	return _sample_field(_df_river, p)


func _sample_field(f: PackedFloat32Array, p: Vector2) -> float:
	if f.is_empty():
		return _BIG
	var fx: float = clampf((p.x + HALF) / CELL, 0.0, float(GRID - 1) - 0.001)
	var fz: float = clampf((p.y + HALF) / CELL, 0.0, float(GRID - 1) - 0.001)
	var gx := int(fx)
	var gz := int(fz)
	var tx := fx - float(gx)
	var tz := fz - float(gz)
	var a: float = f[_idx(gx, gz)]
	var b: float = f[_idx(gx + 1, gz)]
	var c: float = f[_idx(gx, gz + 1)]
	var d: float = f[_idx(gx + 1, gz + 1)]
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)


## Two-pass chamfer (3,4)-style distance transform. Seeds are cells with value 0.
## When `carry` is supplied, the value of the nearest seed is propagated with the
## distance, giving a cheap nearest-seed (Voronoi) field in the same sweep.
func _chamfer2(field: PackedFloat32Array, carry: PackedFloat32Array) -> void:
	var D1 := CELL
	var D2 := CELL * 1.41421356
	var offs := [[-1, 0, D1], [0, -1, D1], [-1, -1, D2], [1, -1, D2]]
	for gz in range(GRID):
		for gx in range(GRID):
			var i := gz * GRID + gx
			if field[i] <= 0.0:
				continue
			for o in offs:
				var nx: int = gx + o[0]
				var nz: int = gz + o[1]
				if nx < 0 or nz < 0 or nx >= GRID or nz >= GRID:
					continue
				var j := nz * GRID + nx
				var cand: float = field[j] + o[2]
				if cand < field[i]:
					field[i] = cand
					carry[i] = carry[j]
	var offs2 := [[1, 0, D1], [0, 1, D1], [1, 1, D2], [-1, 1, D2]]
	for gz in range(GRID - 1, -1, -1):
		for gx in range(GRID - 1, -1, -1):
			var i := gz * GRID + gx
			for o in offs2:
				var nx: int = gx + o[0]
				var nz: int = gz + o[1]
				if nx < 0 or nz < 0 or nx >= GRID or nz >= GRID:
					continue
				var j := nz * GRID + nx
				var cand: float = field[j] + o[2]
				if cand < field[i]:
					field[i] = cand
					carry[i] = carry[j]


func _chamfer(field: PackedFloat32Array) -> PackedFloat32Array:
	var D1 := CELL
	var D2 := CELL * 1.41421356
	for gz in range(GRID):
		var row := gz * GRID
		for gx in range(GRID):
			var i := row + gx
			var v: float = field[i]
			if v <= 0.0:
				continue
			if gx > 0:
				v = minf(v, field[i - 1] + D1)
			if gz > 0:
				v = minf(v, field[i - GRID] + D1)
				if gx > 0:
					v = minf(v, field[i - GRID - 1] + D2)
				if gx < GRID - 1:
					v = minf(v, field[i - GRID + 1] + D2)
			field[i] = v
	for gz in range(GRID - 1, -1, -1):
		var row2 := gz * GRID
		for gx in range(GRID - 1, -1, -1):
			var i := row2 + gx
			var v: float = field[i]
			if gx < GRID - 1:
				v = minf(v, field[i + 1] + D1)
			if gz < GRID - 1:
				v = minf(v, field[i + GRID] + D1)
				if gx < GRID - 1:
					v = minf(v, field[i + GRID + 1] + D2)
				if gx > 0:
					v = minf(v, field[i + GRID - 1] + D2)
			field[i] = v
	return field


## Small separable box blur over the grid.
func _blur(src: PackedFloat32Array, passes: int) -> PackedFloat32Array:
	var a := src
	for _p in range(passes):
		var b := a.duplicate()
		for gz in range(GRID):
			var row := gz * GRID
			for gx in range(1, GRID - 1):
				var i := row + gx
				b[i] = (a[i - 1] + a[i] + a[i + 1]) / 3.0
		var c := b.duplicate()
		for gz in range(1, GRID - 1):
			var row2 := gz * GRID
			for gx in range(GRID):
				var i := row2 + gx
				c[i] = (b[i - GRID] + b[i] + b[i + GRID]) / 3.0
		a = c
	return a


func _blank_field() -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(GRID * GRID)
	f.fill(_BIG)
	return f


func _seed_point(f: PackedFloat32Array, p: Vector2) -> void:
	var gx := int(round((p.x + HALF) / CELL))
	var gz := int(round((p.y + HALF) / CELL))
	if gx < 0 or gz < 0 or gx >= GRID or gz >= GRID:
		return
	f[gz * GRID + gx] = 0.0


func _seed_point_wy(f: PackedFloat32Array, carry: PackedFloat32Array, p: Vector2, wy: float) -> void:
	var gx := int(round((p.x + HALF) / CELL))
	var gz := int(round((p.y + HALF) / CELL))
	if gx < 0 or gz < 0 or gx >= GRID or gz >= GRID:
		return
	var i := gz * GRID + gx
	f[i] = 0.0
	carry[i] = wy


func _seed_segment_wy(f: PackedFloat32Array, carry: PackedFloat32Array, a: Vector2, b: Vector2, wa: float, wb: float) -> void:
	var steps := int(maxf(2.0, a.distance_to(b) / (CELL * 0.5)))
	for s in range(steps + 1):
		var t := float(s) / float(steps)
		_seed_point_wy(f, carry, a.lerp(b, t), lerpf(wa, wb, t))


## Seed every cell the segment a->b passes through.
func _seed_segment(f: PackedFloat32Array, a: Vector2, b: Vector2) -> void:
	var steps := int(maxf(2.0, a.distance_to(b) / (CELL * 0.5)))
	for s in range(steps + 1):
		_seed_point(f, a.lerp(b, float(s) / float(steps)))


func _build_distance_fields() -> void:
	_river_wy = PackedFloat32Array()
	_river_wy.resize(_river.size())
	for i in range(_river.size()):
		_river_wy[i] = _water_height_for_z(_river[i].y)

	var rf := _blank_field()
	var carry := PackedFloat32Array()
	carry.resize(GRID * GRID)
	carry.fill(_WY_H[0])
	for i in range(_river.size() - 1):
		_seed_segment_wy(rf, carry, _river[i], _river[i + 1], _river_wy[i], _river_wy[i + 1])
	_chamfer2(rf, carry)
	_df_river = rf
	# Blur the water-height field so the Voronoi seams at the waterfall become a steep
	# cascade rather than a jagged vertical wall.
	_df_river_wy = _blur(carry, 3)

	var pf := _blank_field()
	for poly in _paths:
		for i in range(poly.size() - 1):
			_seed_segment(pf, poly[i], poly[i + 1])
	_df_path = _chamfer(pf)


## River width at a given point along its course (widens downstream).
func _river_half_width(p: Vector2) -> float:
	var t: float = clampf(inverse_lerp(-390.0, 340.0, p.y), 0.0, 1.0)
	var w := lerpf(4.0, 13.5, t)
	# The plunge pool below the falls is a wide, deep basin.
	w += _falloff(p.distance_to(Vector2(34.0, -178.0)), 46.0) * 16.0
	return w


## Water surface height as a function of how far down the course we are. Keyed on the
## centreline's z, which increases monotonically from the northern source to the
## south-western exit. The near-vertical section is the waterfall.
const _WY_Z := [
	-390.0,
	-300.0,
	-240.0,
	-210.0,
	-200.0,
	-196.0,
	-190.0,
	-184.0,
	-170.0,
	-140.0,
	-84.0,
	-36.0,
	8.0,
	52.0,
	96.0,
	140.0,
	196.0,
	268.0,
	340.0
]
const _WY_H := [46.0, 40.0, 35.5, 33.4, 32.6, 32.0, 15.0, 10.6, 10.1, 9.5, 8.7, 8.0, 7.3, 6.5, 5.7, 4.9, 3.9, 2.6, 1.2]


static func _water_height_for_z(z: float) -> float:
	if z <= _WY_Z[0]:
		return _WY_H[0]
	for i in range(_WY_Z.size() - 1):
		if z <= _WY_Z[i + 1]:
			var t: float = inverse_lerp(_WY_Z[i], _WY_Z[i + 1], z)
			return lerpf(_WY_H[i], _WY_H[i + 1], t)
	return _WY_H[_WY_H.size() - 1]


# --- Paths -----------------------------------------------------------------
func _build_paths() -> void:
	_paths = [
		# Village -> the ford -> the shrine knoll. The final climb SPIRALS around the
		# knoll: a direct line up 26 m of prominence gave a 54-degree path.
		[
			P_VILLAGE,
			Vector2(-98.0, 36.0),
			Vector2(-74.0, 27.0),
			Vector2(-52.0, 17.0),
			P_FORD,
			Vector2(-10.0, -6.0),
			Vector2(46.0, -26.0),
			Vector2(96.0, -44.0),
			Vector2(126.0, -22.0),
			Vector2(158.0, -14.0),
			Vector2(190.0, -30.0),
			Vector2(202.0, -64.0),
			Vector2(188.0, -98.0),
			Vector2(156.0, -110.0),
			Vector2(128.0, -94.0),
			Vector2(126.0, -68.0),
			Vector2(140.0, -56.0),
			P_SHRINE
		],
		# Village -> the paddy fields, both on the same river terrace.
		[P_VILLAGE, Vector2(-115.0, 31.0), Vector2(-105.0, 17.0), P_FIELDS],
		# Village -> forest edge -> the rakshasa camp deep in the trees.
		[P_VILLAGE, Vector2(-146.0, 28.0), Vector2(-168.0, 6.0), Vector2(-184.0, -14.0), P_FOREST_CAMP],
		# The ford -> north along the river -> the falls.
		[P_FORD, Vector2(-16.0, -48.0), Vector2(6.0, -96.0), Vector2(24.0, -140.0), Vector2(34.0, -168.0)],
		# Forest camp -> the ruins in their clearing.
		[P_FOREST_CAMP, Vector2(-190.0, -84.0), Vector2(-178.0, -122.0), P_RUINS],
		# The knoll's foot -> the lookout spur over the valley.
		[Vector2(156.0, -110.0), Vector2(140.0, -126.0), Vector2(116.0, -140.0), P_LOOKOUT],
	]


func path_dist(p: Vector2) -> float:
	return _sample_field(_df_path, p)


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var l2: float = ab.length_squared()
	if l2 < 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


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


static func _falloff(d: float, radius: float) -> float:
	if d >= radius:
		return 0.0
	var t: float = 1.0 - d / radius
	return t * t * (3.0 - 2.0 * t)


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
			if rd < hw + 54.0:
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


## Carve every path into a genuinely walkable corridor.
##
## Diffusion smoothing was not enough — it left a 1.66 gradient (59 degrees) on the
## forest road. Instead: sample the path's own elevation profile, smooth and
## SLOPE-LIMIT that 1-D profile, then blend the terrain toward it inside a corridor.
## This makes walkability a property of the data rather than something to hope for.
const PATH_MAX_GRADE: float = 0.26  # ~15 degrees, comfortable to walk and to ride
const PATH_HALF_WIDTH: float = 3.2  # fully conformed
const PATH_SHOULDER: float = 21.0  # blends out to natural terrain


func _carve_path_corridors() -> void:
	# Level the settled ground FIRST, then cut the roads through it. The roads are
	# anchored to the plateau height, so the two agree where they meet.
	_relevel(P_VILLAGE, 30.0, 52.0, 12.6)
	_relevel(P_FIELDS, 24.0, 44.0, 9.4)

	# The road network is solved as ONE graph, not path by path. Solving each path
	# independently and blending the corridors afterwards lifted the forest road by
	# ~0.5 m where the ruins spur branched off it, producing a 0.72 grade at the
	# junction that neither path's own profile contained.
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

	# Spatial hash of every sample so coincident junction nodes can be welded.
	const WELD: float = 5.0
	var buckets := {}
	for ci in range(chains.size()):
		var pts: Array = chains[ci]
		for i in range(pts.size()):
			var p: Vector2 = pts[i]
			var key := Vector2i(int(floor(p.x / WELD)), int(floor(p.y / WELD)))
			if not buckets.has(key):
				buckets[key] = []
			buckets[key].append(Vector2i(ci, i))

	# Relax: smooth along each chain, weld junctions to a common height, then clamp
	# the grade. Repeating the three lets a change at a junction propagate outward.
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
					if pa.distance_to(pb) > WELD:
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

	# Splat every chain into one accumulation buffer, then apply once.
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


# --- Public queries --------------------------------------------------------
func _idx(gx: int, gz: int) -> int:
	return clampi(gz, 0, GRID - 1) * GRID + clampi(gx, 0, GRID - 1)


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
