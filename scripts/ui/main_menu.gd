class_name MainMenu
extends Node3D
## The title screen, and the first impression the game makes.
##
## There is no painted backdrop: the menu boots the real world, parks a camera above
## the shrine at golden hour and lets it drift. What you are looking at is the place
## you are about to walk into, which is worth the two seconds it costs to build.

const DRIFT_SPEED := 0.030  # radians per second around the centre
const CENTRE := Vector2(158.0, -66.0)  # WorldMap.P_SHRINE
const GOLDEN_HOUR := 17.35

var world: WorldRoot
var cam: Camera3D
var ui: CanvasLayer

var _angle: float = 0.62
var _radius: float = 62.0
var _t: float = 0.0
var _leaving: bool = false
var _content: Array[Node] = []

var _title_layer: Control
var _buttons: VBoxContainer
var _fade: ColorRect
var _settings: SettingsMenu
var _loader: SaveMenu
var _continue_btn: Button


func _ready() -> void:
	SettingsMenu.load_config()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	_build_world()
	_build_ui()
	SettingsMenu.apply(get_tree())
	AudioDirector.play_music("music_explore", 3.0)
	set_process(true)


# ==========================================================================
# the living backdrop
# ==========================================================================
func _build_world() -> void:
	world = WorldRoot.new()
	world.name = "World"
	add_child(world)
	world.build(false)
	world.sky.set_time(GOLDEN_HOUR)
	world.sky.paused = true

	cam = Camera3D.new()
	cam.name = "DriftCam"
	cam.fov = 46.0
	cam.near = 0.10
	cam.far = 2400.0
	add_child(cam)
	cam.current = true
	world.set_focus(cam)
	_place_camera(0.0)

	# The same optional content systems the game builds, so the title screen shows
	# the real village and the real trees rather than bare terrain.
	for cls in ["RiverWater", "Vegetation", "Settlement", "WorldVFX"]:
		var n := _make(cls)
		if n == null:
			continue
		world.add_child(n)
		if n.has_method("setup"):
			if _arity(n, "setup") >= 2:
				n.setup(world.map, world.sky)
			else:
				n.setup(world.map)
		_content.append(n)

	AudioDirector.bind(world, world.sky, cam)


func _make(cls: String) -> Node3D:
	for e in ProjectSettings.get_global_class_list():
		if String(e.get("class", "")) != cls:
			continue
		var scr: Script = load(String(e["path"]))
		if scr == null:
			return null
		var inst: Variant = scr.new()
		if inst is Node3D:
			(inst as Node3D).name = cls
			return inst
		if inst is Object:
			(inst as Object).free()
		return null
	return null


func _arity(n: Node, m: String) -> int:
	for d in n.get_method_list():
		if d.name == m:
			return d.args.size()
	return 1


func _place_camera(delta: float) -> void:
	_angle += DRIFT_SPEED * delta
	# Ease inward a little over the first half-minute, then hold.
	_radius = lerpf(_radius, 44.0, clampf(delta * 0.05, 0.0, 1.0))
	var p2 := CENTRE + Vector2(cos(_angle), sin(_angle)) * _radius
	var ground: float = world.map.height_at(p2.x, p2.y)
	var centre_g: float = world.map.height_at(CENTRE.x, CENTRE.y)
	var bob: float = sin(_t * 0.22) * 1.1
	var pos := Vector3(p2.x, maxf(ground, centre_g) + 14.0 + bob, p2.y)
	var look := Vector3(CENTRE.x, centre_g + 5.0, CENTRE.y)
	cam.look_at_from_position(pos, look, Vector3.UP)


func _process(delta: float) -> void:
	_t += delta
	if world == null:
		return
	_place_camera(delta)
	for n in _content:
		if is_instance_valid(n) and n.has_method("update_focus"):
			n.update_focus(cam.global_position)


