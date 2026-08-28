extends SceneTree
## What the water system costs, measured rather than asserted.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . --script tests/water_perf.gd
##
## (windowed, NOT --headless: a headless run renders nothing and every frame time is the
## cost of an empty loop.)
##
## Two halves:
##   BUILD   setup() wall clock over several runs, plus the geometry it produced.
##   FRAME   200 frames at each viewpoint with the RiverWater node visible and then
##           hidden. The delta is the water's own frame cost. Reported alongside the
##           engine's own counters so the numbers can be cross-checked:
##             Performance.TIME_PROCESS                      CPU time in _process
##             RENDERING_TOTAL_OBJECTS_IN_FRAME              objects submitted
##             RENDERING_TOTAL_PRIMITIVES_IN_FRAME           primitives submitted
##
## vsync pins every reading at the 16.7 ms refresh and hides the difference entirely, so
## it is disabled here. Frame time is the honest measure of a fragment-bound shader;
## TIME_PROCESS is not, and is printed only to show it is NOT where the cost is.
##
## The visible/hidden pair is INTERLEAVED in short rounds and reduced with a MEDIAN, not
## measured as two long blocks and averaged. Measured 2026-08-28: with other Godot
## instances on the same machine the load average was 13-38 and a two-block mean put the
## water's cost at -4.8 ms at one viewpoint, i.e. the machine drifted more between the
## blocks than the water costs. Alternating cancels the drift; the median throws away the
## frames the scheduler stole. Absolute frame times under that load still mean nothing -
## only the paired delta does. Check `uptime` before quoting the absolute numbers.

const SPOTS := [
	{"n": "lookout", "p": Vector3(96, 0, -150), "eye": 6.0, "t": Vector3(-2, 0, -84), "tgt": 2.0},
	{"n": "falls", "p": Vector3(31, 0, -152), "eye": 10.0, "t": Vector3(35, 0, -191), "tgt": 7.0},
	{"n": "ford", "p": Vector3(-18, 0, 22), "eye": 3.0, "t": Vector3(-40, 0, -6), "tgt": 0.4},
	# Straight down at the widest reach: the worst case for a fragment-bound shader is
	# the water filling the whole frame at close range.
	{"n": "fill", "p": Vector3(-34, 0, 10), "eye": 8.0, "t": Vector3(-34, 0, 9), "tgt": 0.0},
]
const ROUNDS := 10  # interleaved on/off rounds per viewpoint
const BLOCK := 20  # frames measured per round per state -> 200 frames each
const SETTLE := 4  # frames discarded after toggling visibility
const WARM := 40
const BUDGET_MS := 9.0


func mean(a: Array) -> float:
	var s := 0.0
	for v in a:
		s += float(v)
	return s / maxf(float(a.size()), 1.0)


func median(a: Array) -> float:
	var b := a.duplicate()
	b.sort()
	return float(b[b.size() / 2])


func p95(a: Array) -> float:
	var b := a.duplicate()
	b.sort()
	return float(b[mini(int(float(b.size()) * 0.95), b.size() - 1)])


func _init() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(false)
	var m := world.map

	# --- BUILD ------------------------------------------------------------
	var builds: Array = []
	var water: RiverWater = null
	for run in range(3):
		var w := RiverWater.new()
		w.name = "Water%d" % run
		world.add_child(w)
		var t0 := Time.get_ticks_usec()
		w.setup(m, world.sky)
		builds.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		if run < 2:
			world.remove_child(w)
			w.queue_free()
		else:
			water = w
			w.name = "Water"
	print("\n=== RiverWater cost ===")
	print("[build] setup() %s ms over %d runs (mean %.1f)" % [str(builds), builds.size(), mean(builds)])

	var tris := 0
	var verts := 0
	var meshes := 0
	var mm := 0
	var parts := 0
	for c in water.get_children():
		if c is MeshInstance3D:
			meshes += 1
			var msh: Mesh = (c as MeshInstance3D).mesh
			for s in range(msh.get_surface_count()):
				var arr: Array = msh.surface_get_arrays(s)
				verts += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
				tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		elif c is MultiMeshInstance3D:
			mm += (c as MultiMeshInstance3D).multimesh.instance_count
		elif c is GPUParticles3D:
			parts += (c as GPUParticles3D).amount
	print(
		(
			"[build] %d nodes | %d MeshInstance3D (= draw calls) | %d MultiMesh instances | %d particles"
			% [water.get_child_count(), meshes, mm, parts]
		)
	)
	print("[build] %d triangles, %d vertices" % [tris, verts])

	# --- FRAME ------------------------------------------------------------
	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.far = 2000.0
	root.add_child(cam)
	cam.current = true
	await process_frame
	world.sky.paused = true
	world.sky.set_time(12.0)
	water.refresh_sky()

	var worst := 0.0
	var worst_at := ""
	for s in SPOTS:
		var eye := Vector3(s.p.x, m.height_at(s.p.x, s.p.z) + s.eye, s.p.z)
		cam.global_position = eye
		cam.look_at(Vector3(s.t.x, m.height_at(s.t.x, s.t.z) + s.tgt, s.t.z), Vector3.UP)
		world.terrain.update_focus(eye, true)
		water.visible = true
		for _i in range(WARM):
			await process_frame
		var all := {true: [], false: []}
		var rounds := {true: [], false: []}
		var proc := {true: 0.0, false: 0.0}
		var objs := {true: 0.0, false: 0.0}
		var prims := {true: 0.0, false: 0.0}
		for r in range(ROUNDS):
			for on in [true, false]:
				water.visible = on
				for _i in range(SETTLE):
					await process_frame
				var frames: Array = []
				for _i in range(BLOCK):
					var t0 := Time.get_ticks_usec()
					await process_frame
					frames.append(float(Time.get_ticks_usec() - t0) / 1000.0)
					proc[on] += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
					objs[on] += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
					prims[on] += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
				(all[on] as Array).append_array(frames)
				(rounds[on] as Array).append(median(frames))
		var n := float(ROUNDS * BLOCK)
		for k in [true, false]:
			proc[k] /= n
			objs[k] /= n
			prims[k] /= n
		var d: float = median(rounds[true]) - median(rounds[false])
		if d > worst:
			worst = d
			worst_at = String(s.n)
		print(
			(
				"[frame] %-8s on %.2f ms (p95 %.2f, %.0f fps) | off %.2f ms | WATER %+.2f ms  [%d frames each, %d interleaved rounds]"
				% [
					s.n,
					median(all[true]),
					p95(all[true]),
					1000.0 / median(all[true]),
					median(all[false]),
					d,
					all[true].size(),
					ROUNDS
				]
			)
		)
		print(
			(
				"        cpu _process %.3f -> %.3f ms | objects %.0f -> %.0f | primitives %.0f -> %.0f"
				% [proc[false], proc[true], objs[false], objs[true], prims[false], prims[true]]
			)
		)
		water.visible = true

	print("[frame] worst water cost %.2f ms at '%s' (budget %.1f ms)" % [worst, worst_at, BUDGET_MS])
	print("RESULT: " + ("PASS" if worst <= BUDGET_MS else "FAIL"))
	quit(0 if worst <= BUDGET_MS else 1)
