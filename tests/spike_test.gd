extends Node
## Find WHAT makes the slow frames slow, rather than guessing. Walks the world and,
## on every frame over the threshold, reports the pending work each streamer is
## holding at that moment.
var game: Game


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	_run()


func _run() -> void:
	game = Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	p.lock_input(true)
	# Warm up over the whole route.
	for r in [Vector2(-120, 44), Vector2(-34, 8), Vector2(150, -60), Vector2(30, -180), Vector2(-180, -20), Vector2(214, 178)]:
		p.global_position = Vector3(r.x, game.world.map.height_at(r.x, r.y) + 0.2, r.y)
		game.world.terrain.update_focus(p.global_position, true)
		for w in range(70):
			await get_tree().process_frame

	# Decisive experiment: build EVERY enemy and NPC body up front. If the slow frames
	# disappear, streaming the builds is the cause; if they do not, it is something the
	# pending counter merely correlates with.
	var prebuild := false
	for arg in OS.get_cmdline_user_args():
		if arg == "--prebuild":
			prebuild = true
	if prebuild:
		var t0 := Time.get_ticks_msec()
		var n := 0
		for e in get_tree().get_nodes_in_group("enemy"):
			if e.has_method("build_visual") and e.has_method("wants_build"):
				e.set_focus_distance(0.0, 0)
				if e.wants_build():
					e.build_visual()
					n += 1
		print("prebuilt %d enemy rigs in %d ms" % [n, Time.get_ticks_msec() - t0])

	var a := Vector2(-140.0, 60.0)
	var b := Vector2(-210.0, -40.0)
	var frames := int(a.distance_to(b) / 8.0 * 60.0)
	var slow := 0
	var hist: Dictionary = {}
	for f in range(frames):
		var t: float = float(f) / float(frames - 1)
		var q: Vector2 = a.lerp(b, t)
		p.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 0.2, q.y)
		# Snapshot pending work BEFORE the frame runs.
		var terr_pending: int = game.world.terrain._pending.size()
		var grass_pending: int = game.vegetation._grass_pending.size() if game.vegetation else 0
		var enemy_pending: int = game.enemies.pending_builds() if game.enemies and game.enemies.has_method("pending_builds") else 0
		await get_tree().process_frame
		var ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		if ms > 34.0:
			slow += 1
			var cause := "unknown"
			if terr_pending > 0:
				cause = "terrain(%d)" % terr_pending
			elif grass_pending > 0:
				cause = "grass(%d)" % grass_pending
			elif enemy_pending > 0:
				cause = "enemy_build(%d)" % enemy_pending
			hist[cause] = hist.get(cause, 0) + 1
			if slow <= 12:
				print(
					(
						"  frame %4d  %6.2f ms   terrain=%d grass=%d enemyBuild=%d  phys=%.1f ms"
						% [
							f,
							ms,
							terr_pending,
							grass_pending,
							enemy_pending,
							Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
						]
					)
				)
	print("slow frames: %d / %d" % [slow, frames])
	print("attributed: %s" % hist)
	print("mesh cache: %s" % MeshKit.cache_stats())
	get_tree().quit()
