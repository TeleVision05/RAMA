extends Node
## Boots the real Game and photographs it from the player's own camera at a set of
## places and times. This is the "does the game look good" check.

const SHOTS := [
	{"n": "01_spawn", "p": Vector2(-114, 66), "yaw": -0.45, "pitch": -0.12, "h": 8.0},
	{"n": "02_village", "p": Vector2(-126, 56), "yaw": 2.55, "pitch": -0.06, "h": 9.2},
	{"n": "03_road", "p": Vector2(-66, 33), "yaw": 1.35, "pitch": -0.04, "h": 10.5},
	{"n": "04_ford", "p": Vector2(-38, 10), "yaw": 2.60, "pitch": -0.14, "h": 12.0},
	{"n": "05_forest", "p": Vector2(-214, -6), "yaw": 0.60, "pitch": -0.02, "h": 13.0},
	{"n": "06_shrine", "p": Vector2(120, -34), "yaw": -0.85, "pitch": 0.04, "h": 16.5},
	{"n": "07_falls", "p": Vector2(44, -172), "yaw": 3.05, "pitch": 0.05, "h": 11.0},
	{"n": "08_lookout", "p": Vector2(104, -144), "yaw": 2.35, "pitch": -0.18, "h": 17.6},
	{"n": "09_ruins", "p": Vector2(-160, -128), "yaw": 0.45, "pitch": -0.03, "h": 10.0},
	{"n": "10_dusk", "p": Vector2(-90, 60), "yaw": 1.55, "pitch": -0.05, "h": 18.5},
	{"n": "11_night", "p": Vector2(-120, 50), "yaw": 2.30, "pitch": -0.04, "h": 23.0},
	{"n": "12_dawn_river", "p": Vector2(-60, 46), "yaw": 2.20, "pitch": -0.06, "h": 6.2},
]


func _ready() -> void:
	_run()


func _run() -> void:
	var game := Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	var cam := game.cam
	game.world.sky.paused = true
	# Do not let the automated camera fight the player's own aiming.
	p.lock_input(true)

	for s in SHOTS:
		var gy: float = game.world.map.height_at(s.p.x, s.p.y)
		p.global_position = Vector3(s.p.x, gy + 0.15, s.p.y)
		p.velocity = Vector3.ZERO
		p.facing_yaw = s.yaw
		cam.yaw = s.yaw
		cam.pitch = s.pitch
		game.world.sky.set_time(s.h)
		game.world.terrain.update_focus(p.global_position, true)
		for i in range(3):
			for n in [game.vegetation, game.vfx, game.wildlife, game.water]:
				if n and n.has_method("update_focus"):
					n.update_focus(p.global_position)
			await get_tree().physics_frame
		# Let streaming, sky radiance, shadows and volumetrics settle.
		for i in range(34):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/game_%s.png" % s.n)
		print("shot %s at (%.0f,%.0f) t=%.1f" % [s.n, s.p.x, s.p.y, s.h])

	# Report what actually got built.
	print("--- systems ---")
	for k in ["water", "vegetation", "settlement", "vfx", "wildlife"]:
		var n: Node = game.get(k)
		print("  %-11s %s  children=%d" % [k, "YES" if n else "no", n.get_child_count() if n else 0])
	print(
		(
			"enemies=%d npcs=%d interactables=%d"
			% [
				get_tree().get_nodes_in_group("enemy").size(),
				get_tree().get_nodes_in_group("npc").size(),
				get_tree().get_nodes_in_group("interactable").size()
			]
		)
	)
	print("done")
	get_tree().quit()
