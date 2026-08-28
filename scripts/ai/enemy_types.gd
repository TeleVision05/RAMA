class_name EnemyTypes
extends RefCounted
## The hostile inhabitants of the Vale: what they are, what they look like, and how
## hard they hit.
##
## Everything an archetype IS lives in `def()` — one dictionary per kind, so tuning a
## fight means editing numbers in one place rather than hunting through the state
## machine. Everything an archetype LOOKS like lives in `build_body()`, which drives
## ProcRig (or BeastRig for the tiger) with distinct proportions, hide tints and gear
## so the four read apart at fifty metres, in silhouette, before any health bar does.
##
## Damage budget this is tuned against: Rama's melee does 20/20/34 and a full-draw
## arrow 48 (14 uncharged). So a warrior is four light swings or two arrows, an elite
## is a real engagement, and a beast dies fast but hits first.

enum Kind { WARRIOR, ARCHER, ELITE, BEAST }

const NAMES := ["warrior", "archer", "elite", "beast"]


static func kind_from_name(n: String) -> int:
	var i: int = NAMES.find(n.to_lower())
	return i if i >= 0 else Kind.WARRIOR


static func display_name(kind: int) -> String:
	match kind:
		Kind.WARRIOR:
			return "Rakshasa Warrior"
		Kind.ARCHER:
			return "Rakshasa Archer"
		Kind.ELITE:
			return "Rakshasa Champion"
		Kind.BEAST:
			return "Vyaghra"
	return "Rakshasa"


# ===========================================================================
#  STATS
# ===========================================================================
## Every number the AI reads. Distances in metres, times in seconds, speeds in m/s.
static func def(kind: int) -> Dictionary:
	match kind:
		Kind.ARCHER:
			return {
				"kind": Kind.ARCHER,
				"health": 60.0,
				"body_radius": 0.36,
				"body_height": 1.86,
				"eye_h": 1.62,
				"walk": 1.55,
				"run": 5.35,
				"accel": 17.0,
				"turn": 7.0,
				"vision": 34.0,
				"fov_deg": 118.0,
				"hearing": 34.0,
				"aggro": 30.0,
				"attack_range": 26.0,  # bow reach
				"attack_min": 7.0,  # closer than this and it backs off
				"attack_cd": 1.6,
				"strafe_dist": 15.0,
				"retreats": true,
				"retreat_health": 0.34,
				"retreat_dist": 18.0,
				"poise": 6.0,  # damage that shrugs off a flinch
				"knockback": 3.6,
				"quadruped": false,
				"hurt_sfx": ["enemy_hurt_1", "enemy_hurt_2", "enemy_hurt_3"],
				"alert_sfx": ["enemy_alert_1", "enemy_alert_2"],
				"idle_sfx": ["enemy_growl_2", "enemy_growl_3"],
				"death_sfx": ["enemy_death_1", "enemy_death_2"],
				"loot": [["arrow", 4, 8, 1.0], ["rakshasa_fang", 1, 1, 0.35]],
			}
		Kind.ELITE:
			return {
				"kind": Kind.ELITE,
				"health": 190.0,
				"body_radius": 0.52,
				"body_height": 2.36,
				"eye_h": 2.05,
				"walk": 1.45,
				"run": 5.10,
				"accel": 15.0,
				"turn": 4.6,
				"vision": 32.0,
				"fov_deg": 132.0,
				"hearing": 32.0,
				"aggro": 26.0,
				"attack_range": 3.3,
				"attack_min": 0.0,
				"attack_cd": 1.5,
				"strafe_dist": 3.9,
				"leap_range": Vector2(6.0, 13.0),
				"leap_cd": 7.0,
				"retreats": false,
				"retreat_health": 0.0,
				"retreat_dist": 0.0,
				"poise": 26.0,
				"knockback": 1.6,
				"quadruped": false,
				"hurt_sfx": ["enemy_hurt_2", "enemy_hurt_3"],
				"alert_sfx": ["enemy_alert_1", "enemy_alert_2"],
				"idle_sfx": ["enemy_growl_1", "enemy_growl_3"],
				"death_sfx": ["enemy_death_1", "enemy_death_2"],
				"loot": [["rakshasa_horn", 1, 1, 1.0], ["arrow", 5, 10, 1.0], ["iron_scrap", 1, 2, 0.7]],
			}
		Kind.BEAST:
			return {
				"kind": Kind.BEAST,
				"health": 70.0,
				"body_radius": 0.42,
				"body_height": 1.05,
				"eye_h": 0.92,
				"walk": 2.20,
				"run": 8.20,
				"accel": 26.0,
				"turn": 8.5,
				"vision": 30.0,
				"fov_deg": 150.0,
				"hearing": 40.0,
				"aggro": 26.0,
				"attack_range": 2.6,
				"attack_min": 0.0,
				"attack_cd": 1.9,
				"strafe_dist": 5.2,
				"retreats": true,
				"retreat_health": 0.42,
				"retreat_dist": 13.0,
				"poise": 4.0,
				"knockback": 4.2,
				"quadruped": true,
				"hurt_sfx": ["beast_snarl_1", "beast_snarl_2"],
				"alert_sfx": ["beast_snarl_1", "beast_snarl_2"],
				"idle_sfx": ["beast_snarl_2", "enemy_growl_2"],
				"death_sfx": ["enemy_death_2"],
				"loot": [["beast_pelt", 1, 1, 1.0], ["beast_claw", 1, 3, 0.8]],
			}
		_:
			return {
				"kind": Kind.WARRIOR,
				"health": 90.0,
				"body_radius": 0.44,
				"body_height": 2.06,
				"eye_h": 1.80,
				"walk": 1.50,
				"run": 5.05,
				"accel": 16.0,
				"turn": 5.4,
				"vision": 30.0,
				"fov_deg": 124.0,
				"hearing": 30.0,
				"aggro": 24.0,
				"attack_range": 2.9,
				"attack_min": 0.0,
				"attack_cd": 1.7,
				"strafe_dist": 3.4,
				"retreats": false,
				"retreat_health": 0.0,
				"retreat_dist": 0.0,
				"poise": 14.0,
				"knockback": 2.6,
				"quadruped": false,
				"hurt_sfx": ["enemy_hurt_1", "enemy_hurt_2", "enemy_hurt_3"],
				"alert_sfx": ["enemy_alert_1", "enemy_alert_2"],
				"idle_sfx": ["enemy_growl_1", "enemy_growl_2", "enemy_growl_3"],
				"death_sfx": ["enemy_death_1", "enemy_death_2"],
				"loot": [["rakshasa_fang", 1, 2, 0.6], ["arrow", 2, 4, 0.8]],
			}


