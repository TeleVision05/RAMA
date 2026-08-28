extends Node
## What the vegetation system costs, on its own, in a real windowed frame.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/veg_perf.tscn
##
## Method, and why it is this shape:
##
##  * World + terrain + sky + vegetation and nothing else — no VFX, settlement,
##    wildlife, NPCs or water — so nothing else in the frame can be blamed.
##  * vsync off and `Engine.max_fps = 0`, otherwise every reading is the refresh cap.
##  * One long warm-up: Godot compiles a pipeline the first time a material is actually
##    drawn, so whichever configuration is measured first otherwise absorbs the lot.
##  * The camera WALKS at sprint speed. The streamer is throttled by distance moved, so
##    a teleporting camera measures a cost the game never pays.
##  * Every sample walks the IDENTICAL stretch of route (`_t` is reset), so the terrain
##    LOD, the visible chunk set and the streaming schedule all line up.
##  * A/B/A/B INTERLEAVED, seven times, reporting the MEDIAN delta. A single A-then-B
##    pass on this machine drifted 4 ms between two identical configurations — enough
##    to invent or hide the entire result being measured.
##
## `viewport_get_measured_render_time_gpu` returns 0 on this Metal backend, so the
## honest figure available is `Performance.TIME_PROCESS`, the whole frame iteration.

# Short samples, alternated many times. This machine is shared: the run that produced
# these constants had a load average of 138 and four Metal shader-compiler services at
# >100% CPU, and long A-then-B samples drifted +-16 ms — enough to invent or erase the
# entire result. Noise is correlated over short windows, so A and B are interleaved
# tightly and the reported figure is the median of the PAIRED differences.
const FRAMES := 40  # per sample
const SETTLE := 12  # frames discarded before each sample
const WARM := 300
const REPS := 15
const SPEED := 8.0  # sprint, m/s

var world: WorldRoot
var veg: Vegetation
var cam: Camera3D
var vp_rid: RID
var _t := 0.0
var _stream := true
var _route: Array[Vector2] = []
var _route_len := 0.0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _run() -> void:
	world = WorldRoot.new()
	add_child(world)
	world.build(false)

	veg = Vegetation.new()
	veg.name = "Vegetation"
	add_child(veg)
	var t0 := Time.get_ticks_usec()
	veg.setup(world.map)
	var setup_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	veg.set_wind(world.sky.wind_dir, world.sky.wind_strength, 1.0)

	cam = Camera3D.new()
	cam.fov = 62.0
	cam.far = 2000.0
	cam.near = 0.12
	add_child(cam)
	cam.current = true
	world.sky.paused = true
	world.sky.set_time(11.0)

	vp_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)

	# A circuit through the thickest forest in the valley — where this system is at its
	# most expensive. Measuring in the meadow would flatter it.
	_route = [
		Vector2(-196, -34),
		Vector2(-232, 10),
		Vector2(-244, 60),
		Vector2(-200, 96),
		Vector2(-160, 40),
		Vector2(-196, -34)
	]
	for i in range(_route.size() - 1):
		_route_len += _route[i].distance_to(_route[i + 1])

	print("setup()            : %.1f ms" % setup_ms)
	for i in range(WARM):
		_walk()
		await get_tree().process_frame
	print("warmed up (%d frames)" % WARM)

	var on := await _ab("everything on", func(): _all(true))
	var stream_only := await _ab(
		"streamed, not drawn",
		func():
			_all(true)
			veg.visible = false
	)
	var draw_only := await _ab(
		"drawn, not streamed",
		func():
			_all(true)
			_stream = false
	)
	var no_cover := await _ab(
		"no ground cover",
		func():
			_all(true)
			_cover(false)
	)
	var no_shadow := await _ab(
		"no veg shadows",
		func():
			_all(true)
			_shadows(false)
	)
	_all(true)

	print("---")
	print("  streaming CPU    : %+.2f ms" % stream_only.d)
	print("  draw only        : %+.2f ms" % draw_only.d)
	print("  of which cover   : %+.2f ms" % (draw_only.d - no_cover.d))
	print("  of which shadows : %+.2f ms" % (draw_only.d - no_shadow.d))
	print("VEGETATION COSTS   : %.2f ms of frame time (median of %d interleaved A/B pairs)" % [on.d, REPS])
	print("  baseline frame   : %.2f ms without it, %.2f ms with it" % [on.b, on.a])
	print("  in frame         : %d objects, %d primitives, %d draw calls attributable" % [on.objs, on.prims, on.draws])
	var budget := 9.0
	print("RESULT: " + ("PASS" if on.d <= budget else "FAIL") + "  (budget %.1f ms, measured %.2f ms)" % [budget, on.d])
	get_tree().quit()


