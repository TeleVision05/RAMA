extends Node
## Drives all three quests end to end in a real running Game and asserts the state
## machine, the gating, the signals, the world objects and the save round-trip.
##
## Everything here goes through the same doors the player uses: the real interactable
## nodes are `interact()`ed, the ambush is killed with `take_damage`, the discovery
## zones are entered by moving the player. `notify_interact` is only called directly
## where the test is checking the seam itself.

const OUT := "res://build/screenshots/quest_%s.png"

var game: Game
var fails: Array[String] = []
var log_order: Array[String] = []
var notes: Array[String] = []
var shots: int = 0


func _ready() -> void:
	await get_tree().process_frame
	_run()


func ok(n: String, v: bool, d: String = "") -> void:
	print("  [%s] %-52s %s" % ["PASS" if v else "FAIL", n, d])
	if not v:
		fails.append(n + ((" — " + d) if d != "" else ""))


func frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


## Wait up to `secs` for a condition, so the test never sleeps longer than it must.
func until(c: Callable, secs: float = 4.0) -> bool:
	var t := 0.0
	while t < secs:
		if c.call():
			return true
		await get_tree().physics_frame
		t += 1.0 / 60.0
	return c.call()


func teleport(at: Vector2, yaw: float = 0.0) -> void:
	var m: WorldMap = game.world.map
	game.player.global_position = Vector3(at.x, m.height_at(at.x, at.y) + 0.35, at.y)
	game.player.velocity = Vector3.ZERO
	game.player.facing_yaw = yaw
	game.player.rotation.y = yaw
	game.cam.yaw = yaw
	game.world.terrain.update_focus(game.player.global_position, true)
	await frames(3)


## Point the camera at a place from where the player is standing.
func look_at_xz(at: Vector2) -> void:
	var p := game.player.global_position
	var d := Vector2(at.x - p.x, at.y - p.z)
	if d.length() < 0.01:
		return
	var yaw := atan2(-d.x, -d.y)
	game.player.facing_yaw = yaw
	game.player.rotation.y = yaw
	game.cam.yaw = yaw
	await frames(6)


## Screenshots are taken from a camera the test owns, not from the player's. The
## player camera runs a spring arm that collides with the world: framed on the bell
## frame it ended up inside the shrine's flagstone paving, and the "look at what you
## built" shot showed the underside of a floor (2026-08-28).
func free_shot(name: String, eye: Vector3, target: Vector3, fov: float = 62.0) -> void:
	# Light it. The run takes several minutes of world time, so half these frames
	# came back at dusk or after dark and could not be judged; the clock is put back
	# the moment the shutter closes.
	var was := game.world.sky.time_of_day
	game.world.sky.set_time(9.6)
	var prev := get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.fov = fov
	cam.far = 900.0
	game.add_child(cam)
	cam.look_at_from_position(eye, target, Vector3.UP)
	cam.make_current()
	await frames(4)
	await shot(name)
	cam.queue_free()
	await get_tree().process_frame
	if prev != null and is_instance_valid(prev):
		prev.make_current()
	game.world.sky.set_time(was)
	await frames(2)


## A camera at `eye` in plan, `up` metres above the ground under `at`. The height
## comes from the TARGET, not from under the camera: the shrine forecourt sits on a
## plateau whose edge falls 11 m, and a camera whose height was taken from its own
## xz ended up underneath the flagstones looking at their undersides.
func eye_over(eye: Vector2, at: Vector2, up: float) -> Vector3:
	var m: WorldMap = game.world.map
	return Vector3(eye.x, m.height_at(at.x, at.y) + up, eye.y)


func ground(at: Vector2, up: float = 0.0) -> Vector3:
	var m: WorldMap = game.world.map
	return Vector3(at.x, m.height_at(at.x, at.y) + up, at.y)


func obj_node(nm: String) -> Node3D:
	return game.interactables.find_object(nm)


func use(nm: String) -> bool:
	var n := obj_node(nm)
	if n == null:
		fails.append("no interactable called " + nm)
		return false
	if n.has_method("can_interact") and not n.call("can_interact", game.player):
		return false
	n.call("interact", game.player)
	await frames(3)
	return true


func topup() -> void:
	GameState.health = GameState.max_health
	if game.player.has_method("heal"):
		game.player.heal(GameState.max_health)


# ===========================================================================
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build/screenshots"))
	game = Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	var qs: QuestSystem = game.quests as QuestSystem
	ok("quest system present", qs != null)
	if qs == null:
		return _finish()
	ok("quest system is in the lookup group", qs.is_in_group("quest_system"))
	var ic: int = game.interactables.get_child_count() if game.interactables else 0
	ok("interactables placed", game.interactables != null and ic >= 18, "%d objects" % ic)

	EventBus.quest_started.connect(func(id): log_order.append("start:" + id))
	EventBus.quest_objective_changed.connect(func(q, o, n, t): notes.append("%s/%s %d/%d" % [q, o, n, t]))
	EventBus.quest_objective_completed.connect(func(q, o): log_order.append("obj:%s/%s" % [q, o]))
	EventBus.quest_completed.connect(func(id): log_order.append("done:" + id))

	await _section_model(qs)
	await _section_q1(qs, p)
	await _section_q2(qs, p)
	await _section_q3(qs, p)
	await _section_marker(qs, p)
	await _section_persistence(qs)
	await _section_failure(qs)
	await _section_dialogue(qs, p)
	await _section_kandas(qs, p)

	print("\nsignal order (%d): %s" % [log_order.size(), ", ".join(log_order)])
	print("screenshots written: %d" % shots)
	_finish()


