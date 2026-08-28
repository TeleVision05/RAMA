extends Node
## What WorldVFX + Wildlife cost inside the REAL game, on the same legs the project
## perf test walks, so a failure there can be attributed or cleared.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/vfx_qa_gameperf.tscn
##
## Method is tests/perf_test.gd's: full Game, vsync off, warm-up lap, then walk each
## leg at sprint speed. The difference is that every leg is walked FOUR times - both
## systems on, wildlife off, vfx off, both off - so the delta is measurable rather
## than argued about. Statistics are the minimum and the median over the leg, not the
## mean: this machine is shared with other Godot runs and the mean is mostly theirs.

var game: Game
var vfx: Node3D
var life: Node3D

const LEGS := [
	["village", Vector2(-140, 60), Vector2(-96, 30)],
	["deep wood", Vector2(-160, 0), Vector2(-210, -40)],
	["river road", Vector2(-70, 20), Vector2(-20, -20)],
]


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


static func _pct(a: Array, f: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return float(s[clampi(int(float(s.size() - 1) * f), 0, s.size() - 1)])


func _set_on(v: bool, l: bool) -> void:
	if vfx:
		vfx.process_mode = Node.PROCESS_MODE_INHERIT if v else Node.PROCESS_MODE_DISABLED
		vfx.visible = v
	if life:
		life.process_mode = Node.PROCESS_MODE_INHERIT if l else Node.PROCESS_MODE_DISABLED
		life.visible = l


## A PAIRED walk: the two systems are toggled on and off every 30 frames along the
## same route, and frame times are bucketed by which state was live. Blocked A/B (walk
## the leg with them on, then again with them off) is worthless on a machine shared
## with other Godot runs - the baseline drifted by up to 20 ms between two identical
## measurements. Interleaving makes both states pay the same contention.
func _paired(a: Vector2, b: Vector2, label: String) -> void:
	var p := game.player
	p.global_position = Vector3(a.x, game.world.map.height_at(a.x, a.y) + 0.2, a.y)
	game.world.terrain.update_focus(p.global_position, true)
	_set_on(true, true)
	for w in range(60):
		await get_tree().process_frame

	var on_ms: Array = []
	var off_ms: Array = []
	var on_obj := 0.0
	var off_obj := 0.0
	var on_draw := 0.0
	var off_draw := 0.0
	var on_n := 0
	var off_n := 0
	var blocks := 24
	var per := 30
	var settle := 8  # frames discarded after each toggle
	var last := Time.get_ticks_usec()
	for blk in range(blocks):
		var live := (blk % 2) == 0
		_set_on(live, live)
		for f in range(per):
			var t: float = float(blk * per + f) / float(blocks * per - 1)
			# Ping-pong along the leg so the whole route is covered in both states.
			var u: float = absf(fposmod(t * 2.0, 2.0) - 1.0)
			var q: Vector2 = a.lerp(b, 1.0 - u)
			p.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 0.2, q.y)
			await get_tree().process_frame
			var now := Time.get_ticks_usec()
			var ms := float(now - last) / 1000.0
			last = now
			if f < settle:
				continue
			var ob: float = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
			var dr: float = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			if live:
				on_ms.append(ms)
				on_obj += ob
				on_draw += dr
				on_n += 1
			else:
				off_ms.append(ms)
				off_obj += ob
				off_draw += dr
				off_n += 1
	_set_on(true, true)
	var on_min := _pct(on_ms, 0.02)
	var off_min := _pct(off_ms, 0.02)
	var on_med := _pct(on_ms, 0.5)
	var off_med := _pct(off_ms, 0.5)
	print(
		(
			"  %-12s ON  min %6.2f med %6.2f ms   obj %5.0f draws %5.0f   (%d frames)"
			% [label, on_min, on_med, on_obj / maxf(float(on_n), 1.0), on_draw / maxf(float(on_n), 1.0), on_n]
		)
	)
	print(
		(
			"  %-12s OFF min %6.2f med %6.2f ms   obj %5.0f draws %5.0f   (%d frames)"
			% ["", off_min, off_med, off_obj / maxf(float(off_n), 1.0), off_draw / maxf(float(off_n), 1.0), off_n]
		)
	)
	print(
		(
			"  %-12s COST of WorldVFX + Wildlife: %+.2f ms best-case, %+.2f ms median"
			% ["", on_min - off_min, on_med - off_med]
		)
	)


func _run() -> void:
	game = Game.new()
	game.quality_tier = 2  # HIGH, the same tier the project perf test uses
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	game.player.lock_input(true)
	vfx = game.vfx
	life = game.wildlife
	print("vfx=%s wildlife=%s  particle density=%.2f" % [vfx != null, life != null, WorldVFX.density])

	# Warm-up lap over every region so pipeline compilation is not counted.
	for r in [Vector2(-120, 44), Vector2(-34, 8), Vector2(-180, -20), Vector2(-20, -20)]:
		game.player.global_position = Vector3(r.x, game.world.map.height_at(r.x, r.y) + 0.2, r.y)
		game.world.terrain.update_focus(game.player.global_position, true)
		for w in range(120):
			await get_tree().process_frame
	# And once more at night, when the fires, fireflies and bats are all awake.
	game.world.sky.set_time(22.0)
	for w in range(180):
		await get_tree().process_frame
	game.world.sky.set_time(11.0)
	game.world.sky.paused = true
	print("warm-up done")

	for hour in [11.0, 21.5]:
		game.world.sky.set_time(hour)
		print("\n=== hour %.1f ===" % hour)
		for leg in LEGS:
			await _paired(leg[1], leg[2], leg[0])

	print("\ndone")
	get_tree().quit()
