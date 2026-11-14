class_name ProcRigDress
extends ProcRigParts
## Part 3 of 6 of ProcRig (see proc_rig.gd): garments and ornament (skirt, sash, jewellery,
## the king's chain, the vanara marks, the ten heads).
## The six parts form one inheritance chain, so every caller still writes `ProcRig.name`.

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
	var b: float = float(cfg.build)
	var r: float = float(cfg.head)
	var yc: float = r * HEAD_C
	if cfg.jewellery:
		# Armlets, a torque and ear studs. Small, but they catch the light and read as
		# deliberate rather than as an unclothed placeholder.
		for side in ["L", "R"]:
			var sh: Node3D = shoulder[side]
			_mesh(sh, MeshKit.tube(0.035, [[0.0, 0.062], [1.0, 0.062]], 12), m, Vector3(0, -cfg.upper_arm * 0.42, 0))
			var el: Node3D = elbow[side]
			_mesh(el, MeshKit.tube(0.022, [[0.0, 0.046], [1.0, 0.046]], 10), m, Vector3(0, -cfg.lower_arm * 0.82, 0))
		_mesh(chest, MeshKit.tube(0.028, [[0.0, 0.085], [1.0, 0.082]], 14, 0.75), m, Vector3(0, cfg.chest * 0.88, 0.01))

	if bool(cfg.get("channavira", false)):
		_build_channavira(m, b, r, yc)
	if bool(cfg.get("vanara", false)):
		_build_vanara_iconography(m, b, r, yc)
	if bool(cfg.get("ten_heads", false)):
		_build_ten_heads(m, r, yc)


func _build_channavira(m_gold: Material, b: float, r: float, yc: float) -> void:
	var c: float = float(cfg.chest)
	var sp: float = float(cfg.spine)
	# Crossed golden warrior bands (Channavira) looping over shoulders and crossing front (-Z) and back (+Z).
	for sx in [-1.0, 1.0]:
		var front_band := PackedVector3Array(
			[
				Vector3(sx * 0.115 * b, c * 0.88, 0.0),
				Vector3(sx * 0.065 * b, c * 0.62, -0.106 * b),
				Vector3(0.0, c * 0.36, -0.116 * b),
				Vector3(-sx * 0.075 * b, 0.04, -0.108 * b),
				Vector3(-sx * 0.125 * b, -sp * 0.55, -0.04 * b),
			]
		)
		var back_band := PackedVector3Array(
			[
				Vector3(sx * 0.115 * b, c * 0.88, 0.0),
				Vector3(sx * 0.065 * b, c * 0.60, 0.104 * b),
				Vector3(0.0, c * 0.34, 0.112 * b),
				Vector3(-sx * 0.075 * b, 0.04, 0.104 * b),
				Vector3(-sx * 0.125 * b, -sp * 0.55, 0.04 * b),
			]
		)
		var rads := PackedFloat32Array([0.011, 0.012, 0.013, 0.012, 0.010])
		_mesh(chest, MeshKit.sweep(front_band, rads, 6, 0.55, Vector3.FORWARD), m_gold, Vector3.ZERO)
		_mesh(chest, MeshKit.sweep(back_band, rads, 6, 0.55, Vector3.BACK), m_gold, Vector3.ZERO)

	# Central Surya-chakra solar disc medallion on the sternum (-Z) + ruby center.
	_mesh(
		chest,
		MeshKit.tube(0.016, [[0.0, 0.038], [0.5, 0.042], [1.0, 0.028]], 14),
		m_gold,
		Vector3(0, c * 0.36, -0.118 * b),
		Vector3.ONE,
		Vector3(-PI * 0.5, 0, 0)
	)
	var m_ruby := Mats.flat(Color(0.88, 0.14, 0.12), 0.20, 0.4)
	_mesh(chest, MeshKit.sphere(0.018, 10, 8), m_ruby, Vector3(0, c * 0.36, -0.124 * b))

	# Yajnopavita: white sacred thread from left shoulder (+X) to right waist (-X).
	var m_thread := Mats.flat(Color(0.96, 0.94, 0.88), 0.65)
	var yajna_path := PackedVector3Array(
		[
			Vector3(0.118 * b, c * 0.90, -0.01 * b),
			Vector3(0.055 * b, c * 0.52, -0.112 * b),
			Vector3(-0.045 * b, 0.08, -0.110 * b),
			Vector3(-0.122 * b, -sp * 0.48, 0.0),
			Vector3(-0.045 * b, 0.08, 0.106 * b),
			Vector3(0.055 * b, c * 0.52, 0.108 * b),
			Vector3(0.118 * b, c * 0.90, -0.01 * b),
		]
	)
	var yajna_r := PackedFloat32Array([0.005, 0.005, 0.005, 0.005, 0.005, 0.005, 0.005])
	_mesh(chest, MeshKit.sweep(yajna_path, yajna_r, 5, 0.8, Vector3.UP), m_thread, Vector3.ZERO)

	# Golden Crown Fillet & Rudraksha ring around the Jata-mukuta topknot on `head`.
	_mesh(
		head,
		MeshKit.tube(r * 0.14, [[0.0, r * 0.78], [0.5, r * 0.81], [1.0, r * 0.77]], 16, 1.15),
		m_gold,
		Vector3(0, yc + r * 0.34, -r * 0.02)
	)
	_mesh(
		head,
		MeshKit.tube(r * 0.12, [[0.0, r * 0.38], [0.5, r * 0.42], [1.0, r * 0.36]], 12),
		m_gold,
		Vector3(0, yc + r * 0.94, r * 0.08)
	)