# ===========================================================================
#  ATTACK SCRIPTS
# ===========================================================================
## An attack is a list of timed phases. "wind" telegraphs, "hit" opens a damage
## sphere, "rec" is the punishable recovery. The player's dodge i-frames run
## 0.06-0.32 s, so every hit window is preceded by a wind-up longer than a dodge —
## which is what makes these fights readable rather than a coin toss.
static func attack_seq(kind: int) -> Array:
	match kind:
		Kind.ARCHER:
			return [
				{"p": "wind", "d": 1.05, "sfx": "bow_draw", "sfx_db": -8.0},
				{"p": "shoot", "d": 0.12, "dmg": 10.0},
				{"p": "rec", "d": 0.72},
			]
		Kind.ELITE:
			# A two-hit combo: a heavy overhand, then a faster follow-through with a
			# wider arc, so stepping in after the first swing is punished.
			return [
				{"p": "wind", "d": 0.46, "sfx": "enemy_attack_2", "sfx_db": -3.0},
				{"p": "hit", "d": 0.15, "dmg": 22.0, "rng": 3.4, "arc": 1.5},
				{"p": "rec", "d": 0.24},
				{"p": "wind", "d": 0.30},
				{"p": "hit", "d": 0.15, "dmg": 22.0, "rng": 3.6, "arc": 2.1},
				{"p": "rec", "d": 0.66},
			]
		Kind.BEAST:
			return [
				{"p": "wind", "d": 0.32, "sfx": "beast_snarl_1", "sfx_db": -2.0},
				{"p": "leap", "d": 0.44, "dmg": 16.0, "rng": 2.3, "arc": 2.0, "speed": 13.5, "up": 3.6},
				{"p": "rec", "d": 0.48},
			]
		_:
			return [
				{"p": "wind", "d": 0.54, "sfx": "enemy_attack_1", "sfx_db": -4.0},
				{"p": "hit", "d": 0.16, "dmg": 14.0, "rng": 3.0, "arc": 1.5},
				{"p": "rec", "d": 0.60},
			]


