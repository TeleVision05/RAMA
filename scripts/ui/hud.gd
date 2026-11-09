class_name HUD
extends CanvasLayer
## Everything the player sees that is not the world.
##
## The HUD is the single owner of interface state: it draws the diegetic layer
## (bars, crosshair, compass, objective, prompts, notifications, damage) and it owns
## the menu stack on top of that, because exactly one thing has to decide whether the
## mouse is captured, whether the tree is paused and whether the player has input.
##
## Restraint is the design: at full health, out of combat, with nothing to interact
## with, almost nothing is on screen.

const HUD_LAYER := 10
const QUICK_SLOT := 0

var game: Node = null
var player: Node = null
var cam_rig: Node = null

var _root: Control
var _menus: Control
var bars: StatBars
var crosshair: Crosshair
var ammo: AmmoReadout
var objective: ObjectiveLine
var prompt: InteractPrompt
var vignette: DamageVignette
var compass: Compass
var notes: Notifications
var combat_overlay: CombatOverlay
var death: DeathOverlay

var pause_menu: PauseMenu
var settings_menu: SettingsMenu
var save_menu: SaveMenu
var inventory: InventoryPanel
var journal: JournalPanel

var _stack: Array[Control] = []
var _dialogue: bool = false
var _dead: bool = false
var _hud_alpha: float = 1.0
var _objective_quest: String = ""
var _objective_id: String = ""


# ==========================================================================
# boot
# ==========================================================================
func _ready() -> void:
	layer = HUD_LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Run after the player camera so the field-of-view override is the last word.
	process_priority = 100
	SettingsMenu.load_config()

	_root = Control.new()
	_root.name = "Diegetic"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UITheme.get_theme()
	add_child(_root)

	vignette = DamageVignette.new()
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(vignette)

	bars = StatBars.new()
	bars.set_anchors_preset(Control.PRESET_FULL_RECT)
	bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bars)

	crosshair = Crosshair.new()
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(crosshair)

	ammo = AmmoReadout.new()
	ammo.set_anchors_preset(Control.PRESET_FULL_RECT)
	ammo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(ammo)

	objective = ObjectiveLine.new()
	objective.set_anchors_preset(Control.PRESET_FULL_RECT)
	objective.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(objective)

	prompt = InteractPrompt.new()
	prompt.set_anchors_preset(Control.PRESET_FULL_RECT)
	prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(prompt)

	compass = Compass.new()
	compass.set_anchors_preset(Control.PRESET_CENTER_TOP)
	compass.size = Vector2(660, 58)
	compass.position = Vector2(-330, 26)
	_root.add_child(compass)

	notes = Notifications.new()
	notes.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	notes.size = Vector2(360, 260)
	notes.position = Vector2(-396, 78)
	_root.add_child(notes)

	combat_overlay = CombatOverlay.new()
	combat_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	combat_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(combat_overlay)

	# The death overlay is a sibling of the diegetic layer, not a child: everything
	# else fades out when Rama falls, and this is what is left.
	death = DeathOverlay.new()
	death.set_anchors_preset(Control.PRESET_FULL_RECT)
	death.mouse_filter = Control.MOUSE_FILTER_IGNORE
	death.theme = UITheme.get_theme()
	death.load_requested.connect(func(): open_save_menu("load"))
	death.title_requested.connect(_to_main_menu)
	add_child(death)

	_menus = Control.new()
	_menus.name = "Menus"
	_menus.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menus.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menus.theme = UITheme.get_theme()
	add_child(_menus)

	pause_menu = PauseMenu.new()
	pause_menu.hide()
	pause_menu.resume_requested.connect(close_all)
	pause_menu.journal_requested.connect(func(): _swap_to(journal))
	pause_menu.save_requested.connect(func(): open_save_menu("save"))
	pause_menu.load_requested.connect(func(): open_save_menu("load"))
	pause_menu.settings_requested.connect(func(): _swap_to(settings_menu))
	pause_menu.main_menu_requested.connect(_to_main_menu)
	pause_menu.quit_requested.connect(func(): get_tree().quit(0))
	_menus.add_child(pause_menu)

	settings_menu = SettingsMenu.new()
	settings_menu.hide()
	settings_menu.closed.connect(close_top)
	_menus.add_child(settings_menu)

	save_menu = SaveMenu.new()
	save_menu.hide()
	save_menu.closed.connect(close_top)
	save_menu.slot_used.connect(_on_slot_used)
	_menus.add_child(save_menu)

	inventory = InventoryPanel.new()
	inventory.hide()
	inventory.focus_mode = Control.FOCUS_ALL
	_menus.add_child(inventory)

	journal = JournalPanel.new()
	journal.hide()
	journal.focus_mode = Control.FOCUS_ALL
	_menus.add_child(journal)

	_connect_bus()
	set_process(true)
	SettingsMenu.apply(get_tree())
	_refresh_from_state()


func _connect_bus() -> void:
	EventBus.player_spawned.connect(_on_player_spawned)
	EventBus.player_stat_changed.connect(_on_stats)
	EventBus.player_damaged.connect(_on_damaged)
	EventBus.player_healed.connect(func(a: float): vignette.heal_flash(a))
	EventBus.player_died.connect(_on_died)
	EventBus.enemy_damaged.connect(_on_enemy_damaged)
	EventBus.interact_target_changed.connect(_on_interact_target)
	EventBus.location_discovered.connect(_on_location)
	EventBus.item_gained.connect(_on_item)
	EventBus.quest_started.connect(_on_quest_started)
	EventBus.quest_objective_changed.connect(_on_objective_changed)
	EventBus.quest_objective_completed.connect(_on_objective_done)
	EventBus.quest_completed.connect(_on_quest_completed)
	EventBus.notify.connect(func(t: String, b: String, k: String): notes.push(t, b, k))
	EventBus.dialogue_started.connect(_on_dialogue_started)
	EventBus.dialogue_ended.connect(_on_dialogue_ended)
	EventBus.game_loaded.connect(_on_game_loaded)
	EventBus.game_saved.connect(_on_game_saved)
	EventBus.request_pause.connect(func(p: bool): set_paused(p))
	if EventBus.has_signal("objective_marker_changed"):
		EventBus.connect("objective_marker_changed", Callable(self, "_on_marker"))


## Bind to a running Game. Optional: the HUD finds the player through the event bus
## and the `player` group if nobody calls this.
func setup(g: Node) -> void:
	game = g
	var p: Variant = g.get("player") if g else null
	if p != null and is_instance_valid(p):
		_on_player_spawned(p)


func _on_player_spawned(p: Node) -> void:
	player = p
	cam_rig = p.get("cam_rig") if p else null
	SettingsMenu.apply(get_tree())
	_refresh_from_state()
	if not bool(GameState.get_flag("welcomed", false)):
		GameState.set_flag("welcomed", true)
		notes.push(
			"॥ श्री रामचन्द्राय नमः ॥",
			"You are Rama, Prince of Ayodhya. Armed with the divine Kodanda, seek Sage Vishvamitra at Siddhashrama to fulfill your destiny.",
			"quest"
		)


