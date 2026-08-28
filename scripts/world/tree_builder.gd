class_name TreeBuilder
extends RefCounted
## Procedural trees for the Vale of Panchavati. Every mesh here is generated, cached
## and shared; the scatter never builds geometry of its own, it only places instances.
##
## Six species, each with a silhouette you can name from a hundred metres away:
##   BANYAN  broad low dome on a fluted trunk, with aerial root pillars dropping from
##           the horizontal limbs. The pillars are the whole point — without them a
##           banyan is just a fat mango.
##   PALM    bare ringed trunk with a lean, 9-12 drooping fronds in a crown.
##   MANGO   dense rounded canopy on a short sturdy bole, dark foliage.
##   SAL     tall straight forest tree, canopy only in the top third, for depth.
##   DEAD    bleached and twisted, no leaves, for the badlands and the ruins.
##   BUSH    low dense shrub, no visible trunk (variant 2 is a fern).
##   ROCK    small boulders — clutter, but they scatter through the same pipeline.
##
## Three LODs per species/variant: FULL (near), MID (~a fifth of the triangles) and
## FAR (a crossed-quad billboard). The scatter cross-fades between them with the
## dither in foliage.gdshader.
##
## ENGINE FACT that shaped this file: Godot's front faces are CLOCKWISE, i.e. the
## visible side of a triangle (A,B,C) is the side that (B-A)x(C-A) points AWAY from.
## Getting that backwards makes a surface silently invisible. Rather than reason about
## it at ninety-odd call sites, `Surf.quad()` takes the normal the face is supposed to
## show and flips the winding itself.

enum Species { BANYAN, PALM, MANGO, SAL, DEAD, BUSH, ROCK }
enum Lod { FULL, MID, FAR }

const SPECIES_COUNT := 7
const LOD_COUNT := 3
const VARIANTS := 3

const SPECIES_NAMES := ["banyan", "palm", "mango", "sal", "dead", "bush", "rock"]

static var _mesh_cache: Dictionary = {}
static var _leaf_mats: Dictionary = {}
static var _bark_mats: Dictionary = {}
static var _all_mats: Array[ShaderMaterial] = []
static var _bark_shader: Shader = null

# Distance bands. The scatter reads these so the CPU-side LOD split and the shader-side
# dither ramp can never disagree; a mismatch shows up as trees blinking out entirely.
#
# FULL -> MID is a hard per-tree swap: every tree carries a random 0.86..1.16 multiplier
# on its own switch distance, so a stand hands over a few trees at a time instead of
# the whole hillside changing shape in one frame. Both meshes share a trunk and a
# height, so the change that is left is small.
#
# MID -> FAR is a real dithered cross-fade, because a billboard and a mesh differ
# enough that a hard swap would be a visible pop.
const LOD_NEAR_END := 38.0
const LOD_MID_END := 76.0
const LOD_FAR_END := 520.0
# Half-width of the MID/FAR cross-fade. Deliberately NARROW, because the width of this
# band is how many trees are stippled at once. At 7 m it was a 14 m shell of dithering
# trees and the treeline read as chicken wire; the spread now comes from LOD_JITTER
# instead, which scatters the hand-over ACROSS trees rather than across pixels.
const LOD_BAND := 3.0
const LOD_JITTER := 14.0  # per-tree spread on the hand-over distance, metres
const CLUTTER_END := 78.0  # bushes and boulders simply end; they have no billboard


# --- Species table ---------------------------------------------------------
## `alt` is the texture name for bases generated without an `_albedo` suffix.
static func profile(species: int) -> Dictionary:
	match species:
		Species.BANYAN:
			return {
				"bark": "bark_banyan",
				"bark_alt": "bark_banyan",
				"no_albedo": true,
				"leaf": "leaf_banyan",
				"cells": 2,
				"leaf_a": Vector3(1.02, 1.06, 0.76),
				"leaf_b": Vector3(0.66, 0.90, 0.56),
				"bark_a": Vector3(1.00, 0.96, 0.88),
				"bark_b": Vector3(0.82, 0.78, 0.70),
				"trans": Vector3(0.52, 0.74, 0.24),
				"trans_amt": 0.85,
				"bark_v": 2.6,
				"sway": 0.16,
			}
		Species.PALM:
			return {
				"bark": "bark_palm",
				"bark_alt": "bark_palm",
				"no_albedo": true,
				"leaf": "leaf_palm",
				"cells": 2,
				"leaf_a": Vector3(1.06, 1.04, 0.70),
				"leaf_b": Vector3(0.76, 1.00, 0.60),
				"bark_a": Vector3(1.06, 1.00, 0.86),
				"bark_b": Vector3(0.88, 0.82, 0.68),
				"trans": Vector3(0.58, 0.78, 0.28),
				"trans_amt": 1.05,
				"bark_v": 3.4,
				"sway": 0.42,
			}
		Species.MANGO:
			return {
				"bark": "bark_banyan",
				"bark_alt": "bark_banyan",
				"no_albedo": true,
				"leaf": "leaf_mango",
				"cells": 2,
				"leaf_a": Vector3(0.90, 1.00, 0.66),
				"leaf_b": Vector3(0.60, 0.84, 0.48),
				"bark_a": Vector3(0.96, 0.90, 0.80),
				"bark_b": Vector3(0.78, 0.72, 0.62),
				"trans": Vector3(0.46, 0.68, 0.20),
				"trans_amt": 0.75,
				"bark_v": 2.2,
				"sway": 0.20,
			}
		Species.SAL:
			return {
				"bark": "bark_banyan",
				"bark_alt": "bark_banyan",
				"no_albedo": true,
				"leaf": "leaf_banyan",
				"cells": 2,
				"leaf_a": Vector3(0.86, 1.02, 0.62),
				"leaf_b": Vector3(0.62, 0.86, 0.50),
				"bark_a": Vector3(0.90, 0.88, 0.84),
				"bark_b": Vector3(0.72, 0.70, 0.66),
				"trans": Vector3(0.48, 0.70, 0.22),
				"trans_amt": 0.82,
				"bark_v": 3.0,
				"sway": 0.30,
			}
		Species.DEAD:
			return {
				"bark": "bark_banyan",
				"bark_alt": "bark_banyan",
				"no_albedo": true,
				"leaf": "leaf_banyan",
				"cells": 2,
				"leaf_a": Vector3(1.0, 1.0, 1.0),
				"leaf_b": Vector3(1.0, 1.0, 1.0),
				"bark_a": Vector3(1.34, 1.26, 1.10),
				"bark_b": Vector3(1.10, 1.02, 0.88),
				"trans": Vector3(0.5, 0.5, 0.5),
				"trans_amt": 0.0,
				"bark_v": 2.4,
				"sway": 0.26,
			}
		Species.BUSH:
			return {
				"bark": "bark_banyan",
				"bark_alt": "bark_banyan",
				"no_albedo": true,
				"leaf": "leaf_banyan",
				"cells": 2,
				"leaf_a": Vector3(0.96, 1.06, 0.68),
				"leaf_b": Vector3(0.62, 0.88, 0.50),
				"bark_a": Vector3(0.90, 0.84, 0.74),
				"bark_b": Vector3(0.74, 0.70, 0.60),
				"trans": Vector3(0.54, 0.76, 0.26),
				"trans_amt": 0.95,
				"bark_v": 1.2,
				"sway": 0.55,
			}
		_:
			return {
				"bark": "rock",
				"bark_alt": "",
				"no_albedo": false,
				"leaf": "leaf_banyan",
				"cells": 2,
				"leaf_a": Vector3(1, 1, 1),
				"leaf_b": Vector3(1, 1, 1),
				"bark_a": Vector3(1.02, 1.00, 0.96),
				"bark_b": Vector3(0.86, 0.84, 0.82),
				"trans": Vector3(0.5, 0.5, 0.5),
				"trans_amt": 0.0,
				"bark_v": 1.6,
				"sway": 0.0,
			}


