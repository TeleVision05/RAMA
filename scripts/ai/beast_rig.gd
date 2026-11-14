class_name BeastRig
extends Node3D
## The vyaghra: a procedurally built, procedurally animated BIG CAT.
##
## The humanoid ProcRig cannot be bent into a cat, and neither can a table. A tiger is
## four facts of anatomy, and the first version of this file had none of them:
##
## 1. **The spine flexes.** A cat's back is the main engine of its gallop; the loin
##    arches and extends through every bound. So the torso is three linked pieces —
##    rump, `lumbar`, `chest` — not one tube.
## 2. **The shoulder blade floats.** A big cat has no collarbone: the scapula slides up
##    the ribcage with every step and stands proud of the back at the withers. So the
##    front legs hang off `scap[L/R]` rather than off the body, and those move.
## 3. **The legs have three segments, folded opposite ways.** Digitigrade: humerus,
##    radius, metacarpus, paw in front; femur, tibia, a long metatarsus and paw behind,
##    with the hock high and folded backwards. A cat's hind leg is a Z; a table's is a
##    post. That contrast is most of the silhouette.
## 4. **The gait changes shape with speed.** Walk (lateral sequence, four beats), trot
##    (diagonal pairs, two beats) and bound (front pair, then hind pair, with a
##    suspension) are not the same cycle played faster. All three are here and blended.
##
## What is reused from ProcRig is its two-bone IK and its "aim a limb down this vector"
## basis helper, both static — so paws PLANT on the terrain by the same maths that
## makes Rama's feet plant. `CreatureKit` supplies the parts that are not primitives:
## the torso shell, the scapula, the paws and the ears.
##
## Streaming: the fine tier (whiskers, claws, toes, teeth, coat tufts) is declared
## through `CreatureKit.detail`, so it stops drawing past `BEAST_DETAIL_DIST` and the
## animal falls back to its silhouette without the director having to know.

# --- proportions (metres) --------------------------------------------------
## Rump-centre height. The withers end up ~0.95 m, which is a large Bengal tiger.
const BODY_H := 0.63
const LUMBAR_Z := 0.32  # rump -> loin joint
const CHEST_Z := 0.36  # loin -> ribcage joint
const NECK_Z := 0.13
const NECK_L := 0.20
const HEAD_L := 0.34

## Leg segments. Sized so the shoulder JOINT lands near 0.63 m with the withers at
## about 0.92 m — a tiger's elbow is halfway up its shoulder height, not two thirds.
## The two-bone pair must also be a little longer than the distance it has to span, or
## `solve_two_bone` clamps and the leg locks out straight.
const F_UP := 0.25  # humerus
const F_LO := 0.26  # radius / ulna
const F_META := 0.13  # metacarpus (the short "wrist" of a digitigrade forelimb)
const H_UP := 0.28  # femur
const H_LO := 0.30  # tibia
const H_META := 0.20  # metatarsus — long, and why the hock sits so high

const LEG_NAME := ["FL", "FR", "BL", "BR"]
const LEG_X := [0.115, -0.115, 0.130, -0.130]
const SCAP_Y := 0.055
const SCAP_Z := 0.010
const HIND_SOCKET := Vector3(0.0, -0.020, 0.150)

# --- gaits -----------------------------------------------------------------
## Each row is [phase FL, FR, BL, BR], duty factor (fraction of the cycle a paw is
## planted), stride length in metres, and how hard the spine works.
##
## Walk is a LATERAL sequence — left hind, left fore, right hind, right fore — which is
## what every cat does below a couple of metres a second. Trot moves diagonal pairs.
## Bound throws the front pair out together, then the hind pair, with the back doing
## the work in between; that is the only one with a suspension phase.
const G_WALK := {"ph": [0.00, 0.50, 0.75, 0.25], "duty": 0.68, "stride": 1.15, "flex": 0.05, "harm": 2.0}
const G_TROT := {"ph": [0.00, 0.50, 0.50, 0.00], "duty": 0.48, "stride": 1.75, "flex": 0.10, "harm": 2.0}
const G_BOUND := {"ph": [0.00, 0.08, 0.50, 0.58], "duty": 0.34, "stride": 2.70, "flex": 0.34, "harm": 1.0}
const WALK_TOP := 2.3  # m/s: fully walking below this
const TROT_TOP := 5.2  # m/s: fully trotting below this, fully bounding a m/s above