func _refresh_from_state() -> void:
	bars.set_stats(GameState.health, GameState.max_health, GameState.stamina, GameState.max_stamina, true)
	ammo.count = GameState.arrows
	compass.clear_places()
	for id in GameState.discovered.keys():
		compass.add_place(String(id), UITheme.prettify(String(id)))
	inventory.refresh()
	journal.refresh()
	_pick_objective()


# ==========================================================================
# per-frame
# ==========================================================================
func _process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		var found := get_tree().get_first_node_in_group("player")
		if found:
			_on_player_spawned(found)

	# Game respawns the player a few seconds after a death; nothing signals that, so
	# the overlay watches the player's own state to know when to let go.
	if _dead and player != null and is_instance_valid(player) and player.has_method("is_dead") and not player.is_dead():
		_dead = false
		death.clear()

	var want: float = 0.0 if (_dialogue or _dead or not _stack.is_empty()) else 1.0
	_hud_alpha = move_toward(_hud_alpha, want, delta * 6.0)
	_root.modulate = Color(1, 1, 1, _hud_alpha)
	_root.visible = _hud_alpha > 0.004
	compass.fade = _hud_alpha
	notes.fade = _hud_alpha

	if player != null and is_instance_valid(player):
		var aiming: bool = bool(player.get("aiming"))
		var charge: float = float(player.get("draw_charge"))
		var using_bow: bool = bool(player.get("using_bow"))
		crosshair.set_state(aiming, charge, delta)
		ammo.set_state(using_bow, GameState.arrows, aiming, delta)
		var pos: Vector3 = (player as Node3D).global_position
		var yaw: float = float(player.get("facing_yaw"))
		if cam_rig != null and is_instance_valid(cam_rig):
			yaw = float(cam_rig.get("yaw"))
		compass.set_view(yaw, Vector2(pos.x, pos.z))
		bars.set_stats(GameState.health, GameState.max_health, GameState.stamina, GameState.max_stamina, false)
		vignette.health_frac = GameState.health / maxf(GameState.max_health, 1.0)
		_apply_fov()

	prompt.enabled = SettingsMenu.get_b("ui/show_prompts")


## The player camera recomputes its field of view every frame from its own constants,
## so the setting is re-applied afterwards rather than fought with.
func _apply_fov() -> void:
	if cam_rig == null or not is_instance_valid(cam_rig):
		return
	var cam: Variant = cam_rig.get("cam")
	if cam == null or not (cam is Camera3D):
		return
	var blend: Variant = cam_rig.get("_blend")
	var extra: Variant = cam_rig.get("_fov_extra")
	if blend == null or extra == null:
		return
	var base: float = lerpf(float(PlayerCamera.FREE["fov"]), float(PlayerCamera.AIMED["fov"]), float(blend)) + float(extra)
	(cam as Camera3D).fov = clampf(base + (SettingsMenu.get_f("video/fov") - 64.0), 30.0, 120.0)


# ==========================================================================
# event bus reactions
# ==========================================================================
func _on_stats(h: float, mh: float, s: float, ms: float) -> void:
	bars.set_stats(h, mh, s, ms, false)


func _on_damaged(amount: float, source: Node) -> void:
	vignette.hurt(amount)
	bars.flash_health()
	if source != null and is_instance_valid(source) and source is Node3D:
		var cam := get_viewport().get_camera_3d()
		if cam and player is Node3D:
			var to: Vector3 = (source as Node3D).global_position - (player as Node3D).global_position
			var local: Vector3 = cam.global_transform.basis.inverse() * to
			vignette.set_hit_direction(atan2(local.x, -local.z))


func _on_died() -> void:
	_dead = true
	notes.clear_all()
	death.begin(GameState.has_slot(0) or GameState.has_slot(1) or GameState.has_slot(2))


func _on_enemy_damaged(enemy: Node, amount: float, crit: bool, hit_pos: Vector3) -> void:
	if combat_overlay != null:
		combat_overlay.on_enemy_damaged(enemy, amount, crit, hit_pos)


func _on_interact_target(target: Node, text: String) -> void:
	prompt.set_target(target != null, text, "E")


func _on_location(id: String, display_name: String) -> void:
	var nice: String = display_name if display_name != "" else UITheme.prettify(id)
	notes.push("Location discovered", nice, "discovery")
	compass.add_place(id, nice)
	journal.note_location(id, nice)
	journal.refresh()


func _on_item(id: String, count: int) -> void:
	var meta: Dictionary = InventoryPanel.CATALOGUE.get(id, {})
	var nice: String = String(meta.get("name", UITheme.prettify(id)))
	notes.push("Gained", nice if count <= 1 else "%s x%d" % [nice, count], "item")
	inventory.refresh()


func _on_quest_started(id: String) -> void:
	notes.push("Quest started", _quest_title(id), "quest")
	# Something is driving quests, so it is worth the journal looking for it again
	# even if there was nothing to find when the HUD booted.
	journal.rescan_quest_system()
	journal.refresh()
	_pick_objective()


func _on_quest_completed(id: String) -> void:
	notes.push("Quest complete", _quest_title(id), "quest")
	journal.refresh()
	_pick_objective()


func _on_objective_changed(quest_id: String, objective_id: String, progress: int, total: int) -> void:
	var text := _objective_text(quest_id, objective_id)
	if total > 1:
		text = "%s  (%d/%d)" % [text, progress, total]
	objective.set_line(text)
	_objective_quest = quest_id
	_objective_id = objective_id
	journal.note_objective(quest_id, objective_id, progress, total)
	journal.refresh()


func _on_objective_done(quest_id: String, objective_id: String) -> void:
	notes.push("Objective complete", _objective_text(quest_id, objective_id), "objective")
	objective.mark_complete()
	journal.refresh()


func _on_marker(position: Vector3, active: bool) -> void:
	compass.set_objective(position, "", active)


func _on_dialogue_started(_speaker: String, _node_id: String) -> void:
	_dialogue = true


func _on_dialogue_ended() -> void:
	_dialogue = false


func _on_game_saved(slot: int) -> void:
	notes.push("Saved", "Slot %d" % (slot + 1), "info")


func _on_game_loaded(slot: int) -> void:
	SaveMenu.apply_loaded_state(game)
	_dead = false
	death.clear()
	_refresh_from_state()
	close_all()
	# Every load path in the game ends up here — the save menu, the quick key and
	# `Game.load_game` alike — so this is the one place the toast is raised.
	notes.push("Loaded", "Slot %d" % (slot + 1), "info")


