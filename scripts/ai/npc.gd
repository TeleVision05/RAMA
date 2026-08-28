class_name NPC
extends CharacterBody3D
## A person of Panchavati.
##
## Everything a villager needs to feel inhabited rather than placed: a ProcRig body
## with its own proportions and cloth, a DAILY SCHEDULE keyed to the sky clock, a
## wander that only ever steps on ground the WorldMap says is walkable, head-tracking
## and greetings for the player, and a panic that sends them running home when a
## rakshasa comes out of the treeline.
##
## The one rule applies here too: every position an NPC moves to is validated against
## the WorldMap first (depth, slope, bounds), and the feet conform through
## `rig.ground_fn`. Nothing floats, nothing wades into the Godavari by accident.

enum Role { ELDER, POTTER, WEAVER, FARMER, HERDER, FISHERMAN, MOTHER, CHILD, GUARD, TRAVELLER, HERMIT }
## The little repeating motion that says "this person has a job".
enum Work { NONE, WHEEL, LOOM, HOE, CAST, CARRY, WATCH, LEAN, BLESS, PLAY, HERD }
enum St { SLEEP, WAKE, WORK, SOCIAL, RETURN, TALK, FLEE }

const ST_NAMES := ["sleep", "wake", "work", "social", "return", "talk", "flee"]

# --- perception ------------------------------------------------------------
const LOOK_DIST := 7.0  # head turns to follow the player inside this
const GREET_DIST := 4.4  # a spoken greeting fires here
const GREET_RESET := 9.5  # ... and re-arms once you are back outside this
const FLEE_DIST := 18.0  # a rakshasa this close and they run
const FLEE_CLEAR := 28.0  # ... and keep running until it is this far

# --- locomotion ------------------------------------------------------------
const SPEED_AMBLE := 0.95
const SPEED_WALK := 1.42
const SPEED_HURRY := 2.20
const SPEED_RUN := 4.30
const ACCEL := 9.0
const TURN_RATE := 7.0
const ARRIVE := 0.55
const GRAVITY := 22.0
const SLOW_PERIOD := 0.33
const BARK_TIME := 3.6

# --- identity (set by NPCDirector via configure) ----------------------------
var id: String = "villager"
var display_name: String = "Villager"
var role: int = Role.FARMER
var work_kind: int = Work.NONE
var dialogue_id: String = ""
var home_pos: Vector3 = Vector3.ZERO
var work_pos: Vector3 = Vector3.ZERO
var social_pos: Vector3 = Vector3.ZERO
var night_pos: Vector3 = Vector3.ZERO  # where the nocturnal ones keep watch
var refuge_pos: Vector3 = Vector3.ZERO  # where they run when frightened
var wander_radius: float = 3.5
var nocturnal: bool = false  # guards, hermits and travellers keep watch
var prop_kind: String = "none"
var greetings: Array = []  # said the first time you come near
var greetings_met: Array = []  # said afterwards
var alarm_lines: Array = ["Rakshasas! Run!"]
var look_cfg: Dictionary = {}
var interact_range: float = 3.4
## Set true to log which mesh the face-exposing pass picked. Off in the game.
static var debug_face: bool = false

# --- refs ------------------------------------------------------------------
var map: WorldMap
var sky: SkySystem
var rig: ProcRig
var prop: Node3D
var bark: Label3D

# --- runtime ---------------------------------------------------------------
var state: int = St.WORK
var _goal: Vector3 = Vector3.ZERO
var _speed: float = SPEED_WALK
var _moving: bool = false
var _pause: float = 0.0
var _face_yaw: float = 0.0
var _t: float = 0.0
var _wt: float = 0.0  # work-motion clock, only runs while working
var _slow: float = 0.0
var _rng := RandomNumberGenerator.new()

var _player: Node3D = null
var _threat: Node3D = null
var _threat_clear: float = 0.0
var _greeted: bool = false
var _talking: bool = false
var _indoors: bool = false
var _bark_t: float = 0.0
var _stuck: float = 0.0
var _stuck_count: int = 0
var _last_check: Vector3 = Vector3.ZERO
var _active: bool = true
var _look_w: float = 0.0
var _crouch: float = 0.0
var _alarm_cool: float = 0.0
var _scan_yaw: float = 0.0
## Written by `_apply_work_pose` and undone before the next `rig.animate`. ProcRig
## LERPS the neck toward its target instead of assigning it, so an additive offset left
## in place compounds every frame — the hermit's +0.06 rad settled at +0.42 rad, a
## permanently craned neck. Measured 2026-08-28.
var _neck_add: float = 0.0
## What `_expose_face` measured on this head, for the test to assert against. Empty if
## the rig built a head this pass did not recognise.
var face_report: Dictionary = {}


# ===========================================================================
#  construction
# ===========================================================================
func configure(d: Dictionary) -> void:
	for k in d:
		if k == "look":
			look_cfg = d[k]
		else:
			set(String(k), d[k])


## Build the body. Call after `configure` and after the node is in the tree.
func build() -> void:
	add_to_group("npc")
	add_to_group("interactable")
	name = "NPC_" + id

	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_max_angle = deg_to_rad(58.0)
	floor_snap_length = 0.7
	slide_on_ceiling = false
	collision_layer = 4  # the player's mask includes 4, so they are solid
	collision_mask = 1 | 8  # terrain and buildings, but not each other

	var height: float = float(look_cfg.get("height", 1.72))
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = clampf(0.30 * (height / 1.80), 0.18, 0.36)
	cap.height = maxf(height * 0.95, cap.radius * 2.0 + 0.10)
	col.shape = cap
	col.position = Vector3(0, cap.height * 0.5, 0)
	add_child(col)

	_rng.seed = hash(id)
	_face_yaw = _rng.randf() * TAU
	rotation.y = _face_yaw

	rig = ProcRig.new()
	rig.name = "Rig"
	rig.configure(_rig_config(height))
	add_child(rig)
	# ProcRig collapses each joint's meshes into one draw at the end of build(), which
	# is a large win and also frees exactly the individual garment and head meshes the
	# two corrections below need. So: build unmerged, correct, then merge by hand.
	var was_merge: bool = ProcRig.merge_enabled
	ProcRig.merge_enabled = false
	rig.build()
	ProcRig.merge_enabled = was_merge
	rig.footstep.connect(_on_footstep)

	_fit_garments(height / 1.80)
	_fit_sash(height / 1.80)
	_expose_face()
	if was_merge:
		rig._merge_draws()
	_attach_prop()
	_build_bark(height)

	_goal = global_position
	_last_check = global_position
	set_physics_process(true)


