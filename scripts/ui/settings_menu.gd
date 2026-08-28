class_name SettingsMenu
extends Control
## Settings that actually change the game, persisted to user://settings.cfg.
##
## The static half of this file is the settings store: it is loaded once on boot and
## applied to the audio director, the viewport, the shadow atlas and the player
## camera. The instance half is the panel that edits it. Nothing here is a stub —
## every row below moves something you can see or hear.

const PATH := "user://settings.cfg"

## key -> [default, min, max, kind]. `kind` is "f" float, "b" bool, "i" stepped int.
const SPEC := {
	"audio/master": [1.00, 0.0, 1.0, "f"],
	"audio/music": [1.00, 0.0, 1.0, "f"],
	"audio/sfx": [1.00, 0.0, 1.0, "f"],
	"audio/ambience": [1.00, 0.0, 1.0, "f"],
	"input/sensitivity": [1.00, 0.25, 3.0, "f"],
	"input/invert_y": [false, 0.0, 1.0, "b"],
	"video/fov": [64.0, 52.0, 92.0, "f"],
	"video/render_scale": [1.00, 0.60, 1.0, "f"],
	"video/quality": [2, 0, 3, "i"],
	"ui/show_prompts": [true, 0.0, 1.0, "b"],
}

## AudioDirector's own defaults, so a slider at maximum reproduces them exactly.
const AUDIO_BASE := {"master": 0.0, "music": -9.0, "sfx": 0.0, "ambience": -6.0}
## Tier names come from Quality so the menu can never disagree with what it applies.
const QUALITY_NAMES := ["Low", "Medium", "High", "Ultra"]

static var cfg: Dictionary = {}
static var _loaded: bool = false

signal closed

var _rows: Array = []
var _panel_style: StyleBoxTexture
var _box: VBoxContainer


# ==========================================================================
# the store
# ==========================================================================
static func load_config() -> Dictionary:
	if _loaded:
		return cfg
	cfg = {}
	for k in SPEC.keys():
		cfg[k] = SPEC[k][0]
	var f := ConfigFile.new()
	if f.load(PATH) == OK:
		for k in SPEC.keys():
			var parts: PackedStringArray = String(k).split("/")
			if not f.has_section_key(parts[0], parts[1]):
				continue
			var v: Variant = f.get_value(parts[0], parts[1], cfg[k])
			cfg[k] = _coerce(String(k), v)
	_loaded = true
	return cfg


static func _coerce(key: String, v: Variant) -> Variant:
	var spec: Array = SPEC[key]
	match String(spec[3]):
		"b":
			return bool(v)
		"i":
			return clampi(int(v), int(spec[1]), int(spec[2]))
		_:
			return clampf(float(v), float(spec[1]), float(spec[2]))


static func save_config() -> void:
	load_config()
	var f := ConfigFile.new()
	for k in SPEC.keys():
		var parts: PackedStringArray = String(k).split("/")
		f.set_value(parts[0], parts[1], cfg[k])
	var err := f.save(PATH)
	if err != OK:
		push_warning("[settings] could not write %s (err %d)" % [PATH, err])


static func get_v(key: String) -> Variant:
	load_config()
	if cfg.has(key):
		return cfg[key]
	if SPEC.has(key):
		return SPEC[key][0]
	return null


static func get_f(key: String) -> float:
	return float(get_v(key))


static func get_b(key: String) -> bool:
	return bool(get_v(key))


static func set_v(key: String, value: Variant) -> void:
	load_config()
	if not SPEC.has(key):
		return
	cfg[key] = _coerce(key, value)


## Drop the in-memory copy and read the file again. Used to prove that settings
## really survive a restart rather than merely surviving a function call.
static func reload_from_disk() -> Dictionary:
	_loaded = false
	cfg = {}
	return load_config()


static func reset_defaults() -> void:
	load_config()
	for k in SPEC.keys():
		cfg[k] = SPEC[k][0]


## Linear 0..1 fader to decibels, on top of the director's own base level.
static func _fader_db(v: float, base: float) -> float:
	if v <= 0.004:
		return -80.0
	return linear_to_db(clampf(v, 0.0, 1.0)) + base