# --- Mesh accumulator ------------------------------------------------------
class Surf:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var t := PackedFloat32Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()

	func vert(p: Vector3, nrm: Vector3, tan: Vector3, col: Color, u: Vector2) -> int:
		var i := v.size()
		v.push_back(p)
		n.push_back(nrm.normalized())
		var tt := tan
		if tt.length_squared() < 1e-8:
			tt = Vector3.RIGHT
		tt = tt.normalized()
		t.push_back(tt.x)
		t.push_back(tt.y)
		t.push_back(tt.z)
		t.push_back(1.0)
		c.push_back(col)
		uv.push_back(u)
		return i

	func tri(a: int, b: int, cc: int) -> void:
		idx.push_back(a)
		idx.push_back(b)
		idx.push_back(cc)

	## Emit a quad whose visible side faces `want`. Handles the clockwise-front-face
	## rule once, here, instead of at every caller.
	func quad(i0: int, i1: int, i2: int, i3: int, want: Vector3) -> void:
		var cr := (v[i1] - v[i0]).cross(v[i3] - v[i0])
		if cr.dot(want) > 0.0:
			var tmp := i1
			i1 = i3
			i3 = tmp
		tri(i0, i1, i3)
		tri(i1, i2, i3)

	func empty() -> bool:
		return idx.is_empty()

	func to_arrays() -> Array:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = v
		a[Mesh.ARRAY_NORMAL] = n
		a[Mesh.ARRAY_TANGENT] = t
		a[Mesh.ARRAY_COLOR] = c
		a[Mesh.ARRAY_TEX_UV] = uv
		a[Mesh.ARRAY_INDEX] = idx
		return a


# --- Public API ------------------------------------------------------------
## The mesh for one (species, variant, LOD). Cached: a forest of 4000 trees shares
## about twenty ArrayMeshes between them.
static func mesh(species: int, variant: int, lod: int) -> ArrayMesh:
	var key := species * 100 + variant * 10 + lod
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var bark := Surf.new()
	var leaf := Surf.new()
	var rng := RandomNumberGenerator.new()
	# Seeded on the species/variant only, NOT the LOD, so a tree's LODs agree in
	# height and lean and the hand-over does not jump.
	rng.seed = 0x5241_4D41 ^ (species * 7919 + variant * 104729)

	if lod == Lod.FAR:
		_build_far(bark, leaf, rng, species, variant)
	else:
		match species:
			Species.BANYAN:
				_build_banyan(bark, leaf, rng, variant, lod)
			Species.PALM:
				_build_palm(bark, leaf, rng, variant, lod)
			Species.MANGO:
				_build_mango(bark, leaf, rng, variant, lod)
			Species.SAL:
				_build_sal(bark, leaf, rng, variant, lod)
			Species.DEAD:
				_build_dead(bark, leaf, rng, variant, lod)
			Species.BUSH:
				_build_bush(bark, leaf, rng, variant, lod)
			_:
				_build_rock(bark, rng, variant, lod)

	var m := ArrayMesh.new()
	var slot := 0
	if not bark.empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bark.to_arrays())
		m.surface_set_material(slot, bark_material(species, lod))
		slot += 1
	if not leaf.empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, leaf.to_arrays())
		m.surface_set_material(slot, leaf_material(species, lod))
		slot += 1
	_mesh_cache[key] = m
	return m


static func triangles(species: int, variant: int, lod: int) -> int:
	var m := mesh(species, variant, lod)
	var n := 0
	for i in range(m.get_surface_count()):
		n += m.surface_get_array_index_len(i) / 3
	return n


## Fade ramp for one LOD, in the vec4 layout the shaders expect.
## Ramp + dither role for one (species, LOD). `x` is the fade ramp, `y` is whether the
## dither is active at all and `z` whether this is the finer half of a pair.
static func lod_ramp(species: int, lod: int) -> Dictionary:
	var clutter := species == Species.BUSH or species == Species.ROCK
	match lod:
		Lod.FULL:
			return {"r": Vector4(-2.0, -1.0, 1.0e5, 1.1e5), "d": false, "inv": false}
		Lod.MID:
			if clutter:
				# Nothing coarser to hand over to, so this is a plain fade to nothing.
				# Narrow, for the same reason the tree band is: LOD_JITTER already
				# spreads the vanishing point over 14 m of bushes, so each one only
				# needs to stipple for the 3 m it takes to go.
				return {"r": Vector4(-2.0, -1.0, CLUTTER_END - 3.0, CLUTTER_END), "d": true, "inv": false}
			return {"r": Vector4(LOD_MID_END - LOD_BAND, LOD_MID_END + LOD_BAND, 1.0e5, 1.1e5), "d": true, "inv": true}
		_:
			return {
				"r": Vector4(LOD_MID_END - LOD_BAND, LOD_MID_END + LOD_BAND, LOD_FAR_END - 90.0, LOD_FAR_END),
				"d": true,
				"inv": false
			}


static func leaf_material(species: int, lod: int) -> ShaderMaterial:
	var key := species * 10 + lod
	if _leaf_mats.has(key):
		return _leaf_mats[key]
	var p := profile(species)
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/foliage.gdshader")
	m.set_shader_parameter("albedo_tex", Mats.tex(p.leaf))
	m.set_shader_parameter("normal_tex", Mats.tex(str(p.leaf) + "_normal"))
	m.set_shader_parameter("two_sided", true)
	m.set_shader_parameter("use_normal_map", true)
	m.set_shader_parameter("tint_a", p.leaf_a)
	m.set_shader_parameter("tint_b", p.leaf_b)
	m.set_shader_parameter("roughness_value", 0.88)
	# 0.55 with the translucency cut would have made shaded canopy darker than it was;
	# 0.44 hands the ambient back and keeps the interior readable.
	m.set_shader_parameter("ao_strength", 0.44)
	m.set_shader_parameter("normal_depth", 0.28)
	m.set_shader_parameter("translucency_color", Color(p.trans.x, p.trans.y, p.trans.z))
	m.set_shader_parameter("translucency", p.trans_amt)
	m.set_shader_parameter("bend_scale", 0.42 + float(p.sway) * 0.8)
	# Distant cards are magnified, so a fixed cutoff eats them alive; loosening it at
	# range keeps far canopies from turning to lace.
	m.set_shader_parameter("alpha_cut", [0.40, 0.34, 0.24][lod])
	m.set_shader_parameter("albedo_gain", [1.72, 1.80, 1.92][lod])
	var r := lod_ramp(species, lod)
	m.set_shader_parameter("lod_fade", r.r)
	m.set_shader_parameter("lod_jitter", LOD_JITTER)
	m.set_shader_parameter("dither_fade", r.d)
	m.set_shader_parameter("dither_invert", r.inv)
	_leaf_mats[key] = m
	_all_mats.append(m)
	return m


static func bark_material(species: int, lod: int) -> ShaderMaterial:
	var key := species * 10 + lod
	if _bark_mats.has(key):
		return _bark_mats[key]
	var p := profile(species)
	var m := ShaderMaterial.new()
	m.shader = _get_bark_shader()
	var base: String = p.bark
	# bark_banyan and bark_palm were generated without the _albedo suffix, so asking for
	# one would push a "missing texture" warning on every run. The profile says which
	# bases are like that rather than discovering it by failing.
	var a: Texture2D = Mats.tex(p.bark_alt) if bool(p.no_albedo) else Mats.tex(base + "_albedo")
	m.set_shader_parameter("alb_tex", a)
	m.set_shader_parameter("nrm_tex", Mats.tex(base + "_normal"))
	m.set_shader_parameter("rgh_tex", Mats.tex(base + "_rough"))
	m.set_shader_parameter("tint_a", p.bark_a)
	m.set_shader_parameter("tint_b", p.bark_b)
	m.set_shader_parameter("bend_scale", p.sway)
	var r := lod_ramp(species, lod)
	m.set_shader_parameter("lod_fade", r.r)
	m.set_shader_parameter("lod_jitter", LOD_JITTER)
	m.set_shader_parameter("dither_fade", r.d)
	m.set_shader_parameter("dither_invert", r.inv)
	_bark_mats[key] = m
	_all_mats.append(m)
	return m


