class_name PauseMenu
extends Control
## The pause screen. Deliberately short: a held breath, not a control room.
##
## It only raises intent; the HUD owns the state machine that decides what a menu
## request means, so this file never touches the tree's paused flag or the mouse.

signal resume_requested
signal save_requested
signal load_requested
signal settings_requested
signal journal_requested
signal main_menu_requested
signal quit_requested

var _panel_style: StyleBoxTexture
var _confirm: String = ""  # "" | "main_menu" | "quit"
var _buttons: Array = []
var _box: VBoxContainer
var _frame: PanelContainer
var _t: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Offsets must be reset too: setting anchors alone on a node that is already
	# in the tree preserves the current (zero) rect and the panel never grows.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme()
	_panel_style = UITheme.panel_style(Color(0.062, 0.049, 0.040, 0.94), 0)
	_build()
	set_process(true)


func _process(delta: float) -> void:
	_t += delta
	_recentre()
	queue_redraw()


func _build() -> void:
	_frame = PanelContainer.new()
	_frame.name = "Frame"
	_frame.add_theme_stylebox_override("panel", _panel_style)
	_frame.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_frame.custom_minimum_size = Vector2(330, 0)
	add_child(_frame)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 30)
	margin.add_theme_constant_override("margin_right", 30)
	margin.add_theme_constant_override("margin_top", 26)
	margin.add_theme_constant_override("margin_bottom", 24)
	_frame.add_child(margin)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 2)
	margin.add_child(_box)

	var head := Label.new()
	head.text = "PAUSED"
	head.theme_type_variation = "Eyebrow"
	_box.add_child(head)

	var rule := Control.new()
	rule.custom_minimum_size = Vector2(0, 16)
	rule.draw.connect(func(): UITheme.carved_rule(rule, Vector2(0, 8), rule.size.x))
	_box.add_child(rule)

	_add_button("Resume", func(): _emit(resume_requested))
	_add_button("Journal", func(): _emit(journal_requested))
	_add_button("Save", func(): _emit(save_requested))
	_add_button("Load", func(): _emit(load_requested))
	_add_button("Settings", func(): _emit(settings_requested))

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 14)
	_box.add_child(gap)

	_add_button("Return to Title", func(): _ask("main_menu"))
	_add_button("Quit", func(): _ask("quit"))

	await get_tree().process_frame
	_recentre()
	_frame.resized.connect(_recentre)


func _add_button(text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.theme_type_variation = "Menu"
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_ALL
	b.pressed.connect(cb)
	b.mouse_entered.connect(func(): AudioDirector.play_ui("ui_hover"))
	_box.add_child(b)
	_buttons.append(b)


func _emit(sig: Signal) -> void:
	AudioDirector.play_ui("ui_click")
	_confirm = ""
	sig.emit()


## Leaving the world is the one thing here that can lose progress, so it asks twice.
func _ask(what: String) -> void:
	AudioDirector.play_ui("ui_click")
	if _confirm != what:
		_confirm = what
		queue_redraw()
		return
	_confirm = ""
	if what == "main_menu":
		main_menu_requested.emit()
	else:
		quit_requested.emit()


func opened() -> void:
	_confirm = ""
	if not _buttons.is_empty():
		(_buttons[0] as Button).grab_focus()
	queue_redraw()


func confirming() -> String:
	return _confirm


func _recentre() -> void:
	if _frame == null or _frame.size.y <= 0.0:
		return
	var want: Vector2 = ((size - _frame.size) * 0.5).round()
	if _frame.position.distance_squared_to(want) > 0.25:
		_frame.position = want


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_recentre()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.020, 0.016, 0.012, 0.58), true)
	if _frame == null:
		return
	if _confirm != "":
		var msg: String = "Press again to return to the title." if _confirm == "main_menu" else "Press again to quit."
		var f := UITheme.body_font()
		var w := UITheme.text_width(f, msg, UITheme.FS_SMALL)
		var pulse: float = 0.72 + 0.28 * sin(_t * 4.4)
		UITheme.draw_text(
			self,
			f,
			Vector2(_frame.position.x + (_frame.size.x - w) * 0.5, _frame.position.y + _frame.size.y + 30.0),
			msg,
			UITheme.FS_SMALL,
			Color(UITheme.CRIMSON_PALE.r, UITheme.CRIMSON_PALE.g, UITheme.CRIMSON_PALE.b, pulse)
		)