# --- joints ----------------------------------------------------------------
var body: Node3D  # rump and pelvis; the root of the whole animal
var lumbar: Node3D  # the flexing loin
var chest: Node3D  # ribcage
var scap: Array[Node3D] = []  # shoulder blades, index 0 = left
var neck: Node3D
var head: Node3D
var jaw: Node3D
var tail: Array[Node3D] = []
var upper: Array[Node3D] = []
var lower: Array[Node3D] = []
var meta: Array[Node3D] = []
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
var _gait: Dictionary = G_WALK.duplicate()
var _scap_rest := [0.0, 0.0]

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
	# The coat texture fades toward cream at one end of its U axis, which the torso
	# loft wraps around the belly. Every OTHER part of the animal — jaw, cheeks, paws,
	# throat — gets its own small loft with its own U wrap, so the fade would land
	# wherever that part's seam happens to be. A tiger is not read from its stripes, it
	# is read from the WHITE: muzzle, cheeks, throat, belly, paws. Those are geometry
	# here, so they get a material rather than a UV.
	var m_pale := Mats.flat(_coat_tint * Color(0.56, 0.515, 0.450), 0.90)
	# The SAME coat, stretched along its V axis for the limbs, the neck and the tail.
	# Every loft maps V 0..1 over its own length, so the seventeen stripes that read
	# correctly across a 1.0 m flank were being squeezed onto a 0.30 m shin and a
	# 0.145 m tail segment: the animal came out in tiger-print pyjamas
	# (build/screenshots/creature_vyaghra_side.png, 2026-08-28).
	var m_limb: StandardMaterial3D = _coat_material(_coat_tint)
	m_limb.uv1_scale = Vector3(1.0, 0.26, 1.0)
	var m_neck: StandardMaterial3D = _coat_material(_coat_tint)
	m_neck.uv1_scale = Vector3(1.0, 0.55, 1.0)
	var m_dark := Mats.flat(_coat_tint * Color(0.17, 0.13, 0.11), 0.72)
	var m_claw := Mats.flat(Color(0.14, 0.13, 0.12), 0.36)

	body = Node3D.new()
	body.name = "Body"
	body.position = Vector3(0, BODY_H, 0)
	add_child(body)
	_build_hindquarters(m_coat, m_pale)

	lumbar = Node3D.new()
	lumbar.name = "Lumbar"
	lumbar.position = Vector3(0, 0.015, -LUMBAR_Z)
	body.add_child(lumbar)

	chest = Node3D.new()
	chest.name = "Chest"
	chest.position = Vector3(0, 0.030, -CHEST_Z)
	lumbar.add_child(chest)
	_build_ribcage(m_coat, m_pale)

	_build_neck_and_head(m_coat, m_neck, m_pale, m_dark, m_claw)
	_build_tail(m_limb, m_dark)

	for i in range(4):
		_build_leg(i, m_limb, m_claw, m_coat)


## The rump: heavy haunches over the hip, and the loin narrowing forward of them. This
## is where a cat's mass sits when it is gathered to jump.
func _build_hindquarters(m_coat: Material, m_pale: Material) -> void:
	# ONE tapered loft from the waist to the tail root. Two overlapping eggs — a rump
	# and a loin — gave the animal a lumpy, segmented back with a hard step where the
	# wider one ended (build/screenshots/creature_vyaghra_neck.png, 2026-08-28). Its
	# front half-width is matched to where the ribcage shell tapers out, so the two
	# meet in a waist instead of a shelf.
	var form: Array = [
		(
			CreatureKit
			. part(
				(
					MeshKit
					. profile_loft(
						0.58,
						[
							[0.00, 0.138, 0.148],
							[0.20, 0.168, 0.176],
							[0.48, 0.190, 0.184],
							[0.76, 0.176, 0.168],
							[1.00, 0.104, 0.110],
						],
						16
					)
				),
				Vector3(0, 0.004, -0.250),
				Vector3(PI * 0.5, 0, 0)
			)
		)
	]
	for sx in [-1.0, 1.0]:
		# The thigh muscle mass, standing proud of the flank. Without it the hind leg
		# looks pinned to a barrel.
		form.append(
			CreatureKit.part(
				MeshKit.ovoid(0.112, 0.34, 0.42, 12, 8),
				Vector3(sx * 0.108, -0.030, 0.115),
				Vector3(PI * 0.5, 0, sx * 0.10),
				Vector3(0.84, 1.0, 1.05)
			)
		)
	CreatureKit.solid(body, form, m_coat, "Rump")
	# Pale under-tail and inner thigh.
	CreatureKit.solid(
		body,
		[
			CreatureKit.part(
				MeshKit.ovoid(0.108, 0.34, 0.5, 10, 7), Vector3(0, -0.118, 0.050), Vector3(PI * 0.5, 0, 0), Vector3(1.0, 1.0, 0.55)
			)
		],
		m_pale,
		"RumpPale"
	)


## The ribcage: DEEP, and deepest just behind the shoulder. That depth against a
## pinched waist is the single strongest "big cat" cue in profile.
func _build_ribcage(m_coat: Material, m_pale: Material) -> void:
	var form: Array = [CreatureKit.part(CreatureKit.quadruped_torso(0.66, 0.180, 0.228, 0.86, 1.0, 16), Vector3(0, 0.0, -0.04))]
	# Brisket: the keel of the chest, hanging between the forelegs.
	form.append(
		CreatureKit.part(
			MeshKit.ovoid(0.058, 0.22, 0.5, 10, 7), Vector3(0, -0.140, 0.020), Vector3(PI * 0.5, 0, 0), Vector3(1.05, 1.0, 0.78)
		)
	)
	CreatureKit.solid(chest, form, m_coat, "Ribcage")
	# Pale belly and chest, inset so the flank keeps its stripes and only the underside
	# reads cream from a low angle.
	(
		CreatureKit
		. solid(
			chest,
			[
				CreatureKit.part(
					MeshKit.ovoid(0.135, 0.56, 0.5, 12, 7), Vector3(0, -0.150, 0.070), Vector3(PI * 0.5, 0, 0), Vector3(1.0, 1.0, 0.48)
				),
				# Kept BEHIND the front of the ribcage. Measured 2026-08-28: the coat shell
				# ends at z -0.066 and this ovoid reached z -0.239, so 17 cm of bare pale
				# ellipsoid hung in the air ahead of the chest, between the forelegs and
				# attached to nothing. Head-on it photographed as a white sac slung under
				# the animal (build/screenshots/creature_vyaghra_head.png). Re-check with
				# `tests/probes/qa_creature_probe.gd` if the torso is ever re-dimensioned.
				CreatureKit.part(
					MeshKit.ovoid(0.084, 0.20, 0.5, 12, 7), Vector3(0, -0.128, -0.002), Vector3(PI * 0.5, 0, 0), Vector3(1.0, 1.0, 0.62)
				),
			],
			m_pale,
			"Belly"
		)
	)


