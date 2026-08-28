extends Node
## What the 3D ground cover costs, measured as a PAIRED DIFFERENCE inside one process.
##
## Two runs of this project disagree by more than 10 ms — shader cache, streaming state,
## and whatever else is on the machine — and other agents are editing the tree builder
## while this is being measured, so a before/after across two builds says nothing about
## this layer. The cover is toggled on and off every few frames at one viewpoint and the
## MEDIAN of the paired differences is reported. A mean is still dragged around by a
## single streaming hitch. See tests/ui_qa_perf.gd for the worked example this follows.

const SPOTS := [
	["village meadow", Vector2(-150, 80)],
	["fields", Vector2(-96, 12)],
	["deep wood", Vector2(-210, -30)],
	["river bank", Vector2(-64, -26)],
	["badlands", Vector2(214, 178)],
]
const PAIRS := 14
const SETTLE := 4
const SAMPLE := 6

var game: Game


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	_run()


func _run() -> void:
	game = Game.new()
	game.spawn_hud = false
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	game.world.sky.paused = true
	game.world.sky.set_time(11.0)
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)

	for spot in SPOTS:
		var at: Vector2 = spot[1]
		p.global_position = Vector3(at.x, game.world.map.height_at(at.x, at.y) + 1.7, at.y)
		game.world.terrain.update_focus(p.global_position, true)
		game.vegetation.update_focus(p.global_position, true)
		for w in range(70):
			await get_tree().process_frame
		var st: Dictionary = game.vegetation.stats()

		var dcpu: Array[float] = []
		var dgpu: Array[float] = []
		var don: Array[float] = []
		for i in range(PAIRS):
			var on_ms := await _measure(true)
			var off_ms := await _measure(false)
			dcpu.append(on_ms[0] - off_ms[0])
			dgpu.append(on_ms[1] - off_ms[1])
			don.append(on_ms[0])
		game.vegetation.set_cover_visible(true)
		print(
			(
				"%-14s cover +%5.2f ms/frame (+%d prims) | inst %5d tri %6d by layer %s | frame %5.2f ms"
				% [
					spot[0],
					_median(dcpu),
					int(_median(dgpu)),
					st.grass_instances,
					st.grass_triangles,
					str(st.cover_tris_by_layer),
					_median(don)
				]
			)
		)
	print("RESULT: PASS")
	get_tree().quit()


## WALL CLOCK across whole frames, not Performance.TIME_PROCESS. TIME_PROCESS is the
## main thread's script time and reported an identical 0.00 ms difference for every one
## of 14 pairs with the cover on and off — it does not see the rendering thread, which
## is where a hundred and fifty thousand triangles are actually paid for.
func _measure(on: bool) -> Array:
	game.vegetation.set_cover_visible(on)
	for i in range(SETTLE):
		await get_tree().process_frame
	var prims := 0.0
	var t0 := Time.get_ticks_usec()
	for i in range(SAMPLE):
		await get_tree().process_frame
		prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(SAMPLE)
	return [ms, prims / float(SAMPLE)]


func _median(a: Array[float]) -> float:
	var b := a.duplicate()
	b.sort()
	return b[b.size() / 2]