func _on_slot_used(_slot: int, mode: String) -> void:
	if mode == "load":
		close_all()


# --- quest text, defensively ----------------------------------------------
func _quest_system() -> Node:
	for n in get_tree().get_nodes_in_group("quest_system"):
		return n
	if game != null and is_instance_valid(game):
		var q: Variant = game.get("quests")
		if q != null and is_instance_valid(q):
			return q
	return null


func _quest_title(id: String) -> String:
	var q := _quest_system()
	if q != null and q.has_method("quest_title"):
		var t: Variant = q.call("quest_title", id)
		if t != null and String(t) != "":
			return String(t)
	return UITheme.prettify(id)


func _objective_text(quest_id: String, objective_id: String) -> String:
	var q := _quest_system()
	if q != null and q.has_method("objective_text"):
		var t: Variant = q.call("objective_text", quest_id, objective_id)
		if t != null and String(t) != "":
			return String(t)
	return UITheme.prettify(objective_id)


## Pick something sensible to show on the objective line from raw GameState, for the
## case where nothing has fired a signal yet (a loaded save, say).
func _pick_objective() -> void:
	for id in GameState.quests.keys():
		var raw: Variant = GameState.quests[id]
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = raw
		if String(d.get("state", "active")) == "complete":
			continue
		var objs: Variant = d.get("objectives", {})
		if typeof(objs) == TYPE_DICTIONARY and not (objs as Dictionary).is_empty():
			var first := String((objs as Dictionary).keys()[0])
			objective.set_line(_objective_text(String(id), first))
			_objective_quest = String(id)
			_objective_id = first
			return
		objective.set_line(_quest_title(String(id)))
		return
	objective.set_line("Bala Kanda: Seek Sage Vishvamitra at Siddhashrama")
	compass.set_objective(Vector3(-136.0, 10.0, 32.0), "Sage Vishvamitra", true)


## Content systems that know where a thing is can point the compass at it.
func set_objective_marker(world_pos: Vector3, label: String = "") -> void:
	compass.set_objective(world_pos, label, true)


func clear_objective_marker() -> void:
	compass.set_objective(Vector3.ZERO, "", false)


func set_objective_text(text: String) -> void:
	objective.set_line(text)


# ==========================================================================
# menus
# ==========================================================================
func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("pause"):
		if _stack.is_empty():
			open_panel(pause_menu)
		else:
			close_top()
		get_viewport().set_input_as_handled()
	elif e.is_action_pressed("inventory"):
		_toggle(inventory)
		get_viewport().set_input_as_handled()
	elif e.is_action_pressed("journal"):
		_toggle(journal)
		get_viewport().set_input_as_handled()
	elif e.is_action_pressed("quick_save"):
		quick_save()
		get_viewport().set_input_as_handled()
	elif e.is_action_pressed("quick_load"):
		quick_load()
		get_viewport().set_input_as_handled()


## Quick save has to capture the LIVE world — where Rama is standing, which way he is
## facing, what hour it is, what the quest system knows — and only the Game can gather
## that. Writing GameState straight to disk saves whatever it last happened to hold,
## which is a save from wherever the player was when some other system last touched it.
func quick_save() -> void:
	var ok: bool
	if game != null and is_instance_valid(game) and game.has_method("save_game"):
		ok = bool(game.call("save_game", QUICK_SLOT))
	else:
		ok = GameState.save_to_slot(QUICK_SLOT)
	if ok:
		save_menu.refresh()
	else:
		notes.push("Could not save", "The save folder could not be written.", "warn")


## Likewise a quick load has to be pushed back into the running world, not merely read
## into GameState, or Rama stays exactly where he was standing with someone else's
## inventory.
func quick_load() -> void:
	if not GameState.has_slot(QUICK_SLOT):
		notes.push("Nothing to load", "Slot %d is empty." % (QUICK_SLOT + 1), "warn")
		return
	if game != null and is_instance_valid(game) and game.has_method("load_game"):
		if not bool(game.call("load_game", QUICK_SLOT)):
			notes.push("Could not load", "Slot %d could not be read." % (QUICK_SLOT + 1), "warn")
		return
	if not GameState.load_from_slot(QUICK_SLOT):
		notes.push("Could not load", "Slot %d could not be read." % (QUICK_SLOT + 1), "warn")


func _toggle(panel: Control) -> void:
	if _stack.has(panel):
		close_top()
	elif _stack.is_empty():
		open_panel(panel)


func open_panel(panel: Control) -> void:
	if _stack.has(panel):
		return
	if not _stack.is_empty():
		(_stack.back() as Control).hide()
	_stack.append(panel)
	if panel == inventory:
		inventory.refresh()
	elif panel == journal:
		journal.refresh()
	elif panel == save_menu:
		save_menu.refresh()
	panel.show()
	if panel.focus_mode != Control.FOCUS_NONE:
		panel.grab_focus()
	if panel == pause_menu:
		pause_menu.opened()
	AudioDirector.play_ui("ui_open")
	_apply_menu_state()


func open_save_menu(mode: String) -> void:
	save_menu.open_as(mode)
	if not _stack.has(save_menu):
		open_panel(save_menu)
	else:
		save_menu.show()


func _swap_to(panel: Control) -> void:
	# From the pause menu into one of its children, keeping the pause underneath.
	open_panel(panel)


func close_top() -> void:
	if _stack.is_empty():
		return
	var top: Control = _stack.pop_back()
	top.hide()
	if not _stack.is_empty():
		var under: Control = _stack.back()
		under.show()
		if under.focus_mode != Control.FOCUS_NONE:
			under.grab_focus()
		if under == pause_menu:
			pause_menu.opened()
	AudioDirector.play_ui("ui_close")
	_apply_menu_state()


func close_all() -> void:
	for p in _stack:
		(p as Control).hide()
	_stack.clear()
	AudioDirector.play_ui("ui_close")
	_apply_menu_state()


func is_menu_open() -> bool:
	return not _stack.is_empty()


func top_panel() -> Control:
	return _stack.back() if not _stack.is_empty() else null


func set_paused(p: bool) -> void:
	if p and _stack.is_empty():
		open_panel(pause_menu)
	elif not p and not _stack.is_empty():
		close_all()


func _apply_menu_state() -> void:
	var open := not _stack.is_empty()
	get_tree().paused = open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if cam_rig != null and is_instance_valid(cam_rig) and cam_rig.has_method("set_enabled"):
		cam_rig.set_enabled(not open)
	if player != null and is_instance_valid(player) and player.has_method("lock_input"):
		player.lock_input(open)
	_menus.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _to_main_menu() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	AudioDirector.stop_music(0.8)
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# ==========================================================================
# launching a session
# ==========================================================================
## Build a playable session (world + player + this HUD) and make it the current
## scene. The main menu calls this; so does the UI test.
static func launch(tree: SceneTree) -> Node:
	var session := Node3D.new()
	session.name = "Session"
	# The HUD goes in FIRST. `Game.boot()` builds an interface for itself if it cannot
	# find one, so adding it after the Game would leave the session with two — two
	# pause menus, both writing `get_tree().paused` and `Input.mouse_mode`. Put it
	# where the Game will find it, and it adopts this one instead.
	var hud := HUD.new()
	hud.name = "HUD"
	session.add_child(hud)
	var g := Game.new()
	g.name = "Game"
	session.add_child(g)
	var old := tree.current_scene
	tree.root.add_child(session)
	tree.current_scene = session
	if old != null and is_instance_valid(old):
		old.queue_free()
	hud.setup(g)
	return session