func _rig_config(height: float) -> Dictionary:
	# ProcRig's proportions are absolute metres, so a shorter villager means scaling
	# every bone, not just the root — scaling the node would shrink the stride with it
	# and make short people skate.
	var s: float = height / 1.80
	var head_s: float = s * (1.24 if role == Role.CHILD else 1.0)
	var c := {
		"height": height,
		"hip_h": 0.94 * s,
		"thigh": 0.46 * s,
		"shin": 0.44 * s,
		"foot": 0.24 * s,
		"spine": 0.30 * s,
		"chest": 0.26 * s,
		"neck": 0.09 * s,
		"head": 0.115 * head_s,
		"shoulder_w": 0.175 * s,
		"upper_arm": 0.30 * s,
		"lower_arm": 0.28 * s,
		"hand": 0.10 * s,
		"hip_w": 0.092 * s,
		"build": float(look_cfg.get("build", 1.0)),
		"skin": "skin_warm",
		"cloth": String(look_cfg.get("cloth", "cloth_saffron")),
		"cloth2": String(look_cfg.get("cloth2", "cloth_white")),
		"hair_color": look_cfg.get("hair_color", Color(0.07, 0.055, 0.05)),
		"dhoti": true,
		"sash": bool(look_cfg.get("sash", true)),
		"jewellery": bool(look_cfg.get("jewellery", false)),
		"topknot": bool(look_cfg.get("topknot", false)),
		"beard": bool(look_cfg.get("beard", false)),
		"skin_tint": look_cfg.get("skin_tint", Color(1, 1, 1)),
		"cloth_tint": look_cfg.get("cloth_tint", Color(1, 1, 1)),
		"seed": hash(id),
	}
	return c


## ProcRig's dhoti, its pleat and its waist cord are built at absolute sizes — they
## are Rama's, and Rama is 1.80 m. On a 1.09 m child that cloth becomes a barrel from
## the ankles to the chest. Scale the group down to match the body.
##
## The group is identified by the "Dhoti" mesh and the siblings that follow it, which
## is how proc_rig.gd builds them. If that ever changes the loop simply finds nothing
## and the garment is left alone, which is the safe failure.
func _fit_garments(s: float) -> void:
	if absf(s - 1.0) < 0.04:
		return
	var kids := rig.hips.get_children()
	var start := -1
	for i in range(kids.size()):
		if kids[i] is MeshInstance3D and String(kids[i].name).begins_with("Dhoti"):
			start = i
			break
	if start < 0:
		return
	# A child wears a short wrap, not an ankle-length dhoti: scaled by height alone the
	# cloth reaches Ila's ankles and turns her into a cylinder with a head on it.
	var vy: float = s * (0.60 if role == Role.CHILD else 1.0)
	for i in range(start, kids.size()):
		var k = kids[i]
		if k is MeshInstance3D:
			var mi := k as MeshInstance3D
			mi.scale = mi.scale * Vector3(s, vy, s)
			mi.position = mi.position * s


## The uttariya has the same problem as the dhoti and a different parent. proc_rig pins
## a 0.60 m card 0.085 m off the chest — Rama's measurements, absolute — so on a 1.62 m
## woman it is both too long and standing clear of her, and reads as a painted board
## hanging in the air beside her rather than as cloth over the shoulder.
##
## Both corrections are MEASURED off the torso rather than nudged: the card is scaled
## with the body and then laid ON the torso's own surface, so it cannot float however
## the rig's proportions change. Flat panels on the chest are the sash and nothing
## else — the torso, the pectorals and the brass torque all have thickness in three
## axes, so the flatness test cannot pick them up by accident.
func _fit_sash(s: float) -> void:
	var torso_z := 0.0
	var panels: Array[MeshInstance3D] = []
	for k in rig.chest.get_children():
		if not (k is MeshInstance3D):
			continue
		var mi := k as MeshInstance3D
		if mi.mesh == null:
			continue
		var h := _half(mi)
		if minf(h.x, minf(h.y, h.z)) > 0.001:
			torso_z = maxf(torso_z, h.z)
		else:
			panels.append(mi)
	for mi in panels:
		mi.scale = mi.scale * Vector3(s, s * 0.88, 1.0)
		mi.position.x *= s
		mi.position.y *= s
		if torso_z > 0.001:
			mi.position.z = signf(mi.position.z) * torso_z * 0.88


