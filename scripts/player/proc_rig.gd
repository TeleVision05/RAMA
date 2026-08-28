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
const SNAP := 0.03
const SNAP_KEYS := [
	"height",
	"hip_h",
	"thigh",
	"shin",
	"foot",
	"spine",
	"chest",
	"neck",
	"head",
	"shoulder_w",
	"upper_arm",
	"lower_arm",
	"hand",
	"hip_w"
]


func _quantise() -> void:
	for k in SNAP_KEYS:
		if cfg.has(k):
			cfg[k] = snappedf(float(cfg[k]), SNAP)
	cfg["build"] = snappedf(float(cfg.get("build", 1.0)), 0.05)


func build() -> void:
	_quantise()
	_rng.seed = hash(cfg.get("seed", 0))
	_idle_seed = _rng.randf() * 100.0
	var b: float = cfg.build

	var m_skin := _mat(cfg.skin, cfg.skin_tint)
	var m_cloth := _mat(cfg.cloth, cfg.cloth_tint)
	var m_cloth2 := _mat(cfg.cloth2, Color(1, 1, 1))
	var m_hair := StandardMaterial3D.new()
	m_hair.albedo_color = cfg.hair_color
	m_hair.roughness = 0.62

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
	# One torso shell from waist to shoulders. A ribcage is an ELLIPTICAL, tapering
	# form; the earlier single ovoid read as a barrel and swallowed the neck.
	_mesh(
		chest,
		(
			MeshKit
			. profile_loft(
				cfg.spine + cfg.chest,
				[
					[0.00, 0.118 * b, 0.090 * b],
					[0.16, 0.128 * b, 0.096 * b],
					[0.38, 0.148 * b, 0.104 * b],
					[0.60, 0.163 * b, 0.108 * b],
					[0.78, 0.166 * b, 0.104 * b],
					[0.92, 0.152 * b, 0.094 * b],
					[1.00, 0.120 * b, 0.078 * b],
				],
				18
			)
		),
		m_skin,
		Vector3(0, -cfg.spine, 0)
	)
	# Pectoral and trapezius suggestion, so the chest is not a smooth shell.
	for sxx in [-1.0, 1.0]:
		_mesh(
			chest,
			MeshKit.ovoid(0.070 * b, 0.10, 0.5, 10, 7),
			m_skin,
			Vector3(sxx * 0.072 * b, cfg.chest * 0.46, 0.082 * b),
			Vector3(1.15, 1.0, 0.55)
		)
		_mesh(
			chest,
			MeshKit.ovoid(0.062 * b, 0.12, 0.5, 10, 7),
			m_skin,
			Vector3(sxx * 0.105 * b, cfg.chest * 0.80, -0.010 * b),
			Vector3(1.2, 1.0, 0.9)
		)

	neck = Node3D.new()
	neck.name = "Neck"
	neck.position = Vector3(0, cfg.chest * 0.92, 0)
	chest.add_child(neck)
	_mesh(neck, MeshKit.limb(cfg.neck, 0.052 * b, 0.062 * b, 1.0, 10), m_skin, Vector3.ZERO)

	head = Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, cfg.neck, 0)
	neck.add_child(head)
	_build_head(m_skin, m_hair)

	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		_build_arm(side, sx, b, m_skin)
		_build_leg(side, sx, b, m_skin)

	if cfg.dhoti:
		_build_dhoti(m_cloth)
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