func _build_neck_and_head(m_coat: Material, m_neck: Material, m_pale: Material, m_dark: Material, m_claw: Material) -> void:
	neck = Node3D.new()
	neck.name = "Neck"
	neck.position = Vector3(0, 0.105, -NECK_Z)
	chest.add_child(neck)
	(
		CreatureKit
		. solid(
			neck,
			[
				(
					CreatureKit
					. part(
						(
							MeshKit
							. profile_loft(
								NECK_L + 0.14,
								[
									[0.00, 0.092, 0.096],
									[0.30, 0.104, 0.112],
									[0.68, 0.124, 0.134],
									[1.00, 0.152, 0.162],
								],
								14
							)
						),
						# The quarter turn is POSITIVE, which is what puts U = 0.25 on the
						# underside; turning it the other way to make the loft run forward put
						# the coat's cream belly along the top of the neck and left a pale tube
						# where the mane should be (build/screenshots/creature_vyaghra_neck.png,
						# 2026-08-28). So the profile is written head-end-first instead.
						Vector3(0, -0.020, -(NECK_L + 0.14) + 0.10),
						Vector3(PI * 0.5, 0, 0),
						Vector3(1.02, 1.0, 1.0)
					)
				)
			],
			m_neck,
			"Neck"
		)
	)
	CreatureKit.solid(
		neck,
		[
			CreatureKit.part(
				MeshKit.ovoid(0.062, 0.26, 0.5, 10, 7), Vector3(0, -0.062, -NECK_L * 0.48), Vector3(PI * 0.5, 0, 0), Vector3(1.0, 1.0, 0.70)
			)
		],
		m_pale,
		"Throat"
	)

	head = Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 0.072, -NECK_L)
	# Scaled rather than re-dimensioned part by part: everything below is authored in
	# one consistent set of head-local numbers, and a tiger's head is simply bigger
	# relative to its body than the first pass allowed for. `_animate_head` only ever
	# writes `rotation`, which preserves scale.
	head.scale = Vector3.ONE * 1.18
	neck.add_child(head)

	var form: Array = []
	var pale: Array = []
	var dark: Array = []
	var fine: Array = []
	var bone: Array = []

	# Cranium: broad, short, flat across the top between the ears.
	form.append(
		CreatureKit.part(
			MeshKit.ovoid(0.108, 0.24, 0.45, 14, 10), Vector3(0, 0.010, -0.055), Vector3(PI * 0.5, 0, 0), Vector3(1.06, 1.0, 0.88)
		)
	)
	for sx in [-1.0, 1.0]:
		# Zygomatic arch and the jaw muscle behind it: a cat's head is WIDE at the
		# cheek and narrow at the muzzle, and that taper is the whole read.
		form.append(
			CreatureKit.part(
				MeshKit.ovoid(0.062, 0.16, 0.5, 10, 7),
				Vector3(sx * 0.086, -0.012, -0.060),
				Vector3(PI * 0.5, sx * 0.20, 0),
				Vector3(0.90, 1.0, 1.05)
			)
		)
		# Ears: rounded, set wide on the corners of the skull, tipped outward.
		form.append(
			CreatureKit.part(CreatureKit.ear(0.088, 0.055, 0.12), Vector3(sx * 0.078, 0.078, 0.005), Vector3(-0.22, sx * 0.30, sx * 0.46))
		)
		dark.append(
			CreatureKit.part(CreatureKit.ear(0.046, 0.026, 0.12), Vector3(sx * 0.080, 0.086, -0.014), Vector3(-0.22, sx * 0.30, sx * 0.46))
		)
		# The white cheek ruff that frames a tiger's face. Set LOW and outboard: built
		# any larger they meet above the muzzle and the animal becomes two pom-poms
		# with a nose between them.
		pale.append(
			CreatureKit.part(
				MeshKit.ovoid(0.040, 0.100, 0.5, 9, 6),
				Vector3(sx * 0.088, -0.042, -0.078),
				Vector3(PI * 0.5, 0, sx * 0.16),
				Vector3(0.82, 1.0, 1.05)
			)
		)
		# Whiskers. Fine tier: four per side, gone by twenty metres.
		for k in range(4):
			var a: float = -0.30 + 0.22 * float(k)
			fine.append(
				CreatureKit.part(
					MeshKit.tube(0.115, [[0.0, 0.0022], [1.0, 0.0008]], 4),
					Vector3(sx * 0.046, -0.018 - 0.008 * float(k), -0.170),
					Vector3(1.35 + a * 0.30, sx * (1.05 + a), 0)
				)
			)

	# Muzzle: short, blunt, and pale. The nose leather sits on the end of it.
	pale.append(
		CreatureKit.part(
			MeshKit.ovoid(0.055, 0.115, 0.5, 12, 8), Vector3(0, -0.030, -0.166), Vector3(PI * 0.5, 0, 0), Vector3(1.10, 1.0, 0.80)
		)
	)
	dark.append(CreatureKit.part(MeshKit.sphere(0.019, 8, 6), Vector3(0, -0.016, -0.212), Vector3.ZERO, Vector3(1.20, 0.80, 0.70)))
	# The dark brow band above the eyes, so the face has a line to read across it and
	# the skull does not render as one smooth egg.
	dark.append(
		CreatureKit.part(
			MeshKit.ovoid(0.070, 0.030, 0.5, 12, 5), Vector3(0, 0.046, -0.118), Vector3(PI * 0.5, 0, 0), Vector3(1.05, 1.0, 0.45)
		)
	)

	# Eyes: amber, faintly self-lit, so the animal reads as a predator at dusk. Set
	# forward and high on the skull — binocular, like everything that hunts.
	var m_eye := StandardMaterial3D.new()
	m_eye.albedo_color = Color(0.92, 0.66, 0.16)
	m_eye.emission_enabled = true
	m_eye.emission = Color(0.85, 0.48, 0.08)
	m_eye.emission_energy_multiplier = 0.65
	m_eye.roughness = 0.15
	var eyes: Array = []
	var pupils: Array = []
	for sx in [-1.0, 1.0]:
		eyes.append(
			CreatureKit.part(MeshKit.sphere(0.021, 9, 7), Vector3(sx * 0.055, 0.026, -0.132), Vector3.ZERO, Vector3(1.05, 0.80, 0.85))
		)
		pupils.append(
			CreatureKit.part(
				MeshKit.sphere(0.012, 7, 6), Vector3(sx * 0.057, 0.026, -0.149), Vector3(0, sx * 0.18, 0), Vector3(0.42, 1.20, 0.50)
			)
		)
	CreatureKit.solid(head, eyes, m_eye, "Eyes")

	jaw = Node3D.new()
	jaw.name = "Jaw"
	jaw.position = Vector3(0, -0.038, -0.070)
	head.add_child(jaw)
	CreatureKit.solid(
		jaw,
		[
			CreatureKit.part(
				MeshKit.ovoid(0.056, 0.155, 0.5, 10, 7), Vector3(0, -0.018, -0.062), Vector3(PI * 0.5, 0, 0), Vector3(1.05, 1.0, 0.58)
			)
		],
		m_pale,
		"Mandible"
	)
	# Canines: two down from the skull, two up from the jaw. Base tier — a cat's
	# canines show past the lip and they are half of what makes it frightening.
	for sx in [-1.0, 1.0]:
		bone.append(CreatureKit.part(CreatureKit.fang(0.056, 0.0115, -0.45), Vector3(sx * 0.036, -0.044, -0.176), Vector3(PI - 0.20, 0, 0)))
	CreatureKit.solid(head, bone, m_claw, "Canines")
	var lower_teeth: Array = []
	for sx in [-1.0, 1.0]:
		lower_teeth.append(
			CreatureKit.part(CreatureKit.fang(0.038, 0.0085, 0.35), Vector3(sx * 0.033, -0.026, -0.164), Vector3(-0.16, 0, 0))
		)
	CreatureKit.detail(jaw, lower_teeth, m_claw, CreatureKit.BEAST_DETAIL_DIST, "Teeth")

	CreatureKit.solid(head, form, m_coat, "Skull")
	CreatureKit.solid(head, pale, m_pale, "Face")
	CreatureKit.solid(head, dark, m_dark, "Mask")
	CreatureKit.solid(head, pupils, _pupil_material(), "Pupils")
	CreatureKit.detail(head, fine, m_dark, CreatureKit.BEAST_DETAIL_DIST, "Whiskers")