## Where the LOD ramp is measured from. Called every frame by Vegetation.update_focus;
## about forty materials, so it does not show up in a profile.
static func set_lod_focus(p: Vector3) -> void:
	for m in _all_mats:
		m.set_shader_parameter("lod_focus", p)


## Push the current weather onto every foliage material at once. Cheap — there are
## about forty of them, not forty thousand.
static func set_wind(dir: Vector2, strength: float, speed: float = 1.0) -> void:
	var d := dir.normalized() if dir.length_squared() > 1e-6 else Vector2(0.82, 0.57)
	for m in _all_mats:
		m.set_shader_parameter("wind_dir", d)
		m.set_shader_parameter("wind_strength", strength)
		m.set_shader_parameter("wind_speed", speed)


static func _get_bark_shader() -> Shader:
	if _bark_shader != null:
		return _bark_shader
	_bark_shader = Shader.new()
	_bark_shader.code = BARK_SHADER
	return _bark_shader


# --- Trunk / branch geometry ----------------------------------------------
## A tapered tube through `pts`. Frames are propagated (each ring reuses the previous
## ring's U axis, re-orthogonalised) so a curved branch does not corkscrew its bark.
static func _tube(
	s: Surf,
	pts: PackedVector3Array,
	radii: PackedFloat32Array,
	flex: PackedFloat32Array,
	ao: PackedFloat32Array,
	sides: int,
	v_scale: float,
	flute: float,
	flute_phase: float
) -> void:
	var count := pts.size()
	if count < 2:
		return
	var rings: Array[PackedInt32Array] = []
	var u_axis := Vector3.RIGHT
	var run := 0.0
	var circ: float = maxf(radii[0], 0.02) * TAU
	var u_rep: float = maxf(1.0, roundf(circ / 2.2))

	for i in range(count):
		var fwd: Vector3
		if i == 0:
			fwd = (pts[1] - pts[0])
		elif i == count - 1:
			fwd = (pts[i] - pts[i - 1])
		else:
			fwd = (pts[i + 1] - pts[i - 1])
		if fwd.length_squared() < 1e-8:
			fwd = Vector3.UP
		fwd = fwd.normalized()
		if i > 0:
			run += pts[i].distance_to(pts[i - 1])
		# Re-orthogonalise the carried axis against the new forward direction.
		var u := u_axis - fwd * u_axis.dot(fwd)
		if u.length_squared() < 1e-6:
			u = (Vector3.RIGHT - fwd * fwd.x)
			if u.length_squared() < 1e-6:
				u = Vector3.FORWARD
		u = u.normalized()
		u_axis = u
		var w := fwd.cross(u).normalized()  # u x w = fwd is what the winding assumes
		var ring := PackedInt32Array()
		var r: float = radii[i]
		for k in range(sides + 1):
			var th := TAU * float(k) / float(sides)
			var rad := (cos(th) * u + sin(th) * w).normalized()
			var rr: float = r * (1.0 + flute * (0.30 * cos(3.0 * th + flute_phase) + 0.16 * cos(7.0 * th)))
			var p := pts[i] + rad * rr
			var tan := -sin(th) * u + cos(th) * w
			var uvv := Vector2(u_rep * float(k) / float(sides), -run / v_scale)
			var col := Color(flex[i], ao[i], 0.5, 0.0)
			ring.push_back(s.vert(p, rad, tan, col, uvv))
		rings.append(ring)

	for i in range(count - 1):
		var lo := rings[i]
		var hi := rings[i + 1]
		for k in range(sides):
			var want := (s.v[lo[k]] + s.v[lo[k + 1]] + s.v[hi[k]] + s.v[hi[k + 1]]) * 0.25 - (pts[i] + pts[i + 1]) * 0.5
			if want.length_squared() < 1e-8:
				want = Vector3.UP
			s.quad(lo[k], hi[k], hi[k + 1], lo[k + 1], want)


## One card. `nrm` is the direction the canopy shell faces here; corner normals fan
## off it so a flat quad shades like a curved piece of foliage instead of a plank.
static func _card(
	s: Surf, c: Vector3, right: Vector3, up: Vector3, uvr: Rect2, nrm: Vector3, flex: float, ao: float
) -> void:
	var rn := right.normalized()
	var un := up.normalized()
	var nn := nrm.normalized()
	var col := Color(flex, ao, 0.5, 0.0)
	var u0 := uvr.position.x
	var u1 := uvr.position.x + uvr.size.x
	var v0 := uvr.position.y
	var v1 := uvr.position.y + uvr.size.y
	var i0 := s.vert(c - right - up, nn * 1.7 - rn * 0.55 - un * 0.40, rn, col, Vector2(u0, v1))
	var i1 := s.vert(c + right - up, nn * 1.7 + rn * 0.55 - un * 0.40, rn, col, Vector2(u1, v1))
	var i2 := s.vert(c + right + up, nn * 1.7 + rn * 0.55 + un * 0.40, rn, col, Vector2(u1, v0))
	var i3 := s.vert(c - right + up, nn * 1.7 - rn * 0.55 + un * 0.40, rn, col, Vector2(u0, v0))
	s.quad(i0, i1, i2, i3, nn)


static func _cell_uv(cells: int, i: int, j: int) -> Rect2:
	var f := 1.0 / float(cells)
	var inset := f * 0.014
	return Rect2(float(i) * f + inset, float(j) * f + inset, f - inset * 2.0, f - inset * 2.0)


## A blob of leaf cards at a branch tip. `centre` is the blob, `hub` the whole tree's
## canopy centre — cards face away from the hub, which is what makes a canopy read as
## a lit volume rather than a pile of flat sprites.
static func _leaf_blob(
	s: Surf,
	rng: RandomNumberGenerator,
	centre: Vector3,
	hub: Vector3,
	count: int,
	size: float,
	radius: float,
	cells: int,
	droop: float,
	flex: float,
	_dry: float
) -> void:
	for i in range(count):
		var dir := Vector3(rng.randfn(0.0, 1.0), rng.randfn(0.0, 0.75), rng.randfn(0.0, 1.0))
		if dir.length_squared() < 1e-6:
			dir = Vector3.UP
		dir = dir.normalized()
		var p := centre + dir * radius * pow(rng.randf(), 0.55)
		var out := p - hub
		if out.length_squared() < 1e-6:
			out = Vector3.UP
		out = out.normalized()
		# Canopy shell normal: mostly outward, biased up so the top of a tree catches
		# the sun and the underside stays in shade.
		var shell := (out * 1.0 + Vector3.UP * 0.55).normalized()
		var yaw := rng.randf() * TAU
		var right := Vector3(cos(yaw), 0.0, sin(yaw))
		var tilt := rng.randf_range(-0.55, 0.25) - droop
		var up := Vector3.UP * cos(tilt) + right.cross(Vector3.UP).normalized() * sin(tilt)
		if up.length_squared() < 1e-6:
			up = Vector3.UP
		var sz: float = size * rng.randf_range(0.78, 1.28)
		var uvr := _cell_uv(cells, rng.randi() % cells, rng.randi() % cells)
		# Cards nearer the hub are buried in the canopy: bake them darker.
		var depth: float = clampf((p - hub).length() / maxf(radius * 2.4, 0.6), 0.0, 1.0)
		var ao: float = clampf(0.30 + 0.70 * depth, 0.0, 1.0)
		_card(
			s,
			p,
			right * sz,
			up.normalized() * sz * 0.86,
			uvr,
			shell,
			clampf(flex + rng.randf_range(-0.06, 0.10), 0.0, 1.0),
			ao
		)