## The champion's gap-closer. Slow enough to see coming, fast enough to punish
## backing away from a fight instead of committing to it.
static func leap_seq() -> Array:
	return [
		{"p": "wind", "d": 0.48, "sfx": "enemy_alert_1", "sfx_db": -2.0},
		{"p": "leap", "d": 0.72, "dmg": 26.0, "rng": 3.4, "arc": 2.6, "speed": 15.0, "up": 7.0},
		{"p": "rec", "d": 0.62},
	]


# ===========================================================================
#  BODIES
# ===========================================================================
## Build the visual for a kind and parent it to `owner_node`. Returns a dictionary
## of the parts the AI needs to drive: {rig|beast, weapon, string}.
static func build_body(kind: int, owner_node: Node3D, seed_v: int) -> Dictionary:
	if kind == Kind.BEAST:
		return _build_beast(owner_node, seed_v)
	return _build_rakshasa(kind, owner_node, seed_v)


static func _build_beast(owner_node: Node3D, seed_v: int) -> Dictionary:
	var b := BeastRig.new()
	b.name = "BeastRig"
	# Slightly different coats per animal, all within a plausible tiger range.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var tint := Color(1.0, 1.0, 1.0).lerp(Color(0.86, 0.78, 0.72), rng.randf() * 0.5)
	b.configure({"tint": tint, "seed": seed_v})
	owner_node.add_child(b)
	b.build()
	return {"beast": b, "rig": null, "weapon": null}


static func _build_rakshasa(kind: int, owner_node: Node3D, seed_v: int) -> Dictionary:
	var rig := ProcRig.new()
	rig.name = "Rig"
	rig.configure(_rig_config(kind, seed_v))
	owner_node.add_child(rig)
	# Build UNMERGED. `build()` collapses each joint's meshes into one draw at the end,
	# and `_face_forward` below needs the head's individual meshes to still exist. Same
	# order npc.gd uses for the same reason: build, correct, then merge by hand.
	var was_merge: bool = ProcRig.merge_enabled
	ProcRig.merge_enabled = false
	rig.build()
	ProcRig.merge_enabled = was_merge

	_face_forward(rig)
	_tune_rakshasa(rig, kind)
	var out := {"rig": rig, "beast": null, "weapon": null, "string": null}

	match kind:
		Kind.ARCHER:
			var bow := Weapons.bow(1.05)
			rig.hand_attach["L"].add_child(bow)
			bow.position = Vector3(0, -0.04, 0.02)
			bow.rotation = Vector3(0.10, 0.0, 1.20)
			out["weapon"] = bow
			out["string"] = bow.get_node_or_null("String")
			var q := Weapons.quiver()
			rig.chest.add_child(q)
			# Behind the shoulder. ProcRig's torso is front-at--Z like its legs, so a
			# quiver at negative Z was worn across the chest.
			q.position = Vector3(-0.11, -0.02, 0.13)
			q.rotation = Vector3(-0.30, 0, -0.42)
			_add_archer_marks(rig)
		Kind.ELITE:
			var blade := Weapons.crude_blade()
			blade.scale = Vector3.ONE * 1.45
			rig.hand_attach["R"].add_child(blade)
			blade.position = Vector3(0, -0.08, 0.03)
			blade.rotation = Vector3(-0.30, 0, 0)
			out["weapon"] = blade
			_add_champion_armour(rig)
		_:
			var cb := Weapons.crude_blade()
			cb.scale = Vector3.ONE * 1.15
			rig.hand_attach["R"].add_child(cb)
			cb.position = Vector3(0, -0.07, 0.02)
			cb.rotation = Vector3(-0.32, 0, 0)
			out["weapon"] = cb
			_add_warrior_wraps(rig)
	rig._merge_draws()
	return out


