extends Node


## End-to-end: launch exactly as a player does — main menu, New Game, then play.
## This is the test that proves the shipped entry point works, not just the systems.
func _ready() -> void:
	# One frame of slack: the tree root is still setting up children during _ready.
	await get_tree().process_frame
	_run()


func _run() -> void:
	var fails: Array[String] = []
	var menu_scene: PackedScene = load("res://scenes/main_menu.tscn")
	if menu_scene == null:
		print("RESULT: FAIL")
		print("  ! main_menu.tscn will not load")
		get_tree().quit(1)
		return
	# HUD.launch() replaces and FREES tree.current_scene. Hand that role to a decoy
	# node so the launch frees the decoy instead of this test, and keep the menu as a
	# child of the test where it builds normally.
	var decoy := Node.new()
	decoy.name = "SceneSlot"
	get_tree().root.add_child(decoy)
	get_tree().current_scene = decoy
	var menu := menu_scene.instantiate()
	add_child(menu)
	for i in range(40):
		await get_tree().process_frame
	print("menu up: %s  children=%d" % [menu.name, menu.get_child_count()])
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://build/screenshots/boot_menu.png")

	# Drive "New Game" the way the button does.
	if not menu.has_method("_on_new_game"):
		fails.append("main menu has no _on_new_game")
	else:
		menu.call("_on_new_game")
	# The menu fades for ~1.1 s before handing over.
	for i in range(140):
		await get_tree().process_frame

	if is_instance_valid(menu):
		menu.queue_free()
		await get_tree().process_frame
	var session := get_tree().current_scene
	print("current scene after New Game: %s" % (session.name if session else "<null>"))
	var game: Node = session.get_node_or_null("Game") if session else null
	var hud: Node = session.get_node_or_null("HUD") if session else null
	if game == null:
		fails.append("no Game node after starting a new game")
	if hud == null:
		fails.append("no HUD node after starting a new game")

	if game:
		for i in range(60):
			await get_tree().physics_frame
		var p: Node = game.get("player")
		if p == null:
			fails.append("Game has no player")
		else:
			var before: Vector3 = p.global_position
			Input.action_press("move_forward")
			for i in range(80):
				await get_tree().physics_frame
			Input.action_release("move_forward")
			var moved: float = before.distance_to(p.global_position)
			print("player moved %.2f m from the menu-started session" % moved)
			if moved < 2.0:
				fails.append("player barely moved after a menu start (%.2f m)" % moved)
			print(
				(
					"world content: enemies=%d npcs=%d interactables=%d"
					% [
						get_tree().get_nodes_in_group("enemy").size(),
						get_tree().get_nodes_in_group("npc").size(),
						get_tree().get_nodes_in_group("interactable").size()
					]
				)
			)
			if get_tree().get_nodes_in_group("enemy").is_empty():
				fails.append("no enemies in the world")
			if get_tree().get_nodes_in_group("npc").is_empty():
				fails.append("no NPCs in the world")
		for i in range(20):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/boot_play.png")

	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)