## Make the face read. Four separate things are wrong with a stock ProcRig head at
## conversation distance, all of them geometry rather than shading, all MEASURED here
## against the skull's own mesh rather than guessed at with magic numbers:
##
##  1. THE FACE IS ON THE BACK OF THE HEAD. proc_rig builds the eyes, the nose and the
##     brow ridge at local +Z, but every other system treats -Z as forward: the player
##     sets `facing_yaw = atan2(-wish.x, -wish.z)`, and `_animate_legs` swings the feet
##     assuming -Z leads. So a villager walks and looks with the back of their skull.
##     Proved with a coloured marker at +-Z either side of the head, photographed from
##     the rig's own forward vector: only the -Z marker draws. RAMA HAS THIS TOO.
##  2. The features are BURIED. An eye's front face sits inside the skull surface, so
##     it never draws at all — which is why no character in this game has had a face.
##  3. The hair ovoid is barely wider than the skull, so it closes over the brow.
##  4. A full white eyeball proud of a flat cheek is a puppet, not a person.
##
## The corrections mirror the head into -Z, then place every feature relative to the
## SKULL SURFACE AT THAT HEIGHT (`_surface_z`) instead of a hand-tuned constant. That
## matters: the previous version shrank the hair cap to 0.88 x 0.82, which put it
## entirely INSIDE the skull and left all twelve villagers bald in every screenshot.
## Anything that has to clear the head is now expressed as "this far proud of the
## surface", and `face_report` records the clearances so the test can fail on them.
##
## All of this belongs in proc_rig.gd, where Rama would get it too — it lives here
## because that file has an owner and this one does not. Everything is found by
## material and by size, so if the rig ever builds a head differently the searches find
## nothing and the head is left exactly as it was built.
func _expose_face() -> void:
	face_report = {}
	var hair_col: Color = rig.cfg.hair_color
	var r: float = rig.cfg.head
	var cap: MeshInstance3D = null
	var skull: MeshInstance3D = null
	var beard: MeshInstance3D = null
	var cap_vol := 0.0
	var skull_vol := 0.0
	var whites: Array[MeshInstance3D] = []
	var irises: Array[MeshInstance3D] = []
	var nose: MeshInstance3D = null
	var nose_z := -1.0
	var brow: MeshInstance3D = null
	var brow_z := -1.0
	var all: Array[MeshInstance3D] = []
	for k in rig.head.get_children():
		if not (k is MeshInstance3D):
			continue
		var mi := k as MeshInstance3D
		var m := mi.material_override as StandardMaterial3D
		if m == null or mi.mesh == null:
			continue
		all.append(mi)
		var h := _half(mi)
		var vol: float = h.x * h.y * h.z
		if m.albedo_color.is_equal_approx(hair_col):
			# Three hair meshes share one colour: the skull cap (much the largest), the
			# jata above the crown, and the beard down at the jaw.
			if mi.position.y < r * 0.80:
				beard = mi
			elif vol > cap_vol:
				cap_vol = vol
				cap = mi
		elif m.albedo_texture == null:
			if m.albedo_color.r > 0.70:
				whites.append(mi)
			elif m.albedo_color.r < 0.30:
				irises.append(mi)
		else:
			# Skin. The biggest is the skull; the rest are ranked by how far forward
			# they were built, which is how the nose and the brow ridge are told apart.
			if vol > skull_vol:
				skull_vol = vol
				skull = mi
			if mi.position.z > nose_z:
				brow = nose
				brow_z = nose_z
				nose_z = mi.position.z
				nose = mi
			elif mi.position.z > brow_z:
				brow_z = mi.position.z
				brow = mi
	if all.is_empty() or skull == null:
		return

	# 1. Turn the head around. Every mesh on it is an ovoid, a sphere or a tube, all of
	# them symmetric in Z, so mirroring the offsets is the whole fix.
	for mi in all:
		mi.position.z = -mi.position.z

	var sk := _half(skull)
	var sc := _centre(skull)

	# 2. HAIR. It has to stay WIDER than the skull or it is simply inside it. Push it
	# back off the brow rather than making it smaller — shrinking is what produced a
	# village of bald men. The scale is only ever increased, never reduced.
	if cap != null:
		var ch := _half(cap)
		if ch.x > 0.0001 and ch.z > 0.0001:
			cap.scale.x *= maxf(1.0, sk.x * 1.06 / ch.x)
			cap.scale.z *= maxf(1.0, sk.z * 1.02 / ch.z)
		cap.position.z = sk.z * 0.40
		cap.position.y += r * 0.03

	# 3. The rig's brow RIDGE, pushed out, reads as a welder's visor. It wants to be a
	# hint under the skin, not a shelf.
	if brow != null and absf(brow.position.z) > r * 0.1:
		brow.position.z = -r * 0.12

	# 4. EYES. An almond, not a ping-pong ball: squashed to roughly 2:1, sat about 6 mm
	# proud of the cheek (a real cornea is 4-6 mm), the white taken off paper-bright so
	# it stops shouting, and the iris opened up so there is more eye than sclera.
	var eye_y: float = sc.y + sk.y * 0.12
	var eye_proud := 0.0
	var eye_front := 0.0
	for e in whites:
		eye_y = e.position.y
		var surf: float = _surface_z(sk, sc, eye_y)
		e.scale = e.scale * Vector3(0.72, 0.42, 0.85)
		e.position.z = -(surf - r * 0.035)
		eye_proud = (_half(e).z - r * 0.035)
		eye_front = e.position.z - _half(e).z
		var em := e.material_override as StandardMaterial3D
		if em != null:
			em.albedo_color = Color(0.80, 0.77, 0.72)
			em.roughness = 0.45
	# The iris is set AGAINST THE WHITE, not against the skull. Placed against the
	# skull it ended up 5 mm in front of the sclera, and since only the cap of a
	# sphere poking through a surface is ever visible, it covered the entire eye: the
	# villagers looked out through two dark slits. Half a millimetre proud is enough.
	for i in irises:
		i.scale = i.scale * Vector3(0.55, 0.62, 0.90)
		i.position.z = eye_front - r * 0.005 + _half(i).z

	# 5. The nose, out through the surface by about a centimetre.
	var nose_proud := 0.0
	if nose != null and nose_z > r * 0.5:
		nose.position.z = -(_surface_z(sk, sc, nose.position.y) - r * 0.06)
		nose_proud = _half(nose).z - r * 0.06

	# 6. A beard that hangs off the JAW instead of floating in front of the mouth.
	if beard != null:
		var by: float = r * 0.10
		beard.scale = beard.scale * Vector3(0.80, 0.95, 0.62)
		beard.position.y = by
		# The FRONT of the beard clears the jaw by two millimetres and no more; the
		# rest of the ovoid stays inside the head. Placed by its centre instead it
		# jutted straight out under the mouth and the elder grew a beak.
		beard.position.z = -(_surface_z(sk, sc, by) + r * 0.02) + _half(beard).z

	var mouth_proud := _face_detail(r, sk, sc, eye_y, hair_col)

	var hair_x := 0.0
	var hair_z := 0.0
	if cap != null:
		hair_x = _half(cap).x - sk.x
		hair_z = _half(cap).z - sk.z
	face_report = {
		"skull": sk,
		"hair": cap != null,
		"hair_over_x": hair_x,
		"hair_over_z": hair_z,
		"eyes": whites.size(),
		"eye_proud": eye_proud,
		"nose_proud": nose_proud,
		"mouth_proud": mouth_proud,
		"beard": beard != null,
		# Every feature must now sit on -Z. This is the assertion that catches a
		# proc_rig that stops building the face at +Z.
		"front_z": _front_extreme(all),
	}
	if debug_face:
		print("[npc] %s face: %s" % [id, face_report])


## Half-extents of a head mesh in the head's own space. These meshes carry no rotation,
## which is what makes the cheap AABB maths below legitimate.
static func _half(mi: MeshInstance3D) -> Vector3:
	var a: AABB = mi.mesh.get_aabb()
	return (a.size * 0.5).abs() * mi.scale.abs()


static func _centre(mi: MeshInstance3D) -> Vector3:
	var a: AABB = mi.mesh.get_aabb()
	return (a.position + a.size * 0.5) * mi.scale + mi.position


## How far forward the skull's surface reaches at height `y`. The skull is an ovoid, so
## an ellipsoid is a close enough model and it is the only thing a feature needs to
## clear. Everything on the face is placed against this rather than against a constant.
static func _surface_z(half: Vector3, centre: Vector3, y: float) -> float:
	var t: float = clampf((y - centre.y) / maxf(half.y, 0.0001), -1.0, 1.0)
	return half.z * sqrt(maxf(0.0, 1.0 - t * t))


## The most-forward point of any head mesh. Negative means the face is on -Z, which is
## the direction the body actually walks and looks.
static func _front_extreme(meshes: Array[MeshInstance3D]) -> float:
	var f := 1.0e9
	for mi in meshes:
		f = minf(f, _centre(mi).z - _half(mi).z)
	return f


