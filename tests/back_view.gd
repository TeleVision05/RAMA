extends Node


## Camera BEHIND the player, walking away. This is the view the game actually gives you,
## and the one that exposed the body being modelled front-at-+Z.
func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	var game := Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = game.player
	game.world.sky.paused = true
	game.world.sky.set_time(11.0)
	var at := Vector2(-150.0, 86.0)
	p.global_position = Vector3(at.x, game.world.map.height_at(at.x, at.y) + 0.15, at.y)
	p.facing_yaw = 0.0
	p.rotation.y = 0.0
	game.world.terrain.update_focus(p.global_position, true)
	var cam := Camera3D.new()
	cam.fov = 34.0
	add_child(cam)
	cam.current = true
	p.lock_input(true)
	for i in range(30):
		await get_tree().physics_frame
	# Walk so the gait is mid-stride.
	p.lock_input(false)
	Input.action_press("move_forward")
	for i in range(45):
		await get_tree().physics_frame
	# forward is -Z, so BEHIND is +Z.
	var b := p.global_position
	cam.look_at_from_position(b + Vector3(0.5, 1.5, 3.4), b + Vector3(0, 1.0, 0), Vector3.UP)
	for i in range(10):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://build/screenshots/back_walk.png")
	Input.action_release("move_forward")
	print("saved back_walk")
	get_tree().quit()
