class_name Ground3D
extends RefCounted
## REAL 3D ground cover: grass tufts, flowers, ferns and broad-leaved undergrowth.
##
## Everything the first pass drew as an alpha-cut card is built here as geometry with
## volume. Review's note was "a lot of them are just 2D, make sure they're all 3D", and
## `build/detail_sheet.png` is why: a card has no thickness, so grass lay flat against
## the ground texture it grew out of and a flower seen in profile was a sliver.
##
## ONE PRIMITIVE does almost all of it. `_lamina` emits a tapered, curved, keeled
## ribbon: it starts pointing along `dir`, bends toward `bend` as it goes, narrows to a
## point, and carries a raised midrib whose ridge flattens out toward the tip. That IS
## a grass blade. Widen it, cup it the other way and it is a petal. Shorten it and hang
## a row of them off a curving stalk and it is a fern frond. Because there is exactly
## one surface generator, "is it 3D?" is answered once rather than per plant.
##
## CROSS-SECTION. Rings of 3 (or 5) points across the width, the middle ones pushed
## along the face normal by `keel`. That is the V the brief asks for: at the base the
## fold is deep, so the blade is never invisible edge-on and always catches a highlight
## along one edge; by the tip the fold has flattened out. `keel` is signed — positive
## rides the midrib on the underside like real grass, negative cups a petal upward.
##
## TRIANGLE COST is (segs - 1) * (ribs - 1) * 2 + (ribs - 1), so one lamina is:
##     ribs 3, segs 1 -> 2      segs 2 -> 6      segs 3 -> 10
##     ribs 5, segs 2 -> 12     segs 3 -> 20
## which is what makes a 58-triangle grass tuft and a 250-triangle marigold clump
## possible in the same file. LOD is a `segs` and a part-count, nothing else changes,
## so the silhouette barely moves across a hand-over.
##
## The mesh builder writes the channel contract documented at the top of
## shaders/grass.gdshader. Nothing here samples a texture: the shape carries the read.

enum Layer { GRASS, FLOWER, FERN }
enum Flower { MARIGOLD, JASMINE, HIBISCUS }

const LAYER_COUNT := 3
const VARIANTS := 3
const LODS := 3

## Blades per tuft and segments per blade, by LOD. The first half of a tuft's blades
## get `segs`, the rest one fewer — the tall front blades carry the curve, the short
## filler ones do not need it. Tuft cost lands at 58 / 16 / 6 triangles.
const TUFT_BLADES := [7, 4, 3]
const TUFT_SEGS := [3, 2, 1]

const SEED := 0x5241_4D41 ^ 0x6C0_A5A

static var _cache: Dictionary = {}
static var _tris: Dictionary = {}
static var _mats: Dictionary = {}
static var _shader: Shader = null


# --- Public API ------------------------------------------------------------
## The mesh for one (layer, variant, LOD). Cached and shared by every instance in the
## world; the scatter never builds geometry of its own.
static func mesh(layer: int, variant: int, lod: int) -> ArrayMesh:
	var key := layer * 100 + variant * 10 + lod
	if _cache.has(key):
		return _cache[key]
	var m: ArrayMesh = null
	match layer:
		Layer.GRASS:
			m = _build_tuft(variant, lod)
		Layer.FLOWER:
			m = _build_flower_clump(variant, lod)
		_:
			m = _build_ground_plant(variant, lod)
	_cache[key] = m
	_tris[key] = _count_tris(m)
	return m


## Triangles in one instance of (layer, variant, LOD). The scatter reports its budget
## from this rather than from a hard-coded number that drifts the moment a petal moves.
static func tris(layer: int, variant: int, lod: int) -> int:
	var key := layer * 100 + variant * 10 + lod
	if not _tris.has(key):
		mesh(layer, variant, lod)
	return int(_tris[key])


## Build every mesh now. Called from Vegetation.setup so the first meadow the player
## walks into does not pay for 27 mesh builds in one frame.
static func prebuild() -> void:
	for l in range(LAYER_COUNT):
		for v in range(VARIANTS):
			for d in range(LODS):
				mesh(l, v, d)


