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
				"body_radius": 0.34,
				"body_height": 2.02,
				"eye_h": 1.86,
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
				"body_radius": 0.56,
				"body_height": 2.48,
				"eye_h": 2.14,
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
				"body_radius": 0.46,
				"body_height": 2.10,
				"eye_h": 1.82,
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
	var rcfg := _rig_config(kind, seed_v)
	var is_dasagriva: bool = owner_node != null and bool(owner_node.get("ten_heads"))
	if is_dasagriva:
		rcfg["ten_heads"] = true
	rig.configure(rcfg)
	owner_node.add_child(rig)
	# Build UNMERGED. `build()` collapses each joint's meshes into one draw at the end,
	# and everything below needs the individual meshes to still exist. Same order
	# npc.gd uses for the same reason: build, correct, then merge by hand.
	var was_merge: bool = ProcRig.merge_enabled
	ProcRig.merge_enabled = false
	rig.build()
	ProcRig.merge_enabled = was_merge

	_orient_front(rig)
	# BEFORE `_tune_rakshasa`. That pass identifies ProcRig's materials by COLOUR, and
	# the hair is identified by colour here; whichever runs second is matching against
	# whatever the first one left behind. Stripping first means this only ever sees
	# the colour ProcRig actually built with.
	var hair_mat := _strip_hair(rig)
	_tune_rakshasa(rig, kind)
	_pose_stance(rig, kind)

	var mats := _kit_materials(rig, hair_mat)
	_build_head_forms(rig, kind, seed_v, mats)
	_build_torso_forms(rig, kind, mats)
	_build_extremities(rig, mats)
	_fit_dhoti(rig, mats.hide)
	_build_gear(rig, kind, seed_v, mats)
	if is_dasagriva:
		_build_ravana_ten_heads(rig, mats)

	var out := {"rig": rig, "beast": null, "weapon": null, "string": null}
	match kind:
		Kind.ARCHER:
			var bow := Weapons.bow(0.92)
			# Thickened across the stave without being lengthened. `Weapons.bow` gives
			# the limb a 16 mm root tapering to 6 mm, which at 40 m is a stick and reads
			# as a spear, not a bow.
			bow.scale = Vector3(0.92 * 1.55, 0.92, 0.92 * 1.55)
			rig.hand_attach["L"].add_child(bow)
			# Held VERTICALLY, at the side, the way an archer carries a bow between
			# shots. The old rotation laid the stave across the body and the result read
			# as a spear in silhouette — measured from build/screenshots/creature_
			# silhouette.png on 2026-08-28, where the archer's outline was a mannequin
			# holding a horizontal stick.
			bow.position = Vector3(0.02, -0.10, -0.02)
			bow.rotation = Vector3(0.12, 1.25, 0.22)
			out["weapon"] = bow
			out["string"] = bow.get_node_or_null("String")
			var q := Weapons.quiver()
			rig.chest.add_child(q)
			# Slung across the BACK, which after `_orient_front` is +Z.
			q.position = Vector3(-0.10, -0.02, 0.13)
			q.rotation = Vector3(0.30, 0.0, -0.42)
		Kind.ELITE:
			var cleaver := CreatureKit.cleaver(1.30)
			rig.hand_attach["R"].add_child(cleaver)
			# Blade DOWN, continuing the line of the forearm. `Weapons` builds its
			# blades along +Y from the grip, and the old rotation left them pointing
			# back UP the arm — which also runs the melee arc backwards, since
			# `ProcRig._animate_arms` winds the shoulder to -2.5 rad (arm up and back)
			# and strikes at +0.75 (arm down and forward): a blade in line with the
			# forearm leads through that arc, a blade up the arm trails through it.
			cleaver.position = Vector3(0, -0.04, -0.015)
			cleaver.rotation = Vector3(PI - 0.30, 0, 0)
			out["weapon"] = cleaver
		_:
			var cb := Weapons.crude_blade()
			cb.scale = Vector3.ONE * 1.30
			rig.hand_attach["R"].add_child(cb)
			cb.position = Vector3(0, -0.03, -0.015)
			cb.rotation = Vector3(PI - 0.30, 0, 0)
			out["weapon"] = cb
	rig._merge_draws()
	return out


## Turn the whole body around.
##
## ProcRig is built to two contradictory conventions. Its LEGS are written against
## "Foot target in RIG-LOCAL space. Forward is -Z", and every controller in the
## project yaws the body with `atan2(-x, -z)` so that -Z is forward. But its HEAD
## (nose, eyes, brow), its TORSO (pectorals at +0.082 z), its DHOTI PLEAT and its FEET
## (toe at +0.20 * foot) are all authored at positive Z. So a rakshasa charges you
## showing the back of its head, the back of its chest and the backs of its feet.
##
## Measured 2026-08-28: `tests/enemy_test.gd` reports `eyes_at_camera` for every
## portrait, and before the head half of this fix it was -1.00 for all three humanoid
## archetypes while the Vyaghra (BeastRig, built to the right convention) was +1.00.
## The torso and foot half was found the same day from build/screenshots/creature_
## champion.png, where the warrior's ochre chest band and the champion's shoulder
## strap were both photographed on the creature's BACK.
##
## Every mesh involved is an ovoid, a sphere or a tube, all symmetric in Z, so
## mirroring the offset and the pitch is the whole fix. The proper repair is in
## ProcRig, where it would fix Rama and the villagers too; that file belongs to
## another system, so this does locally what `npc.gd::_expose_face()` already does.
static func _orient_front(rig: ProcRig) -> void:
	_audit_skull(rig)
	# Only mirror if the face is actually on the wrong side. ProcRig is being reworked
	# by another system, and a blind mirror here would turn a fixed rig back around —
	# the same defect, in the opposite direction, with nothing to notice it. So the
	# rig is ASKED where its face is, by the position of the eye meshes.
	var face_z: float = _face_z(rig)
	build_audit["procrig_face_z"] = face_z
	if face_z < 0.0:
		build_audit["mirrored"] = false
		return
	build_audit["mirrored"] = true
	var joints: Array[Node3D] = [rig.head, rig.chest, rig.hips]
	for side in ["L", "R"]:
		joints.append(rig.ankle[side])
	for j in joints:
		if j == null:
			continue
		for c in j.get_children():
			if c is MeshInstance3D:
				var mi := c as MeshInstance3D
				mi.position.z = -mi.position.z
				mi.rotation.x = -mi.rotation.x


## Which way ProcRig's face is pointing, in metres of z, averaged over the eye meshes.
## Positive means the face is at +Z and needs turning around; negative means ProcRig
## has already been fixed and this must keep its hands off. Zero — no eye mesh found
## at all — falls back to ProcRig's historical +Z convention and says so.
static func _face_z(rig: ProcRig) -> float:
	if rig.head == null:
		return 0.0
	# ProcRig publishes the eyes as `eye["L"]` / `eye["R"]` nodes. That is the reliable
	# handle, and it survived the head rework that broke every colour match here.
	var e: Dictionary = rig.eye
	if e.has("L") and e["L"] != null:
		return (e["L"] as Node3D).position.z
	var acc := 0.0
	var n := 0
	for c in rig.head.get_children():
		if not (c is MeshInstance3D):
			continue
		var mi := c as MeshInstance3D
		var m := mi.material_override as StandardMaterial3D
		if m == null or m.albedo_texture != null:
			continue
		if _near(m.albedo_color, Color(0.11, 0.068, 0.046), 0.05) or _near(m.albedo_color, Color(0.86, 0.83, 0.78), 0.12):
			acc += (mi.transform * mi.get_aabb().get_center()).z
			n += 1
	if n == 0:
		push_warning("[enemy] cannot find ProcRig's eyes to tell which way the face points; assuming +Z")
		return 1.0
	return acc / float(n)


