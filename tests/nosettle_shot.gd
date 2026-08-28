extends SceneTree


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(false)
	var m := world.map
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.far = 2000.0
	root.add_child(cam)
	cam.current = true
	await process_frame
	world.sky.paused = true
	world.sky.set_time(16.0)
	var eye := Vector3(130, m.height_at(130, -100) + 3.0, -100)
	cam.global_position = eye
	cam.look_at(Vector3(154, m.height_at(154, -78.5) + 10.0, -78.5), Vector3.UP)
	world.terrain.update_focus(eye, true)
	for i in range(12):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/screenshots/nosettle_shrine_road.png")
	print("done")
	quit()
