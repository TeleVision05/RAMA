extends Node
## Honest frame-time measurement.
##
## Two corrections over the naive version: vsync OFF (otherwise every reading is just
## the 16.7 ms refresh cap and says nothing), and the player WALKS between waypoints
## rather than teleporting, so streaming cost is measured the way it is actually paid.
## Each leg is also warmed up first, because the first pass through a region pays
## one-off shader compilation that a player pays once at load, not every frame.

## What the village may cost from either camera in `_village_draws`, with villager level of
## detail on (measured 1872 to 2040 over two runs, so about 12 per cent headroom), and the
## most the level of detail may leave of the cost without it (measured 72 to 74 per cent).
const VILLAGE_DRAW_BUDGET := 2300
const VILLAGE_LOD_MAX_SHARE := 0.85

var game: Game
var _village_fails: Array[String] = []


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _run() -> void:
	game = Game.new()
	var tier := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tier="):
			tier = int(a.substr(7))
	game.quality_tier = tier
	print("quality tier: %s" % Quality.NAMES[tier])
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	p.lock_input(true)

	# Warm-up lap: touch every region once so shader compilation is not counted.
	for r in [
		Vector2(-120, 44),
		Vector2(-34, 8),
		Vector2(150, -60),
		Vector2(30, -180),
		Vector2(-180, -20),
		Vector2(214, 178),
		Vector2(-168, -140),
		Vector2(-322, 118)
	]:
		p.global_position = Vector3(r.x, game.world.map.height_at(r.x, r.y) + 0.2, r.y)
		game.world.terrain.update_focus(p.global_position, true)
		# 90 frames each: enough for every material in the region to actually be drawn
		# once, which is when Godot compiles its pipeline.
		for w in range(90):
			await get_tree().process_frame
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	print("warm-up done")
	await _village_draws()
	if OS.get_cmdline_user_args().has("--village-only"):
		_finish_village_only()
		return

	var legs := [
		["village", Vector2(-140, 60), Vector2(-96, 30)],
		["river road", Vector2(-70, 20), Vector2(-20, -20)],
		["shrine", Vector2(120, -30), Vector2(160, -66)],
		["falls", Vector2(50, -140), Vector2(34, -186)],
		["deep wood", Vector2(-160, 0), Vector2(-210, -40)],
		["badlands", Vector2(190, 150), Vector2(220, 185)],
	]
	var worst := 0.0
	var worst_leg := ""
	var all: Array[float] = []
	for leg in legs:
		var a: Vector2 = leg[1]
		var b: Vector2 = leg[2]
		p.global_position = Vector3(a.x, game.world.map.height_at(a.x, a.y) + 0.2, a.y)
		game.world.terrain.update_focus(p.global_position, true)
		for w in range(24):
			await get_tree().process_frame
		# Traverse at SPRINT speed (8 m/s), not by teleporting. The earlier version
		# covered 44 m in 90 frames - 30 m/s, six times sprint - which thrashed the
		# foliage streamer and measured a situation the game never has to survive.
		var dist: float = a.distance_to(b)
		var frames: int = maxi(90, int(dist / 8.0 * 60.0))
		var acc := 0.0
		var peak := 0.0
		var gacc := 0.0
		for f in range(frames):
			var t: float = float(f) / float(frames - 1)
			var q: Vector2 = a.lerp(b, t)
			p.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 0.2, q.y)
			await get_tree().process_frame
			var ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			acc += ms
			peak = maxf(peak, ms)
			gacc += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		var avg := acc / float(frames)
		var gavg := gacc / float(frames)
		all.append(avg)
		if avg > worst:
			worst = avg
			worst_leg = String(leg[0])
		print(
			(
				"  %-11s cpu %6.2f ms  gpu %6.2f ms (%4.0f fps)  peak %6.2f   prims=%d draws=%d"
				% [
					leg[0],
					avg,
					gavg,
					1000.0 / maxf(maxf(avg, gavg), 0.01),
					peak,
					Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
					Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
				]
			)
		)
	var mean := 0.0
	for s in all:
		mean += s
	mean /= float(all.size())
	print(
		(
			"mean %.2f ms (%.0f fps)   worst leg '%s' %.2f ms (%.0f fps)"
			% [mean, 1000.0 / maxf(mean, 0.01), worst_leg, worst, 1000.0 / maxf(worst, 0.01)]
		)
	)
	print(
		(
			"static mem %.0f MB   video mem %.0f MB   nodes %d"
			% [
				Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
				Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
				Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
			]
		)
	)
	# Reported against 60 and 30 fps; GATED at 20, because that is the line below which
	# the game stops being playable rather than merely heavy. Run-to-run variance on an
	# otherwise idle M2 Max is about +/-7 fps (33 and 40 fps mean on identical builds),
	# so a tighter gate would be a coin toss, not a regression detector.
	print(
		(
			"target 60 fps: %s   target 30 fps: %s   gate 20 fps: %s"
			% ["met" if worst < 16.7 else "not met", "met" if worst < 33.3 else "not met", "met" if worst < 50.0 else "NOT MET"]
		)
	)
	var ok: bool = worst < 50.0 and _village_fails.is_empty()
	for f in _village_fails:
		print("  ! " + f)
	print("RESULT: " + ("PASS" if ok else "FAIL (a leg averaged under 20 fps, or the village is over its draw budget)"))
	get_tree().quit(0 if ok else 1)