## Materials are per (layer, variant) but only the flowers actually vary — each species
## needs its own petal palette, and the palette is a uniform rather than a vertex colour
## because COLOR's four channels are already spent on flex, petal, core and AO.
static func material(layer: int, variant: int) -> ShaderMaterial:
	var key := layer * 10 + (variant if layer == Layer.FLOWER else 0)
	if _mats.has(key):
		return _mats[key]
	if _shader == null:
		_shader = load("res://shaders/grass.gdshader")
	var m := ShaderMaterial.new()
	m.shader = _shader
	match layer:
		Layer.GRASS:
			# Measured against the terrain in the village meadow: at (0.55, 0.55, 0.24)
			# / (0.22, 0.45, 0.14) every tuft was brighter and more saturated than the
			# ground it grew out of, so it read as an object placed on a painted
			# surface rather than as that surface standing up.
			m.set_shader_parameter("leaf_a", Color(0.40, 0.42, 0.17))
			m.set_shader_parameter("leaf_b", Color(0.15, 0.33, 0.10))
			m.set_shader_parameter("ground_tint", Color(0.24, 0.22, 0.14))
			# 0.72 read well in an open meadow and was far too strong under a canopy,
			# where the tinted lower half of every blade went black. Real geometry needs
			# less of it than a card did, because the tuft interior is already occluded
			# by baked AO; 0.40 still seats the grass in the dirt.
			m.set_shader_parameter("ground_blend", 0.48)
			m.set_shader_parameter("translucency", 0.8)
			# 0.30 was tuned for cards, which had nothing like this screen coverage; a
			# low matted tuft should not whip like a reed. Measured 2026-08-28 while
			# chasing the flaky shaft check in tests/quest_test.gd: that test's noise
			# floor is NOT this — the median column diff is 0.072 with the wind bend at
			# zero and 0.075-0.083 with it on, while its ratio swings 3.1-4.5 run to run
			# from the peak alone. Do not tune this number against that test.
			m.set_shader_parameter("bend_scale", 0.24)
		Layer.FERN:
			m.set_shader_parameter("leaf_a", Color(0.30, 0.42, 0.16))
			m.set_shader_parameter("leaf_b", Color(0.13, 0.30, 0.10))
			m.set_shader_parameter("ground_tint", Color(0.20, 0.18, 0.12))
			m.set_shader_parameter("ground_blend", 0.30)
			m.set_shader_parameter("translucency", 1.0)
			m.set_shader_parameter("bend_scale", 0.16)
			m.set_shader_parameter("roughness_value", 0.62)
		_:
			m.set_shader_parameter("leaf_a", Color(0.36, 0.48, 0.18))
			m.set_shader_parameter("leaf_b", Color(0.18, 0.38, 0.13))
			m.set_shader_parameter("ground_blend", 0.14)
			m.set_shader_parameter("translucency", 0.55)
			m.set_shader_parameter("bend_scale", 0.14)
			m.set_shader_parameter("roughness_value", 0.55)
			m.set_shader_parameter("specular_amount", 0.4)
			match variant:
				Flower.MARIGOLD:
					m.set_shader_parameter("petal_a", Color(0.86, 0.20, 0.01))
					m.set_shader_parameter("petal_b", Color(1.00, 0.52, 0.02))
					m.set_shader_parameter("core_col", Color(0.60, 0.30, 0.02))
				Flower.JASMINE:
					m.set_shader_parameter("petal_a", Color(0.97, 0.97, 0.93))
					m.set_shader_parameter("petal_b", Color(1.00, 1.00, 1.00))
					m.set_shader_parameter("core_col", Color(0.95, 0.90, 0.55))
				_:
					m.set_shader_parameter("petal_a", Color(0.72, 0.04, 0.06))
					m.set_shader_parameter("petal_b", Color(0.95, 0.15, 0.10))
					m.set_shader_parameter("core_col", Color(0.96, 0.86, 0.42))
	_mats[key] = m
	return m


## Every material this file owns, so the caller can push wind and fade into all of them
## in one pass without knowing how many species there are.
static func all_materials() -> Array:
	var out: Array = []
	for l in range(LAYER_COUNT):
		for v in range(VARIANTS):
			var m := material(l, v)
			if not out.has(m):
				out.append(m)
	return out


static func layer_materials(layer: int) -> Array:
	var out: Array = []
	for v in range(VARIANTS):
		var m := material(layer, v)
		if not out.has(m):
			out.append(m)
	return out