## Measure ProcRig's skull before anything is added to it.
##
## `_skull_at` models that skull as `MeshKit.ovoid(r, 2.25 r, 0.42)` and every face
## feature is placed to clear it. If ProcRig re-proportions its head — and it is
## actively being reworked — those placements sink back inside and the rakshasa loses
## its face again with no test failing. So the assumption is measured against the mesh
## that is actually there, and it complains when it stops holding.
static func _audit_skull(rig: ProcRig) -> void:
	var r: float = rig.cfg.head
	var mi: MeshInstance3D = null
	for c in rig.head.get_children():
		if c is MeshInstance3D and String(c.name) == "Skull":
			mi = c as MeshInstance3D
	if mi == null:
		for c in rig.head.get_children():
			if not (c is MeshInstance3D) or (c as MeshInstance3D).mesh == null:
				continue
			var cand := c as MeshInstance3D
			if mi == null or (cand.transform * cand.get_aabb()).get_volume() > (mi.transform * mi.get_aabb()).get_volume():
				mi = cand
	if mi == null:
		build_audit["skull_front_r"] = 0.0
		push_warning("[enemy] ProcRig built no head mesh to measure")
		return
	var bb: AABB = mi.transform * mi.get_aabb()
	var front: float = bb.position.z / maxf(r, 0.0001)
	var top: float = (bb.position.y + bb.size.y) / maxf(r, 0.0001)
	var half_w: float = (bb.position.x + bb.size.x) / maxf(r, 0.0001)
	build_audit["skull_front_r"] = front
	build_audit["skull_top_r"] = top
	build_audit["skull_halfw_r"] = half_w
	# The model this file places faces against — measured from the built mesh on
	# 2026-08-28: the face reaches z = -0.94 r, the crown y = 1.80 r, half-width 0.82 r.
	if absf(front - SKULL_FRONT) > 0.22 or absf(top - SKULL_TOP) > 0.40 or absf(half_w - SKULL_HALFW) > 0.22:
		push_warning(
			(
				(
					"[enemy] ProcRig's skull now reaches z %.2f r, y %.2f r, x %.2f r, not %.2f/%.2f/%.2f. "
					% [front, top, half_w, SKULL_FRONT, SKULL_TOP, SKULL_HALFW]
				)
				+ "Re-check the face placements in _build_head_forms."
			)
		)


# ---------------------------------------------------------------------------
#  STANCE
# ---------------------------------------------------------------------------
## Give each archetype a resting posture the animation cannot flatten out.
##
## `ProcRig.animate` writes `hips.rotation`, `spine.rotation`, `chest.rotation` and
## every `shoulder.basis` ABSOLUTELY, every frame, from the gait — so a hunch cannot
## be dialled in by setting a rotation on any of them; the next frame erases it. What
## survives is the SKELETON: a joint inserted between two the animation drives, plus
## the node positions (`neck.position`, `head.position`, `shoulder.position`), which
## `animate` never touches. So the stoop and the arm splay are extra joints, and the
## head thrust is a translation.
static func _pose_stance(rig: ProcRig, kind: int) -> void:
	var stoop: float = 0.0
	var splay: float = 0.0
	var thrust: float = 0.0
	var sink: float = 1.0
	match kind:
		Kind.ARCHER:
			# Upright and alert: a skirmisher stands tall to see over cover. The
			# opposite read to the warrior, on purpose.
			stoop = 0.05
			splay = 0.05
			thrust = -0.030
			sink = 1.10
		Kind.ELITE:
			stoop = -0.19
			splay = 0.24
			thrust = -0.075
			sink = 1.35
		_:
			stoop = -0.24
			splay = 0.16
			thrust = -0.060
			sink = 1.25

	# A forward stoop is a NEGATIVE rotation about X. Godot's R_x(t) sends a point at
	# +Y toward +Z, and the creature's face is at -Z, so the intuitive positive angle
	# leans it backwards. (ProcRig's own run lean has this exact sign error, which is
	# why Rama leans away from the direction he is sprinting.)
	var stoop_j := _insert_joint(rig.chest, "Stoop")
	if stoop_j != null:
		stoop_j.rotation.x = stoop
	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		var arm := _insert_joint(rig.shoulder[side], "ArmRoot" + side)
		if arm != null:
			# Rolled out and forward: the ape-shouldered carriage of something that
			# fights with its mass.
			arm.rotation = Vector3(stoop * 0.35, 0.0, sx * splay)
	rig.neck.position += Vector3(0, 0, thrust * 0.45)
	rig.head.position = Vector3(0, rig.cfg.neck * sink, thrust)


## Slip a new Node3D in above `child`, taking over its offset so the new joint rotates
## about the same point the child sat at. Returns the joint, or null if the child has
## no parent to slip under.
static func _insert_joint(child: Node3D, nm: String) -> Node3D:
	var parent := child.get_parent()
	if parent == null:
		return null
	var j := Node3D.new()
	j.name = nm
	j.position = child.position
	var idx: int = child.get_index()
	parent.remove_child(child)
	child.position = Vector3.ZERO
	parent.add_child(j)
	parent.move_child(j, idx)
	j.add_child(child)
	return j


# ---------------------------------------------------------------------------
#  MATERIALS
# ---------------------------------------------------------------------------
## The palette every added form is built from. The hide is READ OFF the rig rather
## than rebuilt, so the new masses shade identically to the body they grow out of and
## merge into the same draw call; the rest are new.
static func _kit_materials(rig: ProcRig, hair_mat: Material) -> Dictionary:
	var tint: Color = rig.cfg.skin_tint
	return {
		"hide": _hide_mat(rig),
		"hair": hair_mat if hair_mat != null else Mats.flat(rig.cfg.hair_color, 0.72),
		# The pale muzzle. Untextured, so it is already brighter than the hide sheet it
		# sits against (mean luminance 0.37); a tint at or above the skin tint made it
		# a surgical mask (build/screenshots/creature_warrior_face.png, 2026-08-28).
		"pale": Mats.flat(Color(tint.r * 0.62 + 0.06, tint.g * 0.60 + 0.06, tint.b * 0.58 + 0.05), 0.80),
		# Old bone, not fresh ivory: a rakshasa's horns are weathered.
		"bone": Mats.flat(Color(0.58, 0.54, 0.44), 0.56),
		# Scrap iron, barely worked. Metallic was 0.80, which in any light without a
		# reflection to catch renders as a BLACK HOLE — measured from
		# build/screenshots/creature_champion_face.png on 2026-08-28, where the
		# breastplate and one pauldron lame came out as pure black silhouettes while
		# the two lames catching the key light blew out to cream. A low metallic with
		# a dark albedo reads as iron in every light instead of only in one.
		"iron": Mats.flat(Color(0.30, 0.29, 0.30), 0.52, 0.30),
		"leather": Mats.flat(Color(0.20, 0.150, 0.115), 0.84),
		"cord": Mats.flat(Color(0.38, 0.30, 0.21), 0.92),
		"paint": Mats.flat(Color(0.70, 0.67, 0.60), 0.96),
		"blood": Mats.flat(Color(0.40, 0.10, 0.08), 0.70),
		"dark": Mats.flat(Color(0.045, 0.038, 0.035), 0.28),
	}


## The rig's own skin material. Found by inspection rather than rebuilt: ProcRig
## caches materials by (texture, tint) and reusing the exact instance is what lets the
## added masses merge into the body's draw call instead of adding one each.
static func _hide_mat(rig: ProcRig) -> Material:
	for c in rig.chest.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).material_override != null:
			return (c as MeshInstance3D).material_override
	return Mats.flat(Color(0.55, 0.55, 0.58), 0.95)


# ---------------------------------------------------------------------------
#  HEAD
# ---------------------------------------------------------------------------
## Everything above the neck that makes a rakshasa not a person: a heavy brow, a
## jutting mandible, long ears, horns, tusks and coarse hide.
##
## Authored against the MEASURED skull. ProcRig's head is `MeshKit.head_shell` scaled
## by `cfg.head`, and every constant below came off the built mesh rather than out of
## the source — measured 2026-08-28 with a probe that printed each head mesh's AABB in
## units of `cfg.head`:
##
## | part                | x        | y           | z            |
## |---------------------|----------|-------------|--------------|
## | Skull (incl. ears)  | +/- 0.82 | -0.04..1.80 | -0.94..+0.95 |
## | brows               | +/- 0.45 |  0.91..1.04 | -0.90..-0.66 |
## | nostrils / mouth    | +/- 0.34 |  0.20..0.39 | -0.75..-0.52 |
## | eyes (node)         | +/- 0.29 |  0.89       | -0.64        |
##
## Two things follow. The face is at **-Z** — ProcRig was turned around in the same
## rework — so `_orient_front` now leaves it alone. And ProcRig already builds a brow,
## cheeks, a nose and eye cavities, so this no longer rebuilds a face on top of an egg;
## it adds the parts a HUMAN head does not have and leaves the rest.
##
## Parts go into five buckets: `form`, `pale` and `bone` are the base tier and always
## draw (they are the silhouette); `fine` and `bone_fine` stop drawing at
## `CreatureKit.DETAIL_DIST`.
const SKULL_FRONT := -0.94  # the face, in units of cfg.head
const SKULL_TOP := 1.80  # the crown
const SKULL_HALFW := 0.82
const SKULL_MID := 0.88  # ProcRig.HEAD_C: the centre the shell is built around
## The eye band, in units of cfg.head, measured off ProcRig's own eye meshes on
## 2026-08-28. Nothing opaque may be placed across it: the self-lit iris is the only
## warm pixel on a rakshasa and the whole face reads from it.
const EYE_LO := 0.78
const EYE_HI := 1.00