## A brow line and a mouth: three small bars, each mostly sunk into the skull, which is
## all it takes for a head to stop being an egg. They are placed against the measured
## surface, so they cannot end up inside it. Returns how far the mouth stands proud.
func _face_detail(r: float, sk: Vector3, sc: Vector3, eye_y: float, hair_col: Color) -> float:
	var m := StandardMaterial3D.new()
	# Tied to the hair so a silver-haired elder does not get a young man's black brows.
	m.albedo_color = hair_col.lerp(Color(0.165, 0.100, 0.072), 0.45)
	m.roughness = 0.78
	var by: float = eye_y + r * 0.17
	for sx in [-1.0, 1.0]:
		var b := MeshInstance3D.new()
		b.name = "Brow" + ("L" if sx > 0.0 else "R")
		b.mesh = MeshKit.box(Vector3(r * 0.34, r * 0.045, r * 0.10))
		b.material_override = m
		b.position = Vector3(sx * r * 0.36, by, -(_surface_z(sk, sc, by) - r * 0.010))
		b.rotation = Vector3(0.0, 0.0, sx * 0.07)
		rig.head.add_child(b)
	var my: float = eye_y - r * 0.34
	var mo := MeshInstance3D.new()
	mo.name = "Mouth"
	mo.mesh = MeshKit.box(Vector3(r * 0.40, r * 0.050, r * 0.10))
	mo.material_override = m
	mo.position = Vector3(0.0, my, -(_surface_z(sk, sc, my) - r * 0.005))
	rig.head.add_child(mo)
	return r * 0.05 - r * 0.005


func set_world(m: WorldMap, s: SkySystem) -> void:
	map = m
	sky = s
	if rig:
		rig.ground_fn = func(x, z): return m.height_at(x, z)


func _build_bark(height: float) -> void:
	bark = Label3D.new()
	bark.name = "Bark"
	bark.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Sized off a real head rather than off a screenshot: 0.048 m per em puts a short
	# line at about 0.5 m, roughly a shoulder's width, which is what a spoken line
	# should look like above somebody. At 0.0019 it was half their body height.
	bark.font_size = 40
	bark.pixel_size = 0.0012
	bark.outline_size = 12
	bark.outline_modulate = Color(0.06, 0.04, 0.03, 0.92)
	bark.modulate = Color(1.0, 0.955, 0.86)
	bark.width = 320.0
	bark.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bark.position = Vector3(0, height + 0.44, 0)
	bark.visible = false
	add_child(bark)


# --- held props ------------------------------------------------------------
func _attach_prop() -> void:
	match prop_kind:
		"staff":
			prop = Weapons.staff()
			prop.scale = Vector3.ONE * clampf(float(look_cfg.get("height", 1.72)) / 1.80, 0.6, 1.15)
			rig.hand_attach["R"].add_child(prop)
			prop.position = Vector3(0.02, 0.09, 0.03)
			prop.rotation = Vector3(0.05, 0.0, 0.04)
		"staff_yoke":
			# Across the shoulders, arms draped over it — every herder in every field.
			prop = Weapons.staff()
			prop.scale = Vector3.ONE * clampf(float(look_cfg.get("height", 1.72)) / 1.80, 0.6, 1.15)
			rig.chest.add_child(prop)
			prop.position = Vector3(0.0, rig.cfg.chest * 0.86, -0.09)
			prop.rotation = Vector3(0.0, 0.0, PI * 0.5)
		"pot_head":
			prop = pot_mesh(clampf(float(look_cfg.get("height", 1.72)) / 1.80, 0.7, 1.1))
			rig.head.add_child(prop)
			prop.position = Vector3(0.0, rig.cfg.head * 2.02, -0.01)
		"kamandalu":
			prop = pot_mesh(0.52)
			rig.hand_attach["L"].add_child(prop)
			prop.position = Vector3(0.0, -0.075, 0.05)
		"basket":
			# On the hip, parented to the pelvis: a basket held in the crook of the arm
			# follows the hand, and the hand is busy at a loom half the day.
			prop = basket_mesh()
			rig.hips.add_child(prop)
			prop.position = Vector3(0.215, -0.03, 0.02)
			prop.rotation = Vector3(0.10, 0.0, -0.30)
			prop.scale = Vector3.ONE * 0.82
		"sickle":
			prop = sickle_mesh()
			rig.hand_attach["R"].add_child(prop)
			prop.position = Vector3(0.0, -0.03, 0.02)
			prop.rotation = Vector3(-0.5, 0.0, 0.0)
		"net":
			prop = net_mesh()
			rig.hand_attach["R"].add_child(prop)
			prop.position = Vector3(0.0, -0.06, 0.03)
		_:
			prop = null