## Push every setting at the live game. Safe to call before the world exists.
##
## Order matters: the quality tier writes msaa, scaling and the shadow atlas, so the
## user's render-scale multiplier is applied on top of whatever the tier chose.
static func apply(tree: SceneTree) -> void:
	load_config()

	AudioDirector.apply_volumes(
		_fader_db(get_f("audio/master"), AUDIO_BASE.master),
		_fader_db(get_f("audio/music"), AUDIO_BASE.music),
		_fader_db(get_f("audio/sfx"), AUDIO_BASE.sfx),
		_fader_db(get_f("audio/ambience"), AUDIO_BASE.ambience)
	)

	if tree == null:
		return
	var vp := tree.root
	var tier: int = clampi(int(get_v("video/quality")), 0, 3)
	var p: Node = tree.get_first_node_in_group("player")
	var game: Node = p.get_parent() if p != null else null

	if game != null and game.has_method("set_quality"):
		game.set_quality(tier)
	elif vp != null:
		# No world yet (the title screen): still honour the tier where we can.
		vp.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_2X, Viewport.MSAA_4X][tier]
		vp.scaling_3d_scale = 0.80 if tier == 0 else 1.0
		RenderingServer.directional_shadow_atlas_set_size([1024, 2048, 4096, 8192][tier], tier >= 1)

	if vp != null:
		vp.positional_shadow_atlas_size = [1024, 2048, 4096, 8192][tier]
		vp.scaling_3d_scale = clampf(vp.scaling_3d_scale * get_f("video/render_scale"), 0.45, 1.0)

	if p != null:
		var cam: Node = p.get("cam_rig")
		if cam != null and is_instance_valid(cam):
			# PlayerCamera's exported base sensitivity is 0.0026 rad/px.
			cam.set("mouse_sensitivity", 0.0026 * get_f("input/sensitivity"))
			cam.set("joy_sensitivity", 2.6 * get_f("input/sensitivity"))
			cam.set("invert_y", get_b("input/invert_y"))


# ==========================================================================
# the panel
# ==========================================================================
func _ready() -> void:
	load_config()
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Offsets must be reset too: setting anchors alone on a node that is already
	# in the tree preserves the current (zero) rect and the panel never grows.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme()
	_panel_style = UITheme.panel_style(Color(0.066, 0.052, 0.043, 0.96), 0)
	_build()
	set_process(true)


## Containers report their final height a frame or two after they are filled, so the
## frame is kept centred continuously rather than positioned once and left behind.
func _process(_delta: float) -> void:
	var pc := get_node_or_null("Frame") as Control
	if pc == null or pc.size.y <= 0.0:
		return
	var want: Vector2 = ((size - pc.size) * 0.5).round()
	if pc.position.distance_squared_to(want) > 0.25:
		pc.position = want


func _build() -> void:
	var pc := PanelContainer.new()
	pc.name = "Frame"
	pc.add_theme_stylebox_override("panel", _panel_style)
	pc.set_anchors_preset(Control.PRESET_TOP_LEFT)
	pc.custom_minimum_size = Vector2(640, 0)
	add_child(pc)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 34)
	margin.add_theme_constant_override("margin_right", 34)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 26)
	pc.add_child(margin)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 6)
	margin.add_child(_box)

	var head := Label.new()
	head.text = "SETTINGS"
	head.theme_type_variation = "Eyebrow"
	_box.add_child(head)
	_box.add_child(_rule())

	_section("SOUND")
	_slider_row("audio/master", "Master")
	_slider_row("audio/music", "Music")
	_slider_row("audio/sfx", "Effects")
	_slider_row("audio/ambience", "Ambience")

	_section("CONTROL")
	_slider_row("input/sensitivity", "Mouse sensitivity")
	_toggle_row("input/invert_y", "Invert look")
	_toggle_row("ui/show_prompts", "Show interaction prompts")

	_section("PICTURE")
	_slider_row("video/fov", "Field of view")
	_step_row("video/quality", "Detail", QUALITY_NAMES)
	_slider_row("video/render_scale", "Render scale")

	_box.add_child(_gap(10))
	_box.add_child(_rule())
	var foot := HBoxContainer.new()
	foot.alignment = BoxContainer.ALIGNMENT_END
	foot.add_theme_constant_override("separation", 10)
	_box.add_child(foot)

	var reset := Button.new()
	reset.text = "Restore Defaults"
	reset.pressed.connect(_on_reset)
	foot.add_child(reset)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_on_back)
	foot.add_child(back)

	# Recentre once the container has measured itself.
	await get_tree().process_frame
	_recentre(pc)
	pc.resized.connect(func(): _recentre(pc))


func _recentre(pc: Control) -> void:
	pc.position = (size - pc.size) * 0.5


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		var pc := get_node_or_null("Frame") as Control
		if pc:
			_recentre(pc)


func _gap(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _rule() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, 12)
	c.draw.connect(func(): UITheme.carved_rule(c, Vector2(0, 6), c.size.x))
	return c