# ---------------------------------------------------------------------------
func _section_model(qs: QuestSystem) -> void:
	print("\n-- the model --")
	ok("eight quests are authored (3 village + 5 Kandas)", QuestData.quest_ids().size() == 8, str(QuestData.quest_ids()))
	var kinds: Dictionary = {}
	for qid in QuestData.quest_ids():
		for o in QuestData.objective_list(String(qid)):
			kinds[(o as Quest.Objective).kind_name()] = true
	var want := ["talk_to", "go_to", "kill", "collect", "interact", "discover", "escort", "return"]
	var missing: Array = []
	for k in want:
		if not kinds.has(k):
			missing.append(k)
	ok(
		"every objective kind is used by a real quest",
		missing.is_empty(),
		"missing " + str(missing) if not missing.is_empty() else str(kinds.keys())
	)

	# Prerequisites, both clauses, without touching the live world.
	ok("an empty prerequisite always passes", qs.prereq_met({}))
	ok("a discovery prerequisite that is unmet fails", not qs.prereq_met({"discovered": ["hidden_grove"]}))
	ok("a quest prerequisite that is unmet fails", not qs.prereq_met({"quests": ["q_shrine"]}))
	GameState.discovered["ford"] = true
	ok("a discovery prerequisite that is met passes", qs.prereq_met({"discovered": ["ford"]}))
	GameState.discovered.erase("ford")

	# Every named place in the world is a discoverable zone, centred where the map
	# says it is. A zone that has drifted off its landmark is a discovery the player
	# gets standing in a field.
	var named := {
		"village": WorldMap.P_VILLAGE,
		"shrine": WorldMap.P_SHRINE,
		"ruins": WorldMap.P_RUINS,
		"waterfall": WorldMap.P_WATERFALL,
		"ford": WorldMap.P_FORD,
		"forest_camp": WorldMap.P_FOREST_CAMP,
		"hidden_grove": WorldMap.P_HIDDEN_GROVE,
		"badlands": WorldMap.P_BADLANDS,
		"fields": WorldMap.P_FIELDS,
		"lookout": WorldMap.P_LOOKOUT
	}
	var bad: Array = []
	for pid in named:
		if not QuestData.PLACES.has(pid):
			bad.append("%s missing" % pid)
			continue
		var d: Dictionary = QuestData.PLACES[pid]
		if (d["at"] as Vector2).distance_to(named[pid]) > 0.01:
			bad.append("%s is not at %s" % [pid, str(named[pid])])
		if String(d.get("name", "")) == "" or float(d.get("r", 0.0)) < 10.0:
			bad.append("%s has no name or too small a zone" % pid)
	ok("all ten named places are discoverable zones on their landmarks", bad.is_empty() and QuestData.PLACES.size() == 10, str(bad))

	ok("an unknown quest cannot start", not qs.start_quest("q_nonsense"))
	ok("q_wild is gated behind the shrine", not qs.can_start("q_wild") and not qs.start_quest("q_wild"), "state=" + qs.state_of("q_wild"))