static func _build_head_forms(rig: ProcRig, kind: int, seed_v: int, mats: Dictionary) -> void:
	var r: float = rig.cfg.head
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_v * 31 + kind)
	# How much bone is in the face. The archer is a whippet; the champion is a bull.
	var heavy: float = 1.0
	var jaw_w: float = 1.0
	match kind:
		Kind.ARCHER:
			heavy = 0.84
			jaw_w = 0.90
		Kind.ELITE:
			heavy = 1.42
			jaw_w = 1.32
		_:
			heavy = 1.22
			jaw_w = 1.16

	var form: Array = []
	var pale: Array = []
	var fine: Array = []
	var bone: Array = []
	var bone_fine: Array = []

	# A shelf ABOVE and IN FRONT OF ProcRig's own brow (which lives at y 0.91..1.04,
	# z -0.90..-0.66). Wider than that and it stops being a brow and becomes a hat brim
	# with the whole face in its shadow.
	form.append(
		CreatureKit.part(
			MeshKit.ovoid(r * 0.34, r * 0.24, 0.5, 14, 7),
			Vector3(0, r * 1.06, -r * 0.76),
			Vector3(0.30, 0, 0),
			Vector3(1.75, 0.60 * heavy, 0.72 + 0.16 * heavy)
		)
	)
	for sx in [-1.0, 1.0]:
		form.append(
			CreatureKit.part(
				MeshKit.ovoid(r * 0.17, r * 0.22, 0.5, 8, 6),
				Vector3(sx * r * 0.36, r * 1.16, -r * 0.68),
				Vector3(0.25, 0, sx * 0.30),
				Vector3(1.0, 1.0, 0.85) * heavy
			)
		)
		# Long swept ear, growing out of where the human one already is (x 0.82 r).
		# This alone separates a rakshasa head from a person's at thirty metres, and it
		# costs two hundred triangles.
		form.append(
			CreatureKit.part(
				CreatureKit.ear(r * 1.35, r * 0.36, 0.90), Vector3(sx * r * 0.74, r * 0.92, r * 0.10), Vector3(-0.28, sx * 0.50, sx * 1.02)
			)
		)

	# Mandible: the jaw leads the face. ProcRig's mouth line is at y 0.20..0.39 and
	# z -0.75..-0.52, so this has to sit under and in front of that.
	form.append(
		CreatureKit.part(
			MeshKit.ovoid(r * 0.40, r * 0.46, 0.42, 12, 7),
			Vector3(0, r * 0.30, -r * 0.56),
			Vector3(-0.12, 0, 0),
			Vector3(1.30 * jaw_w, 0.86, 1.15)
		)
	)

	# The lower face, in a lighter tone than the body. Almost every real predator is
	# paler around the muzzle and the throat, and on a body deliberately painted the
	# colour of a hole in the treeline it is the only thing that gives the face a
	# readable shape at conversation distance.
	pale.append(
		CreatureKit.part(
			MeshKit.ovoid(r * 0.26, r * 0.36, 0.45, 12, 7),
			Vector3(0, r * 0.52, -r * 0.74),
			Vector3(0.10, 0, 0),
			Vector3(1.15 * jaw_w, 1.0, 0.92)
		)
	)
	pale.append(
		CreatureKit.part(
			MeshKit.ovoid(r * 0.30, r * 0.40, 0.5, 12, 7),
			Vector3(0, r * 0.26, -r * 0.52),
			Vector3(-0.20, 0, 0),
			Vector3(1.22 * jaw_w, 0.92, 1.20)
		)
	)

	_head_horns(kind, r, rng, bone)

	# Tusks rise past the lip and splay OUT; straight up they cross the eyes and the
	# face reads as a cage.
	var tusk_l: float = r * lerpf(0.50, 0.78, heavy - 0.84)
	for sx in [-1.0, 1.0]:
		# Quantised, not because 7 % of a tusk is visible but because it is a mesh cache
		# key: `CreatureKit.fang` snaps to 2 mm, which still leaves ~28 distinct tusks
		# per archetype. Five is plenty of variety and bounds the cache.
		var jitter: float = snappedf(1.0 + rng.randf_range(-0.14, 0.14), 0.07)
		bone.append(
			CreatureKit.part(
				CreatureKit.fang(tusk_l * jitter, r * 0.100 * heavy, 0.55),
				Vector3(sx * r * 0.28, r * 0.30, -r * 0.82),
				Vector3(-0.24, 0, sx * -0.42)
			)
		)
		bone_fine.append(
			CreatureKit.part(
				CreatureKit.fang(r * 0.30, r * 0.050, -0.5), Vector3(sx * r * 0.20, r * 0.52, -r * 0.86), Vector3(PI - 0.28, 0, sx * 0.10)
			)
		)
	for i in range(4):
		var f: float = (float(i) / 3.0) * 2.0 - 1.0
		bone_fine.append(
			CreatureKit.part(
				CreatureKit.fang(r * 0.18, r * 0.038, -0.3), Vector3(f * r * 0.15, r * 0.50, -r * 0.88), Vector3(PI - 0.18, 0, f * 0.12)
			)
		)

	# Coarse hide: tubercles over the skull and brow. Placed on the BOUNDING ellipsoid
	# of the measured shell rather than at some fraction of `r` — the shell is narrower
	# than its bounding box almost everywhere, so a bump at 0.8 r is inside the head at
	# most heights.
	for i in range(11):
		var a: float = rng.randf_range(-2.3, 2.3)
		var el: float = rng.randf_range(-0.05, 0.72)
		# SNAPPED before it becomes a mesh cache key. `MeshKit.sphere` memoises on the
		# radius to four decimals, so an unsnapped random radius mints a fresh mesh on
		# almost every spawn: measured 2026-08-28, 25 enemies on unique seeds cost
		# 1151 ms of build and left the mesh cache at 824 entries still climbing, with
		# the 25th rakshasa still costing 23 ms against a 1.3 ms ProcRig baseline. Half
		# a millimetre of quantisation is invisible on a 6 mm wart and collapses the
		# key space to five buckets. (CreatureKit's own generators already snap; it is
		# the raw MeshKit calls in this file that did not.)
		var rr: float = snappedf(r * rng.randf_range(0.045, 0.080), 0.001)
		var dy: float = sin(el)
		var dh: float = cos(el)
		var px: float = sin(a) * dh * SKULL_HALFW * r
		var py: float = (SKULL_MID + dy * (SKULL_TOP - SKULL_MID)) * r
		var pz: float = -cos(a) * dh * absf(SKULL_FRONT) * r
		# Never on the eye. `tests/qa_creature_probe.gd` fires a ray at each iris and
		# names what it hits; on the champion it caught a wart sitting over the right
		# one. A defect that only appears on SOME seeds is worse than one that appears
		# on all of them, because the render you happen to take can miss it.
		if py > EYE_LO * r and py < EYE_HI * r and absf(px) < r * 0.46 and pz < -r * 0.40:
			continue
		fine.append(CreatureKit.part(MeshKit.sphere(rr, 6, 5), Vector3(px, py, pz), Vector3.ZERO, Vector3(1.0, 0.72, 1.0)))

	if kind == Kind.ELITE:
		_champion_face(r, form, fine, bone)

	_build_mane(rig, kind, rng, mats.hair)
	CreatureKit.solid(rig.head, form, mats.hide, "Skull")
	CreatureKit.solid(rig.head, pale, mats.pale, "Muzzle")
	CreatureKit.solid(rig.head, bone, mats.bone, "Horns")
	CreatureKit.detail(rig.head, fine, mats.hide, CreatureKit.DETAIL_DIST, "SkullFine")
	CreatureKit.detail(rig.head, bone_fine, mats.bone, CreatureKit.DETAIL_DIST, "Teeth")


