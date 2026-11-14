extends Node


## Photograph each enemy archetype beside Rama for scale.
func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	var decoy := Node.new()
	get_tree().root.add_child(decoy)
	get_tree().current_scene = decoy
	var session := HUD.launch(get_tree())
	var game: Game = session.get_node("Game")
	for i in range(70):
		await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	game.world.sky.paused = true
	game.world.sky.set_time(11.0)
	var open := Vector2(-150.0, 84.0)
	p.global_position = Vector3(open.x, game.world.map.height_at(open.x, open.y) + 0.15, open.y)
	p.facing_yaw = 0.0
	game.cam.yaw = 0.0
	game.world.terrain.update_focus(p.global_position, true)
	for i in range(40):
		await get_tree().process_frame

	var dir: Node = game.enemies
	print("director: %s  spawn_group=%s" % [dir, dir.has_method("spawn_group") if dir else false])
	var kinds := []
	if dir and dir.has_method("spawn_group"):
		for k in range(4):
			var pos := Vector3(open.x + 4.0, 0, open.y - 6.0 - float(k) * 0.0)
			pos.y = game.world.map.height_at(pos.x, pos.z)
			var got: Array = dir.call("spawn_group", k, pos, 1)
			if not got.is_empty():
				kinds.append(got[0])
	print("spawned %d archetypes" % kinds.size())

	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 38.0
	cam.current = true
	for i in range(kinds.size()):
		var e: Node3D = kinds[i]
		if not is_instance_valid(e):
			continue
		# Stand Rama beside it for scale.
		var ep: Vector3 = e.global_position
		p.global_position = ep + Vector3(1.9, 0.1, 0.0)
		if e.has_method("set_focus_distance"):
			e.call("set_focus_distance", 3.0, 0)
		if e.has_method("wants_build") and e.call("wants_build"):
			e.call("build_visual")
		game.world.terrain.update_focus(ep, true)
		for f in range(50):
			await get_tree().process_frame
		var mid: Vector3 = (ep + p.global_position) * 0.5 + Vector3(0, 1.0, 0)
		cam.look_at_from_position(mid + Vector3(0.6, 0.7, 5.2), mid, Vector3.UP)
		for f in range(12):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var nm: String = e.call("display_name") if e.has_method("display_name") else "kind%d" % i
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/enemy_%d.png" % i)
		print("enemy_%d = %s  state=%s hp=%s" % [i, nm, e.call("state_name") if e.has_method("state_name") else "?", e.get("health")])
	print("done")
	get_tree().quit()