# --- Recursive limb --------------------------------------------------------
static func _limb(
	bark: Surf,
	rng: RandomNumberGenerator,
	p: Dictionary,
	start: Vector3,
	dir: Vector3,
	length: float,
	radius: float,
	depth: int,
	tips: Array
) -> void:
	var segs: int = maxi(2, int(p.segs) - depth)
	var sides: int = maxi(3, int(p.sides) - depth * 2)
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var flex := PackedFloat32Array()
	var ao := PackedFloat32Array()
	var cur := start
	var d: Vector3 = dir.normalized()
	var f0: float = float(p.flex0) + float(depth) * float(p.flex_step)
	var f1: float = f0 + float(p.flex_span)

	for i in range(segs + 1):
		var t := float(i) / float(segs)
		pts.push_back(cur)
		radii.push_back(maxf(0.012, lerpf(radius, radius * float(p.tip), t)))
		flex.push_back(clampf(lerpf(f0, f1, t), 0.0, 1.0))
		ao.push_back(clampf(lerpf(float(p.ao0), 1.0, t), 0.0, 1.0))
		if i < segs:
			var step := length / float(segs)
			d = (
				(d + Vector3(rng.randf_range(-1.0, 1.0), float(p.grav), rng.randf_range(-1.0, 1.0)) * float(p.wobble))
				. normalized()
			)
			cur += d * step

	_tube(bark, pts, radii, flex, ao, sides, float(p.bark_v), float(p.flute) * 0.5, rng.randf() * TAU)

	if depth < int(p.max_depth):
		var n: int = int(p.children) - (1 if depth > 0 else 0)
		for k in range(maxi(1, n)):
			var frac := rng.randf_range(0.5, 0.98)
			var ix := clampi(int(frac * float(segs)), 1, segs)
			var origin := pts[ix]
			var ang := rng.randf() * TAU
			var out := Vector3(cos(ang), 0.0, sin(ang))
			var cd := (
				(pts[ix] - pts[ix - 1]).normalized() * float(p.align)
				+ out * (1.0 - float(p.align))
				+ Vector3.UP * float(p.child_up)
			)
			if cd.length_squared() < 1e-6:
				cd = Vector3.UP
			_limb(
				bark,
				rng,
				p,
				origin,
				cd.normalized(),
				length * float(p.child_len) * rng.randf_range(0.82, 1.14),
				radii[ix] * float(p.child_rad),
				depth + 1,
				tips
			)
	else:
		tips.push_back(pts[segs])
		if segs >= 3:
			tips.push_back(pts[segs - 1].lerp(pts[segs], 0.5))


# --- Species ---------------------------------------------------------------
static func _lodf(lod: int, full: float, mid: float) -> float:
	return full if lod == Lod.FULL else mid


## Fill an ellipsoid shell with leaf cards. This, not the branch tips, is what gives a
## tree its silhouette: branching alone leaves a canopy that reads as a handful of
## clumps floating around a stick. Cards sit on a shell of thickness `thick`, so the
## outside is dense and the middle stays hollow — which is both cheaper and how a real
## crown is built.
static func _canopy_shell(
	s: Surf,
	rng: RandomNumberGenerator,
	hub: Vector3,
	rx: float,
	ry: float,
	count: int,
	size: float,
	cells: int,
	thick: float,
	y_lift: float,
	flex: float,
	droop: float
) -> void:
	for i in range(count):
		var d := Vector3(rng.randfn(0.0, 1.0), rng.randfn(0.0, 1.0) * 0.8 + y_lift, rng.randfn(0.0, 1.0))
		if d.length_squared() < 1e-6:
			d = Vector3.UP
		d = d.normalized()
		var rr: float = 1.0 - thick * pow(rng.randf(), 0.65)
		var p := hub + Vector3(d.x * rx, d.y * ry, d.z * rx) * rr
		# True outward normal of the ellipsoid, not of the sphere it came from.
		var shell := Vector3(d.x / maxf(rx, 0.01), d.y / maxf(ry, 0.01), d.z / maxf(rx, 0.01))
		if shell.length_squared() < 1e-8:
			shell = Vector3.UP
		shell = (shell.normalized() + Vector3.UP * 0.35).normalized()
		var yaw := rng.randf() * TAU
		var right := Vector3(cos(yaw), 0.0, sin(yaw))
		var tilt: float = rng.randf_range(-0.42, 0.16) - droop
		var up := Vector3.UP * cos(tilt) + right.cross(Vector3.UP).normalized() * sin(tilt)
		if up.length_squared() < 1e-6:
			up = Vector3.UP
		var sz: float = size * rng.randf_range(0.75, 1.30)
		var uvr := _cell_uv(cells, rng.randi() % cells, rng.randi() % cells)
		# Depth into the shell drives baked AO: the buried cards go dark, which is what
		# makes a canopy look like a volume instead of a painted ball.
		var ao: float = clampf(0.26 + 0.74 * (1.0 - (1.0 - rr) / maxf(thick, 0.01)) + d.y * 0.15, 0.0, 1.0)
		_card(
			s,
			p,
			right * sz,
			up.normalized() * sz * 0.86,
			uvr,
			shell,
			clampf(flex + rng.randf_range(-0.08, 0.08), 0.0, 1.0),
			ao
		)


