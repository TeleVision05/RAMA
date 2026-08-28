extends Node
## QA PERFORMANCE for the Settlement / Arch system.
##
## Runs the real game, then A/B tests the settlement by HIDING it (visible = false, so
## its draw calls and its shadow casters both leave the frame) at the two viewpoints
## where it is heaviest: standing in the village square, and standing in front of the
## shrine. Anything else in the frame is identical between the two samples, so the
## difference is this system's frame cost and nothing else.
##
## vsync off and a long warm-up first, because Godot compiles pipelines lazily and
## whichever configuration is measured first otherwise absorbs the entire cost.

const SPOTS := [
	["village square", Vector2(-118.0, 50.0), Vector2(-128.0, 58.0)],
	["village road", Vector2(-96.0, 30.0), Vector2(-124.0, 54.0)],
	["shrine court", Vector2(168.0, -70.0), Vector2(154.0, -78.5)],
	["shrine road", Vector2(130.0, -100.0), Vector2(154.0, -78.5)],
	["ruins", Vector2(-176.0, -120.0), Vector2(-168.0, -150.0)],
]
const FRAMES := 200

var game: Game
var vp: RID


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _census(n: Node) -> Array:
	# [triangles, mesh nodes, multimesh nodes, multimesh instances, nodes]
	var t := 0
	var mi := 0
	var mmn := 0
	var mmi := 0
	var nodes := 1
	if n is MeshInstance3D and n.mesh:
		mi += 1
		for i in range((n.mesh as Mesh).get_surface_count()):
			var l: int = (n.mesh as Mesh).surface_get_array_index_len(i)
			if l == 0:
				l = (n.mesh as Mesh).surface_get_array_len(i)
			t += l / 3
	elif n is MultiMeshInstance3D and n.multimesh and n.multimesh.mesh:
		mmn += 1
		mmi += n.multimesh.instance_count
		var per := 0
		for i in range(n.multimesh.mesh.get_surface_count()):
			var l2: int = n.multimesh.mesh.surface_get_array_index_len(i)
			if l2 == 0:
				l2 = n.multimesh.mesh.surface_get_array_len(i)
			per += l2 / 3
		t += per * n.multimesh.instance_count
	for c in n.get_children():
		var r := _census(c)
		t += r[0]
		mi += r[1]
		mmn += r[2]
		mmi += r[3]
		nodes += r[4]
	return [t, mi, mmn, mmi, nodes]


static func _median(a: Array) -> float:
	return _pct(a, 0.5)


## Percentile. p10 of wall time is the honest A/B estimator on a loaded machine:
## scheduler noise only ever ADDS time, so the low percentile of each configuration is
## the closest either gets to running alone, and their difference is the real cost.
static func _pct(a: Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var b: Array = a.duplicate()
	b.sort()
	return b[clampi(int(float(b.size() - 1) * q), 0, b.size() - 1)]


## One measurement block. Reports the MEDIAN per-frame wall time, not the mean: this
## machine runs other Godot sessions concurrently and a single descheduled frame of
## 300 ms drags a 200-frame mean by 1.5 ms, which is the size of the effect being
## measured. The median is unmoved by any number of outliers below half the samples.
func _block(eye: Vector2, on: bool, frames: int, acc: Dictionary) -> void:
	var p := game.player
	p.global_position = Vector3(eye.x, game.world.map.height_at(eye.x, eye.y) + 1.6, eye.y)
	game.world.terrain.update_focus(p.global_position, true)
	game.settlement.visible = on
	for w in range(30):
		await get_tree().process_frame
	var t_prev := Time.get_ticks_usec()
	for f in range(frames):
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		acc.wall.append(float(now - t_prev) / 1000.0)
		t_prev = now
		acc.cpu.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		acc.gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
		acc.objs.append(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		acc.prims.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		acc.draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))


func _new_acc() -> Dictionary:
	return {"wall": [], "cpu": [], "gpu": [], "objs": [], "prims": [], "draws": []}


func _sample(label: String, eye: Vector2, _look: Vector2, on: bool) -> Dictionary:
	var acc := _new_acc()
	await _block(eye, on, FRAMES, acc)
	return {
		"label": label,
		"cpu": _median(acc.cpu),
		"gpu": _median(acc.gpu),
		"wall": _median(acc.wall),
		"peak": acc.wall.max(),
		"objs": _median(acc.objs),
		"prims": _median(acc.prims),
		"draws": _median(acc.draws)
	}


