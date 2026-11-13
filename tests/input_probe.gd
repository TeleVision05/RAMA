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
	"parry": KEY_F,
	"crouch": KEY_V,
	"quick_heal": KEY_H,
	"cycle_astra": KEY_R,
	"astra_1": KEY_1,
	"astra_2": KEY_2,
	"astra_3": KEY_3,
	"astra_4": KEY_4,
	"astra_5": KEY_5,
}
const MOUSE_CHECKS := {"attack": MOUSE_BUTTON_LEFT, "aim": MOUSE_BUTTON_RIGHT}


func _ready() -> void:
	# Settle before touching input. `parse_input_event` is queued, and the action state
	# it feeds is only updated on the input flush, so pressing a key on the very first
	# frame raced and intermittently reported the first action as not triggered.
	QuietMode.bring_to_front()
	for i in range(10):
		await get_tree().process_frame
	var warm := InputEventKey.new()
	warm.physical_keycode = KEY_SHIFT
	warm.pressed = false
	Input.parse_input_event(warm)
	Input.flush_buffered_events()
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
		down.keycode = kc
		down.pressed = true
		Input.parse_input_event(down)
		Input.flush_buffered_events()
		await get_tree().process_frame
		var got := Input.is_action_pressed(name)
		var up := InputEventKey.new()
		up.physical_keycode = kc
		up.keycode = kc
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

	await _check_mouse_look(fails)

	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)


## 3. Mouse look. A synthetic mouse-motion event must turn the camera, in quiet mode
## too, where the cursor is never actually captured. If this breaks, quiet mode has
## changed gameplay rather than only keeping the game out of the user's way.
func _check_mouse_look(fails: Array[String]) -> void:
	var cam := PlayerCamera.new()
	add_child(cam)
	await get_tree().process_frame
	var yaw0 := cam.yaw
	var pitch0 := cam.pitch
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(120.0, 40.0)
	Input.parse_input_event(mm)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var turned := absf(cam.yaw - yaw0) > 0.1 and absf(cam.pitch - pitch0) > 0.01
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var verdict := "OK" if turned else "NOT TURNED"
	print("  %-16s motion     -> %s (quiet=%s, cursor captured=%s)" % ["mouse look", verdict, QuietMode.active, captured])
	if not turned:
		fails.append("mouse look: a mouse-motion event did not turn the camera")
	if QuietMode.active and captured:
		fails.append("mouse look: quiet mode captured the cursor")
	QuietMode.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	cam.queue_free()
	await get_tree().process_frame