static func _build_banyan(bark: Surf, leaf: Surf, rng: RandomNumberGenerator, variant: int, lod: int) -> void:
	var full := lod == Lod.FULL
	var trunk_h := 5.2 + float(variant) * 0.5 + rng.randf_range(-0.3, 0.7)
	var base_r := 1.15 + float(variant) * 0.07 + rng.randf_range(-0.08, 0.16)
	var canopy_r := 9.2 + float(variant) * 0.8

	# --- fluted, buttressed bole
	var rings: int = 9 if full else 5
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var flex := PackedFloat32Array()
	var ao := PackedFloat32Array()
	for i in range(rings):
		var t := float(i) / float(rings - 1)
		var y := lerpf(-0.6, trunk_h, t)
		pts.push_back(Vector3(sin(t * 2.6) * 0.20, y, cos(t * 2.0) * 0.17))
		# A hard flare in the bottom fifth is the buttress; above it a slow taper. The
		# flare is what sells the age of the tree from ground level.
		var r: float = base_r * (1.0 + 1.05 * pow(maxf(0.0, 1.0 - t * 4.2), 2.0)) * lerpf(1.0, 0.60, t)
		radii.push_back(r)
		flex.push_back(t * t * 0.05)
		ao.push_back(lerpf(0.52, 0.98, t))
	_tube(bark, pts, radii, flex, ao, 9 if full else 6, 2.6, 1.0, rng.randf() * TAU)

	var hub := Vector3(0.0, trunk_h + 1.9, 0.0)
	var tips: Array = []
	var root_anchors: Array = []

	# --- horizontal limbs. A banyan reaches OUT, not up: these run nearly level and it
	#     is the space underneath them that the aerial roots then fill.
	var n_limbs: int = 6 if full else 3
	for i in range(n_limbs):
		var ang := TAU * (float(i) + rng.randf_range(-0.18, 0.18)) / float(n_limbs)
		var dir := Vector3(cos(ang), rng.randf_range(0.30, 0.50), sin(ang)).normalized()
		var start := Vector3(0, trunk_h * rng.randf_range(0.70, 0.95), 0)
		var seg_len := canopy_r * rng.randf_range(0.66, 0.86)
		var lpts := PackedVector3Array()
		var lrad := PackedFloat32Array()
		var lflex := PackedFloat32Array()
		var lao := PackedFloat32Array()
		var segs: int = 6 if full else 3
		var cur := start
		var d := dir
		for k in range(segs + 1):
			var t := float(k) / float(segs)
			lpts.push_back(cur)
			lrad.push_back(lerpf(base_r * 0.44, base_r * 0.12, t))
			lflex.push_back(0.05 + t * 0.25)
			lao.push_back(lerpf(0.50, 0.92, t))
			if k < segs:
				# Flatten toward level rather than diving: clamping the vertical
				# component is what stopped the limbs from burying themselves in the
				# ground, which is what the first render of this tree actually did.
				d.y = lerpf(d.y, rng.randf_range(-0.02, 0.06), 0.55)
				d.x += rng.randf_range(-0.14, 0.14)
				d.z += rng.randf_range(-0.14, 0.14)
				d = d.normalized()
				cur += d * (seg_len / float(segs))
			if full and k >= 2 and k <= segs - 1:
				root_anchors.push_back(cur)
		_tube(bark, lpts, lrad, lflex, lao, 6 if full else 4, 2.4, 0.35, rng.randf() * TAU)
		tips.push_back(lpts[segs])
		tips.push_back(lpts[maxi(0, segs - 2)])
		if full:
			tips.push_back(lpts[maxi(0, segs - 4)])

	# --- upward crown branches, kept short so no bare twig pokes out of the dome
	var lp := {
		"segs": 4 if full else 2,
		"sides": 5 if full else 4,
		"tip": 0.30,
		"grav": -0.05,
		"wobble": 0.26,
		"flex0": 0.10,
		"flex_step": 0.22,
		"flex_span": 0.24,
		"ao0": 0.55,
		"bark_v": 2.4,
		"flute": 0.35,
		"max_depth": 1 if full else 0,
		"children": 2,
		"align": 0.60,
		"child_up": 0.35,
		"child_len": 0.58,
		"child_rad": 0.58,
	}
	var n_up: int = 5 if full else 2
	for i in range(n_up):
		var ang2 := TAU * float(i) / float(n_up) + rng.randf_range(-0.4, 0.4)
		var dir2 := Vector3(cos(ang2) * 0.7, 1.0, sin(ang2) * 0.7).normalized()
		_limb(bark, rng, lp, Vector3(0, trunk_h * 0.9, 0), dir2, canopy_r * 0.40, base_r * 0.40, 0, tips)

	# --- AERIAL ROOT PILLARS. Without these it is not a banyan, it is a fat mango.
	if full:
		for i in range(root_anchors.size() - 1, 0, -1):
			var j := rng.randi() % (i + 1)
			var tmp: Vector3 = root_anchors[i]
			root_anchors[i] = root_anchors[j]
			root_anchors[j] = tmp
		var placed := 0
		var want: int = 9 + variant
		for a in root_anchors:
			if placed >= want:
				break
			var av: Vector3 = a
			if Vector2(av.x, av.z).length() < 2.6 or av.y < 1.2:
				continue
			placed += 1
			var rpts := PackedVector3Array()
			var rrad := PackedFloat32Array()
			var rflex := PackedFloat32Array()
			var rao := PackedFloat32Array()
			var steps := 4
			var drift := Vector3(rng.randf_range(-0.35, 0.35), 0.0, rng.randf_range(-0.35, 0.35))
			var thin: float = rng.randf_range(0.13, 0.24)
			for k in range(steps + 1):
				var t := float(k) / float(steps)
				var y := lerpf(av.y, -0.4, t)
				rpts.push_back(Vector3(av.x, y, av.z) + drift * sin(t * 2.4))
				# Fat where it has reached the ground and fused into a second trunk.
				rrad.push_back(thin * lerpf(1.0, 2.8, pow(t, 2.2)))
				rflex.push_back((1.0 - t) * 0.14)
				rao.push_back(lerpf(0.85, 0.40, t))
			_tube(bark, rpts, rrad, rflex, rao, 5, 2.0, 0.55, rng.randf() * TAU)

	# --- the broad low dome
	# The hero specimen in the village square is scaled up ~1.6x, which spreads the same
	# card count over four times the volume. 520 cards was still see-through: photographed
	# from underneath against a bright sky the crown broke into separate floating flakes
	# with sky between them. A banyan is only ever a handful of instances (14 on the whole
	# map, rarely two on screen), so the shell is deliberately the densest in the project
	# and the extra ~1.1k triangles per instance are the cheapest fix available.
	var size: float = _lodf(lod, 0.54, 1.02)
	_canopy_shell(
		leaf, rng, hub, canopy_r * 0.98, canopy_r * 0.44, 760 if full else 96, size, 2, 0.62, 0.15, 0.85, 0.12
	)
	# A second, tighter shell right above the trunk fills the crown of the dome.
	_canopy_shell(
		leaf,
		rng,
		hub + Vector3(0, canopy_r * 0.16, 0),
		canopy_r * 0.48,
		canopy_r * 0.24,
		110 if full else 26,
		size,
		2,
		0.62,
		0.4,
		0.85,
		0.15
	)
	# Foliage hanging off the ends of the level limbs, drooping: this is what fills the
	# skirt of the dome and hides the last stretch of bare branch.
	var per: int = 5 if full else 3
	for i in range(mini(tips.size(), 22 if full else 8)):
		var tp: Vector3 = tips[i]
		_leaf_blob(leaf, rng, tp + Vector3(0, -0.5, 0), hub, per, size * 1.1, 1.7, 2, 0.55, 0.92, 0.10)


static func _build_palm(bark: Surf, leaf: Surf, rng: RandomNumberGenerator, variant: int, lod: int) -> void:
	var full := lod == Lod.FULL
	var h := 9.5 + float(variant) * 2.4 + rng.randf_range(-1.2, 2.4)
	var lean_dir := rng.randf() * TAU
	var lean := Vector3(cos(lean_dir), 0.0, sin(lean_dir)) * rng.randf_range(0.9, 2.4)

	var rings: int = 13 if full else 6
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var flex := PackedFloat32Array()
	var ao := PackedFloat32Array()
	for i in range(rings):
		var t := float(i) / float(rings - 1)
		# A palm leans on a curve, not a straight tilt: most of the bend is up top.
		pts.push_back(Vector3(0, lerpf(-0.4, h, t), 0) + lean * (t * t))
		radii.push_back(lerpf(0.40, 0.17, pow(t, 0.6)) * (1.0 + 0.6 * pow(maxf(0.0, 1.0 - t * 6.0), 2.0)))
		flex.push_back(t * t * 0.24)
		ao.push_back(lerpf(0.5, 1.0, t))
	_tube(bark, pts, radii, flex, ao, 7 if full else 5, 1.5, 0.10, rng.randf() * TAU)

	var crown: Vector3 = pts[rings - 1]
	var n_fronds: int = (11 + variant) if full else 7
	var seg: int = 8 if full else 4
	var flen: float = 4.0 + float(variant) * 0.35
	# The atlas cell holds one frond running corner to corner, so the strip's UVs run
	# along that diagonal rather than axis-aligned. Mapping it square would slice the
	# frond in half and leave the other half of the cell empty.
	for f in range(n_fronds):
		var ang := TAU * (float(f) + rng.randf_range(-0.22, 0.22)) / float(n_fronds)
		var out := Vector3(cos(ang), 0.0, sin(ang))
		var cell_i := rng.randi() % 2
		var cell_j := rng.randi() % 2
		var ca := Vector2(0.06, 0.93) * 0.5 + Vector2(float(cell_i), float(cell_j)) * 0.5
		var cb := Vector2(0.88, 0.08) * 0.5 + Vector2(float(cell_i), float(cell_j)) * 0.5
		var perp := (cb - ca).orthogonal().normalized()
		var half_uv := 0.118
		var rise: float = rng.randf_range(1.1, 2.0)
		var droop: float = rng.randf_range(3.0, 4.6)
		var flw: float = flen * rng.randf_range(0.82, 1.18)
		var twist: float = rng.randf_range(-0.25, 0.25)
		var prev_p := crown
		var prev_l := 0
		var prev_r := 0
		for k in range(seg + 1):
			var t := float(k) / float(seg)
			# Rises off the crown then falls away: the classic frond arc.
			var y := rise * t - droop * t * t
			var p := crown + out.rotated(Vector3.UP, twist * t) * (flw * t) + Vector3(0, y, 0)
			var fwd := (p - prev_p) if k > 0 else (out + Vector3.UP * rise).normalized()
			if fwd.length_squared() < 1e-8:
				fwd = out
			fwd = fwd.normalized()
			var side := fwd.cross(Vector3.UP)
			if side.length_squared() < 1e-6:
				side = out.cross(Vector3.UP)
			side = side.normalized()
			var w: float = 0.70 * sin(clampf(t, 0.0, 1.0) * PI * 0.94 + 0.14) * flw / 4.0
			w = maxf(w, 0.05)
			var nrm := side.cross(fwd).normalized()
			if nrm.dot(Vector3.UP) < 0.0:
				nrm = -nrm
			# Lift the shading normal toward vertical so a crown of near-horizontal
			# fronds still catches the sun instead of going flat grey.
			var shade := (nrm + Vector3.UP * 0.5).normalized()
			var uvc := ca.lerp(cb, t)
			var hw := half_uv * clampf(sin(t * PI * 0.94 + 0.14), 0.12, 1.0)
			var fx: float = 0.15 + 0.85 * t
			var col := Color(fx, clampf(0.55 + 0.45 * t, 0.0, 1.0), 0.5, 0.0)
			var il := leaf.vert(p - side * w, shade, side, col, uvc - perp * hw)
			var ir := leaf.vert(p + side * w, shade, side, col, uvc + perp * hw)
			if k > 0:
				leaf.quad(prev_l, prev_r, ir, il, nrm)
			prev_l = il
			prev_r = ir
			prev_p = p
	# Coconut cluster under the crown.
	if full:
		for i in range(5):
			var a2 := rng.randf() * TAU
			var pnut := crown + Vector3(cos(a2), 0.0, sin(a2)) * 0.40 + Vector3(0, -0.45, 0)
			var npts := PackedVector3Array([pnut, pnut + Vector3(0, -0.26, 0)])
			var nrad := PackedFloat32Array([0.15, 0.09])
			_tube(bark, npts, nrad, PackedFloat32Array([0.3, 0.4]), PackedFloat32Array([0.8, 0.8]), 4, 0.6, 0.0, 0.0)


