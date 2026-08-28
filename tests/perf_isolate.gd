extends Node
## Bisect the frame cost properly: vsync off, warm up before EVERY measurement, and
## keep the player walking so streaming stays in the loop.
var game: Game
var p: Player
var _t := 0.0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func measure(label: String) -> float:
	# Warm up, then sample while walking a fixed circuit at sprint speed.
	for w in range(40):
		_step()
		await get_tree().process_frame
	var acc := 0.0
	var n := 150
	for f in range(n):
		_step()
		await get_tree().process_frame
		acc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var ms := acc / float(n)
	print("  %-26s %7.2f ms   (%3.0f fps)" % [label, ms, 1000.0 / maxf(ms, 0.01)])
	return ms


func _step() -> void:
	_t += 0.016
	var c := Vector2(-120.0, 44.0)
	var q := c + Vector2(cos(_t * 0.9), sin(_t * 0.9)) * 34.0
	p.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 0.2, q.y)


func _run() -> void:
	game = Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	p = game.player
	p.lock_input(true)
	game.world.terrain.update_focus(p.global_position, true)

	# ONE long warm-up before any measurement. Godot compiles shaders and builds
	# pipelines lazily, so whichever configuration is measured first otherwise absorbs
	# the entire cost and every later one looks free.
	for w in range(420):
		_step()
		await get_tree().process_frame
	print("warmed up")

	var base := await measure("everything")
	var systems := {
		"vegetation": game.vegetation,
		"vfx": game.vfx,
		"wildlife": game.wildlife,
		"water": game.water,
		"settlement": game.settlement,
		"solids": game.solids,
		"enemies": game.enemies,
		"npcs": game.npcs,
	}
	for k in systems:
		var n: Node = systems[k]
		if n == null:
			continue
		n.process_mode = Node.PROCESS_MODE_DISABLED
		var m := await measure("without " + k)
		print("      -> %s costs about %.1f ms" % [k, base - m])
		n.process_mode = Node.PROCESS_MODE_INHERIT
	# Hide (not just stop) vegetation, to separate its CPU work from its draw cost.
	if game.vegetation:
		game.vegetation.visible = false
		var m2 := await measure("vegetation hidden")
		print("      -> vegetation DRAW costs about %.1f ms" % (base - m2))
		game.vegetation.visible = true
	game.world.sky.paused = true
	var env := game.world.sky.env.environment
	env.ssao_enabled = false
	env.ssil_enabled = false
	env.volumetric_fog_enabled = false
	await measure("no SSAO/SSIL/volumetrics")
	env.ssao_enabled = true
	env.ssil_enabled = true
	env.volumetric_fog_enabled = true
	game.world.sky.sun.shadow_enabled = false
	await measure("no sun shadows")
	game.world.sky.sun.shadow_enabled = true
	get_tree().quit()
