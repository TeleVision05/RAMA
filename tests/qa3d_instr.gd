extends Node
## QA: does perf_test's own instrumentation cause the slowdown perf_test reports?
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/qa3d_instr.tscn
##
## perf_test calls `viewport_set_measure_render_time(vp, true)` and then reads
## `viewport_get_measured_render_time_gpu` every frame. That forces a CPU/GPU sync per
## frame. It also prints `gpu 0.00 ms` in every run, so whatever it is buying, it is not
## a GPU number. Same walk, same process, instrumentation off then on.

var game: Game


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _walk(read_gpu: bool) -> Array:
	var p := game.player
	var m: WorldMap = game.world.map
	var vp := get_viewport().get_viewport_rid()
	var a := Vector2(-140, 60)
	var b := Vector2(-96, 30)
	p.global_position = Vector3(a.x, m.height_at(a.x, a.y) + 0.2, a.y)
	game.world.terrain.update_focus(p.global_position, true)
	for w in range(30):
		await get_tree().process_frame
	var frames := 300
	var wall := 0.0
	var tp := 0.0
	var t0 := Time.get_ticks_usec()
	for f in range(frames):
		var t := float(f) / float(frames - 1)
		var q := a.lerp(b, t)
		p.global_position = Vector3(q.x, m.height_at(q.x, q.y) + 0.2, q.y)
		await get_tree().process_frame
		tp += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		if read_gpu:
			wall += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	var total := float(Time.get_ticks_usec() - t0) / 1000.0 / float(frames)
	return [total, tp / float(frames), wall / float(frames)]


func _run() -> void:
	game = Game.new()
	game.spawn_hud = false
	game.quality_tier = 2
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	game.player.lock_input(true)
	for w in range(120):
		await get_tree().process_frame
	var vp := get_viewport().get_viewport_rid()

	print("")
	print("== perf_test's INSTRUMENTATION, same walk, same process ==")
	RenderingServer.viewport_set_measure_render_time(vp, false)
	var off := await _walk(false)
	print("  measure_render_time OFF   wall %6.2f ms (%3.0f fps)   TIME_PROCESS %6.2f ms" % [off[0], 1000.0 / off[0], off[1]])
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var on := await _walk(true)
	print(
		(
			"  measure_render_time ON    wall %6.2f ms (%3.0f fps)   TIME_PROCESS %6.2f ms   gpu %.2f ms"
			% [on[0], 1000.0 / on[0], on[1], on[2]]
		)
	)
	print("  -> instrumentation costs %+.2f ms wall, %+.2f ms of TIME_PROCESS" % [on[0] - off[0], on[1] - off[1]])
	RenderingServer.viewport_set_measure_render_time(vp, false)
	var off2 := await _walk(false)
	print("  measure_render_time OFF again %6.2f ms (%3.0f fps)   TIME_PROCESS %6.2f ms" % [off2[0], 1000.0 / off2[0], off2[1]])
	print("RESULT: PASS (measurement only)")
	get_tree().quit()