## Interleave configuration A (built by `setup_a`) against vegetation fully off, REPS
## times, and return the median difference.
func _ab(label: String, setup_a: Callable) -> Dictionary:
	var deltas: Array[float] = []
	var a_ms: Array[float] = []
	var b_ms: Array[float] = []
	var d_obj := 0
	var d_pri := 0
	var d_drw := 0
	for r in range(REPS):
		setup_a.call()
		var a := await _sample()
		_all(false)
		var b := await _sample()
		deltas.append(a.cpu - b.cpu)
		a_ms.append(a.cpu)
		b_ms.append(b.cpu)
		d_obj = a.objs - b.objs
		d_pri = a.prims - b.prims
		d_drw = a.draws - b.draws
	deltas.sort()
	a_ms.sort()
	b_ms.sort()
	var mid := REPS / 2
	print(
		(
			"  %-20s %+6.2f ms   (with %6.2f, without %6.2f)  spread %+.2f..%+.2f"
			% [label, deltas[mid], a_ms[mid], b_ms[mid], deltas[0], deltas[REPS - 1]]
		)
	)
	return {"d": deltas[mid], "a": a_ms[mid], "b": b_ms[mid], "objs": d_obj, "prims": d_pri, "draws": d_drw}


func _all(on: bool) -> void:
	veg.visible = on
	_stream = on
	_cover(true)
	_shadows(true)


func _cover(v: bool) -> void:
	for c in veg.get_children():
		if c is MultiMeshInstance3D and _is_cover(String(c.name)):
			c.visible = v


func _shadows(v: bool) -> void:
	for c in veg.get_children():
		if c is MultiMeshInstance3D and not _is_cover(String(c.name)):
			c.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON if v else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)


func _is_cover(n: String) -> bool:
	return n.begins_with("grass") or n.begins_with("flowers")


func _sample() -> Dictionary:
	_t = 0.0
	for i in range(SETTLE):
		_walk()
		await get_tree().process_frame
	_t = 0.0
	var cpu := 0.0
	var peak := 0.0
	var objs := 0
	var prims := 0
	var draws := 0
	for i in range(FRAMES):
		_walk()
		await get_tree().process_frame
		var ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		cpu += ms
		peak = maxf(peak, ms)
		objs += int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		prims += int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		draws += int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var f := float(FRAMES)
	return {
		"cpu": cpu / f,
		"peak": peak,
		"objs": int(objs / FRAMES),
		"prims": int(prims / FRAMES),
		"draws": int(draws / FRAMES)
	}


func _walk() -> void:
	_t += SPEED / 60.0
	var s := fmod(_t, _route_len)
	var q := _route[0]
	var head := _route[1]
	for i in range(_route.size() - 1):
		var seg := _route[i].distance_to(_route[i + 1])
		if s <= seg:
			q = _route[i].lerp(_route[i + 1], s / maxf(seg, 0.01))
			head = _route[i + 1]
			break
		s -= seg
	var eye := Vector3(q.x, world.map.height_at(q.x, q.y) + 1.75, q.y)
	cam.global_position = eye
	var look := Vector3(head.x, world.map.height_at(head.x, head.y) + 2.0, head.y)
	if eye.distance_to(look) > 0.5:
		cam.look_at(look, Vector3.UP)
	world.terrain.update_focus(eye)
	if _stream:
		veg.update_focus(eye)
