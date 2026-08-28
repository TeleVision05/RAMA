extends Node
## Drives the whole interface inside a running game and renders every screen.
##
##   tools/gd.sh scene res://scenes/ui_test.tscn
##
## Phase A boots the real title screen and photographs it. Phase B boots a real
## session (world + player + HUD), fires the events the HUD listens for, opens every
## panel, and checks that settings survive a round trip through disk and that saving
## then loading a slot really restores the world.
##
## Screenshots land in build/screenshots/ui_*.png — look at them, that is the point.

const OUT := "res://build/screenshots/%s.png"

var fails: Array[String] = []
var shots: Array[String] = []
var game: Game
var hud: HUD
var menu: MainMenu


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run()


func _run() -> void:
	_phase_pure()
	await _phase_title()
	await _phase_session()
	await _phase_launch()
	print("\n--- screenshots ---")
	for s in shots:
		print("  " + s)
	print("\nRESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)


# ==========================================================================
# phase 0 — the pure logic, before anything expensive is built
# ==========================================================================
## Formatters, bearings and generated icons. None of this needs a world, and all of
## it is the kind of thing that is wrong by an hour or by a sign for months because
## nobody looked closely at a screenshot of it.
func _phase_pure() -> void:
	print("\n=== phase 0: formatters, bearings, icons ===")

	# The clock has to carry, not just wrap the minutes.
	check(UITheme.clock(7.0) == "07:00", "clock(7.0) = %s" % UITheme.clock(7.0))
	check(UITheme.clock(19.25) == "19:15", "clock(19.25) = %s" % UITheme.clock(19.25))
	check(
		UITheme.clock(17.999) == "18:00", "clock(17.999) = %s, expected 18:00 (minute rounding must carry the hour)" % UITheme.clock(17.999)
	)
	check(UITheme.clock(23.999) == "00:00", "clock(23.999) = %s, expected 00:00" % UITheme.clock(23.999))
	check(UITheme.clock(24.5) == "00:30", "clock(24.5) = %s" % UITheme.clock(24.5))

	check(UITheme.duration(0.0) == "0 m 00 s", "duration(0) = %s" % UITheme.duration(0.0))
	check(UITheme.duration(189.0) == "3 m 09 s", "duration(189) = %s" % UITheme.duration(189.0))
	check(UITheme.duration(8040.0) == "2 h 14 m", "duration(8040) = %s" % UITheme.duration(8040.0))

	check(UITheme.prettify("hidden_grove") == "Hidden Grove", "prettify = %s" % UITheme.prettify("hidden_grove"))
	check(UITheme.prettify("the-forest-camp") == "The Forest Camp", "prettify = %s" % UITheme.prettify("the-forest-camp"))

	# Bearings are clockwise from north, and north is -Z.
	var o := Vector2.ZERO
	check(absf(Compass.bearing_to(o, Vector2(0, -10))) < 0.01, "north bearing is %.1f, expected 0" % Compass.bearing_to(o, Vector2(0, -10)))
	check(
		absf(Compass.bearing_to(o, Vector2(10, 0)) - 90.0) < 0.01,
		"east bearing is %.1f, expected 90" % Compass.bearing_to(o, Vector2(10, 0))
	)
	check(
		absf(Compass.bearing_to(o, Vector2(0, 10)) - 180.0) < 0.01,
		"south bearing is %.1f, expected 180" % Compass.bearing_to(o, Vector2(0, 10))
	)
	check(
		absf(Compass.bearing_to(o, Vector2(-10, 0)) - 270.0) < 0.01,
		"west bearing is %.1f, expected 270" % Compass.bearing_to(o, Vector2(-10, 0))
	)

	check(SaveMenu._phase_name(0.5) == "night", "phase(00:30) is not night")
	check(SaveMenu._phase_name(12.0) == "midday", "phase(12:00) is not midday")
	check(SaveMenu._phase_name(19.25) == "dusk", "phase(19:15) is not dusk")

	# Every icon the catalogue can ask for has to come back with ink on it. A shape
	# that evaluates to nothing is invisible in the satchel and looks like an engine
	# bug rather than a missing entry.
	var kinds := {}
	for id in InventoryPanel.CATALOGUE.keys():
		kinds[String(InventoryPanel.CATALOGUE[id].get("icon", "lotus"))] = true
	kinds["definitely_not_a_shape"] = true  # the fallback rosette
	var thinnest := 1.0
	var thinnest_kind := ""
	for k in kinds.keys():
		var tex := InventoryPanel.icon_texture(String(k), "brass")
		var img: Image = tex.get_image()
		var lit := 0
		for y in range(0, img.get_height(), 2):
			for x in range(0, img.get_width(), 2):
				if img.get_pixel(x, y).a > 0.5:
					lit += 1
		var cover: float = float(lit) / float((img.get_width() / 2) * (img.get_height() / 2))
		if cover < thinnest:
			thinnest = cover
			thinnest_kind = String(k)
		check(cover > 0.04, "icon '%s' covers only %.1f%% of its tile — it will read as empty" % [k, cover * 100.0])
		check(cover < 0.92, "icon '%s' covers %.1f%% of its tile — it is a filled square" % [k, cover * 100.0])
	print("  %d icon shapes drawn; thinnest is '%s' at %.1f%% coverage" % [kinds.size(), thinnest_kind, thinnest * 100.0])

	# An id no content system ever registered still has to produce a usable entry.
	var unknown := InventoryPanel._entry("moon_pearl", 2)
	check(String(unknown.name) == "Moon Pearl", "unknown item named '%s'" % unknown.name)
	check(String(unknown.desc) != "", "unknown item has no description")
	check(String(unknown.icon) != "", "unknown item has no icon")


# ==========================================================================
# phase A — the title screen
# ==========================================================================
func _phase_title() -> void:
	print("\n=== phase A: title screen ===")
	menu = MainMenu.new()
	menu.name = "MainMenu"
	add_child(menu)
	await frames(150)  # let the fade-up finish and the terrain stream in

	check(menu.cam != null and menu.cam.current, "title camera is not current")
	check(menu.world != null and menu.world.map != null, "title screen has no world")
	var btns := menu._buttons.get_children()
	check(btns.size() == 5, "expected 5 title buttons, got %d" % btns.size())
	var labels: Array[String] = []
	for b in btns:
		labels.append((b as Button).text)
	print("  buttons: %s" % [labels])
	check(labels.has("Continue") and labels.has("New Game") and labels.has("Quit"), "title buttons are missing an entry")

	# Continue must be dead until a save exists.
	_wipe_saves()
	menu._continue_btn.disabled = not menu._any_slot()
	check(menu._continue_btn.disabled, "Continue is enabled with no save on disk")

	await shot("ui_main_menu")

	# ... and alive once one does.
	GameState.day = 3
	GameState.save_to_slot(1)
	menu._continue_btn.disabled = not menu._any_slot()
	check(not menu._continue_btn.disabled, "Continue stayed disabled with a save present")
	check(menu._newest_slot() == 1, "newest slot lookup found %d, expected 1" % menu._newest_slot())

	# The title screen's own settings and load panels.
	menu._on_settings()
	await frames(6)
	check(menu._settings.visible and not menu._buttons.visible, "title settings panel did not take over the screen")
	await shot("ui_menu_settings")
	menu._settings._on_back()
	await frames(4)
	check(menu._buttons.visible, "title buttons did not come back after settings")

	menu._on_load()
	await frames(6)
	check(menu._loader.visible and menu._loader.mode == "load", "title load panel did not open in load mode")
	await shot("ui_menu_load")
	menu._loader.request_close()
	await frames(4)

	menu.queue_free()
	menu = null
	await frames(8)
	_wipe_saves()


# ==========================================================================
# phase B — a real session
# ==========================================================================
func _phase_session() -> void:
	print("\n=== phase B: in-game HUD ===")
	GameState.reset()
	game = Game.new()
	game.name = "Game"
	add_child(game)
	await frames(4)

	# The interface is not something a caller has to remember to bolt on. Booting a
	# Game the way `scenes/game.tscn` does must produce a playable screen, and it must
	# produce exactly one — two HUDs means two pause menus fighting over the paused
	# flag and the mouse mode.
	hud = game.hud as HUD
	check(hud != null, "Game booted without an interface (game.hud is null)")
	if hud == null:
		return
	check(_count_huds(get_tree().root) == 1, "%d HUDs in the tree, expected exactly 1" % _count_huds(get_tree().root))
	check(hud.layer == HUD.HUD_LAYER, "HUD is on canvas layer %d, expected %d" % [hud.layer, HUD.HUD_LAYER])
	check(hud.process_mode == Node.PROCESS_MODE_ALWAYS, "the HUD stops processing while the tree is paused, so its own menus freeze")
	await frames(60)

	check(hud.player == game.player, "HUD did not bind to the player")
	check(hud.cam_rig == game.cam, "HUD did not bind to the camera rig")

	# Every panel must fill the viewport. Setting anchors on a Control that is already
	# in the tree keeps its current (zero) rect, and the whole interface then draws
	# into a 0x0 box in the top-left corner while every assertion above still passes.
	var vp := get_viewport().get_visible_rect().size
	for named in [
		["inventory", hud.inventory],
		["journal", hud.journal],
		["pause", hud.pause_menu],
		["settings", hud.settings_menu],
		["save", hud.save_menu]
	]:
		var c: Control = named[1]
		check(
			c.size.x > vp.x * 0.9 and c.size.y > vp.y * 0.9,
			"the %s panel is %.0fx%.0f inside a %.0fx%.0f viewport" % [named[0], c.size.x, c.size.y, vp.x, vp.y]
		)

	await _test_hud_quiet()
	await _test_notifications()
	await _test_hud_loud()
	await _test_panels()
	await _test_settings_roundtrip()
	await _test_save_load()
	await _test_death()


func _test_hud_quiet() -> void:
	# Full health, nothing happening: the screen should be almost empty.
	GameState.health = GameState.max_health
	GameState.stamina = GameState.max_stamina
	hud.objective.set_line("")
	hud.notes.clear_all()
	await frames(40)
	await shot("ui_hud_quiet")
	check(hud.objective._shown == "", "objective line is showing with no quest")
	check(hud.crosshair._a < 0.05, "crosshair is visible while not aiming (a=%.2f)" % hud.crosshair._a)

	# The bars have to be legible as bars: a fill with no channel behind it is a
	# coloured stick you cannot read a proportion off. Take the same strip of the
	# framebuffer at full health and at a quarter, and require the *unfilled* part to
	# change — that is the track, and only the track, becoming visible.
	var strip := _bars_rect()
	var full := await _sample(strip)
	GameState.health = GameState.max_health * 0.25
	hud.bars.set_stats(GameState.health, GameState.max_health, GameState.stamina, GameState.max_stamina, true)
	await frames(30)
	var quarter := await _sample(strip)
	var delta: float = (full - quarter).length()
	print("  stat bar strip: full %s  quarter %s  delta %.3f" % [full, quarter, delta])
	check(
		delta > 0.02,
		"the stat bar strip is identical at full and quarter health (delta %.3f) — " % delta + "the bar has no readable extent"
	)
	# And the channel must be visible even where nothing is filled: sample the far
	# end of the health bar, which is empty at 25%.
	var tail_r := _bars_tail_rect()
	var tail := await _sample(tail_r)
	# The same patch of world, lifted clear of the bar, as the control.
	var world_here := await _sample(Rect2i(tail_r.position - Vector2i(0, 90), tail_r.size))
	check(
		(tail - world_here).length() > 0.015,
		(
			"the empty end of the health bar is indistinguishable from the world behind "
			+ "it (%s vs %s) — the track is not drawing" % [tail, world_here]
		)
	)
	GameState.health = GameState.max_health
	hud.bars.set_stats(GameState.health, GameState.max_health, GameState.stamina, GameState.max_stamina, true)
	await frames(20)


## Notifications: three on screen at once, the rest queued and admitted as room
## appears, and a repeat of the same headline collapsed rather than stacked.
func _test_notifications() -> void:
	print("  notification stack")
	hud.notes.mute = true
	hud.notes.clear_all()
	await frames(2)
	for i in range(7):
		hud.notes.push("Gained", "Arrow %d" % i, "item")
	await frames(4)
	check(
		hud.notes.visible_count() == Notifications.MAX_VISIBLE,
		"%d cards on screen, expected %d" % [hud.notes.visible_count(), Notifications.MAX_VISIBLE]
	)
	check(hud.notes.total_pushed() >= 7, "only %d pushes counted, expected 7" % hud.notes.total_pushed())

	# A duplicate headline folds into the live card instead of taking a slot.
	var before := hud.notes.visible_count()
	hud.notes.push("Gained", "Arrow 0", "item")
	await frames(2)
	check(hud.notes.visible_count() == before, "a duplicate notification took a new slot (%d -> %d)" % [before, hud.notes.visible_count()])

	# The queue has to drain on its own: cards hold, fade, and the next one is let in.
	var waited := 0.0
	while hud.notes.visible_count() > 0 and waited < 40.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	check(
		hud.notes.visible_count() == 0,
		"%d cards were still on screen after %.1f s — the queue never drained" % [hud.notes.visible_count(), waited]
	)
	print("    7 cards queued and drained in %.1f s" % waited)
	hud.notes.clear_all()
	hud.notes.mute = false
	await frames(2)


func _test_hud_loud() -> void:
	print("  driving the busy HUD state")
	hud.notes.mute = true

	# A quest, an objective, and a marker to point the compass at.
	GameState.quests["rescue_the_herd"] = {
		"state": "active",
		"objectives": {"find_the_tracks": 2, "drive_off_the_rakshasa": 0},
	}
	GameState.quests["bell_of_panchavati"] = {
		"state": "complete",
		"objectives": {"ring_the_bell": 1},
	}
	EventBus.quest_started.emit("rescue_the_herd")
	EventBus.quest_objective_changed.emit("rescue_the_herd", "find_the_tracks", 2, 5)
	await frames(4)
	check(hud.objective._shown.contains("Find The Tracks"), "objective line reads '%s'" % hud.objective._shown)
	check(hud.objective._shown.contains("(2/5)"), "objective line lost its progress: '%s'" % hud.objective._shown)

	hud.set_objective_marker(Vector3(WorldMap.P_SHRINE.x, 40.0, WorldMap.P_SHRINE.y), "Shrine")
	check(hud.compass.has_objective(), "compass took no objective marker")

	# Places found.
	GameState.discover("village", "Panchavati")
	GameState.discover("waterfall", "The Falls")
	GameState.discover("shrine", "Hilltop Shrine")
	await frames(4)
	check(hud.compass.place_count() >= 3, "compass has %d markers, expected at least 3" % hud.compass.place_count())

	# Items.
	GameState.add_item("healing_herb", 3)
	GameState.add_item("brass_bell", 1)
	GameState.add_item("gold_coin", 12)
	GameState.add_item("rakshasa_fang", 2)
	GameState.add_item("lotus", 1)
	GameState.add_item("moon_pearl", 1)  # deliberately unknown to the catalogue
	await frames(4)

	# An interactable prompt.
	EventBus.interact_target_changed.emit(self, "Ring the temple bell")
	# Hurt, from behind and to the left.
	GameState.health = 41.0
	EventBus.player_damaged.emit(26.0, game.player)
	hud.vignette.set_hit_direction(-2.2)
	hud.bars.flash_health()
	GameState.stamina = 42.0
	# Three notifications at once.
	EventBus.notify.emit("Location discovered", "The Falls", "discovery")
	EventBus.notify.emit("Quest started", "Rescue the Herd", "quest")
	EventBus.notify.emit("Gained", "Healing Herb x3", "item")
	EventBus.notify.emit("Objective complete", "Find the tracks", "objective")
	await frames(20)

	check(hud.notes.visible_count() <= 3, "%d notification cards on screen, max is 3" % hud.notes.visible_count())
	check(hud.prompt.text == "Ring the temple bell", "prompt text is '%s'" % hud.prompt.text)

	# Aim for real: the player overwrites `aiming` from the input map every physics
	# tick, so forcing the field would be measuring nothing.
	game.player.using_bow = true
	game.player.bow_node.visible = true
	game.player.sword_node.visible = false
	GameState.arrows = 17
	Input.action_press("aim")
	await pframes(32)
	print("    draw charge at the busy shot: %.2f" % game.player.draw_charge)
	check(game.player.aiming, "the player did not enter the aim state")
	check(game.player.draw_charge > 0.25 and game.player.draw_charge < 0.95, "expected a mid draw, got %.2f" % game.player.draw_charge)
	await shot("ui_hud_busy")

	# Full draw, so the crosshair is at its widest.
	await pframes(40)
	check(game.player.draw_charge >= 0.999, "the draw never completed (%.2f)" % game.player.draw_charge)
	await frames(10)
	await shot("ui_hud_full_draw")
	check(hud.crosshair._a > 0.9, "crosshair did not fade in while aiming (a=%.2f)" % hud.crosshair._a)
	var before := GameState.arrows
	Input.action_release("aim")
	await pframes(8)
	check(GameState.arrows == before - 1, "releasing a full draw did not spend an arrow (%d -> %d)" % [before, GameState.arrows])
	EventBus.interact_target_changed.emit(null, "")
	await frames(20)
	hud.notes.mute = false


func _test_panels() -> void:
	print("  opening every panel")
	# What the middle of the screen looks like with nothing over it, so each panel can
	# be required to actually cover it. A panel that lays out at 0x0 in the corner
	# still reports `visible`, still stacks, and still passes every state assertion.
	var mid := _centre_rect()
	var bare := await _sample(mid)

	# --- inventory --------------------------------------------------------
	hud.open_panel(hud.inventory)
	await frames(10)
	var over := await _sample(mid)
	print("    screen centre: bare %s  under a panel %s" % [bare, over])
	check(
		(bare - over).length() > 0.03,
		(
			"the inventory panel did not change the middle of the screen (%s vs %s) — " % [bare, over]
			+ "it is drawing somewhere other than where it says it is"
		)
	)
	check(hud.is_menu_open(), "inventory did not register as an open menu")
	check(get_tree().paused, "opening a panel did not pause the tree")
	check(hud._hud_alpha < 0.9, "the diegetic HUD did not start fading behind a panel")
	check(hud.inventory.entry_count() >= 7, "inventory shows %d entries, expected at least 7" % hud.inventory.entry_count())
	hud.inventory.select(3)
	await frames(30)
	await shot("ui_inventory")

	hud.close_top()
	await frames(8)
	check(not get_tree().paused, "closing the last panel left the tree paused")

	# --- journal ----------------------------------------------------------
	hud.open_panel(hud.journal)
	await frames(10)
	check(hud.journal.quest_count() >= 2, "journal lists %d quests, expected at least 2" % hud.journal.quest_count())
	check(hud.journal.place_count() >= 3, "journal lists %d places, expected at least 3" % hud.journal.place_count())
	await frames(20)
	await shot("ui_journal_quests")
	hud.journal.set_tab(JournalPanel.TAB_PLACES)
	await frames(16)
	await shot("ui_journal_places")
	hud.journal.set_tab(JournalPanel.TAB_QUESTS)
	hud.close_top()
	await frames(8)

	# --- pause and its children ------------------------------------------
	hud.open_panel(hud.pause_menu)
	await frames(16)
	await shot("ui_pause")
	check(hud.top_panel() == hud.pause_menu, "pause menu is not the top panel")

	hud.pause_menu.settings_requested.emit()
	await frames(20)
	check(hud.top_panel() == hud.settings_menu, "settings did not stack over pause")
	await shot("ui_settings")
	hud.settings_menu._on_back()
	await frames(10)
	check(hud.top_panel() == hud.pause_menu, "closing settings did not reveal pause")

	# Put real journeys in two of the slots so the cards have something to show.
	GameState.day = 2
	GameState.time_of_day = 6.8
	GameState.save_to_slot(0)
	GameState.day = 5
	GameState.time_of_day = 21.4
	GameState.save_to_slot(2)
	GameState.day = 1
	GameState.time_of_day = 7.4
	hud.save_menu.refresh()
	check(hud.save_menu.filled_slots() == 2, "expected 2 filled slots, got %d" % hud.save_menu.filled_slots())

	hud.pause_menu.save_requested.emit()
	await frames(16)
	check(hud.save_menu.mode == "save", "save menu opened in the wrong mode")
	await shot("ui_save")
	hud.save_menu.request_close()
	await frames(10)

	hud.pause_menu.load_requested.emit()
	await frames(16)
	check(hud.save_menu.mode == "load", "load menu opened in the wrong mode")
	await shot("ui_load")
	hud.save_menu.request_close()
	await frames(8)

	hud.close_all()
	await frames(10)
	check(not hud.is_menu_open(), "close_all left a panel open")
	check(not get_tree().paused, "close_all left the tree paused")


func _test_settings_roundtrip() -> void:
	print("  settings persistence")
	SettingsMenu.set_v("audio/music", 0.31)
	SettingsMenu.set_v("input/sensitivity", 2.15)
	SettingsMenu.set_v("input/invert_y", true)
	SettingsMenu.set_v("video/fov", 78.0)
	SettingsMenu.set_v("video/quality", 1)
	SettingsMenu.set_v("ui/show_prompts", false)
	SettingsMenu.save_config()
	SettingsMenu.apply(get_tree())
	await frames(8)

	# The camera really moved.
	var sens: float = float(game.cam.mouse_sensitivity)
	check(absf(sens - 0.0026 * 2.15) < 1e-6, "mouse sensitivity is %f, expected %f" % [sens, 0.0026 * 2.15])
	check(game.cam.invert_y, "invert_y did not reach the camera")
	# The field of view really moved.
	var fov: float = game.cam.cam.fov
	check(absf(fov - 78.0) < 3.0, "camera fov is %.1f, expected about 78" % fov)
	# The prompt toggle really took.
	check(not hud.prompt.enabled, "interaction prompts stayed on after being disabled")

	# Now prove it survived the file, not just the process.
	var reloaded := SettingsMenu.reload_from_disk()
	check(absf(float(reloaded["audio/music"]) - 0.31) < 0.001, "music volume did not persist: %s" % reloaded["audio/music"])
	check(absf(float(reloaded["input/sensitivity"]) - 2.15) < 0.001, "sensitivity did not persist: %s" % reloaded["input/sensitivity"])
	check(bool(reloaded["input/invert_y"]), "invert_y did not persist")
	check(int(reloaded["video/quality"]) == 1, "quality tier did not persist")
	check(not bool(reloaded["ui/show_prompts"]), "prompt toggle did not persist")
	print("    reloaded from disk: %s" % [reloaded])

	# Put things back so the remaining shots look right.
	SettingsMenu.reset_defaults()
	SettingsMenu.save_config()
	SettingsMenu.apply(get_tree())
	await frames(6)
	check(hud.prompt.enabled, "restoring defaults did not re-enable prompts")


func _test_save_load() -> void:
	print("  save / load round trip")
	var here := game.player.global_position
	GameState.day = 4
	GameState.time_of_day = 19.25
	GameState.player_position = here
	GameState.arrows = 9
	var ok := GameState.save_to_slot(2)
	check(ok, "GameState.save_to_slot(2) failed")

	var summary := GameState.slot_summary(2)
	check(not summary.is_empty(), "slot 2 summary came back empty")
	check(int(summary.get("day", 0)) == 4, "slot summary day is %s" % summary.get("day"))
	check(int(summary.get("discovered", 0)) >= 3, "slot summary discovered is %s" % summary.get("discovered"))
	check(int(summary.get("quests_done", 0)) >= 1, "slot summary quests_done is %s" % summary.get("quests_done"))
	print("    slot 2: %s" % [summary])

	# Wreck the state, then load it back.
	GameState.day = 99
	GameState.arrows = 0
	GameState.inventory.clear()
	GameState.discovered.clear()
	game.player.global_position = here + Vector3(40, 0, 40)
	await frames(4)

	check(GameState.load_from_slot(2), "GameState.load_from_slot(2) failed")
	await frames(10)
	check(GameState.day == 4, "day did not restore (%d)" % GameState.day)
	check(GameState.arrows == 9, "arrows did not restore (%d)" % GameState.arrows)
	check(GameState.inventory.size() >= 6, "inventory restored %d entries, expected at least 6" % GameState.inventory.size())
	check(GameState.discovered.size() >= 3, "discovered restored %d places, expected at least 3" % GameState.discovered.size())
	var back := game.player.global_position
	check(back.distance_to(here) < 1.5, "the player did not return to the saved position (%.1f m away)" % back.distance_to(here))
	check(absf(game.world.sky.time_of_day - 19.25) < 0.05, "time of day did not restore (%.2f)" % game.world.sky.time_of_day)
	check(hud.compass.place_count() == 3, "compass did not rebuild after a load (%d)" % hud.compass.place_count())
	check(not hud.is_menu_open(), "loading a save left a menu open")

	# Quick save / quick load use the same machinery — and quick save has to capture
	# the LIVE world, not whatever GameState was last left holding. Stand somewhere
	# new WITHOUT telling GameState, save, walk away, and load: if the key only wrote
	# the dictionary out, Rama comes back to the old position instead of this one.
	var spot := game.player.global_position + Vector3(18.0, 0.0, -14.0)
	spot.y = game.world.map.height_at(spot.x, spot.z) + 0.2
	game.player.global_position = spot
	GameState.arrows = 31
	await frames(2)
	hud.quick_save()
	await frames(2)
	GameState.arrows = 1
	game.player.global_position = spot + Vector3(60.0, 0.0, 60.0)
	await frames(2)
	hud.quick_load()
	await frames(8)
	check(GameState.arrows == 31, "quick load did not restore arrows (%d)" % GameState.arrows)
	var qback := game.player.global_position
	check(
		qback.distance_to(spot) < 1.5,
		"quick save wrote a stale position: came back %.1f m from where the key was " % qback.distance_to(spot) + "pressed"
	)

	# One press, one save. The Game used to poll the same key the HUD consumes, so a
	# single press wrote the slot twice and raised two toasts.
	hud.notes.clear_all()
	await frames(2)
	hud.quick_save()
	await frames(3)
	check(hud.notes.visible_count() == 1, "one quick save raised %d notification cards" % hud.notes.visible_count())

	await frames(30)
	await shot("ui_hud_after_load")


func _test_death() -> void:
	print("  death overlay")
	# An enemy can be mid-hit when this runs, and the player is briefly invulnerable
	# after any damage, so keep asking until it lands rather than assuming one blow.
	var tries := 0
	while not game.player.is_dead() and tries < 40:
		game.player.take_damage(999.0, null)
		await pframes(3)
		tries += 1
	check(game.player.is_dead(), "the player never died after %d blows" % tries)

	# Game revives Rama about 3.2 s later, so the overlay is measured on a wall clock
	# inside that window rather than on a frame count that drifts with the framerate.
	var died_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - died_at < 1300:
		await frames(1)
	var elapsed := Time.get_ticks_msec() - died_at
	print("    measured the death screen %d ms after the blow" % elapsed)
	check(hud._hud_alpha < 0.2, "the diegetic HUD stayed up over the death screen (a=%.2f)" % hud._hud_alpha)
	check(hud.death._a > 0.6, "death overlay had not risen after %d ms (a=%.2f)" % [elapsed, hud.death._a])
	await shot("ui_death")

	# Game respawns after a few seconds; the overlay has to let go on its own.
	var waited := 0
	while game.player.is_dead() and waited < 400:
		await frames(1)
		waited += 1
	print("    respawned after %d frames" % waited)
	if not game.player.is_dead():
		await frames(20)
		check(hud.death._a < 0.9, "death overlay did not release after the respawn (a=%.2f)" % hud.death._a)
	else:
		hud.death.clear()
	await frames(10)


# ==========================================================================
# phase C — the real hand-off from the title screen into a session
# ==========================================================================
func _phase_launch() -> void:
	print("\n=== phase C: launching a session ===")
	# Tear phase B down first: two worlds at once means two WorldEnvironments. The HUD
	# is a child of the Game now, so freeing the Game takes it with it.
	game.queue_free()
	hud = null
	game = null
	await frames(30)
	check(_count_huds(get_tree().root) == 0, "%d HUDs survived the teardown" % _count_huds(get_tree().root))

	# HUD.launch frees whatever the current scene is. This harness IS the current
	# scene, so hand that role to a stub and stay in the tree to watch.
	var stub := Node.new()
	stub.name = "SceneStub"
	get_tree().root.add_child(stub)
	get_tree().current_scene = stub
	await frames(2)

	var session := HUD.launch(get_tree())
	check(session != null, "HUD.launch returned nothing")
	await frames(120)
	check(get_tree().current_scene == session, "the launched session did not become the current scene")
	check(not is_instance_valid(stub), "launch did not free the scene it replaced")
	var g := session.get_node_or_null("Game")
	var h := session.get_node_or_null("HUD")
	check(g != null, "the launched session has no Game")
	check(h != null, "the launched session has no HUD")
	# The Game builds a HUD for itself; `launch` also provides one. Exactly one has to
	# survive that, or the session runs two pause menus over one world.
	check(_count_huds(session) == 1, "the launched session has %d HUDs, expected 1" % _count_huds(session))
	if g != null:
		check(g.get("hud") == h, "the Game built its own HUD instead of adopting the session's")
	if g != null and h != null:
		check(h.player == g.player, "the launched HUD did not bind to the player")
		check(h.cam_rig == g.cam, "the launched HUD did not bind to the camera")
		h.open_panel(h.journal)
		await frames(20)
		check(h.is_menu_open(), "the launched HUD could not open a panel")
		h.close_all()
		await frames(20)
	await shot("ui_launched_session")


# ==========================================================================
# helpers
# ==========================================================================
func check(cond: bool, msg: String) -> void:
	if not cond:
		fails.append(msg)
		print("    FAIL: " + msg)


func _count_huds(n: Node) -> int:
	var c := 1 if n is HUD else 0
	for k in n.get_children():
		c += _count_huds(k)
	return c


## Mean colour of a patch of the real framebuffer. Reading pixels is the only way to
## catch a widget that computes perfectly and draws nothing.
func _sample(r: Rect2i) -> Vector3:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		fails.append("could not read the framebuffer")
		return Vector3.ZERO
	var acc := Vector3.ZERO
	var n := 0
	for y in range(r.position.y, mini(r.end.y, img.get_height())):
		for x in range(r.position.x, mini(r.end.x, img.get_width())):
			var c := img.get_pixel(x, y)
			acc += Vector3(c.r, c.g, c.b)
			n += 1
	return acc / maxf(float(n), 1.0)


## The strip the health and stamina bars are drawn into. StatBars puts its origin at
## (46, height - 74) and the health bar runs 268 px from there.
func _bars_rect() -> Rect2i:
	var vp := get_viewport().get_visible_rect().size
	return Rect2i(38, int(vp.y) - 82, 290, 32)


## The far end of the health bar — empty whenever health is below about 90%.
func _bars_tail_rect() -> Rect2i:
	var vp := get_viewport().get_visible_rect().size
	return Rect2i(250, int(vp.y) - 80, 60, 12)


## A patch in the middle of the screen, where every full-screen panel must land.
func _centre_rect() -> Rect2i:
	var vp := get_viewport().get_visible_rect().size
	return Rect2i(int(vp.x * 0.5) - 60, int(vp.y * 0.5) - 40, 120, 80)


func frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func pframes(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		fails.append("screenshot %s came back null" % name)
		return
	var path: String = OUT % name
	var err := img.save_png(path)
	if err != OK:
		fails.append("could not write %s (err %d)" % [path, err])
		return
	# A screenshot that is one flat colour is a black frame, a frame captured before
	# anything drew, or a viewport that never resolved — all of which have been
	# mistaken for a working screen because the file existed and had the right size.
	var lo := Vector3(2, 2, 2)
	var hi := Vector3(-1, -1, -1)
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 7):
		for x in range(0, img.get_width(), 7):
			var c := img.get_pixel(x, y)
			var v := Vector3(c.r, c.g, c.b)
			lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
			hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
			sum += (v.x + v.y + v.z) / 3.0
			n += 1
	var spread: float = (hi - lo).length()
	var mean: float = sum / maxf(float(n), 1.0)
	if spread < 0.08:
		fails.append("%s is a flat frame (spread %.3f, mean luma %.3f)" % [name, spread, mean])
	shots.append("%s  %dx%d  luma %.3f  spread %.3f" % [path, img.get_width(), img.get_height(), mean, spread])


func _wipe_saves() -> void:
	for i in range(SaveMenu.SLOTS):
		var p := GameState.slot_path(i)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
