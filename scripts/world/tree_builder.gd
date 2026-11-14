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
# Dropped from 38 to 26 when the canopies became real 3D sprigs (2026-08-28). A FULL
# sal went from 848 triangles to 4.4k, and 38 m put 49 of them on screen at once in
# the hidden grove; 26 m puts 23 there. That is the trade: a FULL tree that is five
# times denser, seen a third less far. Measured in the grove — the worst spot on the
# map for this system — the two together land at ~380k tree triangles against 188k for
# the card build, inside the +350k the overhaul allows for near-field foliage. The hand-over is LESS visible than it was, not
# more, because MID is now the same sprigs at 6 triangles a leaf rather than a
# different-looking shell of cards.
const LOD_NEAR_END := 26.0
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
				"lamina": "leaf_lamina_broad",
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
				"lamina": "leaf_lamina_pinna",
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
				"lamina": "leaf_lamina_dark",
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
				"lamina": "leaf_lamina_broad",
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
				"lamina": "leaf_lamina_broad",
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
				"lamina": "leaf_lamina_broad",
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
				"lamina": "leaf_lamina_broad",
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
			return {"r": Vector4(LOD_MID_END - LOD_BAND, LOD_MID_END + LOD_BAND, LOD_FAR_END - 90.0, LOD_FAR_END), "d": true, "inv": false}


static func leaf_material(species: int, lod: int) -> ShaderMaterial:
	var key := species * 10 + lod
	if _leaf_mats.has(key):
		return _leaf_mats[key]
	var p := profile(species)
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/foliage.gdshader")
	# FULL and MID are real leaf geometry and take the single-blade lamina texture,
	# whose UV space IS the leaf. Only FAR is still a card, and a card still wants the
	# old cluster atlas cut out with an alpha scissor. Sharing one texture between the
	# two would either paint a dozen leaves onto one leaf or leave the billboard with
	# a single enormous lamina on it.
	var far := lod == Lod.FAR
	var tname: String = str(p.leaf) if far else str(p.lamina)
	m.set_shader_parameter("albedo_tex", Mats.tex(tname))
	m.set_shader_parameter("normal_tex", Mats.tex(tname + "_normal"))
	m.set_shader_parameter("two_sided", true)
	m.set_shader_parameter("use_normal_map", true)
	m.set_shader_parameter("tint_a", p.leaf_a)
	m.set_shader_parameter("tint_b", p.leaf_b)
	m.set_shader_parameter("roughness_value", 0.88)
	# 0.55 with the translucency cut would have made shaded canopy darker than it was;
	# 0.44 hands the ambient back and keeps the interior readable.
	m.set_shader_parameter("ao_strength", 0.26 if not far else 0.44)
	# The lamina normal map carries real venation and the geometry underneath it is
	# already curved, so it can be pushed much harder than it could on a flat card.
	m.set_shader_parameter("normal_depth", 0.28 if far else 0.55)
	m.set_shader_parameter("translucency_color", Color(p.trans.x, p.trans.y, p.trans.z))
	# 1.7x on real geometry. The card build biased every canopy normal outward and up,
	# so even the far side of a crown took some N-dot-L; a real leaf seen from beneath
	# has its normal flipped to face the viewer and takes NONE, and BACKLIGHT is the only
	# thing lighting it. Measured looking up through a mango at 10:30: the underside sat
	# at luminance 12 with the card-era amount. The old warning about cream-coloured
	# canopies still holds for the FAR billboard, which is why that keeps the old value.
	m.set_shader_parameter("translucency", float(p.trans_amt) * (1.0 if far else 1.7))
	# The shadow-independent half of the translucency. BACKLIGHT alone cannot light a
	# canopy interior — Godot multiplies it by the sun's shadow, and the canopy is
	# standing in its own shadow — so this carries the sun-through-the-leaf effect for
	# FULL and MID. The FAR billboard keeps 0: it is a card with an alpha cutout and the
	# old warning about cream-coloured distant canopies still applies to it.
	m.set_shader_parameter("transmit_strength", 0.0 if far else 0.85)
	m.set_shader_parameter("bend_scale", 0.42 + float(p.sway) * 0.8)
	# Distant cards are magnified, so a fixed cutoff eats them alive; loosening it at
	# range keeps far canopies from turning to lace. The lamina texture is opaque, so
	# on FULL and MID this threshold never fires and the silhouette is pure geometry.
	m.set_shader_parameter("alpha_cut", [0.40, 0.34, 0.24][lod])
	# The cluster atlas is mostly holes, so it needed a big gain to read at all; a solid
	# lamina does not, and 1.72 on one blew it out to cream under AGX.
	m.set_shader_parameter("albedo_gain", [2.15, 2.20, 1.92][lod])
	# Per-leaf hue jitter, which is what a canopy loses when the texture stops supplying
	# twelve differently-coloured leaves per card.
	m.set_shader_parameter("leaf_var", 0.0 if far else 0.30)
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


