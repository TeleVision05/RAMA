extends Node
## QA: the four framings the review asks to be judged on, in the real world with real
## terrain, sky and lighting.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/qa3d_world.tscn
##
## `eye` and `look` are XZ offsets from `at`; their .y is METRES ABOVE THE GROUND AT
## THEIR OWN XZ, so a camera placed 0.12 m up is 0.12 m above the dirt it is standing
## on and not 0.12 m above wherever `at` happens to be.

## [name, at, eye offset, look offset, hour, fov] — a table rather than a dictionary
## per row purely so each row fits on one line and stays readable as a table.
const SHOTS := [
	# 1. Meadow at ankle height — the framing build/detail_sheet.png failed.
	["meadow_ankle", Vector2(-150, 80), Vector3(0, 0.12, 1.2), Vector3(-1, 0.10, -4.0), 10.5, 46.0],
	["meadow_ankle_sun", Vector2(-152, 86), Vector3(0, 0.14, 1.0), Vector3(-3, 0.16, -8.0), 17.4, 46.0],
	["meadow_stand", Vector2(-152, 86), Vector3(0, 1.62, 0.0), Vector3(-8, 1.0, -20.0), 11.0, 58.0],
	["true_meadow_ankle", Vector2(132, -204), Vector3(0, 0.13, 1.1), Vector3(-1, 0.11, -4.0), 10.5, 46.0],
	["true_meadow_stand", Vector2(132, -204), Vector3(0, 1.62, 0.0), Vector3(-8, 1.0, -20.0), 11.0, 58.0],
	# 2. The forest floor, which used to be a ground texture with cards standing on it.
	["forest_floor", Vector2(-206, -30), Vector3(0, 0.75, 1.6), Vector3(-2, 0.18, -6.0), 12.5, 48.0],
	["forest_ankle", Vector2(-232, 10), Vector3(0, 0.13, 1.0), Vector3(-2, 0.20, -5.0), 13.0, 44.0],
	["forest_wide", Vector2(-214, -18), Vector3(0, 1.65, 0.0), Vector3(-6, 1.4, -18.0), 12.0, 62.0],
	# 3. Canopy from directly below.
	["canopy_under", Vector2(-206, -30), Vector3(0, 1.5, 0.0), Vector3(0.6, 14.0, 0.4), 12.0, 68.0],
	["canopy_under2", Vector2(-196, -34), Vector3(0, 1.5, 0.0), Vector3(-0.5, 12.0, 1.0), 13.5, 68.0],
	# 4. A tree in silhouette against the sky.
	["tree_silhouette", Vector2(-186, -40), Vector3(0, 2.0, 14.0), Vector3(0, 7.0, -2.0), 17.9, 40.0],
	["tree_silhouette2", Vector2(-120, 44), Vector3(0, 1.4, 16.0), Vector3(0, 8.0, -2.0), 6.4, 38.0],
	# Context: does the cover read at the distance the game is actually played at?
	["village_play", Vector2(-124, 50), Vector3(0, 2.6, 5.0), Vector3(-3, 0.8, -12.0), 10.0, 55.0],
	["badlands", Vector2(214, 178), Vector3(0, 1.7, 0.0), Vector3(-8, 1.2, -18.0), 11.5, 58.0],
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
	var m: WorldMap = game.world.map

	for s in SHOTS:
		var at: Vector2 = s[1]
		var g := m.height_at(at.x, at.y)
		game.world.sky.set_time(s[4])
		cam.fov = s[5]
		p.global_position = Vector3(at.x, g + 0.2, at.y)
		game.world.terrain.update_focus(p.global_position, true)
		for i in range(6):
			game.vegetation.update_focus(p.global_position, true)
			for n in [game.vfx, game.wildlife, game.solids]:
				if n and n.has_method("update_focus"):
					n.update_focus(p.global_position)
			await get_tree().physics_frame
		var eo: Vector3 = s[2]
		var lo: Vector3 = s[3]
		var eye := Vector3(at.x + eo.x, m.height_at(at.x + eo.x, at.y + eo.z) + eo.y, at.y + eo.z)
		var tgt := Vector3(at.x + lo.x, m.height_at(at.x + lo.x, at.y + lo.z) + lo.y, at.y + lo.z)
		cam.look_at_from_position(eye, tgt, Vector3.UP)
		for i in range(30):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/qw_%s.png" % s[0])
		var st: Dictionary = game.vegetation.stats()
		print(
			(
				"%-20s cover inst %5d tri %7d  layers %s  cells %2d nodes %3d"
				% [s[0], st.grass_instances, st.grass_triangles, str(st.cover_by_layer), st.grass_cells, st.draw_nodes]
			)
		)
	print("done")
	get_tree().quit()
