extends Node


## Photograph a real conversation with a villager, and the interaction prompt.
func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	var decoy := Node.new()
	get_tree().root.add_child(decoy)
	get_tree().current_scene = decoy
	var session := HUD.launch(get_tree())
	var game: Game = session.get_node("Game")
	for i in range(80):
		await get_tree().process_frame
	var p: Player = game.player
	game.world.sky.paused = true
	game.world.sky.set_time(9.5)

	var npcs := get_tree().get_nodes_in_group("npc")
	print("npcs: %d" % npcs.size())
	var shot := 0
	for n in npcs:
		if shot >= 3:
			break
		if not is_instance_valid(n):
			continue
		var np: Node3D = n
		# Stand in front of them, facing them.
		var away := Vector3(1.6, 0, 1.2)
		p.global_position = np.global_position + away
		p.global_position.y = game.world.map.height_at(p.global_position.x, p.global_position.z) + 0.15
		var to := np.global_position - p.global_position
		p.facing_yaw = atan2(-to.x, -to.z)
		game.cam.yaw = p.facing_yaw
		game.cam.pitch = -0.02
		game.world.terrain.update_focus(p.global_position, true)
		for i in range(40):
			await get_tree().physics_frame
		# The prompt should be up now.
		for i in range(14):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/talk_%d_prompt.png" % shot)
		if np.has_method("interact"):
			np.call("interact", p)
		for i in range(90):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/talk_%d_line.png" % shot)
		print("talk_%d with %s" % [shot, np.name])
		# Advance to a choice node if there is one.
		var dlg: Node = null
		for cand in get_tree().get_nodes_in_group("dialogue_system"):
			dlg = cand
		if dlg == null and game.npcs:
			dlg = game.npcs.get("dialogue")
		if dlg and dlg.has_method("advance"):
			for k in range(3):
				dlg.call("advance")
				for i in range(60):
					await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://build/screenshots/talk_%d_choice.png" % shot)
		if dlg and dlg.has_method("cancel"):
			dlg.call("cancel")
		p.lock_input(false)
		await get_tree().physics_frame
		shot += 1
	print("done")
	get_tree().quit()