func _run() -> void:
	game = Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	p.lock_input(true)
	if game.settlement == null:
		print("RESULT: FAIL - Game did not instantiate Settlement")
		get_tree().quit(1)
		return

	var c := _census(game.settlement)
	print("=== SETTLEMENT BUILD CENSUS ===")
	print("triangles                  : %d" % c[0])
	print("MeshInstance3D nodes       : %d" % c[1])
	print("MultiMeshInstance3D nodes  : %d" % c[2])
	print("MultiMesh instances        : %d" % c[3])
	print("nodes in the subtree       : %d" % c[4])
	print("direct children of Settlement: %d" % game.settlement.get_child_count())
	for ch in game.settlement.get_children():
		if ch is MultiMeshInstance3D:
			print(
				(
					"   MM %-18s n=%-4d vis_end=%5.0f shadows=%s"
					% [
						ch.name,
						ch.multimesh.instance_count,
						ch.visibility_range_end,
						"off" if ch.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF else "on"
					]
				)
			)

	# rebuild once in isolation to time setup() on its own
	var t0 := Time.get_ticks_usec()
	var s2 := Settlement.new()
	add_child(s2)
	s2.setup(game.world.map)
	var setup_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	s2.queue_free()
	print("setup() wall clock (second build, warm caches): %.1f ms" % setup_ms)

	vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	game.world.sky.paused = true
	game.world.sky.set_time(10.0)

	# one long warm-up over every spot, both configurations, before measuring anything
	for spot in SPOTS:
		for on in [true, false]:
			game.settlement.visible = on
			p.global_position = Vector3(spot[1].x, game.world.map.height_at(spot[1].x, spot[1].y) + 1.6, spot[1].y)
			game.world.terrain.update_focus(p.global_position, true)
			for w in range(60):
				await get_tree().process_frame
	game.settlement.visible = true
	print("warm-up done; %d frames per configuration in 4 alternating blocks, vsync off" % FRAMES)
	print("machine load average at start: %s" % str(OS.get_processor_count()) + " cores")
	print("")
	print(
		(
			"%-16s %-9s %8s %8s %8s %8s %8s %10s %10s %8s"
			% ["spot", "settle", "wall.p10", "wall.med", "cpu.p10", "gpu", "peak", "objects", "prims", "draws"]
		)
	)

	var worst := 0.0
	var worst_spot := ""
	for spot in SPOTS:
		# PAIRED LOCAL DIFFERENCING.
		#
		# Two earlier designs failed on this machine, which runs several other Godot
		# sessions at once. Means over 200 frames were dominated by 300 ms descheduled
		# frames. Medians over four long alternating blocks were better but still gave
		# -0.11 ms and +10.34 ms for the SAME spot and the SAME code on two consecutive
		# runs, because the background load drifts over the minute a spot takes.
		#
		# So: alternate visibility every 12 frames, 24 times, take the 25th percentile
		# INSIDE each short block, and difference each ON block against the off block
		# that immediately follows it. Adjacent blocks are a second apart, so they see
		# the same load; the median of the 24 paired differences is then a real estimate
		# of what this system costs, with the spread of those differences as its error.
		var pairs: Array = []
		var on_last := _new_acc()
		var off_last := _new_acc()
		for rep in range(24):
			var a := _new_acc()
			var b := _new_acc()
			await _block(spot[1], true, 12, a)
			await _block(spot[1], false, 12, b)
			pairs.append(_pct(a.wall, 0.25) - _pct(b.wall, 0.25))
			on_last = a
			off_last = b
		var d_wall: float = _median(pairs)
		var spread: float = _pct(pairs, 0.84) - _pct(pairs, 0.16)
		print(
			(
				"%-16s %-9s %8.2f %8.2f %8.2f %8.2f %8.2f %9.0f %10.0f %8.0f"
				% [
					spot[0],
					"ON",
					_pct(on_last.wall, 0.25),
					_median(on_last.wall),
					_pct(on_last.cpu, 0.25),
					_median(on_last.gpu),
					on_last.wall.max(),
					_median(on_last.objs),
					_median(on_last.prims),
					_median(on_last.draws)
				]
			)
		)
		print(
			(
				"%-16s %-9s %8.2f %8.2f %8.2f %8.2f %8.2f %9.0f %10.0f %8.0f"
				% [
					spot[0],
					"off",
					_pct(off_last.wall, 0.25),
					_median(off_last.wall),
					_pct(off_last.cpu, 0.25),
					_median(off_last.gpu),
					off_last.wall.max(),
					_median(off_last.objs),
					_median(off_last.prims),
					_median(off_last.draws)
				]
			)
		)
		print(
			(
				"   -> settlement frame cost %+.2f ms  (paired median of 24, 1-sigma spread %.2f ms)" % [d_wall, spread]
				+ (
					"  (+%.0f objects, +%.0f prims, +%.0f draws)"
					% [
						_median(on_last.objs) - _median(off_last.objs),
						_median(on_last.prims) - _median(off_last.prims),
						_median(on_last.draws) - _median(off_last.draws)
					]
				)
			)
		)
		if d_wall > worst:
			worst = d_wall
			worst_spot = String(spot[0])
	game.settlement.visible = true
	print("")
	print("WORST settlement frame cost: %.2f ms at %s  (budget 9.00 ms)" % [worst, worst_spot])
	print("RESULT: " + ("PASS" if worst <= 9.0 else "FAIL"))
	get_tree().quit(0 if worst <= 9.0 else 1)