# ==========================================================================
# widgets
# ==========================================================================


## Health, stamina, and Prana (Celestial Energy). Slim, shallowly arced, and quiet until they matter.
class StatBars:
	extends Control
	const W := 268.0
	const CURVE := 5.0
	const PRANA_COLOR := Color(0.24, 0.62, 0.92, 1.0)

	var health: float = 100.0
	var max_health: float = 100.0
	var stamina: float = 100.0
	var max_stamina: float = 100.0
	var prana: float = 100.0
	var max_prana: float = 100.0
	var _shown_health: float = 1.0
	var _shown_stamina: float = 1.0
	var _shown_prana: float = 1.0
	var _flash: float = 0.0
	var _attention: float = 0.0
	var _last_h: float = -1.0
	var _last_s: float = -1.0
	var _last_p: float = -1.0
	var _t: float = 0.0

	func _ready() -> void:
		set_process(true)

	func _sync_prana(snap: bool) -> void:
		var raw_p: Variant = GameState.get("prana")
		var raw_mp: Variant = GameState.get("max_prana")
		var p_val: float = float(raw_p) if raw_p != null else 100.0
		var mp_val: float = maxf(float(raw_mp) if raw_mp != null else 100.0, 1.0)
		if _last_p >= 0.0 and absf(p_val - _last_p) > 0.5:
			_attention = 1.0
		_last_p = p_val
		prana = p_val
		max_prana = mp_val
		if snap:
			_shown_prana = prana / max_prana

	func set_stats(h: float, mh: float, s: float, ms: float, snap: bool) -> void:
		if _last_h >= 0.0 and (absf(h - _last_h) > 0.01 or absf(s - _last_s) > 0.9):
			_attention = 1.0
		_last_h = h
		_last_s = s
		health = h
		max_health = maxf(mh, 1.0)
		stamina = s
		max_stamina = maxf(ms, 1.0)
		if snap:
			_shown_health = health / max_health
			_shown_stamina = stamina / max_stamina
		_sync_prana(snap)

	func flash_health() -> void:
		_flash = 1.0
		_attention = 1.0

	func _process(delta: float) -> void:
		_t += delta
		_sync_prana(false)
		_flash = maxf(0.0, _flash - delta * 2.2)
		_attention = maxf(0.0, _attention - delta * 0.45)
		_shown_health = lerpf(_shown_health, health / max_health, clampf(delta * 7.0, 0.0, 1.0))
		_shown_stamina = lerpf(_shown_stamina, stamina / max_stamina, clampf(delta * 11.0, 0.0, 1.0))
		_shown_prana = lerpf(_shown_prana, prana / max_prana, clampf(delta * 9.0, 0.0, 1.0))
		queue_redraw()

	## Draw a bar along a shallow arc, so it reads as carved rather than as a widget.
	## One polyline per pass: drawing it as separate capped segments double-blends at
	## every joint and the bar comes out dotted at low alpha.
	##
	## The channel underneath is not decoration. A fill drawn on its own is a coloured
	## stick with no length to measure against: half health and a short bar look the
	## same, and a full bar looks like a stray mark. Three passes, because this HUD
	## sits over sunlit sandstone and over black grass within a single step — a dark
	## outline that reads against the bright ground, a pale bed that reads against the
	## dark, and the ink channel itself over both. All of it scales with `alpha`, so a
	## bar with nothing to say still fades back to almost nothing.
	func _arc_bar(o: Vector2, w: float, thick: float, frac: float, col: Color, track: Color, alpha: float) -> void:
		var segs := 26
		var pts: PackedVector2Array = []
		for i in range(segs + 1):
			var t: float = float(i) / float(segs)
			pts.append(o + Vector2(t * w, -sin(t * PI) * CURVE))
		draw_polyline(pts, Color(0.0, 0.0, 0.0, 0.55 * alpha), thick + 2.6, true)
		draw_polyline(pts, Color(UITheme.PARCHMENT.r, UITheme.PARCHMENT.g, UITheme.PARCHMENT.b, 0.14 * alpha), thick, true)
		draw_polyline(pts, track, thick, true)
		var upto: float = clampf(frac, 0.0, 1.0) * float(segs)
		var full: int = int(floor(upto))
		if upto <= 0.02:
			return
		var fill: PackedVector2Array = []
		for i in range(mini(full, segs) + 1):
			fill.append(pts[i])
		if full < segs and upto - float(full) > 0.02:
			fill.append(pts[full].lerp(pts[full + 1], upto - float(full)))
		if fill.size() >= 2:
			draw_polyline(fill, col, thick, true)
		elif fill.size() == 1:
			draw_circle(fill[0], thick * 0.5, col)

	func _draw() -> void:
		var hf: float = clampf(_shown_health, 0.0, 1.0)
		var sf: float = clampf(_shown_stamina, 0.0, 1.0)
		var pf: float = clampf(_shown_prana, 0.0, 1.0)
		# Quiet when full and rested; loud when any bar has something to say.
		var urgency: float = maxf(maxf(1.0 - hf, (1.0 - sf) * 0.8), (1.0 - pf) * 0.65)
		var a: float = clampf(0.30 + urgency * 0.70 + _attention * 0.55, 0.0, 1.0)

		var o := Vector2(46.0, size.y - 74.0)
		var hcol := UITheme.HEALTH
		if _flash > 0.0:
			hcol = hcol.lerp(Color(1, 0.92, 0.86), _flash * 0.8)
		if hf < 0.30:
			hcol = hcol.lerp(UITheme.CRIMSON_PALE, 0.5 + 0.5 * sin(_t * 5.0))
		_arc_bar(o, W, 7.0, hf, Color(hcol.r, hcol.g, hcol.b, a), Color(0.031, 0.024, 0.020, 0.72 * a), a)

		var sw: float = W - 34.0
		var so := o + Vector2(4.0, 15.0)
		var scol := UITheme.STAMINA
		var s_alpha: float = a * (0.45 if sf > 0.995 else 1.0)
		if sf < 0.06:
			scol = scol.lerp(UITheme.PARCHMENT_FAINT, 0.6)
		_arc_bar(so, sw, 4.0, sf, Color(scol.r, scol.g, scol.b, s_alpha), Color(0.031, 0.024, 0.020, 0.62 * a), a)

		var pw: float = W - 64.0
		var po := o + Vector2(8.0, 27.0)
		var pcol := PRANA_COLOR
		var p_alpha: float = a * (0.55 if pf > 0.995 else 1.0)
		_arc_bar(po, pw, 3.8, pf, Color(pcol.r, pcol.g, pcol.b, p_alpha), Color(0.024, 0.038, 0.058, 0.65 * a), a)

		# Brass serifs and golden filigree that bracket the three bars (Jiva, Bala, Prana).
		var tick := Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, a * 0.82)
		draw_line(o + Vector2(-9, -4), o + Vector2(-9, 32), tick, 1.0, true)
		draw_line(o + Vector2(W + 1, -4), o + Vector2(W + 1, 4), tick, 1.0, true)
		draw_line(so + Vector2(sw + 1, -3), so + Vector2(sw + 1, 3), Color(tick.r, tick.g, tick.b, a * 0.55), 1.0, true)
		draw_line(po + Vector2(pw + 1, -3), po + Vector2(pw + 1, 3), Color(tick.r, tick.g, tick.b, a * 0.68), 1.2, true)
		draw_colored_polygon(
			PackedVector2Array([po + Vector2(-5, 0), po + Vector2(-2, -3), po + Vector2(1, 0), po + Vector2(-2, 3)]),
			Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, a * 0.75)
		)


