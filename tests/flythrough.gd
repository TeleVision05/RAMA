extends SceneTree
## Renders the world from fixed viewpoints so composition and lighting can actually be
## LOOKED at. Camera heights are relative to the GROUND, never absolute, so a shot can
## never end up buried inside a hill.

const SHOTS := [
	{"n": "village", "p": Vector2(-120, 96), "eye": 6.0, "t": Vector2(-120, 44), "tgt": 2.0, "h": 8.2},
	{"n": "ford", "p": Vector2(-4, 40), "eye": 4.0, "t": Vector2(-40, 4), "tgt": 0.5, "h": 16.0},
	{"n": "shrine", "p": Vector2(96, -6), "eye": 5.0, "t": Vector2(158, -66), "tgt": 14.0, "h": 9.4},
	{"n": "falls", "p": Vector2(64, -150), "eye": 8.0, "t": Vector2(34, -196), "tgt": 14.0, "h": 11.0},
	{"n": "forest", "p": Vector2(-150, 6), "eye": 3.0, "t": Vector2(-196, -34), "tgt": 2.0, "h": 15.0},
	{"n": "valley_dusk", "p": Vector2(150, 130), "eye": 70.0, "t": Vector2(-60, -40), "tgt": 10.0, "h": 18.3},
	{"n": "night", "p": Vector2(-120, 92), "eye": 5.0, "t": Vector2(-120, 44), "tgt": 2.0, "h": 23.0},
	{"n": "dawn_mtn", "p": Vector2(10, 40), "eye": 30.0, "t": Vector2(24, -220), "tgt": 60.0, "h": 6.3},
	{"n": "ruins", "p": Vector2(-168, -100), "eye": 5.0, "t": Vector2(-168, -148), "tgt": 2.0, "h": 10.5},
	{"n": "badlands", "p": Vector2(180, 140), "eye": 8.0, "t": Vector2(214, 178), "tgt": 6.0, "h": 16.8},
]


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(true)
	var m := world.map

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
		var tgt := Vector3(s.t.x, m.height_at(s.t.x, s.t.y) + s.tgt, s.t.y)
		cam.global_position = eye
		cam.look_at(tgt, Vector3.UP)
		world.terrain.update_focus(eye, true)
		for i in range(12):
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://build/screenshots/fly_%s.png" % s.n)
		print("%-12s eye=%.1f,%.1f,%.1f" % [s.n, eye.x, eye.y, eye.z])
	print("done")
	quit()