# --- The one primitive -----------------------------------------------------
## A tapered, curved, keeled ribbon. See the file header for the geometry; see
## shaders/grass.gdshader for what the colour channels mean.
##
## Rings 0..segs-1 are real cross-sections; the tip is a single vertex, which is what
## makes a 1-segment lamina cost 2 triangles instead of 4 and still be a folded, 3D
## surface rather than a plane.
static func _lamina(s: TreeBuilder.Surf, cfg: Dictionary) -> void:
	var dir: Vector3 = (cfg["dir"] as Vector3).normalized()
	var bend: Vector3 = cfg["bend"]
	bend = bend - dir * bend.dot(dir)
	if bend.length_squared() < 1e-9:
		bend = _perp(dir)
	bend = bend.normalized()

	var origin: Vector3 = cfg["origin"]
	var length: float = cfg["length"]
	var width: float = cfg["width"]
	var segs: int = int(cfg["segs"])
	var ribs: int = int(cfg.get("ribs", 3))
	var droop: float = cfg.get("droop", 0.9)
	var keel: float = cfg.get("keel", 0.8)
	var twist: float = cfg.get("twist", 0.0)
	var taper: float = cfg.get("taper", 0.55)
	var bulge: float = cfg.get("bulge", 0.2)
	var dpow: float = cfg.get("dpow", 1.6)
	var hue: float = cfg.get("hue", 0.5)
	var petal: float = cfg.get("petal", 0.0)
	var core: float = cfg.get("core", 0.0)
	var ao0: float = cfg.get("ao0", 0.5)
	var ao1: float = cfg.get("ao1", 1.0)
	var flex0: float = cfg.get("flex0", 0.0)
	var flex1: float = cfg.get("flex1", 1.0)

	# Centreline, integrated rather than interpolated: the angle from `dir` grows as
	# droop * t^dpow, so the part leaves the base almost straight and rolls over near
	# the tip, which is how a blade actually hangs. Sampled every sixth substep so the
	# ring positions land exactly on r/segs.
	var sub := segs * 6
	var pos := PackedVector3Array()
	var tng := PackedVector3Array()
	pos.resize(segs + 1)
	tng.resize(segs + 1)
	var p := origin
	var stp := length / float(sub)
	for k in range(sub + 1):
		var t := float(k) / float(sub)
		var ang := droop * pow(t, dpow)
		var d := (dir * cos(ang) + bend * sin(ang)).normalized()
		if k % 6 == 0:
			pos[k / 6] = p
			tng[k / 6] = d
		p += d * stp

	var offs: PackedFloat32Array
	var kw: PackedFloat32Array
	if ribs >= 5:
		ribs = 5
		offs = PackedFloat32Array([-1.0, -0.55, 0.0, 0.55, 1.0])
		kw = PackedFloat32Array([0.0, 0.72, 1.0, 0.72, 0.0])
	else:
		ribs = 3
		offs = PackedFloat32Array([-1.0, 0.0, 1.0])
		kw = PackedFloat32Array([0.0, 1.0, 0.0])

	var side0 := dir.cross(bend)
	var rows: Array = []
	var rnrm := PackedVector3Array()
	var rside := PackedVector3Array()
	for r in range(segs):
		var t := float(r) / float(segs)
		var td: Vector3 = tng[r]
		var sd := side0.rotated(td, twist * t).normalized()
		var nf := sd.cross(td).normalized()
		rside.push_back(sd)
		rnrm.push_back(nf)
		var w := width * pow(1.0 - t, taper) * (1.0 + bulge * sin(PI * t))
		# The fold is deep at the base and gone by the tip: a V cross-section that
		# flattens, exactly as briefed. Without the extra (1-t) power the keel would
		# only shrink as fast as the width and the blade would stay a gutter all the
		# way up.
		var kk := keel * w * pow(1.0 - t, 0.7)
		var row := PackedVector3Array()
		for j in range(ribs):
			row.push_back(pos[r] + sd * (offs[j] * w) + nf * (kw[j] * kk))
		rows.push_back(row)

	var tip: Vector3 = pos[segs]
	var ids: Array = []
	for r in range(segs):
		var t := float(r) / float(segs)
		var col := Color(lerpf(flex0, flex1, t), petal, core, lerpf(ao0, ao1, t))
		var row: PackedVector3Array = rows[r]
		var prev: PackedVector3Array = rows[maxi(r - 1, 0)]
		var nxt: PackedVector3Array = rows[mini(r + 1, segs - 1)]
		var row_ids := PackedInt32Array()
		for j in range(ribs):
			# Central differences on the vertex grid. Cheaper to reason about than
			# accumulating face normals, and it gives the two halves of the V genuinely
			# different normals — which is the whole point of building the V.
			var along := (tip if r + 1 >= segs else nxt[j]) - prev[j]
			var across := row[mini(j + 1, ribs - 1)] - row[maxi(j - 1, 0)]
			var nn := across.cross(along)
			if nn.length_squared() < 1e-12:
				nn = rnrm[r]
			nn = nn.normalized()
			if nn.dot(rnrm[r]) < 0.0:
				nn = -nn
			var tan := across if across.length_squared() > 1e-12 else rside[r]
			row_ids.push_back(s.vert(row[j], nn, tan, col, Vector2(hue, t)))
		ids.append(row_ids)

	var tip_col := Color(flex1, petal, core, ao1)
	var tip_i := s.vert(tip, rnrm[segs - 1], rside[segs - 1], tip_col, Vector2(hue, 1.0))
	for r in range(segs - 1):
		var a: PackedInt32Array = ids[r]
		var b: PackedInt32Array = ids[r + 1]
		for j in range(ribs - 1):
			var want := s.n[a[j]] + s.n[a[j + 1]] + s.n[b[j]] + s.n[b[j + 1]]
			if want.length_squared() < 1e-9:
				want = rnrm[r]
			s.quad(a[j], a[j + 1], b[j + 1], b[j], want)
	var last: PackedInt32Array = ids[segs - 1]
	for j in range(ribs - 1):
		var w2 := s.n[last[j]] + s.n[last[j + 1]]
		if w2.length_squared() < 1e-9:
			w2 = rnrm[segs - 1]
		_tri_facing(s, last[j], last[j + 1], tip_i, w2)


## A tapered tube following the same integrated, drooping centreline as `_lamina`:
## stems, petioles, fern rachides and stamen columns. Returns the tip frame so whatever
## sits on the end can be placed without re-deriving the curve.
static func _stalk(s: TreeBuilder.Surf, cfg: Dictionary) -> Dictionary:
	var dir: Vector3 = (cfg["dir"] as Vector3).normalized()
	var bend: Vector3 = cfg.get("bend", Vector3.ZERO)
	bend = bend - dir * bend.dot(dir)
	if bend.length_squared() < 1e-9:
		bend = _perp(dir)
	bend = bend.normalized()

	var origin: Vector3 = cfg["origin"]
	var length: float = cfg["length"]
	var r0: float = cfg["r0"]
	var r1: float = cfg.get("r1", r0 * 0.6)
	var sides: int = int(cfg.get("sides", 3))
	var segs: int = int(cfg.get("segs", 2))
	var droop: float = cfg.get("droop", 0.0)
	var dpow: float = cfg.get("dpow", 1.6)
	var hue: float = cfg.get("hue", 0.35)
	var petal: float = cfg.get("petal", 0.0)
	var core: float = cfg.get("core", 0.0)
	var ao0: float = cfg.get("ao0", 0.5)
	var ao1: float = cfg.get("ao1", 0.9)
	var flex0: float = cfg.get("flex0", 0.0)
	var flex1: float = cfg.get("flex1", 1.0)

	var sub := segs * 6
	var pos := PackedVector3Array()
	var tng := PackedVector3Array()
	pos.resize(segs + 1)
	tng.resize(segs + 1)
	var p := origin
	var stp := length / float(sub)
	for k in range(sub + 1):
		var t := float(k) / float(sub)
		var ang := droop * pow(t, dpow)
		var d := (dir * cos(ang) + bend * sin(ang)).normalized()
		if k % 6 == 0:
			pos[k / 6] = p
			tng[k / 6] = d
		p += d * stp

	var side0 := dir.cross(bend).normalized()
	var ids: Array = []
	for r in range(segs + 1):
		var t := float(r) / float(segs)
		var td: Vector3 = tng[r]
		var sd := side0 - td * side0.dot(td)
		if sd.length_squared() < 1e-9:
			sd = _perp(td)
		sd = sd.normalized()
		var od := td.cross(sd).normalized()
		var rad := lerpf(r0, r1, t)
		var col := Color(lerpf(flex0, flex1, t), petal, core, lerpf(ao0, ao1, t))
		var row := PackedInt32Array()
		for j in range(sides):
			var a := TAU * float(j) / float(sides)
			var nn := (sd * cos(a) + od * sin(a)).normalized()
			row.push_back(s.vert(pos[r] + nn * rad, nn, od, col, Vector2(hue, t)))
		ids.append(row)
	for r in range(segs):
		var a: PackedInt32Array = ids[r]
		var b: PackedInt32Array = ids[r + 1]
		for j in range(sides):
			var j2 := (j + 1) % sides
			var want := s.n[a[j]] + s.n[a[j2]]
			s.quad(a[j], a[j2], b[j2], b[j], want)
	var last_t: Vector3 = tng[segs]
	return {"tip": pos[segs], "dir": last_t, "side": side0 - last_t * side0.dot(last_t)}


