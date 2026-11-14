class_name WorldMapBase
extends RefCounted
## Part 1 of 6 of WorldMap (see world_map.gd): constants, the baked arrays, the noise,
## the river, the distance fields and the path polylines.
## The six parts form one inheritance chain, so every caller still writes `WorldMap.name`.

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


# ---------------------------------------------------------------------------
## Called as the map is prepared: progress(fraction 0..1, plain-language step). The
## loading screen sets this; it stays empty in tests and tools.
static var progress: Callable = Callable()


static func _report(frac: float, text: String) -> void:
	if progress.is_valid():
		progress.call(clampf(frac, 0.0, 1.0), text)


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


static func _falloff(d: float, radius: float) -> float:
	if d >= radius:
		return 0.0
	var t: float = 1.0 - d / radius
	return t * t * (3.0 - 2.0 * t)


# --- Public queries --------------------------------------------------------
func _idx(gx: int, gz: int) -> int:
	return clampi(gz, 0, GRID - 1) * GRID + clampi(gx, 0, GRID - 1)