# ==========================================================================
# the menu itself
# ==========================================================================
func _build_ui() -> void:
	ui = CanvasLayer.new()
	ui.name = "UI"
	ui.layer = 20
	add_child(ui)

	_title_layer = TitleArt.new()
	_title_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_layer.theme = UITheme.get_theme()
	ui.add_child(_title_layer)

	_buttons = VBoxContainer.new()
	_buttons.name = "Buttons"
	_buttons.theme = UITheme.get_theme()
	_buttons.add_theme_constant_override("separation", 2)
	_buttons.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_buttons.position = Vector2(126, 430)
	_buttons.custom_minimum_size = Vector2(300, 0)
	ui.add_child(_buttons)

	_continue_btn = _add_button("Continue", _on_continue)
	_continue_btn.disabled = not _any_slot()
	if _continue_btn.disabled:
		_continue_btn.tooltip_text = "No journey has been set down yet."
	_add_button("New Game", _on_new_game)
	_add_button("Load", _on_load)
	_add_button("Settings", _on_settings)
	_add_button("Quit", func(): get_tree().quit(0))

	_settings = SettingsMenu.new()
	_settings.hide()
	_settings.closed.connect(
		func():
			_settings.hide()
			_set_menu_visible(true)
	)
	ui.add_child(_settings)

	_loader = SaveMenu.new()
	_loader.hide()
	_loader.mode = "load"
	_loader.closed.connect(
		func():
			_loader.hide()
			_set_menu_visible(true)
	)
	_loader.slot_used.connect(_on_slot_loaded)
	ui.add_child(_loader)

	_fade = ColorRect.new()
	_fade.color = Color(0.02, 0.016, 0.012, 1.0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_fade)
	# Fade up from black on arrival.
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 0.0, 1.6).set_trans(Tween.TRANS_SINE)


func _add_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.theme_type_variation = "Menu"
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(cb)
	b.mouse_entered.connect(
		func():
			if not b.disabled:
				AudioDirector.play_ui("ui_hover")
	)
	_buttons.add_child(b)
	return b


func _set_menu_visible(on: bool) -> void:
	_buttons.visible = on
	_title_layer.visible = on


func _any_slot() -> bool:
	for i in range(SaveMenu.SLOTS):
		if GameState.has_slot(i):
			return true
	return false


func _newest_slot() -> int:
	var best := -1
	var best_time := -1
	for i in range(SaveMenu.SLOTS):
		var s := GameState.slot_summary(i)
		if s.is_empty():
			continue
		var m := int(s.get("modified", 0))
		if m > best_time:
			best_time = m
			best = i
	return best


# --- actions ---------------------------------------------------------------
func _on_continue() -> void:
	var slot := _newest_slot()
	if slot < 0:
		AudioDirector.play_ui("ui_close")
		return
	if not GameState.load_from_slot(slot):
		AudioDirector.play_ui("ui_close")
		return
	AudioDirector.play_ui("ui_click")
	_start(true)


func _on_new_game() -> void:
	AudioDirector.play_ui("ui_click")
	GameState.reset()
	_start(false)


func _on_load() -> void:
	AudioDirector.play_ui("ui_open")
	_loader.open_as("load")
	_set_menu_visible(false)


func _on_slot_loaded(_slot: int, mode: String) -> void:
	if mode != "load":
		return
	_start(true)


func _on_settings() -> void:
	AudioDirector.play_ui("ui_open")
	_settings.show()
	_settings.sync_widgets()
	_set_menu_visible(false)


## Fade to black, then hand the tree over to a real session.
func _start(restore: bool) -> void:
	if _leaving:
		return
	_leaving = true
	_set_menu_visible(false)
	_settings.hide()
	_loader.hide()
	AudioDirector.stop_music(1.1)
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(func(): _enter_world(restore))