## Turn the head around.
##
## ProcRig builds its head with the face at LOCAL +Z — nose, eyes, brow and beard are
## all at positive Z, the hair cap at negative Z — while its legs are written against
## the opposite convention ("Foot target in RIG-LOCAL space. Forward is -Z.") and every
## controller in the project, this one included, yaws the body with `atan2(-x, -z)` so
## that -Z is forward. The result is a rakshasa whose face is on the back of its head:
## it charges you, and what you see is its hair.
##
## Measured 2026-08-28: `tests/enemy_test.gd` reports `eyes_at_camera` for every
## portrait, and before this it was -1.00 for all three humanoid archetypes while the
## Vyaghra (BeastRig, built to the right convention) was +1.00. All four "character
## sheet" portraits in build/screenshots were photographs of the back of a head.
##
## `npc.gd::_expose_face()` found the same defect and fixed it locally the same way —
## every mesh on the head is an ovoid, a sphere or a tube, all symmetric in Z, so
## mirroring the offsets is the whole fix. The proper repair is in ProcRig, where it
## would fix Rama and the villagers too; that file belongs to another system, so this
## does what the NPCs already do rather than leaving the rakshasas faceless.
static func _face_forward(rig: ProcRig) -> void:
	if rig.head == null:
		return
	for c in rig.head.get_children():
		if c is MeshInstance3D:
			var mi := c as MeshInstance3D
			mi.position.z = -mi.position.z
			mi.rotation.x = -mi.rotation.x


## Rakshasas are built from the same rig as the villagers, on purpose: the same
## skeleton, pushed to different proportions. The warrior is broad and low-browed,
## the archer is long and light, the champion is a head taller than Rama and half
## again as thick. Menacing through mass and stance, not through gore.
static func _rig_config(kind: int, seed_v: int) -> Dictionary:
	var base := {
		"skin": "demon_hide",
		"cloth": "cloth_indigo",
		"cloth2": "cloth_indigo",
		# A dark warm mane, NOT near-black. On a charcoal hide, near-black hair and a
		# charcoal skull merge into one lump with no features in it, which is what the
		# portraits showed: a head you cannot read from any angle.
		"hair_color": Color(0.20, 0.135, 0.105),
		"dhoti": true,
		"sash": false,
		"jewellery": false,
		"topknot": false,
		# No beard. ProcRig's beard is a solid mass under the jaw, and on a rakshasa it
		# buried the one thing the face is built around — the tusks pushed up past the
		# lip. A rakshasa reads as not-a-person from its jaw; hiding the jaw threw that
		# away and gave back nothing.
		"beard": false,
		"horns": true,
		"seed": seed_v,
	}
	match kind:
		Kind.ARCHER:
			(
				base
				. merge(
					{
						"height": 1.95,
						"hip_h": 1.02,
						"thigh": 0.50,
						"shin": 0.49,
						"foot": 0.25,
						"spine": 0.32,
						"chest": 0.25,
						"neck": 0.11,
						"head": 0.112,
						"shoulder_w": 0.170,
						"upper_arm": 0.34,
						"lower_arm": 0.33,
						"hand": 0.11,
						"hip_w": 0.105,
						"build": 0.86,
						# Sallow, sun-starved olive: the forest skirmisher. `demon_hide` is
						# already a MID-GREY sheet (mean luminance 0.37), and a tint at or
						# above 1.0 does not "keep it neutral", it leaves a pale plated
						# surface that a noon sun blows out to near white. Measured from
						# build/screenshots/enemy_02_melee.png on 2026-08-28: a camp of
						# rakshasas read as white marble statues, BRIGHTER than the bark and
						# the meadow they were standing in, which is the opposite of a threat
						# silhouette. Every tint here is now a darkener.
						"skin_tint": Color(0.62, 0.70, 0.52),
						"cloth_tint": Color(0.52, 0.58, 0.38),
					},
					true
				)
			)
		Kind.ELITE:
			(
				base
				. merge(
					{
						"height": 2.36,
						"hip_h": 1.26,
						"thigh": 0.60,
						"shin": 0.58,
						"foot": 0.31,
						"spine": 0.38,
						"chest": 0.35,
						"neck": 0.11,
						"head": 0.140,
						"shoulder_w": 0.245,
						"upper_arm": 0.40,
						"lower_arm": 0.37,
						"hand": 0.14,
						"hip_w": 0.145,
						"build": 1.62,
						# Bruised iron with a cold violet cast; the champion is the darkest of
						# them, and reads as a hole in the treeline before you can count its
						# horns.
						"skin_tint": Color(0.50, 0.45, 0.54),
						"cloth_tint": Color(0.36, 0.30, 0.38),
					},
					true
				)
			)
		_:
			(
				base
				. merge(
					{
						"height": 2.06,
						"hip_h": 1.10,
						"thigh": 0.52,
						"shin": 0.50,
						"foot": 0.28,
						"spine": 0.33,
						"chest": 0.30,
						"neck": 0.09,
						"head": 0.125,
						"shoulder_w": 0.215,
						"upper_arm": 0.35,
						"lower_arm": 0.32,
						"hand": 0.12,
						"hip_w": 0.128,
						"build": 1.38,
						# Charcoal hide with a cold cast, the colour of cold cinders — the one
						# the description always claimed and the number never delivered.
						"skin_tint": Color(0.63, 0.65, 0.68),
						"cloth_tint": Color(0.56, 0.44, 0.30),
					},
					true
				)
			)
	return base


