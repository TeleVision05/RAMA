extends Node
## Boots the real Game, drops the NPCDirector into it and proves the villagers of
## Panchavati actually live there: they stand on the ground, they walk, the clock
## moves them from bed to work to the square, the player can talk to them, the
## dialogue graph branches, conditions hide options they have not earned, and input
## is locked for the length of a conversation and released after it.
##
## Also photographs the village so the result can be looked at rather than assumed.
##
##   tools/gd.sh scene res://scenes/npc_test.tscn

const OUT := "res://build/screenshots/npc_%s.png"

var game: Game
var dir: NPCDirector
var ds: DialogueSystem
var fails: Array[String] = []
var dlg_started: int = 0
var dlg_ended: int = 0
var events: Array[String] = []


func _ready() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build/screenshots"))
	game = Game.new()
	add_child(game)
	await frames(3)
	var p := game.player

	EventBus.dialogue_started.connect(func(_s, _n): dlg_started += 1)
	EventBus.dialogue_ended.connect(func(): dlg_ended += 1)
	EventBus.dialogue_event.connect(func(n, _src): events.append(n))

	# Game instantiates optional systems by class name. If it already built the
	# director, use THAT one — a second copy would put two of every villager on the
	# same patch of ground.
	var t0 := Time.get_ticks_msec()
	if game.npcs is NPCDirector:
		dir = game.npcs as NPCDirector
		print("[npc] Game built the director itself: %d villagers" % dir.npcs.size())
	else:
		dir = NPCDirector.new()
		dir.name = "NPCDirector"
		game.add_child(dir)
		dir.setup(game.world.map, game.world.sky)
		print("[npc] populated %d villagers in %d ms" % [dir.npcs.size(), Time.get_ticks_msec() - t0])
	ds = dir.dialogue
	if ds == null:
		ds = DialogueSystem.instance(self)
	print(
		(
			"[npc] npc group total=%d (a duplicate director would double this)"
			% get_tree().get_nodes_in_group("npc").size()
		)
	)
	if get_tree().get_nodes_in_group("npc").size() != dir.npcs.size():
		fails.append(
			(
				"the npc group holds %d nodes but the director owns %d"
				% [get_tree().get_nodes_in_group("npc").size(), dir.npcs.size()]
			)
		)
	await steps(30)

	_check_roster()
	_check_faces()
	await _check_movement()
	await _check_work_poses()
	await _check_neck_drift()
	await _check_schedule()
	await _check_dialogue(p)
	await _check_conditions()
	await _check_flee()
	await _shots()
	await _check_perf()

	print("\n=== RESULT: %s ===" % ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)


# ===========================================================================
#  1. everyone exists, is grounded, and honours the interactable contract
# ===========================================================================
func _check_roster() -> void:
	print("\n--- roster ---")
	var map := game.world.map
	if dir.npcs.size() < 12:
		fails.append("expected at least 12 NPCs, got %d" % dir.npcs.size())
	var roles := {}
	for n in dir.npcs:
		var gy := map.height_at(n.global_position.x, n.global_position.z)
		var dy: float = n.global_position.y - gy
		var wet := map.water_depth_at(n.global_position.x, n.global_position.z)
		print(
			(
				"  %-11s %-16s %-9s pos=(%7.1f,%6.1f) dy=%+.2f slope=%.2f dlg=%s"
				% [
					n.id,
					n.display_name,
					NPC.ST_NAMES[n.state],
					n.global_position.x,
					n.global_position.z,
					dy,
					map.slope_at(n.global_position.x, n.global_position.z),
					n.dialogue_id
				]
			)
		)
		if absf(dy) > 0.35:
			fails.append("%s is %.2f m off the ground" % [n.id, dy])
		if wet > 0.05:
			fails.append("%s is standing in %.2f m of water" % [n.id, wet])
		if not n.is_in_group("npc") or not n.is_in_group("interactable"):
			fails.append("%s is not in the npc/interactable groups" % n.id)
		if not n.has_method("interact_prompt") or not n.has_method("interact"):
			fails.append("%s does not implement the interactable contract" % n.id)
		if not DialogueData.has(n.dialogue_id):
			fails.append("%s points at a missing dialogue tree '%s'" % [n.id, n.dialogue_id])
		if n.rig == null or n.rig.get_child_count() == 0:
			fails.append("%s has no rig" % n.id)
		roles[n.role] = true
	for r in [
		NPC.Role.ELDER,
		NPC.Role.POTTER,
		NPC.Role.WEAVER,
		NPC.Role.FARMER,
		NPC.Role.HERDER,
		NPC.Role.FISHERMAN,
		NPC.Role.MOTHER,
		NPC.Role.CHILD,
		NPC.Role.GUARD,
		NPC.Role.TRAVELLER,
		NPC.Role.HERMIT
	]:
		if not roles.has(r):
			fails.append("no NPC fills role %d" % r)
	print("  prompt sample: '%s'" % dir.get_npc("suryadatta").interact_prompt())
	print("  streaming: %d of %d active at spawn" % [dir.active_count(), dir.npcs.size()])
	if dir.active_count() >= dir.npcs.size():
		fails.append("streaming never culls: all %d NPCs active while the hermit is 290 m away" % dir.npcs.size())