## A shallow cone: flower receptacles, buds, anther heads. `sides` triangles.
static func _dome(s: TreeBuilder.Surf, cfg: Dictionary) -> void:
	var centre: Vector3 = cfg["origin"]
	var up: Vector3 = (cfg["dir"] as Vector3).normalized()
	var rad: float = cfg["radius"]
	var hgt: float = cfg["height"]
	var sides: int = int(cfg.get("sides", 7))
	var hue: float = cfg.get("hue", 0.5)
	var petal: float = cfg.get("petal", 0.0)
	var core: float = cfg.get("core", 1.0)
	var flex: float = cfg.get("flex", 0.5)
	var ao: float = cfg.get("ao", 0.9)
	var sd := _perp(up)
	var od := up.cross(sd).normalized()
	var col := Color(flex, petal, core, ao)
	var apex := s.vert(centre + up * hgt, up, sd, col, Vector2(hue, 1.0))
	var ring := PackedInt32Array()
	for j in range(sides):
		var a := TAU * float(j) / float(sides)
		var rd := sd * cos(a) + od * sin(a)
		var nn := (rd * hgt + up * rad).normalized()
		ring.push_back(s.vert(centre + rd * rad, nn, od, col, Vector2(hue, 0.15)))
	for j in range(sides):
		var j2 := (j + 1) % sides
		var want := s.n[ring[j]] + s.n[ring[j2]] + up * 0.5
		_tri_facing(s, ring[j], ring[j2], apex, want)


# --- Grass -----------------------------------------------------------------
## A tuft: 5-9 blades fanning from a common base at varied angles, heights, bends,
## twists and hues. Three variants so a meadow is not one clump repeated — upright
## meadow grass, a low splayed rosette, and a tall wispy one.
static func _build_tuft(variant: int, lod: int) -> ArrayMesh:
	var s := TreeBuilder.Surf.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED ^ (variant * 7717 + 31)
	var n: int = TUFT_BLADES[lod]
	var segs: int = TUFT_SEGS[lod]
	# Short, splayed and matted, NOT tall and upright. The first in-world pass stood
	# 0.5 m spikes a metre apart and the meadow read as a painted ground with reeds on
	# it: what makes ground cover look like ground cover is that each tuft COVERS
	# GROUND, and a tuft that fans out to 0.24 m of radius covers four times the area of
	# one that stands to attention, for the same triangles.
	# A meadow is not one height. Variant 0 is the mat that covers the ground, variant 1
	# the middle, variant 2 the taller upright accents that break the mat and catch the
	# light — all three are drawn together in the near band, from their own blocks of the
	# same instance buffer.
	# LOD COMPENSATION. A far tuft keeps 4 of 7 blades, then 3 — and until this was
	# measured it kept them at the NEAR width, so a band-2 tuft carried 43% of the blade
	# area of a band-0 one. Multiplied by the 0.20 instance fraction band 2 used to draw
	# at, the far field carried 8.6% of the near field's blade area, and almost the whole
	# frame in a standing shot is band 1 and 2.
	#
	# Widening the survivors conserves blade area for ZERO extra triangles, which is what
	# an LOD is for: keep the aggregate, drop the detail. At 7 m a blade is two pixels
	# across and nobody can tell 22 mm from 33 mm, but they can tell grass from dirt.
	#
	# Measured 2026-08-28 with tests/probes/qa3d_cover.gd, WITH the LAYER_FRAC rise in
	# vegetation.gd, as screen area the cover occupies in a meadow frame:
	#     near 2 m  8.9 -> 9.8%     mid 12 m  8.9 -> 10.3%     far 30 m  10.4 -> 7.8%
	# So this is a real but SMALL win, not the fix. Instances rose 39% for 13% more
	# triangles, which is the trade working as intended, but the meadow still reads as a
	# grass TEXTURE with sprigs standing on it rather than as a sward.
	#
	# The remaining gap is NOT the biome weighting, which was the obvious suspect and is
	# wrong. At the village meadow the biome is VILLAGE, `_grass_weight` returns 0.60 and
	# total acceptance measures 0.54-0.58 — but a spot WorldMap actually classes MEADOW,
	# open and flat, at (132, -204), measures 8.6-9.6% cover against the village spot's
	# 8.7-10.8%. Same number. The limiter is simply blade area per square metre:
	# GRASS_PER_CELL is 2.5 tufts/m2 and a tuft is a handful of thin ribbons, so ~10% is
	# what that density buys at any weighting. Moving it needs candidate density or blade
	# width, and both cost triangles — there is headroom (the whole layer measured 0.4-1.2
	# ms/frame) but it is a deliberate art/perf trade, not a bug fix.
	#
	# Do not read the far-30 m column as a regression from this change; it moves 7.8-10.4%
	# run to run at a fixed setting, which is the noise floor of the measurement.
	var area_fix: float = [1.0, 1.55, 2.10][lod]
	var spread: float = [0.68, 0.50, 0.30][variant]
	var tall: float = [0.21, 0.29, 0.36][variant] * ([1.0, 1.08, 1.16][lod] as float)
	# Measured off the first gallery pass: at 0.80 rad the blades read as stiff spikes.
	# What makes a blade look like grass rather than a spine is that the tip goes PAST
	# horizontal, and that the bend is concentrated near the tip (dpow) so the lower
	# half stays upright and carries the arc.
	var droop: float = [1.55, 1.30, 0.88][variant]
	var wide: float = ([0.0110, 0.0096, 0.0076][variant] as float) * area_fix
	var scatter: float = [0.075, 0.058, 0.040][variant]
	# The tallest blades carry the curve; the filler ones behind them do not need it.
	var rich := int(ceil(float(n) * 0.5))
	for i in range(n):
		var a := (float(i) / float(n)) * TAU + rng.randf_range(-0.55, 0.55)
		var out := Vector3(cos(a), 0.0, sin(a))
		var base := out * rng.randf_range(0.0, scatter)
		var lean := spread * rng.randf_range(0.35, 1.55)
		_lamina(
			s,
			{
				"origin": base,
				"dir": (Vector3.UP + out * tan(lean)).normalized(),
				"bend": out,
				"length": tall * rng.randf_range(0.50, 1.45),
				"width": wide * rng.randf_range(0.70, 1.35),
				"segs": segs if i < rich else maxi(1, segs - 1),
				"ribs": 3,
				"droop": droop * rng.randf_range(0.50, 1.35),
				# A deep fold at the root is what keeps a blade legible edge-on.
				"keel": rng.randf_range(0.60, 1.15),
				"twist": rng.randf_range(-1.1, 1.1),
				"taper": 0.52,
				"bulge": 0.24,
				"hue": rng.randf(),
				# The middle of a tuft is genuinely dark. Baked here because thousands
				# of tufts cannot afford to cast the shadows that would do it for real.
				"ao0": rng.randf_range(0.34, 0.52),
				"ao1": 1.0,
				"dpow": 1.95,
			}
		)
	return _finish(s, material(Layer.GRASS, variant))


