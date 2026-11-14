extends Node
## What the quest layer costs per frame.
##
##   tools/gd.sh scene res://scenes/quest_qa_perf.tscn
##
## Measured the way ARCHITECTURE.md says to measure in this project: never by
## comparing two runs — two runs on the same build disagree by more than 10 ms — but
## by alternating the two conditions inside one process and taking the MEDIAN of the
## paired differences, so a single streaming hitch lands in one pair and the other
## pairs outvote it.
##
## Two places are measured, because they are the two worst cases the system has:
##   * the shrine forecourt, where five lit interactables and the objective marker
##     are on screen at once;
##   * the hidden grove, which is seven standing lamps, a heart and a particle field.
## Each is measured twice: the whole `Interactables` node on and off, then the
## `QuestSystem` (its polling and its marker) on and off.

const BLOCK := 20  # frames per block
const PAIRS := 22  # on/off pairs per condition
const BUDGET := 2.0  # ms/frame this layer is allowed

var game: Game
var quests: QuestSystem
var things: Interactables
var over_budget: Array[String] = []


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _block(n: int) -> float:
	var cpu := 0.0
	for i in range(n):
		await get_tree().process_frame
		cpu += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	return cpu / float(n)


func _median(v: Array[float]) -> float:
	if v.is_empty():
		return 0.0
	v.sort()
	var n := v.size()
	return v[n / 2] if n % 2 == 1 else (v[n / 2 - 1] + v[n / 2]) * 0.5


func _quartile(v: Array[float], q: float) -> float:
	if v.is_empty():
		return 0.0
	var s := v.duplicate()
	s.sort()
	return s[clampi(int(round(q * float(s.size() - 1))), 0, s.size() - 1)]


func _paired(label: String, setter: Callable) -> float:
	var diffs: Array[float] = []
	for r in range(PAIRS):
		setter.call(true)
		await get_tree().process_frame
		await get_tree().process_frame
		var on := await _block(BLOCK)
		setter.call(false)
		await get_tree().process_frame
		await get_tree().process_frame
		var off := await _block(BLOCK)
		diffs.append(on - off)
	setter.call(true)
	var med := _median(diffs)
	print(
		(
			"    %-26s %+7.3f ms   (quartiles %+.3f .. %+.3f over %d pairs of %d frames)"
			% [label, med, _quartile(diffs, 0.25), _quartile(diffs, 0.75), PAIRS, BLOCK]
		)
	)
	if med > BUDGET:
		over_budget.append("%s: %.2f ms" % [label, med])
	return med


func _set_things(on: bool) -> void:
	if things == null:
		return
	things.visible = on
	things.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED


func _set_quests(on: bool) -> void:
	if quests == null:
		return
	quests.visible = on
	quests.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED


func _stand(at: Vector2) -> void:
	var m: WorldMap = game.world.map
	game.player.global_position = Vector3(at.x, m.height_at(at.x, at.y) + 0.35, at.y)
	game.player.velocity = Vector3.ZERO
	game.world.terrain.update_focus(game.player.global_position, true)
	# Every material in view has to be drawn once before its pipeline is compiled.
	# That one-off is not a per-frame cost, so burn it off before measuring.
	for i in range(150):
		await get_tree().process_frame


func _run() -> void:
	game = Game.new()
	game.name = "Game"
	game.spawn_hud = false
	add_child(game)
	for i in range(90):
		await get_tree().process_frame
	game.player.lock_input(true)
	quests = game.quests as QuestSystem
	things = game.interactables as Interactables
	print("\n=== quest layer ===")
	print("  QuestSystem     : %s" % ("present" if quests != null else "MISSING"))
	print(
		(
			"  Interactables   : %s (%d objects)"
			% ["present" if things != null else "MISSING", things.get_child_count() if things != null else 0]
		)
	)
	if quests == null or things == null:
		print("\nRESULT: FAIL\n  ! the quest layer did not build")
		get_tree().quit(1)
		return

	# Both quests that put things on screen are opened, so the marker is live and the
	# shrine furniture is in the state a player would meet it in.
	quests.start_quest("q_lost_goat")
	quests.notify_talk("gopa")
	await get_tree().process_frame

	print("\n  the shrine forecourt (5 lit objects and the marker in view)")
	await _stand(Vector2(163.0, -72.0))
	await _paired("Interactables on/off", _set_things)
	await _paired("QuestSystem on/off", _set_quests)

	print("\n  the hidden grove (7 standing lamps, the heart, a particle field)")
	await _stand(Vector2(-318.0, 114.0))
	await _paired("Interactables on/off", _set_things)
	await _paired("QuestSystem on/off", _set_quests)

	print("\n  Panchavati (stall, fire, arrows; nothing of this system in view)")
	await _stand(Vector2(-123.0, 55.0))
	await _paired("Interactables on/off", _set_things)

	var fps := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	print("\n  whole-frame TIME_PROCESS at the last standpoint: %.2f ms" % fps)
	print("\nRESULT: " + ("PASS" if over_budget.is_empty() else "FAIL"))
	for o in over_budget:
		print("  ! over the %.1f ms budget — %s" % [BUDGET, o])
	get_tree().quit(0 if over_budget.is_empty() else 1)