## Horns, and the whole reason `CreatureKit.horn` exists.
##
## The two horns of a pair are generated SEPARATELY with different lengths, ridge
## counts and splay, because a matched pair reads as a hat. The three archetypes get
## three different growth directions so that the head is identifiable in outline
## before anything else about the body is: the warrior's sweep forward like a
## buffalo's, the archer's back along the skull like an antelope's, the champion's up
## and out with one of them snapped off.
static func _head_horns(kind: int, r: float, rng: RandomNumberGenerator, bone: Array) -> void:
	for sx in [-1.0, 1.0]:
		var vary: float = snappedf(1.0 + rng.randf_range(-0.10, 0.10), 0.05)
		var rid: int = 5 + rng.randi_range(0, 2)
		match kind:
			Kind.ARCHER:
				# Long, thin, laid back over the skull. Reads as speed.
				bone.append(
					CreatureKit.part(
						CreatureKit.horn(r * 3.9 * vary, r * 0.20, r * 0.022, 0.95, sx * -0.42, sx * 0.4, rid, 0.20),
						Vector3(sx * r * 0.44, r * 1.42, r * 0.10),
						Vector3(-0.55, 0, sx * -0.20)
					)
				)
			Kind.ELITE:
				# Massive, up and out. The left one is broken half-way: the champion
				# has already survived something.
				var broken: float = 0.28 if sx < 0.0 else 0.0
				bone.append(
					CreatureKit.part(
						CreatureKit.horn(r * 3.5 * vary, r * 0.50, r * 0.06, -0.42, sx * -0.95, sx * 0.5, rid, 0.36, broken),
						Vector3(sx * r * 0.52, r * 1.30, r * 0.02),
						Vector3(-0.12, 0, sx * -0.34)
					)
				)
			_:
				# Forward and down, then hooking up: a bull about to put its head into
				# something.
				bone.append(
					CreatureKit.part(
						CreatureKit.horn(r * 2.9 * vary, r * 0.32, r * 0.04, -1.45, sx * -0.60, sx * 0.6, rid, 0.32),
						Vector3(sx * r * 0.50, r * 1.32, -r * 0.02),
						Vector3(0.30, 0, sx * -0.42)
					)
				)


## Replace ProcRig's hair with a mane.
##
## ProcRig builds hair as ONE ovoid skull-cap, 1.04 * r wide against a skull of
## 0.92 * r — bigger than the head it sits on. On a person that is a scalp; on a
## rakshasa, photographed on 2026-08-28, it was a smooth brown helmet that swallowed
## the ears and left the face in a hole. This deletes it (matched by the material
## ProcRig gave it, which is the only thing that reliably identifies it) and grows a
## swept-back mane of coarse locks in its place — silhouette instead of a dome.
static func _strip_hair(rig: ProcRig) -> Material:
	var m_hair: Material = null
	var hair: Color = rig.cfg.hair_color
	for c in rig.head.get_children():
		if not (c is MeshInstance3D):
			continue
		var mi := c as MeshInstance3D
		var mm := mi.material_override as StandardMaterial3D
		# By NAME first — ProcRig names the cap "Hair", and that survived a head rework
		# that moved the hair colour out of reach of any loose colour match.
		if String(mi.name) == "Hair" or (mm != null and mm.albedo_texture == null and _near(mm.albedo_color, hair, 0.02)):
			if mm != null:
				m_hair = mm
			rig.head.remove_child(mi)
			mi.queue_free()
	build_audit["hair_stripped"] = m_hair != null
	if m_hair == null:
		push_warning("[enemy] no hair cap found to strip; ProcRig's hair node has changed")
	return m_hair


static func _build_mane(rig: ProcRig, kind: int, rng: RandomNumberGenerator, m_hair: Material) -> void:
	var r: float = rig.cfg.head
	var locks: int = 7 if kind == Kind.ARCHER else 9
	var span: float = 0.55 if kind == Kind.ARCHER else 0.95
	var parts: Array = []
	for i in range(locks):
		var f: float = (float(i) / float(locks - 1)) * 2.0 - 1.0
		var ln: float = snappedf(r * (1.5 + span * (1.0 - absf(f) * 0.55)) * (1.0 + rng.randf_range(-0.16, 0.16)), 0.01)
		parts.append(
			CreatureKit.part(
				MeshKit.tube(ln, [[0.0, r * 0.17], [0.55, r * 0.13], [1.0, r * 0.055]], 6, 0.70),
				Vector3(f * r * 0.58, r * 1.62, r * 0.16),
				Vector3(1.42 + rng.randf_range(-0.16, 0.16), f * 0.35, f * -0.42)
			)
		)
	# A low ruff along the nape, so the mane joins the neck instead of floating.
	parts.append(
		CreatureKit.part(
			MeshKit.ovoid(r * 0.48, r * 0.62, 0.5, 10, 6), Vector3(0, r * 0.92, r * 0.56), Vector3(0.30, 0, 0), Vector3(1.25, 1.0, 0.72)
		)
	)
	CreatureKit.solid(rig.head, parts, m_hair, "Mane")


## The champion's face, and only the champion's: a bone crest between the horns, three
## old scars, and ash warpaint in vertical bars.
##
## The intent is a creature that has FOUGHT, not a mutilated one. Scars are raised
## ridges of hide the same colour as the rest of it; the paint is what the player
## actually registers, because it is the only high-contrast thing on a body deliberately
## painted the colour of a hole in the treeline.
static func _champion_face(r: float, form: Array, fine: Array, bone: Array) -> void:
	bone.append(
		CreatureKit.part(
			MeshKit.ovoid(r * 0.16, r * 0.90, 0.6, 8, 6), Vector3(0, r * 1.56, r * 0.06), Vector3(-0.20, 0, 0), Vector3(1.0, 1.0, 0.42)
		)
	)
	for i in range(3):
		bone.append(
			CreatureKit.part(
				CreatureKit.fang(r * (0.34 - 0.06 * float(i)), r * 0.075, 0.4),
				Vector3(0, r * (1.48 - 0.28 * float(i)), r * (0.30 + 0.16 * float(i))),
				Vector3(0.55 + 0.25 * float(i), 0, 0)
			)
		)
	# Scar: a raised welt from the left brow down across the cheek.
	fine.append(
		CreatureKit.part(
			MeshKit.tube(r * 1.15, [[0.0, r * 0.045], [0.5, r * 0.055], [1.0, r * 0.028]], 5),
			Vector3(-r * 0.30, r * 1.16, -r * 0.62),
			Vector3(0.10, 0, 2.55)
		)
	)
	fine.append(
		CreatureKit.part(
			MeshKit.tube(r * 0.55, [[0.0, r * 0.038], [1.0, r * 0.020]], 5), Vector3(r * 0.44, r * 0.92, -r * 0.46), Vector3(0.0, 0, -2.10)
		)
	)
	form.append(
		CreatureKit.part(
			MeshKit.ovoid(r * 0.12, r * 0.34, 0.5, 6, 5),
			Vector3(r * 0.56, r * 1.04, -r * 0.16),
			Vector3(0, 0, -0.9),
			Vector3(1.0, 1.0, 0.5)
		)
	)


## Vertical ash bars down the champion's face, and two across the chest. Their own
## material, so they are their own draw and their own LOD group.
static func _champion_paint(rig: ProcRig, mats: Dictionary) -> void:
	# Paint has to HUG the surface it is on. Built from ovoids the first time, at five
	# segments and five rings, it rendered as pale faceted crystals stuck to the face
	# and chest (build/screenshots/creature_champion_face.png, 2026-08-28). A narrow
	# `plate` wrapped at the body's own radius lies on the skin instead.
	#
	# The bars are also SPLIT around the eyes. Four full-height bars centred on y 1.14 r
	# measured out at y 0.86..1.42 r, z -0.91..-0.63 r, which put four opaque staves
	# across both eyes and in front of them: the champion photographed as a face behind
	# prison bars with one eye showing (build/screenshots/creature_champion_face.png,
	# 2026-08-28). The eye band is y 0.83..0.95 r, so an upper run stops at 1.05 r and a
	# lower run starts at 0.78 r. Three bars rather than four, and less splay: the outer
	# pair of four sat at 41 degrees around a 0.90 r cylinder, where the skull's own
	# surface has fallen away to nothing like that radius, so they stood off the cheek.
	var r: float = rig.cfg.head
	var face: Array = []
	for i in range(3):
		var f: float = float(i) - 1.0
		face.append(
			CreatureKit.part(
				CreatureKit.plate(r * 0.88, r * 0.42, 0.13, 0.004, 5), Vector3(0, r * 1.26, 0), Vector3(0.0, PI + f * 0.22, 0.0)
			)
		)
		face.append(
			CreatureKit.part(
				CreatureKit.plate(r * 0.88, r * 0.46, 0.12, 0.004, 5), Vector3(0, r * 0.55, 0), Vector3(0.0, PI + f * 0.22, 0.0)
			)
		)
	CreatureKit.detail(rig.head, face, mats.paint, CreatureKit.DETAIL_DIST, "Warpaint")

	var b: float = rig.cfg.build
	var body: Array = []
	for i in range(3):
		body.append(
			CreatureKit.part(
				CreatureKit.plate(0.152 * b, 0.20, 0.11, 0.005, 5),
				Vector3(0, rig.cfg.chest * 0.46, 0),
				Vector3(0.0, PI + (float(i) - 1.0) * 0.30, 0.0)
			)
		)
	CreatureKit.detail(rig.chest, body, mats.paint, CreatureKit.DETAIL_DIST, "WarpaintChest")