# --- Flowers ---------------------------------------------------------------
## Marigold, jasmine, hibiscus: petals arranged in 3D around a receptacle, on a stem,
## with a calyx and a few basal leaves. They have to read as flowers from the side as
## well as from above, which a card never did.
static func _build_flower_clump(species: int, lod: int) -> ArrayMesh:
	var s := TreeBuilder.Surf.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED ^ (species * 104729 + 977)
	# Marigolds and jasmine grow in bunches; a hibiscus bloom is a whole plant on its
	# own and looks wrong stacked three to a clump.
	var head_counts: Array = [[3, 2, 1], [4, 2, 1], [1, 1, 1]][species]
	var heads: int = head_counts[lod]
	var leaves: int = [4, 2, 1][lod]

	for i in range(heads):
		var a := rng.randf() * TAU
		var out := Vector3(cos(a), 0.0, sin(a))
		var off := out * rng.randf_range(0.0, 0.09)
		# Jasmine is a low bushy thing and a hibiscus bloom sits on a short woody spur;
		# only the marigold carries its head on a long stem. One scale, three plants.
		# Measured in the village meadow after the grass went to 2.5 tufts/m2: a 0.25 m
		# stem puts the head UNDER the grass, and a flower you cannot see is not a
		# flower. These now clear the mat.
		var stem_len := rng.randf_range(0.26, 0.44) * ([1.0, 0.62, 0.78][species] as float)
		var lean := rng.randf_range(0.04, 0.22)
		var stalk := _stalk(
			s,
			{
				"origin": off,
				"dir": (Vector3.UP + out * lean).normalized(),
				"bend": out,
				"length": stem_len,
				# 5.5 mm was an 11 mm thick stalk under a 70 mm flower and the first
				# gallery pass read as bamboo.
				"r0": 0.0038,
				"r1": 0.0024,
				"sides": 3 if lod > 0 else 4,
				"segs": 1 if lod > 0 else 2,
				"droop": rng.randf_range(0.10, 0.36),
				"hue": 0.25,
				"ao0": 0.45,
				"ao1": 0.8,
				"flex0": 0.0,
				"flex1": 0.72,
			}
		)
		# Species-relative bloom size. At 1.35 the hibiscus read as a red umbrella lying
		# on the grass and swamped the other two; a marigold head is the one that needed
		# the size, because its florets are individually tiny.
		var size := rng.randf_range(1.25, 1.70) * ([1.35, 1.05, 0.95][species] as float)
		_flower_head(s, stalk, species, lod, size, rng)

	# Basal leaves. Without them a flower clump seen from directly above is a colour
	# floating over bare dirt.
	for i in range(leaves):
		var a := rng.randf() * TAU
		var out := Vector3(cos(a), 0.0, sin(a))
		_lamina(
			s,
			{
				"origin": out * rng.randf_range(0.01, 0.05) + Vector3(0.0, 0.012, 0.0),
				"dir": (Vector3.UP * 0.55 + out).normalized(),
				"bend": out - Vector3.UP * 0.5,
				"length": rng.randf_range(0.12, 0.21),
				"width": rng.randf_range(0.018, 0.034),
				"segs": 2 if lod == 0 else 1,
				"ribs": 5 if lod == 0 else 3,
				"droop": rng.randf_range(0.5, 0.9),
				"keel": -0.45,
				"twist": rng.randf_range(-0.4, 0.4),
				"taper": 0.42,
				"bulge": 0.4,
				"hue": rng.randf() * 0.5,
				"ao0": 0.5,
				"ao1": 0.92,
				"flex0": 0.0,
				"flex1": 0.35,
			}
		)
	return _finish(s, material(Layer.FLOWER, species))


