extends Node
## Walk a long circuit and watch node count, object count and memory. A streaming
## system that fails to free what it replaces shows up here as a monotonic climb, and
## it would degrade a real play session exactly the same way.
var game: Game


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _run() -> void:
	game = Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	p.lock_input(true)
	var t := 0.0
	var rows: Array = []
	var worst_orphans := 0
	for lap in range(7):
		for f in range(220):
			t += 0.016
			var q := Vector2(-120.0, 44.0) + Vector2(cos(t * 0.9), sin(t * 0.9)) * 46.0
			p.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 0.2, q.y)
			await get_tree().process_frame
		var ms := 0.0
		for f in range(60):
			await get_tree().process_frame
			ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		ms /= 60.0
		var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		var objs := int(Performance.get_monitor(Performance.OBJECT_COUNT))
		var mem := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
		var orph := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
		rows.append([nodes, objs, mem, ms])
		worst_orphans = maxi(worst_orphans, orph)
		print("  lap %d: nodes=%5d objects=%6d orphans=%4d mem=%6.1f MB  frame=%6.2f ms" % [lap, nodes, objs, orph, mem, ms])
	var first: Array = rows[1]
	var last: Array = rows[rows.size() - 1]
	var node_growth: int = last[0] - first[0]
	var mem_growth: float = last[2] - first[2]
	var slowdown: float = last[3] - first[3]
	print("growth after 5 laps: nodes %+d  memory %+.1f MB  frame %+.2f ms" % [node_growth, mem_growth, slowdown])
	# Frame time is reported but NOT asserted: this suite runs while other Godot
	# processes may be on the same machine, and contention shows up here as a spike
	# that has nothing to do with the game. Node and memory growth are what prove
	# whether the streamers actually free what they replace.
	var ok: bool = node_growth < 250 and mem_growth < 25.0
	# An orphan is a node that was built and never added to the tree or freed: it lives
	# until exit and is reported there as a leak. The humanoid animation sources once
	# left 16 of them on every run (2026-11-13); there is no reason for even one.
	if worst_orphans > 0:
		ok = false
		print("  ! %d orphan nodes (built, never added to the tree, never freed)" % worst_orphans)
	print("RESULT: " + ("PASS" if ok else "FAIL (streaming leaks nodes or memory, or nodes were orphaned)"))
	get_tree().quit(0 if ok else 1)
