extends Node
## Quiet mode: the game runs without taking anything from the person at the keyboard.
##
## The test gate runs while someone is using the same computer. A windowed test run
## once grabbed their mouse, because the camera captures the cursor the moment a
## session starts. This autoload is the ONE place that decides whether the game may
## capture the mouse, pull its window to the front, or make a sound.
##
## Quiet mode is on when either:
##   * the display server is headless (`--headless`), or
##   * the user argument `--quiet-test` is passed:  Godot --path . <scene> -- --quiet-test
##
## In quiet mode the game:
##   * never sets the mouse to captured or confined; the cursor stays free;
##   * never moves its window to the foreground, and marks the window no-focus;
##   * mutes the Master bus, so nothing reaches the speakers. Players still report
##     `playing`, so the audio tests see the same state they always did.
##
## Gameplay does not change. The game still REMEMBERS that it asked for a captured
## mouse, and `is_mouse_look()` answers from that, so the camera turns from synthetic
## mouse-motion events exactly as it would from a real mouse.

const FLAG := "--quiet-test"

## True when this run must not touch the mouse, the focus or the speakers.
var active: bool = false

# The mouse mode the game asked for, which is not always the one it was given.
var _wanted_mouse: Input.MouseMode = Input.MOUSE_MODE_VISIBLE


func _enter_tree() -> void:
	active = detect()
	if not active:
		return
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if DisplayServer.get_name() != "headless":
		_calm_window()
	print("[quiet] quiet mode on: mouse never captured, window never focused, audio muted")


## Whether this process was started in quiet mode. Static so it can be asked before
## the autoload exists (for example from a `--script` test).
static func detect() -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	return OS.get_cmdline_user_args().has(FLAG) or OS.get_cmdline_args().has(FLAG)


## Every write to the mouse mode goes through here.
func set_mouse_mode(mode: Input.MouseMode) -> void:
	_wanted_mouse = mode
	if active and _takes_the_mouse(mode):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	Input.mouse_mode = mode


## Whether mouse motion should turn the camera: the game asked for a captured mouse.
## Outside quiet mode this is exactly the real mouse mode, as it always was.
func is_mouse_look() -> bool:
	if active:
		return _wanted_mouse == Input.MOUSE_MODE_CAPTURED
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


## Bring the game window to the front, unless it must stay out of the way.
func bring_to_front() -> void:
	if active:
		return
	DisplayServer.window_move_to_foreground()


static func _takes_the_mouse(mode: Input.MouseMode) -> bool:
	return mode in [Input.MOUSE_MODE_CAPTURED, Input.MOUSE_MODE_CONFINED, Input.MOUSE_MODE_CONFINED_HIDDEN]


# A real window exists (a test that needs rendered pixels). It cannot be made
# invisible from here, because it was created before any script ran; the test runner
# launches the process hidden and in the background. This makes sure the game itself
# never asks for focus and never catches a stray click.
func _calm_window() -> void:
	var w := get_window()
	if w == null:
		return
	w.set_flag(Window.FLAG_NO_FOCUS, true)
	w.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