# ---------------------------------------------------------------------------
func _section_q1(qs: QuestSystem, p: Player) -> void:
	print("\n-- Q1  The Path Through the Forest --")
	ok("q_lost_goat starts", qs.start_quest("q_lost_goat"))
	ok("starting twice is refused", not qs.start_quest("q_lost_goat"))
	var seeded: Dictionary = GameState.quests["q_lost_goat"]["objectives"]
	ok("every visible step is seeded into the log for the journal", seeded.size() == 7, "%d keys: %s" % [seeded.size(), str(seeded.keys())])
	ok("the first step is to hear Gopa out", qs.current_objective("q_lost_goat").id == "speak")

	# A step behind a gate cannot be advanced out of order.
	qs.notify_interact("forest_evidence")
	await frames(2)
	ok("a gated step refuses progress out of order", qs.progress("q_lost_goat", "investigate") == 0)

	qs.notify_talk("gopa")
	await frames(4)
	ok("talking to Gopa clears the first step", qs.objective_done("q_lost_goat", "speak"))
	ok("the marked place is next now", qs.current_objective("q_lost_goat").id == "travel")

	var found: Array[String] = []
	EventBus.location_discovered.connect(func(id, _n): found.append(String(id)))
	await teleport(Vector2(-184.0, -14.0))
	await until(func(): return qs.objective_done("q_lost_goat", "travel"), 3.0)
	await teleport(Vector2(-196.0, -34.0))
	await until(func(): return GameState.discovered.has("forest_camp"), 3.0)
	ok("walking into a named place discovers it once", found.has("forest_camp") and found.count("forest_camp") == 1, str(found))
	await teleport(Vector2(-184.0, -14.0))
	await frames(6)
	ok("walking to the marked place clears the GO_TO step", qs.objective_done("q_lost_goat", "travel"))

	# The two pieces of evidence, used as objects, not as calls into the system.
	ok("the broken cart is there and can be searched", await use("BrokenCart"))
	ok("the cart yields Bindu's bell", GameState.has_item("goat_bell"))
	ok("finding the bell clears the COLLECT step", qs.objective_done("q_lost_goat", "bell"))
	ok(
		"one piece of evidence is not two",
		qs.progress("q_lost_goat", "investigate") == 1,
		"%d/2" % qs.progress("q_lost_goat", "investigate")
	)
	await free_shot("q1_evidence", eye_over(Vector2(-179.8, -11.6), Vector2(-183.6, -15.6), 3.0), ground(Vector2(-183.6, -15.6), 1.0), 66.0)
	# The gouges face world +Z, so the camera has to be on that side of the trunk.
	await free_shot("q1_claws", eye_over(Vector2(-181.3, -13.9), Vector2(-181.6, -17.2), 1.8), ground(Vector2(-181.6, -17.2), 1.45), 42.0)
	ok("the clawed tree is there", await use("ClawedTree"))
	ok("both pieces of evidence clear the step", qs.objective_done("q_lost_goat", "investigate"))

	# The ambush.
	var here := Vector3(-189.0, game.world.map.height_at(-189.0, -23.0), -23.0)
	await until(func(): return _enemies_near(here, 45.0) >= 3, 4.0)
	var spawned := _enemies_near(here, 45.0)
	ok("an ambush was put in the world", spawned >= 3, "%d enemies within 45 m" % spawned)
	var killed := await _kill(4)
	ok("four rakshasas went down", killed >= 4, "%d killed" % killed)
	await until(func(): return qs.objective_done("q_lost_goat", "defeat"), 3.0)
	ok(
		"the kills counted",
		qs.objective_done("q_lost_goat", "defeat"),
		"%d/%d" % [qs.progress("q_lost_goat", "defeat"), qs.objective_total("q_lost_goat", "defeat")]
	)
	topup()

	# The escort.
	var pen := obj_node("BinduPen")
	ok("the pen only opens once the camp is quiet", pen != null and pen.call("can_interact", p))
	ok("Bindu is cut loose", await use("BinduPen"))
	var goat: Node3D = pen.get_node_or_null("Bindu") as Node3D
	ok("Bindu is following", goat != null and bool(goat.call("is_following")))

	# The bell out of the pack: the RETURN step must refuse without it.
	GameState.remove_item("goat_bell", 1)
	await teleport(Vector2(-120.0, 44.0))
	var arrived := await until(func(): return qs.objective_done("q_lost_goat", "bindu"), 6.0)
	ok("walking Bindu home clears the ESCORT step", arrived)
	ok(
		"Bindu arrived with the player",
		goat != null and goat.global_position.distance_to(p.global_position) < 30.0,
		"%.1f m away" % (goat.global_position.distance_to(p.global_position) if goat != null else -1.0)
	)
	ok("the RETURN step refuses while the bell is not carried", not qs.objective_done("q_lost_goat", "report"))
	ok("the escort's own reward was granted", GameState.has_item("healing_salve"))
	if goat != null:
		var gp := goat.global_position
		await free_shot("q1_bindu_home", gp + Vector3(3.4, 2.0, 3.4), gp + Vector3(0, 0.55, 0), 52.0)

	var gopa := _npc_pos("gopa")
	print(
		(
			"    gopa at %s, Rama at %s, %.1f m apart"
			% [str(gopa), str(p.global_position), p.global_position.distance_to(gopa) if gopa != Vector3.INF else -1.0]
		)
	)
	GameState.add_item("goat_bell", 1)
	await until(func(): return qs.is_complete("q_lost_goat"), 4.0)
	ok("carrying the bell back to Gopa closes the quest", qs.is_complete("q_lost_goat"), qs.state_of("q_lost_goat"))
	ok(
		"the reward was paid",
		GameState.item_count("arrow_bundle") >= 2 and GameState.arrows > 0,
		"arrows=%d bundles=%d" % [GameState.arrows, GameState.item_count("arrow_bundle")]
	)
	ok("the quest set its flag", bool(GameState.get_flag("forest_answered", false)))
	# The villagers' welcome: nearby people actually say something out loud.
	var welcomed := 0
	var welcome := String(QuestData.QUESTS["q_lost_goat"]["rewards"]["welcome"])
	for n in get_tree().get_nodes_in_group("npc"):
		var b: Variant = n.get("bark")
		if b != null and is_instance_valid(b) and String(b.get("text")) == welcome:
			welcomed += 1
	ok("Panchavati says something when you come back", welcomed >= 1, "%d villagers spoke" % welcomed)
	ok(
		"Q1 fired its steps in order",
		_order_ok(
			[
				"start:q_lost_goat",
				"obj:q_lost_goat/speak",
				"obj:q_lost_goat/travel",
				"obj:q_lost_goat/bell",
				"obj:q_lost_goat/investigate",
				"obj:q_lost_goat/defeat",
				"obj:q_lost_goat/bindu",
				"obj:q_lost_goat/report",
				"done:q_lost_goat"
			]
		),
		str(log_order)
	)


