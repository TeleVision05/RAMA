extends Node


func _ready() -> void:
	_run()


func _run() -> void:
	var game := Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	p.lock_input(true)
	# Stand on clear high ground away from roads and look at Rama from several angles.
	var pos := Vector2(-150.0, 70.0)
	p.global_position = Vector3(pos.x, game.world.map.height_at(pos.x, pos.y) + 0.1, pos.y)
	game.world.sky.paused = true
	game.world.sky.set_time(10.0)
	game.world.terrain.update_focus(p.global_position, true)
	print("player at %s  visible=%s  rig children=%d" % [p.global_position, p.visible, p.rig.get_child_count()])
	print("rig aabb: hips=%s head=%s" % [p.rig.hips.global_position, p.rig.head.global_position])

	# A dedicated camera so nothing about the gameplay camera can hide him.
	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 38.0
	cam.current = true
	var angles := [0.0, 2.2, 4.1]
	for i in range(angles.size()):
		var a: float = angles[i]
		var eye := p.global_position + Vector3(sin(a) * 3.2, 1.35, cos(a) * 3.2)
		cam.look_at_from_position(eye, p.global_position + Vector3(0, 0.95, 0), Vector3.UP)
		for f in range(14):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/pv_%d.png" % i)
		print("pv_%d from %s" % [i, eye])
	get_tree().quit()