# ---------------------------------------------------------------------------
#  TORSO AND LIMBS
# ---------------------------------------------------------------------------
## Mass where a fighting animal carries it. ProcRig's torso is a smooth shell with a
## pectoral hint; on a 2.5 m creature that reads as a mannequin in a rim light. This
## adds the trapezius yoke, the deltoids, a dorsal ridge of keratin scutes and the
## coarse tubercles that make ashen hide read as hide.
static func _build_torso_forms(rig: ProcRig, kind: int, mats: Dictionary) -> void:
	var b: float = rig.cfg.build
	var ch: float = rig.cfg.chest
	var sw: float = rig.cfg.shoulder_w
	var yoke: float = 1.0
	match kind:
		Kind.ARCHER:
			yoke = 0.80
		Kind.ELITE:
			yoke = 1.35
		_:
			yoke = 1.12

	var form: Array = []
	var fine: Array = []
	var bone: Array = []

	# Trapezius yoke: one mass from the base of the skull out to both shoulders. This
	# is the single biggest contributor to "broad", and it is what a smooth ovoid
	# torso cannot give you.
	#
	# Every half-width below is written in METRES against two numbers from ProcRig:
	# the shoulder sockets sit at +/- `shoulder_w`, and the torso loft's widest
	# half-width is 0.166 * build. Anything wider than about `shoulder_w` stops being
	# a muscle and becomes a shelf — the first version multiplied three factors
	# together and gave the champion a yoke 1.06 m across on a 0.60 m chest, which
	# photographed as a stone collar (build/screenshots/creature_champion_face.png,
	# 2026-08-28).
	var yoke_w: float = sw * (0.92 + 0.16 * yoke)
	form.append(
		CreatureKit.part(
			MeshKit.ovoid(0.088 * b, 0.20, 0.5, 12, 7),
			Vector3(0, ch * 0.90, 0.010 * b),
			Vector3(-0.16, 0, 0),
			Vector3(yoke_w / (0.088 * b), 0.70 * yoke, 1.05)
		)
	)
	# Latissimus flare: the back widens below the shoulders, which is what makes a
	# body read as a V rather than a tube.
	for sx in [-1.0, 1.0]:
		form.append(
			CreatureKit.part(
				MeshKit.ovoid(0.058 * b, 0.30, 0.5, 10, 7),
				Vector3(sx * (sw * 0.62), ch * 0.34, 0.034 * b),
				Vector3(0.0, 0, sx * 0.24),
				Vector3(0.88, 1.0, 0.70)
			)
		)
		# Sternal / pectoral slab on the FRONT (-Z after `_orient_front`).
		form.append(
			CreatureKit.part(
				MeshKit.ovoid(0.062 * b, 0.15, 0.5, 10, 7),
				Vector3(sx * (sw * 0.40), ch * 0.52, -0.086 * b),
				Vector3(0.10, 0, sx * -0.10),
				Vector3(1.05 * yoke, 1.0, 0.62)
			)
		)
	# A thick neck, because a short one on its own just leaves a gap. ProcRig gives
	# the neck a 0.052-0.062 * build limb; a rakshasa's is a column.
	CreatureKit.solid(
		rig.neck,
		[
			CreatureKit.part(
				MeshKit.ovoid(0.082 * b * (0.72 + 0.24 * yoke), rig.cfg.neck + 0.12, 0.5, 12, 7),
				Vector3(0, rig.cfg.neck * 0.42, 0.006),
				Vector3(-0.10, 0, 0),
				Vector3(1.0, 1.0, 0.94)
			)
		],
		mats.hide,
		"Neck"
	)

	# Dorsal ridge: seven keratin scutes down the spine, tallest between the shoulder
	# blades. Reads from the side at any distance and costs one draw.
	for i in range(7):
		var t: float = float(i) / 6.0
		var hgt: float = (0.055 + 0.055 * sin(t * PI)) * b
		bone.append(
			CreatureKit.part(
				CreatureKit.fang(hgt, 0.026 * b * (0.7 + 0.5 * sin(t * PI)), 0.7),
				Vector3(0, ch * lerpf(0.90, -0.14, t), (0.082 + 0.016 * sin(t * PI)) * b),
				Vector3(0.55, 0, 0)
			)
		)

	# Tubercles. Scattered, not gridded: a grid reads as a pattern and a pattern reads
	# as fabric.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(kind * 977 + 5)
	for i in range(16):
		var a: float = rng.randf_range(-PI, PI)
		var yy: float = rng.randf_range(-0.12, ch * 0.92)
		var rr: float = snappedf(rng.randf_range(0.012, 0.026) * b, 0.002)
		fine.append(
			CreatureKit.part(
				MeshKit.sphere(rr, 6, 5), Vector3(sin(a) * 0.155 * b, yy, cos(a) * 0.105 * b), Vector3.ZERO, Vector3(1.0, 0.70, 1.0)
			)
		)
	if kind == Kind.ELITE:
		# Three old cuts across the chest, raised and pale-edged.
		for i in range(3):
			fine.append(
				CreatureKit.part(
					MeshKit.tube(0.20 + 0.06 * float(i), [[0.0, 0.011 * b], [0.5, 0.014 * b], [1.0, 0.007 * b]], 5),
					Vector3(-0.06 * b + 0.05 * b * float(i), ch * (0.30 + 0.16 * float(i)), -0.115 * b),
					Vector3(0.15, 0.0, 2.2 - 0.25 * float(i))
				)
			)

	CreatureKit.solid(rig.chest, form, mats.hide, "Torso")
	CreatureKit.solid(rig.chest, bone, mats.bone, "Ridge")
	CreatureKit.detail(rig.chest, fine, mats.hide, CreatureKit.DETAIL_DIST, "Hide")

	# Deltoid caps and forearm tubercles, on the joints that carry them.
	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		var delt: Array = [
			CreatureKit.part(
				MeshKit.ovoid(0.082 * b * yoke, 0.20 * b, 0.42, 10, 7),
				Vector3(sx * 0.012 * b, -0.045 * b, 0),
				Vector3(0.0, 0, sx * -0.12),
				Vector3(1.05, 1.0, 0.92)
			)
		]
		CreatureKit.solid(rig.shoulder[side], delt, mats.hide, "Deltoid")
		var arm_fine: Array = []
		for i in range(5):
			var f: float = float(i) / 4.0
			arm_fine.append(
				CreatureKit.part(
					MeshKit.sphere(snappedf(rng.randf_range(0.008, 0.018) * b, 0.002), 6, 5),
					Vector3(sin(f * 9.0) * 0.048 * b, -f * rig.cfg.lower_arm * 0.8, cos(f * 9.0) * 0.048 * b),
					Vector3.ZERO,
					Vector3(1.0, 0.7, 1.0)
				)
			)
		CreatureKit.detail(rig.elbow[side], arm_fine, mats.hide, CreatureKit.DETAIL_DIST, "ArmHide")

	# Haunches: the hips carry visible glutes, or the legs look pinned on.
	var hip_form: Array = []
	for sx2 in [-1.0, 1.0]:
		hip_form.append(
			CreatureKit.part(
				MeshKit.ovoid(0.082 * b, 0.20, 0.5, 10, 7),
				Vector3(sx2 * 0.085 * b, -0.085, 0.055 * b),
				Vector3.ZERO,
				Vector3(1.0, 1.0, 0.86)
			)
		)
	CreatureKit.solid(rig.hips, hip_form, mats.hide, "Haunch")