## Push the sun onto every foliage material. `dir` is the direction the light TRAVELS
## (down and along), `energy` 0..1 scales the transmission so leaves stop glowing after
## dark — the same rule ARCHITECTURE records for every other unshaded tint in the world.
## Called from SkySystem._apply, which is the only thing that knows where the sun is.
static func set_sun(dir: Vector3, energy: float) -> void:
	var d := dir.normalized() if dir.length_squared() > 1e-6 else Vector3.DOWN
	var e := clampf(energy, 0.0, 2.0)
	for m in _all_mats:
		m.set_shader_parameter("sun_dir", d)
		m.set_shader_parameter("sun_transmit", e)


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
##
## THE ONLY REMAINING CALLER IS `_build_far`. Everything the player can walk up to is
## real geometry now; past LOD_MID_END a leaf is under a pixel and a billboard is the
## right answer. Do not reach for this from a FULL or MID builder.
static func _card(s: Surf, c: Vector3, right: Vector3, up: Vector3, uvr: Rect2, nrm: Vector3, flex: float, ao: float) -> void:
	var rn := right.normalized()
	var un := up.normalized()
	var nn := nrm.normalized()
	# COLOR.a is the flutter phase, and it must be constant over the whole card: the
	# shader used to hash the vertex position for it, which gives the four corners four
	# different beats. A card only skewed; a real leaf built the same way tears apart.
	var ph: float = fposmod(c.x * 12.9898 + c.y * 78.233 + c.z * 37.719, 1.0)
	var col := Color(flex, ao, 0.5, ph)
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


# --- Sprigs ----------------------------------------------------------------
## Sprig shape by species. The canopy species differ HERE, not in the shell code:
##   banyan  broad ovate leaves held fairly flat, dense, glossy
##   mango   long lanceolate leaves, strongly drooping, dark
##   sal     the largest leaves, held out, a more open crown
##   bush    small leaves on a short twig
##
## MID keeps the sprig and drops each leaf to the two-triangle folded dart. It is still
## real geometry, and that is the point: the FULL/MID hand-over now changes DENSITY,
## not KIND, which is why LOD_NEAR_END could come in from 38 m to 30 m without the swap
## becoming more visible. MID leaves are also 1.55x larger, because past 30 m what has
## to survive is the silhouette fill, and filling it with fewer, bigger blades is the
## only version of that the triangle budget can pay for.
static func _sprig_spec(species: int, lod: int) -> Dictionary:
	var full := lod == Lod.FULL
	var c := Veg3D.sprig_cfg()
	# SIX triangles a leaf, not ten, for everything but the banyan — and one twig
	# segment, not two. Measured 2026-08-28: at ten triangles a canopy that fitted the
	# budget had 34 sprigs on a sal and photographed as a tree in winter. Coverage per
	# triangle is what a canopy needs, and the cheapest way to buy it is a smaller leaf
	# with the same cross-section, so the saved triangles go into MORE sprigs and BIGGER
	# blades. rows = 2 still has the camber, the taper and the pointed tip; what it gives
	# up is one bend along the length.
	c["rows"] = 2 if full else 1
	# No twig at MID. A 3 cm twig at 26 m is under a pixel wide, and it was 6 of the
	# 16 triangles in a MID sprig — 37% of the whole MID canopy budget spent on
	# something that cannot be resolved. The leaves still sit on the same virtual spine.
	c["stem_segs"] = 1 if full else 0
	match species:
		Species.BANYAN:
			c["length"] = 0.50
			c["width"] = 0.34
			c["broad"] = 0.44
			c["tip"] = 0.48
			c["base_w"] = 0.54
			c["camber"] = 0.40
			c["droop"] = 0.38
			c["twist"] = 0.26
			c["sag"] = 0.22
			c["spread"] = 1.16
			c["stem_len"] = 0.50
			c["stem_r"] = 0.017
			c["stem_droop"] = 0.34
			c["leaves"] = 6
		Species.MANGO:
			c["length"] = 0.56
			c["width"] = 0.27
			c["broad"] = 0.42
			c["tip"] = 0.22
			c["base_w"] = 0.56
			c["camber"] = 0.52
			c["droop"] = 1.05
			c["twist"] = 0.45
			c["sag"] = 0.80
			c["spread"] = 0.92
			c["stem_len"] = 0.44
			c["stem_r"] = 0.014
			c["stem_droop"] = 0.72
			c["leaves"] = 7
		Species.SAL:
			c["length"] = 0.62
			c["width"] = 0.34
			c["broad"] = 0.40
			c["tip"] = 0.34
			c["base_w"] = 0.52
			c["camber"] = 0.46
			c["droop"] = 0.55
			c["twist"] = 0.34
			c["sag"] = 0.34
			c["spread"] = 1.05
			c["stem_len"] = 0.55
			c["stem_r"] = 0.018
			c["stem_droop"] = 0.40
			c["leaves"] = 5
		_:
			c["length"] = 0.28
			c["width"] = 0.19
			c["broad"] = 0.40
			c["tip"] = 0.30
			c["base_w"] = 0.52
			c["camber"] = 0.48
			c["droop"] = 0.60
			c["twist"] = 0.35
			c["sag"] = 0.30
			c["spread"] = 1.20
			c["stem_len"] = 0.22
			c["stem_r"] = 0.010
			c["stem_droop"] = 0.30
			c["leaves"] = 5
	if not full:
		# MID trades leaf COUNT for leaf SIZE. Past 26 m the eye is reading silhouette
		# fill, not shape, so a fifth as many blades at 2.25x holds the crown together for
		# a tenth of the triangles. Coverage goes as the SQUARE of the size, which is why
		# this is the only lever that buys density for free — and it matters more than the
		# FULL settings do, because 26 to 76 m is where most of a forest actually is.
		# Measured in the deep wood: 655 MID trees on screen against 44 FULL.
		c["length"] = float(c["length"]) * 2.25
		c["width"] = float(c["width"]) * 2.25
		c["stem_len"] = float(c["stem_len"]) * 1.25
		c["stem_r"] = float(c["stem_r"]) * 1.5
	return c


## Plant one sprig so that its LEAVES land on the canopy surface and its twig is buried
## behind them: the base is pulled back along the growth direction by half the twig.
static func _plant_sprig(s: Surf, rng: RandomNumberGenerator, at: Vector3, grow: Vector3, spec: Dictionary, flex: float, ao: float) -> void:
	var g: Vector3 = grow
	if g.length_squared() < 1e-8:
		g = Vector3.UP
	g = g.normalized()
	var side := g.cross(Vector3.UP)
	if side.length_squared() < 1e-8:
		side = g.cross(Vector3.RIGHT)
	side = side.normalized().rotated(g, rng.randf() * TAU)
	var up := g.cross(side).normalized()
	var c: Dictionary = spec.duplicate()
	c["flex"] = clampf(flex, 0.0, 1.0)
	c["ao"] = clampf(ao, 0.0, 1.0)
	c["phase"] = rng.randf()
	var base: Vector3 = at - g * (float(spec.stem_len) * 0.55)
	Veg3D.sprig(s, Transform3D(Basis(side, up, g), base), rng, c)


## Sprigs hanging off a branch tip: this is what fills the skirt of a crown and hides
## the last stretch of bare branch.
static func _sprig_blob(
	s: Surf,
	rng: RandomNumberGenerator,
	centre: Vector3,
	hub: Vector3,
	count: int,
	radius: float,
	spec: Dictionary,
	droop: float,
	flex: float
) -> void:
	for i in range(count):
		var dir := Vector3(rng.randfn(0.0, 1.0), rng.randfn(0.0, 0.75), rng.randfn(0.0, 1.0))
		if dir.length_squared() < 1e-6:
			dir = Vector3.UP
		var p := centre + dir.normalized() * radius * pow(rng.randf(), 0.55)
		var out := p - hub
		if out.length_squared() < 1e-6:
			out = Vector3.UP
		var grow := (out.normalized() + Vector3.DOWN * droop).normalized()
		var depth: float = clampf((p - hub).length() / maxf(radius * 2.4, 0.6), 0.0, 1.0)
		_plant_sprig(s, rng, p, grow, spec, clampf(flex + rng.randf_range(-0.06, 0.10), 0.0, 1.0), 0.50 + 0.50 * depth)


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
			d = ((d + Vector3(rng.randf_range(-1.0, 1.0), float(p.grav), rng.randf_range(-1.0, 1.0)) * float(p.wobble)).normalized())
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
			var cd := (pts[ix] - pts[ix - 1]).normalized() * float(p.align) + out * (1.0 - float(p.align)) + Vector3.UP * float(p.child_up)
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


## Fill an ellipsoid shell with SPRIGS. This, not the branch tips, is what gives a
## tree its silhouette: branching alone leaves a canopy that reads as a handful of
## clumps floating around a stick.
##
## Sprigs sit on a shell of thickness `thick`, and `thick` is now the important number.
## The card version wanted a THIN shell — cards were opaque, so anything buried behind
## the surface was wasted. A sprig is mostly gaps, so the depth is where the canopy
## comes from: with thick 0.72 a ray from underneath crosses three or four sprigs at
## different distances, which is exactly the "leaves at many depths and angles" the
## review asked for and the thing a shell of billboards can never do.
##
## Each sprig grows OUTWARD along the ellipsoid normal (with gravity mixed in), so its
## twig points into the crown and its leaves reach the surface. That single choice is
## what stops the twigs from being visible as a hedgehog of sticks.
static func _canopy_shell(
	s: Surf,
	rng: RandomNumberGenerator,
	hub: Vector3,
	rx: float,
	ry: float,
	count: int,
	spec: Dictionary,
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
		var rr: float = 1.0 - thick * pow(rng.randf(), 0.55)
		var p := hub + Vector3(d.x * rx, d.y * ry, d.z * rx) * rr
		# True outward normal of the ellipsoid, not of the sphere it came from.
		var shell := Vector3(d.x / maxf(rx, 0.01), d.y / maxf(ry, 0.01), d.z / maxf(rx, 0.01))
		if shell.length_squared() < 1e-8:
			shell = Vector3.UP
		shell = shell.normalized()
		var grow := (
			shell + Vector3.DOWN * droop + Vector3(rng.randf_range(-0.35, 0.35), rng.randf_range(-0.25, 0.25), rng.randf_range(-0.35, 0.35))
		)
		# Depth into the shell drives baked AO: buried sprigs go dark, which is what
		# makes a canopy look like a volume instead of a painted ball.
		#
		# The floor came up from 0.26 to 0.44 when the cards became sprigs. A card shell
		# was one layer thick and cast almost no shadow on itself; a 0.74-thick shell of
		# real leaves shadows its own interior for real, and Godot multiplies BACKLIGHT
		# by the shadow attenuation, so an interior leaf got neither sun nor glow AND a
		# 0.26 AO on top. Photographed from underneath they came out at luminance 5-10:
		# black paper. The shadow is doing the job the baked term used to fake.
		var ao: float = clampf(0.44 + 0.56 * (1.0 - (1.0 - rr) / maxf(thick, 0.01)) + d.y * 0.15, 0.0, 1.0)
		_plant_sprig(s, rng, p, grow, spec, clampf(flex + rng.randf_range(-0.08, 0.08), 0.0, 1.0), ao)


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
	# 760 CARDS became 118 SPRIGS. That is a sixth of the elements and eight times the
	# triangles per element, and it is the trade the review asked for: a card was an
	# opaque 1.1 m rectangle with a dozen leaves painted on it, a sprig is six real
	# leaves at six real angles. The crown is more open than it was — it has to be, a
	# canopy of individually modelled leaves cannot be as dense as a canopy of painted
	# ones inside any triangle budget — and the shell is thicker to compensate, so what
	# you see from underneath is depth rather than a wall.
	#
	# The banyan is the exception to the ~6k per-tree guidance on purpose: 14 exist on
	# the whole map, one stands in the village square at 1.6x scale, and it is the tree
	# the player walks under. It is the only species allowed past 6k.
	var spec := _sprig_spec(Species.BANYAN, lod)
	_canopy_shell(leaf, rng, hub, canopy_r * 0.98, canopy_r * 0.46, 130 if full else 40, spec, 0.74, 0.15, 0.85, 0.28)
	# A second, tighter shell right above the trunk fills the crown of the dome.
	_canopy_shell(
		leaf, rng, hub + Vector3(0, canopy_r * 0.16, 0), canopy_r * 0.50, canopy_r * 0.26, 35 if full else 12, spec, 0.70, 0.4, 0.85, 0.22
	)
	# A third shell on the UNDERSIDE of the dome, growing downward and inward.
	#
	# Photographed standing at the trunk of the hero specimen, the two shells above were
	# not enough: the hero is scaled 1.58x, so its crown is 14 m across, and a 40-degree
	# lens pointed straight up sees a cone only 3.6 m wide at canopy height. Everything
	# both shells placed was OUTSIDE that cone, and the shot came back as bare limbs
	# against the sky. This is the shell the player actually stands under.
	_canopy_shell(
		leaf, rng, hub - Vector3(0, canopy_r * 0.12, 0), canopy_r * 0.56, canopy_r * 0.30, 45 if full else 12, spec, 0.95, -0.35, 0.85, 0.55
	)
	# Foliage hanging off the ends of the level limbs, drooping: this is what fills the
	# skirt of the dome and hides the last stretch of bare branch.
	var per: int = 2 if full else 1
	for i in range(mini(tips.size(), 20 if full else 8)):
		var tp: Vector3 = tips[i]
		_sprig_blob(leaf, rng, tp + Vector3(0, -0.5, 0), hub, per, 1.7, spec, 0.45, 0.92)


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
	# --- THE CROWN. A frond used to be a two-triangle-per-segment strip with a picture
	# of a frond on it: edge-on it vanished, and it is the plant you can name from
	# across the valley. It is now a real rachis carrying ~30 individually curved,
	# folded leaflets. That is 282 triangles a frond against 16, and it is where most
	# of the palm's new budget went — deliberately, because the palm is the species the
	# player stands next to on the river road.
	var n_fronds: int = (11 + variant) if full else 8
	var flen: float = 4.0 + float(variant) * 0.35
	for f in range(n_fronds):
		var ang := TAU * (float(f) + rng.randf_range(-0.22, 0.22)) / float(n_fronds)
		var out := Vector3(cos(ang), 0.0, sin(ang))
		var side := Vector3(-out.z, 0.0, out.x)
		var fc := Veg3D.frond_cfg()
		fc["length"] = flen * rng.randf_range(0.86, 1.16)
		fc["rise"] = rng.randf_range(1.1, 2.0)
		fc["droop"] = rng.randf_range(3.0, 4.6)
		fc["sweep"] = rng.randf_range(-0.30, 0.30)
		fc["rachis_r"] = 0.052
		fc["phase"] = rng.randf()
		if full:
			fc["pairs"] = 17
			fc["rows"] = 2
			fc["pinna_len"] = 1.18
			fc["pinna_w"] = 0.30
		else:
			# MID: half the leaflets, at the two-triangle folded dart, 1.5x wider so the
			# frond still reads as a blade rather than a comb at 40 m.
			fc["pairs"] = 9
			fc["rows"] = 1
			fc["pinna_len"] = 1.45
			fc["pinna_w"] = 0.56
		Veg3D.frond(leaf, Transform3D(Basis(side, Vector3.UP, out), crown), rng, fc)
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
		_limb(bark, rng, lp, Vector3(0, trunk_h * rng.randf_range(0.78, 1.0), 0), dir, canopy_r * 0.85, base_r * 0.50, 0, tips)

	# Dense, rounded, dark. Mango leaves are long, narrow and hang almost vertically,
	# so a mango sprig is seven lanceolate blades with a heavy sag — which is also why
	# it is the one species where a thick shell costs nothing to read: the leaves are
	# narrow enough that you see past the outer layer to the one behind it anyway.
	var spec := _sprig_spec(Species.MANGO, lod)
	_canopy_shell(leaf, rng, hub, canopy_r, canopy_r * 0.88, 62 if full else 23, spec, 0.72, 0.10, 0.90, 0.40)
	var per: int = 2 if full else 1
	for i in range(mini(tips.size(), 12 if full else 4)):
		_sprig_blob(leaf, rng, tips[i], hub, per, 0.9, spec, 0.55, 0.95)


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
	# Sal is the workhorse — 2621 of them, and the species that decides whether the
	# deep wood holds its frame rate — so it gets the leanest sprig: five leaves, the
	# largest blades in the project, on a long twig.
	var spec := _sprig_spec(Species.SAL, lod)
	_canopy_shell(leaf, rng, hub, canopy_r, canopy_r * 0.64, 68 if full else 19, spec, 0.72, 0.15, 0.92, 0.34)
	_canopy_shell(
		leaf, rng, hub - Vector3(0, canopy_r * 0.55, 0), canopy_r * 0.74, canopy_r * 0.36, 22 if full else 5, spec, 0.76, 0.0, 0.92, 0.42
	)
	var per: int = 2 if full else 1
	for i in range(mini(tips.size(), 11 if full else 4)):
		_sprig_blob(leaf, rng, tips[i], hub, per, 0.9, spec, 0.45, 0.95)


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
			bark, rng, lp, Vector3(sin(y * 0.7) * 0.3, y, cos(y * 0.6) * 0.3), dir, h * rng.randf_range(0.24, 0.44), base_r * 0.42, 0, tips
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
		_tube(bark, sp, sr, PackedFloat32Array([0.0, 0.2, 0.45]), PackedFloat32Array([0.5, 0.7, 0.9]), 4, 1.0, 0.2, rng.randf() * TAU)

	# A shrub is sprigs on its stems; a FERN is not a shrub at all but a rosette of
	# small fronds, which is exactly the primitive the palm uses at a tenth of the size.
	# Building it out of crossed cards is what made the old one read as a green X.
	if fern:
		var nf: int = 6 if full else 3
		for i in range(nf):
			var ang3 := TAU * (float(i) + rng.randf_range(-0.2, 0.2)) / float(nf)
			var out3 := Vector3(cos(ang3), 0.0, sin(ang3))
			var sd3 := Vector3(-out3.z, 0.0, out3.x)
			var fc := Veg3D.frond_cfg()
			fc["length"] = spread * rng.randf_range(1.05, 1.45)
			fc["rise"] = h * rng.randf_range(0.55, 0.95)
			fc["droop"] = h * rng.randf_range(0.75, 1.25)
			fc["sweep"] = rng.randf_range(-0.35, 0.35)
			fc["rachis_r"] = 0.014
			fc["pairs"] = 7 if full else 4
			fc["rows"] = 1
			fc["pinna_len"] = 0.26 if full else 0.34
			fc["pinna_w"] = 0.075 if full else 0.105
			fc["back"] = 0.85
			fc["fall"] = 0.22
			fc["flex"] = 0.95
			fc["ao"] = 0.88
			fc["phase"] = rng.randf()
			Veg3D.frond(leaf, Transform3D(Basis(sd3, Vector3.UP, out3), Vector3(0, h * 0.28, 0)), rng, fc)
		return

	var spec := _sprig_spec(Species.BUSH, lod)
	var sprigs: int = 15 if full else 5
	for i in range(sprigs):
		var ang2 := rng.randf() * TAU
		var rr: float = spread * pow(rng.randf(), 0.45)
		var yy: float = rng.randf_range(0.14, 1.0) * h
		var p := Vector3(cos(ang2) * rr * 0.7, yy, sin(ang2) * rr * 0.7)
		var out := p - hub
		if out.length_squared() < 1e-6:
			out = Vector3.UP
		var grow := (out.normalized() + Vector3.UP * 0.55 + Vector3(0, rng.randf_range(-0.3, 0.3), 0)).normalized()
		_plant_sprig(leaf, rng, p, grow, spec, clampf(0.45 + yy / h * 0.5, 0.0, 1.0), clampf(0.35 + yy / h * 0.65, 0.0, 1.0))


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
			var d := 1.0 + 0.16 * sin(dir.x * lobes.x + 1.3) + 0.13 * sin(dir.y * lobes.y + 2.1) + 0.11 * sin(dir.z * lobes.z + 0.7)
			var p := Vector3(dir.x * rx, dir.y * ry, dir.z * rz) * d
			p.y = maxf(p.y, -ry * 0.62)
			var tan := Vector3(-sin(th), 0.0, cos(th))
			row.push_back(bark.vert(p, dir, tan, Color(0.0, clampf(0.45 + dir.y * 0.5, 0.0, 1.0), 0.5, 0.0), Vector2(u * 1.6, v * 1.1)))
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
		# Resized per species when the canopies became sprigs.
		#
		# These numbers were chosen against a canopy of OPAQUE cards. A canopy of real
		# leaves is more open, so the same billboard covered up to 2.9x the silhouette
		# of the MID mesh it takes over from and the tree would have visibly fattened at
		# 76 m. The factors are not a guess: tests/probes/veg3d_lod.gd renders all three LODs
		# of a species at one framing and reports the covered fraction, and these are
		# what bring every MID -> FAR ratio inside 0.65 .. 1.45. The palm goes UP —
		# its MID crown of nine real fronds is BROADER than the billboard was.
		var far_w: float = [0.88, 1.06, 0.58, 0.76, 1.0, 0.70, 1.0][species]
		var far_h: float = [0.90, 1.08, 0.60, 0.78, 1.0, 0.72, 1.0][species]
		cr *= far_w
		ch *= far_h
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
