class_name BeastRig
extends Node3D
## A procedurally built, procedurally animated QUADRUPED predator.
##
## The humanoid ProcRig cannot be bent into a cat: a tiger's spine is horizontal, its
## front and hind limbs fold in OPPOSITE directions, and its gait is a diagonal trot,
## not an alternating biped stride. So the body is built here from MeshKit primitives
## and posed from scratch every frame, exactly like ProcRig does for people.
##
## What IS reused is ProcRig's two-bone IK and its "aim a limb down this vector"
## basis helper, both static — so paws PLANT on the terrain and do not skate, by the
## same maths that makes Rama's feet plant.

# --- proportions (metres) --------------------------------------------------
const BODY_L := 1.32  # chest to rump
const BODY_H := 0.74  # belly height at rest
const F_UP := 0.42  # front upper limb (scapula -> elbow)
const F_LO := 0.40  # front lower limb (elbow -> paw)
const H_UP := 0.47  # hind upper (hip -> stifle)
const H_LO := 0.45  # hind lower (stifle -> paw)
const NECK_L := 0.34
const STRIDE_LEN := 1.55  # metres travelled per full gait cycle
const STANCE := 0.56  # fraction of the cycle a paw is planted

# Front pair first. A trot moves diagonal pairs together, so FL and BR share a phase.
const LEG_PH := [0.0, 0.5, 0.5, 0.0]
const LEG_X := [-0.165, 0.165, -0.185, 0.185]
const LEG_Z := [-0.47, -0.47, 0.45, 0.45]
const SOCKET_Y := [0.02, 0.02, 0.085, 0.085]
const LEG_NAME := ["FL", "FR", "BL", "BR"]

# --- joints ----------------------------------------------------------------
var body: Node3D
var neck: Node3D
var head: Node3D
var jaw: Node3D
var tail: Array[Node3D] = []
var upper: Array[Node3D] = []
var lower: Array[Node3D] = []
var paw: Array[Node3D] = []

# --- animation state -------------------------------------------------------
var ground_fn: Callable = Callable()
var look_target: Vector3 = Vector3.ZERO
var look_weight: float = 0.0
## -1 = gathered on the haunches ready to spring, 0 = neutral, +1 = fully extended
## mid-pounce. A cat does both halves of a lunge and they are opposite shapes; one
## value that only went one way could only ever show half of it.
var lunge: float = 0.0
var maw: float = 0.0  # 0..1 jaw open
var hurt_amount: float = 0.0
var dead_amount: float = 0.0
var stride_phase: float = 0.0

var _t: float = 0.0
var _breath: float = 0.0
var _planted := [true, true, true, true]
var _seed: float = 0.0
var _coat_tint: Color = Color(1, 1, 1)

signal footstep(side: String, position: Vector3, speed: float)

static var _coat_tex: ImageTexture = null


func configure(over: Dictionary) -> void:
	_coat_tint = over.get("tint", _coat_tint)
	_seed = float(over.get("seed", 0)) * 0.37