## Clawed hands and feet.
##
## ProcRig ends every limb in a rounded stump — no fingers and barely a foot — which
## is the single loudest "mannequin" cue at conversation distance, and it is the one
## thing a rakshasa can least afford: the whole creature is a thing that grabs. Four
## digits and a dumb-thumb per hand, three toes per foot, and a claw on each. Base
## tier, because a hand silhouettes; the claws are fine enough to fade with the rest
## of the detail.
static func _build_extremities(rig: ProcRig, mats: Dictionary) -> void:
	var b: float = rig.cfg.build
	var hl: float = rig.cfg.hand
	var fl: float = rig.cfg.foot
	for side in ["L", "R"]:
		var digits: Array = []
		var claws: Array = []
		for i in range(4):
			var f: float = (float(i) / 3.0) * 2.0 - 1.0
			# The outer digits are shorter and swing back, the way a real hand splays.
			var ln: float = hl * (0.70 - absf(f) * 0.14)
			var rr: float = 0.017 * b * (1.0 - absf(f) * 0.16)
			digits.append(
				CreatureKit.part(
					MeshKit.tube(ln, [[0.0, rr], [0.55, rr * 0.88], [1.0, rr * 0.62]], 6, 0.85, Vector3(0, 0, -ln * 0.30)),
					Vector3(f * 0.030 * b, -hl * 0.92, -0.004),
					Vector3(PI - 0.24, f * 0.18, 0)
				)
			)
			claws.append(
				CreatureKit.part(
					CreatureKit.fang(hl * 0.34, rr * 0.72, 1.1),
					Vector3(f * 0.032 * b, -hl * 0.92 - ln, -ln * 0.30),
					Vector3(PI - 0.62, f * 0.18, 0)
				)
			)
		# The thumb sits inboard and points across the palm.
		var sx: float = 1.0 if side == "L" else -1.0
		digits.append(
			CreatureKit.part(
				MeshKit.tube(hl * 0.52, [[0.0, 0.019 * b], [1.0, 0.012 * b]], 6, 0.85),
				Vector3(sx * 0.040 * b, -hl * 0.60, -0.010),
				Vector3(PI - 0.55, 0, sx * 1.15)
			)
		)
		CreatureKit.solid(rig.hand[side], digits, mats.hide, "Digits")
		CreatureKit.detail(rig.hand[side], claws, mats.bone, CreatureKit.DETAIL_DIST, "Claws")

		var toes: Array = []
		var t_claws: Array = []
		for i in range(3):
			var f2: float = float(i) - 1.0
			toes.append(
				CreatureKit.part(
					MeshKit.ovoid(0.028 * b, fl * 0.34, 0.5, 7, 5),
					Vector3(f2 * 0.038 * b, -0.040, -fl * 0.62),
					Vector3(PI * 0.5, f2 * 0.22, 0),
					Vector3(1.0, 1.0, 0.80)
				)
			)
			t_claws.append(
				CreatureKit.part(
					CreatureKit.fang(fl * 0.26, 0.011 * b, 1.0),
					Vector3(f2 * 0.042 * b, -0.044, -fl * 0.80),
					Vector3(-PI * 0.42, f2 * 0.22, 0)
				)
			)
		# A heel, so the foot is not a flat wedge from behind.
		toes.append(
			CreatureKit.part(
				MeshKit.ovoid(0.042 * b, 0.070, 0.5, 8, 6), Vector3(0, -0.028, fl * 0.26), Vector3.ZERO, Vector3(1.0, 1.0, 0.85)
			)
		)
		CreatureKit.solid(rig.ankle[side], toes, mats.hide, "Toes")
		CreatureKit.detail(rig.ankle[side], t_claws, mats.bone, CreatureKit.DETAIL_DIST, "Talons")


## ProcRig's dhoti is one fixed size whatever body it is on — the wrap has to clear
## thighs at a fixed 0.11 m, so the radius is hard-coded. On a rakshasa half again as
## thick it reads as a tight skirt, and on the lean archer as a barrel. Scaled here to
## the build, with a floor that keeps the thighs inside the cloth.
static func _fit_dhoti(rig: ProcRig, _hide: Material) -> void:
	var b: float = rig.cfg.build
	var k: float = clampf(0.70 + 0.26 * b, 0.94, 1.30)
	# ProcRig now hangs the whole garment off a `skirt_node` that it swings with the
	# body, so the fit is one scale on that node. The garment's radius is fixed at
	# build time to clear thighs at 0.11 m — it is the one part of the body that does
	# NOT scale with `build`, so on a rakshasa half again as thick it reads as a tight
	# skirt and on the lean archer as a barrel.
	var n: Node3D = rig.skirt_node
	build_audit["dhoti_fitted"] = n != null
	if n != null:
		n.scale = Vector3(k, 1.0, k)


# ---------------------------------------------------------------------------
#  GEAR
# ---------------------------------------------------------------------------
static func _build_gear(rig: ProcRig, kind: int, seed_v: int, mats: Dictionary) -> void:
	match kind:
		Kind.ARCHER:
			_archer_kit(rig, mats)
		Kind.ELITE:
			_champion_kit(rig, seed_v, mats)
		_:
			_warrior_kit(rig, seed_v, mats)


## Scavenged, not issued: a hide pauldron lashed over one shoulder, bone bracers, a
## cord belt hung with trophies, and a single band of ochre-red — the only saturated
## colour on an otherwise ash-grey body, and the reason a warrior reads as a rakshasa
## rather than as a rock at thirty metres.
static func _warrior_kit(rig: ProcRig, seed_v: int, mats: Dictionary) -> void:
	var b: float = rig.cfg.build
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_v)

	# Pauldron on the LEFT: the sword is in the right hand, and armour goes on the arm
	# that is not swinging.
	var pl: Array = [
		CreatureKit.part(CreatureKit.plate(0.100 * b, 0.145 * b, 2.4, 0.016, 10), Vector3(0, 0.030 * b, 0), Vector3(-PI * 0.5, 0.0, 0.30)),
		CreatureKit.part(CreatureKit.plate(0.112 * b, 0.095 * b, 2.0, 0.014, 9), Vector3(0, -0.072 * b, 0), Vector3(-PI * 0.5, 0.0, 0.24)),
	]
	CreatureKit.solid(rig.shoulder["L"], pl, mats.leather, "Pauldron")
	# The lashings that hold it on, close up.
	var lash: Array = []
	for i in range(4):
		var a: float = -0.9 + 0.6 * float(i)
		lash.append(
			CreatureKit.part(
				MeshKit.tube(0.10 * b, [[0.0, 0.007], [1.0, 0.006]], 5),
				Vector3(sin(a) * 0.098 * b, 0.015 * b, cos(a) * 0.098 * b),
				Vector3(0.0, a, 1.3)
			)
		)
	CreatureKit.detail(rig.shoulder["L"], lash, mats.cord, CreatureKit.DETAIL_DIST, "Lashing")

	# Bone bracers, both forearms.
	for side in ["L", "R"]:
		var br: Array = [
			CreatureKit.part(CreatureKit.wrap(0.052 * b, 0.15, 5.2, 0.012, 12), Vector3(0, -rig.cfg.lower_arm * 0.60, 0), Vector3(0, 0, 0))
		]
		CreatureKit.solid(rig.elbow[side], br, mats.bone, "Bracer")
		var shin: Array = [
			CreatureKit.part(CreatureKit.wrap(0.062 * b, 0.13, 4.4, 0.014, 12), Vector3(0, -rig.cfg.shin * 0.62, 0), Vector3.ZERO)
		]
		CreatureKit.solid(rig.knee[side], shin, mats.leather, "Greave")

	# Cord belt with hanging trophies.
	var belt: Array = [CreatureKit.part(CreatureKit.wrap(0.146 * b, 0.055, TAU, 0.0, 16), Vector3(0, 0.010, 0), Vector3.ZERO)]
	CreatureKit.solid(rig.hips, belt, mats.cord, "Belt")
	var hang: Array = []
	for i in range(3):
		var a2: float = -0.7 + 0.7 * float(i) + rng.randf_range(-0.15, 0.15)
		var ln: float = snappedf(0.13 + rng.randf() * 0.09, 0.01)
		hang.append(
			CreatureKit.part(
				MeshKit.tube(ln, [[0.0, 0.008], [1.0, 0.006]], 5),
				Vector3(sin(a2) * 0.15 * b, -0.02, -cos(a2) * 0.15 * b),
				Vector3(PI, 0, 0)
			)
		)
		hang.append(
			CreatureKit.part(
				CreatureKit.fang(0.075, 0.014, 0.5), Vector3(sin(a2) * 0.15 * b, -0.02 - ln, -cos(a2) * 0.15 * b), Vector3(PI, 0, 0)
			)
		)
	CreatureKit.detail(rig.hips, hang, mats.bone, CreatureKit.DETAIL_DIST, "Trophies")

	# The ochre band, worn across the chest and knotted at the hip.
	# A band that goes AROUND the body. Built from two flattened ovoids the first
	# time, it read as a red shard stuck to the chest.
	var m_red := Mats.flat(Color(0.58, 0.19, 0.11), 0.90)
	var band: Array = [
		CreatureKit.part(CreatureKit.plate(0.152 * b, 0.075, 3.1, 0.008, 14), Vector3(0, rig.cfg.chest * 0.46, 0), Vector3(0.34, PI, 0.0)),
		CreatureKit.part(
			CreatureKit.plate(0.150 * b, 0.070, 2.6, 0.008, 12), Vector3(0, rig.cfg.chest * 0.38, 0), Vector3(-0.30, 0.0, 0.0)
		),
	]
	CreatureKit.solid(rig.chest, band, m_red, "Sash")


