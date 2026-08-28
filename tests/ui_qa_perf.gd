extends Node
## What the interface costs per frame, measured so the answer survives being re-run.
##
##   tools/gd.sh scene res://scenes/ui_qa_perf.tscn
##
## Boots the game exactly as `scenes/game.tscn` does, reports whether the shipped Game
## actually produces an interface, then measures the HUD's frame cost.
##
## THE MEASUREMENT. Two things had to be got right before any number here meant
## anything, and both were got wrong first:
##
##  1. Interleave, do not compare runs. Two runs of this project on the same build
##     disagree by more than 10 ms — different shader-cache state, different streaming
##     state, a different thermal state. Comparing across them "showed" that a HUD
##     which was not drawing at all cost 4 ms MORE than one that was.
##
##  2. Take the median of PAIRED differences, not the difference of means. Even
##     interleaved, a single streaming hitch inside one block moves that block's mean
##     by 20 ms and drags the whole average with it; the same harness reported the
##     quiet HUD at +1.5 ms and then at -1.8 ms on consecutive runs. Pairing an "on"
##     block with the "off" block next to it and taking the median across many pairs
##     throws the hitches away, because a hitch lands in one pair and the other pairs
##     outvote it.
##
## The reported figure is the median paired difference, with the quartiles printed so
## a reader can see how much the number is worth.

const BLOCK := 20  # frames per block
const PAIRS := 24  # on/off pairs per condition
const BUDGET := 5.0  # ms/frame the interface is allowed

var game: Game
var hud: HUD
var over_budget: Array[String] = []


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _find_hud(n: Node, depth: int = 0) -> Node:
	if n is HUD:
		return n
	if depth > 3:
		return null
	for c in n.get_children():
		var r := _find_hud(c, depth + 1)
		if r != null:
			return r
	return null


## Mean TIME_PROCESS over `n` frames, in milliseconds.
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


## Alternate `on` and `off` and report the median of the paired differences.
## `setter` takes a bool and turns the thing being measured on or off.
func _paired(label: String, setter: Callable, indent: String = "  ") -> float:
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
			"%s%-20s %+7.3f ms   (quartiles %+.3f .. %+.3f over %d pairs of %d frames)"
			% [indent, label, med, _quartile(diffs, 0.25), _quartile(diffs, 0.75), PAIRS, BLOCK]
		)
	)
	return med


func _hud_setter(on: bool) -> void:
	if hud == null:
		return
	hud.visible = on
	hud.process_mode = Node.PROCESS_MODE_ALWAYS if on else Node.PROCESS_MODE_DISABLED


func _condition(label: String) -> float:
	var ms := await _paired(label, _hud_setter)
	if ms > BUDGET:
		over_budget.append("%s: %.2f ms" % [label, ms])
	return ms


func _run() -> void:
	game = Game.new()
	game.name = "Game"
	add_child(game)
	for i in range(60):
		await get_tree().process_frame

	hud = _find_hud(self) as HUD
	print("\n=== interface presence ===")
	print("  HUD found under the Game  : %s" % (hud.name if hud != null else "<none>"))
	print("  Game.hud                  : %s" % (game.hud.name if game.hud != null else "<null>"))
	if hud == null:
		print("\nRESULT: FAIL")
		print("  ! booting scenes/game.tscn produces no interface")
		get_tree().quit(1)
		return
	print("  HUD bound to player       : %s" % (hud.player != null))
	print("  HUD bound to camera rig   : %s" % (hud.cam_rig != null))

	game.player.lock_input(true)
	# Every material in this region has to be drawn once before its pipeline is
	# compiled; that one-off is not a per-frame cost.
	for i in range(180):
		await get_tree().process_frame

	print("\n=== what the interface costs, median paired difference ===")
	var quiet := await _condition("quiet")

	# Worst case: aiming at full draw, three cards up, low health, an objective, a
	# marker on the compass and an interaction prompt — everything at once.
	hud.notes.mute = true
	game.player.using_bow = true
	Input.action_press("aim")
	for i in range(40):
		await get_tree().physics_frame
	for i in range(6):
		EventBus.notify.emit("Gained", "Healing Herb %d" % i, "item")
	GameState.health = GameState.max_health * 0.3
	EventBus.player_damaged.emit(20.0, game.player)
	hud.vignette.set_hit_direction(-2.2)
	hud.objective.set_line("Find the tracks  (2/5)")
	hud.set_objective_marker(Vector3(WorldMap.P_SHRINE.x, 40.0, WorldMap.P_SHRINE.y))
	EventBus.interact_target_changed.emit(self, "Ring the temple bell")
	await get_tree().process_frame
	var busy := await _condition("busy (worst case)")

	# `--widgets` attributes the busy cost to an individual widget against the same
	# alternating baseline. Off by default: it costs eight more conditions, and while
	# the busy total sits inside the noise there is nothing to attribute. Measured
	# 2026-08-28, the two that were worth suspecting came back at nothing —
	# stat bars -0.10 ms, crosshair -0.18 ms.
	if OS.get_cmdline_user_args().has("--widgets"):
		print("\n  where the busy-state cost goes:")
		for w in [
			["stat bars", hud.bars],
			["crosshair", hud.crosshair],
			["ammo readout", hud.ammo],
			["objective line", hud.objective],
			["interact prompt", hud.prompt],
			["damage vignette", hud.vignette],
			["compass", hud.compass],
			["notifications", hud.notes]
		]:
			var ci: CanvasItem = w[1]
			await _paired(String(w[0]), func(on: bool): ci.visible = on, "    ")
	Input.action_release("aim")
	GameState.health = GameState.max_health
	hud.notes.clear_all()

	# A full-screen panel over a paused world.
	hud.open_panel(hud.inventory)
	for i in range(10):
		await get_tree().process_frame
	var panel := await _condition("inventory open")
	hud.close_all()
	for i in range(20):
		await get_tree().process_frame

	# The straight 300-frame reading, HUD on, normal play.
	_hud_setter(true)
	for i in range(20):
		await get_tree().process_frame
	var cpu := 0.0
	var phys := 0.0
	var peak := 0.0
	for i in range(300):
		await get_tree().process_frame
		var ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		cpu += ms
		peak = maxf(peak, ms)
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	print("\n=== 300 consecutive frames, HUD on, normal play ===")
	print("  Performance.TIME_PROCESS          : %.3f ms   (peak %.3f ms)" % [cpu / 300.0, peak])
	print("  Performance.TIME_PHYSICS_PROCESS  : %.3f ms" % (phys / 300.0))

	print("\n  interface budget: %.1f ms/frame" % BUDGET)
	print("  quiet %.2f   busy %.2f   panel %.2f" % [quiet, busy, panel])
	print("\nRESULT: " + ("PASS" if over_budget.is_empty() else "FAIL"))
	for o in over_budget:
		print("  ! over budget — " + o)
	get_tree().quit(0 if over_budget.is_empty() else 1)