# ===========================================================================
#  1b. the FACE — measured, because "they have faces now" was wrong twice
# ===========================================================================
## proc_rig builds a head whose features are on +Z and buried inside the skull, and
## NPC._expose_face corrects it. Both of those corrections have already been got wrong
## once — an earlier pass shrank the hair cap to 0.88 x 0.82 and put it entirely INSIDE
## the skull, which left all twelve villagers bald in seventeen screenshots that were
## signed off as good. So this asserts the geometry rather than the intent: hair wider
## than the skull, eyes/nose/mouth standing proud of the surface, every head mesh in
## front of the origin on -Z, which is the direction the body walks and looks.
func _check_faces() -> void:
	print("\n--- faces ---")
	for n in dir.npcs:
		var f: Dictionary = n.face_report
		if f.is_empty():
			fails.append("%s: _expose_face recognised nothing on the head" % n.id)
			continue
		var sk: Vector3 = f["skull"]
		print(
			(
				"  %-11s hair +%.3f/%.3f m over the skull  eye +%.1f mm  nose +%.1f mm  mouth +%.1f mm  front z=%+.3f"
				% [
					n.id,
					f["hair_over_x"],
					f["hair_over_z"],
					float(f["eye_proud"]) * 1000.0,
					float(f["nose_proud"]) * 1000.0,
					float(f["mouth_proud"]) * 1000.0,
					f["front_z"]
				]
			)
		)
		if not bool(f["hair"]):
			fails.append("%s has no hair mesh at all" % n.id)
		elif float(f["hair_over_x"]) <= 0.0:
			fails.append(
				(
					"%s is BALD: the hair cap is %.3f m narrower than the skull, so it draws inside the head"
					% [n.id, -float(f["hair_over_x"])]
				)
			)
		if int(f["eyes"]) != 2:
			fails.append("%s has %d eyes" % [n.id, int(f["eyes"])])
		if float(f["eye_proud"]) <= 0.001:
			fails.append("%s: the eye is buried %.1f mm inside the skull" % [n.id, -float(f["eye_proud"]) * 1000.0])
		if float(f["eye_proud"]) > 0.014:
			fails.append(
				"%s: the eye stands %.1f mm proud — that is a stuck-on ball" % [n.id, float(f["eye_proud"]) * 1000.0]
			)
		if float(f["nose_proud"]) <= 0.002:
			fails.append("%s has no nose clearing the face (%.1f mm)" % [n.id, float(f["nose_proud"]) * 1000.0])
		if float(f["mouth_proud"]) <= 0.0:
			fails.append("%s has no mouth clearing the face" % n.id)
		# The whole head must lie forward of the origin on -Z.
		if float(f["front_z"]) > -sk.z * 0.9:
			fails.append(
				(
					"%s: the face is not on -Z (front-most head vertex at z=%+.3f, skull half-depth %.3f)"
					% [n.id, float(f["front_z"]), sk.z]
				)
			)


# ===========================================================================
#  2. they MOVE — 30 s of simulated village life
# ===========================================================================
func _check_movement() -> void:
	print("\n--- movement over 30 s ---")
	game.world.sky.paused = true
	game.world.sky.set_time(10.0)
	await steps(20)
	var start := {}
	for n in dir.npcs:
		if n.is_active():
			start[n.id] = n.global_position
	Engine.time_scale = 3.0
	await steps(600)  # 600 physics ticks x 3 = 30 simulated seconds
	Engine.time_scale = 1.0
	await steps(10)

	var moved := 0
	var map := game.world.map
	for n in dir.npcs:
		if not start.has(n.id):
			continue
		var d: float = start[n.id].distance_to(n.global_position)
		var dy: float = n.global_position.y - map.height_at(n.global_position.x, n.global_position.z)
		print("  %-11s moved %5.2f m   dy=%+.2f  state=%s" % [n.id, d, dy, NPC.ST_NAMES[n.state]])
		if d > 1.0:
			moved += 1
		if absf(dy) > 0.7:
			fails.append("%s drifted %.2f m off the ground while walking" % [n.id, dy])
		if map.water_depth_at(n.global_position.x, n.global_position.z) > 0.35:
			fails.append("%s walked into the river" % n.id)
	print("  %d of %d active villagers moved more than 1 m" % [moved, start.size()])
	if moved < int(float(start.size()) * 0.7):
		fails.append("only %d of %d villagers moved in 30 s — they are standing still" % [moved, start.size()])


# ===========================================================================
#  2b. every work kind actually poses the body
# ===========================================================================
## `_apply_work_pose` is a `match` with a `_: pass` default, so a Work value nobody
## wrote a case for silently produces a villager standing to attention — which is what
## both children were doing, because Work.PLAY had no case. Compare each villager's
## upper-arm direction against the same villager with `work_kind` forced to NONE: if
## the two agree, there is no pose.
func _check_work_poses() -> void:
	print("\n--- work poses ---")
	game.world.sky.paused = true
	game.world.sky.set_time(12.0)
	# Streaming off for the duration: the director re-culls the hermit within 0.25 s of
	# waking him, which silently turned his pose measurement into "0.0 deg".
	dir.set_process(false)
	await steps(10)
	var seen := {}
	for n in dir.npcs:
		# The hermit lives 290 m away and is streamed out, but his pose still has to
		# exist — an unposed Work value is a missing `match` case wherever it happens.
		var woke := false
		if not n.is_active():
			n.set_active(true)
			woke = true
			await steps(2)
		var real: int = n.work_kind
		var posed := await _arm_dirs(n, real)
		var rest := await _arm_dirs(n, NPC.Work.NONE)
		n.work_kind = real
		var dl: float = rad_to_deg(posed[0].angle_to(rest[0]))
		var dr: float = rad_to_deg(posed[1].angle_to(rest[1]))
		var moved: float = maxf(dl, dr)
		seen[real] = true
		print("  %-11s work=%-2d arms differ from rest by %5.1f deg (L %.1f, R %.1f)" % [n.id, real, moved, dl, dr])
		if real != NPC.Work.NONE and moved < 8.0:
			fails.append(
				(
					"%s has work kind %d but the pose does not move the arms (%.1f deg) — a missing `match` case"
					% [n.id, real, moved]
				)
			)
		if woke:
			n.set_active(false)
	for w in [
		NPC.Work.WHEEL,
		NPC.Work.LOOM,
		NPC.Work.HOE,
		NPC.Work.CAST,
		NPC.Work.CARRY,
		NPC.Work.WATCH,
		NPC.Work.LEAN,
		NPC.Work.BLESS,
		NPC.Work.PLAY,
		NPC.Work.HERD
	]:
		if not seen.has(w):
			fails.append("nobody on the roster exercises work kind %d" % w)

	# The water carrier's hand has to actually be at the pot she is steadying.
	var mum := dir.get_npc("sulochana")
	mum._moving = false
	mum._pause = 30.0
	await steps(30)
	var hand: Vector3 = (mum.rig.hand_attach["L"] as Node3D).global_position
	var pot: Vector3 = mum.prop.global_position if mum.prop != null else mum.global_position
	var reach: float = hand.distance_to(pot)
	print("  sulochana: steadying hand is %.2f m from the pot" % reach)
	if reach > 0.42:
		fails.append("the water carrier's hand is %.2f m from the pot she is steadying" % reach)
	dir.set_process(true)


