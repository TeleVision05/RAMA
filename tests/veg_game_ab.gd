extends Node
## Vegetation's marginal cost inside the REAL game (every other system present), in the
## village and on the forest road. Interleaved A/B, median of the paired differences.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/veg_game_ab.tscn
##
## B is not `process_mode = DISABLED`: Vegetation has no _process of its own, Game
## drives it from ITS _process, so disabling the node changes nothing. B nulls Game's
## reference (which stops update_focus) and hides the node.
const FRAMES := 45
const SETTLE := 15
const REPS := 9
var game: Game
var veg: Node3D
var _t := 0.0
var _a := Vector2(-140, 60)
var _b := Vector2(-96, 24)


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _run() -> void:
	game = Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	game.player.lock_input(true)
	veg = game.vegetation
	if veg == null:
		print("RESULT: FAIL  (Game did not instantiate Vegetation)")
		get_tree().quit(1)
		return
	for i in range(400):
		_walk()
		await get_tree().process_frame
	print("warmed up")

	var deltas: Array[float] = []
	var on: Array[float] = []
	var off: Array[float] = []
	for r in range(REPS):
		game.vegetation = veg
		veg.visible = true
		var a := await _sample()
		game.vegetation = null
		veg.visible = false
		var b := await _sample()
		deltas.append(a - b)
		on.append(a)
		off.append(b)
	game.vegetation = veg
	veg.visible = true
	deltas.sort()
	on.sort()
	off.sort()
	var mid := REPS / 2
	print("village walk : with %6.2f ms   without %6.2f ms" % [on[mid], off[mid]])
	print("VEGETATION   : %+.2f ms median of %d pairs (spread %+.2f .. %+.2f)" % [deltas[mid], REPS, deltas[0], deltas[REPS - 1]])
	print("RESULT: " + ("PASS" if deltas[mid] <= 9.0 else "FAIL") + "  (budget 9.0 ms, measured %+.2f ms)" % deltas[mid])
	get_tree().quit()


func _sample() -> float:
	_t = 0.0
	for i in range(SETTLE):
		_walk()
		await get_tree().process_frame
	_t = 0.0
	var acc := 0.0
	for i in range(FRAMES):
		_walk()
		await get_tree().process_frame
		acc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	return acc / float(FRAMES)


func _walk() -> void:
	_t += 8.0 / 60.0
	var d := _a.distance_to(_b)
	var s: float = fmod(_t, d * 2.0)
	var f: float = s / d if s <= d else (2.0 - s / d)
	var q := _a.lerp(_b, f)
	game.player.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 0.2, q.y)