## A terracotta water pot: shoulder, neck and a flared lip.
static func pot_mesh(scale_f: float = 1.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Pot"
	var body := MeshInstance3D.new()
	body.mesh = (
		MeshKit
		. profile_loft(
			0.30,
			[
				[0.00, 0.052, 0.052],
				[0.10, 0.098, 0.098],
				[0.30, 0.140, 0.140],
				[0.50, 0.152, 0.152],
				[0.70, 0.128, 0.128],
				[0.84, 0.072, 0.072],
				[0.93, 0.066, 0.066],
				[1.00, 0.090, 0.090],
			],
			14
		)
	)
	body.material_override = Mats.pbr("terracotta", 1.6)
	root.add_child(body)
	root.scale = Vector3.ONE * scale_f
	return root


## A coiled reed basket.
static func basket_mesh() -> Node3D:
	var root := Node3D.new()
	root.name = "Basket"
	var body := MeshInstance3D.new()
	body.mesh = (
		MeshKit
		. profile_loft(
			0.22,
			[
				[0.00, 0.085, 0.085],
				[0.20, 0.125, 0.125],
				[0.70, 0.158, 0.158],
				[1.00, 0.172, 0.172],
			],
			14
		)
	)
	body.material_override = Mats.pbr("thatch", 2.4)
	root.add_child(body)
	var rim := MeshInstance3D.new()
	rim.mesh = MeshKit.tube(0.024, [[0.0, 0.178], [1.0, 0.176]], 16, 1.0)
	rim.material_override = Mats.pbr("wood_beam", 3.0)
	rim.position = Vector3(0, 0.208, 0)
	root.add_child(rim)
	return root


## A short curved sickle: a wooden haft and an iron crescent.
static func sickle_mesh() -> Node3D:
	var root := Node3D.new()
	root.name = "Sickle"
	var haft := MeshInstance3D.new()
	haft.mesh = MeshKit.tube(0.17, [[0.0, 0.018], [1.0, 0.015]], 8)
	haft.material_override = Mats.pbr("wood_beam", 5.0)
	haft.position = Vector3(0, -0.085, 0)
	root.add_child(haft)
	var blade := MeshInstance3D.new()
	blade.mesh = MeshKit.tube(0.30, [[0.0, 0.017], [0.5, 0.013], [1.0, 0.004]], 6, 0.30, Vector3(0.20, 0, 0.0))
	blade.material_override = Mats.flat(Color(0.55, 0.54, 0.52), 0.36, 0.85)
	blade.position = Vector3(0, 0.085, 0)
	root.add_child(blade)
	return root


## A bundled cast net on a float ring.
static func net_mesh() -> Node3D:
	var root := Node3D.new()
	root.name = "Net"
	var m := Mats.flat(Color(0.74, 0.68, 0.52), 0.92)
	var bundle := MeshInstance3D.new()
	bundle.mesh = MeshKit.ovoid(0.105, 0.26, 0.5, 10, 8)
	bundle.material_override = m
	bundle.position = Vector3(0, -0.12, 0.02)
	root.add_child(bundle)
	for i in range(4):
		var a: float = TAU * float(i) / 4.0
		var f := MeshInstance3D.new()
		f.mesh = MeshKit.sphere(0.024, 6, 5)
		f.material_override = Mats.pbr("wood_beam", 4.0)
		f.position = Vector3(cos(a) * 0.09, -0.23, sin(a) * 0.09)
		root.add_child(f)
	return root


# ===========================================================================
#  interactable contract
# ===========================================================================
func interact_prompt() -> String:
	return "Speak with %s" % display_name


func can_interact(_player: Node) -> bool:
	return _active and not _indoors and not _talking and state != St.FLEE and dialogue_id != ""


func interact(player: Node) -> void:
	if not can_interact(player):
		return
	var ds := DialogueSystem.instance(self)
	ds.start(dialogue_id, self, player)


## Turn to face a point and stand still for a moment. The hook for anything that
## needs a villager's attention: a cutscene, a quest beat, a screenshot.
func face_point(p: Vector3) -> void:
	_face_yaw = _yaw_to(p)
	rotation.y = _face_yaw
	_moving = false
	_pause = maxf(_pause, 4.0)
	if rig:
		rig.look_target = p
		rig.look_weight = 1.0
		_look_w = 1.0


## Called by DialogueSystem so the villager stands still and looks at you while you
## are talking to them, instead of ambling off mid-sentence.
func set_talking(on: bool) -> void:
	_talking = on
	if on:
		_moving = false
		_pause = 0.6
		hide_bark()
	else:
		_pause = 1.2


# ===========================================================================
#  streaming
# ===========================================================================
func set_active(on: bool) -> void:
	if on == _active:
		return
	_active = on
	visible = on and not _indoors
	set_physics_process(on)
	if on:
		# Coming back into range: skip them forward to wherever the clock says they
		# should be, so the village is never caught mid-yesterday.
		snap_to_schedule()


func is_active() -> bool:
	return _active


## Teleport onto the current schedule anchor, grounded.
func snap_to_schedule() -> void:
	if map == null:
		return
	var sc := _schedule()
	var p: Vector2 = Vector2(sc.pos.x, sc.pos.z)
	var f := _walkable_near(p, maxf(sc.radius, 1.0))
	global_position = Vector3(f.x, map.height_at(f.x, f.y) + 0.10, f.y)
	velocity = Vector3.ZERO
	_goal = global_position
	_moving = false
	_pause = _rng.randf_range(0.4, 2.0)


# ===========================================================================
#  simulation
# ===========================================================================
func _physics_process(delta: float) -> void:
	if map == null:
		return
	_t += delta
	_alarm_cool = maxf(0.0, _alarm_cool - delta)
	_slow -= delta
	if _slow <= 0.0:
		_slow_tick(SLOW_PERIOD + absf(_slow))
		_slow = SLOW_PERIOD
	_plan(delta)
	_steer(delta)
	_drive_rig(delta)
	_tick_bark(delta)


## The 3 Hz brain: who is nearby, is anything dangerous, are we indoors.
func _slow_tick(dt: float) -> void:
	if _threat != null and not is_instance_valid(_threat):
		_threat = null
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D

	# --- danger -----------------------------------------------------------
	var nearest: Node3D = null
	var nd: float = 1.0e9
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node3D):
			continue
		if e.has_method("is_alive") and not e.is_alive():
			continue
		var d: float = global_position.distance_to((e as Node3D).global_position)
		if d < nd:
			nd = d
			nearest = e as Node3D
	if nearest != null and nd < FLEE_DIST:
		if _threat == null:
			_alarm()
		_threat = nearest
		_threat_clear = 0.0
	elif _threat != null:
		if nearest == null or nd > FLEE_CLEAR:
			_threat_clear += dt
			if _threat_clear > 2.5:
				_threat = null
		else:
			_threat_clear = 0.0

	# --- the player -------------------------------------------------------
	if _player and _threat == null:
		var pd: float = global_position.distance_to(_player.global_position)
		if not _greeted and pd < GREET_DIST and not _indoors and _active:
			_greeted = true
			_greet()
		elif _greeted and pd > GREET_RESET:
			_greeted = false

	# --- stuck ------------------------------------------------------------
	if _moving:
		if global_position.distance_to(_last_check) < 0.055:
			_stuck += dt
			if _stuck > 1.2:
				_stuck = 0.0
				_unstick()
		else:
			_stuck = 0.0
			_stuck_count = 0
	else:
		_stuck = 0.0
	_last_check = global_position


func _greet() -> void:
	var pool: Array = greetings_met if bool(GameState.get_flag("met_" + id, false)) else greetings
	if pool.is_empty():
		pool = greetings
	if pool.is_empty():
		return
	var line := String(pool[_rng.randi() % pool.size()])
	say(line)
	AudioDirector.play_3d("ui_hover", global_position + Vector3(0, 1.4, 0), -21.0)
	EventBus.npc_greeted.emit(id, display_name, line)


func _alarm() -> void:
	if _alarm_cool > 0.0:
		return
	_alarm_cool = 6.0
	if not alarm_lines.is_empty():
		say(String(alarm_lines[_rng.randi() % alarm_lines.size()]), 2.6)
	AudioDirector.play_3d("ui_close", global_position + Vector3(0, 1.4, 0), -14.0)
	EventBus.npc_alarmed.emit(id, _threat)