## The direction the upper arms point, in chest space, after `w` has had time to settle.
func _arm_dirs(n: NPC, w: int) -> Array:
	n.work_kind = w
	for i in range(24):
		n._moving = false
		n._pause = 30.0
		await get_tree().physics_frame
	return [
		(n.rig.shoulder["L"] as Node3D).basis * Vector3(0, -1, 0),
		(n.rig.shoulder["R"] as Node3D).basis * Vector3(0, -1, 0),
	]


# ===========================================================================
#  2c. an additive pose must not compound
# ===========================================================================
## proc_rig ASSIGNS hips/spine/chest each frame but LERPS the neck, so a `+=` written
## into the neck by a work pose is re-read as its own input next frame and runs away to
## a fixed point. The hermit's +0.06 rad settled at +0.42 rad — a permanently craned
## neck that no screenshot of the hermit would have caught, because there is nothing to
## compare him with.
func _check_neck_drift() -> void:
	print("\n--- additive pose stability ---")
	var n := dir.get_npc("suryadatta")
	var was: int = n.work_kind
	n.work_kind = NPC.Work.BLESS
	n._moving = false
	n._pause = 200.0
	await steps(20)
	var early: float = n.rig.neck.rotation.x
	Engine.time_scale = 4.0
	for i in range(900):
		n._moving = false
		n._pause = 200.0
		await get_tree().physics_frame
	Engine.time_scale = 1.0
	var late: float = n.rig.neck.rotation.x
	n.work_kind = was
	print("  neck pitch under a +0.06 rad additive pose: %.4f -> %.4f rad after 60 s" % [early, late])
	if absf(late) > 0.20:
		fails.append(
			(
				"the additive neck pose compounded to %.3f rad (%.0f deg) — it is being fed back into itself"
				% [late, rad_to_deg(late)]
			)
		)
	if absf(late - early) > 0.06:
		fails.append("the neck pose drifted %.3f rad over 60 s instead of holding" % (late - early))


# ===========================================================================
#  3. the clock moves them
# ===========================================================================
func _check_schedule() -> void:
	print("\n--- schedule ---")
	game.world.sky.paused = true

	game.world.sky.set_time(1.5)
	await _sim(48.0)
	var home_ok := 0
	var indoors := 0
	for n in dir.npcs:
		if not n.is_active() or n.nocturnal:
			continue
		var d: float = _flat(n.global_position, n.home_pos)
		if n.is_indoors():
			indoors += 1
		if d < 3.5 or n.is_indoors():
			home_ok += 1
		else:
			print(
				(
					"  ! %s is %.1f m from home at 01:30 (state=%s goal=%.1f m away, on_floor=%s, v=%.2f)"
					% [
						n.id,
						d,
						NPC.ST_NAMES[n.state],
						_flat(n.global_position, n.goal()),
						n.is_on_floor(),
						Vector2(n.velocity.x, n.velocity.z).length()
					]
				)
			)
	var sleepers := 0
	for n in dir.npcs:
		if n.is_active() and not n.nocturnal:
			sleepers += 1
	print("  night 01:30 -> %d/%d villagers home, %d gone indoors" % [home_ok, sleepers, indoors])
	if home_ok < sleepers - 1:
		fails.append("night schedule did not send the villagers home (%d/%d)" % [home_ok, sleepers])
	if indoors == 0:
		fails.append("nobody went indoors at night")

	var guard := dir.get_npc("vikrama")
	if guard.is_indoors():
		fails.append("the gate guard went to bed; he is supposed to keep watch")

	game.world.sky.set_time(12.0)
	await _sim(60.0)
	var work_ok := 0
	var total := 0
	for n in dir.npcs:
		if not n.is_active():
			continue
		total += 1
		var d: float = _flat(n.global_position, n.work_pos)
		var limit: float = maxf(n.wander_radius + 3.0, 5.0)
		if d < limit:
			work_ok += 1
		else:
			print("  ! %s is %.1f m from its work station at noon (limit %.1f)" % [n.id, d, limit])
		if n.is_indoors():
			fails.append("%s is still indoors at noon" % n.id)
	print("  noon 12:00 -> %d/%d villagers at their station" % [work_ok, total])
	if work_ok < total - 1:
		fails.append("day schedule did not send the villagers to work (%d/%d)" % [work_ok, total])

	game.world.sky.set_time(18.4)
	await _sim(60.0)
	var square: Vector3 = dir.get_npc("ghatikara").social_pos
	var near := 0
	var counted := 0
	for n in dir.npcs:
		if not n.is_active() or n.id == "vamadeva":
			continue
		counted += 1
		if _flat(n.global_position, square) < 18.0:
			near += 1
	print("  evening 18:24 -> %d/%d gathered within 18 m of the square" % [near, counted])
	if near < counted - 2:
		fails.append("the evening gathering did not happen (%d/%d near the square)" % [near, counted])

	game.world.sky.set_time(10.5)
	await _sim(20.0)


