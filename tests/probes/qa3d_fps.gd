extends Node
## QA: is the game actually slow, or is perf_test's instrument lying?
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/qa3d_fps.tscn
##
## perf_test gates on `Performance.TIME_PROCESS` and prints `gpu 0.00 ms`. Two things
## make that suspect: a GPU time of exactly zero is not a measurement, and switching 38
## AI nodes off moved TIME_PROCESS the WRONG WAY by 12 ms, which no amount of noise
## explains. So measure the only number that cannot be argued with — wall-clock seconds
## per frame over a long window — and print the monitors beside it.

var game: Game


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _run() -> void:
	game = Game.new()
	game.spawn_hud = false
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	p.lock_input(true)
	var m: WorldMap = game.world.map
	print("")
	print("== WALL CLOCK vs THE MONITORS ==")
	for spot in [
		["village", Vector2(-120, 44)],
		["deep wood", Vector2(-210, -40)],
		["falls", Vector2(34, -186)],
		["badlands", Vector2(214, 178)],
	]:
		var at: Vector2 = spot[1]
		p.global_position = Vector3(at.x, m.height_at(at.x, at.y) + 0.2, at.y)
		game.world.terrain.update_focus(p.global_position, true)
		for w in range(150):
			await get_tree().process_frame
		var n := 400
		var tp := []
		var t0 := Time.get_ticks_usec()
		for i in range(n):
			await get_tree().process_frame
			tp.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		var wall := float(Time.get_ticks_usec() - t0) / 1000.0 / float(n)
		tp.sort()
		print(
			(
				"  %-10s WALL %6.2f ms (%3.0f fps)   TIME_PROCESS %6.2f ms   monitor FPS %3.0f   draws %4d prims %d"
				% [
					spot[0],
					wall,
					1000.0 / wall,
					tp[tp.size() / 2],
					Performance.get_monitor(Performance.TIME_FPS),
					Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
					Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
				]
			)
		)
	# Now perf_test's own route, at its own sprint speed, on the wall clock. Standing
	# still says nothing about a streamer.
	print("")
	print("== perf_test's WALK, measured on the wall clock ==")
	var legs := [
		["village", Vector2(-140, 60), Vector2(-96, 30)],
		["river road", Vector2(-70, 20), Vector2(-20, -20)],
		["shrine", Vector2(120, -30), Vector2(160, -66)],
		["falls", Vector2(50, -140), Vector2(34, -186)],
		["deep wood", Vector2(-160, 0), Vector2(-210, -40)],
		["badlands", Vector2(190, 150), Vector2(220, 185)],
	]
	var worst := 0.0
	var acc := 0.0
	for leg in legs:
		var a: Vector2 = leg[1]
		var b: Vector2 = leg[2]
		p.global_position = Vector3(a.x, m.height_at(a.x, a.y) + 0.2, a.y)
		game.world.terrain.update_focus(p.global_position, true)
		for w in range(24):
			await get_tree().process_frame
		var dist := a.distance_to(b)
		var frames := maxi(90, int(dist / 8.0 * 60.0))
		var samples := []
		for f in range(frames):
			var t := float(f) / float(frames - 1)
			var q := a.lerp(b, t)
			p.global_position = Vector3(q.x, m.height_at(q.x, q.y) + 0.2, q.y)
			var t1 := Time.get_ticks_usec()
			await get_tree().process_frame
			samples.append(float(Time.get_ticks_usec() - t1) / 1000.0)
		var sum := 0.0
		for v in samples:
			sum += v
		var mean := sum / float(samples.size())
		samples.sort()
		acc += mean
		worst = maxf(worst, mean)
		print(
			(
				"  %-11s WALL mean %6.2f ms (%3.0f fps)   median %6.2f   p95 %6.2f   max %7.2f"
				% [
					leg[0],
					mean,
					1000.0 / mean,
					samples[samples.size() / 2],
					samples[int(float(samples.size()) * 0.95)],
					samples[samples.size() - 1],
				]
			)
		)
	var mn := acc / float(legs.size())
	print("  mean %.2f ms (%.0f fps)   worst leg %.2f ms (%.0f fps)" % [mn, 1000.0 / mn, worst, 1000.0 / worst])
	print("RESULT: PASS (measurement only)")
	get_tree().quit()
