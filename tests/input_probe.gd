extends Node
## Verifies input END TO END, the way a keyboard does it.
##
## The playtest drives the game with `Input.action_press()`, which sets an action's
## state DIRECTLY and never consults the InputMap. That is why it passed for hours
## while the shipped game had eighteen actions and not one key bound to any of them.
## This test synthesises real InputEventKey/MouseButton events through
## `Input.parse_input_event()`, so a missing binding fails here.

const KEY_CHECKS := {
	"move_forward": KEY_W,
	"move_back": KEY_S,
	"move_left": KEY_A,
	"move_right": KEY_D,
	"sprint": KEY_SHIFT,
	"jump": KEY_SPACE,
	"dodge": KEY_CTRL,
	"interact": KEY_E,
	"swap_weapon": KEY_Q,
	"journal": KEY_J,
	"inventory": KEY_I,
	"pause": KEY_ESCAPE,
	"quick_save": KEY_F5,
	"quick_load": KEY_F6,
	"dev_screenshot": KEY_F7,
	"dev_time": KEY_T,
}
const MOUSE_CHECKS := {"attack": MOUSE_BUTTON_LEFT, "aim": MOUSE_BUTTON_RIGHT}


func _ready() -> void:
	# Settle before touching input. `parse_input_event` is queued, and the action state
	# it feeds is only updated on the input flush, so pressing a key on the very first
	# frame raced and intermittently reported the first action as not triggered.
	for i in range(6):
		await get_tree().process_frame
	_run()


func _run() -> void:
	var fails: Array[String] = []

	# 1. Every action must exist and carry at least one event.
	for a in KEY_CHECKS.keys() + MOUSE_CHECKS.keys():
		var name := String(a)
		if not InputMap.has_action(name):
			fails.append(name + ": action does not exist")
		elif InputMap.action_get_events(name).is_empty():
			fails.append(name + ": no events bound")

	# 2. A real key event must actually raise the action.
	for a in KEY_CHECKS:
		var name := String(a)
		if not InputMap.has_action(name):
			continue
		var kc: int = KEY_CHECKS[a]
		var down := InputEventKey.new()
		down.physical_keycode = kc
		down.pressed = true
		Input.parse_input_event(down)
		Input.flush_buffered_events()
		await get_tree().process_frame
		var got := Input.is_action_pressed(name)
		var up := InputEventKey.new()
		up.physical_keycode = kc
		up.pressed = false
		Input.parse_input_event(up)
		Input.flush_buffered_events()
		await get_tree().process_frame
		print("  %-16s %-10s -> %s" % [name, OS.get_keycode_string(kc), "OK" if got else "NOT TRIGGERED"])
		if not got:
			fails.append("%s: pressing %s does not raise the action" % [name, OS.get_keycode_string(kc)])
		if Input.is_action_pressed(name):
			fails.append("%s: still held after key release" % name)

	for a in MOUSE_CHECKS:
		var name := String(a)
		if not InputMap.has_action(name):
			continue
		var btn: int = MOUSE_CHECKS[a]
		var d := InputEventMouseButton.new()
		d.button_index = btn
		d.pressed = true
		Input.parse_input_event(d)
		Input.flush_buffered_events()
		await get_tree().process_frame
		var got2 := Input.is_action_pressed(name)
		var u := InputEventMouseButton.new()
		u.button_index = btn
		u.pressed = false
		Input.parse_input_event(u)
		Input.flush_buffered_events()
		await get_tree().process_frame
		print("  %-16s mouse %-4d -> %s" % [name, btn, "OK" if got2 else "NOT TRIGGERED"])
		if not got2:
			fails.append("%s: mouse button %d does not raise the action" % [name, btn])

	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)
