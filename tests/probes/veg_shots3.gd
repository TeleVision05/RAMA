extends SceneTree
## Fast three-shot loop for judging canopy shading: the shot where the crown bleached
## (sun behind it, morning), the shot that was already right (low evening sun), and the
## close-up under the hero banyan. Same structure as vegetation_test, thirteen shots
## shorter, because a canopy tweak has to be checked against all three at once.
const OUT := "res://build/qa/%s.png"
const SHOTS := [
	{"n": "banyan_sun", "p": Vector2(-127, 71), "eye": 2.4, "t": Vector2(-105, 55), "tgt": 9.0, "h": 9.0},
	{"n": "backlit", "p": Vector2(-210, -10), "eye": 2.0, "t": Vector2(-260, -60), "tgt": 12.0, "h": 17.0},
	{"n": "banyan_under", "p": Vector2(-96, 47), "eye": 1.8, "t": Vector2(-108, 56), "tgt": 6.0, "h": 10.4},
]


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(false)
	var m := world.map
	var veg := Vegetation.new()
	root.add_child(veg)
	veg.setup(m, world.sky)
	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.far = 2000.0
	cam.near = 0.12
	root.add_child(cam)
	cam.current = true
	await process_frame
	for s in SHOTS:
		world.sky.paused = true
		world.sky.set_time(s.h)
		var eye := Vector3(s.p.x, m.height_at(s.p.x, s.p.y) + s.eye, s.p.y)
		cam.global_position = eye
		cam.look_at(Vector3(s.t.x, m.height_at(s.t.x, s.t.y) + s.tgt, s.t.y), Vector3.UP)
		world.terrain.update_focus(eye, true)
		veg.update_focus(eye, true)
		for i in range(34):
			await process_frame
		await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png(OUT % ("s3_" + s.n))
		print("shot %s tri %d" % [s.n, veg.stats().total_triangles])
	quit()
