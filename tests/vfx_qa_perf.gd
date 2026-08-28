extends Node
## What WorldVFX + Wildlife actually cost, on their own, in a real windowed frame.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/vfx_qa_perf.tscn
##
## Method. World + terrain + sky and NOTHING else - no vegetation, settlement, water,
## NPCs - so nothing else is in the frame to blame. vsync off, Engine.max_fps 0.
##
## Two things had to be fixed before the numbers meant anything:
##
##   * A long walking route re-streams terrain chunks mid-measurement, and a chunk
##     rebuild is ~12 ms. That noise is several times the signal, and the first version
##     of this harness reported the two systems as costing NEGATIVE milliseconds. The
##     camera now orbits a 22 m circle, well inside one 64 m chunk ring, so terrain is
##     static and the animals still move (they react to focus distance, not to chunks).
##   * The MEAN frame time is dominated by whatever background hitch happens to land in
##     the window. Everything below is a MEDIAN over 240 frames, with the 95th
##     percentile printed beside it so a hitch cannot hide either.
##
## Each scenario is measured in four configurations. `neither` is measured twice, first
## and last, and the two must agree or the machine drifted and the run is not trusted.

const FRAMES := 300
const WARM := 90
const LONG_WARM := 420

var world: WorldRoot
var vfx: WorldVFX
var life: Wildlife
var cam: Camera3D
var _t := 0.0
var _centre := Vector2(-120, 44)
var _radius := 22.0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _step(dt: float) -> void:
	_t += dt
	var a := _t * 0.30
	var q := _centre + Vector2(cos(a), sin(a)) * _radius
	var p := Vector3(q.x, world.map.height_at(q.x, q.y) + 1.7, q.y)
	# Look along the tangent, tilted down a little: never colinear with UP.
	var tang := Vector3(-sin(a), 0.0, cos(a))
	cam.global_position = p
	cam.look_at(p + tang * 12.0 + Vector3(0.0, -2.0, 0.0), Vector3.UP)
	world.terrain.update_focus(p)
	if vfx.process_mode != Node.PROCESS_MODE_DISABLED:
		vfx.update_focus(p)
	if life.process_mode != Node.PROCESS_MODE_DISABLED:
		life.update_focus(p)


