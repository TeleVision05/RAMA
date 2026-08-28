extends Node
## The intentional viewpoints. Each is a composed shot — foreground, midground and a
## distant silhouette — at the hour that flatters it. Rendered from a free camera so
## the framing is deliberate rather than wherever the gameplay camera happened to be.

const SHOTS := [
	{"n": "01_dawn_over_the_vale", "eye": Vector3(126, 62, 96), "look": Vector3(-70, 14, -30), "h": 6.4, "fov": 52.0},
	{"n": "02_village_morning", "eye": Vector3(-98, 20, 74), "look": Vector3(-126, 13, 44), "h": 8.1, "fov": 46.0},
	{"n": "03_the_ford", "eye": Vector3(-16, 12, 28), "look": Vector3(-44, 7, 2), "h": 9.6, "fov": 50.0},
	{"n": "04_forest_road", "eye": Vector3(-150, 26, 24), "look": Vector3(-196, 26, -30), "h": 10.4, "fov": 44.0},
	{"n": "05_the_falls", "eye": Vector3(74, 30, -158), "look": Vector3(36, 22, -194), "h": 12.0, "fov": 48.0},
	{"n": "06_shrine_at_noon", "eye": Vector3(206, 58, -34), "look": Vector3(158, 52, -66), "h": 12.6, "fov": 42.0},
	{"n": "07_ruins_afternoon", "eye": Vector3(-142, 42, -116), "look": Vector3(-170, 34, -150), "h": 15.2, "fov": 46.0},
	{"n": "08_lookout_sunset", "eye": Vector3(112, 78, -132), "look": Vector3(-30, 20, 20), "h": 18.1, "fov": 56.0},
	{"n": "09_village_dusk", "eye": Vector3(-104, 19, 66), "look": Vector3(-128, 13, 42), "h": 19.2, "fov": 44.0},
	{"n": "10_moonlit_river", "eye": Vector3(-52, 14, 40), "look": Vector3(-96, 7, 92), "h": 23.2, "fov": 50.0},
	{"n": "11_mountains_night", "eye": Vector3(20, 52, -60), "look": Vector3(24, 96, -250), "h": 1.4, "fov": 46.0},
	{"n": "12_hidden_grove", "eye": Vector3(-296, 40, 140), "look": Vector3(-322, 32, 118), "h": 9.0, "fov": 48.0},
]


func _ready() -> void:
	await get_tree().process_frame
	_run()


## Slide the eye back along the view direction until nothing is inside it.
func _clear_of_trees(game: Game, eye: Vector3, look: Vector3) -> Vector3:
	var solids: SolidStreamer = game.solids
	if solids == null:
		return eye
	var back := eye - look
	back.y = 0.0
	if back.length() < 0.01:
		return eye
	back = back.normalized()
	for step in range(0, 26):
		var q: Vector3 = eye + back * float(step) * 1.2
		q.y = maxf(q.y, game.world.map.height_at(q.x, q.z) + 1.6)
		var clear := true
		for i in range(solids._solids.size()):
			var sol = solids._solids[i]
			if sol.box != Vector3.ZERO:
				continue
			# Anything within this radius of the lens will fill the frame.
			if Vector2(sol.pos.x - q.x, sol.pos.z - q.z).length() < sol.radius + 3.4:
				clear = false
				break
		if clear:
			return q
	return eye


func _run() -> void:
	var game := Game.new()
	game.quality_tier = Quality.Tier.ULTRA
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	game.world.sky.paused = true

	var cam := Camera3D.new()
	cam.far = 2400.0
	cam.near = 0.10
	add_child(cam)
	cam.current = true

	for s in SHOTS:
		var eye: Vector3 = s.eye
		# Keep the camera above the ground whatever the terrain does under it.
		eye.y = maxf(eye.y, game.world.map.height_at(eye.x, eye.z) + 1.6)
		# ... and out of the trees. Several shots had a trunk or a leaf card filling the
		# frame because the eye happened to land inside a banyan.
		eye = _clear_of_trees(game, eye, s.look)
		# Stream the world around the SHOT, and stand Rama in the frame.
		p.global_position = Vector3(s.look.x, game.world.map.height_at(s.look.x, s.look.z) + 0.2, s.look.z)
		game.world.sky.set_time(s.h)
		game.world.terrain.update_focus(eye, true)
		for i in range(4):
			for n in [game.vegetation, game.vfx, game.wildlife, game.water, game.solids]:
				if n and n.has_method("update_focus"):
					n.update_focus(eye)
			await get_tree().physics_frame
		cam.fov = s.fov
		cam.look_at_from_position(eye, s.look, Vector3.UP)
		cam.current = true
		for i in range(46):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/cine_%s.png" % s.n)
		print("shot %s  t=%.1f" % [s.n, s.h])
	print("done")
	get_tree().quit()
