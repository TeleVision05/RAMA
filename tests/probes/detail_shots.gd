extends Node


## Close-ups of the things that read as flat. Baseline for the 3D overhaul.
func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	var game := Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	game.world.sky.paused = true
	game.world.sky.set_time(11.0)

	var cam := Camera3D.new()
	cam.fov = 34.0
	cam.near = 0.05
	add_child(cam)
	cam.current = true

	# Stand in the forest, then look at things from very close.
	var spots := [
		{"n": "leaves_close", "at": Vector2(-196, -20), "eye": Vector3(0, 6.5, 5.0), "look": Vector3(0, 6.0, 0)},
		{"n": "canopy_under", "at": Vector2(-196, -20), "eye": Vector3(0, 2.0, 3.0), "look": Vector3(0, 9.0, -2)},
		{"n": "grass_close", "at": Vector2(-150, 80), "eye": Vector3(0, 0.55, 1.6), "look": Vector3(0, 0.18, -0.6)},
		{"n": "flowers_close", "at": Vector2(-150, 80), "eye": Vector3(0, 0.5, 1.2), "look": Vector3(0, 0.15, -0.8)},
		{"n": "bush_close", "at": Vector2(-180, 40), "eye": Vector3(0, 1.2, 2.6), "look": Vector3(0, 0.7, 0)},
	]
	for s in spots:
		var at: Vector2 = s.at
		var g := game.world.map.height_at(at.x, at.y)
		p.global_position = Vector3(at.x, g + 0.2, at.y)
		game.world.terrain.update_focus(p.global_position, true)
		for i in range(6):
			for n in [game.vegetation, game.vfx, game.wildlife, game.solids]:
				if n and n.has_method("update_focus"):
					n.update_focus(p.global_position)
			await get_tree().physics_frame
		var base := Vector3(at.x, g, at.y)
		cam.look_at_from_position(base + s.eye, base + s.look, Vector3.UP)
		for i in range(26):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/det_%s.png" % s.n)
		print("shot det_%s" % s.n)
	print("done")
	get_tree().quit()