static func _flower_head(s: TreeBuilder.Surf, stalk: Dictionary, species: int, lod: int, size: float, rng: RandomNumberGenerator) -> void:
	var base: Vector3 = stalk["tip"]
	var up: Vector3 = (stalk["dir"] as Vector3).normalized()
	var sd: Vector3 = stalk["side"]
	if sd.length_squared() < 1e-9:
		sd = _perp(up)
	sd = sd.normalized()
	var od := up.cross(sd).normalized()
	var flex := 0.72

	# Calyx: a ring of small sepals cupping the head, so the join between stem and
	# flower is a plant and not a butt joint.
	var sepals := 5 if lod == 0 else 3
	for j in range(sepals):
		var a := TAU * float(j) / float(sepals)
		var rd := sd * cos(a) + od * sin(a)
		_lamina(
			s,
			{
				"origin": base + rd * (0.008 * size),
				"dir": (up * 0.6 + rd).normalized(),
				"bend": rd - up * 0.8,
				"length": 0.030 * size,
				"width": 0.010 * size,
				"segs": 1,
				"ribs": 3,
				"droop": 0.8,
				"keel": -0.7,
				"hue": 0.1,
				"ao0": 0.55,
				"ao1": 0.85,
				"flex0": flex,
				"flex1": flex,
			}
		)

	match species:
		Flower.MARIGOLD:
			_marigold_head(s, base, up, sd, od, size, lod, flex, rng)
		Flower.JASMINE:
			_jasmine_head(s, base, up, sd, od, size, lod, flex, rng)
		_:
			_hibiscus_head(s, base, up, sd, od, size, lod, flex, rng)


## Dense ray florets in three whorls of decreasing radius and increasing pitch, over a
## domed receptacle. The whorls are what make a marigold read as a ball of petals from
## any angle rather than a disc.
static func _marigold_head(
	s: TreeBuilder.Surf,
	base: Vector3,
	up: Vector3,
	sd: Vector3,
	od: Vector3,
	size: float,
	lod: int,
	flex: float,
	rng: RandomNumberGenerator
) -> void:
	var head := base + up * (0.006 * size)
	_dome(
		s,
		{
			"origin": head,
			"dir": up,
			"radius": 0.017 * size,
			"height": 0.018 * size,
			"sides": 7 if lod == 0 else 5,
			"hue": 0.4,
			"core": 1.0,
			"flex": flex,
			"ao": 0.72,
		}
	)
	# Four whorls, each smaller and more upright than the last, so the head is a DOME of
	# overlapping florets. Three whorls of long pointed petals is a daisy, which is what
	# the first pass rendered.
	var whorls := [[10, 1.00, 1.40, 2], [9, 0.74, 1.04, 1], [7, 0.48, 0.66, 1], [5, 0.24, 0.26, 1]]
	if lod > 0:
		whorls = [[7, 1.00, 1.30, 1], [5, 0.58, 0.72, 1]]
	for w in range(whorls.size()):
		var spec: Array = whorls[w]
		var cnt: int = spec[0]
		var rs: float = spec[1]
		var pitch: float = spec[2]
		var segs: int = spec[3]
		var roll := rng.randf() * TAU
		for j in range(cnt):
			var a := TAU * float(j) / float(cnt) + roll
			var rd := sd * cos(a) + od * sin(a)
			var dirv := (up * cos(pitch) + rd * sin(pitch)).normalized()
			_lamina(
				s,
				{
					"origin": head + rd * (0.012 * size * rs) + up * (0.008 * size),
					"dir": dirv,
					# Ray florets curl back on themselves; bending outward AND down is
					# what gives the head its round silhouette in profile.
					"bend": (rd - up * 0.55).normalized(),
					"length": 0.026 * size * (0.52 + 0.48 * rs),
					"width": 0.0105 * size,
					"segs": segs,
					"ribs": 3,
					"droop": 0.75 + 0.5 * float(w),
					"keel": -1.05,
					"twist": rng.randf_range(-0.35, 0.35),
					"taper": 0.30,
					"bulge": 0.5,
					"hue": rng.randf(),
					"petal": 1.0,
					"ao0": 0.66 - 0.1 * float(w),
					"ao1": 1.0,
					"flex0": flex,
					"flex1": flex,
				}
			)


## Five narrow white petals on a slim corolla tube.
static func _jasmine_head(
	s: TreeBuilder.Surf,
	base: Vector3,
	up: Vector3,
	sd: Vector3,
	od: Vector3,
	size: float,
	lod: int,
	flex: float,
	rng: RandomNumberGenerator
) -> void:
	var tube := _stalk(
		s,
		{
			"origin": base,
			"dir": up,
			"bend": sd,
			"length": 0.026 * size,
			"r0": 0.0045 * size,
			"r1": 0.0060 * size,
			"sides": 5,
			"segs": 1,
			"hue": 0.15,
			"core": 0.35,
			"ao0": 0.7,
			"ao1": 0.9,
			"flex0": flex,
			"flex1": flex,
		}
	)
	var head: Vector3 = tube["tip"]
	_dome(
		s,
		{
			"origin": head,
			"dir": up,
			"radius": 0.005 * size,
			"height": 0.004 * size,
			"sides": 5,
			"hue": 0.9,
			"core": 1.0,
			"flex": flex,
			"ao": 0.9,
		}
	)
	var roll := rng.randf() * TAU
	for j in range(5):
		var a := TAU * float(j) / 5.0 + roll
		var rd := sd * cos(a) + od * sin(a)
		var pitch := 1.24
		_lamina(
			s,
			{
				"origin": head + rd * (0.004 * size),
				"dir": (up * cos(pitch) + rd * sin(pitch)).normalized(),
				"bend": (rd - up * 0.35).normalized(),
				"length": 0.026 * size,
				"width": 0.0072 * size,
				"segs": 2 if lod == 0 else 1,
				"ribs": 3,
				"droop": 0.42,
				"keel": -0.85,
				"twist": rng.randf_range(-0.25, 0.25),
				"taper": 0.34,
				"bulge": 0.55,
				"hue": rng.randf() * 0.4 + 0.6,
				"petal": 1.0,
				"ao0": 0.82,
				"ao1": 1.0,
				"flex0": flex,
				"flex1": flex,
			}
		)