## The bow reticle. It only exists while aiming, and it opens outward as the draw
## builds so the shot can be read at a glance.
class Crosshair:
	extends Control
	var aiming: bool = false
	var charge: float = 0.0
	var _a: float = 0.0
	var _full: float = 0.0
	var _t: float = 0.0

	func _ready() -> void:
		set_process(true)

	func set_state(is_aiming: bool, draw_charge: float, delta: float) -> void:
		aiming = is_aiming
		charge = draw_charge
		var target: float = 1.0 if is_aiming else 0.0
		_a = move_toward(_a, target, delta * 6.5)
		if charge >= 0.999:
			_full = minf(1.0, _full + delta * 4.0)
		else:
			_full = maxf(0.0, _full - delta * 5.0)

	func _process(delta: float) -> void:
		_t += delta
		if _a > 0.004 or aiming:
			queue_redraw()
		elif _a <= 0.004:
			queue_redraw()

	func _draw() -> void:
		if _a <= 0.004:
			return
		var c := size * 0.5
		var col := Color(UITheme.PARCHMENT.r, UITheme.PARCHMENT.g, UITheme.PARCHMENT.b, _a)
		var hot := Color(UITheme.SAFFRON_PALE.r, UITheme.SAFFRON_PALE.g, UITheme.SAFFRON_PALE.b, _a)

		# Ticks spread outward with the draw.
		var r: float = lerpf(9.0, 30.0, charge)
		var len: float = lerpf(5.0, 11.0, charge)
		var tint: Color = col.lerp(hot, _full)
		for i in range(4):
			var ang: float = TAU * float(i) / 4.0 + PI * 0.25
			var d := Vector2(cos(ang), sin(ang))
			draw_line(c + d * r, c + d * (r + len), tint, 1.6, true)

		# A brass arc that closes as the draw completes.
		if charge > 0.02:
			draw_arc(
				c,
				34.0,
				-PI * 0.5,
				-PI * 0.5 + TAU * charge,
				48,
				Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, _a * 0.85),
				2.0,
				true
			)
		# The still point at the centre.
		draw_circle(c, 1.7 + _full * 1.0, tint)
		if _full > 0.0:
			var pulse: float = 0.5 + 0.5 * sin(_t * 8.0)
			draw_arc(c, 38.0 + pulse * 2.0, 0.0, TAU, 48, Color(hot.r, hot.g, hot.b, _a * _full * 0.55), 1.2, true)


## Arrows remaining & Divya Astra attunement (bottom-right), plus crosshair-adjacent count when aiming.
class AmmoReadout:
	extends Control
	const AFTERGLOW := 2.4
	const ASTRAS := [
		{"name": "[1] Shara — Sacred Shaft", "col": Color(0.784, 0.635, 0.290, 1.0)},
		{"name": "[2] Agneyastra — Fire of Agni", "col": Color(0.96, 0.48, 0.16, 1.0)},
		{"name": "[3] Varunastra — Torrent of Varuna", "col": Color(0.26, 0.72, 0.94, 1.0)},
		{"name": "[4] Vayavyastra — Gale of Vayu", "col": Color(0.38, 0.88, 0.62, 1.0)},
		{"name": "[5] Brahmastra — Solar Disk of Brahma", "col": Color(1.0, 0.86, 0.32, 1.0)},
	]

	var count: int = 0
	var _a: float = 0.0
	var _bump: float = 0.0
	var _hold: float = 0.0
	var _last: int = -1
	var _last_astra: int = 0
	var _astra_flash: float = 0.0

	func _ready() -> void:
		set_process(true)

	## Visible while the bow is drawn, and for a couple of seconds after the count
	## changes. Otherwise there is no reason for a number to be on screen.
	func set_state(using_bow: bool, arrows: int, aiming: bool, delta: float) -> void:
		if _last >= 0 and arrows != _last:
			_bump = 1.0
			_hold = AFTERGLOW
		_last = arrows
		count = arrows
		var raw_astra: Variant = GameState.get("active_astra")
		var cur_astra: int = clampi(int(raw_astra) if raw_astra != null else 0, 0, 4)
		if cur_astra != _last_astra:
			_last_astra = cur_astra
			_astra_flash = 1.0
			_hold = AFTERGLOW
		_astra_flash = maxf(0.0, _astra_flash - delta * 2.2)
		_hold = maxf(0.0, _hold - delta)
		var target: float = 0.0
		if using_bow:
			if aiming:
				target = 1.0
			elif _hold > 0.0:
				target = 0.75
		_a = move_toward(_a, target, delta * 5.0)
		_bump = maxf(0.0, _bump - delta * 2.0)

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var f_label := UITheme.label_font()
		var f_eye := UITheme.eyebrow_font()
		var f_body := UITheme.body_font()

		# 1. Crosshair-adjacent arrow count when drawing the bow.
		if _a > 0.01:
			var c := size * 0.5 + Vector2(46.0, 34.0)
			var low: bool = count <= 3
			var col: Color = UITheme.PARCHMENT if not low else UITheme.CRIMSON_PALE
			var a: float = _a * (0.85 + _bump * 0.15)
			var g := c + Vector2(0, -5)
			draw_line(g + Vector2(0, 8), g + Vector2(0, -6), Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, a), 1.4, true)
			draw_colored_polygon(
				PackedVector2Array([g + Vector2(0, -10), g + Vector2(3.4, -4.4), g + Vector2(-3.4, -4.4)]),
				Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, a)
			)
			UITheme.draw_text(self, f_label, c + Vector2(12, 5), str(count), UITheme.FS_LABEL, Color(col.r, col.g, col.b, a))

		# 2. Bottom-right Kodanda Quiver & Divya Astra Attunement Readout.
		var raw_astra: Variant = GameState.get("active_astra")
		var astra_idx: int = clampi(int(raw_astra) if raw_astra != null else 0, 0, ASTRAS.size() - 1)
		var astra: Dictionary = ASTRAS[astra_idx]
		var acol: Color = astra["col"]
		var aname := String(astra["name"])
		var raw_max: Variant = GameState.get("max_arrows")
		var max_arr: int = int(raw_max) if raw_max != null else 40
		var base_a: float = clampf(0.68 + _a * 0.32 + _astra_flash * 0.30, 0.0, 1.0)

		var rx: float = size.x - 46.0
		var ry: float = size.y - 76.0
		var arr_str := "Arrows  %d / %d" % [count, max_arr]
		var aw := UITheme.text_width(f_body, arr_str, UITheme.FS_SMALL)
		var arr_col: Color = UITheme.PARCHMENT if count > 3 else UITheme.CRIMSON_PALE
		UITheme.draw_text(
			self, f_body, Vector2(rx - aw, ry), arr_str, UITheme.FS_SMALL, Color(arr_col.r, arr_col.g, arr_col.b, base_a * 0.92)
		)

		var as_w := UITheme.text_width(f_label, aname, UITheme.FS_SMALL)
		var as_pos := Vector2(rx - as_w, ry + 22.0)
		var d_pos := as_pos + Vector2(-12.0, -5.0)
		draw_colored_polygon(
			PackedVector2Array([d_pos + Vector2(0, -4.5), d_pos + Vector2(4.5, 0), d_pos + Vector2(0, 4.5), d_pos + Vector2(-4.5, 0)]),
			Color(acol.r, acol.g, acol.b, base_a)
		)
		UITheme.draw_text(self, f_label, as_pos, aname, UITheme.FS_SMALL, Color(acol.r, acol.g, acol.b, base_a))

		var hint := "[WASD] Move  ·  [Hold RMB] Draw Kodanda  ·  [Q] Sword  ·  [F] Parry  ·  [1-5/R] Astras  ·  [J] Kandas"
		var hw := UITheme.text_width(f_eye, hint, UITheme.FS_TINY)
		UITheme.draw_text(
			self,
			f_eye,
			Vector2(rx - hw, ry + 42.0),
			hint,
			UITheme.FS_TINY,
			Color(UITheme.PARCHMENT_FAINT.r, UITheme.PARCHMENT_FAINT.g, UITheme.PARCHMENT_FAINT.b, base_a * 0.78)
		)


