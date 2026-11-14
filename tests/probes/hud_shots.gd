extends Node


## Photograph the running session WITH the HUD, in the situations the HUD exists for.
func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	var decoy := Node.new()
	get_tree().root.add_child(decoy)
	get_tree().current_scene = decoy
	var session := HUD.launch(get_tree())
	var game: Game = session.get_node("Game")
	var hud: Node = session.get_node("HUD")
	for i in range(60):
		await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	game.world.sky.paused = true

	var shots := [
		{"n": "hud_village", "p": Vector2(-124, 52), "yaw": 2.4, "h": 9.5, "act": "none"},
		{"n": "hud_aim", "p": Vector2(-150, 20), "yaw": 1.1, "h": 11.0, "act": "aim"},
		{"n": "hud_hurt", "p": Vector2(-120, 44), "yaw": 2.2, "h": 15.0, "act": "hurt"},
		{"n": "hud_notify", "p": Vector2(158, -66), "yaw": 0.6, "h": 17.5, "act": "notify"},
		{"n": "hud_night", "p": Vector2(-120, 50), "yaw": 2.3, "h": 23.0, "act": "none"},
	]
	for s in shots:
		var gy: float = game.world.map.height_at(s.p.x, s.p.y)
		p.global_position = Vector3(s.p.x, gy + 0.15, s.p.y)
		p.velocity = Vector3.ZERO
		p.facing_yaw = s.yaw
		game.cam.yaw = s.yaw
		game.cam.pitch = -0.08
		game.world.sky.set_time(s.h)
		game.world.terrain.update_focus(p.global_position, true)
		match s.act:
			"aim":
				p.lock_input(false)
				Input.action_press("aim")
				for i in range(70):
					await get_tree().physics_frame
			"hurt":
				p.take_damage(38.0, null)
				GameState.stamina = 22.0
			"notify":
				EventBus.notify.emit("Location discovered", "The Forgotten Shrine", "discover")
				EventBus.quest_objective_changed.emit("shrine", "inspect", 0, 1)
				if hud.has_method("set_objective_text"):
					hud.call("set_objective_text", "Read the inscription on the plinth")
		for i in range(30):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/%s.png" % s.n)
		print("shot %s" % s.n)
		if s.act == "aim":
			Input.action_release("aim")
			p.lock_input(true)
			await get_tree().physics_frame
	print("done")
	get_tree().quit()
