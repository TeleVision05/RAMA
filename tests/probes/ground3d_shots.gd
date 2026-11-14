extends Node
## The ground cover photographed in the real world — real terrain, real sky, real
## lighting — at the framings the brief asks to be judged on, plus the two from
## build/detail_sheet.png so the before and after can be put side by side.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/ground3d_shots.tscn

## `eye` and `look` are XZ offsets from `at`, with .y read as METRES ABOVE THE GROUND
## AT THEIR OWN XZ. Taking both heights from the ground under `at` put the camera
## inside the terrain in four of eleven shots on the first pass, and a shot you cannot
## trust is worse than no shot.
const SHOTS := [
	# The money shot: camera down among the blades, looking along the ground.
	{"n": "grass_ankle", "at": Vector2(-150, 80), "eye": Vector3(0, 0.16, 1.1), "look": Vector3(-1, 0.14, -3.0), "h": 11.0, "fov": 42.0},
	{"n": "grass_wade", "at": Vector2(-150, 80), "eye": Vector3(0, 1.62, 0.0), "look": Vector3(-3, 0.15, -7.0), "h": 10.0, "fov": 55.0},
	{"n": "grass_close", "at": Vector2(-150, 80), "eye": Vector3(0, 0.55, 1.6), "look": Vector3(0, 0.10, -0.6), "h": 11.0},
	{"n": "flowers_close", "at": Vector2(-150, 80), "eye": Vector3(0, 0.5, 1.2), "look": Vector3(0, 0.08, -0.8), "h": 11.0},
	{"n": "flowers_macro", "at": Vector2(-146, 74), "eye": Vector3(0, 0.34, 1.5), "look": Vector3(0, 0.26, -1.2), "h": 10.0, "fov": 24.0},
	{"n": "flowers_bed", "at": Vector2(-100, 4), "eye": Vector3(0, 0.60, 2.2), "look": Vector3(0, 0.22, -3.0), "h": 9.5, "fov": 38.0},
	{"n": "meadow_noon", "at": Vector2(-152, 86), "eye": Vector3(0, 1.60, 0.0), "look": Vector3(-10, 1.2, -22.0), "h": 12.0, "fov": 58.0},
	{"n": "meadow_golden", "at": Vector2(-152, 86), "eye": Vector3(0, 1.60, 0.0), "look": Vector3(-10, 1.2, -22.0), "h": 17.6, "fov": 58.0},
	{
		"n": "meadow_low_golden",
		"at": Vector2(-150, 80),
		"eye": Vector3(0, 0.30, 1.2),
		"look": Vector3(-4, 0.35, -9.0),
		"h": 17.8,
		"fov": 48.0
	},
	{"n": "forest_floor", "at": Vector2(-206, -30), "eye": Vector3(0, 0.80, 1.6), "look": Vector3(-2, 0.20, -6.0), "h": 12.5, "fov": 48.0},
	{
		"n": "forest_floor_low",
		"at": Vector2(-232, 10),
		"eye": Vector3(0, 0.30, 1.0),
		"look": Vector3(-2, 0.22, -5.0),
		"h": 13.0,
		"fov": 44.0
	},
	{"n": "cover_edgeon", "at": Vector2(-150, 80), "eye": Vector3(0, 0.09, 0.9), "look": Vector3(0, 0.09, -3.0), "h": 15.0, "fov": 34.0},
	{"n": "band_handover", "at": Vector2(-152, 86), "eye": Vector3(0, 1.1, 0.0), "look": Vector3(0, 0.2, -34.0), "h": 12.0, "fov": 50.0},
]


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	var game := Game.new()
	game.spawn_hud = false
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	p.visible = false
	game.world.sky.paused = true

	var cam := Camera3D.new()
	cam.near = 0.02
	add_child(cam)
	cam.current = true

	for s in SHOTS:
		var at: Vector2 = s.at
		var g := game.world.map.height_at(at.x, at.y)
		game.world.sky.set_time(s.h)
		cam.fov = s.get("fov", 34.0)
		p.global_position = Vector3(at.x, g + 0.2, at.y)
		game.world.terrain.update_focus(p.global_position, true)
		for i in range(4):
			game.vegetation.update_focus(p.global_position, true)
			for n in [game.vfx, game.wildlife, game.solids]:
				if n and n.has_method("update_focus"):
					n.update_focus(p.global_position)
			await get_tree().physics_frame
		var eo: Vector3 = s.eye
		var lo: Vector3 = s.look
		var m: WorldMap = game.world.map
		var eye := Vector3(at.x + eo.x, m.height_at(at.x + eo.x, at.y + eo.z) + eo.y, at.y + eo.z)
		var tgt := Vector3(at.x + lo.x, m.height_at(at.x + lo.x, at.y + lo.z) + lo.y, at.y + lo.z)
		cam.look_at_from_position(eye, tgt, Vector3.UP)
		for i in range(30):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/gc_%s.png" % s.n)
		var st: Dictionary = game.vegetation.stats()
		print(
			(
				"%-18s cover inst %5d tri %6d  by layer inst %s tri %s  cells %d nodes %d"
				% [
					s.n,
					st.grass_instances,
					st.grass_triangles,
					str(st.cover_by_layer),
					str(st.cover_tris_by_layer),
					st.grass_cells,
					st.draw_nodes
				]
			)
		)
	print("done")
	get_tree().quit()