static func _build_mango(bark: Surf, leaf: Surf, rng: RandomNumberGenerator, variant: int, lod: int) -> void:
	var full := lod == Lod.FULL
	var trunk_h := 2.9 + float(variant) * 0.35 + rng.randf_range(-0.3, 0.6)
	var base_r := 0.44 + float(variant) * 0.04 + rng.randf_range(-0.05, 0.1)
	var rings: int = 6 if full else 4
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var flex := PackedFloat32Array()
	var ao := PackedFloat32Array()
	for i in range(rings):
		var t := float(i) / float(rings - 1)
		pts.push_back(Vector3(sin(t * 2.4) * 0.17, lerpf(-0.5, trunk_h, t), cos(t * 1.8) * 0.14))
		radii.push_back(base_r * (1.0 + 0.6 * pow(maxf(0.0, 1.0 - t * 4.0), 2.0)) * lerpf(1.0, 0.70, t))
		flex.push_back(t * t * 0.07)
		ao.push_back(lerpf(0.54, 0.95, t))
	_tube(bark, pts, radii, flex, ao, 7 if full else 5, 2.2, 0.55, rng.randf() * TAU)

	var canopy_r := 4.4 + float(variant) * 0.5
	var hub := Vector3(0.0, trunk_h + canopy_r * 0.68, 0.0)
	var lp := {
		"segs": 4 if full else 2,
		"sides": 5 if full else 4,
		"tip": 0.30,
		"grav": 0.10,
		"wobble": 0.32,
		"flex0": 0.12,
		"flex_step": 0.24,
		"flex_span": 0.26,
		"ao0": 0.5,
		"bark_v": 2.0,
		"flute": 0.2,
		"max_depth": 1 if full else 0,
		"children": 2,
		"align": 0.55,
		"child_up": 0.45,
		"child_len": 0.56,
		"child_rad": 0.56,
	}
	var tips: Array = []
	var n: int = 5 if full else 3
	for i in range(n):
		var ang := TAU * (float(i) + rng.randf_range(-0.2, 0.2)) / float(n)
		var dir := Vector3(cos(ang) * 0.85, 1.0, sin(ang) * 0.85).normalized()
		_limb(
			bark,
			rng,
			lp,
			Vector3(0, trunk_h * rng.randf_range(0.78, 1.0), 0),
			dir,
			canopy_r * 0.85,
			base_r * 0.50,
			0,
			tips
		)

	# Dense, rounded, dark: a mango canopy is very nearly opaque.
	var size: float = _lodf(lod, 0.50, 0.86)
	_canopy_shell(leaf, rng, hub, canopy_r, canopy_r * 0.88, 170 if full else 58, size, 2, 0.55, 0.10, 0.90, 0.10)
	var per: int = 4 if full else 2
	for i in range(mini(tips.size(), 12 if full else 4)):
		_leaf_blob(leaf, rng, tips[i], hub, per, size * 1.1, 0.8, 2, 0.15, 0.95, 0.05)


static func _build_sal(bark: Surf, leaf: Surf, rng: RandomNumberGenerator, variant: int, lod: int) -> void:
	var full := lod == Lod.FULL
	var h := 15.0 + float(variant) * 2.6 + rng.randf_range(-1.5, 3.0)
	var base_r := 0.46 + float(variant) * 0.05
	var rings: int = 7 if full else 4
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var flex := PackedFloat32Array()
	var ao := PackedFloat32Array()
	var drift := Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6))
	for i in range(rings):
		var t := float(i) / float(rings - 1)
		pts.push_back(Vector3(0, lerpf(-0.5, h, t), 0) + drift * t * t)
		radii.push_back(base_r * (1.0 + 0.7 * pow(maxf(0.0, 1.0 - t * 5.0), 2.0)) * lerpf(1.0, 0.26, pow(t, 0.85)))
		flex.push_back(t * t * t * 0.22)
		ao.push_back(lerpf(0.50, 1.0, t))
	_tube(bark, pts, radii, flex, ao, 7 if full else 5, 3.0, 0.35, rng.randf() * TAU)

	var canopy_r := 4.7 + float(variant) * 0.45
	var hub := Vector3(drift.x, h * 0.86, drift.z)
	var lp := {
		"segs": 3 if full else 2,
		"sides": 5 if full else 4,
		"tip": 0.28,
		"grav": 0.18,
		"wobble": 0.28,
		"flex0": 0.30,
		"flex_step": 0.22,
		"flex_span": 0.24,
		"ao0": 0.6,
		"bark_v": 2.4,
		"flute": 0.2,
		"max_depth": 1 if full else 0,
		"children": 2,
		"align": 0.5,
		"child_up": 0.5,
		"child_len": 0.58,
		"child_rad": 0.58,
	}
	var tips: Array = []
	var n: int = 6 if full else 3
	for i in range(n):
		var ang := TAU * float(i) / float(n) + rng.randf_range(-0.3, 0.3)
		var y := h * rng.randf_range(0.62, 0.90)
		var dir := Vector3(cos(ang), rng.randf_range(0.55, 1.0), sin(ang)).normalized()
		_limb(bark, rng, lp, Vector3(drift.x * 0.8, y, drift.z * 0.8), dir, canopy_r * 0.80, base_r * 0.32, 0, tips)

	# A sal crown is layered rather than a single ball: two overlapping shells at
	# different heights give the forest canopy some depth when seen from a ridge.
	var size: float = _lodf(lod, 0.55, 0.88)
	_canopy_shell(leaf, rng, hub, canopy_r, canopy_r * 0.62, 140 if full else 46, size, 2, 0.55, 0.15, 0.92, 0.15)
	_canopy_shell(
		leaf,
		rng,
		hub - Vector3(0, canopy_r * 0.55, 0),
		canopy_r * 0.72,
		canopy_r * 0.34,
		50 if full else 14,
		size,
		2,
		0.6,
		0.0,
		0.92,
		0.25
	)
	var per: int = 3 if full else 2
	for i in range(mini(tips.size(), 10 if full else 4)):
		_leaf_blob(leaf, rng, tips[i], hub, per, size, 0.8, 2, 0.2, 0.95, 0.08)