# --- schedule ---------------------------------------------------------------
## Where this person is supposed to be at the current hour, and how far they may
## drift from it.
func _schedule() -> Dictionary:
	var h: float = sky.time_of_day if sky else 12.0
	if h < 5.4 or h >= 20.9:
		if nocturnal:
			# The guard holds the gate, the hermit keeps his vigil, the traveller
			# sleeps by the square because he has nowhere else to be.
			return {"pos": night_pos, "st": St.WORK, "radius": minf(wander_radius, 2.4), "speed": SPEED_AMBLE}
		return {"pos": home_pos, "st": St.SLEEP, "radius": 0.8, "speed": SPEED_WALK}
	if h < 7.3:
		# Out of the door at first light: stretch, sweep the step, fetch water.
		return {"pos": home_pos, "st": St.WAKE, "radius": 2.6, "speed": SPEED_AMBLE}
	if h < 17.1:
		return {"pos": work_pos, "st": St.WORK, "radius": wander_radius, "speed": SPEED_WALK}
	if h < 19.7:
		return {"pos": social_pos, "st": St.SOCIAL, "radius": 5.0, "speed": SPEED_AMBLE}
	return {"pos": home_pos, "st": St.RETURN, "radius": 1.6, "speed": SPEED_HURRY}


func _plan(delta: float) -> void:
	if _threat != null and not is_instance_valid(_threat):
		_threat = null
	var sc := _schedule()
	var want_state: int = sc.st

	if _talking:
		want_state = St.TALK
	elif _threat != null:
		want_state = St.FLEE

	if want_state != state:
		state = want_state
		_pause = 0.0
		_moving = false
		if state != St.WORK:
			_wt = 0.0
		_repick()

	match state:
		St.TALK:
			_moving = false
			if _player:
				_face_yaw = _yaw_to(_player.global_position)
		St.FLEE:
			_speed = SPEED_RUN
			_pause = 0.0
			# Head for cover: the village square, angled away from whatever is chasing.
			var away := global_position - _threat.global_position
			away.y = 0.0
			if away.length() < 0.1:
				away = Vector3.FORWARD
			var to_ref := refuge_pos - global_position
			to_ref.y = 0.0
			var dir := away.normalized()
			if to_ref.length() > 3.0 and to_ref.normalized().dot(away.normalized()) > -0.25:
				dir = to_ref.normalized()
			var p := Vector2(global_position.x, global_position.z) + Vector2(dir.x, dir.z) * 7.0
			var f := _walkable_near(p, 5.0)
			_goal = Vector3(f.x, map.height_at(f.x, f.y), f.y)
			_moving = true
			_face_yaw = _yaw_to(_goal)
		_:
			_speed = sc.speed
			if _moving:
				var flat := Vector2(_goal.x - global_position.x, _goal.z - global_position.z)
				if flat.length() < ARRIVE:
					_moving = false
					_pause = _pause_for(state)
				else:
					_face_yaw = _yaw_to(_goal)
			else:
				_pause -= delta
				if _pause <= 0.0:
					_repick()

	# Indoors at night, once they have actually reached the door.
	var want_in: bool = state == St.SLEEP and global_position.distance_to(home_pos) < 2.2
	if want_in != _indoors:
		_indoors = want_in
		visible = _active and not _indoors
		if _indoors:
			hide_bark()


## Blocked by a bank, a wall or a rock. Try to step around it; if that keeps failing
## and nobody is near enough to notice, take the schedule anchor directly rather than
## stand in a corner for the rest of the day.
func _unstick() -> void:
	_stuck_count += 1
	if _stuck_count >= 4:
		var unseen := true
		if _player != null and is_instance_valid(_player):
			unseen = global_position.distance_to(_player.global_position) > 26.0
		if unseen:
			_stuck_count = 0
			snap_to_schedule()
			return
	var here := Vector2(global_position.x, global_position.z)
	var to_goal := Vector2(_goal.x - global_position.x, _goal.z - global_position.z)
	if to_goal.length() < 0.1:
		to_goal = Vector2(1.0, 0.0)
	to_goal = to_goal.normalized()
	# A detour is a step around an obstacle, not a licence to leave the village. Without
	# the leash a villager who gets stuck repeatedly walks a random 2.5-5.5 m every
	# time, and the weaver ended up 9.2 m off her loom at noon with a 2.4 m wander
	# radius. Two passes, so a genuinely boxed-in villager can still break out.
	var sc := _schedule()
	var anchor := Vector2(sc.pos.x, sc.pos.z)
	var leash: float = maxf(sc.radius, 1.0) + 6.0
	for pass_i in range(2):
		for i in range(12):
			var side: float = 1.0 if i % 2 == 0 else -1.0
			var p := here + to_goal.rotated(deg_to_rad(30.0 + float(i) * 11.0) * side) * _rng.randf_range(2.5, 5.5)
			if pass_i == 0 and p.distance_to(anchor) > leash:
				continue
			if _walkable(p) and _clear_line(here, p):
				_goal = Vector3(p.x, map.height_at(p.x, p.y), p.y)
				_moving = true
				_face_yaw = _yaw_to(_goal)
				return
	_repick()


func _pause_for(st: int) -> float:
	match st:
		St.WORK:
			return _rng.randf_range(4.0, 9.0)
		St.SOCIAL:
			return _rng.randf_range(3.0, 7.0)
		St.WAKE:
			return _rng.randf_range(2.0, 5.0)
		St.SLEEP:
			return _rng.randf_range(6.0, 12.0)
	return _rng.randf_range(1.5, 3.5)


## Choose the next place to stand, on ground the map says is walkable.
func _repick() -> void:
	var sc := _schedule()
	var anchor := Vector2(sc.pos.x, sc.pos.z)
	var radius: float = sc.radius
	if role == Role.CHILD and state == St.WORK:
		radius = maxf(radius, 7.0)
	var here := Vector2(global_position.x, global_position.z)
	var target := anchor
	if radius > 0.9:
		for i in range(14):
			var a: float = _rng.randf() * TAU
			var r: float = sqrt(_rng.randf()) * radius
			var p := anchor + Vector2(cos(a), sin(a)) * r
			if not _walkable(p):
				continue
			if not _clear_line(here, p):
				continue
			if p.distance_to(here) < 0.9:
				continue
			target = p
			break
	target = _walkable_near(target, 3.0)
	_goal = Vector3(target.x, map.height_at(target.x, target.y), target.y)
	_moving = true
	if role == Role.CHILD and state == St.WORK:
		_speed = SPEED_RUN * 0.62
	_face_yaw = _yaw_to(_goal)


func _walkable(p: Vector2) -> bool:
	if not map.in_bounds(p.x, p.y):
		return false
	if map.water_depth_at(p.x, p.y) > 0.06:
		return false
	if map.slope_at(p.x, p.y) > 0.36:
		return false
	# Fishermen work the bank; everyone else keeps a respectful distance from a
	# river that has drowned people.
	var min_river: float = 2.2 if role == Role.FISHERMAN else 5.0
	if map.river_dist(p) < min_river:
		return false
	return true


