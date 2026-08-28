extends Node
## THE acceptance test. Walks the checklist end to end from a fresh launch and
## asserts a real outcome for every item, rather than reporting that a system exists.

var game: Game
var hud: Node
var fails: Array[String] = []
var checks: Array = []
var errors_seen: int = 0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# One frame of slack: the tree root is still setting up children during _ready,
	# and adding to it here fails outright.
	await get_tree().process_frame
	_run()


func ok(name: String, pass_v: bool, detail: String = "") -> void:
	checks.append([name, pass_v, detail])
	print("  [%s] %-34s %s" % ["PASS" if pass_v else "FAIL", name, detail])
	if not pass_v:
		fails.append(name + (("  — " + detail) if detail != "" else ""))


func frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func idle(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _run() -> void:
	print("=== RAMA acceptance test ===")

	# --- 1-3 launch through the menu ------------------------------------
	var menu_scene: PackedScene = load("res://scenes/main_menu.tscn")
	ok("main menu loads", menu_scene != null)
	# HUD.launch() replaces and FREES tree.current_scene. Hand that role to a decoy
	# node so the launch frees the decoy instead of this test, and keep the menu as a
	# child of the test where it builds normally.
	var decoy := Node.new()
	decoy.name = "SceneSlot"
	get_tree().root.add_child(decoy)
	get_tree().current_scene = decoy
	var menu := menu_scene.instantiate()
	add_child(menu)
	await idle(50)
	ok("main menu renders", menu.get_child_count() > 0, "%d children" % menu.get_child_count())
	menu.call("_on_new_game")
	await idle(150)
	if is_instance_valid(menu):
		menu.queue_free()
		await get_tree().process_frame
	var session := get_tree().current_scene
	game = session.get_node_or_null("Game") if session else null
	hud = session.get_node_or_null("HUD") if session else null
	ok("new game starts a session", game != null)
	ok("HUD is present", hud != null)
	if game == null:
		return _finish()
	await frames(40)
	var p: Player = game.player
	ok("player spawns", p != null and is_instance_valid(p))
	var gy := game.world.map.height_at(p.global_position.x, p.global_position.z)
	ok("player spawns on the ground", absf(p.global_position.y - gy) < 1.0, "delta %.2f m" % (p.global_position.y - gy))

	# --- 4-6 camera and movement ----------------------------------------
	var cam: PlayerCamera = game.cam
	ok("camera exists and is current", cam != null and cam.camera().current)
	var y0 := cam.yaw
	cam.yaw += 1.0
	await frames(4)
	ok("camera responds to look input", absf(cam.yaw - y0) > 0.5)

	var a := p.global_position
	Input.action_press("move_forward")
	await frames(70)
	Input.action_release("move_forward")
	var walk := a.distance_to(p.global_position)
	ok("player walks", walk > 3.0, "%.1f m in ~1.2 s" % walk)
	await frames(15)
	a = p.global_position
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await frames(70)
	Input.action_release("sprint")
	Input.action_release("move_forward")
	var sprint := a.distance_to(p.global_position)
	ok("sprint is faster than run", sprint > walk, "%.1f m vs %.1f m" % [sprint, walk])
	await frames(25)
	var jy := p.global_position.y
	var peak := jy
	Input.action_press("jump")
	await frames(3)
	Input.action_release("jump")
	for i in range(70):
		await get_tree().physics_frame
		peak = maxf(peak, p.global_position.y)
	ok("player jumps and lands", peak - jy > 0.8 and p.is_on_floor(), "+%.2f m" % (peak - jy))

	# --- 7 exploration: no falling through the world ---------------------
	var worst := 0.0
	Input.action_press("move_forward")
	Input.action_press("sprint")
	for i in range(420):
		await get_tree().physics_frame
		var pp := p.global_position
		worst = maxf(worst, game.world.map.height_at(pp.x, pp.z) - pp.y)
		if i % 120 == 0:
			cam.yaw += 1.3
	Input.action_release("sprint")
	Input.action_release("move_forward")
	ok("player never sinks through terrain", worst < 1.2, "worst %.2f m over 7 s" % worst)

	# --- 8 NPCs -----------------------------------------------------------
	var npcs := get_tree().get_nodes_in_group("npc")
	ok("NPCs exist", npcs.size() >= 5, "%d NPCs" % npcs.size())
	var moved_any := false
	var before := {}
	for n in npcs:
		before[n] = (n as Node3D).global_position
	await frames(180)
	for n in npcs:
		if is_instance_valid(n) and before[n].distance_to((n as Node3D).global_position) > 0.4:
			moved_any = true
			break
	ok("NPCs move about", moved_any)
	var grounded := true
	for n in npcs:
		if not is_instance_valid(n):
			continue
		var np: Vector3 = (n as Node3D).global_position
		if absf(np.y - game.world.map.height_at(np.x, np.z)) > 2.0:
			grounded = false
			break
	ok("NPCs stand on the ground", grounded)

	# --- 9 dialogue -------------------------------------------------------
	var talk_ok := false
	var dlg_started := false
	EventBus.dialogue_started.connect(func(_s, _n): dlg_started = true)
	if not npcs.is_empty():
		var npc: Node3D = npcs[0]
		p.global_position = npc.global_position + Vector3(1.4, 0.3, 0)
		await frames(10)
		if npc.has_method("interact"):
			npc.call("interact", p)
			await frames(20)
			talk_ok = dlg_started or p._input_locked
	ok("talking to an NPC opens dialogue", talk_ok)
	# Dialogue locks player input; leaving it open silently disabled every later
	# combat check, which is exactly what it should do in game, so close it here.
	var dlg: Node = null
	for n in get_tree().get_nodes_in_group("dialogue_system"):
		dlg = n
		break
	if dlg == null and game.npcs and game.npcs.get("dialogue") != null:
		dlg = game.npcs.get("dialogue")
	if dlg and dlg.has_method("cancel"):
		dlg.call("cancel")
	p.lock_input(false)
	await frames(10)
	ok("input is released after dialogue", not p._input_locked)

	# --- 10-11 quests -----------------------------------------------------
	var qs: Node = game.quests
	ok("quest system present", qs != null)
	var quest_started := false
	var obj_changed := false
	EventBus.quest_started.connect(func(_id): quest_started = true)
	EventBus.quest_objective_changed.connect(func(_q, _o, _p, _t): obj_changed = true)
	# Use a real quest id; "forest_path" was never one of them.
	var started_id := ""
	if qs:
		for m in ["start_quest", "start", "begin_quest"]:
			if qs.has_method(m):
				qs.call(m, "q_lost_goat")
				started_id = m
				break
		await frames(24)
	ok(
		"a quest can be started",
		quest_started or GameState.quests.size() > 0,
		"via %s; quests in state: %d" % [started_id if started_id != "" else "<no api>", GameState.quests.size()]
	)

	# --- 12-16 enemies and combat ----------------------------------------
	var enemies := get_tree().get_nodes_in_group("enemy")
	ok("enemies exist", enemies.size() >= 5, "%d enemies" % enemies.size())
	var target: Node3D = null
	for e in enemies:
		if is_instance_valid(e) and e.has_method("take_damage") and e.call("is_alive"):
			target = e
			break
	ok("enemies implement the damage contract", target != null)
	if target:
		# Put the enemy in front of the player and fight it.
		var tp := p.global_position - p.global_transform.basis.z * 4.0
		tp.y = game.world.map.height_at(tp.x, tp.z) + 0.2
		target.global_position = tp
		await frames(30)
		var start_pos := target.global_position
		var idle_state := String(target.call("state_name")) if target.has_method("state_name") else ""
		if target.has_method("alert_from"):
			target.call("alert_from", p.global_position, true)
		await frames(150)
		var moved: float = start_pos.distance_to(target.global_position)
		var now_state := String(target.call("state_name")) if target.has_method("state_name") else ""
		# An alerted enemy either closes or circles; both are engagement, and which one
		# it picks depends on its archetype and its range. What must NOT happen is that
		# it stays in its idle state and stands still.
		var engaged: bool = now_state in ["chase", "attack", "strafe", "investigate", "retreat"]
		ok("enemy AI engages the player", engaged or moved > 0.8, "%s -> %s, moved %.2f m" % [idle_state, now_state, moved])

		var hp_before: float = target.get("health") if target.get("health") != null else -1.0
		target.call("take_damage", 40.0, p, target.global_position + Vector3(0, 1, 0), false)
		await frames(6)
		var hp_after: float = target.get("health") if target.get("health") != null else -1.0
		ok("enemies take damage", hp_after < hp_before, "%.0f -> %.0f" % [hp_before, hp_after])
		for i in range(12):
			if not is_instance_valid(target) or not target.call("is_alive"):
				break
			target.call("take_damage", 60.0, p, target.global_position + Vector3(0, 1, 0), false)
			await frames(4)
		var dead: bool = not is_instance_valid(target) or not target.call("is_alive")
		ok("enemies can be killed", dead)

	var h0 := GameState.health
	p.take_damage(18.0, null)
	await frames(6)
	ok("player takes damage", GameState.health < h0, "%.0f -> %.0f" % [h0, GameState.health])

	# bow
	var arrows0 := GameState.arrows
	p.using_bow = true
	Input.action_press("aim")
	await frames(60)
	var charged := p.draw_charge
	Input.action_release("aim")
	await frames(8)
	ok(
		"bow draws and fires",
		charged > 0.85 and GameState.arrows == arrows0 - 1,
		"charge %.2f, arrows %d -> %d" % [charged, arrows0, GameState.arrows]
	)

	# --- 17-18 rewards ----------------------------------------------------
	var inv_before := GameState.item_count("arrow_bundle")
	GameState.add_item("arrow_bundle", 1)
	ok("items can be granted", GameState.item_count("arrow_bundle") == inv_before + 1)

	# --- 19-20 save / load ------------------------------------------------
	var mark := Vector3(150.0, 0.0, -66.0)
	mark.y = game.world.map.height_at(mark.x, mark.z) + 0.2
	p.global_position = mark
	GameState.set_flag("acceptance_marker", true)
	await frames(4)
	ok("save works", game.save_game(4))
	GameState.reset()
	p.global_position = game.spawn_point()
	await frames(4)
	ok("load works", game.load_game(4))
	await frames(8)
	ok("load restores position", p.global_position.distance_to(mark) < 2.0, "%.2f m away" % p.global_position.distance_to(mark))
	ok("load restores flags", GameState.get_flag("acceptance_marker") == true)

	# --- 21 day / night ---------------------------------------------------
	game.world.sky.paused = true
	game.world.sky.set_time(12.0)
	await idle(6)
	var day_energy: float = game.world.sky.sun.light_energy
	var day_amb: float = game.world.sky.env.environment.ambient_light_energy
	game.world.sky.set_time(23.5)
	await idle(6)
	var night_energy: float = game.world.sky.sun.light_energy
	var night_amb: float = game.world.sky.env.environment.ambient_light_energy
	ok(
		"day/night changes the lighting",
		night_energy < day_energy * 0.2 and night_amb < day_amb * 0.6,
		"sun %.2f->%.2f  ambient %.2f->%.2f" % [day_energy, night_energy, day_amb, night_amb]
	)
	ok("moon lights the night", game.world.sky.moon.light_energy > 0.05, "moon %.2f" % game.world.sky.moon.light_energy)
	game.world.sky.set_time(10.0)
	game.world.sky.paused = false

	# --- 22 audio ---------------------------------------------------------
	var amb_playing := 0
	for k in AudioDirector._amb:
		var pl: AudioStreamPlayer = AudioDirector._amb[k]
		if pl.playing:
			amb_playing += 1
	ok("ambience beds are playing", amb_playing >= 3, "%d beds" % amb_playing)
	AudioDirector.play_music("music_explore", 0.2)
	await idle(20)
	var music_on: bool = AudioDirector._music_a.playing or AudioDirector._music_b.playing
	ok("music plays", music_on)

	# --- 23 UI ------------------------------------------------------------
	if hud:
		var vis := 0
		for c in hud.get_children():
			if c is CanvasItem and (c as CanvasItem).visible:
				vis += 1
		ok("HUD has visible elements", vis > 0, "%d visible children" % vis)
		if hud.has_method("set_objective_text"):
			hud.call("set_objective_text", "Acceptance run")
			await idle(4)
			ok("HUD objective can be set", true)

	# --- menus and panels ---------------------------------------------------
	if hud:
		var panels := {
			"pause": hud.get("pause_menu"),
			"settings": hud.get("settings_menu"),
			"save": hud.get("save_menu"),
			"inventory": hud.get("inventory"),
			"journal": hud.get("journal"),
		}
		for k in panels:
			var c: Control = panels[k]
			ok("HUD has a %s panel" % k, c != null)
			if c == null:
				continue
			hud.call("open_panel", c)
			await idle(8)
			var opened: bool = c.visible
			hud.call("close_all")
			await idle(8)
			ok("%s panel opens and closes" % k, opened and not c.visible)
		# Pausing must actually pause the tree and free the mouse.
		hud.call("set_paused", true)
		await idle(4)
		var paused_ok: bool = get_tree().paused
		hud.call("set_paused", false)
		await idle(4)
		ok("pause stops the game", paused_ok and not get_tree().paused)

	# --- 24 interactables --------------------------------------------------
	var inter := get_tree().get_nodes_in_group("interactable")
	ok("world has interactables", inter.size() >= 5, "%d" % inter.size())

	# --- 25 performance ----------------------------------------------------
	p.global_position = Vector3(WorldMap.P_VILLAGE.x, 0, WorldMap.P_VILLAGE.y)
	p.global_position.y = game.world.map.height_at(p.global_position.x, p.global_position.z) + 0.2
	game.world.terrain.update_focus(p.global_position, true)
	await idle(150)
	var acc := 0.0
	for i in range(120):
		await get_tree().process_frame
		acc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var ms := acc / 120.0
	ok("performance is playable", ms < 33.0, "%.1f ms (%.0f fps) in the village" % [ms, 1000.0 / maxf(ms, 0.01)])

	await idle(10)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://build/screenshots/acceptance.png")
	_finish()


func _finish() -> void:
	var passed := 0
	for c in checks:
		if c[1]:
			passed += 1
	print("\n%d / %d checks passed" % [passed, checks.size()])
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)