func _build_head(m_skin: Material, m_hair: Material) -> void:
	var r: float = cfg.head
	_mesh(head, MeshKit.ovoid(r, r * 2.25, 0.42, 16, 12), m_skin, Vector3(0, r * 0.92, 0), Vector3(0.92, 1.0, 1.0))
	# Brow and jaw give the profile some structure instead of a bare egg.
	_mesh(
		head,
		MeshKit.ovoid(r * 0.80, r * 0.62, 0.5, 12, 8),
		m_skin,
		Vector3(0, r * 1.28, r * 0.30),
		Vector3(1.05, 0.6, 0.75)
	)
	_mesh(
		head,
		MeshKit.ovoid(r * 0.72, r * 0.72, 0.4, 12, 8),
		m_skin,
		Vector3(0, r * 0.60, r * 0.24),
		Vector3(1.0, 0.85, 0.85)
	)
	# Nose.
	_mesh(
		head,
		MeshKit.ovoid(r * 0.20, r * 0.46, 0.35, 8, 6),
		m_skin,
		Vector3(0, r * 0.95, r * 0.80),
		Vector3(0.8, 1.0, 0.9)
	)
	# Eyes: dark inset spheres, then a bright iris highlight. Cheap but they read.
	var m_eye := StandardMaterial3D.new()
	m_eye.albedo_color = Color(0.86, 0.83, 0.78)
	m_eye.roughness = 0.20
	var m_iris := StandardMaterial3D.new()
	m_iris.albedo_color = Color(0.09, 0.055, 0.04)
	m_iris.roughness = 0.10
	var m_socket := StandardMaterial3D.new()
	m_socket.albedo_color = Color(0.22, 0.14, 0.11)
	m_socket.roughness = 0.55
	# Eyes sit IN the skull, not on it, and the iris covers most of the visible sclera.
	# At conversation distance the earlier version read as googly: too large, too far
	# proud of the face, and too much white around a small pupil.
	for sx in [-1.0, 1.0]:
		# Socket: a darker recess so the eye is not a bright dot on flat skin.
		_mesh(
			head,
			MeshKit.sphere(r * 0.135, 10, 8),
			m_socket,
			Vector3(sx * r * 0.35, r * 1.04, r * 0.615),
			Vector3(1.15, 0.78, 0.6)
		)
		_mesh(
			head,
			MeshKit.sphere(r * 0.108, 10, 8),
			m_eye,
			Vector3(sx * r * 0.35, r * 1.04, r * 0.640),
			Vector3(1.1, 0.80, 0.55)
		)
		_mesh(
			head,
			MeshKit.sphere(r * 0.072, 8, 6),
			m_iris,
			Vector3(sx * r * 0.35, r * 1.035, r * 0.690),
			Vector3(1, 1, 0.5)
		)
		# Brow ridge over each eye.
		_mesh(
			head,
			MeshKit.ovoid(r * 0.26, r * 0.16, 0.5, 8, 6),
			m_skin,
			Vector3(sx * r * 0.36, r * 1.24, r * 0.60),
			Vector3(1.25, 1.0, 0.7)
		)

	# Hair: a skull cap plus, for Rama and the ascetics, a jata (topknot).
	_mesh(
		head,
		MeshKit.ovoid(r * 1.04, r * 1.90, 0.40, 16, 10),
		m_hair,
		Vector3(0, r * 1.16, -r * 0.10),
		Vector3(0.99, 1.0, 1.03)
	)
	if cfg.topknot:
		# Jata: a compact coil set back on the crown, not a chef's hat.
		_mesh(
			head,
			MeshKit.ovoid(r * 0.36, r * 0.52, 0.5, 10, 8),
			m_hair,
			Vector3(0, r * 2.06, -r * 0.30),
			Vector3(1.1, 1.0, 1.0)
		)
		_mesh(
			head,
			MeshKit.tube(r * 0.30, [[0.0, r * 0.30], [1.0, r * 0.22]], 10),
			m_hair,
			Vector3(0, r * 1.86, -r * 0.30)
		)
	if cfg.beard:
		# Under the jaw, not across the mouth: the earlier placement read as a dark band.
		_mesh(
			head,
			MeshKit.ovoid(r * 0.50, r * 0.86, 0.30, 12, 8),
			m_hair,
			Vector3(0, r * 0.22, r * 0.26),
			Vector3(1.05, 1.0, 0.82)
		)
	if cfg.horns:
		var m_horn := StandardMaterial3D.new()
		m_horn.albedo_color = Color(0.14, 0.12, 0.12)
		m_horn.roughness = 0.5
		for sx in [-1.0, 1.0]:
			var h := MeshKit.tube(
				r * 1.5,
				[[0.0, r * 0.20], [0.5, r * 0.13], [1.0, r * 0.03]],
				8,
				1.0,
				Vector3(sx * r * 0.5, 0, -r * 0.35)
			)
			_mesh(head, h, m_horn, Vector3(sx * r * 0.62, r * 1.55, -r * 0.10))


func _build_arm(side: String, sx: float, b: float, m_skin: Material) -> void:
	var sh := Node3D.new()
	sh.name = "Shoulder" + side
	sh.position = Vector3(sx * cfg.shoulder_w, cfg.chest * 0.72, 0)
	chest.add_child(sh)
	shoulder[side] = sh
	_mesh(sh, MeshKit.sphere(0.072 * b, 10, 8), m_skin, Vector3.ZERO)
	_mesh(sh, _down(MeshKit.limb(cfg.upper_arm, 0.052 * b, 0.068 * b, 1.06, 10)), m_skin, Vector3.ZERO)

	var el := Node3D.new()
	el.name = "Elbow" + side
	el.position = Vector3(0, -cfg.upper_arm, 0)
	sh.add_child(el)
	elbow[side] = el
	_mesh(el, MeshKit.sphere(0.050 * b, 8, 6), m_skin, Vector3.ZERO)
	_mesh(el, _down(MeshKit.limb(cfg.lower_arm, 0.040 * b, 0.052 * b, 1.04, 10)), m_skin, Vector3.ZERO)

	var hd := Node3D.new()
	hd.name = "Hand" + side
	hd.position = Vector3(0, -cfg.lower_arm, 0)
	el.add_child(hd)
	hand[side] = hd
	_mesh(
		hd,
		MeshKit.ovoid(0.048 * b, cfg.hand, 0.45, 8, 6),
		m_skin,
		Vector3(0, -cfg.hand * 0.5, 0),
		Vector3(0.75, 1.0, 1.0)
	)
	var at := Node3D.new()
	at.name = "Attach" + side
	at.position = Vector3(0, -cfg.hand * 0.55, 0.02)
	hd.add_child(at)
	hand_attach[side] = at


