class_name ProcRig
extends ProcRigMotion
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
##
## The 1,650 lines that used to live here are split by responsibility into a chain of
## classes, each extending the one before, so `rig.animate(...)`, `ProcRig.merge_enabled`
## and `ProcRig.solve_two_bone` all keep working:
##
##   ProcRigBase    config, joints, animation state, material and mesh helpers, merging
##   ProcRigParts   torso, head, eyes, arms, legs
##   ProcRigDress   skirt, sash, jewellery, iconography
##   ProcRigDetail  face, cloth swing, level of detail, grip
##   ProcRigMotion  locomotion, IK, arms, head, additive poses
##   ProcRig        `build()` and the measurements
##
## tests/proc_rig_golden_test.gd pins how every config builds and poses.

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

	_build_pelvis(m_skin, b)
	_build_core(m_skin, m_hair, b, sh_w)

	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		_build_arm(side, sx, b, sh_w, m_skin)
		_build_leg(side, sx, b, m_skin)

	if cfg.dhoti:
		_build_skirt(m_cloth)
	if cfg.sash:
		_build_sash(m_cloth2)
	if cfg.jewellery or bool(cfg.get("channavira", false)) or bool(cfg.get("vanara", false)) or bool(cfg.get("ten_heads", false)):
		_build_jewellery()

	_merge_draws()

	if cfg.has("model") and String(cfg["model"]) != "":
		humanoid_model = HumanoidModel.build(String(cfg["model"]))
		if humanoid_model:
			humanoid_model.rotation.y = PI
			add_child(humanoid_model)
			_hide_procedural_meshes()

	for side in ["L", "R"]:
		_foot_world[side] = _rest_foot(side)

## The hip joint and the pelvis mesh.
func _build_pelvis(m_skin: Material, b: float) -> void:
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


## Spine, chest, neck (with its two cords) and the head, each a joint under the last.
func _build_core(m_skin: Material, m_hair: Material, b: float, sh_w: float) -> void:
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
	# Sternocleidomastoids: the two cords down the front of the neck (-Z).
	for sxx in [-1.0, 1.0]:
		_mesh(
			neck,
			MeshKit.limb(cfg.neck * 0.95, 0.014 * b, 0.019 * b, 1.0, 6),
			m_skin,
			Vector3(sxx * 0.026 * b, 0.004, -0.036 * b),
			Vector3.ONE,
			Vector3(-0.30, 0.0, sxx * 0.24)
		)

	head = Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, cfg.neck, 0)
	neck.add_child(head)
	_build_head(m_skin, m_hair)


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