## The single line of "what am I doing", top left, with a carved tick when it changes.
class ObjectiveLine:
	extends Control
	var text: String = ""
	var _shown: String = ""
	var _in: float = 0.0
	var _tick: float = 0.0
	var _a: float = 0.0

	func _ready() -> void:
		set_process(true)

	func set_line(t: String) -> void:
		if t == text:
			return
		text = t
		_shown = t
		_in = 0.0
		_tick = 1.0 if t != "" else 0.0

	func mark_complete() -> void:
		_tick = 1.0

	func _process(delta: float) -> void:
		_in = minf(1.0, _in + delta * 2.6)
		_tick = maxf(0.0, _tick - delta * 0.7)
		_a = move_toward(_a, 1.0 if _shown != "" else 0.0, delta * 3.0)
		queue_redraw()

	func _draw() -> void:
		if _a <= 0.01 or _shown == "":
			return
		var ease: float = 1.0 - pow(1.0 - _in, 3.0)
		var o := Vector2(46.0, 84.0 + (1.0 - ease) * 8.0)
		var a: float = _a * ease
		UITheme.draw_text(
			self, UITheme.eyebrow_font(), o, "OBJECTIVE", UITheme.FS_TINY, Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, a * 0.9)
		)
		var tx: float = o.x
		if _tick > 0.0:
			# A diamond that draws itself in, then fades. Below half a pixel the four
			# corners collapse onto each other and the polygon fails to triangulate.
			var s: float = 4.6 * clampf(_tick * 2.2, 0.0, 1.0)
			if s < 0.5:
				s = 0.0
			var col := Color(UITheme.SAFFRON.r, UITheme.SAFFRON.g, UITheme.SAFFRON.b, a * clampf(_tick * 1.6, 0.0, 1.0))
			var cy: float = o.y + 20.0
			if s > 0.0:
				draw_colored_polygon(
					PackedVector2Array(
						[Vector2(tx + 5, cy - s), Vector2(tx + 5 + s, cy), Vector2(tx + 5, cy + s), Vector2(tx + 5 - s, cy)]
					),
					col
				)
			tx += 18.0
		UITheme.draw_text(
			self,
			UITheme.label_font(),
			Vector2(tx, o.y + 26.0),
			_shown,
			UITheme.FS_LABEL,
			Color(UITheme.PARCHMENT.r, UITheme.PARCHMENT.g, UITheme.PARCHMENT.b, a),
			HORIZONTAL_ALIGNMENT_LEFT,
			520.0
		)


## "E — Ring the bell", near the middle of the screen where the interactable is.
class InteractPrompt:
	extends Control
	var enabled: bool = true
	var text: String = ""
	var key: String = "E"
	var _on: bool = false
	var _a: float = 0.0

	func _ready() -> void:
		set_process(true)

	func set_target(has_target: bool, prompt_text: String, key_name: String) -> void:
		_on = has_target and prompt_text != ""
		if _on:
			text = prompt_text
			key = key_name

	func _process(delta: float) -> void:
		_a = move_toward(_a, 1.0 if (_on and enabled) else 0.0, delta * 7.0)
		queue_redraw()

	func _draw() -> void:
		if _a <= 0.01:
			return
		var f := UITheme.body_font()
		var fe := UITheme.eyebrow_font()
		var tw := UITheme.text_width(f, text, UITheme.FS_BODY)
		var kw := UITheme.text_width(fe, key, UITheme.FS_TINY)
		var box := 26.0
		var total: float = box + 12.0 + tw
		var o := Vector2(size.x * 0.5 - total * 0.5, size.y * 0.5 + 126.0 + (1.0 - _a) * 6.0)

		var kb := Rect2(o, Vector2(box, box))
		var sb := UITheme.flat_style(
			Color(0.062, 0.049, 0.040, 0.86 * _a), 3, 1.0, Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, 0.85 * _a), 0, 0
		)
		draw_style_box(sb, kb)
		UITheme.draw_text(
			self,
			fe,
			Vector2(kb.position.x + (box - kw) * 0.5, kb.position.y + box * 0.5 + 4.5),
			key,
			UITheme.FS_TINY,
			Color(UITheme.SAFFRON_PALE.r, UITheme.SAFFRON_PALE.g, UITheme.SAFFRON_PALE.b, _a)
		)
		UITheme.draw_text(
			self,
			f,
			Vector2(o.x + box + 12.0, o.y + box * 0.5 + 5.5),
			text,
			UITheme.FS_BODY,
			Color(UITheme.PARCHMENT.r, UITheme.PARCHMENT.g, UITheme.PARCHMENT.b, _a)
		)