## Five broad recurved petals with a protruding staminal column — the one flower here
## whose profile is unmistakable, so it is the one worth spending ribs on.
static func _hibiscus_head(
	s: TreeBuilder.Surf,
	base: Vector3,
	up: Vector3,
	sd: Vector3,
	od: Vector3,
	size: float,
	lod: int,
	flex: float,
	rng: RandomNumberGenerator
) -> void:
	var head := base + up * (0.004 * size)
	var roll := rng.randf() * TAU
	for j in range(5):
		var a := TAU * float(j) / 5.0 + roll
		var rd := sd * cos(a) + od * sin(a)
		# Pitched further off the head axis and narrower than the first pass, which
		# fused the five petals into one smooth dish — a red umbrella rather than a
		# hibiscus. The recurve at the tip is what separates them in silhouette.
		var pitch := 1.16
		_lamina(
			s,
			{
				"origin": head + rd * (0.006 * size),
				"dir": (up * cos(pitch) + rd * sin(pitch)).normalized(),
				"bend": (rd - up * 0.55).normalized(),
				"length": 0.056 * size,
				"width": 0.021 * size,
				"segs": 2,
				"ribs": 5 if lod == 0 else 3,
				"droop": 1.35,
				# Cupped hard: a hibiscus petal is a shallow bowl, and the cup is what
				# holds a highlight on one side and shade on the other.
				"keel": -1.15,
				"twist": rng.randf_range(-0.3, 0.3),
				"taper": 0.30,
				"bulge": 0.75,
				"hue": rng.randf(),
				"petal": 1.0,
				"ao0": 0.7,
				"ao1": 1.0,
				"flex0": flex,
				"flex1": flex,
			}
		)
	var col := _stalk(
		s,
		{
			"origin": head,
			"dir": (up * 0.94 + sd * 0.34).normalized(),
			"bend": sd,
			"length": 0.062 * size,
			"r0": 0.0032 * size,
			"r1": 0.0020 * size,
			"sides": 5,
			"segs": 1,
			"droop": 0.30,
			"hue": 0.95,
			"core": 1.0,
			"ao0": 0.85,
			"ao1": 1.0,
			"flex0": flex,
			"flex1": flex,
		}
	)
	if lod > 0:
		return
	var tip: Vector3 = col["tip"]
	var tdir: Vector3 = (col["dir"] as Vector3).normalized()
	var tside := _perp(tdir)
	var tod := tdir.cross(tside).normalized()
	for j in range(5):
		var a := TAU * float(j) / 5.0
		var rd := tside * cos(a) + tod * sin(a)
		_dome(
			s,
			{
				"origin": tip + rd * (0.004 * size) - tdir * (0.004 * size),
				"dir": rd,
				"radius": 0.0026 * size,
				"height": 0.0034 * size,
				"sides": 3,
				"hue": 0.95,
				"core": 1.0,
				"flex": flex,
				"ao": 1.0,
			}
		)


# --- Ferns and undergrowth -------------------------------------------------
## Variants 0 and 1 are ferns — a rachis with pinnae either side, curving and drooping.
## Variant 2 is low broad-leaved undergrowth. Both exist because a forest floor that is
## a texture with a few cards on it is the flattest thing in the game.
static func _build_ground_plant(variant: int, lod: int) -> ArrayMesh:
	if variant == 2:
		return _build_broadleaf(lod)
	var s := TreeBuilder.Surf.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED ^ (variant * 22679 + 4441)
	var fronds: int = [5, 3, 2][lod] + variant
	var pairs: int = [7, 5, 3][lod]
	var reach: float = 0.42 if variant == 0 else 0.30
	var roll := rng.randf() * TAU
	for i in range(fronds):
		var a := TAU * float(i) / float(fronds) + roll + rng.randf_range(-0.3, 0.3)
		var out := Vector3(cos(a), 0.0, sin(a))
		var lean := rng.randf_range(0.42, 0.78)
		var length := reach * rng.randf_range(0.78, 1.25)
		# The frond's arch is chosen ONCE and reused below to place the pinnae. Rolling
		# a second random here is how leaflets end up floating beside their own stalk.
		var droop := rng.randf_range(0.95, 1.45)
		var dir0 := (Vector3.UP * cos(lean) + out * sin(lean)).normalized()
		var bend0 := (out - Vector3.UP * 0.9).normalized()
		bend0 = (bend0 - dir0 * bend0.dot(dir0)).normalized()
		_stalk(
			s,
			{
				"origin": out * 0.012,
				"dir": (Vector3.UP * cos(lean) + out * sin(lean)).normalized(),
				"bend": (out - Vector3.UP * 0.9).normalized(),
				"length": length,
				"r0": 0.0060,
				"r1": 0.0016,
				"sides": 3,
				"segs": 4 if lod == 0 else 2,
				# A fern frond arches: it leaves the crown climbing and finishes with the
				# tip pointing at the ground. Anything less reads as a palm leaf.
				"droop": droop,
				"hue": 0.2,
				"ao0": 0.42,
				"ao1": 0.85,
				"flex0": 0.0,
				"flex1": 1.0,
			}
		)
		# Pinnae are placed by re-walking the same curve the rachis followed, so a
		# leaflet never floats off the stalk it is supposed to be attached to.
		for k in range(pairs):
			var t := 0.16 + 0.80 * float(k) / float(pairs)
			var ang := droop * pow(t, 1.6)
			var td := (dir0 * cos(ang) + bend0 * sin(ang)).normalized()
			var pp := _walk(dir0, bend0, droop, 1.6, length, t)
			var side := dir0.cross(bend0).normalized()
			var shrink: float = 1.0 - 0.55 * t
			for sgn: float in [-1.0, 1.0]:
				var lat: Vector3 = side * sgn
				_lamina(
					s,
					{
						"origin": out * 0.012 + pp,
						"dir": (lat + td * 0.55).normalized(),
						"bend": (Vector3.DOWN + lat * 0.3).normalized(),
						"length": length * 0.31 * shrink,
						"width": length * 0.060 * shrink,
						# A pinna is 3 cm long. A second segment on it costs 4 extra
						# triangles times 14 pinnae times 5 fronds — 280 triangles a
						# plant — and is invisible; the fold and the tilt carry it.
						"segs": 1,
						"ribs": 3,
						"droop": rng.randf_range(0.45, 0.85),
						"keel": 0.85,
						# Alternate the roll along the rachis so the leaflets are not all
						# in one plane, which is the difference between a fern and a comb.
						"twist": rng.randf_range(-0.5, 0.5) * sgn + (0.35 if k % 2 == 0 else -0.35),
						"taper": 0.48,
						"bulge": 0.35,
						"hue": rng.randf() * 0.6,
						"ao0": 0.5,
						"ao1": 0.95,
						"flex0": t * 0.7,
						"flex1": minf(1.0, t * 0.7 + 0.35),
					}
				)
	return _finish(s, material(Layer.FERN, variant))