# ===========================================================================
#  4. talking to somebody
# ===========================================================================
func _check_dialogue(p: Player) -> void:
	print("\n--- dialogue ---")
	var elder := dir.get_npc("suryadatta")

	# Walk up to him the way the player would: stand in front, press E.
	var away := Vector3(0.82, 0.0, 0.58).normalized()
	p.global_position = elder.global_position + away * 2.3 + Vector3(0, 0.25, 0)
	p.velocity = Vector3.ZERO
	p.facing_yaw = atan2(away.x, away.z)
	game.cam.yaw = p.facing_yaw
	await steps(6)
	var target := p.current_interactable()
	print("  interact target = %s" % (target.name if target else "<none>"))
	if target != elder:
		fails.append("standing in front of the elder did not make him the interact target")
	Input.action_press("interact")
	await steps(2)
	Input.action_release("interact")
	await steps(4)

	if not ds.is_active():
		fails.append("pressing interact did not open a dialogue")
		return
	if ds.start("potter", dir.get_npc("ghatikara"), p):
		fails.append("a second dialogue started while one was already running")
	print("  opened: node=%s speaker='%s' choices=%s" % [ds.current_node_id, ds.default_speaker(), ds.choice_labels()])
	if ds.current_node_id != "e_intro":
		fails.append("first conversation with the elder started at '%s', expected 'e_intro'" % ds.current_node_id)
	if not ds.box.visible:
		fails.append("the dialogue box is not visible while a dialogue is running")
	if not bool(p.get("_input_locked")):
		fails.append("player input was not locked when the dialogue opened")
	if not elder.is_talking():
		fails.append("the elder was not told he is in a conversation")
	if dlg_started != 1:
		fails.append("EventBus.dialogue_started fired %d times, expected 1" % dlg_started)
	print("  typing on open=%s (%d chars)" % [ds.box.is_typing(), ds.box._total])
	if not ds.box.is_typing():
		fails.append("the line did not start typing on: it appeared all at once")

	# The villager must stop walking while you talk to him.
	var was := elder.global_position
	await steps(90)
	var drift: float = was.distance_to(elder.global_position)
	print("  elder drifted %.3f m over 1.5 s of conversation" % drift)
	if drift > 0.35:
		fails.append("the elder wandered off mid-sentence (%.2f m)" % drift)

	# Branch: choice 1 is "Is all well here?" -> e_trouble.
	var labels := ds.choice_labels()
	if labels.size() != 3:
		fails.append("e_intro offered %d choices, expected 3" % labels.size())
	ds.choose(1)
	await steps(2)
	print("  chose '%s' -> node=%s" % [labels[1] if labels.size() > 1 else "?", ds.current_node_id])
	if ds.current_node_id != "e_trouble":
		fails.append("choosing branch 1 reached '%s', expected 'e_trouble'" % ds.current_node_id)

	# ... and on to e_look, which sets a flag through an action.
	ds.choose(1)
	await steps(2)
	if ds.current_node_id != "e_look":
		fails.append("second branch reached '%s', expected 'e_look'" % ds.current_node_id)
	if not bool(GameState.get_flag("elder_asked_help", false)):
		fails.append("the node action did not set the elder_asked_help flag")
	ds.advance()  # e_look -> e_hub
	await steps(2)
	if ds.current_node_id != "e_hub":
		fails.append("advancing past e_look reached '%s', expected 'e_hub'" % ds.current_node_id)

	# The last hub option ends the conversation.
	var hub := ds.choice_labels()
	print("  hub choices: %s" % [hub])
	if hub.size() < 2:
		fails.append("the elder's hub offered %d choices" % hub.size())
	ds.choose(hub.size() - 1)
	await steps(4)
	print(
		"  after ending: active=%s locked=%s box_visible=%s" % [ds.is_active(), p.get("_input_locked"), ds.box.visible]
	)
	if ds.is_active():
		fails.append("the conversation did not end on the closing choice")
	if bool(p.get("_input_locked")):
		fails.append("player input is still locked after the dialogue ended")
	if ds.box.visible:
		fails.append("the dialogue box is still on screen after the dialogue ended")
	if elder.is_talking():
		fails.append("the elder still thinks he is in a conversation")
	if dlg_ended != 1:
		fails.append("EventBus.dialogue_ended fired %d times, expected 1" % dlg_ended)

	# One-shot: he must not introduce himself twice.
	await steps(4)
	ds.start("elder", elder, p)
	await steps(2)
	print("  second visit starts at node=%s" % ds.current_node_id)
	if ds.current_node_id == "e_intro":
		fails.append("the elder re-introduced himself on the second conversation")
	if ds.current_node_id != "e_idle":
		fails.append("the second conversation started at '%s', expected small talk 'e_idle'" % ds.current_node_id)
	ds.cancel()
	await steps(2)
	if bool(p.get("_input_locked")):
		fails.append("cancelling a dialogue left the player locked")