# ---------------------------------------------------------------------------
func _section_q2(qs: QuestSystem, _p: Player) -> void:
	print("\n-- Q2  The Forgotten Shrine --")
	ok("q_shrine has not started yet", qs.state_of("q_shrine") == Quest.STATE_NOT_STARTED)
	await teleport(Vector2(160.0, -70.0))
	await until(func(): return GameState.discovered.has("shrine"), 3.0)
	ok("arriving on the knoll discovers the shrine", GameState.discovered.has("shrine"))
	ok("the discovery opened the quest by itself", qs.is_active("q_shrine"), qs.state_of("q_shrine"))
	ok("the step for arriving is credited at once", qs.objective_done("q_shrine", "find"))

	# A conversation elsewhere in the world offers to close this quest. It must not.
	ok("a strict quest refuses a wholesale completion", not qs.complete_quest("q_shrine") and qs.is_active("q_shrine"))

	await teleport(Vector2(164.4, -76.6))
	ok("the inscription can be read", await use("Inscription"))
	ok("reading it clears the step", qs.objective_done("q_shrine", "inscription"))

	# The puzzle. The stone names sun, river, fig; the lamps wear those emblems.
	var puzzle: Node = game.interactables.lamp_puzzle
	# The puzzle has to be solvable from what the world shows: the stone names an
	# order, and each lamp says which one it is.
	var stone: Node3D = obj_node("Inscription")
	var carved := String(stone.get("body"))
	var at_a := carved.findn(String(QuestData.LAMP_EMBLEM_NAMES[QuestData.LAMP_ORDER[0]]))
	var at_b := carved.findn(String(QuestData.LAMP_EMBLEM_NAMES[QuestData.LAMP_ORDER[1]]))
	var at_c := carved.findn(String(QuestData.LAMP_EMBLEM_NAMES[QuestData.LAMP_ORDER[2]]))
	ok("the inscription names all three lamps", at_a >= 0 and at_b >= 0 and at_c >= 0, carved.replace("\n", " / "))
	ok("and names them in the order the puzzle wants", at_a < at_b and at_b < at_c, "positions %d, %d, %d" % [at_a, at_b, at_c])
	for emblem in QuestData.LAMP_ORDER:
		var lamp: Node3D = obj_node("Lamp_" + String(emblem))
		var prompt := String(lamp.call("interact_prompt"))
		ok("the %s lamp says which one it is" % emblem, prompt.findn(String(QuestData.LAMP_EMBLEM_NAMES[emblem])) >= 0, prompt)
	ok("lighting the river lamp first is refused", not puzzle.call("light", obj_node("Lamp_river")))
	await frames(2)
	ok("a wrong lamp leaves the step at zero", qs.progress("q_shrine", "lamps") == 0)
	ok("the sun lamp is accepted first", puzzle.call("light", obj_node("Lamp_sun")))
	await frames(2)
	ok("the fig lamp out of turn puts every flame out", not puzzle.call("light", obj_node("Lamp_fig")))
	await frames(2)
	ok("and the step goes back to zero", qs.progress("q_shrine", "lamps") == 0, "%d/3" % qs.progress("q_shrine", "lamps"))
	ok("no lamp is left burning after a reset", not _any_lamp_lit())
	for emblem in QuestData.LAMP_ORDER:
		ok("lamp of %s lights in turn" % emblem, puzzle.call("light", obj_node("Lamp_" + String(emblem))))
		await frames(2)
	ok("three lamps in the right order clear the step", qs.objective_done("q_shrine", "lamps"), "%d/3" % qs.progress("q_shrine", "lamps"))
	await free_shot(
		"q2_lamp_emblem", eye_over(Vector2(165.42, -79.50), Vector2(166.0, -80.6), 0.80), ground(Vector2(166.0, -80.6), 0.38), 30.0
	)
	await free_shot("q2_lamps_lit", eye_over(Vector2(170.9, -81.9), Vector2(166.4, -78.5), 2.3), ground(Vector2(166.3, -78.5), 1.0), 62.0)

	# The optional threshold lamp, which needs the traveller's oil.
	var tl := obj_node("ThresholdLamp")
	ok(
		"the threshold lamp refuses without oil",
		not GameState.has_item("lamp_oil") and String(tl.call("interact_prompt")).findn("oil") >= 0,
		String(tl.call("interact_prompt"))
	)
	GameState.add_item("lamp_oil", 1)
	await teleport(Vector2(163.2, -76.4))
	ok("with oil it lights", await use("ThresholdLamp"))
	ok("the optional step is recorded", qs.objective_done("q_shrine", "lamp"))
	ok("the optional step did not finish the quest", qs.is_active("q_shrine"))

	# The journal, mid-quest, with two quests in it.
	if game.hud != null:
		game.hud.open_panel(game.hud.journal)
		await frames(8)
		ok("the journal lists both quests", game.hud.journal.quest_count() >= 2, "%d quests" % game.hud.journal.quest_count())
		await shot("q2_journal_active")
		game.hud.close_all()
		await frames(4)

	# The bell, in the ruins, behind a gate.
	await teleport(Vector2(-160.0, -142.5))
	await frames(6)
	var gate := obj_node("RuinGate")
	ok("the gate is shut", gate != null and not bool(gate.get("open")))
	var before := get_tree().get_nodes_in_group("enemy").size()
	ok("the gate heaves open", await use("RuinGate"))
	await until(func(): return float(gate.get("_anim")) >= 1.0, 3.0)
	ok("the gate finished opening", float(gate.get("_anim")) >= 1.0, "%.2f" % float(gate.get("_anim")))
	await until(func(): return get_tree().get_nodes_in_group("enemy").size() > before, 3.0)
	ok(
		"something was keeping the bell company",
		get_tree().get_nodes_in_group("enemy").size() > before,
		"%d -> %d enemies" % [before, get_tree().get_nodes_in_group("enemy").size()]
	)
	await free_shot(
		"q2_ruin_gate", eye_over(Vector2(-150.4, -139.4), Vector2(-158.6, -143.9), 4.2), ground(Vector2(-159.4, -144.4), 1.7), 60.0
	)
	topup()

	await teleport(Vector2(-155.6, -144.2))
	ok("the bell can be taken", await use("BellPickup"))
	ok("taking it clears the COLLECT step", qs.objective_done("q_shrine", "bell"))
	ok("the pickup is gone from the world", not (obj_node("BellPickup") as Node3D).visible)
	topup()

	# Hang it and ring it.
	await teleport(Vector2(164.6, -76.6))
	var hp_before := GameState.max_health
	ok("the bell is hung", await use("BellFrame"))
	await until(func(): return qs.is_complete("q_shrine"), 3.0)
	ok("hanging and ringing the bell finishes the quest", qs.is_complete("q_shrine"), qs.state_of("q_shrine"))
	ok("the blessing raised max health", GameState.max_health > hp_before, "%.0f -> %.0f" % [hp_before, GameState.max_health])
	ok("the quest set its flag", bool(GameState.get_flag("blessing_of_the_bell", false)))
	await free_shot("q2_bell_hung", eye_over(Vector2(169.8, -71.4), Vector2(164.6, -74.4), 2.6), ground(Vector2(164.6, -74.4), 1.5), 52.0)