## A long, thick-rooted counterbalance. A tiger's tail is nearly the length of its
## body and it is heavy at the base — a thin whip reads as a rat.
func _build_tail(m_coat: Material, m_dark: Material) -> void:
	var parent: Node3D = body
	var pos := Vector3(0, 0.105, 0.300)
	var segs := 7
	for i in range(segs):
		var seg := Node3D.new()
		seg.name = "Tail%d" % i
		seg.position = pos
		parent.add_child(seg)
		var r0: float = lerpf(0.050, 0.024, float(i) / float(segs))
		var r1: float = lerpf(0.050, 0.024, float(i + 1) / float(segs))
		# `MeshKit.tube` lofts and `MeshKit.loft` does not cap, so the last segment's far
		# end was a 24 mm hole: the tail photographed as a cut length of pipe with a grey
		# disc of backface at the end (build/screenshots/creature_vyaghra_side.png,
		# 2026-08-28). The tip segment closes instead, with a slight club before it —
		# which is also what a tiger's tail actually does.
		var prof: Array = [[0.0, r0], [1.0, r1]]
		if i == segs - 1:
			prof = [[0.0, r0], [0.45, r1 * 1.16], [0.80, r1 * 0.92], [1.0, 0.002]]
		CreatureKit.solid(
			seg,
			[CreatureKit.part(MeshKit.tube(0.145, prof, 8), Vector3.ZERO, Vector3(PI * 0.5, 0, 0))],
			m_dark if i == segs - 1 else m_coat,
			"Seg"
		)
		tail.append(seg)
		parent = seg
		pos = Vector3(0, 0, 0.145)