## A rosette of broad cupped leaves close to the ground. Cheap volume for the spaces
## between ferns, and it is the thing that stops the forest floor reading as a plane.
static func _build_broadleaf(lod: int) -> ArrayMesh:
	var s := TreeBuilder.Surf.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED ^ 90001
	var n: int = [7, 5, 3][lod]
	var roll := rng.randf() * TAU
	for i in range(n):
		var a := TAU * float(i) / float(n) + roll + rng.randf_range(-0.25, 0.25)
		var out := Vector3(cos(a), 0.0, sin(a))
		var lean := rng.randf_range(0.75, 1.15)
		var petiole := _stalk(
			s,
			{
				"origin": out * 0.008,
				"dir": (Vector3.UP * cos(lean) + out * sin(lean)).normalized(),
				"bend": out,
				"length": rng.randf_range(0.05, 0.10),
				"r0": 0.0042,
				"r1": 0.0026,
				"sides": 3,
				"segs": 1,
				"droop": 0.25,
				"hue": 0.2,
				"ao0": 0.4,
				"ao1": 0.7,
				"flex0": 0.0,
				"flex1": 0.4,
			}
		)
		var tip: Vector3 = petiole["tip"]
		var td: Vector3 = petiole["dir"]
		_lamina(
			s,
			{
				"origin": tip,
				"dir": td,
				"bend": (out - Vector3.UP * 0.45).normalized(),
				"length": rng.randf_range(0.13, 0.22),
				"width": rng.randf_range(0.040, 0.062),
				"segs": 2,
				"ribs": 5 if lod == 0 else 3,
				"droop": rng.randf_range(0.55, 0.95),
				# Cupped upward with a pronounced midrib: the leaf holds a curve, so it
				# is still a leaf when you look along its edge.
				"keel": -0.80,
				"twist": rng.randf_range(-0.35, 0.35),
				"taper": 0.36,
				"bulge": 0.62,
				"hue": rng.randf(),
				"ao0": 0.55,
				"ao1": 1.0,
				"flex0": 0.4,
				"flex1": 1.0,
			}
		)
	return _finish(s, material(Layer.FERN, 2))


# --- Helpers ---------------------------------------------------------------
## Position along the same drooping centreline `_lamina` and `_stalk` integrate, at
## parameter t. Used to hang pinnae off a rachis without duplicating the integrator.
static func _walk(dir: Vector3, bend: Vector3, droop: float, dpow: float, length: float, t: float) -> Vector3:
	var steps := 12
	var p := Vector3.ZERO
	var stp := length * t / float(steps)
	for k in range(steps):
		var u := t * float(k) / float(steps)
		var ang := droop * pow(u, dpow)
		p += (dir * cos(ang) + bend * sin(ang)).normalized() * stp
	return p


## Any unit vector perpendicular to `v`. The usual substitute axis Vector3(v.z, 0, -v.x)
## is ITSELF zero when v is exactly vertical, which is the degenerate case this file
## hits constantly (every stem points straight up), so that branch is not optional.
static func _perp(v: Vector3) -> Vector3:
	var c := Vector3(v.z, 0.0, -v.x)
	if c.length_squared() < 1e-9:
		c = Vector3(1.0, 0.0, 0.0)
	return c.normalized()


## Emit a triangle whose visible side faces `want`. Godot's front faces are CLOCKWISE;
## Surf.quad already handles this for quads, and this is the same rule for the tip fans.
static func _tri_facing(s: TreeBuilder.Surf, a: int, b: int, c: int, want: Vector3) -> void:
	var cr := (s.v[b] - s.v[a]).cross(s.v[c] - s.v[a])
	if cr.dot(want) > 0.0:
		s.tri(a, c, b)
	else:
		s.tri(a, b, c)


static func _finish(s: TreeBuilder.Surf, mat: Material) -> ArrayMesh:
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.to_arrays())
	m.surface_set_material(0, mat)
	return m


static func _count_tris(m: ArrayMesh) -> int:
	var t := 0
	for i in range(m.get_surface_count()):
		var a := m.surface_get_arrays(i)
		var idx = a[Mesh.ARRAY_INDEX]
		if idx != null and (idx as PackedInt32Array).size() > 0:
			t += (idx as PackedInt32Array).size() / 3
		else:
			t += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t