## `demon_hide` is a plated, reptilian sheet: pale scales, dark ridges, dark streaks.
## ProcRig tiles it once across each body part, which at rakshasa scale makes each
## plate the size of a hand and reads as lichen on rock. Just under two repeats puts
## the plates at roughly five centimetres, where they read as scales, and the normal
## map does the rest. Done here rather than in ProcRig because it is a property of
## THIS creature's scale, not of the rig.
static func _tune_rakshasa(rig: ProcRig, kind: int) -> void:
	var hide := Mats.tex("demon_hide")
	var eyes := 0
	var seen := {}
	var stack: Array = [rig]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MeshInstance3D):
			continue
		var m := (n as MeshInstance3D).material_override as StandardMaterial3D
		if m == null or seen.has(m.get_instance_id()):
			continue
		seen[m.get_instance_id()] = true
		# Horns in old ivory. ProcRig gives them near-black, which on a near-black
		# skull is a silhouette cue you can only see against the sky.
		if m.albedo_texture == null and _near(m.albedo_color, Color(0.14, 0.12, 0.12), 0.03):
			m.albedo_color = Color(0.72, 0.68, 0.58)
			m.roughness = 0.42
		elif hide != null and m.albedo_texture == hide:
			m.uv1_scale = Vector3(1.9, 1.9, 1.9)
			m.normal_scale = 0.70
			m.roughness = 1.0
		# ProcRig gives everyone a near-black iris. On a rakshasa it should catch the
		# light: amber, faintly self-lit, so the thing in the treeline at dusk is
		# unmistakably looking at you. Menace from a pair of eyes, not from gore.
		#
		# Matched with a TOLERANCE, and counted. This used `is_equal_approx` against
		# two colour literals copied out of ProcRig — `Color(0.10, 0.06, 0.04)` for
		# the iris and `Color(0.94, 0.92, 0.88)` for the sclera. ProcRig has since
		# retuned its eyes to 0.09/0.055/0.04 and 0.86/0.83/0.78, and
		# `is_equal_approx` compares to about one part in a hundred thousand, so BOTH
		# branches silently stopped matching anything: every rakshasa built since has
		# had ProcRig's default dead black eye, and the amber was never once drawn.
		# Measured 2026-08-28 from build/screenshots/enemy_10_warrior_idle.png, where
		# the head is one unreadable black mass. A neighbouring file's literal is not
		# a stable key, so this now matches loosely and SAYS SO when it matches
		# nothing.
		elif m.albedo_texture == null and _near(m.albedo_color, Color(0.095, 0.058, 0.040), 0.05):
			m.albedo_color = Color(0.90, 0.55, 0.10)
			m.emission_enabled = true
			m.emission = Color(1.0, 0.55, 0.10)
			m.emission_energy_multiplier = 2.2
			eyes += 1
		elif m.albedo_texture == null and _near(m.albedo_color, Color(0.90, 0.87, 0.83), 0.10):
			m.albedo_color = Color(0.88, 0.78, 0.55)
			eyes += 1

	last_eye_count = eyes
	if eyes == 0:
		push_warning(
			(
				"[enemy] %s got no amber eyes: ProcRig's eye materials no longer " % NAMES[kind]
				+ "match what _tune_rakshasa looks for"
			)
		)

	if kind != Kind.ARCHER:
		_add_tusks(rig)