## No stepping over the river or off a cliff on the way, either.
func _clear_line(a: Vector2, b: Vector2) -> bool:
	var n: int = int(maxf(2.0, a.distance_to(b) / 1.6))
	for i in range(1, n + 1):
		var p := a.lerp(b, float(i) / float(n))
		if not map.in_bounds(p.x, p.y):
			return false
		if map.water_depth_at(p.x, p.y) > 0.20:
			return false
		if map.slope_at(p.x, p.y) > 0.44:
			return false
	return true


## Spiral out from `p` until the ground is walkable. Used for spawning and for
## recovering when a schedule anchor lands somewhere silly.
func _walkable_near(p: Vector2, max_r: float) -> Vector2:
	if _walkable(p):
		return p
	var r: float = 0.8
	while r <= max_r:
		for i in range(10):
			var a: float = TAU * float(i) / 10.0 + r
			var q := p + Vector2(cos(a), sin(a)) * r
			if _walkable(q):
				return q
		r += 0.9
	return p


func _yaw_to(target: Vector3) -> float:
	var d := target - global_position
	d.y = 0.0
	if d.length_squared() < 0.0004:
		return _face_yaw
	return atan2(-d.x, -d.z)


# --- motion ----------------------------------------------------------------
func _steer(delta: float) -> void:
	var want := Vector3.ZERO
	if _moving:
		var to := _goal - global_position
		to.y = 0.0
		var d := to.length()
		if d > ARRIVE:
			want = to / d * _speed
	velocity.x = move_toward(velocity.x, want.x, ACCEL * delta)
	velocity.z = move_toward(velocity.z, want.z, ACCEL * delta)
	if is_on_floor():
		velocity.y = -0.6
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()

	var turn: float = TURN_RATE * (1.7 if state == St.FLEE else 1.0) * delta
	rotation.y = _approach_angle(rotation.y, _face_yaw, turn)


static func _approach_angle(cur: float, target: float, max_step: float) -> float:
	var d: float = wrapf(target - cur, -PI, PI)
	return cur + clampf(d, -max_step, max_step)


# --- presentation ----------------------------------------------------------
func _drive_rig(delta: float) -> void:
	var sp := Vector2(velocity.x, velocity.z).length()

	# Head tracking: they notice you well before you are close enough to talk.
	var want_look: float = 0.0
	var look_at_p := global_position + Vector3(0, 1.5, 0) - global_transform.basis.z * 4.0
	if _threat != null and is_instance_valid(_threat):
		want_look = 1.0
		look_at_p = _threat.global_position + Vector3(0, 1.2, 0)
	elif _talking and _player:
		want_look = 1.0
		look_at_p = _player.global_position + Vector3(0, 1.52, 0)
	elif _player and not _indoors:
		var d: float = global_position.distance_to(_player.global_position)
		if d < LOOK_DIST:
			want_look = clampf(1.0 - (d - 1.0) / LOOK_DIST, 0.0, 1.0)
			look_at_p = _player.global_position + Vector3(0, 1.52, 0)
	if want_look < 0.01 and work_kind == Work.WATCH and not _moving:
		# A guard with nobody to watch sweeps the road.
		_scan_yaw = sin(_t * 0.32) * 1.0
		want_look = 0.55
		look_at_p = (
			global_position
			+ Vector3(0, 1.5, 0)
			+ (global_transform.basis * Vector3(sin(_scan_yaw), 0.0, -cos(_scan_yaw))) * 6.0
		)
	_look_w = lerpf(_look_w, want_look, 1.0 - pow(0.002, delta))
	rig.look_weight = _look_w
	rig.look_target = look_at_p

	if state == St.WORK:
		_wt += delta
	var target_crouch: float = 0.0
	if not _moving and state == St.WORK:
		match work_kind:
			Work.WHEEL:
				target_crouch = 0.30
			Work.LOOM:
				target_crouch = 0.22
			Work.CAST:
				target_crouch = 0.16
	_crouch = lerpf(_crouch, target_crouch, 1.0 - pow(0.004, delta))

	if state == St.FLEE:
		rig.hurt_amount = maxf(rig.hurt_amount, 0.30)

	# The neck is the one joint proc_rig lerps rather than assigns, so last frame's
	# additive pose has to come off BEFORE it lerps or the offset compounds.
	rig.neck.rotation.x -= _neck_add
	_neck_add = 0.0

	(
		rig
		. animate(
			delta,
			{
				"speed": sp,
				"on_floor": is_on_floor(),
				"air_time": 0.0,
				"dodge": 0.0,
				"crouch": _crouch,
			}
		)
	)
	_apply_work_pose(delta)