# ===========================================================================
#  BUILD
# ===========================================================================
func build() -> void:
	var m_coat := _coat_material(_coat_tint)
	var m_dark := Mats.flat(_coat_tint * Color(0.24, 0.18, 0.15), 0.7)
	var m_claw := Mats.flat(Color(0.12, 0.11, 0.10), 0.35, 0.2)
	# The coat texture fades toward cream at the extremes of its U axis, which is
	# meant to put a pale belly on the torso loft — but every OTHER part of the
	# animal (jaw, cheeks, paws, throat) gets its own small loft with its own U
	# wrap, so the fade lands wherever that part's seam happens to be. Judged from
	# build/screenshots/enemy_10_beast_idle.png on 2026-08-28 the result was a
	# uniformly orange animal: stripes and nothing else. A tiger is not read from
	# its stripes, it is read from the white — muzzle, cheeks, throat, belly, paws.
	# Those are geometry here, so they get a material rather than a UV.
	var m_pale := Mats.flat(_coat_tint * Color(0.90, 0.84, 0.76), 0.85)

	body = Node3D.new()
	body.name = "Body"
	body.position = Vector3(0, BODY_H, 0)
	add_child(body)

	# Torso. profile_loft runs along +Y, so it is rotated a quarter turn about X to
	# lie along +Z; that is a PROPER rotation, so the clockwise winding survives.
	# (Mirroring instead would turn the whole animal inside out.)
	_mesh(
		body,
		(
			MeshKit
			. profile_loft(
				BODY_L,
				[
					[0.00, 0.158, 0.170],
					[0.10, 0.206, 0.222],
					[0.30, 0.214, 0.226],
					[0.55, 0.188, 0.190],
					[0.78, 0.206, 0.208],
					[0.92, 0.184, 0.184],
					[1.00, 0.146, 0.146],
				],
				16
			)
		),
		m_coat,
		Vector3(0, 0.0, -BODY_L * 0.5),
		Vector3.ONE,
		Vector3(PI * 0.5, 0, 0)
	)

	# Shoulder and haunch bulk, so the silhouette is muscled rather than a sausage.
	for sx in [-1.0, 1.0]:
		_mesh(
			body,
			MeshKit.ovoid(0.132, 0.34, 0.5, 10, 8),
			m_coat,
			Vector3(sx * 0.128, -0.035, -BODY_L * 0.36),
			Vector3(0.78, 1.15, 1.0),
			Vector3(PI * 0.5, 0, 0)
		)
		_mesh(
			body,
			MeshKit.ovoid(0.150, 0.38, 0.5, 10, 8),
			m_coat,
			Vector3(sx * 0.136, -0.010, BODY_L * 0.35),
			Vector3(0.80, 1.15, 1.0),
			Vector3(PI * 0.5, 0, 0)
		)

	# Pale belly: a flattened slab under the ribs, inset so the flank keeps its
	# stripes and only the underside reads cream from a low angle.
	_mesh(
		body,
		(
			MeshKit
			. profile_loft(
				BODY_L * 0.76,
				[
					[0.00, 0.120, 0.070],
					[0.25, 0.160, 0.082],
					[0.75, 0.158, 0.080],
					[1.00, 0.112, 0.062],
				],
				12
			)
		),
		m_pale,
		Vector3(0, -0.088, -BODY_L * 0.36),
		Vector3.ONE,
		Vector3(PI * 0.5, 0, 0)
	)
	# Throat, running up under the jaw.
	_mesh(
		body,
		MeshKit.ovoid(0.105, 0.30, 0.5, 10, 7),
		m_pale,
		Vector3(0, -0.020, -BODY_L * 0.56),
		Vector3(0.86, 1.0, 1.0),
		Vector3(PI * 0.5, 0, 0)
	)

	_build_neck_and_head(m_coat, m_dark, m_claw, m_pale)
	_build_tail(m_coat)

	for i in range(4):
		_build_leg(i, m_coat, m_claw, m_pale)