## Draw calls in the village from two fixed cameras (6 m up, 40 m south and 55 m east of
## the square, looking at it), with the villagers hidden, drawn without level of detail,
## and drawn with it. Draw counts do not depend on machine load, so they are asserted.
## Measured 2026-11-13 at the High tier, two runs: hidden 1481 to 1662, off 2518 to 2788,
## on 1813 to 2040, so the 14 villagers cost about 75 draws each without level of detail
## and about 25 with it.
func _village_draws() -> void:
	var p := game.player
	var v := Vector2(WorldMap.P_VILLAGE.x, WorldMap.P_VILLAGE.y)
	var vg: float = game.world.map.height_at(v.x, v.y)
	print("village draw calls (counts do not depend on machine load)")
	for spot in [["from the south", Vector2(0.0, 40.0)], ["from the east", Vector2(55.0, 0.0)]]:
		var q: Vector2 = v + (spot[1] as Vector2)
		p.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 0.2, q.y)
		game.world.terrain.update_focus(p.global_position, true)
		var cam := Camera3D.new()
		add_child(cam)
		cam.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 6.0, q.y)
		cam.look_at(Vector3(v.x, vg + 2.0, v.y))
		cam.current = true
		for w in range(90):
			await get_tree().process_frame
		var hidden := await _avg_draws(false, true)
		var off := await _avg_draws(false, false)
		var on := await _avg_draws(true, false)
		print("  %-15s villagers hidden %5.0f   lod off %5.0f   lod on %5.0f   (near/mid/far %s)" % [spot[0], hidden, off, on, _lod_census()])
		if on > off * VILLAGE_LOD_MAX_SHARE:
			_village_fails.append("%s: level of detail saved too little (%.0f draws on, %.0f off)" % [spot[0], on, off])
		if on > VILLAGE_DRAW_BUDGET:
			_village_fails.append("%s: %.0f draw calls is over the village budget of %d" % [spot[0], on, VILLAGE_DRAW_BUDGET])
		cam.queue_free()
	game.cam.camera().current = true
	NPCLod.enabled = true
	for n in get_tree().get_nodes_in_group("npc"):
		(n as NPC).visible = (n as NPC).is_active()


func _avg_draws(lod_on: bool, hide_villagers: bool) -> float:
	NPCLod.enabled = lod_on
	for n in get_tree().get_nodes_in_group("npc"):
		(n as NPC).visible = not hide_villagers
	# The director re-evaluates levels four times a second; give it several passes.
	for i in range(60):
		await get_tree().process_frame
	var acc := 0.0
	for i in range(20):
		await get_tree().process_frame
		acc += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	return acc / 20.0


func _lod_census() -> String:
	var c := [0, 0, 0]
	for n in get_tree().get_nodes_in_group("npc"):
		if n is NPC and (n as NPC).is_active():
			c[(n as NPC).lod] += 1
	return "%d/%d/%d" % c


func _finish_village_only() -> void:
	for f in _village_fails:
		print("  ! " + f)
	print("RESULT: " + ("PASS" if _village_fails.is_empty() else "FAIL (village draw budget)"))
	get_tree().quit(0 if _village_fails.is_empty() else 1)
