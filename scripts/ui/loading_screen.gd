class_name LoadingScreen
extends CanvasLayer
## A full-screen loading overlay with a progress bar driven by real work.
##
## The world bake takes about ten seconds the first time the game runs, and building the
## village and warming the shaders takes a few more. Without this the window sits frozen
## on whatever was last drawn. Work reports through `report()` and the overlay redraws
## itself immediately (`RenderingServer.force_draw`), because the main thread is busy
## and would never get to draw it otherwise.
##
## Progress only ever moves forward, and `stage()` lets each phase of the load map its
## own 0..1 onto a slice of the whole bar.

const BG := Color(0.02, 0.016, 0.012, 1.0)
## Redraws closer together than this are skipped; a redraw costs a frame of GPU time.
const MIN_REDRAW_MS := 40

var progress: float = 0.0
var message: String = ""

var _lo: float = 0.0
var _hi: float = 1.0
var _bar: ProgressBar
var _label: Label
var _last_draw_ms: int = 0
var _closing: bool = false


## Put a loading screen on top of everything under `host`.
static func open(host: Node, title: String = "RAMA") -> LoadingScreen:
	var ls := LoadingScreen.new()
	ls.name = "LoadingScreen"
	ls.layer = 100
	host.add_child(ls)
	ls._build(title)
	return ls


func _build(title: String) -> void:
	var back := ColorRect.new()
	back.color = BG
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(back)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(520, 0)
	box.position = Vector2(-260, 40)
	box.theme = UITheme.get_theme()
	box.add_theme_constant_override("separation", 14)
	back.add_child(box)

	var head := Label.new()
	head.text = title
	head.theme_type_variation = "Title"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(head)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.step = 0.001
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(520, 10)
	box.add_child(_bar)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", UITheme.SAFFRON_PALE)
	box.add_child(_label)
	report(0.0, "Starting")


## Make the next calls to `report()` fill only the slice lo..hi of the whole bar.
func stage(lo: float, hi: float) -> void:
	_lo = clampf(lo, 0.0, 1.0)
	_hi = clampf(hi, _lo, 1.0)


## `fraction` is progress within the current stage; `text` says what is happening now.
func report(fraction: float, text: String = "") -> void:
	if _closing:
		return
	progress = maxf(progress, lerpf(_lo, _hi, clampf(fraction, 0.0, 1.0)))
	if text != "":
		message = text
	if _bar:
		_bar.value = progress
	if _label:
		_label.text = message
	_redraw_now()


func _redraw_now() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_draw_ms < MIN_REDRAW_MS:
		return
	_last_draw_ms = now
	# Does nothing on a headless run, where there is no renderer to draw with.
	RenderingServer.force_draw(false, 0.0)


## Fill the bar, then fade out and free the overlay.
func finish(fade_seconds: float = 0.5) -> void:
	if _closing:
		return
	stage(0.0, 1.0)
	report(1.0, "Ready")
	_closing = true
	if not is_inside_tree() or fade_seconds <= 0.0:
		queue_free()
		return
	var root := get_child(0) as Control
	var tw := create_tween()
	tw.tween_property(root, "modulate:a", 0.0, fade_seconds)
	tw.tween_callback(queue_free)
