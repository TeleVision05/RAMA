extends Node
## What do the TREES cost, per frame, honestly?
##
## ARCHITECTURE is explicit that two separate runs on this project disagree by more than
## 10 ms, so this never compares one run against another. It alternates tree foliage ON
## and OFF inside ONE process, pairs each ON block with the OFF block beside it, and
## takes the MEDIAN of the paired differences — a mean is dragged around by a single
## streaming hitch.
##
## Trees only: the tree MultiMeshes are named "<species>_v<variant>_l<lod>", which is
## what separates them from the ground flora another system owns.

const PAIRS := 7
const SAMPLE := 42
const WARM := 26

var game: Game
var p: Player
var _t := 0.0
var _trees: Array[MultiMeshInstance3D] = []
var _flora: Array[Node3D] = []
var _chars: Array[Node3D] = []


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _step() -> void:
	_t += 0.016
	var c := Vector2(-120.0, 44.0)
	var q := c + Vector2(cos(_t * 0.9), sin(_t * 0.9)) * 30.0
	p.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 0.2, q.y)
	for n in [game.vegetation, game.vfx, game.wildlife, game.solids]:
		if n and n.has_method("update_focus"):
			n.update_focus(p.global_position)


func _collect() -> void:
	_trees.clear()
	var re := RegEx.new()
	re.compile("^(banyan|palm|mango|sal|dead|bush|rock)_v\\d+_l\\d+$")
	_flora.clear()
	for c in game.vegetation.get_children():
		if c is MultiMeshInstance3D:
			if re.search(c.name):
				_trees.append(c)
			else:
				_flora.append(c)
	_chars.clear()
	for grp in ["enemy", "npc"]:
		for n in get_tree().get_nodes_in_group(grp):
			if n is Node3D:
				_chars.append(n)


func _set_vis(arr: Array, on: bool) -> void:
	for m in arr:
		if is_instance_valid(m):
			m.visible = on


func _set_trees(on: bool) -> void:
	_set_vis(_trees, on)


func _block() -> float:
	for i in range(WARM):
		_step()
		await get_tree().process_frame
	var s: Array[float] = []
	for i in range(SAMPLE):
		_step()
		await get_tree().process_frame
		s.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	s.sort()
	return s[s.size() / 2]


func _run() -> void:
	game = Game.new()
	game.spawn_hud = false
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	p = game.player
	p.lock_input(true)
	var v := Vector2(-120.0, 44.0)
	p.global_position = Vector3(v.x, game.world.map.height_at(v.x, v.y) + 0.2, v.y)
	game.world.terrain.update_focus(p.global_position, true)
	for i in range(90):
		_step()
		await get_tree().process_frame
	_collect()

	_set_trees(true)
	await _block()
	var on_prims := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var on_draws := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_set_trees(false)
	await _block()
	var off_prims := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var off_draws := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)

	print("tree multimesh nodes: %d" % _trees.size())
	print("prims  with trees %d   without %d   -> trees = %d" % [on_prims, off_prims, on_prims - off_prims])
	print("draws  with trees %d   without %d   -> trees = %d" % [on_draws, off_draws, on_draws - off_draws])

	var groups := [["TREE foliage", _trees], ["ground flora", _flora], ["enemies + NPCs", _chars]]
	print("nodes: trees=%d flora=%d chars=%d" % [_trees.size(), _flora.size(), _chars.size()])
	var results := []
	for grp in groups:
		var label: String = grp[0]
		var arr: Array = grp[1]
		if arr.is_empty():
			continue
		var diffs: Array[float] = []
		for i in range(PAIRS):
			_set_vis(arr, true)
			var a := await _block()
			_set_vis(arr, false)
			var b := await _block()
			diffs.append(a - b)
		_set_vis(arr, true)
		diffs.sort()
		results.append([label, diffs[diffs.size() / 2], diffs[0], diffs[diffs.size() - 1]])
		print("  %-16s median %+6.2f ms  (min %+6.2f, max %+6.2f)" % [label, diffs[diffs.size() / 2], diffs[0], diffs[diffs.size() - 1]])
	print("")
	print("%-18s %10s" % ["system", "ms/frame"])
	var tree_ms := 0.0
	for r in results:
		print("%-18s %10.2f" % [r[0], r[1]])
		if str(r[0]).begins_with("TREE"):
			tree_ms = r[1]
	print("")
	print("TREE FOLIAGE: %.2f ms/frame against a ~9.00 ms budget" % tree_ms)
	print("RESULT: " + ("PASS" if tree_ms <= 9.0 else "FAIL"))
	get_tree().quit()