## Long forearm bracer on the BOW arm only, shin bindings, a quiver strap and a chalk
## band across the eyes. The asymmetry is the point: one armoured forearm reads as an
## archer from behind, before the bow is visible.
static func _archer_kit(rig: ProcRig, mats: Dictionary) -> void:
	var b: float = rig.cfg.build
	var m_bone := Mats.flat(Color(0.88, 0.84, 0.72), 0.50)
	var br: Array = [
		CreatureKit.part(CreatureKit.wrap(0.046 * b, 0.26, 5.4, 0.016, 12), Vector3(0, -rig.cfg.lower_arm * 0.52, 0), Vector3.ZERO)
	]
	CreatureKit.solid(rig.elbow["L"], br, m_bone, "Bracer")
	var thumb: Array = [
		CreatureKit.part(CreatureKit.wrap(0.036 * b, 0.06, 5.0, 0.006, 8), Vector3(0, -rig.cfg.hand * 0.35, 0), Vector3.ZERO)
	]
	CreatureKit.solid(rig.hand["R"], thumb, m_bone, "Tab")

	for side in ["L", "R"]:
		var bind: Array = []
		for i in range(3):
			bind.append(
				CreatureKit.part(
					CreatureKit.wrap(0.055 * b, 0.055, 5.6, 0.008, 10),
					Vector3(0, -rig.cfg.shin * (0.34 + 0.16 * float(i)), 0),
					Vector3(0, 0.4 * float(i), 0)
				)
			)
		CreatureKit.solid(rig.knee[side], bind, mats.cord, "Binding")

	# Quiver strap, running from the right shoulder to the left hip across the front.
	var strap: Array = [
		CreatureKit.part(
			MeshKit.ovoid(0.028 * b, 0.56, 0.5, 6, 6),
			Vector3(-0.030 * b, rig.cfg.chest * 0.42, -0.098 * b),
			Vector3(0.10, 0.0, 0.50),
			Vector3(1.0, 1.0, 0.34)
		),
		CreatureKit.part(
			MeshKit.ovoid(0.028 * b, 0.56, 0.5, 6, 6),
			Vector3(0.035 * b, rig.cfg.chest * 0.42, 0.098 * b),
			Vector3(-0.10, 0.0, 0.50),
			Vector3(1.0, 1.0, 0.34)
		),
	]
	CreatureKit.solid(rig.chest, strap, mats.leather, "Strap")

	# Chalk. It must not cross the EYE BAND, which `tests/qa_creature_probe.gd` measures
	# at y 0.83..0.95 r: the first version was one band centred on y 1.00 r and its AABB
	# came back at y 0.80..1.01 r, z -0.95..-0.76 r — spanning both eyes and 0.1 r in
	# FRONT of them. The archer photographed with a blank pale plank where its face
	# should be and no eyes at all (build/screenshots/creature_archer_face.png,
	# 2026-08-28), which is the one thing this creature cannot afford to lose: the
	# self-lit iris is the only warm pixel on it. So the paint goes above the brow and
	# down the cheeks, and leaves the eyes in clear hide.
	var r: float = rig.cfg.head
	var chalk: Array = [
		CreatureKit.part(CreatureKit.plate(r * 0.86, r * 0.16, 0.95, 0.004, 8), Vector3(0, r * 1.26, 0), Vector3(0.10, PI, 0))
	]
	for sx in [-1.0, 1.0]:
		chalk.append(
			CreatureKit.part(
				CreatureKit.plate(r * 0.88, r * 0.34, 0.13, 0.004, 5), Vector3(0, r * 0.60, 0), Vector3(0.0, PI + sx * 0.30, 0)
			)
		)
	CreatureKit.detail(rig.head, chalk, mats.paint, CreatureKit.DETAIL_DIST, "Chalk")


