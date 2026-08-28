class_name ProcRig
extends Node3D
## A procedurally built, procedurally animated humanoid.
##
## There are no imported character assets and no skinned meshes: the body is a
## hierarchy of generated meshes, and every pose is computed in code. That buys full
## control (any proportions, any species, no animation pipeline) at the cost of having
## to write the locomotion by hand — which is done here with real two-bone IK on the
## legs so feet PLANT and do not slide, plus layered additive poses for aiming,
## attacking, flinching and dying.
##
## The same class builds Rama, villagers, guards and rakshasas; only the config differs.

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


func build() -> void:
	_quantise()
	_rng.seed = hash(cfg.get("seed", 0))
	_idle_seed = _rng.randf() * 100.0
	_derive_variety()
	var b: float = cfg.build
	var sh_w: float = float(cfg.shoulders)

	var m_skin := _mat(cfg.skin, cfg.skin_tint)
	var m_cloth := _mat(cfg.cloth, cfg.cloth_tint)
	var m_cloth2 := _mat(cfg.cloth2, Color(1, 1, 1))
	# Hair carries a cloth normal map. Flat-shaded it reads as a moulded plastic cap
	# however good the silhouette is; the grain is what makes it hair.
	var m_hair := Mats.pbr("cloth_white", 3.0, "cloth_white").duplicate()
	m_hair.albedo_color = Color(cfg.hair_color) * 1.15
	m_hair.roughness = 0.80
	m_hair.normal_scale = 0.9

	hips = Node3D.new()
	hips.name = "Hips"
	hips.position = Vector3(0, cfg.hip_h, 0)
	add_child(hips)

	# Pelvis: wider than deep, tucked under the waist.
	_mesh(
		hips,
		(
			MeshKit
			. profile_loft(
				0.24,
				[
					[0.0, 0.108 * b, 0.086 * b],
					[0.30, 0.132 * b, 0.100 * b],
					[0.68, 0.140 * b, 0.104 * b],
					[1.0, 0.124 * b, 0.092 * b],
				],
				16
			)
		),
		m_skin,
		Vector3(0, -0.16, 0)
	)

	spine = Node3D.new()
	spine.name = "Spine"
	hips.add_child(spine)

	chest = Node3D.new()
	chest.name = "Chest"
	chest.position = Vector3(0, cfg.spine, 0)
	spine.add_child(chest)
	_build_torso(m_skin, b, sh_w)

	neck = Node3D.new()
	neck.name = "Neck"
	neck.position = Vector3(0, cfg.chest * 0.92, 0)
	chest.add_child(neck)
	_mesh(neck, MeshKit.limb(cfg.neck, 0.052 * b, 0.062 * b, 1.0, 10), m_skin, Vector3.ZERO)
	# Sternocleidomastoids: the two cords down the front of the neck. Without them the
	# neck is a pipe and the head looks screwed on.
	for sxx in [-1.0, 1.0]:
		_mesh(
			neck,
			MeshKit.limb(cfg.neck * 0.95, 0.014 * b, 0.019 * b, 1.0, 6),
			m_skin,
			Vector3(sxx * 0.026 * b, 0.004, 0.036 * b),
			Vector3.ONE,
			Vector3(0.30, 0.0, sxx * 0.24)
		)

	head = Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, cfg.neck, 0)
	neck.add_child(head)
	_build_head(m_skin, m_hair)

	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		_build_arm(side, sx, b, sh_w, m_skin)
		_build_leg(side, sx, b, m_skin)

	if cfg.dhoti:
		_build_skirt(m_cloth)
	if cfg.sash:
		_build_sash(m_cloth2)
	if cfg.jewellery:
		_build_jewellery()

	_merge_draws()

	for side in ["L", "R"]:
		_foot_world[side] = _rest_foot(side)


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


## The torso, with a skeleton under the skin: a ribcage that tapers into the waist,
## collarbones, pectorals and the two blades of the scapulae. All one material, so
## `_merge_draws` collapses the lot into a single draw the moment the rig is built.
func _build_torso(m_skin: Material, b: float, sh_w: float) -> void:
	var belly: float = float(cfg.belly)
	var wide: float = b * sh_w
	_mesh(
		chest,
		(
			MeshKit
			. profile_loft(
				cfg.spine + cfg.chest,
				[
					[0.00, (0.118 + belly * 0.075) * b, (0.090 + belly * 0.060) * b],
					[0.16, (0.128 + belly * 0.070) * b, (0.096 + belly * 0.055) * b],
					[0.38, (0.148 + belly * 0.030) * b, (0.104 + belly * 0.025) * b],
					[0.60, 0.163 * wide, 0.108 * b],
					[0.78, 0.166 * wide, 0.104 * b],
					[0.92, 0.152 * wide, 0.094 * b],
					[1.00, 0.120 * wide, 0.078 * b],
				],
				18
			)
		),
		m_skin,
		Vector3(0, -cfg.spine, 0)
	)
	for sxx in [-1.0, 1.0]:
		# Pectoral.
		_mesh(
			chest,
			MeshKit.ovoid(0.070 * b, 0.10, 0.5, 10, 7),
			m_skin,
			Vector3(sxx * 0.078 * b, cfg.chest * 0.56, 0.078 * b),
			Vector3(1.30, 0.72, 0.42)
		)
		# Trapezius, running from the neck out to the point of the shoulder.
		_mesh(
			chest,
			MeshKit.ovoid(0.062 * b, 0.12, 0.5, 10, 7),
			m_skin,
			Vector3(sxx * 0.105 * wide, cfg.chest * 0.80, -0.010 * b),
			Vector3(1.2, 1.0, 0.9)
		)
		# Collarbone: an S from the sternum to the acromion. It is two centimetres of
		# geometry and it is most of what says "there is a skeleton in there".
		var cl := PackedVector3Array()
		var cr := PackedFloat32Array()
		for i in range(5):
			var f: float = float(i) / 4.0
			(
				cl
				. append(
					Vector3(
						sxx * f * cfg.shoulder_w * 0.94,
						cfg.chest * 0.755 + sin(f * PI) * 0.006,
						lerpf(0.072, 0.012, f * f) * b,
					)
				)
			)
			cr.append(lerpf(0.0125, 0.0165, f) * b)
		_mesh(chest, MeshKit.sweep(cl, cr, 6, 0.85, Vector3.UP), m_skin, Vector3.ZERO)
		# Shoulder blade.
		_mesh(
			chest,
			MeshKit.ovoid(0.062 * b, 0.135, 0.45, 9, 6),
			m_skin,
			Vector3(sxx * 0.078 * wide, cfg.chest * 0.52, -0.088 * b),
			Vector3(1.0, 1.0, 0.30),
			Vector3(0.0, 0.0, sxx * 0.22)
		)
	# The line down the sternum and the linea alba below it.
	_mesh(
		chest,
		MeshKit.limb(cfg.spine + cfg.chest * 0.90, 0.010 * b, 0.014 * b, 1.0, 6),
		m_skin,
		Vector3(0, -cfg.spine, (0.086 + belly * 0.052) * b)
	)