## Loose colour match. Two materials built by different files are the same material
## when they LOOK the same, not when their literals are bit-identical.
static func _near(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) < tol and absf(a.g - b.g) < tol and absf(a.b - b.b) < tol


## How many eye materials the last `_tune_rakshasa` retinted. Zero means the coupling
## to ProcRig's eye colours has broken again; the test asserts on it.
static var last_eye_count: int = 0


## Lower canines pushed up past the lip. One silhouette cue does more for "this is not
## a person" than any amount of texture, and it costs two meshes.
static func _add_tusks(rig: ProcRig) -> void:
	var r: float = rig.cfg.head
	var m := Mats.flat(Color(0.88, 0.85, 0.74), 0.35)
	for sx in [-1.0, 1.0]:
		var tusk := MeshInstance3D.new()
		# Authored in the CORRECTED frame: `_face_forward` has already turned the head
		# around, so the face — and the lower jaw these come out of — is at -Z.
		tusk.mesh = MeshKit.tube(
			r * 0.62,
			[[0.0, r * 0.085], [0.55, r * 0.058], [1.0, r * 0.010]],
			6,
			1.0,
			Vector3(sx * r * 0.12, 0.0, r * 0.20)
		)
		tusk.material_override = m
		tusk.position = Vector3(sx * r * 0.30, r * 0.50, -r * 0.60)
		tusk.rotation = Vector3(-0.28, 0.0, sx * -0.16)
		rig.head.add_child(tusk)


## The champion's single armoured shoulder: a beaten iron pauldron with brass rivets
## over the sword arm. One asymmetric silhouette cue is worth more than a full suit.
static func _add_champion_armour(rig: ProcRig) -> void:
	var m_iron := Mats.flat(Color(0.20, 0.195, 0.205), 0.42, 0.80)
	var m_brass := Mats.brass()
	var sh: Node3D = rig.shoulder["R"]

	var pauldron := MeshInstance3D.new()
	pauldron.mesh = (
		MeshKit
		. profile_loft(
			0.26,
			[
				[0.00, 0.185, 0.170],
				[0.30, 0.205, 0.190],
				[0.62, 0.190, 0.176],
				[0.86, 0.156, 0.146],
				[1.00, 0.120, 0.112],
			],
			12
		)
	)
	pauldron.material_override = m_iron
	pauldron.position = Vector3(0, 0.06, 0)
	pauldron.rotation = Vector3(PI, 0, 0)
	sh.add_child(pauldron)

	# Overlapping lames down the upper arm.
	for i in range(2):
		var lame := MeshInstance3D.new()
		lame.mesh = MeshKit.tube(0.052, [[0.0, 0.115 - 0.014 * float(i)], [1.0, 0.098 - 0.014 * float(i)]], 12, 0.90)
		lame.material_override = m_iron
		lame.position = Vector3(0, -0.135 - 0.075 * float(i), 0)
		lame.rotation = Vector3(PI, 0, 0)
		sh.add_child(lame)

	for i in range(5):
		var a: float = PI * (0.15 + 0.175 * float(i))
		var rivet := MeshInstance3D.new()
		rivet.mesh = MeshKit.sphere(0.016, 6, 5)
		rivet.material_override = m_brass
		rivet.position = Vector3(cos(a) * 0.175, -0.02, sin(a) * 0.165)
		sh.add_child(rivet)

	# A chest strap anchoring it, so the pauldron is worn rather than stuck on.
	var strap := MeshInstance3D.new()
	strap.mesh = MeshKit.quad(0.085, 0.52, true)
	strap.material_override = Mats.flat(Color(0.16, 0.12, 0.10), 0.72)
	strap.position = Vector3(-0.075, rig.cfg.chest * 0.82, 0.115)
	strap.rotation = Vector3(0.10, 0.0, 0.52)
	rig.chest.add_child(strap)