# ===========================================================================
#  5. conditions hide options; actions move the world
# ===========================================================================
func _check_conditions() -> void:
	print("\n--- conditions and actions ---")
	var gopa := dir.get_npc("gopa")
	var p := game.player

	GameState.quests["q_lost_goat"] = {"state": "active", "objectives": {}}
	ds.start("herder", gopa, p)
	await steps(2)
	var without := ds.choice_labels()
	print("  without the bell: node=%s choices=%s" % [ds.current_node_id, without])
	if ds.current_node_id != "gp_active":
		fails.append("an active quest did not route the herder to 'gp_active' (got '%s')" % ds.current_node_id)
	for l in without:
		if String(l).contains("bell"):
			fails.append("the 'found the bell' option showed without the bell in the pack")
	ds.cancel()
	await steps(2)

	GameState.add_item("goat_bell", 1)
	ds.start("herder", gopa, p)
	await steps(2)
	var with := ds.choice_labels()
	print("  with the bell:    choices=%s" % [with])
	if with.size() != without.size() + 1:
		fails.append("carrying the bell did not reveal an extra option (%d vs %d)" % [with.size(), without.size()])
	var bell_idx := -1
	for i in range(with.size()):
		if String(with[i]).contains("bell"):
			bell_idx = i
	if bell_idx < 0:
		fails.append("the bell option is still hidden while carrying the bell")
	else:
		ds.choose(bell_idx)
		await steps(2)
		print(
			(
				"  -> node=%s  quest=%s  bell=%d  salve=%d"
				% [
					ds.current_node_id,
					ds.quest_state("q_lost_goat"),
					GameState.item_count("goat_bell"),
					GameState.item_count("healing_salve")
				]
			)
		)
		if ds.quest_state("q_lost_goat") != "complete":
			fails.append("handing over the bell did not complete the quest")
		if GameState.item_count("goat_bell") != 0:
			fails.append("the bell was not taken from the pack")
		if GameState.item_count("healing_salve") != 2:
			fails.append("the reward salve was not given (have %d)" % GameState.item_count("healing_salve"))
		ds.advance()
		await steps(2)
	if ds.is_active():
		ds.cancel()
		await steps(2)

	# The quest hook: the traveller starts it, gives the oil, and fires an event.
	var bhadra := dir.get_npc("bhadra")
	ds.start("traveller", bhadra, p)
	await steps(2)
	ds.choose(0)  # "Where have you come from?"
	await steps(2)
	ds.advance()  # b_where -> b_why
	await steps(2)
	ds.choose(0)  # "What lamp?"
	await steps(2)
	if ds.current_node_id != "b_lamp":
		fails.append("the traveller's thread reached '%s', expected 'b_lamp'" % ds.current_node_id)
	ds.choose(0)  # "I will climb up and light it."
	await steps(2)
	print(
		(
			"  quest q_shrine=%s  lamp_oil=%d  events=%s"
			% [ds.quest_state("q_shrine"), GameState.item_count("lamp_oil"), events]
		)
	)
	if ds.quest_state("q_shrine") != "active":
		fails.append("accepting the errand did not start q_shrine")
	if GameState.item_count("lamp_oil") < 1:
		fails.append("Bhadra did not hand over the lamp oil")
	if not events.has("shrine_errand_taken"):
		fails.append("the one-off dialogue event did not fire (events=%s)" % [events])
	await _drain("the traveller thread")

	# Now the hermit's entry must route to the completion branch, because the quest is
	# active AND the oil is in the pack.
	var hermit := dir.get_npc("vamadeva")
	ds.start("hermit", hermit, p)
	await steps(2)
	print("  hermit entry with oil: node=%s" % ds.current_node_id)
	if ds.current_node_id != "h_offer":
		fails.append("the hermit did not open on 'h_offer' with the quest active and oil carried")
	GameState.health = 40.0
	ds.choose(0)  # "Bhadra sent oil for the lamp."
	await steps(2)
	print(
		(
			"  after lighting: quest=%s oil=%d health=%.0f shrine_lit=%s"
			% [
				ds.quest_state("q_shrine"),
				GameState.item_count("lamp_oil"),
				GameState.health,
				GameState.get_flag("shrine_lit", false)
			]
		)
	)
	if ds.quest_state("q_shrine") != "complete":
		fails.append("lighting the lamp did not complete q_shrine")
	if GameState.item_count("lamp_oil") != 0:
		fails.append("the oil was not consumed")
	if not bool(GameState.get_flag("shrine_lit", false)):
		fails.append("the shrine_lit flag was not set")
	var q: Dictionary = GameState.quests.get("q_shrine", {})
	var objs: Dictionary = q.get("objectives", {})
	print("  q_shrine objectives=%s" % [objs])
	if int(objs.get("lamp", 0)) < 1:
		fails.append("quest_advance did not record the lamp objective (%s)" % [objs])
	await _drain("the hermit thread")
	if GameState.health <= 40.0:
		fails.append("the hermit's blessing did not heal (health %.0f)" % GameState.health)
	if bool(game.player.get("_input_locked")):
		fails.append("input still locked after the hermit conversation")


