extends Node
## QA: does the new foliage hold up IN THE WORLD?
##
## The first three spots are byte-for-byte the framings that produced the "before"
## evidence in build/detail_sheet.png, so before and after are comparable. The rest are
## the views the QA brief asks for: the forest, a meadow at ankle height, a canopy from
## directly below, and a tree in silhouette against the sky.
##
## spawn_hud = false, per ARCHITECTURE — a HUD in a measurement harness can open its
## own pause menu mid-capture and dim the whole viewport.

var _game: Game
var _cam: Camera3D


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _settle(p: Player, pos: Vector3, frames: int = 8) -> void:
	p.global_position = pos
	_game.world.terrain.update_focus(pos, true)
	for i in range(frames):
		for n in [_game.vegetation, _game.vfx, _game.wildlife, _game.solids]:
			if n and n.has_method("update_focus"):
				n.update_focus(pos)
		await get_tree().physics_frame


func _run() -> void:
	_game = Game.new()
	_game.spawn_hud = false
	add_child(_game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = _game.player
	p.lock_input(true)
	_game.world.sky.paused = true
	_game.world.sky.set_time(11.0)

	_cam = Camera3D.new()
	_cam.fov = 34.0
	_cam.near = 0.05
	_cam.far = 900.0
	add_child(_cam)
	_cam.current = true

	var spots := [
		# --- the three framings from the BEFORE sheet, unchanged ---
		{"n": "leaves_close", "at": Vector2(-196, -20), "eye": Vector3(0, 6.5, 5.0), "look": Vector3(0, 6.0, 0)},
		{"n": "canopy_under", "at": Vector2(-196, -20), "eye": Vector3(0, 2.0, 3.0), "look": Vector3(0, 9.0, -2)},
		{"n": "bush_close", "at": Vector2(-180, 40), "eye": Vector3(0, 1.2, 2.6), "look": Vector3(0, 0.7, 0)},
		# --- the QA brief's views ---
		{"n": "forest_wide", "at": Vector2(-200, -40), "eye": Vector3(0, 12.0, 30.0), "look": Vector3(0, 8.0, -22.0)},
		{"n": "forest_eye", "at": Vector2(-198, -30), "eye": Vector3(0, 1.7, 0.0), "look": Vector3(0, 2.4, -26.0)},
		{"n": "meadow_ankle", "at": Vector2(-150, 80), "eye": Vector3(0, 0.22, 1.4), "look": Vector3(0, 0.30, -9.0)},
		{"n": "canopy_straight_up", "at": Vector2(-196, -20), "eye": Vector3(0, 1.7, 0.0), "look": Vector3(0.4, 22.0, 0.3)},
		{"n": "grove_under", "at": Vector2(-322, 118), "eye": Vector3(0, 1.7, 0.0), "look": Vector3(1.0, 18.0, 0.6)},
		{"n": "village_banyan", "at": Vector2(-120, 44), "eye": Vector3(0, 2.0, 16.0), "look": Vector3(0, 7.0, 0)},
		{"n": "tree_silhouette", "at": Vector2(-120, 60), "eye": Vector3(0, 1.6, 20.0), "look": Vector3(0, 9.0, -6.0)},
	]
	for s in spots:
		var at: Vector2 = s.at
		var g: float = _game.world.map.height_at(at.x, at.y)
		await _settle(p, Vector3(at.x, g + 0.2, at.y))
		var base := Vector3(at.x, g, at.y)
		_cam.look_at_from_position(base + s.eye, base + s.look, Vector3.UP)
		for i in range(26):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/qaw_%s.png" % s.n)
		print("shot qaw_%s" % s.n)
	print("RESULT: PASS")
	get_tree().quit()