# ---------------------------------------------------------------------------
func _section_q3(qs: QuestSystem, _p: Player) -> void:
	print("\n-- Q3  Into the Wild --")
	ok("the shrine unlocked the prerequisite", qs.can_start("q_wild"))
	await teleport(Vector2(38.0, -186.0))
	await until(func(): return qs.is_active("q_wild"), 4.0)
	ok("standing at the falls opens the quest", qs.is_active("q_wild"), qs.state_of("q_wild"))
	ok("the falls are logged", qs.objective_done("q_wild", "falls"))
	var seeded: Dictionary = GameState.quests["q_wild"]["objectives"]
	ok("the grove is not listed yet", not seeded.has("grove"), str(seeded.keys()))
	ok("and it is not visible", not qs.objective_visible("q_wild", "grove"))

	await teleport(Vector2(96.0, -150.0))
	await until(func(): return qs.objective_done("q_wild", "lookout"), 3.0)
	ok("the lookout is logged", qs.objective_done("q_wild", "lookout"))
	await teleport(Vector2(214.0, 178.0))
	await until(func(): return qs.objective_done("q_wild", "badlands"), 3.0)
	ok("the badlands are logged", qs.objective_done("q_wild", "badlands"))
	ok(
		"three readings reveal the grove",
		qs.objective_visible("q_wild", "grove") and (GameState.quests["q_wild"]["objectives"] as Dictionary).has("grove"),
		str((GameState.quests["q_wild"]["objectives"] as Dictionary).keys())
	)

	await teleport(Vector2(-322.0, 112.0))
	await until(func(): return qs.is_complete("q_wild"), 4.0)
	ok("reaching the grove finishes the quest", qs.is_complete("q_wild"), qs.state_of("q_wild"))
	ok("the grove gave up its seed", GameState.has_item("grove_seed"))
	ok("the walk was worth a longer wind", GameState.max_stamina > 100.0, "%.0f stamina" % GameState.max_stamina)
	# Above the canopy: at head height the grove is a wall of ferns.
	await free_shot("q3_grove", eye_over(Vector2(-303.0, 99.0), Vector2(-322.0, 118.0), 24.0), ground(Vector2(-322.0, 118.0), 5.0), 62.0)
	await free_shot(
		"q3_grove_close", eye_over(Vector2(-316.4, 123.6), Vector2(-322.0, 118.0), 3.4), ground(Vector2(-322.0, 118.0), 1.5), 62.0
	)
	ok(
		"the grove is built where the quest says it is",
		(
			obj_node("GroveHeart") != null
			and (obj_node("GroveHeart").global_position.distance_to(Vector3(-322.0, obj_node("GroveHeart").global_position.y, 118.0)) < 1.0)
		)
	)
	ok("the grove keeps something worth the walk", obj_node("GroveGift") != null and (obj_node("GroveGift") as Node3D).visible)
	ok("and it can be taken", await use("GroveGift"))
	ok("the amulet is in the pack", GameState.has_item("amulet"))
	ok("the pickup left the world once taken", not (obj_node("GroveGift") as Node3D).visible)


# ---------------------------------------------------------------------------
func _section_marker(qs: QuestSystem, _p: Player) -> void:
	print("\n-- the objective marker --")
	await frames(4)
	ok("with nothing active there is no marker", not qs.marker_is_active())

	# Listen before anything moves: the signal fires when the marker appears, moves
	# or goes away, so a listener attached afterwards hears nothing and proves nothing.
	var seen := {"pos": Vector3.ZERO, "active": false, "n": 0}
	EventBus.objective_marker_changed.connect(
		func(pos: Vector3, a: bool):
			seen["pos"] = pos
			seen["active"] = a
			seen["n"] = int(seen["n"]) + 1
	)

	# Put a quest back into play and check the marker follows it.
	var keep := GameState.quests.duplicate(true)
	GameState.quests.erase("q_lost_goat")
	GameState.set_flag("saw_cart", false)
	GameState.set_flag("saw_claws", false)
	qs.start_quest("q_lost_goat")
	qs.notify_talk("gopa")
	await frames(6)
	var want := Vector2(-184.0, -14.0)
	ok(
		"the marker stands over the current step",
		qs.marker_is_active() and Vector2(qs.marker_position().x - want.x, qs.marker_position().z - want.y).length() < 1.5,
		"marker at %s" % str(qs.marker_position())
	)

	# Stand far enough off that the shaft is at full strength, then freeze the system
	# so the two frames below differ ONLY by whether the marker is drawn.
	await teleport(Vector2(-184.0, 24.0))
	await frames(20)
	ok(
		"the compass was told where to point",
		bool(seen["active"]) and Vector2(Vector3(seen["pos"]).x - want.x, Vector3(seen["pos"]).z - want.y).length() < 1.5,
		"%d emissions, last at %s" % [int(seen["n"]), str(seen["pos"])]
	)
	var at := qs.marker_position()
	var eye := at + Vector3(26.0, 6.0, 26.0)
	var aim := at + Vector3(0, 13.0, 0)
	var marker: Node3D = qs.get("_marker")
	ok("the marker node exists and is shown", marker != null and marker.visible)
	qs.process_mode = Node.PROCESS_MODE_DISABLED
	await frames(2)
	# Stop the clock for the pair. Freezing only the quest system was not enough: the
	# wind in the foliage shaders, walking NPCs and the HUD's notification toasts all
	# moved between the two frames, and whichever moved most became the "peak column"
	# (x=801, 1243, 1335, 1383 of 1600 across four runs on 2026-11-13). time_scale 0
	# also stops shader TIME and particles: main.cpp hands the renderer the scaled step.
	var was_scale := Engine.time_scale
	Engine.time_scale = 0.0
	marker.visible = true
	await free_shot("marker_on", eye, aim, 58.0)
	marker.visible = false
	await free_shot("marker_off", eye, aim, 58.0)
	Engine.time_scale = was_scale
	marker.visible = true
	qs.process_mode = Node.PROCESS_MODE_INHERIT
	var ab := _column_diff("marker_on", "marker_off")
	print("    marker column diff: peak %.4f at x=%d, median %.4f, ratio %.1f" % [ab["peak"], int(ab["peak_x"]), ab["median"], ab["ratio"]])
	ok("the shaft actually reached the screen", ab["ratio"] >= 4.0, "peak column is %.1fx the median column (needs 4.0x)" % ab["ratio"])
	ok(
		"and it stands where the marker stands",
		absf(float(ab["peak_x"]) - float(ab["width"]) * 0.5) < float(ab["width"]) * 0.22,
		"peak at x=%d of %d" % [int(ab["peak_x"]), int(ab["width"])]
	)

	# It fades out as you arrive, so it never stands inside the thing it points at.
	var far_alpha := _marker_alpha(qs)
	await teleport(Vector2(-185.0, -12.0))
	await frames(20)
	var near_alpha := _marker_alpha(qs)
	ok("the marker fades out as you arrive", near_alpha < far_alpha * 0.35, "alpha %.3f at 38 m, %.3f at 2 m" % [far_alpha, near_alpha])

	# Put the world back.
	GameState.quests = keep
	qs.load_from(GameState)
	await frames(6)
	ok("the marker went away with the quest", not qs.marker_is_active())
	ok("and the compass was told to clear it", not bool(seen["active"]), "%d emissions in all" % int(seen["n"]))