## One limb: three driven segments and a paw, hung off the scapula in front and off
## the pelvis behind.
func _build_leg(i: int, m_coat: Material, m_claw: Material, m_body: Material = null) -> void:
	var front: bool = i < 2
	var l1: float = F_UP if front else H_UP
	var l2: float = F_LO if front else H_LO
	var l3: float = F_META if front else H_META
	# A tiger's forelegs are its weapons; thin ones read as a deer.
	var thick: float = 0.096 if front else 0.102
	var root: Node3D

	if front:
		var sc := Node3D.new()
		sc.name = "Scap" + LEG_NAME[i]
		sc.position = Vector3(LEG_X[i], SCAP_Y, SCAP_Z)
		chest.add_child(sc)
		# The blade itself, standing proud of the ribs. This is the lump that rides up
		# and down at the withers of every walking cat.
		CreatureKit.solid(
			sc,
			[
				CreatureKit.part(
					CreatureKit.scapula(0.130, 0.068, 0.044), Vector3(0, -0.030, -0.010), Vector3(0.22, 0, (1.0 if i == 0 else -1.0) * 0.10)
				)
			],
			m_body,
			"Blade"
		)
		scap.append(sc)
		_scap_rest[i] = SCAP_Y
		root = sc
	else:
		root = body

	var up := Node3D.new()
	up.name = "Upper" + LEG_NAME[i]
	up.position = (Vector3(0, -0.100, 0.0) if front else Vector3(LEG_X[i], HIND_SOCKET.y, HIND_SOCKET.z))
	root.add_child(up)
	# Limbs are built along +Y then turned a half-turn about X so they HANG. A half
	# turn is a proper rotation, so no winding flip and no invisible legs.
	CreatureKit.solid(
		up, [CreatureKit.part(MeshKit.limb(l1, thick * 0.70, thick * 1.55, 1.12, 9), Vector3.ZERO, Vector3(PI, 0, 0))], m_coat, "Seg"
	)

	var lo := Node3D.new()
	lo.name = "Lower" + LEG_NAME[i]
	lo.position = Vector3(0, -l1, 0)
	up.add_child(lo)
	CreatureKit.solid(
		lo, [CreatureKit.part(MeshKit.limb(l2, thick * 0.46, thick * 0.86, 1.06, 8), Vector3.ZERO, Vector3(PI, 0, 0))], m_coat, "Seg"
	)

	var mt := Node3D.new()
	mt.name = "Meta" + LEG_NAME[i]
	mt.position = Vector3(0, -l2, 0)
	lo.add_child(mt)
	CreatureKit.solid(
		mt, [CreatureKit.part(MeshKit.limb(l3, thick * 0.40, thick * 0.54, 1.02, 8), Vector3.ZERO, Vector3(PI, 0, 0))], m_coat, "Seg"
	)

	var pw := Node3D.new()
	pw.name = "Paw" + LEG_NAME[i]
	pw.position = Vector3(0, -l3, 0)
	mt.add_child(pw)
	# A real paw: a pad and four splayed toes, merged into one mesh by CreatureKit.
	# In COAT, not in the pale material. White paws read as socks; a tiger's feet are
	# the same colour as its legs, with only the underside of the pad paler.
	CreatureKit.solid(pw, [CreatureKit.part(CreatureKit.paw(0.062 if front else 0.058, 0.0), Vector3(0, -0.014, 0.0))], m_coat, "Pad")
	CreatureKit.detail(
		pw,
		[CreatureKit.part(CreatureKit.claws(0.062 if front else 0.058, 0.030), Vector3(0, -0.014, 0.0))],
		m_claw,
		CreatureKit.BEAST_DETAIL_DIST,
		"Claws"
	)

	upper.append(up)
	lower.append(lo)
	meta.append(mt)
	paw.append(pw)