func _build_neck_and_head(m_coat: Material, m_dark: Material, m_claw: Material, m_pale: Material) -> void:
	neck = Node3D.new()
	neck.name = "Neck"
	neck.position = Vector3(0, 0.075, -BODY_L * 0.50)
	body.add_child(neck)
	# Rotated the other quarter turn so the loft runs FORWARD (-Z).
	_mesh(
		neck,
		(
			MeshKit
			. profile_loft(
				NECK_L,
				[
					[0.0, 0.150, 0.145],
					[0.5, 0.132, 0.128],
					[1.0, 0.110, 0.108],
				],
				12
			)
		),
		m_coat,
		Vector3.ZERO,
		Vector3.ONE,
		Vector3(-PI * 0.5, 0, 0)
	)

	head = Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, -0.01, -NECK_L)
	neck.add_child(head)

	# Skull: broad and short, laid along -Z.
	_mesh(
		head,
		MeshKit.ovoid(0.140, 0.29, 0.45, 14, 10),
		m_coat,
		Vector3(0, 0.005, -0.07),
		Vector3(1.08, 0.94, 1.0),
		Vector3(-PI * 0.5, 0, 0)
	)
	# Muzzle: white, which with the cheeks is most of what says "tiger" at a glance.
	_mesh(
		head,
		MeshKit.ovoid(0.092, 0.17, 0.5, 10, 8),
		m_pale,
		Vector3(0, -0.024, -0.200),
		Vector3(1.10, 0.86, 1.0),
		Vector3(-PI * 0.5, 0, 0)
	)
	# The dark brow band above the eyes, so the face has a line to read across it and
	# the skull does not render as one smooth egg.
	_mesh(
		head,
		MeshKit.ovoid(0.122, 0.050, 0.5, 10, 5),
		m_dark,
		Vector3(0, 0.082, -0.112),
		Vector3(1.0, 0.55, 1.0),
		Vector3(-PI * 0.5, 0, 0)
	)
	# Nose leather.
	_mesh(head, MeshKit.sphere(0.028, 8, 6), m_dark, Vector3(0, -0.005, -0.255), Vector3(1.1, 0.8, 0.7))
	# Cheek ruffs — the wide-faced tiger read.
	for sx in [-1.0, 1.0]:
		# Set LOW and inboard. At the size they were first built the two pale ruffs met
		# above the muzzle and swallowed the eyes and the brow band with them: seen
		# head-on the tiger was two white pom-poms with a nose between them
		# (build/screenshots/enemy_10_beast_idle.png, 2026-08-28). A ruff frames the
		# face; it is not the face.
		_mesh(
			head,
			MeshKit.ovoid(0.056, 0.118, 0.5, 8, 6),
			m_pale,
			Vector3(sx * 0.100, -0.062, -0.098),
			Vector3(0.86, 1.0, 1.15),
			Vector3(-PI * 0.5, 0, 0)
		)
		# Ears: small rounded triangles set wide.
		_mesh(
			head,
			MeshKit.ovoid(0.062, 0.098, 0.6, 8, 6),
			m_coat,
			Vector3(sx * 0.098, 0.118, 0.005),
			Vector3(1.0, 1.0, 0.40),
			Vector3(-0.20, 0.0, sx * -0.34)
		)
		_mesh(
			head,
			MeshKit.ovoid(0.040, 0.062, 0.6, 6, 5),
			m_dark,
			Vector3(sx * 0.104, 0.126, -0.012),
			Vector3(1.0, 1.0, 0.28),
			Vector3(-0.20, 0.0, sx * -0.34)
		)

	# Eyes: amber, faintly self-lit, so the animal reads as a predator at dusk.
	var m_eye := StandardMaterial3D.new()
	m_eye.albedo_color = Color(0.92, 0.66, 0.16)
	m_eye.emission_enabled = true
	m_eye.emission = Color(0.85, 0.48, 0.08)
	m_eye.emission_energy_multiplier = 0.55
	m_eye.roughness = 0.15
	var m_pupil := Mats.flat(Color(0.04, 0.03, 0.03), 0.1)
	for sx in [-1.0, 1.0]:
		# Bigger and set further out on the skull, now that the ruffs are not covering
		# them. A predator is read from its eyes at forty metres and from nothing else.
		_mesh(head, MeshKit.sphere(0.034, 8, 6), m_eye, Vector3(sx * 0.068, 0.038, -0.132))
		_mesh(head, MeshKit.sphere(0.019, 6, 5), m_pupil, Vector3(sx * 0.070, 0.038, -0.160), Vector3(0.5, 1.4, 1.0))

	jaw = Node3D.new()
	jaw.name = "Jaw"
	jaw.position = Vector3(0, -0.035, -0.075)
	head.add_child(jaw)
	_mesh(
		jaw,
		MeshKit.ovoid(0.062, 0.17, 0.5, 8, 6),
		m_pale,
		Vector3(0, -0.022, -0.070),
		Vector3(1.0, 0.55, 1.0),
		Vector3(-PI * 0.5, 0, 0)
	)
	# Canines: two down from the skull, two up from the jaw.
	for sx in [-1.0, 1.0]:
		_mesh(
			head,
			MeshKit.tube(0.052, [[0.0, 0.011], [0.6, 0.008], [1.0, 0.001]], 6),
			m_claw,
			Vector3(sx * 0.040, -0.052, -0.196),
			Vector3.ONE,
			Vector3(PI, 0.0, 0.0)
		)
		_mesh(
			jaw,
			MeshKit.tube(0.036, [[0.0, 0.009], [0.6, 0.006], [1.0, 0.001]], 6),
			m_claw,
			Vector3(sx * 0.038, -0.030, -0.180)
		)


func _build_tail(m_coat: Material) -> void:
	var parent: Node3D = body
	var pos := Vector3(0, 0.055, BODY_L * 0.50)
	for i in range(5):
		var seg := Node3D.new()
		seg.name = "Tail%d" % i
		seg.position = pos
		parent.add_child(seg)
		var r0: float = lerpf(0.042, 0.020, float(i) / 5.0)
		var r1: float = lerpf(0.042, 0.020, float(i + 1) / 5.0)
		_mesh(
			seg,
			MeshKit.tube(0.20, [[0.0, r0], [1.0, r1]], 8),
			m_coat,
			Vector3.ZERO,
			Vector3.ONE,
			Vector3(PI * 0.5, 0, 0)
		)
		tail.append(seg)
		parent = seg
		pos = Vector3(0, 0, 0.20)


