extends Node
## A clean square hero render for the desktop icon. Boots the world WITHOUT the HUD, so
## no notification cards end up baked into the artwork.
func _ready() -> void:
	await get_tree().process_frame
	_run()

func _run() -> void:
	var game := Game.new()
	game.quality_tier = Quality.Tier.ULTRA
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	p.visible = false                      # keep Rama out of the icon
	game.world.sky.paused = true

	var cam := Camera3D.new()
	cam.fov = 40.0
	cam.far = 2000.0
	add_child(cam)
	cam.current = true

	# The shrine on its knoll, low golden light raking across the shikhara.
	var s := WorldMap.P_SHRINE
	var ground := game.world.map.height_at(s.x, s.y)
	var target := Vector3(s.x, ground + 5.0, s.y)
	var shots := [
		{"n": "a", "eye": Vector3(34.0, 12.0, 30.0), "h": 7.6},
		{"n": "b", "eye": Vector3(-26.0, 14.0, 34.0), "h": 17.4},
		{"n": "c", "eye": Vector3(30.0, 20.0, -28.0), "h": 6.9},
	]
	for sh in shots:
		game.world.sky.set_time(sh.h)
		var eye: Vector3 = target + sh.eye
		game.world.terrain.update_focus(eye, true)
		for i in range(5):
			for n in [game.vegetation, game.vfx, game.wildlife, game.solids]:
				if n and n.has_method("update_focus"):
					n.update_focus(eye)
			await get_tree().physics_frame
		cam.look_at_from_position(eye, target, Vector3.UP)
		for i in range(40):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/icon_src_%s.png" % sh.n)
		print("icon shot ", sh.n)
	print("done")
	get_tree().quit()