static func _build_dead(bark: Surf, _leaf: Surf, rng: RandomNumberGenerator, variant: int, lod: int) -> void:
	var full := lod == Lod.FULL
	var h := 5.6 + float(variant) * 1.5 + rng.randf_range(-0.8, 1.6)
	var base_r := 0.42 + float(variant) * 0.05
	var rings: int = 7 if full else 4
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var flex := PackedFloat32Array()
	var ao := PackedFloat32Array()
	# A dead trunk twists: a spiral drift plus a broken, uneven taper.
	for i in range(rings):
		var t := float(i) / float(rings - 1)
		var tw := t * 4.0 + float(variant)
		pts.push_back(Vector3(sin(tw) * 0.45 * t, lerpf(-0.5, h, t), cos(tw * 0.8) * 0.40 * t))
		radii.push_back(base_r * (1.0 + 0.75 * pow(maxf(0.0, 1.0 - t * 4.5), 2.0)) * lerpf(1.0, 0.20, pow(t, 0.8)))
		flex.push_back(t * t * 0.10)
		ao.push_back(lerpf(0.5, 1.0, t))
	_tube(bark, pts, radii, flex, ao, 6 if full else 4, 2.4, 0.8, rng.randf() * TAU)

	var lp := {
		"segs": 4 if full else 2,
		"sides": 4,
		"tip": 0.14,
		"grav": 0.05,
		"wobble": 0.6,
		"flex0": 0.12,
		"flex_step": 0.2,
		"flex_span": 0.2,
		"ao0": 0.6,
		"bark_v": 2.2,
		"flute": 0.4,
		"max_depth": 1 if full else 0,
		"children": 2,
		"align": 0.45,
		"child_up": 0.30,
		"child_len": 0.55,
		"child_rad": 0.5,
	}
	var tips: Array = []
	var n: int = 6 if full else 3
	for i in range(n):
		var ang := TAU * float(i) / float(n) + rng.randf_range(-0.5, 0.5)
		var y := h * rng.randf_range(0.40, 0.95)
		var dir := Vector3(cos(ang), rng.randf_range(0.25, 0.95), sin(ang)).normalized()
		_limb(
			bark,
			rng,
			lp,
			Vector3(sin(y * 0.7) * 0.3, y, cos(y * 0.6) * 0.3),
			dir,
			h * rng.randf_range(0.24, 0.44),
			base_r * 0.42,
			0,
			tips
		)


static func _build_bush(bark: Surf, leaf: Surf, rng: RandomNumberGenerator, variant: int, lod: int) -> void:
	var full := lod == Lod.FULL
	var fern := variant == 2
	var h := (0.80 if fern else 1.15) + rng.randf_range(-0.15, 0.5)
	var spread := (1.15 if fern else 0.90) + float(variant) * 0.12
	var hub := Vector3(0, h * 0.55, 0)

	var n_stems: int = 3 if full else 1
	for i in range(n_stems):
		var ang := TAU * float(i) / float(n_stems) + rng.randf_range(-0.4, 0.4)
		var top := Vector3(cos(ang) * spread * 0.35, h * 0.9, sin(ang) * spread * 0.35)
		var sp := PackedVector3Array([Vector3(0, -0.25, 0), top * 0.5, top])
		var sr := PackedFloat32Array([0.075, 0.05, 0.028])
		_tube(
			bark,
			sp,
			sr,
			PackedFloat32Array([0.0, 0.2, 0.45]),
			PackedFloat32Array([0.5, 0.7, 0.9]),
			4,
			1.0,
			0.2,
			rng.randf() * TAU
		)

	var cards: int = (30 if fern else 34) if full else 15
	var size: float = _lodf(lod, 0.25, 0.50)
	for i in range(cards):
		var ang2 := rng.randf() * TAU
		var rr: float = spread * pow(rng.randf(), 0.45)
		var yy: float = rng.randf_range(0.10, 1.0) * h
		var p := Vector3(cos(ang2) * rr, yy, sin(ang2) * rr)
		var out := p - hub
		if out.length_squared() < 1e-6:
			out = Vector3.UP
		var shell := (out.normalized() + Vector3.UP * 0.7).normalized()
		var right := Vector3(cos(ang2 + 1.57), 0.0, sin(ang2 + 1.57))
		# A fern's fronds lie almost flat; a shrub's leaves stand up.
		var tilt: float = rng.randf_range(-1.35, -0.75) if fern else rng.randf_range(-0.5, 0.3)
		var up := (Vector3.UP * cos(tilt) + right.cross(Vector3.UP).normalized() * sin(tilt)).normalized()
		var uvr := _cell_uv(2, rng.randi() % 2, rng.randi() % 2)
		var sz: float = size * rng.randf_range(0.8, 1.35)
		_card(
			leaf,
			p,
			right * sz,
			up * sz * 0.85,
			uvr,
			shell,
			clampf(0.45 + yy / h * 0.5, 0.0, 1.0),
			clampf(0.35 + yy / h * 0.65, 0.0, 1.0)
		)


static func _build_rock(bark: Surf, rng: RandomNumberGenerator, variant: int, lod: int) -> void:
	var full := lod == Lod.FULL
	var rows: int = 6 if full else 4
	var cols: int = 8 if full else 5
	var rx := 0.9 + float(variant) * 0.25
	var ry := 0.55 + float(variant) * 0.16
	var rz := 0.8 + float(variant) * 0.22
	# A lat/long sphere squashed and bitten into by three sine lobes: cheap, and it
	# still reads as a weathered boulder once the rock normal map lands on it.
	var lobes := Vector3(rng.randf_range(2.0, 4.0), rng.randf_range(2.0, 5.0), rng.randf_range(3.0, 6.0))
	var grid: Array[PackedInt32Array] = []
	for j in range(rows + 1):
		var v := float(j) / float(rows)
		var phi := v * PI
		var row := PackedInt32Array()
		for i in range(cols + 1):
			var u := float(i) / float(cols)
			var th := u * TAU
			var dir := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			var d := (
				1.0
				+ 0.16 * sin(dir.x * lobes.x + 1.3)
				+ 0.13 * sin(dir.y * lobes.y + 2.1)
				+ 0.11 * sin(dir.z * lobes.z + 0.7)
			)
			var p := Vector3(dir.x * rx, dir.y * ry, dir.z * rz) * d
			p.y = maxf(p.y, -ry * 0.62)
			var tan := Vector3(-sin(th), 0.0, cos(th))
			row.push_back(
				bark.vert(
					p, dir, tan, Color(0.0, clampf(0.45 + dir.y * 0.5, 0.0, 1.0), 0.5, 0.0), Vector2(u * 1.6, v * 1.1)
				)
			)
		grid.append(row)
	for j in range(rows):
		for i in range(cols):
			var a := grid[j][i]
			var b := grid[j][i + 1]
			var c := grid[j + 1][i + 1]
			var d2 := grid[j + 1][i]
			var want := (bark.v[a] + bark.v[b] + bark.v[c] + bark.v[d2]) * 0.25
			if want.length_squared() < 1e-8:
				want = Vector3.UP
			bark.quad(a, b, c, d2, want)