func _build_leg(i: int, m_coat: Material, m_claw: Material, m_pale: Material) -> void:
	var front: bool = i < 2
	var l1: float = F_UP if front else H_UP
	var l2: float = F_LO if front else H_LO
	# A tiger's forelegs are its weapons; thin ones read as a deer.
	var thick: float = 0.088 if front else 0.094

	var up := Node3D.new()
	up.name = "Upper" + LEG_NAME[i]
	up.position = Vector3(LEG_X[i], SOCKET_Y[i], LEG_Z[i])
	body.add_child(up)
	# Limbs are built along +Y then turned a half-turn about X so they HANG. A half
	# turn is a proper rotation, so no winding flip and no invisible legs.
	_mesh(
		up, MeshKit.limb(l1, thick * 0.70, thick * 1.55, 1.10, 8), m_coat, Vector3.ZERO, Vector3.ONE, Vector3(PI, 0, 0)
	)

	var lo := Node3D.new()
	lo.name = "Lower" + LEG_NAME[i]
	lo.position = Vector3(0, -l1, 0)
	up.add_child(lo)
	_mesh(
		lo, MeshKit.limb(l2, thick * 0.48, thick * 0.82, 1.06, 8), m_coat, Vector3.ZERO, Vector3.ONE, Vector3(PI, 0, 0)
	)

	var pw := Node3D.new()
	pw.name = "Paw" + LEG_NAME[i]
	pw.position = Vector3(0, -l2, 0)
	lo.add_child(pw)
	_mesh(
		pw,
		MeshKit.ovoid(0.058, 0.115, 0.5, 8, 6),
		m_pale,
		Vector3(0, -0.024, -0.018),
		Vector3(1.0, 0.55, 1.0),
		Vector3(PI * 0.5, 0, 0)
	)
	for c in range(3):
		var a: float = -0.030 + 0.030 * float(c)
		_mesh(
			pw,
			MeshKit.tube(0.030, [[0.0, 0.006], [1.0, 0.001]], 5),
			m_claw,
			Vector3(a, -0.036, -0.066),
			Vector3.ONE,
			Vector3(-2.2, 0, 0)
		)

	upper.append(up)
	lower.append(lo)
	paw.append(pw)