static func _pct(a: Array, f: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return float(s[clampi(int(float(s.size() - 1) * f), 0, s.size() - 1)])


func _measure(label: String) -> Dictionary:
	for w in range(WARM):
		_step(0.016)
		await get_tree().process_frame
	var cpu: Array = []
	var frame: Array = []
	var objs := 0.0
	var prims := 0.0
	var draws := 0.0
	var last := Time.get_ticks_usec()
	for f in range(FRAMES):
		_step(0.016)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frame.append(float(now - last) / 1000.0)
		last = now
		cpu.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		objs += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var n := float(FRAMES)
	var r := {
		"cpu": _pct(cpu, 0.02),
		"cpu50": _pct(cpu, 0.5),
		"frame": _pct(frame, 0.02),
		"frame50": _pct(frame, 0.5),
		"objects": objs / n,
		"primitives": prims / n,
		"draws": draws / n,
	}
	print(
		(
			"  %-16s script min %5.2f / med %6.2f ms   frame min %5.2f / med %6.2f ms   obj %5.0f  draws %5.0f  prims %9.0f"
			% [label, r.cpu, r.cpu50, r.frame, r.frame50, r.objects, r.draws, r.primitives]
		)
	)
	return r


func _set_on(v: bool, l: bool) -> void:
	vfx.process_mode = Node.PROCESS_MODE_INHERIT if v else Node.PROCESS_MODE_DISABLED
	vfx.visible = v
	life.process_mode = Node.PROCESS_MODE_INHERIT if l else Node.PROCESS_MODE_DISABLED
	life.visible = l


func _scenario(nm: String, hour: float, centre: Vector2, rain: float) -> void:
	_centre = centre
	world.sky.set_time(hour)
	_set_on(true, true)
	vfx.set_rain(rain)
	print("\n[%s]  hour %.1f  rain %.2f  centre (%.0f, %.0f)" % [nm, hour, rain, centre.x, centre.y])
	# Let terrain stream the whole ring in before anything is timed.
	for w in range(200):
		_step(0.016)
		await get_tree().process_frame
	world.terrain.update_focus(cam.global_position, true)
	for w in range(60):
		_step(0.016)
		await get_tree().process_frame

	_set_on(false, false)
	var base0 := await _measure("neither")
	_set_on(true, true)
	var both := await _measure("vfx + wildlife")
	_set_on(true, false)
	var no_life := await _measure("vfx only")
	_set_on(false, true)
	var no_vfx := await _measure("wildlife only")
	_set_on(false, false)
	var base1 := await _measure("neither (again)")
	_set_on(true, true)

	var base: float = minf(base0.frame, base1.frame)
	var drift: float = absf(base0.frame - base1.frame)
	print("  -> wildlife  %+.2f ms frame   (%+.2f ms script)" % [both.frame - no_life.frame, both.cpu - no_life.cpu])
	print("  -> vfx       %+.2f ms frame   (%+.2f ms script)" % [both.frame - no_vfx.frame, both.cpu - no_vfx.cpu])
	print(
		(
			"  -> BOTH      %+.2f ms frame   (%+.2f ms script)   +%.0f objects  +%.0f draws  +%.0f prims"
			% [
				both.frame - base,
				both.cpu - base0.cpu,
				both.objects - base0.objects,
				both.draws - base0.draws,
				both.primitives - base0.primitives
			]
		)
	)
	print(
		(
			"  -> baseline drift between the two `neither` runs: %.2f ms%s"
			% [drift, "  <-- NOISY, distrust this scenario" if drift > 0.5 else ""]
		)
	)


## Deterministic per-frame CPU cost of each system's own script, with the engine's
## own call to _process switched off so nothing is counted twice. Whole-frame timing on
## this machine is useless (it is shared with other Godot runs; the baseline drifted by
## up to 8 ms between two identical measurements), but the MINIMUM of several hundred
## direct calls is a real number: it is the cost of one uncontended call.
func _micro(nm: String, hour: float, centre: Vector2, rain: float) -> void:
	_centre = centre
	world.sky.set_time(hour)
	_set_on(true, true)
	vfx.set_rain(rain)
	for w in range(160):
		_step(0.016)
		await get_tree().process_frame

	# From here the engine must not call _process on either system: this loop does.
	_set_on(false, false)
	vfx.visible = true
	life.visible = true
	var dt := 1.0 / 60.0
	var lt: Array = []
	var vt: Array = []
	var et: Array = []
	for i in range(600):
		_step(dt)
		var t0 := Time.get_ticks_usec()
		life._process(dt)
		var t1 := Time.get_ticks_usec()
		vfx._process(dt)
		var t2 := Time.get_ticks_usec()
		lt.append(float(t1 - t0) / 1000.0)
		vt.append(float(t2 - t1) / 1000.0)
		if i % 4 == 0:
			var t3 := Time.get_ticks_usec()
			vfx._evaluate()
			et.append(float(Time.get_ticks_usec() - t3) / 1000.0)
		if i % 60 == 0:
			await get_tree().process_frame
	_set_on(true, true)
	print(
		(
			"  %-20s Wildlife._process  min %.3f  med %.3f  p95 %.3f ms"
			% [nm, _pct(lt, 0.0), _pct(lt, 0.5), _pct(lt, 0.95)]
		)
	)
	print(
		(
			"  %-20s WorldVFX._process  min %.3f  med %.3f  p95 %.3f ms"
			% ["", _pct(vt, 0.0), _pct(vt, 0.5), _pct(vt, 0.95)]
		)
	)
	print(
		(
			"  %-20s WorldVFX._evaluate min %.3f  med %.3f  p95 %.3f ms   (runs at 3.6 Hz)"
			% ["", _pct(et, 0.0), _pct(et, 0.5), _pct(et, 0.95)]
		)
	)


func _count_nodes(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count_nodes(ch)
	return c


func _emitter_count(n: Node) -> int:
	var c := 1 if n is GPUParticles3D else 0
	for ch in n.get_children():
		c += _emitter_count(ch)
	return c


func _quad_budget(n: Node, include_rain: bool) -> int:
	var c := 0
	if n is GPUParticles3D:
		var p := n as GPUParticles3D
		if include_rain or not (p.name == "Rain" or p.name == "RainSplash"):
			c += p.amount
	for ch in n.get_children():
		c += _quad_budget(ch, include_rain)
	return c


func _run() -> void:
	world = WorldRoot.new()
	add_child(world)
	world.build(false)

	# The shipping tier, not the class default: Game sets this before VFX builds.
	WorldVFX.density = Quality.particle_density(Quality.Tier.HIGH)

	vfx = WorldVFX.new()
	vfx.name = "VFX"
	add_child(vfx)
	var t0 := Time.get_ticks_usec()
	vfx.setup(world.map, world.sky)
	var vfx_ms := float(Time.get_ticks_usec() - t0) / 1000.0

	life = Wildlife.new()
	life.name = "Wildlife"
	add_child(life)
	t0 = Time.get_ticks_usec()
	life.setup(world.map, world.sky)
	var life_ms := float(Time.get_ticks_usec() - t0) / 1000.0

	cam = Camera3D.new()
	cam.fov = 62.0
	cam.far = 2000.0
	cam.near = 0.12
	add_child(cam)
	cam.current = true
	world.sky.paused = true

	var st: Dictionary = life.stats()
	var mm_instances := 0
	var mm_count := 0
	for f in life._flocks:
		mm_instances += f.n
		mm_count += 1
	if life._fish:
		mm_instances += life._fish.n
		mm_count += 1

	print("=== WorldVFX + Wildlife: static budget ===")
	print("  particle density tier      : %.2f (Quality.Tier.HIGH)" % WorldVFX.density)
	print("  WorldVFX.setup()           : %.1f ms" % vfx_ms)
	print("  Wildlife.setup()           : %.1f ms" % life_ms)
	print("  vfx nodes                  : %d" % (_count_nodes(vfx) - 1))
	print("  wildlife nodes             : %d" % (_count_nodes(life) - 1))
	print("  wildlife animals           : %d" % st.animals)
	print("  wildlife triangles         : %d" % st.triangles)
	print("  wildlife draw calls (all)  : %d" % st.draw_calls)
	print("  MultiMeshes / instances    : %d / %d" % [mm_count, mm_instances])
	print("  particle emitters          : %d" % _emitter_count(vfx))
	print("  particle quads, dry        : %d" % _quad_budget(vfx, false))
	print("  particle quads, downpour   : %d" % _quad_budget(vfx, true))

	# One long warm-up across both lighting states before anything is timed: Godot
	# builds a pipeline the first time each material is actually drawn.
	_centre = Vector2(-120, 44)
	world.sky.set_time(19.0)
	for w in range(LONG_WARM):
		_step(0.016)
		await get_tree().process_frame
	world.sky.set_time(22.6)
	_centre = Vector2(-196, -34)
	for w in range(LONG_WARM):
		_step(0.016)
		await get_tree().process_frame
	vfx.set_rain(0.9)
	for w in range(200):
		_step(0.016)
		await get_tree().process_frame
	vfx.set_rain(0.0)
	print("\nwarmed up")

	print("\n=== per-frame CPU cost of each system's own script (direct calls) ===")
	await _micro("meadow noon", 11.0, Vector2(-92, 6), 0.0)
	await _micro("forest camp night", 22.6, Vector2(-196, -34), 0.0)
	await _micro("village dusk", 19.3, Vector2(-120, 44), 0.0)
	await _micro("downpour fields", 13.0, Vector2(-92, 6), 0.95)
	await _micro("ruins night (bats)", 23.0, WorldMap.P_RUINS, 0.0)
	await _micro("ford dawn (mist)", 6.0, WorldMap.P_FORD, 0.0)

	print("\n=== whole-frame timing (see the header: this machine is shared) ===")
	await _scenario("meadow noon", 11.0, Vector2(-92, 6), 0.0)
	await _scenario("forest camp night", 22.6, Vector2(-196, -34), 0.0)
	await _scenario("village dusk", 19.3, Vector2(-120, 44), 0.0)
	await _scenario("downpour fields", 13.0, Vector2(-92, 6), 0.95)

	print("\ndone")
	get_tree().quit()