## The head. Everything on it is generated by MeshKit against the SAME sculpted skull
## field, so the hair cannot end up inside the scalp and the mouth cannot end up inside
## the face — both of which have happened here before, to characters that shipped.
##
## THE FACE IS ON -Z, which is the direction this rig walks and looks. It used to be
## built on +Z, and two other files each carried a routine to turn the head back to
## front; both of those now defer to `face_metrics()` and leave the head alone.
func _build_head(m_skin: Material, m_hair: Material) -> void:
	var r: float = cfg.head
	var fp: int = int(cfg.face)
	var yc: float = r * HEAD_C
	var hseed: int = int(hash(cfg.get("seed", 0)) & 7)
	var sc := Vector3.ONE * r
	var mi := _mesh(head, MeshKit.head_shell(1.0, fp, 0), m_skin, Vector3(0, yc, 0), sc)
	mi.name = "Skull"
	_mesh(head, MeshKit.face_cavities(1.0, fp), _mat_cavity(), Vector3(0, yc, 0), sc)
	var hair := _mesh(head, MeshKit.hair(1.0, fp, int(cfg.hair_style), hseed, 0), m_hair, Vector3(0, yc, 0), sc)
	hair.name = "Hair"
	_mesh(head, MeshKit.brows(1.0, fp, 0), m_hair, Vector3(0, yc, 0), sc)
	if float(cfg.beard_len) > 0.02:
		_mesh(head, MeshKit.beard(1.0, fp, float(cfg.beard_len), 0), m_hair, Vector3(0, yc, 0), sc)
	# LOD 1 head: the same field at a third of the resolution, hidden until it is
	# needed. It gets its OWN material instances so `_merge_draws` cannot fold it back
	# into the near head — that pass groups by material, and two skin meshes under one
	# joint would become one mesh that is always drawn.
	_skin_lod = _mat_variant(m_skin, "lod")
	_hair_lod = _mat_variant(m_hair, "hairlod")
	var sl := _mesh(head, MeshKit.head_shell(1.0, fp, 1), _skin_lod, Vector3(0, yc, 0), sc)
	sl.name = "SkullLo"
	sl.visible = false
	var hlo := _mesh(head, MeshKit.hair(1.0, fp, int(cfg.hair_style), hseed, 1), _hair_lod, Vector3(0, yc, 0), sc)
	hlo.name = "HairLo"
	hlo.visible = false
	_near_mats = [m_skin, m_hair, _mat_cavity()]
	_build_eyes(r, m_skin)
	if cfg.horns:
		var m_horn := StandardMaterial3D.new()
		m_horn.albedo_color = Color(0.14, 0.12, 0.12)
		m_horn.roughness = 0.5
		for sx in [-1.0, 1.0]:
			var h := MeshKit.tube(r * 1.5, [[0.0, r * 0.20], [0.5, r * 0.13], [1.0, r * 0.03]], 8, 1.0, Vector3(sx * r * 0.5, 0, r * 0.35))
			_mesh(head, h, m_horn, Vector3(sx * r * 0.62, yc + r * 0.62, r * 0.10))


## Eyeballs that track, and lids that blink.
##
## The lids share one node per pair because a blink is a rotation about the line
## through both eye centres — which is exactly the X axis they both sit on — so two
## meshes and two nodes buy a blink for both eyes. The eyeballs cannot share: a yaw
## about a shared origin swings one eye out of its socket by eight millimetres.
func _build_eyes(r: float, m_skin: Material) -> void:
	var ex: float = MeshKit.EYE_X * r
	var ey: float = (HEAD_C + MeshKit.EYE_Y) * r
	var ez: float = MeshKit.EYE_Z * r
	# These two colours are a published interface: enemy_types.gd finds the eyes by
	# matching them loosely so a rakshasa's can be retinted amber. Moving either more
	# than about 0.05 silently costs every rakshasa its eyes.
	var m_eye := Mats.flat(Color(0.86, 0.83, 0.78), 0.22)
	var m_iris := Mats.flat(Color(0.11, 0.068, 0.046), 0.08)
	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		var e := Node3D.new()
		e.name = "Eye" + side
		e.position = Vector3(sx * ex, ey, ez)
		e.scale = Vector3.ONE * r
		head.add_child(e)
		eye[side] = e
		_mesh(e, MeshKit.sphere(MeshKit.EYE_R, 16, 11), m_eye, Vector3.ZERO)
		_mesh(e, MeshKit.spherical_cap(MeshKit.EYE_R * 1.014, 0.50, 12, 3), m_iris, Vector3.ZERO)
	for upper in [true, false]:
		var n := Node3D.new()
		n.name = "LidUp" if upper else "LidLo"
		n.position = Vector3(0, ey, ez)
		n.scale = Vector3.ONE * r
		head.add_child(n)
		var lid := MeshKit.eyelid(MeshKit.EYE_R, upper, 0)
		var parts: Array = [
			{"mesh": lid, "xform": Transform3D(Basis(), Vector3(MeshKit.EYE_X, 0, 0))},
			{"mesh": lid, "xform": Transform3D(Basis(), Vector3(-MeshKit.EYE_X, 0, 0))},
		]
		_mesh(n, MeshKit.bake_cached(parts), m_skin, Vector3.ZERO)
		if upper:
			_lid_up = n
		else:
			_lid_lo = n
	# LOD 1: two dark discs, one draw, replacing six.
	var cap := MeshKit.spherical_cap(MeshKit.EYE_R * 1.02, 0.62, 10, 2)
	var ec := Vector3(MeshKit.EYE_X, HEAD_C + MeshKit.EYE_Y, MeshKit.EYE_Z)
	var lo: Array = [
		{"mesh": cap, "xform": Transform3D(Basis(), ec)},
		{"mesh": cap, "xform": Transform3D(Basis(), Vector3(-ec.x, ec.y, ec.z))},
	]
	_eyes_lo = _mesh(head, MeshKit.bake_cached(lo), m_iris, Vector3.ZERO, Vector3.ONE * r)
	_eyes_lo.name = "EyesLo"
	_eyes_lo.visible = false


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