## Additive work poses, layered on top of the finished locomotion pose. ProcRig
## slerps toward its own targets each frame, so writing the joints afterwards is
## what makes a potter look like a potter without touching the shared rig.
func _apply_work_pose(_delta: float) -> void:
	if state == St.FLEE:
		# Arms up, body pitched forward: running away, not jogging.
		_set_arm("L", Vector3(-0.9, 0.0, 0.75), Vector3(-1.9, 0, 0))
		_set_arm("R", Vector3(-0.9, 0.0, -0.75), Vector3(-1.9, 0, 0))
		rig.chest.rotation.x += 0.22
		return
	if _moving and work_kind != Work.CARRY and work_kind != Work.HERD:
		return
	var w: float = _wt

	match work_kind:
		Work.WHEEL:
			# Hunched over the wheel, hands cupped and turning.
			rig.spine.rotation.x += 0.40
			rig.chest.rotation.x += 0.16
			var a: float = w * 3.1
			_set_arm("L", Vector3(-1.02 + sin(a) * 0.10, 0.0, 0.34), Vector3(-1.30 + cos(a) * 0.16, 0, 0))
			_set_arm("R", Vector3(-1.02 + sin(a + 1.6) * 0.10, 0.0, -0.34), Vector3(-1.30 + cos(a + 1.6) * 0.16, 0, 0))
		Work.LOOM:
			# The shuttle goes across, the beater comes back.
			rig.spine.rotation.x += 0.24
			var s: float = sin(w * 1.9)
			_set_arm("L", Vector3(-1.20, 0.0, 0.22 + s * 0.34), Vector3(-1.35 - s * 0.30, 0, 0))
			_set_arm("R", Vector3(-1.20, 0.0, -0.22 + s * 0.34), Vector3(-1.35 + s * 0.30, 0, 0))
		Work.HOE:
			# A cutting stroke with the sickle, then a slow reach for the next stalk.
			var t: float = fposmod(w * 0.62, 1.0)
			var e: float = smoothstep(0.0, 0.45, t) - smoothstep(0.55, 1.0, t)
			rig.spine.rotation.x += 0.30 + e * 0.28
			_set_arm("R", Vector3(-0.55 - e * 0.70, 0.0, -0.30 + e * 0.55), Vector3(-1.05 + e * 0.55, 0, 0))
			_set_arm("L", Vector3(-0.95 - e * 0.25, 0.0, 0.42), Vector3(-1.40, 0, 0))
		Work.CAST:
			# Crouched at the water's edge, gathering and swinging the net.
			var t2: float = fposmod(w * 0.34, 1.0)
			var sw: float = smoothstep(0.55, 0.78, t2) * (1.0 - smoothstep(0.82, 1.0, t2))
			rig.spine.rotation.x += 0.34 - sw * 0.30
			_set_arm("R", Vector3(-0.70 - sw * 1.55, 0.0, -0.40 - sw * 0.35), Vector3(-1.55 + sw * 1.30, 0, 0))
			_set_arm("L", Vector3(-0.85, 0.0, 0.40), Vector3(-1.50, 0, 0))
		Work.CARRY:
			# One hand up steadying the pot on her head, the other swinging free.
			# Written as directions, not eulers: the euler version put the arm straight
			# up and BACKWARD, so she waved at the sky while the pot sat unheld.
			var bob: float = sin(w * 0.9) * 0.035
			_aim_arm("L", Vector3(0.30, 0.95, -0.06), Vector3(-0.42 + bob, 0.86, -0.28))
			rig.chest.rotation.z += 0.03
		Work.HERD:
			# Arms draped over the staff across the shoulders.
			_set_arm("L", Vector3(-1.42, 0.0, 1.32), Vector3(-0.55, 0, 0))
			_set_arm("R", Vector3(-1.42, 0.0, -1.32), Vector3(-0.55, 0, 0))
		Work.WATCH:
			# At ease with the staff planted, weight shifting foot to foot.
			_set_arm("R", Vector3(-0.30, 0.0, -0.26), Vector3(-0.28, 0, 0))
			_set_arm("L", Vector3(0.05 + sin(w * 0.5) * 0.03, 0.0, 0.20), Vector3(-0.30, 0, 0))
			rig.hips.rotation.z += sin(_t * 0.42) * 0.035
		Work.LEAN:
			# Leaning on the staff, one hip cocked: a man who has walked a long way.
			_set_arm("R", Vector3(-0.34, 0.0, -0.20), Vector3(-0.20, 0, 0))
			_set_arm("L", Vector3(0.12, 0.0, 0.34), Vector3(-0.55, 0, 0))
			rig.hips.rotation.z += 0.075 + sin(_t * 0.3) * 0.02
			rig.chest.rotation.z -= 0.05
		Work.BLESS:
			# The right hand raised in abhaya, the kamandalu in the left.
			_set_arm("R", Vector3(-1.62 + sin(w * 0.6) * 0.04, 0.0, -0.34), Vector3(-1.25, 0, 0))
			_set_arm("L", Vector3(-0.42, 0.0, 0.30), Vector3(-1.05, 0, 0))
			_neck_add = 0.06
			rig.neck.rotation.x += _neck_add
		Work.PLAY:
			# A child between one dash and the next: arms out for balance, weight
			# rocking foot to foot, chin up because everything is happening above them.
			var sw2: float = sin(w * 2.6)
			# The elbow has to break, or the arms come out as a scarecrow's crossbar.
			_aim_arm("L", Vector3(0.74, 0.26 + sw2 * 0.22, -0.42), Vector3(0.42, 0.52 - sw2 * 0.30, -0.74))
			_aim_arm("R", Vector3(-0.74, 0.26 - sw2 * 0.22, -0.42), Vector3(-0.42, 0.52 + sw2 * 0.30, -0.74))
			rig.chest.rotation.x -= 0.07
			rig.hips.rotation.z += sw2 * 0.055
			_neck_add = -0.05
			rig.neck.rotation.x += _neck_add
		_:
			pass


func _set_arm(side: String, sh: Vector3, el: Vector3) -> void:
	rig.shoulder[side].basis = Basis.from_euler(sh)
	rig.elbow[side].basis = Basis.from_euler(el)


## Aim a whole arm by DIRECTION rather than by euler, both directions given in the
## chest's space. Shoulder eulers compose as Y*X*Z through two joints and are not
## readable by eye: written that way, the water carrier's raised arm pointed up and
## behind her, nowhere near the pot it was supposed to be steadying.
func _aim_arm(side: String, upper: Vector3, fore: Vector3) -> void:
	var sh := _aim(upper)
	rig.shoulder[side].basis = sh
	rig.elbow[side].basis = sh.inverse() * _aim(fore)


## The basis that takes a limb's rest direction (-Y, hanging down) onto `dir`.
static func _aim(dir: Vector3) -> Basis:
	var y := -dir.normalized()
	var ref := Vector3(0, 0, 1)
	if absf(y.dot(ref)) > 0.94:
		ref = Vector3(1, 0, 0)
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y))


func _on_footstep(_side: String, pos: Vector3, sp: float) -> void:
	if sp < 0.35 or not _active or _indoors:
		return
	var surf := "grass"
	match map.biome_at(pos.x, pos.z):
		WorldMap.Biome.PATH, WorldMap.Biome.VILLAGE, WorldMap.Biome.FIELD:
			surf = "dirt"
		WorldMap.Biome.ROCK, WorldMap.Biome.MOUNTAIN:
			surf = "stone"
		WorldMap.Biome.SAND, WorldMap.Biome.RIVERBED:
			surf = "dirt"
	AudioDirector.play_3d(
		"footstep_%s_%d" % [surf, 1 + (_rng.randi() % 4)], pos, lerpf(-24.0, -15.0, clampf(sp / 4.0, 0.0, 1.0))
	)


# --- barks -----------------------------------------------------------------
## Say a line above their head for a few seconds.
func say(line: String, secs: float = BARK_TIME) -> void:
	if bark == null:
		return
	bark.text = line
	bark.visible = true
	bark.modulate.a = 0.0
	_bark_t = secs


func hide_bark() -> void:
	_bark_t = 0.0
	if bark:
		bark.visible = false


func _tick_bark(delta: float) -> void:
	if bark == null or not bark.visible:
		return
	_bark_t -= delta
	var a: float = bark.modulate.a
	if _bark_t <= 0.0:
		a = maxf(0.0, a - delta * 3.4)
		if a <= 0.01:
			bark.visible = false
	else:
		a = minf(1.0, a + delta * 5.0)
	bark.modulate.a = a


# --- queries (for tests, HUD and the quest system) --------------------------
func state_name() -> String:
	var i: int = clampi(state, 0, ST_NAMES.size() - 1)
	return ST_NAMES[i]


func is_indoors() -> bool:
	return _indoors


func is_talking() -> bool:
	return _talking


func is_fleeing() -> bool:
	return state == St.FLEE


func schedule_anchor() -> Vector3:
	return _schedule().pos


func goal() -> Vector3:
	return _goal