func _build_leg(side: String, sx: float, b: float, m_skin: Material) -> void:
	var th := Node3D.new()
	th.name = "Thigh" + side
	th.position = Vector3(sx * cfg.hip_w, -0.03, 0)
	hips.add_child(th)
	thigh[side] = th
	_mesh(th, _down(MeshKit.limb(cfg.thigh, 0.070 * b, 0.098 * b, 1.10, 12)), m_skin, Vector3.ZERO)

	var kn := Node3D.new()
	kn.name = "Knee" + side
	kn.position = Vector3(0, -cfg.thigh, 0)
	th.add_child(kn)
	knee[side] = kn
	_mesh(kn, MeshKit.sphere(0.060 * b, 8, 6), m_skin, Vector3.ZERO)
	_mesh(kn, _down(MeshKit.limb(cfg.shin, 0.046 * b, 0.072 * b, 1.06, 10)), m_skin, Vector3.ZERO)

	var an := Node3D.new()
	an.name = "Ankle" + side
	an.position = Vector3(0, -cfg.shin, 0)
	kn.add_child(an)
	ankle[side] = an
	# Foot: a flattened wedge, longer forward than back.
	_mesh(
		an,
		MeshKit.ovoid(0.058 * b, cfg.foot, 0.55, 8, 6),
		m_skin,
		Vector3(0, -0.028, cfg.foot * 0.20),
		Vector3(0.85, 0.42, 1.0),
		Vector3(PI * 0.5, 0, 0)
	)


func _build_dhoti(m_cloth: Material) -> void:
	# A wrapped lower garment: a tapered skirt from the waist to mid-calf, with a
	# front pleat panel. Built as geometry rather than a texture so it silhouettes.
	# A wrapped dhoti falls close to the leg and reaches mid-calf; the earlier version
	# flared like a cone and read as a separate object floating at the waist.
	# The wrap must clear the LEGS. Thighs sit at x = +/-0.11 with a radius near 0.108,
	# so anything under about 0.22 lets them poke through and the garment reads as a
	# flat panel down the front instead of a skirt. Measured, not guessed.
	var skirt := (
		MeshKit
		. profile_loft(
			0.66,
			[
				[0.00, 0.176, 0.150],
				[0.14, 0.198, 0.170],
				[0.42, 0.222, 0.190],
				[0.72, 0.234, 0.200],
				[0.93, 0.238, 0.204],
				[1.00, 0.230, 0.196],
			],
			20
		)
	)
	var mi := _mesh(hips, _down(skirt), m_cloth, Vector3(0, 0.050, 0))
	mi.name = "Dhoti"
	# The kachcha: the pleated fold tucked at the front. It HANGS, so it needs the same
	# flip as the wrap — without it the panel grew upward across the chest.
	_mesh(
		hips,
		_down(
			(
				MeshKit
				. profile_loft(
					0.60,
					[
						[0.0, 0.056, 0.026],
						[0.5, 0.070, 0.030],
						[1.0, 0.064, 0.026],
					],
					10
				)
			)
		),
		m_cloth,
		Vector3(0, 0.03, 0.150)
	)
	# Waist cord.
	_mesh(hips, MeshKit.tube(0.026, [[0.0, 0.182], [1.0, 0.182]], 18, 0.85), m_cloth, Vector3(0, 0.042, 0))


func _build_sash(m: Material) -> void:
	# Uttariya: a cloth over the left shoulder, crossing the chest.
	var band := MeshKit.quad(0.115, 0.60, true)
	_mesh(chest, band, m, Vector3(0.055, cfg.chest * 0.80, 0.085), Vector3(1, 1, 1), Vector3(0.1, 0.0, -0.42))
	_mesh(chest, band, m, Vector3(-0.05, cfg.chest * 0.80, -0.085), Vector3(1, 1, 1), Vector3(-0.1, PI, -0.42))


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
	_hip_y_off = lerpf(
		_hip_y_off, bob + breathe - air_tuck * 0.06 - st.get("crouch", 0.0) * 0.26, 1.0 - pow(0.0001, delta)
	)
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

	# --- additive layers ---------------------------------------------------
	if hurt_amount > 0.001:
		var h: float = hurt_amount
		chest.rotation.x -= h * 0.42
		spine.rotation.x -= h * 0.22
		head.rotation.x -= h * 0.30
		hurt_amount = maxf(0.0, hurt_amount - delta * 3.2)
	if dead_amount > 0.001:
		_pose_dead(dead_amount)


func _animate_legs(
	_delta: float, speed: float, stride: float, moving: float, on_floor: bool, air_tuck: float, dodge: float
) -> void:
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
		if ground_fn.is_valid() and on_floor:
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