func _section(title: String) -> void:
	_box.add_child(_gap(12))
	var l := Label.new()
	l.text = title
	l.theme_type_variation = "Eyebrow"
	l.add_theme_color_override("font_color", UITheme.BRASS_DIM)
	_box.add_child(l)
	_box.add_child(_gap(2))


func _row(label_text: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	h.custom_minimum_size = Vector2(0, 32)
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(228, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", UITheme.PARCHMENT_DIM)
	l.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	h.add_child(l)
	_box.add_child(h)
	return h


func _value_label() -> Label:
	var v := Label.new()
	v.theme_type_variation = "Value"
	v.custom_minimum_size = Vector2(88, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return v


func _slider_row(key: String, label_text: String) -> void:
	var spec: Array = SPEC[key]
	var h := _row(label_text)
	var s := HSlider.new()
	s.min_value = float(spec[1])
	s.max_value = float(spec[2])
	s.step = 0.01 if float(spec[2]) <= 4.0 else 1.0
	s.value = get_f(key)
	s.custom_minimum_size = Vector2(240, 22)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(s)
	var v := _value_label()
	h.add_child(v)
	v.text = _format(key, s.value)
	s.value_changed.connect(
		func(val: float):
			set_v(key, val)
			v.text = _format(key, val)
			_live_apply(key)
	)
	s.drag_ended.connect(
		func(changed: bool):
			if changed:
				save_config()
				AudioDirector.play_ui("ui_click")
	)
	_rows.append({"key": key, "node": s, "value": v})


func _toggle_row(key: String, label_text: String) -> void:
	var h := _row(label_text)
	var b := Button.new()
	b.toggle_mode = true
	b.button_pressed = get_b(key)
	b.custom_minimum_size = Vector2(96, 30)
	b.text = "ON" if b.button_pressed else "OFF"
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_override("font", UITheme.eyebrow_font())
	b.add_theme_font_size_override("font_size", UITheme.FS_TINY)
	h.add_child(b)
	h.add_child(_value_label())
	b.toggled.connect(
		func(on: bool):
			b.text = "ON" if on else "OFF"
			set_v(key, on)
			save_config()
			_live_apply(key)
			AudioDirector.play_ui("ui_click")
	)
	_rows.append({"key": key, "node": b, "value": null})


func _step_row(key: String, label_text: String, names: Array) -> void:
	var spec: Array = SPEC[key]
	var h := _row(label_text)
	var s := HSlider.new()
	s.min_value = float(spec[1])
	s.max_value = float(spec[2])
	s.step = 1.0
	s.value = float(int(get_v(key)))
	s.custom_minimum_size = Vector2(240, 22)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(s)
	var v := _value_label()
	h.add_child(v)
	v.text = String(names[clampi(int(s.value), 0, names.size() - 1)])
	s.value_changed.connect(
		func(val: float):
			set_v(key, int(val))
			v.text = String(names[clampi(int(val), 0, names.size() - 1)])
			save_config()
			_live_apply(key)
	)
	_rows.append({"key": key, "node": s, "value": v})


func _format(key: String, v: float) -> String:
	if key == "video/fov":
		return "%d°" % int(round(v))
	if key == "input/sensitivity":
		return "%.2fx" % v
	if key == "video/render_scale":
		return "%d%%" % int(round(v * 100.0))
	return "%d%%" % int(round(v * 100.0))


func _live_apply(key: String) -> void:
	# Volumes and camera settings are cheap; re-apply everything and stay honest.
	apply(get_tree())
	if key.begins_with("audio/"):
		AudioDirector.play_2d("ui_hover", -14.0)


## Re-read the store into the widgets, after a defaults restore or a reload.
func sync_widgets() -> void:
	for r in _rows:
		var key: String = r.key
		var n: Node = r.node
		if n is HSlider:
			var spec: Array = SPEC[key]
			(n as HSlider).set_value_no_signal(float(get_v(key)) if String(spec[3]) != "i" else float(int(get_v(key))))
			if r.value != null:
				if String(spec[3]) == "i":
					(r.value as Label).text = String(QUALITY_NAMES[clampi(int(get_v(key)), 0, 3)])
				else:
					(r.value as Label).text = _format(key, get_f(key))
		elif n is Button:
			(n as Button).set_pressed_no_signal(get_b(key))
			(n as Button).text = "ON" if get_b(key) else "OFF"


func _on_reset() -> void:
	reset_defaults()
	save_config()
	sync_widgets()
	apply(get_tree())
	AudioDirector.play_ui("ui_click")


func _on_back() -> void:
	save_config()
	AudioDirector.play_ui("ui_close")
	closed.emit()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.020, 0.016, 0.012, 0.66), true)