# ===========================================================================
#  6. panic
# ===========================================================================
func _check_flee() -> void:
	print("\n--- fleeing ---")
	var victim := dir.get_npc("ghatikara")
	var threat := Node3D.new()
	threat.name = "TestRakshasa"
	threat.add_to_group("enemy")
	game.add_child(threat)
	threat.global_position = victim.global_position + Vector3(6.0, 0.0, 4.0)
	var d0: float = victim.global_position.distance_to(threat.global_position)
	await _sim(6.0)
	var d1: float = victim.global_position.distance_to(threat.global_position)
	print("  potter: state=%s  distance to the rakshasa %.1f -> %.1f m" % [NPC.ST_NAMES[victim.state], d0, d1])
	if not victim.is_fleeing():
		fails.append("the potter did not flee from an enemy 7 m away")
	if d1 <= d0 + 2.0:
		fails.append("the potter fled but did not get away (%.1f -> %.1f m)" % [d0, d1])
	if victim.can_interact(game.player):
		fails.append("a fleeing villager still offers a conversation")

	threat.queue_free()
	await _sim(8.0)
	print("  after the threat is gone: state=%s" % NPC.ST_NAMES[victim.state])
	if victim.is_fleeing():
		fails.append("the potter never calmed down after the enemy was removed")


# ===========================================================================
#  7. look at it
# ===========================================================================
## Photography uses its own camera. The player's third-person rig is right for
## playing and wrong for framing: it ends up inside palm trunks and points at
## whatever the yaw happened to be.
var scam: Camera3D


func _shots() -> void:
	print("\n--- screenshots ---")
	scam = Camera3D.new()
	scam.name = "ShotCam"
	scam.far = 1400.0
	scam.near = 0.08
	game.add_child(scam)
	game.player.lock_input(true)

	await npc_shot("00_face", ["sulochana"], 12.0, 7.0, 1.30, 1.62, 36.0, 1.44)
	await npc_shot("01_square", ["suryadatta", "ila", "sulochana"], 10.5, 16.0, 9.5, 5.0, 58.0)
	await npc_shot("02_elder", ["suryadatta"], 11.2, 8.0, 2.7, 1.55, 46.0)
	await npc_shot("03_potter", ["ghatikara"], 13.0, 10.0, 2.6, 1.60, 48.0)
	await npc_shot("04_weaver", ["ratnavali"], 13.0, 9.0, 2.6, 1.60, 48.0)
	await npc_shot("05_mother", ["sulochana"], 12.0, 9.0, 2.8, 1.70, 48.0)
	await npc_shot("06_child", ["ila"], 12.4, 9.0, 2.5, 1.30, 46.0)
	await npc_shot("07_farmer", ["halin"], 13.4, 10.0, 2.9, 1.70, 48.0)
	await npc_shot("08_herder", ["gopa"], 14.0, 10.0, 3.0, 1.70, 48.0)
	await npc_shot("09_fisherman", ["kevat"], 9.2, 10.0, 3.0, 1.60, 48.0)
	await npc_shot("10_guard", ["vikrama"], 16.8, 10.0, 3.0, 1.75, 48.0)
	await npc_shot("11_traveller", ["bhadra"], 16.2, 10.0, 2.8, 1.70, 48.0)
	await npc_shot("12_hermit", ["vamadeva"], 8.6, 10.0, 3.0, 1.65, 48.0)
	await npc_shot("13_night_gate", ["vikrama"], 22.6, 14.0, 4.0, 2.10, 54.0)

	await _shot_greeting()
	await _shot_dialogue()


## Frame one or more villagers from the open side, with the player parked just behind
## the camera so terrain and NPC streaming stay centred on the shot.
func npc_shot(
	nm: String, ids: Array, hour: float, warm: float, back: float, high: float, fov: float, aim_h: float = 1.02
) -> void:
	var first := dir.get_npc(String(ids[0]))
	game.world.sky.paused = true
	game.world.sky.set_time(hour)
	_park(first.global_position + _clear_dir(first.global_position, 6.0) * 5.0)
	await _sim(warm)

	# Freeze and turn them BEFORE choosing the camera: a child at a full run covers
	# two metres while the shot is being set up, and the framing goes stale.
	var aim := _centroid(ids)
	var od := _clear_dir(aim, back)
	_park(aim + od * (back + 2.2))
	for id in ids:
		dir.get_npc(String(id)).face_point(game.player.global_position)
	await steps(6)

	aim = _centroid(ids)
	od = _clear_dir(aim, back)
	var eye := aim + od * back + Vector3(0.0, high, 0.0)
	eye.y = maxf(eye.y, game.world.map.height_at(eye.x, eye.z) + 1.1)
	_park(eye + od * 2.4)
	for id in ids:
		dir.get_npc(String(id)).face_point(game.player.global_position)
	scam.fov = fov
	scam.current = true
	scam.look_at_from_position(eye, aim + Vector3(0.0, aim_h, 0.0), Vector3.UP)
	game.world.terrain.update_focus(eye, true)
	await frames(30)
	await capture(nm)
	var n0 := dir.get_npc(String(ids[0]))
	var facing: float = (-n0.global_transform.basis.z).dot((eye - n0.global_position).normalized())
	print(
		(
			"  %-16s hour=%4.1f active=%d subject=(%.0f,%.0f) faces_camera=%+.2f"
			% [nm, hour, dir.active_count(), aim.x, aim.z, facing]
		)
	)
	if facing < 0.2:
		fails.append("%s: the subject is turned away from the camera (%.2f)" % [nm, facing])


func _centroid(ids: Array) -> Vector3:
	var a := Vector3.ZERO
	for id in ids:
		a += dir.get_npc(String(id)).global_position
	return a / float(ids.size())


## Direction from a villager toward the open ground of the square — the side a camera
## can stand on without a palm trunk in the way.
func _open_dir(p: Vector3) -> Vector3:
	var c := Vector3(WorldMap.P_VILLAGE.x, 0.0, WorldMap.P_VILLAGE.y)
	var d := c - p
	d.y = 0.0
	if d.length() < 6.0:
		d = Vector3(0.72, 0.0, 0.70)
	return d.normalized()


