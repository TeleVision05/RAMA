extends Node


## Save/load must round-trip the live world, not just the dictionary.
func _ready() -> void:
	_run()


func _run() -> void:
	var game := Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var fails: Array[String] = []
	var p := game.player
	p.lock_input(true)

	# Put the world into a distinctive state.
	var here := Vector3(150.0, 0.0, -66.0)
	here.y = game.world.map.height_at(here.x, here.z) + 0.2
	p.global_position = here
	p.facing_yaw = 1.234
	game.world.sky.set_time(19.75)
	GameState.health = 42.0
	GameState.arrows = 7
	GameState.add_item("temple_bell", 1)
	GameState.discover("shrine", "The Forgotten Shrine")
	GameState.set_flag("bell_returned", true)
	GameState.quests["forest_path"] = {"state": "active", "objectives": {"talk": 1, "investigate": 0}}
	await get_tree().physics_frame

	if not game.save_game(3):
		fails.append("save_game returned false")

	# Trash the live state, then load it back.
	GameState.reset()
	p.global_position = game.spawn_point()
	game.world.sky.set_time(6.0)
	await get_tree().physics_frame
	if not game.load_game(3):
		fails.append("load_game returned false")
	await get_tree().physics_frame
	await get_tree().physics_frame

	print("pos  %s (wanted ~%s)" % [p.global_position, here])
	print("time %.2f  health %.1f  arrows %d" % [game.world.sky.time_of_day, GameState.health, GameState.arrows])
	print("items %s  discovered %s  flags %s" % [GameState.inventory, GameState.discovered.keys(), GameState.flags])
	print("quests %s" % GameState.quests)

	if p.global_position.distance_to(here) > 1.5:
		fails.append("player position not restored (%s vs %s)" % [p.global_position, here])
	if absf(game.world.sky.time_of_day - 19.75) > 0.4:
		fails.append("time of day not restored (%.2f)" % game.world.sky.time_of_day)
	# Health regenerates out of combat, so a couple of frames after the load it will
	# have crept up; the assertion is that it came back near 42, not exactly at it.
	if absf(GameState.health - 42.0) > 1.5:
		fails.append("health not restored (%.2f)" % GameState.health)
	if GameState.arrows != 7:
		fails.append("arrows not restored")
	if GameState.item_count("temple_bell") != 1:
		fails.append("inventory not restored")
	if not GameState.discovered.has("shrine"):
		fails.append("discoveries not restored")
	if GameState.get_flag("bell_returned") != true:
		fails.append("flags not restored")
	if not GameState.quests.has("forest_path"):
		fails.append("quest state not restored")
	elif String(GameState.quests["forest_path"].get("state", "")) != "active":
		fails.append("quest state wrong after load")

	var summ := GameState.slot_summary(3)
	print("slot summary: %s" % summ)
	if summ.is_empty():
		fails.append("slot_summary returned nothing for a written slot")

	# A missing slot must fail cleanly, not crash.
	# Use a slot no other test touches, and make sure it is genuinely absent first —
	# a concurrently-running test had written slot 2 and made this assertion lie.
	var empty_slot := 7
	if GameState.has_slot(empty_slot):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.slot_path(empty_slot)))
	print("slot %d exists on disk: %s" % [empty_slot, GameState.has_slot(empty_slot)])
	if game.load_game(empty_slot):
		fails.append("loading an empty slot reported success")

	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)