## Warriors wear ragged arm and shin wraps and a band of ochre-red — scavenged cloth,
## no metal. The red is the only saturated thing on an otherwise ash-grey body, which
## is what lets a warrior read as a rakshasa and not as a rock at thirty metres.
static func _add_warrior_wraps(rig: ProcRig) -> void:
	var m := Mats.pbr("cloth_indigo", 5.0, "cloth_indigo").duplicate()
	m.albedo_color = Color(0.40, 0.33, 0.28)
	var m_red := Mats.pbr("cloth_indigo", 4.0, "cloth_indigo").duplicate()
	m_red.albedo_color = Color(1.30, 0.34, 0.20)
	var strap := MeshInstance3D.new()
	strap.mesh = MeshKit.quad(0.095, 0.62, true)
	strap.material_override = m_red
	strap.position = Vector3(0.065, rig.cfg.chest * 0.86, 0.098)
	strap.rotation = Vector3(0.12, 0.0, -0.50)
	rig.chest.add_child(strap)
	var strap_b := MeshInstance3D.new()
	strap_b.mesh = MeshKit.quad(0.095, 0.62, true)
	strap_b.material_override = m_red
	strap_b.position = Vector3(-0.055, rig.cfg.chest * 0.86, -0.098)
	strap_b.rotation = Vector3(-0.12, PI, -0.50)
	rig.chest.add_child(strap_b)
	var belt := MeshInstance3D.new()
	belt.mesh = MeshKit.tube(0.075, [[0.0, 0.150], [0.5, 0.158], [1.0, 0.146]], 14, 0.80)
	belt.material_override = m_red
	belt.position = Vector3(0, 0.020, 0)
	rig.hips.add_child(belt)
	for side in ["L", "R"]:
		var el: Node3D = rig.elbow[side]
		var wrap := MeshInstance3D.new()
		wrap.mesh = MeshKit.tube(0.14, [[0.0, 0.062], [0.5, 0.066], [1.0, 0.058]], 10, 0.92)
		wrap.material_override = m
		wrap.position = Vector3(0, -0.05, 0)
		wrap.rotation = Vector3(PI, 0, 0)
		el.add_child(wrap)
		var kn: Node3D = rig.knee[side]
		var shin := MeshInstance3D.new()
		shin.mesh = MeshKit.tube(0.20, [[0.0, 0.082], [0.5, 0.086], [1.0, 0.074]], 10, 0.92)
		shin.material_override = m
		shin.position = Vector3(0, -0.10, 0)
		shin.rotation = Vector3(PI, 0, 0)
		kn.add_child(shin)


## Archers bind their forearms and shins in undyed cloth and chalk a pale band across
## the chest — a skirmisher's kit, and a lighter read than the warrior's red.
static func _add_archer_marks(rig: ProcRig) -> void:
	var m_bone := Mats.pbr("cloth_white", 4.0, "cloth_white").duplicate()
	m_bone.albedo_color = Color(0.92, 0.88, 0.76)
	for side in ["L", "R"]:
		var el: Node3D = rig.elbow[side]
		var bind := MeshInstance3D.new()
		bind.mesh = MeshKit.tube(0.16, [[0.0, 0.050], [0.5, 0.054], [1.0, 0.046]], 10, 0.92)
		bind.material_override = m_bone
		bind.position = Vector3(0, -0.11, 0)
		bind.rotation = Vector3(PI, 0, 0)
		el.add_child(bind)
	var band := MeshInstance3D.new()
	band.mesh = MeshKit.quad(0.075, 0.50, true)
	band.material_override = m_bone
	band.position = Vector3(-0.045, rig.cfg.chest * 0.84, 0.092)
	band.rotation = Vector3(0.10, 0.0, 0.46)
	rig.chest.add_child(band)


# ===========================================================================
#  LOOT
# ===========================================================================
## Roll this kind's drop table. Returns [[id, count], ...].
static func roll_loot(kind: int, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for entry in def(kind).get("loot", []):
		var id: String = entry[0]
		var lo: int = int(entry[1])
		var hi: int = int(entry[2])
		var chance: float = float(entry[3])
		if rng.randf() > chance:
			continue
		out.append([id, rng.randi_range(lo, hi)])
	return out


static func item_label(id: String) -> String:
	match id:
		"arrow":
			return "Arrows"
		"rakshasa_fang":
			return "Rakshasa Fang"
		"rakshasa_horn":
			return "Rakshasa Horn"
		"iron_scrap":
			return "Scrap Iron"
		"beast_pelt":
			return "Striped Pelt"
		"beast_claw":
			return "Tiger Claw"
	return id.capitalize()