func _enter_world(restore: bool) -> void:
	var session := HUD.launch(get_tree())
	if restore:
		var g := session.get_node_or_null("Game")
		if g:
			SaveMenu.apply_loaded_state(g)


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("pause"):
		if _settings.visible:
			_settings.hide()
			_set_menu_visible(true)
			get_viewport().set_input_as_handled()
		elif _loader.visible:
			_loader.hide()
			_set_menu_visible(true)
			get_viewport().set_input_as_handled()


# ==========================================================================
## The wordmark and the scrim behind it. Drawn rather than laid out, because the
## letter spacing and the rules under it are the whole design.
class TitleArt:
	extends Control
	var _t: float = 0.0
	var _grad: Texture2D

	func _ready() -> void:
		set_process(true)
		_grad = _make_scrim()

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	## A left-to-right ink wash so the type always has something to sit on, whatever
	## the camera happens to be flying over.
	static func _make_scrim() -> Texture2D:
		var w := 96
		var h := 64
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		for y in range(h):
			for x in range(w):
				var u: float = float(x) / float(w - 1)
				var v: float = float(y) / float(h - 1)
				var side: float = pow(clampf(1.0 - u * 1.15, 0.0, 1.0), 1.25)
				var bottom: float = pow(clampf((v - 0.62) / 0.38, 0.0, 1.0), 1.8)
				var top: float = pow(clampf(1.0 - v / 0.20, 0.0, 1.0), 1.6)
				var a: float = clampf(side * 0.90 + bottom * 0.40 + top * 0.30, 0.0, 0.94)
				img.set_pixel(x, y, Color(0.031, 0.024, 0.020, a))
		return ImageTexture.create_from_image(img)

	func _draw() -> void:
		draw_texture_rect(_grad, Rect2(Vector2.ZERO, size), false)

		var x := 132.0
		var y := 318.0
		var f := UITheme.display_font()
		# The wordmark, with a warm shadow so it reads against a bright sky.
		draw_string(
			f,
			Vector2(x + 3, y + 4),
			"RAMA",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			UITheme.FS_DISPLAY,
			Color(0.05, 0.03, 0.02, 0.55)
		)
		draw_string(f, Vector2(x, y), "RAMA", HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_DISPLAY, UITheme.PARCHMENT)

		var wordmark_w: float = UITheme.text_width(f, "RAMA", UITheme.FS_DISPLAY)
		UITheme.carved_rule(self, Vector2(x + 4, y + 26.0), maxf(wordmark_w - 26.0, 120.0), UITheme.BRASS, 0.85)

		var fe := UITheme.eyebrow_font()
		UITheme.draw_text(
			self,
			fe,
			Vector2(x + 6, y + 62.0),
			"THE VALE OF PANCHAVATI",
			UITheme.FS_TINY,
			Color(UITheme.SAFFRON_PALE.r, UITheme.SAFFRON_PALE.g, UITheme.SAFFRON_PALE.b, 0.92)
		)

		var fb := UITheme.body_font()
		UITheme.draw_text(
			self,
			fb,
			Vector2(x + 6, y + 94.0),
			"An open-world adventure in ancient India.",
			UITheme.FS_SMALL,
			Color(UITheme.PARCHMENT_DIM.r, UITheme.PARCHMENT_DIM.g, UITheme.PARCHMENT_DIM.b, 0.85)
		)

		# A slow breathing brass hairline down the left margin.
		var breathe: float = 0.35 + 0.20 * sin(_t * 0.6)
		draw_line(
			Vector2(x - 26.0, y - 76.0),
			Vector2(x - 26.0, size.y - 120.0),
			Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, breathe * 0.5),
			1.0,
			true
		)

		UITheme.draw_text(
			self,
			fe,
			Vector2(x + 6, size.y - 46.0),
			"GODOT 4.7  ·  PROCEDURAL WORLD  ·  NO IMPORTED ART",
			UITheme.FS_TINY,
			Color(UITheme.PARCHMENT_FAINT.r, UITheme.PARCHMENT_FAINT.g, UITheme.PARCHMENT_FAINT.b, 0.55)
		)