func _build_arm(side: String, sx: float, b: float, sh_w: float, m_skin: Material) -> void:
	var sh := Node3D.new()
	sh.name = "Shoulder" + side
	sh.position = Vector3(sx * cfg.shoulder_w * sh_w, cfg.chest * 0.72, 0)
	chest.add_child(sh)
	shoulder[side] = sh
	_mesh(sh, MeshKit.sphere(0.070 * b, 10, 8), m_skin, Vector3.ZERO)
	# Deltoid over the joint, then the bicep sitting forward of the bone.
	_mesh(
		sh,
		(
			ProcRig
			. _down(
				(
					MeshKit
					. limb_anat(
						cfg.upper_arm,
						[
							[0.00, 0.070 * b, 0.068 * b, 0.0, 0.0],
							[0.16, 0.075 * b, 0.072 * b, 0.0, -0.004 * b],
							[0.40, 0.059 * b, 0.064 * b, 0.0, -0.009 * b],
							[0.64, 0.050 * b, 0.056 * b, 0.0, -0.007 * b],
							[0.86, 0.043 * b, 0.046 * b, 0.0, -0.002 * b],
							[1.00, 0.040 * b, 0.043 * b, 0.0, 0.0],
						],
						11
					)
				)
			)
		),
		m_skin,
		Vector3.ZERO
	)

	var el := Node3D.new()
	el.name = "Elbow" + side
	el.position = Vector3(0, -cfg.upper_arm, 0)
	sh.add_child(el)
	elbow[side] = el
	_mesh(el, MeshKit.sphere(0.047 * b, 8, 6), m_skin, Vector3.ZERO)
	# Forearm: the flexor mass just under the elbow, then a wrist that is flat, not round.
	_mesh(
		el,
		(
			ProcRig
			. _down(
				(
					MeshKit
					. limb_anat(
						cfg.lower_arm,
						[
							[0.00, 0.047 * b, 0.049 * b, 0.0, 0.0],
							[0.16, 0.051 * b, 0.054 * b, 0.0, -0.004 * b],
							[0.45, 0.043 * b, 0.047 * b, 0.0, -0.002 * b],
							[0.78, 0.033 * b, 0.038 * b, 0.0, 0.0],
							[1.00, 0.028 * b, 0.036 * b, 0.0, 0.0],
						],
						10
					)
				)
			)
		),
		m_skin,
		Vector3.ZERO
	)

	var hd := Node3D.new()
	hd.name = "Hand" + side
	hd.position = Vector3(0, -cfg.lower_arm, 0)
	el.add_child(hd)
	hand[side] = hd
	var hl: float = cfg.hand * 1.35
	var g: int = int(cfg.grip_l if side == "L" else cfg.grip_r)
	if g < 0:
		g = MeshKit.Grip.RELAXED
	_grip[side] = g
	# The two levels live under their own nodes so nothing merges them together: both
	# carry the skin material, and `_merge_draws` groups by material.
	var l0 := Node3D.new()
	l0.name = "Lod0"
	hd.add_child(l0)
	var l1 := Node3D.new()
	l1.name = "Lod1"
	l1.visible = false
	hd.add_child(l1)
	_hand_hi[side] = _mesh(l0, MeshKit.hand(hl, b, g, sx, 0), m_skin, Vector3.ZERO)
	_hand_lo[side] = _mesh(l1, MeshKit.hand_lod(hl, b, g, sx), m_skin, Vector3.ZERO)

	var at := Node3D.new()
	at.name = "Attach" + side
	# In the palm, inside the arc the fingers close through, so a shaft parented here
	# is held rather than floated beside the hand.
	at.position = Vector3(-sx * 0.085 * hl, -0.50 * hl, 0.0)
	hd.add_child(at)
	hand_attach[side] = at


func _build_leg(side: String, sx: float, b: float, m_skin: Material) -> void:
	var th := Node3D.new()
	th.name = "Thigh" + side
	th.position = Vector3(sx * cfg.hip_w, -0.03, 0)
	hips.add_child(th)
	thigh[side] = th
	_mesh(
		th,
		(
			ProcRig
			. _down(
				(
					MeshKit
					. limb_anat(
						cfg.thigh,
						[
							[0.00, 0.097 * b, 0.099 * b, 0.0, 0.0],
							[0.22, 0.099 * b, 0.103 * b, 0.0, -0.004 * b],
							[0.55, 0.085 * b, 0.091 * b, 0.0, -0.006 * b],
							[0.82, 0.071 * b, 0.075 * b, 0.0, -0.002 * b],
							[1.00, 0.062 * b, 0.066 * b, 0.0, 0.0],
						],
						12
					)
				)
			)
		),
		m_skin,
		Vector3.ZERO
	)

	var kn := Node3D.new()
	kn.name = "Knee" + side
	kn.position = Vector3(0, -cfg.thigh, 0)
	th.add_child(kn)
	knee[side] = kn
	_mesh(kn, MeshKit.sphere(0.058 * b, 8, 6), m_skin, Vector3.ZERO)
	# Calf: the belly of it sits BEHIND the bone and high, which is the difference
	# between a leg and a length of pipe.
	_mesh(
		kn,
		(
			ProcRig
			. _down(
				(
					MeshKit
					. limb_anat(
						cfg.shin,
						[
							[0.00, 0.060 * b, 0.062 * b, 0.0, 0.0],
							[0.12, 0.064 * b, 0.070 * b, 0.0, 0.007 * b],
							[0.32, 0.059 * b, 0.069 * b, 0.0, 0.014 * b],
							[0.58, 0.047 * b, 0.054 * b, 0.0, 0.008 * b],
							[0.84, 0.034 * b, 0.041 * b, 0.0, 0.002 * b],
							[1.00, 0.029 * b, 0.037 * b, 0.0, 0.0],
						],
						11
					)
				)
			)
		),
		m_skin,
		Vector3.ZERO
	)

	var an := Node3D.new()
	an.name = "Ankle" + side
	an.position = Vector3(0, -cfg.shin, 0)
	kn.add_child(an)
	ankle[side] = an
	# The ankle's local +Z is FORWARD (`basis_down` aims it along the rig's -Z), so the
	# foot — which is generated with its toes on -Z — is turned about Y, and generated
	# for the opposite side so the arch still lands on the inside edge.
	_mesh(an, MeshKit.foot(cfg.foot, b, -sx, 0), m_skin, Vector3.ZERO, Vector3.ONE, Vector3(0, PI, 0))


## The lower garment, under its own node so the whole thing can swing.
##
## The wrap must CLEAR THE LEGS. Thighs sit at x = +/-0.11 with a radius near 0.10, so
## anything under about 0.22 lets them poke through and the garment reads as a flat
## panel down the front instead of a skirt. Measured, not guessed — and the pleats cut
## into that radius, so they are accounted for here rather than added on top.
func _build_skirt(m_cloth: Material) -> void:
	skirt_node = Node3D.new()
	skirt_node.name = "Skirt"
	skirt_node.position = Vector3(0, 0.050, 0)
	hips.add_child(skirt_node)
	var g := String(cfg.garment)
	var seed_i: int = int(hash(cfg.get("seed", 0)) & 15)
	# A dhoti is wound tight at the waist, full over the hips, and falls in. It has to
	# clear the thigh — x 0.11 with a radius of 0.099, so 0.209 at the hip and less
	# below — and the pleats cut INTO that radius, which is why they are budgeted here
	# rather than added on top of a number that was already the minimum.
	var length: float = 0.47
	var stations: Array = [[0.0, 0.170], [0.15, 0.240], [0.45, 0.228], [0.74, 0.208], [0.92, 0.196], [1.0, 0.176]]
	var pleats: int = 10
	var depth: float = 0.080
	if g == "lungi":
		length = 0.58
		stations = [[0.0, 0.168], [0.20, 0.236], [0.62, 0.206], [0.90, 0.190], [1.0, 0.172]]
		pleats = 7
		depth = 0.048
	elif g == "sari":
		length = 0.80
		stations = [[0.0, 0.166], [0.15, 0.238], [0.50, 0.222], [0.80, 0.206], [0.94, 0.200], [1.0, 0.182]]
		pleats = 15
		depth = 0.085
	var mi := _mesh(skirt_node, MeshKit.skirt(length, stations, pleats, depth, 0.030, seed_i, 26), m_cloth, Vector3.ZERO)
	mi.name = "Dhoti"
	if g != "lungi":
		# The kachcha: the pleated fold tucked at the front and hanging free.
		_mesh(
			skirt_node,
			MeshKit.skirt(length * 1.06, [[0.0, 0.050], [0.35, 0.072], [1.0, 0.058]], 5, 0.30, 0.028, seed_i + 3, 10),
			m_cloth,
			Vector3(0, -0.020, -0.152)
		)
	# Waist cord.
	_mesh(skirt_node, MeshKit.tube(0.026, [[0.0, 0.188], [1.0, 0.188]], 18, 0.85), m_cloth, Vector3(0, -0.008, 0))


## The uttariya over the shoulder — or, on a sari, the pallu. Real cloth with a closed
## cross-section and folds down its length, not a flat card that vanishes edge-on.
func _build_sash(m: Material) -> void:
	sash_node = Node3D.new()
	sash_node.name = "Sash"
	chest.add_child(sash_node)
	var c: float = cfg.chest
	var seed_i: int = int(hash(cfg.get("seed", 0)) & 7)
	var sari := String(cfg.garment) == "sari"
	var path := PackedVector3Array(
		[
			Vector3(-0.075, -cfg.spine * 0.55, 0.112),
			Vector3(-0.020, c * 0.22, 0.126),
			Vector3(0.070, c * 0.66, 0.108),
			Vector3(0.140, c * 0.92, 0.030),
			Vector3(0.132, c * 0.84, -0.072),
			Vector3(0.080, c * 0.30, -0.124),
			Vector3(0.010, -cfg.spine * 0.40, -0.130),
			Vector3(-0.030, -cfg.spine * (1.35 if sari else 0.95), -0.115),
		]
	)
	var mi := _mesh(sash_node, MeshKit.cloth_strip(path, 0.190 if sari else 0.128, 0.009, 0.34, seed_i, 10), m, Vector3.ZERO)
	mi.name = "Uttariya"


func _build_jewellery() -> void:
	var m := Mats.brass()
	# Armlets, a torque and ear studs. Small, but they catch the light and read as
	# deliberate rather than as an unclothed placeholder.
	for side in ["L", "R"]:
		var sh: Node3D = shoulder[side]
		_mesh(sh, MeshKit.tube(0.035, [[0.0, 0.062], [1.0, 0.062]], 12), m, Vector3(0, -cfg.upper_arm * 0.42, 0))
		var el: Node3D = elbow[side]
		_mesh(el, MeshKit.tube(0.022, [[0.0, 0.046], [1.0, 0.046]], 10), m, Vector3(0, -cfg.lower_arm * 0.82, 0))
	_mesh(chest, MeshKit.tube(0.028, [[0.0, 0.085], [1.0, 0.082]], 14, 0.75), m, Vector3(0, cfg.chest * 0.88, 0.01))


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


## Drive the whole pose. `st` keys:
##   speed (planar m/s), vel (local-space velocity), on_floor, air_time,
##   crouch, dodge (0..1), state (String)
func animate(delta: float, st: Dictionary) -> void:
	_t += delta
	var speed: float = st.get("speed", 0.0)
	var on_floor: bool = st.get("on_floor", true)
	var dodge: float = st.get("dodge", 0.0)
	var air_t: float = st.get("air_time", 0.0)

	# --- gait phase -------------------------------------------------------
	var moving: float = clampf(speed / 1.2, 0.0, 1.0)
	if on_floor and speed > 0.12:
		stride_phase = fposmod(stride_phase + (speed / STRIDE_LEN) * delta, 1.0)
	else:
		# Settle to a clean stance rather than freezing mid-step.
		stride_phase = lerpf(stride_phase, roundf(stride_phase * 2.0) * 0.5, 1.0 - pow(0.001, delta))
	_breath += delta * lerpf(0.9, 2.6, moving)

	var stride: float = clampf(speed * 0.46, 0.0, 1.05)
	var bob: float = sin(stride_phase * TAU * 2.0) * 0.030 * moving
	var sway: float = sin(stride_phase * TAU) * 0.020 * moving
	var breathe: float = sin(_breath) * 0.008 * (1.0 - moving * 0.7)

	# --- body ------------------------------------------------------------
	var target_lean := Vector2(clampf(speed * 0.055, 0.0, 0.24), 0.0)
	if dodge > 0.01:
		target_lean.x += 0.55 * sin(dodge * PI)
	_lean = _lean.lerp(target_lean, 1.0 - pow(0.0008, delta))

	var air_tuck: float = clampf(air_t * 1.6, 0.0, 1.0) if not on_floor else 0.0
	_hip_y_off = lerpf(_hip_y_off, bob + breathe - air_tuck * 0.06 - st.get("crouch", 0.0) * 0.26, 1.0 - pow(0.0001, delta))
	hips.position = Vector3(sway * 0.5, cfg.hip_h + _hip_y_off, 0.0)
	hips.rotation = Vector3(_lean.x * 0.35, sin(stride_phase * TAU) * 0.10 * moving, sway * 0.6)

	spine.rotation = Vector3(_lean.x * 0.55, -sin(stride_phase * TAU) * 0.09 * moving, -sway * 0.5)
	chest.rotation = Vector3(_lean.x * 0.30 + breathe * 2.0, -sin(stride_phase * TAU) * 0.11 * moving, 0.0)

	# --- legs -------------------------------------------------------------
	if dead_amount < 0.5:
		_animate_legs(delta, speed, stride, moving, on_floor, air_tuck, dodge)

	# --- arms -------------------------------------------------------------
	_animate_arms(delta, stride_phase, moving, on_floor, air_tuck, dodge)

	# --- head -------------------------------------------------------------
	_animate_head(delta)
	# The eyes and lids are HIDDEN at LOD 1, so posing them there is pure waste — and
	# with three dozen rigs in the village it is waste thirty-seven times a frame.
	if _lod <= 0:
		_animate_face(delta)
	_animate_cloth(delta, moving)
	_lod_tick += 1
	if _lod_tick % 8 == 1:
		_update_lod()
	if _lod_tick % 17 == 3:
		_update_grip()

	# --- additive layers ---------------------------------------------------
	if hurt_amount > 0.001:
		var h: float = hurt_amount
		chest.rotation.x -= h * 0.42
		spine.rotation.x -= h * 0.22
		head.rotation.x -= h * 0.30
		hurt_amount = maxf(0.0, hurt_amount - delta * 3.2)
	if dead_amount > 0.001:
		_pose_dead(dead_amount)


func _animate_legs(_delta: float, speed: float, stride: float, moving: float, on_floor: bool, air_tuck: float, dodge: float) -> void:
	var hips_inv := hips.transform.affine_inverse()
	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		var ph: float = fposmod(stride_phase + (0.0 if side == "L" else 0.5), 1.0)

		# Foot target in RIG-LOCAL space. Forward is -Z.
		var fx: float = sx * cfg.hip_w * 1.02
		var fz: float
		var fy: float = 0.0
		if ph < STANCE_FRAC:
			# Planted: slide backwards under the body at the travel speed.
			var t: float = ph / STANCE_FRAC
			fz = lerpf(-stride * 0.5, stride * 0.5, t)
		else:
			# Swing: arc forward and lift.
			var t: float = (ph - STANCE_FRAC) / (1.0 - STANCE_FRAC)
			var e: float = t * t * (3.0 - 2.0 * t)
			fz = lerpf(stride * 0.5, -stride * 0.5, e)
			fy = sin(t * PI) * (0.055 + stride * 0.14)
			if t > 0.5 and _foot_planted[side]:
				_foot_planted[side] = false
			# Report the plant one step later, when it lands.
		if ph < STANCE_FRAC and not _foot_planted[side]:
			_foot_planted[side] = true
			footstep.emit(side, to_global(Vector3(fx, 0, fz)), speed)

		if not on_floor:
			# Tuck in the air, trailing leg lower.
			fz = lerpf(fz, -0.10 + sx * 0.02, air_tuck)
			fy = lerpf(fy, 0.16 + air_tuck * 0.10, air_tuck)
		if dodge > 0.01:
			var d: float = sin(dodge * PI)
			fy = lerpf(fy, 0.30, d)
			fz = lerpf(fz, -0.05, d * 0.6)

		# Conform to the ground under the foot.
		if ground_fn.is_valid() and on_floor and is_inside_tree():
			var wp := to_global(Vector3(fx, 0.0, fz))
			var gy: float = ground_fn.call(wp.x, wp.z)
			fy += clampf(gy - global_position.y, -0.55, 0.55)

		var foot_local := Vector3(fx, fy + 0.055, fz)
		var target_h := hips_inv * foot_local
		var root_h: Vector3 = thigh[side].position
		# Knee points forward (-Z in rig space) and slightly outward.
		var pole := (hips_inv.basis * Vector3(sx * 0.35, 0.0, -1.0)).normalized()
		var knee_p := solve_two_bone(root_h, target_h, cfg.thigh, cfg.shin, pole)

		var fwd_ref: Vector3 = hips_inv.basis * Vector3.FORWARD
		var th_basis := basis_down(knee_p - root_h, fwd_ref)
		thigh[side].basis = th_basis
		var kn_world_basis := basis_down(target_h - knee_p, fwd_ref)
		knee[side].basis = th_basis.inverse() * kn_world_basis
		# Keep the sole roughly level with the ground.
		var ank_basis := basis_down(Vector3.DOWN, fwd_ref)
		ankle[side].basis = kn_world_basis.inverse() * ank_basis
		ankle[side].rotate_object_local(
			Vector3.RIGHT, -0.12 + sin(fposmod(stride_phase + (0.0 if side == "L" else 0.5), 1.0) * TAU) * 0.16 * moving
		)


func _animate_arms(delta: float, phase: float, moving: float, on_floor: bool, air_tuck: float, dodge: float) -> void:
	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		# Arms swing opposite the leg on the same side.
		var ph: float = fposmod(phase + (0.5 if side == "L" else 0.0), 1.0)
		var swing: float = sin(ph * TAU) * (0.28 + moving * 0.52) * moving
		var idle_drift: float = sin(_t * 0.7 + _idle_seed + sx) * 0.035 * (1.0 - moving)

		var sh_rot := Vector3(swing, 0.0, sx * (0.14 + moving * 0.07) + idle_drift)
		var el_rot := Vector3(-0.22 - moving * 0.55 - maxf(0.0, -swing) * 0.6, 0.0, 0.0)
		if not on_floor:
			sh_rot = sh_rot.lerp(Vector3(-0.55, 0.0, sx * 0.55), air_tuck)
			el_rot = el_rot.lerp(Vector3(-1.0, 0.0, 0.0), air_tuck)
		if dodge > 0.01:
			var d: float = sin(dodge * PI)
			sh_rot = sh_rot.lerp(Vector3(-1.5, 0.0, sx * 0.35), d)
			el_rot = el_rot.lerp(Vector3(-2.0, 0.0, 0.0), d)

		# Aiming a bow: left arm extends along the aim, right hand draws to the cheek.
		if aim_weight > 0.001:
			var local_aim: Vector3 = (global_transform.basis.inverse() * aim_dir).normalized()
			var pitch: float = asin(clampf(local_aim.y, -1.0, 1.0))
			if side == "L":
				sh_rot = sh_rot.lerp(Vector3(-PI * 0.5 - pitch, 0.0, 0.30), aim_weight)
				el_rot = el_rot.lerp(Vector3(-0.10, 0.0, 0.0), aim_weight)
			else:
				sh_rot = sh_rot.lerp(Vector3(-PI * 0.42 - pitch * 0.8, 0.0, -1.02), aim_weight)
				el_rot = el_rot.lerp(Vector3(-2.28, 0.0, 0.0), aim_weight)

		# Melee: a diagonal overhead cut with the right arm, left arm counterbalancing.
		if attack_swing > 0.001:
			var a: float = attack_swing
			var wind: float = clampf(a / 0.30, 0.0, 1.0)
			var strike: float = clampf((a - 0.30) / 0.40, 0.0, 1.0)
			var recover: float = clampf((a - 0.70) / 0.30, 0.0, 1.0)
			var arc: float = lerpf(-2.5, 0.75, strike * strike * (3.0 - 2.0 * strike))
			if side == "R":
				sh_rot = sh_rot.lerp(Vector3(arc, -0.35, -0.5), (1.0 - recover) * (0.35 + wind * 0.65))
				el_rot = el_rot.lerp(Vector3(-0.55 - (1.0 - strike) * 1.1, 0.0, 0.0), 1.0 - recover)
			else:
				sh_rot = sh_rot.lerp(Vector3(0.5, 0.0, 0.9), (1.0 - recover) * 0.6)

		var target_sh := Basis.from_euler(sh_rot)
		var target_el := Basis.from_euler(el_rot)
		var k: float = 1.0 - pow(0.00002, delta)
		shoulder[side].basis = shoulder[side].basis.slerp(target_sh, k)
		elbow[side].basis = elbow[side].basis.slerp(target_el, k)


func _animate_head(delta: float) -> void:
	var target := Vector3(sin(_t * 0.53 + _idle_seed) * 0.05, sin(_t * 0.31 + _idle_seed) * 0.10, 0.0)
	if look_weight > 0.001:
		var local := (global_transform.basis.inverse() * (look_target - head.global_position)).normalized()
		var yaw: float = atan2(-local.x, -local.z)
		var pitch: float = asin(clampf(local.y, -1.0, 1.0))
		target = target.lerp(Vector3(-clampf(pitch, -0.6, 0.6), clampf(yaw, -1.1, 1.1), 0.0), look_weight)
	if aim_weight > 0.001:
		var la: Vector3 = (global_transform.basis.inverse() * aim_dir).normalized()
		target = target.lerp(Vector3(-asin(clampf(la.y, -1.0, 1.0)) * 0.8, atan2(-la.x, -la.z) * 0.7, 0.0), aim_weight)
	neck.rotation = neck.rotation.lerp(target * 0.35, 1.0 - pow(0.0001, delta))
	head.rotation = head.rotation.lerp(target * 0.65, 1.0 - pow(0.0001, delta))


func _pose_dead(a: float) -> void:
	var e: float = clampf(a, 0.0, 1.0)
	hips.position.y = lerpf(hips.position.y, 0.22, e)
	hips.rotation = hips.rotation.lerp(Vector3(-1.35, 0.35, 0.25), e)
	spine.rotation = spine.rotation.lerp(Vector3(0.5, 0.0, 0.2), e)
	chest.rotation = chest.rotation.lerp(Vector3(0.35, 0.2, 0.0), e)
	head.rotation = head.rotation.lerp(Vector3(0.5, 0.4, 0.0), e)
	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		thigh[side].basis = thigh[side].basis.slerp(Basis.from_euler(Vector3(-0.7, 0.0, sx * 0.3)), e)
		knee[side].basis = knee[side].basis.slerp(Basis.from_euler(Vector3(1.1, 0.0, 0.0)), e)
		shoulder[side].basis = shoulder[side].basis.slerp(Basis.from_euler(Vector3(0.4, 0.0, sx * 1.1)), e)
		elbow[side].basis = elbow[side].basis.slerp(Basis.from_euler(Vector3(-0.35, 0.0, 0.0)), e)


# ===========================================================================
#  FACE, CLOTH AND LEVEL OF DETAIL
# ===========================================================================
## Blink, and look at what the head is looking at.
##
## A face whose eyes never move is the single loudest "this is a puppet" cue at
## conversation distance, and both halves are nearly free: the lids are two nodes
## rotating about one axis, and the eyes are two nodes taking a clamped aim.
func _animate_face(delta: float) -> void:
	if _lid_up == null:
		return
	# --- blink. Irregular on purpose; a metronome reads as a machine.
	_blink_t -= delta
	if _blink_t <= 0.0 and _blink_a <= 0.0:
		_blink_a = 0.001
		if _blink_left <= 0:
			_blink_left = 2 if _rng.randf() < 0.22 else 1
	if _blink_a > 0.0:
		# 55 ms shut, 95 ms open: a real blink is not symmetric.
		_blink_a += delta * (1.0 / 0.055 if _blink_dir > 0.0 else -(1.0 / 0.095))
		if _blink_a >= 1.0:
			_blink_a = 1.0
			_blink_dir = -1.0
		elif _blink_a <= 0.0:
			_blink_a = 0.0
			_blink_dir = 1.0
			_blink_left -= 1
			_blink_t = 0.09 if _blink_left > 0 else _rng.randf_range(2.1, 6.4)

	# --- gaze. When nothing is being looked at the eyes still drift and flick, which
	# is what a person's do; a dead-ahead stare is the puppet again.
	var want := Vector2.ZERO
	_sac_t -= delta
	if _sac_t <= 0.0:
		_sac_t = _rng.randf_range(1.1, 3.4)
		_sac = Vector2(_rng.randf_range(-0.16, 0.16), _rng.randf_range(-0.09, 0.07))
	if look_weight > 0.001 and head != null:
		var d: Vector3 = (look_target - eye_centre()).normalized()
		var loc: Vector3 = head.global_transform.basis.inverse() * d
		want = Vector2(atan2(-loc.x, -loc.z), asin(clampf(loc.y, -1.0, 1.0))) * look_weight
	want += _sac * (1.0 - clampf(look_weight, 0.0, 1.0) * 0.55)
	want.x = clampf(want.x, -0.42, 0.42)
	want.y = clampf(want.y, -0.28, 0.24)
	_gaze = _gaze.lerp(want, 1.0 - pow(0.00004, delta))
	for side in ["L", "R"]:
		if eye.has(side):
			(eye[side] as Node3D).rotation = Vector3(_gaze.y, _gaze.x, 0.0)

	# Rotating the lid about X sweeps its edge round the eyeball: -0.74 rad takes the
	# upper lid from open to where the two lids meet, +0.34 brings the lower up to it.
	# The upper lid also FOLLOWS the eye down, or a downward glance shows white above.
	_lid_up.rotation.x = -0.74 * _blink_a + _gaze.y * 0.45
	_lid_lo.rotation.x = 0.34 * _blink_a + _gaze.y * 0.16


var _blink_dir: float = 1.0


## World position between the eyes — where a gaze is measured from.
func eye_centre() -> Vector3:
	if eye.has("L") and eye.has("R"):
		return ((eye["L"] as Node3D).global_position + (eye["R"] as Node3D).global_position) * 0.5
	return head.global_position if head != null else global_position


## Cloth lags the body. A spring on the hem's offset, driven by how fast the character
## is travelling and turning, then read out as a rotation about the waist — so the hem
## swings wide on a turn and trails on a sprint, and settles when they stop.
func _animate_cloth(delta: float, moving: float) -> void:
	if delta <= 0.0 or not is_inside_tree():
		return
	var gp := global_position
	var yaw: float = global_transform.basis.get_euler().y
	var lv := Vector3.ZERO
	if _has_prev:
		lv = global_transform.basis.inverse() * ((gp - _prev_gpos) / delta)
		_turn = wrapf(yaw - _prev_yaw, -PI, PI) / delta
	_prev_gpos = gp
	_prev_yaw = yaw
	_has_prev = true

	# The hem wants to be where the body WAS: opposite the travel, and thrown outward
	# on a turn.
	var drive := Vector2(clampf(-lv.x * 0.070 - _turn * 0.055, -0.42, 0.42), clampf(-lv.z * 0.070, -0.42, 0.42))
	_sway_v += (drive - _sway) * (52.0 * delta)
	_sway_v *= pow(0.02, delta)
	_sway += _sway_v * delta

	if skirt_node != null:
		var flap: float = sin(stride_phase * TAU) * 0.055 * moving
		skirt_node.rotation = Vector3(clampf(-_sway.y * 0.85, -0.34, 0.34), 0.0, clampf(_sway.x * 0.85 + flap, -0.34, 0.34))
	if sash_node != null:
		# Lighter cloth: further and quicker, and it flutters with the stride.
		var f2: float = sin(stride_phase * TAU + 1.1) * 0.10 * moving
		sash_node.rotation = Vector3(clampf(-_sway.y * 1.35, -0.48, 0.48), 0.0, clampf(_sway.x * 1.35 + f2, -0.48, 0.48))


## Hands become mittens and the six eye meshes become one dark pair past `lod_near`.
## Characters are the largest single share of this game's draw calls, so the detail a
## conversation needs has to stop being drawn the moment the conversation is over.
func _update_lod() -> void:
	var want := 0
	if is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			want = 0 if global_position.distance_squared_to(cam.global_position) < lod_near * lod_near else 1
	if want != _lod:
		set_lod(want)


func set_lod(level: int) -> void:
	_lod = level
	var near: bool = level == 0
	for side in ["L", "R"]:
		var hd: Node3D = hand.get(side)
		if hd == null:
			continue
		var l0 := hd.get_node_or_null("Lod0")
		var l1 := hd.get_node_or_null("Lod1")
		if l0:
			(l0 as Node3D).visible = near
		if l1:
			(l1 as Node3D).visible = not near
	# The head's LOD pair is found by MATERIAL, not by node name: `_merge_draws` folds
	# the hair, the brows and the beard into one node with a generated name, and the
	# creature system replaces a rakshasa's head meshes outright. A material identity
	# survives both, and anything with a material this rig did not make is left alone.
	if head != null and not _near_mats.is_empty():
		for c in head.get_children():
			if not (c is MeshInstance3D):
				continue
			var m: Material = (c as MeshInstance3D).material_override
			if m == _skin_lod or m == _hair_lod:
				(c as MeshInstance3D).visible = not near
			elif _near_mats.has(m):
				(c as MeshInstance3D).visible = near
	for side in ["L", "R"]:
		if eye.has(side):
			(eye[side] as Node3D).visible = near
	if _lid_up != null:
		_lid_up.visible = near
	if _lid_lo != null:
		_lid_lo.visible = near
	if _eyes_lo != null and is_instance_valid(_eyes_lo):
		_eyes_lo.visible = not near


## Close the hand round whatever it is holding. `grip_l` / `grip_r` override; left at
## -1 the hand simply looks at its own attach point, so picking up a bow closes the
## fist that holds it without anyone having to remember to say so.
func _update_grip() -> void:
	for side in ["L", "R"]:
		var want: int = int(cfg.grip_l if side == "L" else cfg.grip_r)
		if want < 0:
			var at: Node3D = hand_attach.get(side)
			want = MeshKit.Grip.CLOSED if (at != null and at.get_child_count() > 0) else MeshKit.Grip.RELAXED
		if want == int(_grip[side]):
			continue
		_grip[side] = want
		var sx: float = 1.0 if side == "L" else -1.0
		var hl: float = cfg.hand * 1.35
		var hi: MeshInstance3D = _hand_hi.get(side)
		var lo: MeshInstance3D = _hand_lo.get(side)
		if hi != null and is_instance_valid(hi):
			hi.mesh = MeshKit.hand(hl, cfg.build, want, sx, 0)
		if lo != null and is_instance_valid(lo):
			lo.mesh = MeshKit.hand_lod(hl, cfg.build, want, sx)


# ===========================================================================
#  MEASUREMENTS
# ===========================================================================
## What the head actually came out as, measured off the geometry.
##
## This is a contract, not a debug aid: `tests/npc_test.gd` asserts on every number in
## it, because "they have faces now" has been wrong twice in this project — once with
## the features buried inside the skull, once with the hair cap sized so it drew
## entirely inside the head and left twelve villagers bald in seventeen screenshots
## that were signed off as good.
static var _metrics_cache: Dictionary = {}


func face_metrics() -> Dictionary:
	var r: float = cfg.head
	var fp: int = int(cfg.face)
	var key := "%.4f|%d|%d|%.2f" % [r, fp, int(cfg.hair_style), float(cfg.beard_len)]
	var hit: Variant = _metrics_cache.get(key)
	if hit != null:
		return hit
	var p: Dictionary = MeshKit.face_preset(fp)
	var skull: ArrayMesh = MeshKit.head_shell(1.0, fp, 0)
	var hair: ArrayMesh = MeshKit.hair(1.0, fp, int(cfg.hair_style), int(hash(cfg.get("seed", 0)) & 7), 0)
	var sa: AABB = skull.get_aabb()
	var ha: AABB = hair.get_aabb()
	var sk: Vector3 = sa.size * 0.5 * r

	# The eye, against the skull surface AT THE EYE'S OWN X — found by scanning the
	# azimuth, because the displaced surface is not where the base ellipsoid puts it.
	var eye_surf := 0.0
	var best := 1.0e9
	for i in range(24):
		var q := MeshKit.head_surface(MeshKit.EYE_Y, -PI * 0.5 + lerpf(0.05, 1.30, float(i) / 23.0), r, p)
		var d: float = absf(q.x - MeshKit.EYE_X * r)
		if d < best:
			best = d
			eye_surf = q.z
	var eye_front: float = (MeshKit.EYE_Z - MeshKit.EYE_R) * r
	# The nose, against the face immediately under it — how far the tip stands in
	# front of the plane the upper lip sits on, which is what a nose is.
	var tip: float = MeshKit.head_surface(-0.400, -PI * 0.5, r, p).z
	var under: float = MeshKit.head_surface(-0.560, -PI * 0.5, r, p).z
	# The lip, against the skin below it.
	var lip: float = MeshKit.head_surface(-0.700, -PI * 0.5, r, p).z
	var below: float = MeshKit.head_surface(-0.800, -PI * 0.5, r, p).z
	var pos_z: float = minf(sa.position.z, ha.position.z) * r
	var clear: float = MeshKit.hair_clearance(1.0, fp, int(cfg.hair_style), int(hash(cfg.get("seed", 0)) & 7)) * r

	var out := {
		"skull": sk,
		"hair": true,
		"hair_over_x": clear,
		"hair_over_z": clear,
		"eyes": 2,
		"eye_proud": eye_surf - eye_front,
		"nose_proud": under - tip,
		"mouth_proud": below - lip,
		"beard": float(cfg.beard_len) > 0.02,
		"front_z": pos_z,
	}
	_metrics_cache[key] = out
	return out


## Scale the garments to a body that is not Rama's.
##
## The dhoti, its pleat and its waist cord are built at ABSOLUTE sizes — they are
## Rama's, and Rama is 1.80 m. On a 1.09 m child that cloth is a barrel from the ankles
## to the chest. Callers that scale a rig by height call this; nothing else needs to
## know how the garment is put together.
func fit_garments(s: float, child: bool = false) -> void:
	if absf(s - 1.0) < 0.02 and not child:
		return
	if skirt_node != null:
		# A child wears a short wrap, not an ankle-length dhoti.
		skirt_node.scale = Vector3(s, s * (0.58 if child else 1.0), s)
		skirt_node.position = skirt_node.position * s
	if sash_node != null:
		sash_node.scale = Vector3(s, s * (0.70 if child else 0.92), s)
