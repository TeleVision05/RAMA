extends Node
## Registers every input action and its bindings IN CODE, at startup.
##
## Why not project.godot: the `[input]` section there needs Godot 4's
## `Object(InputEventKey, ...)` constructor syntax. Hand-written Godot-3-style
## dictionaries are accepted by the parser, create the ACTION, and then silently drop
## every event — so the game launched with eighteen actions and not one key bound to
## any of them, and nothing complained.
##
## Doing it here means the bindings are code, reviewable and testable, and
## `tests/input_probe.gd` asserts every action has at least one usable event.

const BINDINGS := {
	"move_forward": {"keys": [KEY_W, KEY_UP], "axis": [[JOY_AXIS_LEFT_Y, -1.0]]},
	"move_back": {"keys": [KEY_S, KEY_DOWN], "axis": [[JOY_AXIS_LEFT_Y, 1.0]]},
	"move_left": {"keys": [KEY_A, KEY_LEFT], "axis": [[JOY_AXIS_LEFT_X, -1.0]]},
	"move_right": {"keys": [KEY_D, KEY_RIGHT], "axis": [[JOY_AXIS_LEFT_X, 1.0]]},
	"sprint": {"keys": [KEY_SHIFT], "pad": [JOY_BUTTON_LEFT_STICK]},
	"jump": {"keys": [KEY_SPACE], "pad": [JOY_BUTTON_A]},
	"dodge": {"keys": [KEY_CTRL, KEY_C], "pad": [JOY_BUTTON_B]},
	"attack": {"mouse": [MOUSE_BUTTON_LEFT], "pad": [JOY_BUTTON_X]},
	"aim": {"mouse": [MOUSE_BUTTON_RIGHT], "axis": [[JOY_AXIS_TRIGGER_LEFT, 1.0]]},
	"interact": {"keys": [KEY_E], "pad": [JOY_BUTTON_Y]},
	"swap_weapon": {"keys": [KEY_Q], "pad": [JOY_BUTTON_LEFT_SHOULDER]},
	"journal": {"keys": [KEY_J], "pad": [JOY_BUTTON_BACK]},
	"inventory": {"keys": [KEY_I, KEY_TAB]},
	"pause": {"keys": [KEY_ESCAPE], "pad": [JOY_BUTTON_START]},
	"quick_save": {"keys": [KEY_F5]},
	"quick_load": {"keys": [KEY_F6]},
	"dev_screenshot": {"keys": [KEY_F7]},
	"dev_time": {"keys": [KEY_T]},
	"ui_confirm_alt": {"keys": [KEY_ENTER, KEY_KP_ENTER]},
	"parry": {"keys": [KEY_F], "pad": [JOY_BUTTON_RIGHT_SHOULDER]},
	"crouch": {"keys": [KEY_V, KEY_Z]},
	"quick_heal": {"keys": [KEY_H]},
	"cycle_astra": {"keys": [KEY_R]},
	"astra_1": {"keys": [KEY_1]},
	"astra_2": {"keys": [KEY_2]},
	"astra_3": {"keys": [KEY_3]},
	"astra_4": {"keys": [KEY_4]},
	"astra_5": {"keys": [KEY_5]},
}


func _ready() -> void:
	install()


## Idempotent: safe to call again after a settings change or a remap.
static func install() -> void:
	for action in BINDINGS:
		var name := String(action)
		if not InputMap.has_action(name):
			InputMap.add_action(name, 0.2)
		else:
			InputMap.action_set_deadzone(name, 0.2)
		var spec: Dictionary = BINDINGS[action]

		for kc in spec.get("keys", []):
			if _has_key(name, kc):
				continue
			var e := InputEventKey.new()
			# Physical keycode: position on the keyboard, so WASD stays WASD on AZERTY.
			e.physical_keycode = kc
			e.keycode = kc
			InputMap.action_add_event(name, e)

		for mb in spec.get("mouse", []):
			var em := InputEventMouseButton.new()
			em.button_index = mb
			InputMap.action_add_event(name, em)

		for pb in spec.get("pad", []):
			var ep := InputEventJoypadButton.new()
			ep.button_index = pb
			InputMap.action_add_event(name, ep)

		for ax in spec.get("axis", []):
			var ea := InputEventJoypadMotion.new()
			ea.axis = ax[0]
			ea.axis_value = ax[1]
			InputMap.action_add_event(name, ea)


static func _has_key(action: String, keycode: int) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventKey and (e as InputEventKey).physical_keycode == keycode:
			return true
	return false