## Layered iron on ONE shoulder, a bracer to match, a breastplate scrap and warpaint.
## The champion is read from its asymmetry: the armoured side is the side it leads
## with, and one massive shoulder is worth more at a glance than a whole suit.
static func _champion_kit(rig: ProcRig, seed_v: int, mats: Dictionary) -> void:
	var b: float = rig.cfg.build
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_v * 7 + 3)
	var sh: Node3D = rig.shoulder["R"]

	# Three overlapping lames, each smaller than the last, plus a spike on the cap.
	# Sized against the shoulder it is worn on: ProcRig's shoulder ball is 0.072 * b
	# and the deltoid mass on top of it about 0.11 * b, so a cap of 0.105 * b sits
	# ON the arm. At 0.135 * b it stood off the body like a satellite dish
	# (build/screenshots/creature_champion_face.png, 2026-08-28).
	var pl: Array = [
		CreatureKit.part(CreatureKit.plate(0.105 * b, 0.150 * b, 2.5, 0.018, 12), Vector3(0, 0.040 * b, 0), Vector3(-PI * 0.5, 0, -0.24)),
		CreatureKit.part(CreatureKit.plate(0.118 * b, 0.095 * b, 2.2, 0.016, 12), Vector3(0, -0.070 * b, 0), Vector3(-PI * 0.5, 0, -0.20)),
		CreatureKit.part(CreatureKit.plate(0.118 * b, 0.080 * b, 1.9, 0.014, 12), Vector3(0, -0.150 * b, 0), Vector3(-PI * 0.5, 0, -0.16)),
		CreatureKit.part(CreatureKit.fang(0.105 * b, 0.020 * b, 0.3), Vector3(-0.060 * b, 0.085 * b, -0.01), Vector3(0.20, 0, -0.60)),
	]
	CreatureKit.solid(sh, pl, mats.iron, "Pauldron")
	var rivets: Array = []
	for i in range(7):
		var a: float = PI * (0.10 + 0.135 * float(i))
		rivets.append(CreatureKit.part(MeshKit.sphere(0.011 * b, 6, 5), Vector3(cos(a) * 0.118 * b, 0.02 * b, sin(a) * 0.112 * b)))
	CreatureKit.detail(sh, rivets, Mats.brass(), CreatureKit.DETAIL_DIST, "Rivets")

	var br: Array = [
		CreatureKit.part(CreatureKit.wrap(0.062 * b, 0.20, 5.4, 0.014, 12), Vector3(0, -rig.cfg.lower_arm * 0.58, 0), Vector3.ZERO)
	]
	CreatureKit.solid(rig.elbow["R"], br, mats.iron, "Bracer")

	# The other shoulder carries a torn cord and a trophy — the asymmetry that says
	# this one has been stripping the dead for a while.
	var trophy: Array = [
		CreatureKit.part(MeshKit.tube(0.11, [[0.0, 0.008], [1.0, 0.006]], 5), Vector3(0.02, -0.05, -0.055), Vector3(PI + 0.2, 0, 0.2)),
		CreatureKit.part(CreatureKit.horn(0.115, 0.020, 0.004, -0.9, 0.2, 0.0, 4, 0.24), Vector3(0.02, -0.16, -0.065), Vector3(PI, 0, 0.2)),
	]
	CreatureKit.solid(rig.shoulder["L"], trophy, mats.bone, "Trophy")

	# Breastplate scrap, lashed over the left of the chest. Sized against ProcRig's
	# torso loft, whose widest half-width is 0.166 * build — a plate any larger than
	# that stands off the body instead of lying on it.
	var chest_plate: Array = [
		CreatureKit.part(
			CreatureKit.plate(0.112 * b, 0.20, 1.05, 0.014, 10), Vector3(0.0, rig.cfg.chest * 0.44, 0.0), Vector3(0.08, PI - 0.40, 0.20)
		)
	]
	CreatureKit.solid(rig.chest, chest_plate, mats.iron, "Breastplate")

	# Heavy belt: cord with four iron plates hung on it.
	var belt: Array = [CreatureKit.part(CreatureKit.wrap(0.158 * b, 0.062, TAU, 0.0, 16), Vector3(0, 0.01, 0), Vector3.ZERO)]
	CreatureKit.solid(rig.hips, belt, mats.leather, "Belt")
	var plates: Array = []
	for i in range(4):
		var a2: float = -1.2 + 0.8 * float(i)
		plates.append(
			CreatureKit.part(
				MeshKit.box(Vector3(0.062, 0.075, 0.012)),
				Vector3(sin(a2) * 0.172 * b, -0.010, -cos(a2) * 0.172 * b),
				Vector3(0.0, a2 + PI, rng.randf_range(-0.12, 0.12))
			)
		)
	CreatureKit.detail(rig.hips, plates, mats.iron, CreatureKit.DETAIL_DIST, "BeltPlates")

	_champion_paint(rig, mats)


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
		# A dark warm mane. Do NOT darken this past about 0.17 on the red channel:
		# `_tune_rakshasa` finds ProcRig's iris by matching Color(0.095, 0.058, 0.040)
		# to a tolerance of 0.05, and a hair colour inside that box gets retinted amber
		# AND made emissive. At 0.13/0.092/0.072 it did exactly that, and the whole
		# hair cap came out as a glowing orange blob over the face
		# (build/screenshots/creature_warrior_face.png, 2026-08-28).
		"hair_color": Color(0.17, 0.120, 0.095),
		"dhoti": true,
		"sash": false,
		"jewellery": false,
		"topknot": false,
		# No beard. ProcRig's beard is a solid mass under the jaw, and on a rakshasa it
		# buried the one thing the face is built around — the tusks pushed up past the
		# lip. A rakshasa reads as not-a-person from its jaw; hiding the jaw threw that
		# away and gave back nothing.
		"beard": false,
		# ProcRig's horns are two smooth cones. `_head_horns` builds real ones with
		# growth collars, per-side asymmetry and a different growth direction per
		# archetype, so the rig's pair is switched off rather than buried under them.
		"horns": false,
		"seed": seed_v,
	}
	match kind:
		Kind.ARCHER:
			(
				base
				. merge(
					{
						# The tallest of the three and by far the lightest. It was 1.95 m —
						# SHORTER than the warrior — which is the opposite of what "lean and
						# tall" reads as, and left the two of them the same outline with
						# different tints. Long shins and long forearms do the rest.
						"height": 2.19,
						"hip_h": 1.23,
						"thigh": 0.60,
						"shin": 0.57,
						"foot": 0.26,
						"spine": 0.34,
						"chest": 0.24,
						"neck": 0.13,
						"head": 0.106,
						"shoulder_w": 0.158,
						"upper_arm": 0.42,
						"lower_arm": 0.41,
						"hand": 0.12,
						"hip_w": 0.098,
						"build": 0.88,
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
						# Bigger in every dimension, and a short thick neck so the head sits
						# down between the shoulders. `hip_h` is deliberately just UNDER
						# thigh + shin: `solve_two_bone` clamps the reach to l1 + l2 - 0.004,
						# so a hip set higher than the leg is long leaves the foot target
						# unreachable and the champion walks on tiptoe. The proportions are
						# also snapped to 3 cm by `ProcRig._quantise` before any of this is
						# measured, which is what makes the second champion free to build.
						"height": 2.48,
						"hip_h": 1.28,
						"thigh": 0.63,
						"shin": 0.60,
						"foot": 0.35,
						"spine": 0.40,
						"chest": 0.36,
						"neck": 0.07,
						"head": 0.148,
						"shoulder_w": 0.278,
						"upper_arm": 0.44,
						"lower_arm": 0.40,
						"hand": 0.17,
						"hip_w": 0.158,
						"build": 1.82,
						# Bruised iron with a cold violet cast; the champion is the darkest of
						# them, and reads as a hole in the treeline before you can count its
						# horns.
						# Bruised iron with a cold violet cast. Lifted from 0.50/0.45/0.54:
						# ProcRig scales skin tints by 1.34/1.24/1.16 and then multiplies a
						# hide sheet whose mean luminance is 0.37, so that landed at an
						# albedo near 0.23 and the champion photographed as a black
						# cut-out with no readable feature on it at two metres.
						"skin_tint": Color(0.64, 0.58, 0.68),
						"cloth_tint": Color(0.42, 0.36, 0.44),
					},
					true
				)
			)
		_:
			(
				base
				. merge(
					{
						# Short-legged, broad and thick-necked: heavy infantry. The old
						# hip_h of 1.10 snapped to 1.11 against a leg that snapped to 1.02,
						# which is 9 mm further than `solve_two_bone` will reach, so the
						# warrior stood with both knees locked straight.
						"height": 2.10,
						"hip_h": 1.08,
						"thigh": 0.51,
						"shin": 0.51,
						"foot": 0.31,
						"spine": 0.33,
						"chest": 0.32,
						"neck": 0.07,
						"head": 0.128,
						"shoulder_w": 0.236,
						"upper_arm": 0.37,
						"lower_arm": 0.35,
						"hand": 0.14,
						"hip_w": 0.136,
						"build": 1.46,
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
		if hide != null and m.albedo_texture == hide:
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
			"[enemy] %s got no amber eyes: ProcRig's eye materials no longer " % NAMES[kind] + "match what _tune_rakshasa looks for"
		)


## Loose colour match. Two materials built by different files are the same material
## when they LOOK the same, not when their literals are bit-identical.
static func _near(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) < tol and absf(a.g - b.g) < tol and absf(a.b - b.b) < tol


## How many eye materials the last `_tune_rakshasa` retinted. Zero means the coupling
## to ProcRig's eye colours has broken again; the test asserts on it.
static var last_eye_count: int = 0

## What the last rakshasa build found when it reached into ProcRig.
##
## Everything in `_orient_front`, `_strip_hair`, `_seat_eyes` and `_skull_at` is a
## coupling to a file this system does not own, matched by colour, by name or by a
## measured dimension. Couplings like that do not fail loudly — they silently stop
## matching, and the art regresses with every test still green. (That is exactly how
## the amber eye went missing for a whole art pass.) So each one records what it
## found, and `tests/creature_shots.gd` prints the lot.
static var build_audit: Dictionary = {}


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


## Dasagriva Ravana's crown of auxiliary heads and golden mukutas.
static func _build_ravana_ten_heads(rig: ProcRig, mats: Dictionary) -> void:
	if rig == null or rig.head == null:
		return
	if rig.head.get_node_or_null("RavanaHeads") != null:
		return
	var r: float = float(rig.cfg.get("head", 0.12))
	var crown_mat: StandardMaterial3D = mats.get("brass", Mats.pbr("brass", 2.0))
	var skin_mat: StandardMaterial3D = mats.get("skin", Mats.pbr("skin_warm", 2.0))
	# Central tall golden Mukuta on main head
	var main_crown := MeshInstance3D.new()
	main_crown.name = "MainMukuta"
	main_crown.mesh = MeshKit.tube(r * 1.45, [[0.0, r * 0.78], [0.45, r * 0.62], [0.85, r * 0.34], [1.0, r * 0.08]], 10)
	main_crown.material_override = crown_mat
	main_crown.position = Vector3(0.0, r * 1.65, 0.0)
	rig.head.add_child(main_crown)
	# Fan of flanking heads (5 left, 4 right) along an arched collar
	var offsets := [-4, -3, -2, -1, 1, 2, 3, 4, 5]
	for idx in offsets:
		var side_sign: float = signf(float(idx))
		var tier: float = absf(float(idx))
		var ang: float = side_sign * (0.26 * tier)
		var hr: float = r * clampf(0.68 - tier * 0.04, 0.46, 0.66)
		var hx: float = sin(ang) * (r * 1.05 + tier * r * 0.46)
		var hy: float = r * (0.78 - tier * 0.06)
		var hz: float = (1.0 - cos(ang)) * r * 0.55
		var sub_skull := MeshInstance3D.new()
		sub_skull.mesh = MeshKit.ovoid(hr * 0.86, hr * 1.04, 0.5, 10, 8)
		sub_skull.material_override = skin_mat
		sub_skull.position = Vector3(hx, hy, hz)
		sub_skull.rotation = Vector3(0.0, -ang * 0.55, -side_sign * 0.08 * tier)
		rig.head.add_child(sub_skull)
		var sub_crown := MeshInstance3D.new()
		sub_crown.mesh = MeshKit.tube(hr * 1.15, [[0.0, hr * 0.72], [0.6, hr * 0.44], [1.0, hr * 0.08]], 8)
		sub_crown.material_override = crown_mat
		sub_crown.position = Vector3(hx, hy + hr * 0.85, hz)
		sub_crown.rotation = sub_skull.rotation
		rig.head.add_child(sub_crown)