## Trees, huts and the well have no colliders, so a raycast cannot find them; the
## scatter list and the settlement's own hut table can. Pick the direction whose sight
## line to the subject is clear, preferring the open side of the village when several
## are. This reaches into sibling systems' private state, which is fine for a
## screenshot harness and would not be fine in the game.
func _blockers(aim: Vector3, radius: float) -> Array:
	var out: Array = []
	var veg := game.vegetation
	if veg != null:
		var pos: Variant = veg.get("_pos")
		if pos is PackedVector3Array:
			for tp in pos as PackedVector3Array:
				if Vector2(tp.x - aim.x, tp.z - aim.z).length() < radius:
					out.append({"p": Vector2(tp.x, tp.z), "r": 2.1})
	var st := game.settlement
	if st != null:
		var huts: Variant = st.get("_hut_spots")
		if huts is Array:
			for h in huts as Array:
				var hp: Vector2 = h.get("p", Vector2.ZERO)
				if hp.distance_to(Vector2(aim.x, aim.z)) < radius:
					out.append({"p": hp, "r": maxf(float(h.get("r", 3.0)), 3.0)})
		if st.has_method("points_of_interest"):
			for poi in st.points_of_interest():
				var pp: Vector3 = poi.get("position", Vector3.ZERO)
				if String(poi.get("kind", "")) == "landmark" and Vector2(pp.x - aim.x, pp.z - aim.z).length() < radius:
					out.append({"p": Vector2(pp.x, pp.z), "r": 2.6})
	return out


func _clear_dir(aim: Vector3, back: float) -> Vector3:
	var blockers := _blockers(aim, back + 8.0)
	var open := _open_dir(aim)
	var best := open
	var best_score := -1.0e9
	for i in range(36):
		var a: float = TAU * float(i) / 36.0
		var d := Vector2(cos(a), sin(a))
		var clear: float = back
		for b in blockers:
			var rel: Vector2 = (b["p"] as Vector2) - Vector2(aim.x, aim.z)
			var br: float = b["r"]
			var along: float = rel.dot(d)
			if along < 0.3 or along > back + 4.0:
				continue
			if absf(rel.cross(d)) < br:
				clear = minf(clear, along - br)
		var score: float = minf(clear, back) * 2.4 + d.dot(Vector2(open.x, open.z)) * 1.2
		if score > best_score:
			best_score = score
			best = Vector3(d.x, 0.0, d.y)
	return best


func _park(p: Vector3) -> void:
	var gy := game.world.map.height_at(p.x, p.z)
	game.player.global_position = Vector3(p.x, gy + 0.2, p.z)
	game.player.velocity = Vector3.ZERO


## A villager noticing you and saying so, caught while the bark is on screen.
func _shot_greeting() -> void:
	var n := dir.get_npc("gopa")
	game.world.sky.set_time(13.6)
	_park(n.global_position + Vector3(16.0, 0.0, 16.0))
	await _sim(4.0)
	var od := _clear_dir(n.global_position, 3.4)
	_park(n.global_position + od * 3.2)
	await steps(40)
	var eye := n.global_position + od * 3.4 + Vector3(0.0, 1.85, 0.0)
	scam.fov = 46.0
	scam.current = true
	scam.look_at_from_position(eye, n.global_position + Vector3(0.0, 1.55, 0.0), Vector3.UP)
	game.world.terrain.update_focus(eye, true)
	await frames(24)
	print("  greeting bark visible=%s text='%s'" % [n.bark.visible, n.bark.text])
	if not n.bark.visible:
		fails.append("no greeting bark appeared when the player walked up to Gopa")
	await capture("14_greeting")


## The conversation, over Rama's shoulder, from a hand-placed third-person camera.
func _shot_dialogue() -> void:
	var p := game.player
	p.lock_input(false)
	game.world.sky.set_time(11.4)
	var elder := dir.get_npc("suryadatta")
	_park(elder.global_position + _clear_dir(elder.global_position, 6.0) * 6.0)
	await _sim(6.0)

	var od := _clear_dir(elder.global_position, 6.0)
	var fwd := -od  # from the camera side toward the elder
	p.global_position = elder.global_position + od * 2.5 + Vector3(0.0, 0.2, 0.0)
	p.velocity = Vector3.ZERO
	p.facing_yaw = atan2(-fwd.x, -fwd.z)
	game.cam.yaw = p.facing_yaw
	elder.face_point(p.global_position)
	await steps(20)

	# Over Rama's shoulder: he sits low-left, the elder stands clear above the panel.
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var eye := elder.global_position + od * 4.3 + right * 1.05 + Vector3(0.0, 1.95, 0.0)
	eye.y = maxf(eye.y, game.world.map.height_at(eye.x, eye.z) + 1.4)
	scam.fov = 50.0
	scam.current = true
	scam.look_at_from_position(eye, elder.global_position + Vector3(0.0, 1.48, 0.0), Vector3.UP)
	game.world.terrain.update_focus(eye, true)

	GameState.flags["dlg_seen"] = {}  # let him introduce himself again for the photo
	ds.start("elder", elder, p)
	await steps(4)
	ds.box.skip_typing()
	await frames(40)
	await capture("15_dialogue")
	print("  dialogue shot: node=%s choices=%d" % [ds.current_node_id, ds.box.choice_count()])

	ds.box.move_selection(1)
	ds.choose(1)
	await steps(4)
	ds.box.skip_typing()
	await frames(30)
	await capture("16_reply")

	# Mid-reveal, to prove the typewriter is really typing.
	ds.advance()
	await steps(2)
	await frames(5)
	await capture("17_typing")
	ds.cancel()
	await steps(4)


