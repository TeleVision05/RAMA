extends SceneTree
## QA PERFORMANCE, isolated. Terrain + sky + Settlement and nothing else.
##
## The full-game harness (tests/probes/qa_settle_perf.gd) is the number that matters, but its
## baseline frame carries vegetation, wildlife, VFX, water and the NPC directors, and on
## a machine running several other Godot sessions the variance of all that is larger
## than the effect being measured. Here the frame contains only the terrain and this
## system, so the same paired A/B has far less to hide in.
##
## Method: alternate Settlement.visible every 12 frames, 30 times, take the 25th
## percentile inside each block and difference each ON block against the off block that
## follows it. Report the median of those paired differences and their spread.

const SPOTS := [
	["village square", Vector2(-118.0, 50.0), Vector2(-128.0, 58.0)],
	["village road", Vector2(-96.0, 30.0), Vector2(-124.0, 54.0)],
	["shrine court", Vector2(168.0, -70.0), Vector2(154.0, -78.5)],
	["ruins", Vector2(-176.0, -120.0), Vector2(-168.0, -150.0)],
]
const PAIRS := 30
const BLOCK := 12

var world
var settle: Settlement
var cam: Camera3D


static func _pct(a: Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var b: Array = a.duplicate()
	b.sort()
	return b[clampi(int(float(b.size() - 1) * q), 0, b.size() - 1)]


func _block(on: bool) -> Array:
	settle.visible = on
	for w in range(4):
		await process_frame
	var out: Array = []
	var t_prev := Time.get_ticks_usec()
	for f in range(BLOCK):
		await process_frame
		var now := Time.get_ticks_usec()
		out.append(float(now - t_prev) / 1000.0)
		t_prev = now
	return out


func _init() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var root := get_root()
	world = WorldRoot.new()
	root.add_child(world)
	world.build(true)
	settle = Settlement.new()
	settle.name = "Settlement"
	world.add_child(settle)
	var t0 := Time.get_ticks_usec()
	settle.setup(world.map)
	var setup_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0

	# A --script SceneTree run opens a 100x100 window, which measures almost no GPU work
	# at all; force the real 1600x900 target so the draw cost is the shipped one.
	DisplayServer.window_set_size(Vector2i(1600, 900))
	root.size = Vector2i(1600, 900)
	cam = Camera3D.new()
	cam.fov = 60.0
	cam.far = 2000.0
	cam.near = 0.10
	root.add_child(cam)
	cam.current = true
	# look_at needs the node in the tree (ARCHITECTURE.md, "Node.look_at errors")
	await process_frame
	world.sky.paused = true
	world.sky.set_time(10.0)
	var vp := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)

	print("=== ISOLATED SETTLEMENT PERFORMANCE (terrain + sky + settlement only) ===")
	print("setup() wall clock: %.1f ms" % setup_ms)
	print("viewport: %s" % str(root.get_visible_rect().size))
	print("cores: %d" % OS.get_processor_count())

	# warm every spot in both configurations before measuring
	for spot in SPOTS:
		for on in [true, false]:
			_look(spot)
			settle.visible = on
			for w in range(45):
				await process_frame
	print("")
	print("%-16s %9s %9s %9s %9s %9s %9s" % ["spot", "on.p25", "off.p25", "cost", "spread", "+draws", "+prims"])

	var worst := 0.0
	var worst_spot := ""
	for spot in SPOTS:
		_look(spot)
		for w in range(20):
			await process_frame
		var diffs: Array = []
		var on_all: Array = []
		var off_all: Array = []
		var d_on := 0.0
		var d_off := 0.0
		var p_on := 0.0
		var p_off := 0.0
		for rep in range(PAIRS):
			var a: Array = await _block(true)
			d_on = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			p_on = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
			var b: Array = await _block(false)
			d_off = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			p_off = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
			diffs.append(_pct(a, 0.25) - _pct(b, 0.25))
			on_all.append_array(a)
			off_all.append_array(b)
		var cost: float = _pct(diffs, 0.5)
		var spread: float = _pct(diffs, 0.84) - _pct(diffs, 0.16)
		print(
			(
				"%-16s %9.2f %9.2f %+9.2f %9.2f %9.0f %9.0f"
				% [spot[0], _pct(on_all, 0.25), _pct(off_all, 0.25), cost, spread, d_on - d_off, p_on - p_off]
			)
		)
		if cost > worst:
			worst = cost
			worst_spot = String(spot[0])
	print("")
	print("WORST isolated settlement frame cost: %.2f ms at %s   (budget 9.00 ms)" % [worst, worst_spot])
	print("RESULT: " + ("PASS" if worst <= 9.0 else "FAIL"))
	quit(0 if worst <= 9.0 else 1)


func _look(spot: Array) -> void:
	var m = world.map
	var eye := Vector3(spot[1].x, m.height_at(spot[1].x, spot[1].y) + 1.7, spot[1].y)
	var tgt := Vector3(spot[2].x, m.height_at(spot[2].x, spot[2].y) + 1.7, spot[2].y)
	cam.global_position = eye
	cam.look_at(tgt, Vector3.UP)
	world.terrain.update_focus(eye, true)
