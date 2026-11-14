class_name SmokeCheck
extends Node
## A short end-to-end check that works on an EXPORTED build, where the test scenes are not
## shipped: boot a real session (HUD and Game, behind the loading screen), walk, fire an
## arrow, open and close the journal, then print `RESULT: PASS` or `RESULT: FAIL` and quit.
##
##   RAMA.app/Contents/MacOS/RAMA --headless -- --quiet-test --smoke
##
## The main menu hands over to this scene when `--smoke` is among the user arguments.
## Everything it reads is also checked from `tools/run_tests.py --exported <path>`.

const FLAG := "--smoke"
const SCENE := "res://scenes/smoke_check.tscn"
const TIMEOUT_SECONDS := 150.0

var _fails: Array[String] = []
var _done: bool = false


## True when this process was started with `-- --smoke`.
static func requested() -> bool:
	return OS.get_cmdline_user_args().has(FLAG)


func _ready() -> void:
	get_tree().create_timer(TIMEOUT_SECONDS).timeout.connect(_on_timeout)
	_run()


func _on_timeout() -> void:
	if _done:
		return
	_fails.append("the session did not come up within %d seconds" % int(TIMEOUT_SECONDS))
	_finish()


func _step(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _run() -> void:
	print("[smoke] build %s, engine %s" % [ProjectSettings.get_setting("application/config/version", "?"), Engine.get_version_info().string])
	# HUD.launch frees the current scene; this node must outlive it to finish the check.
	get_tree().current_scene = null
	var session := HUD.launch(get_tree())
	var game := session.get_node("Game") as Game
	await game.warm_up_done
	print("[smoke] world loaded, loading screen lifted")
	var p := game.player
	await _step(60)
	_check_world(game)
	await _check_walk(p)
	await _check_bow()
	await _check_journal(session.get_node("HUD") as HUD)
	_finish()


func _check_world(game: Game) -> void:
	if game.world == null or game.world.map == null:
		_fails.append("the world did not load")
		return
	var pos := game.player.global_position
	var ground := game.world.map.height_at(pos.x, pos.z)
	print("[smoke] player at %s, ground %.2f, on floor %s" % [pos, ground, game.player.is_on_floor()])
	if absf(pos.y - ground) > 0.8 or not game.player.is_on_floor():
		_fails.append("the player is not standing on the ground")


func _check_walk(p: Player) -> void:
	var before := p.global_position
	Input.action_press("move_forward")
	await _step(90)
	Input.action_release("move_forward")
	var moved := before.distance_to(p.global_position)
	print("[smoke] walked %.1f m in 1.5 s" % moved)
	if moved < 3.0:
		_fails.append("the player barely moved (%.1f m)" % moved)


func _check_bow() -> void:
	var arrows := GameState.arrows
	Input.action_press("aim")
	await _step(70)
	Input.action_release("aim")
	await _step(6)
	print("[smoke] arrows %d -> %d, in flight %d" % [arrows, GameState.arrows, get_tree().get_nodes_in_group("arrow").size()])
	if GameState.arrows != arrows - 1:
		_fails.append("drawing and releasing the bow did not fire an arrow")


func _check_journal(hud: HUD) -> void:
	hud.open_panel(hud.journal)
	await _step(4)
	var opened := hud.journal.visible
	hud.close_top()
	await _step(4)
	print("[smoke] journal opened %s, closed %s" % [opened, not hud.journal.visible])
	if not opened:
		_fails.append("the journal did not open")
	if hud.journal.visible:
		_fails.append("the journal did not close")


func _finish() -> void:
	if _done:
		return
	_done = true
	print("RESULT: " + ("PASS" if _fails.is_empty() else "FAIL"))
	for f in _fails:
		print("  ! " + f)
	get_tree().quit(0 if _fails.is_empty() else 1)