# --- material --------------------------------------------------------------
## The coat is synthesised, like every other texture in this project. Bands run
## across the V axis, which the lofts map along the length of the body, so the
## stripes wrap the ribs the way a tiger's do instead of running down the spine.
static func coat_texture() -> ImageTexture:
	if _coat_tex != null:
		return _coat_tex
	var w := 128
	var img := Image.create(w, w, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x54_49_47_52  # "TIGR"
	var base := Color(0.760, 0.395, 0.118)
	var pale := Color(0.905, 0.800, 0.660)
	for y in range(w):
		for x in range(w):
			var fx := float(x)
			var fy := float(y)
			# Grain.
			var n: float = sin(fx * 0.42 + fy * 0.11) * 0.030 + cos(fy * 0.77) * 0.026
			n += sin((fx + fy) * 0.19) * 0.022
			# Pale flanks: the U axis wraps around the body, so its extremes are the
			# belly. Fade toward cream there.
			var belly: float = pow(absf(fx / float(w) - 0.5) * 2.0, 2.4)
			var c: Color = base.lerp(pale, belly * 0.72)
			c = Color(clampf(c.r * (1.0 + n), 0, 1), clampf(c.g * (1.0 + n), 0, 1), clampf(c.b * (1.0 + n), 0, 1))
			img.set_pixel(x, y, c)
	# Stripes: wavy vertical-in-world bands, i.e. constant-V rows, with forked ends.
	var dark := Color(0.085, 0.062, 0.052)
	var stripes := 13
	for s in range(stripes):
		var cy: float = (float(s) + 0.5) * (float(w) / float(stripes)) + rng.randf_range(-3.0, 3.0)
		var thick: float = rng.randf_range(2.2, 4.6)
		var amp: float = rng.randf_range(1.5, 4.5)
		var freq: float = rng.randf_range(0.03, 0.075)
		var reach: float = rng.randf_range(0.24, 0.46)  # how far around the body
		for x in range(w):
			var fx := float(x)
			var off: float = sin(fx * freq + float(s)) * amp
			# Taper the stripe out toward the belly.
			var dcen: float = absf(fx / float(w) - 0.5) * 2.0
			if dcen > reach + 0.42:
				continue
			var fade: float = clampf((reach + 0.42 - dcen) / 0.30, 0.0, 1.0)
			var half: float = thick * fade
			for dy in range(-6, 7):
				var yy: float = cy + off + float(dy)
				var d: float = absf(float(dy))
				if d > half:
					continue
				var k: float = clampf(1.0 - d / maxf(half, 0.001), 0.0, 1.0)
				var px := int(fposmod(yy, float(w)))
				var cur: Color = img.get_pixel(x, px)
				img.set_pixel(x, px, cur.lerp(dark, k * 0.95))
	_coat_tex = ImageTexture.create_from_image(img)
	return _coat_tex


static func _coat_material(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = coat_texture()
	m.albedo_color = tint
	m.roughness = 0.82
	m.metallic = 0.0
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
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
	parent.add_child(mi)
	return mi


func shoulder_height() -> float:
	return BODY_H + 0.21


# ===========================================================================
#  ANIMATION
# ===========================================================================
func animate(delta: float, st: Dictionary) -> void:
	_t += delta
	var speed: float = st.get("speed", 0.0)
	var on_floor: bool = st.get("on_floor", true)
	var moving: float = clampf(speed / 2.2, 0.0, 1.0)

	if on_floor and speed > 0.15:
		stride_phase = fposmod(stride_phase + (speed / STRIDE_LEN) * delta, 1.0)
	else:
		stride_phase = lerpf(stride_phase, roundf(stride_phase * 2.0) * 0.5, 1.0 - pow(0.002, delta))
	_breath += delta * lerpf(1.1, 3.4, moving)

	var stride: float = clampf(speed * 0.30, 0.0, 0.62)
	var bob: float = sin(stride_phase * TAU * 2.0) * 0.026 * moving
	var roll: float = sin(stride_phase * TAU) * 0.055 * moving
	var breathe: float = sin(_breath) * 0.010 * (1.0 - moving * 0.6)

	# The two halves of a lunge. Gathering drops the chest and draws every paw in
	# under the belly; the spring throws the chest up and the forelegs out. Rearing
	# nose-down was the previous version's mistake — that is a cat falling over, not
	# a cat about to hit you.
	var crouch: float = clampf(-lunge, 0.0, 1.0)
	var reach: float = clampf(lunge, 0.0, 1.0)
	var dead: float = clampf(dead_amount, 0.0, 1.0)

	body.position = Vector3(0.0, BODY_H + bob + breathe - crouch * 0.17 + reach * 0.11 - dead * (BODY_H - 0.24), 0.0)
	body.rotation = Vector3(
		-0.035 * moving - crouch * 0.10 + reach * 0.34 + hurt_amount * 0.12,
		sin(stride_phase * TAU) * 0.045 * moving,
		roll
	)
	if dead > 0.001:
		body.rotation = body.rotation.lerp(Vector3(0.10, 0.0, 1.32), dead)

	if dead < 0.55:
		_animate_legs(delta, speed, stride, moving, on_floor, crouch, reach)
	else:
		_pose_dead_legs(dead, delta)

	_animate_head(delta, moving, crouch, reach, dead)
	_animate_tail(delta, moving, crouch, reach)

	if hurt_amount > 0.001:
		hurt_amount = maxf(0.0, hurt_amount - delta * 3.4)


func _animate_legs(
	_delta: float, speed: float, stride: float, _moving: float, on_floor: bool, crouch: float, reach: float
) -> void:
	var body_inv := body.transform.affine_inverse()
	for i in range(4):
		var front: bool = i < 2
		var l1: float = F_UP if front else H_UP
		var l2: float = F_LO if front else H_LO
		var ph: float = fposmod(stride_phase + float(LEG_PH[i]), 1.0)

		var fx: float = LEG_X[i]
		var fz: float = LEG_Z[i]
		var fy: float = 0.0
		if ph < STANCE:
			var t: float = ph / STANCE
			fz += lerpf(-stride * 0.5, stride * 0.5, t)
			if not _planted[i]:
				_planted[i] = true
				footstep.emit(LEG_NAME[i], to_global(Vector3(fx, 0, fz)), speed)
		else:
			var t: float = (ph - STANCE) / (1.0 - STANCE)
			var e: float = t * t * (3.0 - 2.0 * t)
			fz += lerpf(stride * 0.5, -stride * 0.5, e)
			fy = sin(t * PI) * (0.045 + stride * 0.22)
			if t > 0.45:
				_planted[i] = false

		if not on_floor:
			# Airborne: front legs reach, hind legs tuck.
			fz += (-0.16 if front else 0.14)
			fy += 0.20
		if crouch > 0.01:
			# Gather: every paw comes in under the belly, nothing leaves the ground.
			fz += (0.11 if front else -0.13) * crouch
		if reach > 0.01:
			fz += (-0.26 if front else 0.20) * reach
			fy += (0.24 if front else 0.10) * reach

		if ground_fn.is_valid() and on_floor:
			var wp := to_global(Vector3(fx, 0.0, fz))
			var gy: float = ground_fn.call(wp.x, wp.z)
			fy += clampf(gy - global_position.y, -0.45, 0.45)

		var target := body_inv * Vector3(fx, fy + 0.050, fz)
		var root_p: Vector3 = upper[i].position
		# A cat's elbow folds BACKWARD and its stifle folds FORWARD. That opposition
		# is the whole reason a quadruped cannot borrow the biped's legs.
		var pole_dir := Vector3(0, 0, 1.0) if front else Vector3(0, 0, -1.0)
		var pole: Vector3 = (body_inv.basis * pole_dir).normalized()
		var joint := ProcRig.solve_two_bone(root_p, target, l1, l2, pole)

		var fwd_ref: Vector3 = body_inv.basis * Vector3.FORWARD
		var b_up := ProcRig.basis_down(joint - root_p, fwd_ref)
		upper[i].basis = b_up
		var b_lo := ProcRig.basis_down(target - joint, fwd_ref)
		lower[i].basis = b_up.inverse() * b_lo
		# Keep the pad flat on the ground.
		var b_paw := ProcRig.basis_down(Vector3.DOWN, fwd_ref)
		paw[i].basis = b_lo.inverse() * b_paw


func _pose_dead_legs(e: float, delta: float) -> void:
	for i in range(4):
		var sx: float = -1.0 if i % 2 == 0 else 1.0
		var k: float = 1.0 - pow(0.0005, delta)
		upper[i].basis = upper[i].basis.slerp(Basis.from_euler(Vector3(0.55 * sx, 0.0, 1.25 * sx)), k)
		lower[i].basis = lower[i].basis.slerp(Basis.from_euler(Vector3(-0.95, 0.0, 0.0)), k)
		paw[i].basis = paw[i].basis.slerp(Basis.IDENTITY, k)
	var _unused := e


func _animate_head(delta: float, moving: float, crouch: float, reach: float, dead: float) -> void:
	var idle := Vector3(sin(_t * 0.41 + _seed) * 0.06 + 0.10, sin(_t * 0.27 + _seed) * 0.16, 0.0)
	var target := idle
	if look_weight > 0.001 and dead < 0.5:
		var local: Vector3 = global_transform.basis.inverse() * (look_target - head.global_position)
		if local.length_squared() > 0.0001:
			local = local.normalized()
			var yaw: float = atan2(-local.x, -local.z)
			var pitch: float = asin(clampf(local.y, -1.0, 1.0))
			target = target.lerp(Vector3(-clampf(pitch, -0.7, 0.7), clampf(yaw, -1.2, 1.2), 0.0), look_weight)
	# Head drops in line with the spine to charge, and lolls when dead.
	# Head drops in line with the spine to stalk, and levels out over the spring.
	target.x += crouch * 0.34 + moving * 0.12 - reach * 0.26
	if dead > 0.001:
		target = target.lerp(Vector3(0.35, 0.85, 0.0), dead)
	var k: float = 1.0 - pow(0.0002, delta)
	neck.rotation = neck.rotation.lerp(target * 0.45, k)
	head.rotation = head.rotation.lerp(target * 0.55, k)
	jaw.rotation.x = lerpf(jaw.rotation.x, 0.06 + maw * 0.62, 1.0 - pow(0.00001, delta))


func _animate_tail(delta: float, moving: float, crouch: float, reach: float) -> void:
	for i in range(tail.size()):
		var f: float = float(i + 1) / float(tail.size())
		var swish: float = sin(_t * (2.1 + moving * 2.4) - f * 2.3 + _seed) * (0.16 + moving * 0.14)
		var droop: float = 0.30 - moving * 0.30 - crouch * 0.12 - reach * 0.45
		var target := Vector3(droop * f, swish, 0.0)
		if dead_amount > 0.001:
			target = target.lerp(Vector3(0.0, 0.30 * f, 0.0), dead_amount)
		tail[i].rotation = tail[i].rotation.lerp(target, 1.0 - pow(0.0006, delta))