## Billboard LOD: crossed quads. Not a baked impostor, but past LOD_MID_END the eye is
## only reading silhouette and colour anyway.
##
## Each canopy quad samples ONE atlas cell, not the whole atlas. Using the full 0..1
## range put all four clusters on one card with dark gaps between them, and a distant
## tree read as a little checkerboard of four green squares instead of a canopy.
static func _build_far(bark: Surf, leaf: Surf, rng: RandomNumberGenerator, species: int, variant: int) -> void:
	var cr: float  # canopy half-width
	var ch: float  # canopy half-height
	var cy: float  # canopy centre height
	var trunk_top: float
	var trunk_w: float
	match species:
		Species.BANYAN:
			cr = 9.4 + float(variant) * 0.8
			ch = 3.4
			cy = 7.4
			trunk_top = 6.4
			trunk_w = 2.0
		Species.PALM:
			cr = 3.9
			ch = 1.5
			cy = 10.6 + float(variant) * 2.4
			trunk_top = cy
			trunk_w = 0.6
		Species.MANGO:
			cr = 4.9 + float(variant) * 0.55
			ch = 4.0 + float(variant) * 0.45
			cy = 6.1
			trunk_top = 3.4
			trunk_w = 1.0
		Species.SAL:
			cr = 4.8 + float(variant) * 0.45
			ch = 3.9 + float(variant) * 0.4
			cy = (15.0 + float(variant) * 2.6) * 0.86
			trunk_top = cy - 1.0
			trunk_w = 0.85
		Species.DEAD:
			cr = 0.0
			ch = 0.0
			cy = 0.0
			trunk_top = 5.6 + float(variant) * 1.5
			trunk_w = 1.1
		Species.BUSH:
			cr = 1.05
			ch = 0.7
			cy = 0.62
			trunk_top = 0.0
			trunk_w = 0.0
		_:
			_build_rock(bark, rng, variant, Lod.MID)
			return

	if trunk_w > 0.0:
		for k in range(2):
			var a := PI * 0.5 * float(k) + 0.4
			var right := Vector3(cos(a), 0.0, sin(a)) * trunk_w * 0.5
			var nrm := Vector3(-sin(a), 0.0, cos(a))
			var lo := Color(0.05, 0.85, 0.5, 0.0)
			var hi := Color(0.18, 0.95, 0.5, 0.0)
			var rn := right.normalized()
			var i0 := bark.vert(-right, nrm, rn, lo, Vector2(0, 1))
			var i1 := bark.vert(right, nrm, rn, lo, Vector2(1, 1))
			var i2 := bark.vert(right + Vector3(0, trunk_top, 0), nrm, rn, hi, Vector2(1, 0))
			var i3 := bark.vert(-right + Vector3(0, trunk_top, 0), nrm, rn, hi, Vector2(0, 0))
			bark.quad(i0, i1, i2, i3, nrm)

	if cr > 0.0:
		# Three planes at 60 degrees, not two at 90: a two-quad cross has an angle where
		# it visibly thins to a line, and a whole hillside of trees does it at once.
		for k in range(3):
			var a2 := PI * float(k) / 3.0 + 0.35
			var right2 := Vector3(cos(a2), 0.0, sin(a2)) * cr
			var nrm2 := Vector3(-sin(a2), 0.0, cos(a2))
			var uvr := _cell_uv(2, k % 2, (k / 2) % 2)
			_card(leaf, Vector3(0, cy, 0), right2, Vector3(0, ch, 0), uvr, nrm2, 0.55, 0.92)


const BARK_SHADER := """
shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// Trunks, branches, aerial roots and boulders. Shares the wind model and the LOD
// dither with foliage.gdshader so bark and leaves bend as one object; if these two
// drifted apart a canopy would visibly detach from its trunk in a gust.

uniform sampler2D alb_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nrm_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rgh_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec3 tint_a = vec3(1.0, 0.97, 0.9);
uniform vec3 tint_b = vec3(0.82, 0.78, 0.7);
uniform float albedo_gain : hint_range(0.2, 3.0) = 1.05;
uniform float normal_depth : hint_range(0.0, 3.0) = 1.15;
uniform float ao_strength : hint_range(0.0, 1.0) = 0.62;

uniform vec2 wind_dir = vec2(0.82, 0.57);
uniform float wind_strength : hint_range(0.0, 3.0) = 0.5;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.0;
uniform float bend_scale = 0.2;

uniform vec4 lod_fade = vec4(-2.0, -1.0, 4000.0, 4200.0);
uniform float lod_jitter = 0.0;
// See foliage.gdshader: measured from the streaming focus, not the camera, so the
// shadow pass and the camera pass agree about which LOD owns a tree.
uniform vec3 lod_focus = vec3(1.0e9);
uniform bool dither_fade = false;
uniform bool dither_invert = false;

varying vec3 v_var;
varying float v_fade;
varying float v_ao;

void vertex() {
	vec3 iorg = MODEL_MATRIX[3].xyz;
	v_var = vec3(INSTANCE_CUSTOM.x, INSTANCE_CUSTOM.y, INSTANCE_CUSTOM.w);
	v_ao = COLOR.g;

	float phase = INSTANCE_CUSTOM.z * 6.2831853 + iorg.x * 0.071 + iorg.z * 0.113;
	float t = TIME * wind_speed;
	float gust = 0.55 + 0.45 * sin(t * 0.21 + iorg.x * 0.013 + iorg.z * 0.017)
		* cos(t * 0.097 + iorg.z * 0.0071);
	float amp = wind_strength * gust;

	vec3 wd = normalize(vec3(wind_dir.x, 0.0, wind_dir.y) + vec3(1e-5, 0.0, 1e-5));
	float s2 = max(dot(MODEL_MATRIX[0].xyz, MODEL_MATRIX[0].xyz), 1e-4);
	vec3 lwd = vec3(dot(MODEL_MATRIX[0].xyz, wd), 0.0, dot(MODEL_MATRIX[2].xyz, wd)) / s2;

	float flex = COLOR.r;
	float sway = sin(t * 0.83 + phase) * 0.62 + sin(t * 1.67 + phase * 1.61) * 0.38;
	VERTEX += lwd * (sway * amp * bend_scale * flex * flex);

	// Ramp from the INSTANCE ORIGIN with the same per-tree offset foliage.gdshader
	// uses, so a trunk and its canopy always hand over together. See the long note in
	// that file for why a per-vertex distance breaks the dither.
	float lodh = fract(sin(dot(floor(iorg.xz * 4.0), vec2(12.9898, 78.233))) * 43758.5453);
	vec3 fpt = lod_focus.x > 1.0e8 ? CAMERA_POSITION_WORLD : lod_focus;
	float dref = distance(iorg, fpt) + (lodh - 0.5) * lod_jitter;
	v_fade = smoothstep(lod_fade.x, lod_fade.y, dref)
		* (1.0 - smoothstep(lod_fade.z, lod_fade.w, dref));
}

void fragment() {
	if (dither_fade) {
		vec2 p = floor(FRAGCOORD.xy);
		float dq = fract(52.9829189 * fract(0.06711056 * p.x + 0.00583715 * p.y));
		if (dither_invert) {
			if (v_fade > dq) { discard; }
		} else {
			if (v_fade <= dq) { discard; }
		}
	}
	vec3 tint = mix(tint_a, tint_b, clamp(v_var.x, 0.0, 1.0));
	ALBEDO = texture(alb_tex, UV).rgb * tint * albedo_gain * clamp(v_var.y, 0.4, 2.0);
	ROUGHNESS = clamp(texture(rgh_tex, UV).r, 0.25, 1.0);
	SPECULAR = 0.34;
	AO = mix(1.0, clamp(v_ao, 0.0, 1.0), ao_strength);
	AO_LIGHT_AFFECT = 0.6;
	NORMAL_MAP = texture(nrm_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_depth;
}
"""