# ===========================================================================
#  8. what the village costs per frame
# ===========================================================================
## Two numbers, both asked for by name: the absolute per-frame cost of the running
## game over 300 frames, and the share of it that belongs to this system.
##
## The share is measured the way ARCHITECTURE.md says to measure anything here — the
## villagers are switched on and off INSIDE one process, in alternating blocks, and the
## reported figure is the MEDIAN OF THE PAIRED DIFFERENCES. Two separate runs of this
## project disagree by more than 10 ms, and a mean is dragged around by a single
## streaming hitch, so neither would answer the question.
const PERF_BLOCK := 20
const PERF_PAIRS := 20
const PERF_BUDGET := 5.0


func _check_perf() -> void:
	print("\n--- performance ---")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	game.player.lock_input(true)
	game.world.sky.paused = true
	game.world.sky.set_time(12.0)
	# Stand in the middle of the village, where every villager is loaded and drawing.
	_park(
		(
			Vector3(dir.get_npc("suryadatta").global_position.x, 0.0, dir.get_npc("suryadatta").global_position.z)
			+ Vector3(6.0, 0.0, 6.0)
		)
	)
	scam.current = false
	game.cam.camera().current = true
	game.world.terrain.update_focus(game.player.global_position, true)
	await frames(90)

	var cpu := 0.0
	var phys := 0.0
	for i in range(300):
		await get_tree().process_frame
		cpu += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	cpu /= 300.0
	phys /= 300.0
	print("  300 frames in the village, %d villagers active:" % dir.active_count())
	print("    TIME_PROCESS          = %.3f ms/frame" % cpu)
	print("    TIME_PHYSICS_PROCESS  = %.3f ms/frame" % phys)

	var d_cpu: Array[float] = []
	var d_phys: Array[float] = []
	var on_cpu := 0.0
	var off_cpu := 0.0
	var on_ph := 0.0
	var off_ph := 0.0
	for i in range(PERF_PAIRS):
		_npcs_enabled(true)
		var on := await _perf_block(PERF_BLOCK)
		_npcs_enabled(false)
		var off := await _perf_block(PERF_BLOCK)
		d_cpu.append(on[0] - off[0])
		d_phys.append(on[1] - off[1])
		on_cpu += on[0]
		off_cpu += off[0]
		on_ph += on[1]
		off_ph += off[1]
	print(
		(
			"  block means: process %.3f on / %.3f off ms   physics %.3f on / %.3f off ms"
			% [on_cpu / PERF_PAIRS, off_cpu / PERF_PAIRS, on_ph / PERF_PAIRS, off_ph / PERF_PAIRS]
		)
	)
	_npcs_enabled(true)
	d_cpu.sort()
	d_phys.sort()
	var med_cpu: float = d_cpu[d_cpu.size() / 2]
	var med_phys: float = d_phys[d_phys.size() / 2]
	print("  villagers on vs off, %d interleaved pairs, median paired difference:" % PERF_PAIRS)
	print(
		(
			"    TIME_PROCESS          = %+.3f ms   (quartiles %+.3f .. %+.3f)"
			% [med_cpu, d_cpu[d_cpu.size() / 4], d_cpu[d_cpu.size() * 3 / 4]]
		)
	)
	print(
		(
			"    TIME_PHYSICS_PROCESS  = %+.3f ms   (quartiles %+.3f .. %+.3f)"
			% [med_phys, d_phys[d_phys.size() / 4], d_phys[d_phys.size() * 3 / 4]]
		)
	)
	print("    total attributable    = %+.3f ms/frame (budget %.1f)" % [med_cpu + med_phys, PERF_BUDGET])
	if med_cpu + med_phys > PERF_BUDGET:
		fails.append("the villagers cost %.2f ms/frame, over the %.1f ms budget" % [med_cpu + med_phys, PERF_BUDGET])


## Mean TIME_PROCESS and TIME_PHYSICS_PROCESS over `n` frames, in milliseconds.
func _perf_block(n: int) -> Array:
	var a := 0.0
	var b := 0.0
	for i in range(n):
		await get_tree().process_frame
		a += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		b += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	return [a / float(n), b / float(n)]


## Simulation AND drawing off, without `set_active`, which teleports them onto the
## schedule and would put a spawn cost inside the measurement.
func _npcs_enabled(on: bool) -> void:
	dir.set_process(on)
	for n in dir.npcs:
		n.set_physics_process(on and n.is_active())
		n.visible = on and n.is_active() and not n.is_indoors()


func capture(nm: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(OUT % nm)


# ===========================================================================
#  helpers
# ===========================================================================
## Advance until the conversation closes, refusing to spin forever on a graph that
## loops or a panel that never resolves.
func _drain(what: String) -> void:
	var guard := 0
	while ds.is_active() and guard < 40:
		guard += 1
		ds.advance()
		await steps(2)
	if ds.is_active():
		fails.append("%s never ended after 40 advances (stuck at '%s')" % [what, ds.current_node_id])
		ds.cancel()
		await steps(2)


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Run `secs` of simulated village time as fast as the physics loop allows.
func _sim(secs: float) -> void:
	Engine.time_scale = 5.0
	await steps(int(maxf(1.0, secs * 60.0 / 5.0)))
	Engine.time_scale = 1.0
	await steps(2)


func steps(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame
