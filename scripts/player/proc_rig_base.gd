class_name ProcRigBase
extends Node3D
## Part 1 of 6 of ProcRig (see proc_rig.gd): the config, the joints, the animation state,
## and the helpers every other part uses (materials, meshes, mesh merging).
## The six parts form one inheritance chain, so every caller still writes `ProcRig.name`.

# --- proportions (metres) --------------------------------------------------
var cfg := {
	"height": 1.80,
	"hip_h": 0.94,
	"thigh": 0.46,
	"shin": 0.44,
	"foot": 0.24,
	"spine": 0.30,
	"chest": 0.26,
	"neck": 0.09,
	"head": 0.115,
	"shoulder_w": 0.175,
	"upper_arm": 0.30,
	"lower_arm": 0.28,
	"hand": 0.10,
	"build": 1.0,  # limb thickness multiplier
	"hip_w": 0.11,
	"skin": "skin_warm",
	"cloth": "cloth_saffron",
	"cloth2": "cloth_white",
	"hair_color": Color(0.07, 0.055, 0.05),
	"dhoti": true,
	"sash": true,
	"jewellery": true,
	"topknot": true,
	"beard": false,
	"horns": false,
	"claws": false,
	"tilaka": false,
	"channavira": false,
	"vanara": false,
	"ten_heads": false,
	"skin_tint": Color(1, 1, 1),
	"cloth_tint": Color(1, 1, 1),
	# Everything below is derived from `seed` when left at its sentinel, so twelve
	# villagers are twelve people rather than one person at twelve scales. Each is
	# quantised to a handful of buckets: the mesh cache is keyed on these, and rolling
	# them continuously is exactly the mistake that made a rig build cost 53 ms.
	"face": -1,  # MeshKit.FACE_PRESETS index
	"hair_style": -1,  # MeshKit.Hair
	"beard_len": -1.0,  # 0 = clean shaven
	"belly": -1.0,  # waist fullness
	"shoulders": -1.0,  # shoulder width multiplier
	"garment": "",  # "dhoti" | "lungi" | "sari"
	"grip_l": -1,  # MeshKit.Grip, -1 = follow whatever the hand is holding
	"grip_r": -1,
}

# --- joints ----------------------------------------------------------------
var hips: Node3D
var spine: Node3D
var chest: Node3D
var neck: Node3D
var head: Node3D
var thigh := {}  # "L"/"R" -> Node3D
var knee := {}
var ankle := {}
var shoulder := {}
var elbow := {}
var hand := {}
var hand_attach := {}  # where a weapon parents
var eye := {}  # "L"/"R" -> Node3D, rotates to track what the head is looking at
var skirt_node: Node3D  # the dhoti / lungi / sari, swung by velocity
var sash_node: Node3D  # the uttariya or pallu, lighter and quicker
var humanoid_model: HumanoidModel = null

# --- animation state -------------------------------------------------------
var stride_phase: float = 0.0
var _foot_world := {"L": Vector3.ZERO, "R": Vector3.ZERO}
var _foot_planted := {"L": true, "R": true}
var _breath: float = 0.0
var _t: float = 0.0

var look_target: Vector3 = Vector3.ZERO
var look_weight: float = 0.0
var aim_weight: float = 0.0  # 0 = relaxed, 1 = bow drawn
var aim_dir: Vector3 = Vector3.FORWARD
var attack_swing: float = 0.0  # 0..1 through a melee arc
var attack_kind: int = 0
var hurt_amount: float = 0.0
var dead_amount: float = 0.0
var _rng := RandomNumberGenerator.new()
var _idle_seed: float = 0.0

# --- face --------------------------------------------------------------------
var _lid_up: Node3D
var _lid_lo: Node3D
var _eyes_lo: MeshInstance3D
var _blink_t: float = 1.0
var _blink_a: float = 0.0
var _blink_left: int = 0
var _sac_t: float = 0.0
var _sac := Vector2.ZERO
var _gaze := Vector2.ZERO

# --- cloth -------------------------------------------------------------------
var _sway := Vector2.ZERO
var _sway_v := Vector2.ZERO
var _prev_gpos: Vector3 = Vector3.ZERO
var _prev_yaw: float = 0.0
var _turn: float = 0.0
var _has_prev: bool = false

# --- level of detail ---------------------------------------------------------
## Hands drop to mittens and the eyes to two dark discs past this. A knuckle is a
## third of a pixel at twelve metres and the eye geometry is six draw calls.
static var lod_near: float = 12.0
var _lod: int = -1
var _lod_tick: int = 0
var _hand_hi := {}
var _hand_lo := {}
var _grip := {"L": -1, "R": -1}

## Ground sampler so feet can conform to the terrain. Set by the owner.
var ground_fn: Callable = Callable()


func configure(over: Dictionary) -> void:
	for k in over:
		cfg[k] = over[k]


## Proportions are SNAPPED to a coarse grid before any mesh is generated.
##
## Every generated mesh is memoised on its arguments, but each character was rolling
## continuous random proportions, so every rig missed the cache and cost ~53 ms to
## build; with 26 enemies and 12 villagers streaming in, that was 98 of the 131 slow
## frames on a walk across the map. Snapped to 3 cm, a rakshasa is visually identical
## and the second one of its size costs 1.3 ms.
## Where the head's centre sits above the neck joint, in units of `head`. Every part of
## the head is generated at a CANONICAL radius of 1 and scaled by `head` on the way in:
## the field is linear in the radius, so this collapses what would be one sculpted skull
## per body size down to one per face preset. Measured 2026-08-28: it took a rig build
## from 28 ms back to 1.6 ms.
const HEAD_C := 0.88

const SNAP := 0.03
const SNAP_KEYS := [
	"height", "hip_h", "thigh", "shin", "foot", "spine", "chest", "neck", "head", "shoulder_w", "upper_arm", "lower_arm", "hand", "hip_w"
]


func _quantise() -> void:
	for k in SNAP_KEYS:
		if cfg.has(k):
			cfg[k] = snappedf(float(cfg[k]), SNAP)
	cfg["build"] = snappedf(float(cfg.get("build", 1.0)), 0.05)


## Fill in whatever the caller did not specify, from the seed, in BUCKETS.
##
## Twelve villagers built from one config are one person twelve times. The variety has
## to be quantised, though: every generated mesh is memoised on its arguments, and
## rolling a continuous face shape per villager is exactly the mistake that once made a
## rig build cost 53 ms instead of 1.
func _derive_variety() -> void:
	var rv := RandomNumberGenerator.new()
	rv.seed = hash(cfg.get("seed", 0)) * 31 + 7
	if int(cfg.face) < 0:
		cfg["face"] = rv.randi_range(0, 3)
	if int(cfg.hair_style) < 0:
		if cfg.topknot:
			cfg["hair_style"] = MeshKit.Hair.JATA
		else:
			cfg["hair_style"] = [MeshKit.Hair.BUN, MeshKit.Hair.BRAID, MeshKit.Hair.LOOSE, MeshKit.Hair.SHORT][rv.randi_range(0, 3)]
	if float(cfg.beard_len) < 0.0:
		cfg["beard_len"] = [0.35, 0.70, 1.00][rv.randi_range(0, 2)] if cfg.beard else 0.0
	if float(cfg.belly) < 0.0:
		cfg["belly"] = [0.0, 0.10, 0.20][rv.randi_range(0, 2)]
	if float(cfg.shoulders) < 0.0:
		cfg["shoulders"] = [0.94, 1.02, 1.10][rv.randi_range(0, 2)]
	if String(cfg.garment) == "":
		# Only people wear a sari. `skin` is the discriminator because it is the one
		# thing every caller already sets, and a rakshasa in a pallu is not the note.
		if String(cfg.skin).begins_with("skin") and not cfg.topknot:
			cfg["garment"] = ["dhoti", "dhoti", "lungi", "sari"][rv.randi_range(0, 3)]
		else:
			cfg["garment"] = "dhoti"
	if String(cfg.garment) == "sari":
		cfg["sash"] = true  # the pallu is not optional; it is what makes it a sari


## Collapse each joint's meshes down to one per material.
##
## A rig is built from ~42 separate MeshInstance3D nodes, and every one of them is its
## own draw call. Measured 2026-08-28 in the village: twelve villagers alone accounted
## for 503 of 1246 visible draws. The meshes under a joint never move relative to each
## other, so they can be merged once at build time; only the joints themselves need to
## stay separate for the animation to work.
static var merge_enabled: bool = true


func _merge_draws() -> void:
	if not merge_enabled:
		return
	var joints: Array[Node3D] = [hips, spine, chest, neck, head]
	for side in ["L", "R"]:
		joints.append(shoulder[side])
		joints.append(elbow[side])
		joints.append(hand[side])
		joints.append(thigh[side])
		joints.append(knee[side])
		joints.append(ankle[side])
	# The garments hang off their own nodes so they can swing; merge inside those too,
	# or a dhoti costs three draws instead of one.
	joints.append(skirt_node)
	joints.append(sash_node)
	for j in joints:
		if j != null:
			_merge_joint(j)


func _merge_joint(j: Node3D) -> void:
	var groups: Dictionary = {}
	for c in j.get_children():
		if not (c is MeshInstance3D) or c.get_child_count() > 0:
			continue
		var mi := c as MeshInstance3D
		if mi.mesh == null or mi.material_override == null:
			continue
		var key: int = mi.material_override.get_instance_id()
		if not groups.has(key):
			groups[key] = {"mat": mi.material_override, "parts": [], "nodes": []}
		groups[key].parts.append({"mesh": mi.mesh, "xform": mi.transform})
		groups[key].nodes.append(mi)
	for key in groups:
		var g: Dictionary = groups[key]
		if g.parts.size() < 2:
			continue
		var merged := MeshKit.bake_cached(g.parts)
		for n in g.nodes:
			j.remove_child(n)
			n.queue_free()
		var mi2 := MeshInstance3D.new()
		mi2.mesh = merged
		mi2.material_override = g.mat
		mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		j.add_child(mi2)


var _skin_lod: Material
var _hair_lod: Material
var _near_mats: Array = []

static var _variant_cache: Dictionary = {}


## A distinct Material object that LOOKS identical. Two meshes can then share an
## appearance while `_merge_draws`, which groups by material identity, keeps them apart.
static func _mat_variant(src: Material, tag: String) -> Material:
	var key := "%d|%s" % [src.get_instance_id(), tag]
	var hit: Variant = _variant_cache.get(key)
	if hit != null:
		return hit
	var m: Material = src.duplicate()
	_variant_cache[key] = m
	return m


static var _cav_mat: StandardMaterial3D = null


## Nostrils and the line of the mouth. Deliberately NOT near any of the colours
## enemy_types.gd matches on, or every rakshasa would grow glowing amber nostrils.
func _mat_cavity() -> Material:
	if _cav_mat == null:
		_cav_mat = Mats.flat(Color(0.17, 0.085, 0.07), 0.88)
	return _cav_mat


# --- helpers ---------------------------------------------------------------
static var _mat_cache: Dictionary = {}


func _mat(base: String, tint: Color) -> Material:
	# Cached: a duplicate per rig meant ~5 material clones per character, each
	# carrying its own texture references.
	var key := "%s|%.2f|%.2f|%.2f" % [base, tint.r, tint.g, tint.b]
	var hit: Variant = _mat_cache.get(key)
	if hit != null:
		return hit
	var m: StandardMaterial3D = Mats.pbr(base, 1.0, base).duplicate()
	m.albedo_color = tint
	# Skin and cloth normals at full strength turned the body into shading noise at
	# character scale; the detail is real but it is millimetre detail.
	if m.normal_enabled:
		m.normal_scale = 0.35 if base.begins_with("skin") else 0.55
	if base.begins_with("cloth"):
		m.uv1_scale = Vector3(2.2, 2.2, 2.2)
	elif base.begins_with("skin"):
		# Pore detail, not a wood grain wrapped once around the whole limb.
		m.uv1_scale = Vector3(4.0, 4.0, 4.0)
		m.albedo_color = Color(tint.r * 1.34, tint.g * 1.24, tint.b * 1.16, tint.a)
	_mat_cache[key] = m
	return m


func _mesh(
	parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, scale_v: Vector3 = Vector3.ONE, rot: Vector3 = Vector3.ZERO
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.scale = scale_v
	if rot != Vector3.ZERO:
		mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mi)
	return mi


static var _down_cache: Dictionary = {}


## Flip a +Y mesh so it hangs down from its joint. Memoised on the source mesh, since
## the same limb mesh is flipped for every character that shares those proportions.
static func _down(m: ArrayMesh) -> ArrayMesh:
	var key: int = m.get_instance_id()
	var hit: Variant = _down_cache.get(key)
	if hit != null:
		return hit
	var out := _down_gen(m)
	_down_cache[key] = out
	return out


static func _down_gen(m: ArrayMesh) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var arrays := m.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	# SurfaceTool.commit() leaves ARRAY_INDEX null when the surface is not indexed.
	var idx := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		idx = arrays[Mesh.ARRAY_INDEX]
	var seq: Array = []
	if idx.is_empty():
		for i in range(v.size()):
			seq.append(i)
	else:
		for i in idx:
			seq.append(i)
	# Mirroring in Y reverses handedness, so the winding must be reversed too or the
	# limb renders inside out.
	var n := seq.size()
	for t in range(0, n, 3):
		for k in [2, 1, 0]:
			var i: int = seq[t + k]
			st.set_uv(uv[i] if uv.size() == v.size() else Vector2.ZERO)
			st.add_vertex(Vector3(v[i].x, -v[i].y, v[i].z))
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


func total_leg() -> float:
	return cfg.thigh + cfg.shin


func _rest_foot(side: String) -> Vector3:
	var sx: float = 1.0 if side == "L" else -1.0
	var p := Vector3(sx * cfg.hip_w, 0.0, 0.0)
	return (global_transform * p) if is_inside_tree() else p


# ===========================================================================
#  ANIMATION
# ===========================================================================
## Everything below computes a pose from scratch every frame. There is no animation
## data: locomotion is a foot-placement cycle resolved with two-bone IK, and aiming,
## attacking, flinching and dying are additive layers blended on top of it.

const STRIDE_LEN: float = 1.55  # metres of travel per full gait cycle
const STANCE_FRAC: float = 0.62  # fraction of the cycle a foot is planted

var _hip_y_off: float = 0.0
var _lean: Vector2 = Vector2.ZERO
var _arm_extra := {"L": Vector3.ZERO, "R": Vector3.ZERO}
var _last_pos: Vector3 = Vector3.ZERO
var _step_signal_side: String = ""

signal footstep(side: String, position: Vector3, speed: float)


## Orientation whose local -Y points along `dir`. Limbs are built hanging downward,
## so this is how a limb is aimed at a target.
static func basis_down(dir: Vector3, fwd_ref: Vector3) -> Basis:
	var y := -dir.normalized()
	var z := fwd_ref - y * fwd_ref.dot(y)
	if z.length_squared() < 1.0e-6:
		z = Vector3.FORWARD - y * Vector3.FORWARD.dot(y)
		if z.length_squared() < 1.0e-6:
			z = Vector3.RIGHT - y * Vector3.RIGHT.dot(y)
	z = z.normalized()
	var x := y.cross(z).normalized()
	z = x.cross(y).normalized()
	return Basis(x, y, z)


## Classic two-bone IK. Returns the joint (knee/elbow) position.
static func solve_two_bone(root_p: Vector3, target: Vector3, l1: float, l2: float, pole: Vector3) -> Vector3:
	var to_t := target - root_p
	var d: float = clampf(to_t.length(), 0.02, l1 + l2 - 0.004)
	var dir := to_t.normalized() if to_t.length() > 0.0001 else Vector3.DOWN
	var cos_a: float = clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0)
	var a: float = acos(cos_a)
	var axis := dir.cross(pole)
	if axis.length_squared() < 1.0e-6:
		axis = dir.cross(Vector3.RIGHT)
		if axis.length_squared() < 1.0e-6:
			axis = dir.cross(Vector3.FORWARD)
	axis = axis.normalized()
	return root_p + dir.rotated(axis, -a) * l1


var _blink_dir: float = 1.0


# ===========================================================================
#  MEASUREMENTS
# ===========================================================================
## What the head actually came out as, measured off the geometry.
##
## This is a contract, not a debug aid: `tests/probes/npc_test.gd` asserts on every number in
## it, because "they have faces now" has been wrong twice in this project — once with
## the features buried inside the skull, once with the hair cap sized so it drew
## entirely inside the head and left twelve villagers bald in seventeen screenshots
## that were signed off as good.
static var _metrics_cache: Dictionary = {}