func _marker_alpha(qs: QuestSystem) -> float:
	var mat: StandardMaterial3D = qs.get("_marker_mat")
	return mat.albedo_color.a if mat != null else -1.0


## Sum the absolute difference between two frames column by column. A shaft of light
## is a narrow vertical thing, so it shows up as one column far above the median —
## which is a claim that survives grass moving in the wind between the two frames,
## and which a warm-pixel count does not: the first version of this check passed on
## a frame that was nothing but sunlit sandstone.
func _column_diff(a_name: String, b_name: String) -> Dictionary:
	var a := Image.load_from_file(ProjectSettings.globalize_path(OUT % a_name))
	var b := Image.load_from_file(ProjectSettings.globalize_path(OUT % b_name))
	if a == null or b == null or a.get_size() != b.get_size():
		return {"peak": 0.0, "peak_x": 0, "median": 1.0, "ratio": 0.0, "width": 1}
	var w := a.get_width()
	var h := a.get_height()
	var cols := PackedFloat32Array()
	cols.resize(w)
	for x in range(w):
		var acc := 0.0
		for y in range(0, h, 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			acc += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
		cols[x] = acc / float(h / 2)
	var sorted := Array(cols)
	sorted.sort()
	var median: float = float(sorted[sorted.size() / 2])
	var peak := 0.0
	var peak_x := 0
	for x in range(w):
		if cols[x] > peak:
			peak = cols[x]
			peak_x = x
	return {"peak": peak, "peak_x": peak_x, "median": median, "ratio": peak / maxf(median, 0.0004), "width": w}


# ---------------------------------------------------------------------------
func _section_persistence(qs: QuestSystem) -> void:
	print("\n-- save and load --")
	var snapshot := GameState.quests.duplicate(true)
	var disc := GameState.discovered.duplicate(true)
	var inv := GameState.inventory.duplicate(true)
	var mh := GameState.max_health
	ok("the game saves", game.save_game(5))
	GameState.reset()
	await frames(4)
	ok("the reset really cleared the log", GameState.quests.is_empty())
	ok("the game loads", game.load_game(5))
	await frames(8)
	ok("every quest came back", GameState.quests.size() == snapshot.size(), "%d of %d" % [GameState.quests.size(), snapshot.size()])
	var identical := true
	var diff := ""
	for qid in snapshot:
		var a: Dictionary = snapshot[qid]
		var b: Dictionary = GameState.quests.get(qid, {})
		if String(a.get("state", "")) != String(b.get("state", "")):
			identical = false
			diff = "%s state %s vs %s" % [qid, a.get("state"), b.get("state")]
			break
		var ao: Dictionary = a.get("objectives", {})
		var bo: Dictionary = b.get("objectives", {})
		if ao.size() != bo.size():
			identical = false
			diff = "%s has %d steps, loaded %d" % [qid, ao.size(), bo.size()]
			break
		for oid in ao:
			if int(ao[oid]) != int(bo.get(oid, -1)):
				identical = false
				diff = "%s/%s %d vs %d" % [qid, oid, int(ao[oid]), int(bo.get(oid, -1))]
				break
	ok("the quest log round-trips byte for byte", identical, diff)
	ok("discoveries round-trip", GameState.discovered.size() == disc.size(), "%d of %d" % [GameState.discovered.size(), disc.size()])
	ok("the inventory round-trips", GameState.inventory.size() == inv.size(), "%d of %d" % [GameState.inventory.size(), inv.size()])
	ok("the blessing survived the load", is_equal_approx(GameState.max_health, mh), "%.0f vs %.0f" % [GameState.max_health, mh])
	ok("a completed quest cannot restart", not qs.start_quest("q_shrine") and qs.is_complete("q_shrine"))
	var lamps_before := qs.progress("q_shrine", "lamps")
	qs.advance_quest("q_shrine", "lamps", 1)
	ok("a completed quest cannot be advanced", qs.is_complete("q_shrine") and qs.progress("q_shrine", "lamps") == lamps_before)
	# The world objects came back the way the log says.
	ok("the bell is still hanging in its frame", bool((obj_node("BellFrame") as Node).get("hung")))
	ok("the lamps are still lit after the load", _lit_lamp_count() == 3, "%d of 3 lit" % _lit_lamp_count())
	ok("the taken pickup is still gone", not (obj_node("BellPickup") as Node3D).visible)
	ok("the ruin gate is still open", bool((obj_node("RuinGate") as Node).get("open")))


# ---------------------------------------------------------------------------
func _section_failure(qs: QuestSystem) -> void:
	print("\n-- the failure state --")
	GameState.reset()
	await frames(2)
	ok("a fresh quest starts", qs.start_quest("q_lost_goat"))
	qs.notify_talk("gopa")
	await frames(3)
	ok("it took progress before failing", qs.objective_done("q_lost_goat", "speak"))
	# Snapshot before failing. The load in the previous section puts Rama back where
	# he was saved, which is 2 m from the forest objective, so the position poll can
	# legitimately clear a step between here and the assertion below; comparing
	# against a hard 0 made this section flake once in nine runs.
	var frozen := {}
	for oid in QuestData.quest("q_lost_goat").objective_ids():
		frozen[oid] = qs.progress("q_lost_goat", String(oid))
	ok("it can be failed", qs.fail_quest("q_lost_goat"))
	ok("the state is failed", qs.state_of("q_lost_goat") == Quest.STATE_FAILED, qs.state_of("q_lost_goat"))
	ok("a failed quest is not active", not qs.is_active("q_lost_goat"))
	ok("a failed quest cannot restart", not qs.start_quest("q_lost_goat"))
	ok("a failed quest cannot be failed twice", not qs.fail_quest("q_lost_goat"))
	for oid in frozen:
		qs.advance_quest("q_lost_goat", String(oid), 1)
	qs.notify_interact("forest_evidence")
	qs.notify_talk("gopa")
	await frames(20)
	var moved: Array = []
	for oid in frozen:
		if qs.progress("q_lost_goat", String(oid)) != int(frozen[oid]):
			moved.append(String(oid))
	ok("a failed quest takes no more progress, from any source", moved.is_empty(), "moved: " + str(moved))
	ok("the failed state survives a save and a load", game.save_game(6) and _reload_state(6) == Quest.STATE_FAILED)


# ---------------------------------------------------------------------------
## The seam the whole quest layer hangs off in normal play: a real conversation with
## a real villager, whose action strings reach this system. Every other section
## calls `notify_talk` directly, which would keep passing if the dialogue hook were
## wired to nothing at all.
func _section_dialogue(qs: QuestSystem, p: Player) -> void:
	print("\n-- the conversation that starts it --")
	GameState.reset()
	await frames(4)
	game.world.sky.set_time(11.0)
	var gopa: Node3D = null
	if game.npcs != null and game.npcs.has_method("get_npc"):
		gopa = game.npcs.call("get_npc", "gopa") as Node3D
	ok("Gopa is in the world", gopa != null)
	if gopa == null:
		return
	if gopa.has_method("set_active"):
		gopa.call("set_active", true)
	if gopa.has_method("snap_to_schedule"):
		gopa.call("snap_to_schedule")
	await frames(6)

	var gp := gopa.global_position
	var stand := Vector2(gp.x + 1.5, gp.z + 1.5)
	var yaw: float = atan2(-(gp.x - stand.x), -(gp.z - stand.y))
	await teleport(stand, yaw)
	var reached := await until(func(): return p.current_interactable() == gopa, 3.0)
	ok("Rama's interact target is Gopa", reached, "target is %s" % (str(p.current_interactable())))

	gopa.call("interact", p)
	await frames(6)
	var ds := DialogueSystem.get_instance()
	ok("a conversation opened", ds != null and ds.is_active())
	if ds == null:
		return

	# Walk the tree toward the line where Gopa asks for help, choosing by what the
	# option says rather than by an index, so re-authoring the conversation does not
	# quietly turn this into a test of nothing.
	var steps := 0
	while ds.is_active() and steps < 20:
		steps += 1
		var labels: Array = ds.choice_labels()
		if labels.is_empty():
			ds.advance()
		else:
			var pick := 0
			for i in range(labels.size()):
				var t := String(labels[i]).to_lower()
				if (
					t.findn("look for them") >= 0
					or t.findn("i will find it") >= 0
					or t.findn("troubling") >= 0
					or t.findn("where did you") >= 0
				):
					pick = i
					break
			ds.choose(pick)
		await frames(3)
	ok("the conversation ran to its end", not ds.is_active(), "%d steps" % steps)
	ok("the dialogue action started the quest through this system", qs.is_active("q_lost_goat"), qs.state_of("q_lost_goat"))
	ok(
		"ending the conversation cleared the TALK_TO step",
		qs.objective_done("q_lost_goat", "speak"),
		"%d/1" % qs.progress("q_lost_goat", "speak")
	)
	ok(
		"the conversation can read the quest state back",
		ds.check("quest:q_lost_goat:active") and not ds.check("quest:q_lost_goat:complete")
	)

	# The hermit's conversation offers to close the shrine quest outright. It must
	# not be able to, because the shrine is not a thing you can be told you have
	# put right.
	ok("q_shrine can be started for the strict check", qs.start_quest("q_shrine"))
	ds.act("quest_complete:q_shrine")
	await frames(3)
	ok("a dialogue action cannot close a strict quest early", qs.is_active("q_shrine"), qs.state_of("q_shrine"))
	ds.act("quest_advance:q_shrine:lamp:1")
	await frames(3)
	ok("but a dialogue action can advance one of its steps", qs.objective_done("q_shrine", "lamp"))


# ---------------------------------------------------------------------------
func _section_kandas(qs: QuestSystem, _p: Player) -> void:
	print("\n-- The Five Kandas of Rama's Life --")
	GameState.reset()
	await frames(4)

	# 1. Bala Kanda
	ok("q_bala_kanda starts", qs.start_quest("q_bala_kanda"))
	qs.notify_talk("vishvamitra")
	await frames(3)
	ok("Vishvamitra counsel completes", qs.objective_done("q_bala_kanda", "counsel"))
	ok("Shiva Dhanush monument exists and can be strung", await use("ShivaDhanush"))
	ok("Pinaka objective completes", qs.objective_done("q_bala_kanda", "pinaka"))
	await teleport(Vector2(-172.0, 12.0))
	await frames(10)
	await _kill(3)
	await until(func(): return qs.is_complete("q_bala_kanda"), 4.0)
	ok("Bala Kanda completes", qs.is_complete("q_bala_kanda") and bool(GameState.get_flag("kanda_bala_done", false)))

	# 2. Ayodhya Kanda
	ok("q_ayodhya_kanda starts", qs.start_quest("q_ayodhya_kanda"))
	qs.notify_talk("kevat")
	await frames(3)
	ok("Guha/Kevat river talk completes", qs.objective_done("q_ayodhya_kanda", "guha"))
	ok("Chitrakoot Paduka altar exists and can be consecrated", await use("ChitrakootPaduka"))
	ok("Paduka objective completes", qs.objective_done("q_ayodhya_kanda", "paduka"))
	qs.notify_talk("bharata")
	await until(func(): return qs.is_complete("q_ayodhya_kanda"), 3.0)
	ok("Ayodhya Kanda completes", qs.is_complete("q_ayodhya_kanda") and GameState.has_item("rama_paduka"))

	# 3. Aranya Kanda
	ok("q_aranya_kanda starts", qs.start_quest("q_aranya_kanda"))
	qs.notify_talk("sita")
	await frames(3)
	ok("Sita Parnashala talk completes", qs.objective_done("q_aranya_kanda", "parnashala"))
	ok("Maricha's Golden Deer exists and can be unmasked", await use("GoldenDeer"))
	ok("Mayamrig objective completes", qs.objective_done("q_aranya_kanda", "mayamrig"))
	await teleport(Vector2(-208.0, 18.0))
	await frames(10)
	await _kill(4)
	await until(func(): return qs.objective_done("q_aranya_kanda", "khara"), 4.0)
	ok("Jatayu Memorial exists and can be blessed", await use("JatayuMemorial"))
	await until(func(): return qs.is_complete("q_aranya_kanda"), 3.0)
	ok(
		"Aranya Kanda completes and grants Akshaya Tunira",
		qs.is_complete("q_aranya_kanda") and bool(GameState.get_flag("akshaya_tunira", false))
	)

	# 4. Kishkindha & Sundara Kanda
	ok("q_kishkindha_kanda starts", qs.start_quest("q_kishkindha_kanda"))
	qs.notify_talk("hanuman")
	await frames(3)
	ok("Hanuman alliance talk completes", qs.objective_done("q_kishkindha_kanda", "meet_hanuman"))
	ok("Sapta Tala (Seven Sala Trees) trial exists and can be pierced", await use("SaptaTalaTrial"))
	ok("Sapta Tala objective completes", qs.objective_done("q_kishkindha_kanda", "sapta_tala"))
	await teleport(Vector2(-290.0, 96.0))
	await frames(10)
	await _kill(3)
	await until(func(): return qs.is_complete("q_kishkindha_kanda"), 4.0)
	ok("Kishkindha Kanda completes and grants Sita's Chudamani", qs.is_complete("q_kishkindha_kanda") and GameState.has_item("chudamani"))

	# 5. Yuddha Kanda
	ok("q_yuddha_kanda starts", qs.start_quest("q_yuddha_kanda"))
	qs.notify_talk("agastya")
	await frames(3)
	ok("Agastya counsel completes", qs.objective_done("q_yuddha_kanda", "agastya"))
	ok("Aditya Hridayam Surya Altar exists and can be chanted at", await use("SuryaAltar"))
	ok("Aditya Hridayam objective completes", qs.objective_done("q_yuddha_kanda", "aditya"))
	ok("Rama Setu floating stones exist and can be inscribed", await use("RamaSetuStone"))
	ok("Rama Setu objective completes", qs.objective_done("q_yuddha_kanda", "setu"))
	await teleport(WorldMap.P_BADLANDS)
	await frames(10)
	await _kill(4)
	await until(func(): return qs.is_complete("q_yuddha_kanda"), 4.0)
	ok("Yuddha Kanda completes and establishes Rama Rajya", qs.is_complete("q_yuddha_kanda") and bool(GameState.get_flag("rama_rajya", false)))


func _reload_state(slot: int) -> String:
	GameState.reset()
	GameState.load_from_slot(slot)
	var raw: Variant = GameState.quests.get("q_lost_goat", {})
	return String((raw as Dictionary).get("state", "none"))


# ===========================================================================
#  helpers
# ===========================================================================
func _npc_pos(npc_id: String) -> Vector3:
	for n in get_tree().get_nodes_in_group("npc"):
		if is_instance_valid(n) and n is Node3D and String(n.get("id")) == npc_id:
			return (n as Node3D).global_position
	return Vector3.INF


func _enemies_near(at: Vector3, r: float) -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(e) and (e as Node3D).global_position.distance_to(at) < r:
			n += 1
	return n


func _kill(count: int) -> int:
	var killed := 0
	var guard := 0
	while killed < count and guard < 240:
		guard += 1
		topup()
		var live: Node = null
		for e in get_tree().get_nodes_in_group("enemy"):
			if (
				is_instance_valid(e)
				and bool(e.call("is_alive"))
				and (e as Node3D).global_position.distance_to(game.player.global_position) < 70.0
			):
				live = e
				break
		if live == null:
			await get_tree().physics_frame
			continue
		live.call("take_damage", 400.0, game.player, (live as Node3D).global_position + Vector3(0, 1.4, 0), true)
		await get_tree().physics_frame
		if not is_instance_valid(live) or not bool(live.call("is_alive")):
			killed += 1
	topup()
	return killed


func _any_lamp_lit() -> bool:
	return _lit_lamp_count() > 0


func _lit_lamp_count() -> int:
	var n := 0
	for e in QuestData.LAMP_ORDER:
		var l := obj_node("Lamp_" + String(e))
		if l != null and bool(l.get("lit")):
			n += 1
	return n


## Does `log_order` contain these entries, in this order, with anything between?
func _order_ok(want: Array) -> bool:
	var i := 0
	for entry in log_order:
		if i < want.size() and entry == String(want[i]):
			i += 1
	return i == want.size()


func shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		fails.append("screenshot %s came back null" % name)
		return
	var path: String = OUT % name
	if img.save_png(path) != OK:
		fails.append("could not write " + path)
		return
	shots += 1
	var lo := Vector3(2, 2, 2)
	var hi := Vector3(-1, -1, -1)
	for y in range(0, img.get_height(), 7):
		for x in range(0, img.get_width(), 7):
			var c := img.get_pixel(x, y)
			var v := Vector3(c.r, c.g, c.b)
			lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
			hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
	var spread: float = (hi - lo).length()
	ok("screenshot %s is a real frame" % name, spread >= 0.08, "spread %.3f" % spread)


func _finish() -> void:
	# A paused tree stops discovery, position objectives and ambush spawns (all in
	# QuestSystem._process) while this suite keeps stepping on physics_frame. The
	# 2026-11-13 audit's six quest failures in a windowed run are reproduced exactly by
	# pausing the tree; say so instead of reporting six unrelated-looking failures.
	if get_tree().paused:
		fails.append(
			"the game was paused during the run, so quest progress could not happen"
			+ " (did a pause, inventory or journal key reach the window?)"
		)
	print("\nRESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)