func _build_vanara_iconography(m_gold: Material, b: float, r: float, yc: float) -> void:
	# Expressive S-curved golden monkey tail attached to `hips`, curving up behind the back (+Z).
	var m_tail := _mat(cfg.skin, Color(cfg.skin_tint) * Color(1.08, 0.92, 0.65))
	var tail_path := PackedVector3Array(
		[
			Vector3(0.0, -0.06, 0.10 * b),
			Vector3(0.0, -0.10, 0.24 * b),
			Vector3(0.02, 0.04, 0.36 * b),
			Vector3(0.04, 0.28, 0.42 * b),
			Vector3(0.02, 0.56, 0.36 * b),
			Vector3(-0.02, 0.78, 0.42 * b),
			Vector3(0.0, 0.88, 0.52 * b),
		]
	)
	var tail_r := PackedFloat32Array([0.032 * b, 0.028 * b, 0.025 * b, 0.022 * b, 0.020 * b, 0.024 * b, 0.012 * b])
	_mesh(hips, MeshKit.sweep(tail_path, tail_r, 8, 1.0, Vector3.UP), m_tail, Vector3.ZERO)
	# Golden tail band near the base and Kundala hoop earrings + Kiritam coronet on head.
	_mesh(
		hips,
		MeshKit.tube(0.028, [[0.0, 0.034 * b], [1.0, 0.034 * b]], 10),
		m_gold,
		Vector3(0, -0.08, 0.16 * b),
		Vector3.ONE,
		Vector3(1.2, 0, 0)
	)
	for sx in [-1.0, 1.0]:
		_mesh(
			head,
			MeshKit.tube(r * 0.08, [[0.0, r * 0.22], [0.5, r * 0.25], [1.0, r * 0.22]], 10),
			m_gold,
			Vector3(sx * r * 0.78, yc - r * 0.12, -r * 0.05),
			Vector3.ONE,
			Vector3(0, 0, PI * 0.5)
		)
	_mesh(
		head,
		MeshKit.tube(r * 0.95, [[0.0, r * 0.76], [0.25, r * 0.68], [0.60, r * 0.44], [0.88, r * 0.20], [1.0, r * 0.04]], 14, 1.10),
		m_gold,
		Vector3(0, yc + r * 0.36, -r * 0.02)
	)


func _build_ten_heads(m_gold: Material, r: float, yc: float) -> void:
	# Regal crescent fan of smaller sculpted dark-indigo heads (4 left, 4 right, 1 high crest) crowned with golden Kirita spires.
	var fan := Node3D.new()
	fan.name = "DasagrivaCrown"
	head.add_child(fan)
	var m_indigo := Mats.flat(Color(0.16, 0.17, 0.28), 0.55)
	var sub_r: float = r * 0.56
	var sub_mesh := MeshKit.head_shell(1.0, int(cfg.face), 1)
	var spire_mesh := MeshKit.tube(
		sub_r * 1.35,
		[[0.0, sub_r * 0.75], [0.35, sub_r * 0.52], [0.75, sub_r * 0.26], [1.0, sub_r * 0.04]],
		10
	)
	for side_sign in [-1.0, 1.0]:
		for idx in range(1, 5):
			var fi := float(idx)
			var ang: float = side_sign * (0.28 * fi)
			var dist: float = r * (0.95 + fi * 0.58)
			var hy: float = yc + r * (0.08 + sin(fi * 0.42) * 0.28)
			var hz: float = r * (0.12 + fi * 0.10)
			var hpos := Vector3(side_sign * dist, hy, hz)
			_mesh(fan, sub_mesh, m_indigo, hpos, Vector3.ONE * sub_r, Vector3(0.0, -ang * 0.55, -side_sign * 0.08 * fi))
			_mesh(fan, spire_mesh, m_gold, hpos + Vector3(0, sub_r * 0.42, 0), Vector3.ONE, Vector3(0.0, -ang * 0.55, -side_sign * 0.08 * fi))
	# High crest 10th head + tall Mukuta spire.
	var crest_pos := Vector3(0.0, yc + r * 1.45, r * 0.08)
	_mesh(fan, sub_mesh, m_indigo, crest_pos, Vector3.ONE * (sub_r * 1.08))
	_mesh(fan, spire_mesh, m_gold, crest_pos + Vector3(0, sub_r * 0.48, 0), Vector3.ONE * 1.18)
	# Main central head golden Kirita crown.
	_mesh(
		fan,
		MeshKit.tube(r * 1.30, [[0.0, r * 0.80], [0.35, r * 0.58], [0.75, r * 0.30], [1.0, r * 0.06]], 14, 1.10),
		m_gold,
		Vector3(0.0, yc + r * 0.38, -r * 0.02)
	)
	_merge_joint(fan)