# --- material --------------------------------------------------------------
## The coat is synthesised, like every other texture in this project.
##
## Layout, and it matters: the torso lofts run along the body, so the ring index (U)
## wraps AROUND the animal and the profile parameter (V) runs nose to tail. After the
## quarter-turn that lays a loft along Z, U = 0.25 is the belly and U = 0.75 is the
## spine. The first version faded to cream at U = 0 and U = 0.5 — the two FLANKS — and
## drew its stripes only within 0.46 of U = 0.5, which is one flank and nothing else.
## Photographed on 2026-08-28 (build/screenshots/creature_vyaghra_side.png) the result
## was a cream animal with a few short bars on one side. Stripes now run over the back
## and die out at the belly, which is where a tiger's actually stop.
static func coat_texture() -> ImageTexture:
	if _coat_tex != null:
		return _coat_tex
	var w := 160
	var img := Image.create(w, w, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x54_49_47_52  # "TIGR"
	var base := Color(0.735, 0.365, 0.105)
	var pale := Color(0.900, 0.815, 0.680)
	var dark := Color(0.070, 0.052, 0.045)
	for y in range(w):
		for x in range(w):
			var fx := float(x)
			var fy := float(y)
			var n: float = sin(fx * 0.42 + fy * 0.11) * 0.030 + cos(fy * 0.77) * 0.026
			n += sin((fx + fy) * 0.19) * 0.022
			# Belly at U = 0.25, spine at U = 0.75.
			var u: float = fx / float(w)
			var belly: float = pow(clampf(cos((u - 0.25) * TAU) * 0.5 + 0.5, 0.0, 1.0), 2.6)
			var c: Color = base.lerp(pale, belly * 0.88)
			# The spine is a shade darker than the flank, which is what stops the back
			# reading as flat orange from above.
			var spine: float = pow(clampf(cos((u - 0.75) * TAU) * 0.5 + 0.5, 0.0, 1.0), 4.0)
			c = c.lerp(base * Color(0.80, 0.78, 0.80), spine * 0.55)
			c = Color(clampf(c.r * (1.0 + n), 0, 1), clampf(c.g * (1.0 + n), 0, 1), clampf(c.b * (1.0 + n), 0, 1))
			img.set_pixel(x, y, c)
	# Stripes: bands that wrap the body (constant V, spanning U), centred on the spine
	# and tapering out toward the belly, with forked ends.
	var stripes := 17
	for s in range(stripes):
		var cy: float = (float(s) + 0.5) * (float(w) / float(stripes)) + rng.randf_range(-3.0, 3.0)
		var thick: float = rng.randf_range(2.4, 5.2)
		var amp: float = rng.randf_range(1.5, 4.5)
		var freq: float = rng.randf_range(0.03, 0.075)
		var reach: float = rng.randf_range(0.30, 0.46)  # how far down the flank
		var fork: float = rng.randf()
		for x in range(w):
			var fx := float(x)
			var u: float = fx / float(w)
			# Distance around the body from the SPINE, 0 at the back, 1 at the belly.
			var d: float = absf(fposmod(u - 0.75 + 0.5, 1.0) - 0.5) * 2.0
			if d > reach + 0.34:
				continue
			var fade: float = clampf((reach + 0.34 - d) / 0.26, 0.0, 1.0)
			var off: float = sin(fx * freq + float(s)) * amp
			# Some stripes fork: a second band peels away over the flank.
			var split: float = 0.0 if fork < 0.5 else sin(u * TAU * 2.0) * 3.0 * clampf(d - 0.25, 0.0, 1.0)
			var half: float = thick * fade
			for dy in range(-7, 8):
				var yy: float = cy + off + split + float(dy)
				var dd: float = absf(float(dy))
				if dd > half:
					continue
				var k: float = clampf(1.0 - dd / maxf(half, 0.001), 0.0, 1.0)
				var px := int(fposmod(yy, float(w)))
				var cur: Color = img.get_pixel(x, px)
				img.set_pixel(x, px, cur.lerp(dark, k * 0.96))
	_coat_tex = ImageTexture.create_from_image(img)
	return _coat_tex


static var _pupil_mat: StandardMaterial3D = null


## Shared across every vyaghra: a fresh StandardMaterial3D per animal is a fresh
## uniform set for the renderer to bind.
static func _pupil_material() -> StandardMaterial3D:
	if _pupil_mat == null:
		_pupil_mat = Mats.flat(Color(0.04, 0.03, 0.03), 0.10)
	return _pupil_mat


static func _coat_material(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = coat_texture()
	m.albedo_color = tint
	m.roughness = 0.84
	m.metallic = 0.0
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m


func shoulder_height() -> float:
	return BODY_H + 0.25


# ===========================================================================
#  ANIMATION
# ===========================================================================
func animate(delta: float, st: Dictionary) -> void:
	_t += delta
	var speed: float = st.get("speed", 0.0)
	var on_floor: bool = st.get("on_floor", true)
	var moving: float = clampf(speed / 2.2, 0.0, 1.0)
	_blend_gait(speed, delta)

	if on_floor and speed > 0.15:
		stride_phase = fposmod(stride_phase + (speed / float(_gait.stride)) * delta, 1.0)
	else:
		stride_phase = lerpf(stride_phase, roundf(stride_phase * 2.0) * 0.5, 1.0 - pow(0.002, delta))
	_breath += delta * lerpf(1.1, 3.6, moving)

	var stride: float = clampf(speed * 0.28, 0.0, 0.70)
	var run: float = clampf((speed - WALK_TOP) / 4.0, 0.0, 1.0)
	var cyc: float = stride_phase * TAU
	var bob: float = sin(cyc * float(_gait.harm)) * (0.020 + run * 0.045) * moving
	var roll: float = sin(cyc) * 0.050 * moving * (1.0 - run * 0.6)
	var breathe: float = sin(_breath) * 0.010 * (1.0 - moving * 0.6)

	# The two halves of a lunge. Gathering drops the chest and draws every paw in
	# under the belly; the spring throws the chest up and the forelegs out. Rearing
	# nose-down was the first version's mistake — that is a cat falling over, not a
	# cat about to hit you.
	var crouch: float = clampf(-lunge, 0.0, 1.0)
	var reach: float = clampf(lunge, 0.0, 1.0)
	var dead: float = clampf(dead_amount, 0.0, 1.0)

	body.position = Vector3(0.0, BODY_H + bob + breathe - crouch * 0.16 + reach * 0.10 - dead * (BODY_H - 0.20), 0.0)
	body.rotation = Vector3(-0.020 * moving - crouch * 0.08 + reach * 0.30 + hurt_amount * 0.10, sin(cyc) * 0.040 * moving, roll)
	if dead > 0.001:
		body.rotation = body.rotation.lerp(Vector3(0.10, 0.0, 1.34), dead)

	_animate_spine(delta, cyc, moving, run, crouch, reach, dead)

	if dead < 0.55:
		_animate_legs(delta, speed, stride, on_floor, crouch, reach)
	else:
		_pose_dead_legs(delta)

	_animate_head(delta, moving, crouch, reach, dead)
	_animate_tail(delta, moving, run, crouch, reach)

	if hurt_amount > 0.001:
		hurt_amount = maxf(0.0, hurt_amount - delta * 3.4)


## Cross-fade walk -> trot -> bound. The phase OFFSETS are interpolated the short way
## round the circle, so a leg never jumps half a cycle when the animal changes gear;
## interpolating them linearly instead makes the hind legs stutter at exactly the
## speed the player is chasing at.
func _blend_gait(speed: float, delta: float) -> void:
	var a: Dictionary = G_WALK
	var b: Dictionary = G_TROT
	var k: float = clampf((speed - (WALK_TOP - 0.9)) / 0.9, 0.0, 1.0)
	if speed > WALK_TOP:
		a = G_TROT
		b = G_BOUND
		k = clampf((speed - TROT_TOP) / 1.2, 0.0, 1.0)
	var ph: Array = []
	for i in range(4):
		ph.append(_lerp_phase(float(a.ph[i]), float(b.ph[i]), k))
	var want := {
		"ph": ph,
		"duty": lerpf(float(a.duty), float(b.duty), k),
		"stride": lerpf(float(a.stride), float(b.stride), k),
		"flex": lerpf(float(a.flex), float(b.flex), k),
		"harm": lerpf(float(a.harm), float(b.harm), k),
	}
	# Ease into it, so a shove that spikes the speed for one frame does not snap the
	# gait over and back.
	var s: float = 1.0 - pow(0.02, delta)
	var cur: Array = []
	for i in range(4):
		cur.append(_lerp_phase(float(_gait.ph[i]), float(want.ph[i]), s))
	_gait = {
		"ph": cur,
		"duty": lerpf(float(_gait.duty), float(want.duty), s),
		"stride": lerpf(float(_gait.stride), float(want.stride), s),
		"flex": lerpf(float(_gait.flex), float(want.flex), s),
		"harm": lerpf(float(_gait.harm), float(want.harm), s),
	}


static func _lerp_phase(a: float, b: float, k: float) -> float:
	var d: float = fposmod(b - a + 0.5, 1.0) - 0.5
	return fposmod(a + d * k, 1.0)


## The loin. A walking cat bends side to side; a bounding one arches and extends
## through the whole back once per stride, and that is where the reach comes from.
func _animate_spine(delta: float, cyc: float, moving: float, run: float, crouch: float, reach: float, dead: float) -> void:
	var flex: float = float(_gait.flex)
	var target := Vector3(-cos(cyc) * flex * moving + crouch * 0.30 - reach * 0.34, sin(cyc) * 0.10 * moving * (1.0 - run), 0.0)
	if dead > 0.001:
		target = target.lerp(Vector3(0.30, 0.20, 0.0), dead)
	lumbar.rotation = lumbar.rotation.lerp(target, 1.0 - pow(0.0004, delta))
	# The ribcage counter-rotates a little, so the flex reads as a spine and not as a
	# hinge in the middle of a tube.
	chest.rotation = chest.rotation.lerp(
		Vector3(target.x * -0.45 - crouch * 0.12 + reach * 0.20, target.y * -0.55, 0.0), 1.0 - pow(0.0004, delta)
	)


func _animate_legs(_delta: float, speed: float, stride: float, on_floor: bool, crouch: float, reach: float) -> void:
	var duty: float = float(_gait.duty)
	for i in range(4):
		var front: bool = i < 2
		var l1: float = F_UP if front else H_UP
		var l2: float = F_LO if front else H_LO
		var l3: float = F_META if front else H_META
		var ph: float = fposmod(stride_phase + float(_gait.ph[i]), 1.0)

		# --- where the paw wants to be, in RIG-LOCAL space --------------------
		var fx: float = LEG_X[i]
		var fz: float = _rest_z(i)
		var fy: float = 0.0
		if ph < duty:
			var t: float = ph / duty
			fz += lerpf(-stride * 0.5, stride * 0.5, t)
			if not _planted[i]:
				_planted[i] = true
				footstep.emit(LEG_NAME[i], to_global(Vector3(fx, 0, fz)), speed)
		else:
			var t: float = (ph - duty) / (1.0 - duty)
			var e: float = t * t * (3.0 - 2.0 * t)
			fz += lerpf(stride * 0.5, -stride * 0.5, e)
			fy = sin(t * PI) * (0.045 + stride * 0.26)
			if t > 0.45:
				_planted[i] = false

		if not on_floor:
			# Airborne: front legs reach, hind legs tuck.
			fz += (-0.16 if front else 0.16)
			fy += 0.22
		if crouch > 0.01:
			# Gather: every paw comes in under the belly, nothing leaves the ground.
			fz += (0.12 if front else -0.14) * crouch
		if reach > 0.01:
			fz += (-0.28 if front else 0.22) * reach
			fy += (0.26 if front else 0.12) * reach

		if ground_fn.is_valid() and on_floor:
			var wp := to_global(Vector3(fx, 0.0, fz))
			var gy: float = ground_fn.call(wp.x, wp.z)
			fy += clampf(gy - global_position.y, -0.45, 0.45)

		var contact := Vector3(fx, fy + 0.042, fz)
		# The ankle sits `l3` above the paw and BEHIND it — forward is -Z, so the hock
		# of a hind leg is at POSITIVE z relative to the paw it stands on. The first
		# version had this sign inverted, which put the heel in front of the toes and
		# straightened the one joint that makes a cat's hind leg a Z instead of a post.
		var lean := Vector3(0.0, 1.0, 0.10 if front else 0.46).normalized()
		var ankle: Vector3 = contact + lean * l3

		# --- solve the two-bone part in the joint's own parent frame -----------
		var px: Transform3D = _leg_parent_xform(i)
		var inv := px.affine_inverse()
		var root_p: Vector3 = upper[i].position
		var target_a: Vector3 = inv * ankle
		# A cat's elbow folds BACKWARD and its stifle folds FORWARD. That opposition is
		# the whole reason a quadruped cannot borrow the biped's legs.
		var pole_dir := Vector3(0, 0, 1.0) if front else Vector3(0, 0, -1.0)
		var pole: Vector3 = (inv.basis * pole_dir).normalized()
		var joint := ProcRig.solve_two_bone(root_p, target_a, l1, l2, pole)

		var fwd_ref: Vector3 = inv.basis * Vector3.FORWARD
		var b_up := ProcRig.basis_down(joint - root_p, fwd_ref)
		upper[i].basis = b_up
		var b_lo := ProcRig.basis_down(target_a - joint, fwd_ref)
		lower[i].basis = b_up.inverse() * b_lo
		var b_mt := ProcRig.basis_down(inv * contact - target_a, fwd_ref)
		meta[i].basis = b_lo.inverse() * b_mt
		# Keep the pad flat on the ground.
		var b_paw := ProcRig.basis_down(inv.basis * Vector3.DOWN, fwd_ref)
		paw[i].basis = b_mt.inverse() * b_paw

		if front:
			_animate_scapula(i, ph, speed)


## Where this leg's socket lives, as a transform from RIG-LOCAL space. The front pair
## hang off a scapula that hangs off a ribcage that hangs off a flexing loin, so their
## parent frame changes every frame; the hind pair only see the body.
func _leg_parent_xform(i: int) -> Transform3D:
	if i < 2:
		return body.transform * lumbar.transform * chest.transform * scap[i].transform
	return body.transform


func _rest_z(i: int) -> float:
	if i < 2:
		return -(LUMBAR_Z + CHEST_Z) + SCAP_Z + 0.020
	# The hind paw stands a little BEHIND the hip, which is what opens the hock angle.
	return HIND_SOCKET.z + 0.075


## The shoulder blade rides up as the leg comes under the body and drops as it
## extends. Two centimetres of travel, and it is the difference between a cat and a
## coffee table with legs.
func _animate_scapula(i: int, ph: float, speed: float) -> void:
	var amp: float = clampf(speed * 0.012, 0.0, 0.030)
	var sc: Node3D = scap[i]
	sc.position.y = _scap_rest[i] + sin(ph * TAU + 0.4) * amp
	sc.position.z = SCAP_Z + cos(ph * TAU) * amp * 0.6
	sc.rotation.x = sin(ph * TAU + 0.8) * clampf(speed * 0.06, 0.0, 0.22)


func _pose_dead_legs(delta: float) -> void:
	for i in range(4):
		var sx: float = -1.0 if i % 2 == 0 else 1.0
		var k: float = 1.0 - pow(0.0005, delta)
		upper[i].basis = upper[i].basis.slerp(Basis.from_euler(Vector3(0.55 * sx, 0.0, 1.25 * sx)), k)
		lower[i].basis = lower[i].basis.slerp(Basis.from_euler(Vector3(-0.95, 0.0, 0.0)), k)
		meta[i].basis = meta[i].basis.slerp(Basis.from_euler(Vector3(0.6, 0.0, 0.0)), k)
		paw[i].basis = paw[i].basis.slerp(Basis.IDENTITY, k)


func _animate_head(delta: float, moving: float, crouch: float, reach: float, dead: float) -> void:
	var idle := Vector3(sin(_t * 0.41 + _seed) * 0.06 + 0.06, sin(_t * 0.27 + _seed) * 0.16, 0.0)
	var target := idle
	if look_weight > 0.001 and dead < 0.5:
		var local: Vector3 = global_transform.basis.inverse() * (look_target - head.global_position)
		if local.length_squared() > 0.0001:
			local = local.normalized()
			var yaw: float = atan2(-local.x, -local.z)
			var pitch: float = asin(clampf(local.y, -1.0, 1.0))
			target = target.lerp(Vector3(-clampf(pitch, -0.7, 0.7), clampf(yaw, -1.2, 1.2), 0.0), look_weight)
	# Head drops in line with the spine to stalk, and levels out over the spring.
	target.x += crouch * 0.32 + moving * 0.10 - reach * 0.24
	if dead > 0.001:
		target = target.lerp(Vector3(0.35, 0.85, 0.0), dead)
	var k: float = 1.0 - pow(0.0002, delta)
	neck.rotation = neck.rotation.lerp(target * 0.45, k)
	head.rotation = head.rotation.lerp(target * 0.55, k)
	jaw.rotation.x = lerpf(jaw.rotation.x, 0.05 + maw * 0.60, 1.0 - pow(0.00001, delta))


## The tail. It is a counterweight, so it lags the body: each segment follows the one
## in front with a phase delay, and the whole thing lifts as the animal accelerates.
func _animate_tail(delta: float, moving: float, run: float, crouch: float, reach: float) -> void:
	var n := tail.size()
	for i in range(n):
		var f: float = float(i + 1) / float(n)
		var swish: float = sin(_t * (2.0 + moving * 2.2) - f * 2.6 + _seed) * (0.14 + moving * 0.12)
		# Down and relaxed at rest, streamed out straight behind at a gallop, tucked
		# when gathering to pounce.
		var droop: float = 0.34 - run * 0.40 - crouch * 0.20 - reach * 0.42
		var target := Vector3(droop * f, swish, 0.0)
		if dead_amount > 0.001:
			target = target.lerp(Vector3(0.0, 0.30 * f, 0.0), dead_amount)
		tail[i].rotation = tail[i].rotation.lerp(target, 1.0 - pow(0.0006, delta))