## Damage: an edge tint that bites when you are hit and lingers when you are low,
## plus an arc pointing back at whatever hit you.
class DamageVignette:
	extends Control
	var health_frac: float = 1.0
	var _hurt: float = 0.0
	var _heal: float = 0.0
	var _dir: float = 0.0
	var _dir_life: float = 0.0
	var _t: float = 0.0
	var _tex: Texture2D

	func _ready() -> void:
		_tex = UITheme.vignette_texture()
		set_process(true)

	func hurt(amount: float) -> void:
		_hurt = clampf(maxf(_hurt, amount / 26.0), 0.0, 1.2)

	func heal_flash(_amount: float) -> void:
		_heal = 1.0

	func set_hit_direction(angle: float) -> void:
		_dir = angle
		_dir_life = 1.0

	func _process(delta: float) -> void:
		_t += delta
		_hurt = maxf(0.0, _hurt - delta * 1.5)
		_heal = maxf(0.0, _heal - delta * 1.2)
		_dir_life = maxf(0.0, _dir_life - delta * 0.9)
		queue_redraw()

	func _draw() -> void:
		var low: float = clampf((0.36 - health_frac) / 0.36, 0.0, 1.0)
		var pulse: float = 0.55 + 0.45 * sin(_t * 3.2)
		var red: float = clampf(_hurt * 0.62 + low * 0.30 * pulse, 0.0, 0.85)
		if red > 0.004:
			draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false, Color(0.62, 0.10, 0.07, red))
		if _heal > 0.004:
			draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false, Color(0.38, 0.62, 0.36, _heal * 0.22))
		if _dir_life > 0.004:
			# A short, soft wedge out near the edge of vision: enough to say "from
			# there", never enough to read as a gauge. Built from stacked arcs so it
			# fades away from its centre instead of ending in a hard stop.
			var c := size * 0.5
			var r: float = minf(size.x, size.y) * 0.42
			var mid: float = _dir - PI * 0.5
			var a: float = pow(_dir_life, 1.6) * 0.62
			for i in range(4):
				var t: float = float(i) / 3.0
				var span: float = lerpf(0.26, 0.05, t)
				draw_arc(
					c, r + t * 3.0, mid - span, mid + span, 20, Color(0.92, 0.32, 0.22, a * lerpf(0.35, 1.0, t)), lerpf(7.0, 2.0, t), true
				)


## What you see when Rama falls. Restrained: a line, and the two things you can do.
class DeathOverlay:
	extends Control
	signal load_requested
	signal title_requested

	var _a: float = 0.0
	var _on: bool = false
	var _has_save: bool = false
	var _box: VBoxContainer

	func _ready() -> void:
		set_process(true)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_box = VBoxContainer.new()
		_box.alignment = BoxContainer.ALIGNMENT_CENTER
		_box.add_theme_constant_override("separation", 4)
		_box.set_anchors_preset(Control.PRESET_CENTER)
		_box.hide()
		add_child(_box)
		var b1 := Button.new()
		b1.text = "Load a save"
		b1.theme_type_variation = "Menu"
		b1.pressed.connect(func(): load_requested.emit())
		_box.add_child(b1)
		var b2 := Button.new()
		b2.text = "Return to Title"
		b2.theme_type_variation = "Menu"
		b2.pressed.connect(func(): title_requested.emit())
		_box.add_child(b2)

	func begin(has_save: bool) -> void:
		_on = true
		_has_save = has_save
		(_box.get_child(0) as Button).disabled = not has_save

	func clear() -> void:
		_on = false
		_box.hide()

	func _process(delta: float) -> void:
		# Game revives the player about three seconds after a death, so the overlay
		# has to be fully readable well inside that window.
		var was := _a
		_a = move_toward(_a, 1.0 if _on else 0.0, delta * (0.95 if _on else 1.8))
		# Fully faded out and staying that way. Rewriting the button box's position
		# and modulate every frame relaid out a Container on every frame of the game,
		# for an overlay that is not on screen and almost never is.
		if _a <= 0.0 and was <= 0.0:
			return
		if _box:
			_box.visible = _a > 0.85
			_box.modulate = Color(1, 1, 1, clampf((_a - 0.85) / 0.15, 0.0, 1.0))
			# Centre on the box's own measured width. The old constant 90 px assumed a
			# label width, and left the two buttons sitting 15 px off the axis the
			# title above them is centred on.
			_box.position = Vector2(round((size.x - _box.size.x) * 0.5), round(size.y * 0.5 + 24.0))
			mouse_filter = Control.MOUSE_FILTER_STOP if _box.visible else Control.MOUSE_FILTER_IGNORE
		queue_redraw()

	func _draw() -> void:
		if _a <= 0.004:
			return
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.055, 0.020, 0.016, _a * 0.82), true)
		var f := UITheme.title_font()
		var msg := "RAMA HAS FALLEN"
		var w := UITheme.text_width(f, msg, UITheme.FS_TITLE)
		UITheme.draw_text(
			self,
			f,
			Vector2(size.x * 0.5 - w * 0.5, size.y * 0.5 - 30.0),
			msg,
			UITheme.FS_TITLE,
			Color(UITheme.PARCHMENT.r, UITheme.PARCHMENT.g, UITheme.PARCHMENT.b, _a)
		)
		var sub := "The valley is quiet." if _has_save else "There is no way back from here."
		var fb := UITheme.body_font()
		var sw := UITheme.text_width(fb, sub, UITheme.FS_SMALL)
		UITheme.draw_text(
			self,
			fb,
			Vector2(size.x * 0.5 - sw * 0.5, size.y * 0.5 - 4.0),
			sub,
			UITheme.FS_SMALL,
			Color(UITheme.PARCHMENT_FAINT.r, UITheme.PARCHMENT_FAINT.g, UITheme.PARCHMENT_FAINT.b, _a)
		)


## Floating 2D damage numbers projected from 3D world hit positions, plus an ornate
## top-center Boss Health Bar below the compass when fighting a titled Rakshasa lord.
class CombatOverlay:
	extends Control
	const POP_LIFE := 0.85
	const BOSS_RANGE := 28.0

	var _pops: Array = []  # [{world_pos, text, crit, age, jitter}]
	var _boss: Node = null
	var _boss_title: String = ""
	var _boss_hp: float = 0.0
	var _boss_max: float = 100.0
	var _boss_shown: float = 1.0
	var _boss_alpha: float = 0.0
	var _boss_hold: float = 0.0
	var _scan_t: float = 0.0

	func _ready() -> void:
		set_process(true)

	func on_enemy_damaged(enemy: Node, amount: float, crit: bool, hit_pos: Vector3) -> void:
		var dmg_val: int = maxi(1, int(round(amount)))
		_pops.append(
			{
				"world_pos": hit_pos,
				"text": ("%d!" % dmg_val) if crit else str(dmg_val),
				"crit": crit,
				"age": 0.0,
				"jitter": randf_range(-14.0, 14.0),
			}
		)
		if enemy != null and is_instance_valid(enemy):
			var bt: Variant = enemy.get("boss_title")
			if bt != null and String(bt) != "":
				_boss = enemy
				_boss_title = String(bt)
				_boss_hold = 6.0
				_sync_boss_stats(enemy, false)
		queue_redraw()

	func _sync_boss_stats(e: Node, snap: bool) -> void:
		var raw_h: Variant = e.get("health")
		var raw_mh: Variant = e.get("max_health")
		_boss_hp = maxf(0.0, float(raw_h) if raw_h != null else 0.0)
		_boss_max = maxf(1.0, float(raw_mh) if raw_mh != null else 100.0)
		if snap:
			_boss_shown = _boss_hp / _boss_max

	func _scan_nearby_boss() -> void:
		var tree := get_tree()
		if tree == null:
			return
		var cam := get_viewport().get_camera_3d()
		var ref_pos := cam.global_position if cam != null else GameState.player_position
		for n in tree.get_nodes_in_group("enemy"):
			if not is_instance_valid(n) or not (n is Node3D):
				continue
			if n.has_method("is_alive") and not bool(n.call("is_alive")):
				continue
			var bt: Variant = n.get("boss_title")
			if bt == null or String(bt) == "":
				continue
			var d: float = (n as Node3D).global_position.distance_to(ref_pos)
			if d <= BOSS_RANGE:
				var snap := _boss != n
				_boss = n
				_boss_title = String(bt)
				_boss_hold = maxf(_boss_hold, 1.5)
				_sync_boss_stats(n, snap)
				return

	func _process(delta: float) -> void:
		var i := _pops.size() - 1
		while i >= 0:
			var p: Dictionary = _pops[i]
			p["age"] = float(p["age"]) + delta
			if float(p["age"]) >= POP_LIFE:
				_pops.remove_at(i)
			i -= 1

		_scan_t -= delta
		if _scan_t <= 0.0:
			_scan_t = 0.25
			_scan_nearby_boss()

		var boss_alive := false
		if _boss != null and is_instance_valid(_boss):
			var alive := true
			if _boss.has_method("is_alive"):
				alive = bool(_boss.call("is_alive"))
			_sync_boss_stats(_boss, false)
			if alive and _boss_hp > 0.0:
				boss_alive = true
		if boss_alive and _boss_hold > 0.0:
			_boss_hold = maxf(0.0, _boss_hold - delta)
			_boss_alpha = move_toward(_boss_alpha, 1.0, delta * 4.5)
		else:
			_boss_alpha = move_toward(_boss_alpha, 0.0, delta * 3.0)
		_boss_shown = lerpf(_boss_shown, clampf(_boss_hp / maxf(_boss_max, 1.0), 0.0, 1.0), clampf(delta * 8.0, 0.0, 1.0))

		if not _pops.is_empty() or _boss_alpha > 0.004:
			queue_redraw()

	func _draw() -> void:
		var cam := get_viewport().get_camera_3d()
		var f_head := UITheme.label_font()
		var f_eye := UITheme.eyebrow_font()

		# 1. Floating 2D Combat Damage Numbers
		for p in _pops:
			var age: float = float(p["age"])
			var t: float = clampf(age / POP_LIFE, 0.0, 1.0)
			var wpos: Vector3 = p["world_pos"]
			var spos := size * 0.5
			if cam != null:
				if cam.is_position_behind(wpos):
					continue
				spos = cam.unproject_position(wpos)
			var rise: float = (1.0 - pow(1.0 - t, 2.2)) * 46.0
			var alpha: float = clampf(1.0 - pow(t, 1.8), 0.0, 1.0)
			var is_crit: bool = bool(p["crit"])
			var fsize: int = UITheme.FS_HEAD if is_crit else UITheme.FS_LABEL
			var col: Color = Color(1.0, 0.86, 0.32, alpha) if is_crit else Color(0.95, 0.90, 0.80, alpha)
			var txt := String(p["text"])
			var tw := UITheme.text_width(f_head, txt, fsize)
			var draw_pos := Vector2(spos.x + float(p["jitter"]) - tw * 0.5, spos.y - rise)
			UITheme.draw_text(self, f_head, draw_pos, txt, fsize, col)

		# 2. Ornate Top-Center Boss Health Bar below the Compass
		if _boss_alpha > 0.01 and _boss_title != "":
			var bw := 460.0
			var bh := 10.0
			var bx: float = (size.x - bw) * 0.5
			var by := 112.0
			var ba := _boss_alpha

			var title_str := _boss_title.to_upper()
			var tw := UITheme.text_width(f_eye, title_str, UITheme.FS_TINY)
			UITheme.draw_text(
				self,
				f_eye,
				Vector2((size.x - tw) * 0.5, by - 10.0),
				title_str,
				UITheme.FS_TINY,
				Color(UITheme.SAFFRON_PALE.r, UITheme.SAFFRON_PALE.g, UITheme.SAFFRON_PALE.b, ba)
			)

			var bar_r := Rect2(Vector2(bx, by), Vector2(bw, bh))
			draw_rect(bar_r.grow(2.0), Color(0.03, 0.02, 0.02, 0.82 * ba), true)
			draw_rect(bar_r, Color(0.14, 0.05, 0.04, 0.88 * ba), true)
			var fill_w: float = bw * clampf(_boss_shown, 0.0, 1.0)
			if fill_w > 1.0:
				draw_rect(Rect2(bar_r.position, Vector2(fill_w, bh)), Color(0.78, 0.18, 0.14, 0.95 * ba), true)
				draw_rect(Rect2(bar_r.position, Vector2(fill_w, 3.0)), Color(0.96, 0.42, 0.28, 0.65 * ba), true)
			draw_rect(bar_r.grow(1.0), Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, 0.88 * ba), false, 1.2)

			for side in [-1.0, 1.0]:
				var cx: float = bx if side < 0.0 else (bx + bw)
				var cy: float = by + bh * 0.5
				draw_colored_polygon(
					PackedVector2Array([Vector2(cx, cy - 5), Vector2(cx + 5, cy), Vector2(cx, cy + 5), Vector2(cx - 5, cy)]),
					Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, ba)
				)
