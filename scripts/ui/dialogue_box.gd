class_name DialogueBox
extends Control
## The conversation panel: a parchment leaf in a carved stone frame.
##
## Everything is drawn in one `_draw` rather than assembled from engine Panels, for
## two reasons. The obvious one is that a default StyleBox looks like a default
## StyleBox. The less obvious one is the per-character reveal: text is wrapped ONCE
## into fixed lines and then revealed a character at a time along those lines, so the
## paragraph never reflows as it types — which is exactly what happens if you feed a
## growing substring to an autowrapping label.
##
## API, as used by DialogueSystem:
##     var choice: int = await box.show_line(speaker, text, ["yes", "no"])
## returns the chosen index, or -1 for a line with no choices. `close()` resolves any
## pending call with -1 so a cancelled conversation cannot leave a coroutine hanging.

signal line_shown(speaker: String, text: String)
signal choice_selected(index: int)
signal advanced
signal box_opened
signal box_closed
signal _resolved

# --- palette: sandstone, ink, brass ----------------------------------------
const STONE := Color(0.278, 0.227, 0.184)
const STONE_HI := Color(0.427, 0.361, 0.290)
const STONE_LO := Color(0.145, 0.114, 0.090)
const PARCH_TOP := Color(0.933, 0.882, 0.780)
const PARCH_BOT := Color(0.843, 0.769, 0.635)
const INK := Color(0.176, 0.114, 0.063)
const INK_SOFT := Color(0.361, 0.290, 0.216)
const BRASS := Color(0.804, 0.635, 0.302)
const SAFFRON := Color(0.847, 0.443, 0.125)
const NAME_INK := Color(0.988, 0.945, 0.867)

const CHARS_PER_SEC := 52.0
const MAX_FRACTION := 0.52  # the panel may never eat more than this much screen

# --- state -----------------------------------------------------------------
var typing_sound: bool = true

var _speaker: String = ""
var _full: String = ""
var _choices: Array = []
var _sel: int = 0
var _reveal: float = 0.0
var _total: int = 0
var _waiting: bool = false
var _result: int = -1
var _open: bool = false
var _appear: float = 0.0
var _cool: float = 0.0
var _hint_t: float = 0.0
var _tick: float = 0.0

# --- layout (recomputed in _relayout) ---------------------------------------
var _ui: float = 1.0
var _rect := Rect2()
var _lines: PackedStringArray = PackedStringArray()
var _fs_body: int = 22
var _fs_name: int = 19
var _fs_choice: int = 20
var _fs_hint: int = 14
var _pad: float = 26.0
var _line_h: float = 30.0
var _row_h: float = 36.0
var _frame_w: float = 10.0
var _name_rect := Rect2()
var _choice_rects: Array[Rect2] = []


func _ready() -> void:
	name = "DialogueBox"
	# ARCHITECTURE.md: `set_anchors_preset` on a Control ALREADY IN THE TREE keeps its
	# current rect, so the panel ends up anchored to a 0x0 box in the top-left. The
	# painting here is all absolute and survived that by luck; the offsets version is
	# the one that is actually correct, and `_relayout` now clamps into this rect.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	z_index = 10
	set_process(true)
	get_viewport().size_changed.connect(_on_resize)


func _on_resize() -> void:
	if _open:
		_relayout()
		queue_redraw()


# ===========================================================================
#  public API
# ===========================================================================
func open() -> void:
	_open = true
	_appear = 0.0
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_speaker = ""
	_full = ""
	_choices = []
	_choice_rects.clear()
	box_opened.emit()


## Show one line and wait. Returns the index of the chosen reply, or -1 when the
## line had no choices and was simply advanced.
func show_line(speaker: String, text: String, choices: Array = []) -> int:
	_open = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_speaker = speaker
	_full = text
	_choices = []
	for c in choices:
		_choices.append(String(c))
	_choice_rects.clear()
	_sel = 0
	_reveal = 0.0
	_cool = 0.13
	_hint_t = 0.0
	_result = -1
	_relayout()
	queue_redraw()
	line_shown.emit(speaker, text)
	_waiting = true
	await _resolved
	return _result


## Resolve any pending `show_line` with -1 and hide.
func close() -> void:
	_open = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choice_rects.clear()
	if _waiting:
		_waiting = false
		_result = -1
		_resolved.emit()
	visible = false
	box_closed.emit()


func is_waiting() -> bool:
	return _waiting


func is_typing() -> bool:
	return _waiting and _reveal < float(_total)


func skip_typing() -> void:
	_reveal = float(_total)
	queue_redraw()


func choice_count() -> int:
	return _choices.size()


func choice_labels() -> Array:
	return _choices.duplicate()


func selected_index() -> int:
	return _sel


func move_selection(step: int) -> void:
	if _choices.size() < 2:
		return
	_sel = wrapi(_sel + step, 0, _choices.size())
	AudioDirector.play_2d("ui_hover", -14.0)
	queue_redraw()


func select(i: int) -> void:
	if _choices.is_empty():
		return
	_sel = clampi(i, 0, _choices.size() - 1)
	queue_redraw()


## Advance, or commit the highlighted reply. Typing is skipped first, exactly as a
## player mashing the key would expect.
func press_confirm() -> void:
	if not _waiting:
		return
	if _reveal < float(_total):
		skip_typing()
		return
	_result = _sel if not _choices.is_empty() else -1
	if _choices.is_empty():
		advanced.emit()
	else:
		choice_selected.emit(_sel)
	AudioDirector.play_2d("ui_click", -9.0)
	_waiting = false
	_resolved.emit()


# ===========================================================================
#  frame
# ===========================================================================
func _process(delta: float) -> void:
	if not visible:
		return
	if _appear < 1.0:
		_appear = minf(1.0, _appear + delta * 6.0)
	modulate = Color(1, 1, 1, _appear)
	if not _waiting:
		return
	_hint_t += delta
	_cool = maxf(0.0, _cool - delta)
	if _reveal < float(_total):
		# Clamped: on a hitched frame an unclamped reveal fast-forwards through a whole
		# paragraph, which looks like the line simply appeared.
		_reveal += minf(delta, 0.05) * CHARS_PER_SEC
		if typing_sound:
			_tick -= delta
			if _tick <= 0.0:
				_tick = 0.105
				AudioDirector.play_2d("ui_hover", -27.0)
	if _cool <= 0.0:
		if not _choices.is_empty() and _reveal >= float(_total):
			if Input.is_action_just_pressed("ui_down") or Input.is_action_just_pressed("move_back"):
				move_selection(1)
			elif Input.is_action_just_pressed("ui_up") or Input.is_action_just_pressed("move_forward"):
				move_selection(-1)
		if Input.is_action_just_pressed("ui_accept") or Input.is_action_just_pressed("interact"):
			press_confirm()
	queue_redraw()


# ===========================================================================
#  layout
# ===========================================================================
func _font() -> Font:
	var f := get_theme_default_font()
	return f if f != null else ThemeDB.fallback_font


func _relayout() -> void:
	var vp := get_viewport_rect().size
	_ui = clampf(vp.y / 900.0, 0.72, 2.2)
	var font := _font()

	# Shrink a step at a time rather than clipping: a long line still fits.
	for scale_try in [1.0, 0.92, 0.84, 0.76, 0.68]:
		_fs_body = int(round(23.0 * _ui * scale_try))
		_fs_name = int(round(19.0 * _ui * scale_try))
		_fs_choice = int(round(20.0 * _ui * scale_try))
		_fs_hint = int(round(14.0 * _ui * scale_try))
		_pad = round(28.0 * _ui * scale_try)
		_frame_w = maxf(8.0, round(16.0 * _ui * scale_try))
		_line_h = round(float(_fs_body) * 1.46)
		_row_h = round(float(_fs_choice) * 1.90)
		var w: float = clampf(vp.x * 0.74, 480.0, 1240.0 * _ui)
		_lines = _wrap(_full, font, _fs_body, w - _pad * 2.0)
		var text_h: float = maxf(1.0, float(_lines.size())) * _line_h
		var ch_h: float = 0.0
		if not _choices.is_empty():
			ch_h = round(14.0 * _ui) + float(_choices.size()) * _row_h
		var h: float = _pad + text_h + ch_h + round(10.0 * _ui) + _pad
		if h <= vp.y * MAX_FRACTION or scale_try <= 0.68:
			var x: float = round((vp.x - w) * 0.5)
			var y: float = round(vp.y - h - 54.0 * _ui)
			_rect = Rect2(x, y, w, h)
			break

	# The name plate is a tab sitting on the panel's top rail.
	var nw: float = font.get_string_size(_speaker, HORIZONTAL_ALIGNMENT_LEFT, -1, _fs_name).x
	var plate_h: float = round(float(_fs_name) * 2.20)
	_name_rect = Rect2(_rect.position.x + round(34.0 * _ui), _rect.position.y - plate_h + round(6.0 * _ui), nw + round(56.0 * _ui), plate_h)

	# Total revealable characters, counted along the wrapped lines.
	_total = 0
	for l in _lines:
		_total += l.length()
	_rebuild_choice_rects()


func _rebuild_choice_rects() -> void:
	_choice_rects.clear()
	if _choices.is_empty():
		return
	var x: float = _rect.position.x + _pad
	var w: float = _rect.size.x - _pad * 2.0
	var y: float = _choices_top()
	for _i in range(_choices.size()):
		var row := Rect2(x - round(10.0 * _ui), y, w + round(20.0 * _ui), _row_h - round(4.0 * _ui))
		_choice_rects.append(row)
		y += _row_h


func _gui_input(e: InputEvent) -> void:
	if not _open or not _waiting:
		return
	if e is InputEventMouseMotion:
		if _reveal >= float(_total) and not _choices.is_empty():
			var mp: Vector2 = (e as InputEventMouseMotion).position
			for i in range(_choice_rects.size()):
				if _choice_rects[i].has_point(mp):
					if _sel != i:
						_sel = i
						AudioDirector.play_2d("ui_hover", -14.0)
						queue_redraw()
					break
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if _reveal < float(_total):
				skip_typing()
				accept_event()
				return
			if _choices.is_empty():
				press_confirm()
				accept_event()
				return
			for i in range(_choice_rects.size()):
				if _choice_rects[i].has_point(mb.position):
					_sel = i
					press_confirm()
					accept_event()
					return


## Wrap once, by hand, so the reveal cannot reflow the paragraph under itself.
static func _wrap(text: String, font: Font, size: int, w: float) -> PackedStringArray:
	var out := PackedStringArray()
	if text == "":
		return out
	for para in text.split("\n"):
		var cur := ""
		for word in para.split(" ", false):
			var trial: String = word if cur == "" else cur + " " + word
			if cur == "" or font.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= w:
				cur = trial
			else:
				out.append(cur)
				cur = word
		out.append(cur)
	return out


# ===========================================================================
#  painting
# ===========================================================================
func _draw() -> void:
	if _full == "" and _choices.is_empty():
		return
	draw_set_transform(Vector2(0.0, (1.0 - _appear) * 24.0), 0.0, Vector2.ONE)
	_draw_shadow()
	_draw_stone()
	var inner := _rect.grow(-_frame_w)
	_draw_parchment(inner)
	_draw_name_plate()
	_draw_text(inner)
	if _reveal >= float(_total):
		if _choices.is_empty():
			_draw_hint(inner)
		else:
			_draw_choices(inner)


func _draw_shadow() -> void:
	for i in range(4):
		var g: float = float(4 - i) * 3.0 * _ui
		draw_rect(Rect2(_rect.position + Vector2(0, 3.0 * _ui), _rect.size).grow(g), Color(0.0, 0.0, 0.0, 0.055), true)


## The frame: a sandstone band with a lit top edge, a shadowed bottom edge, a row of
## carved dentils along the rails and heavier blocks at the corners — the cornice of a
## Hampi doorway, reduced to what reads at this size.
func _draw_stone() -> void:
	draw_rect(_rect, STONE, true)
	var t: float = maxf(1.0, round(2.0 * _ui))

	# Dentils first, so the bevels cap them cleanly at the ends.
	var d: float = round(13.0 * _ui)
	var gap: float = round(9.0 * _ui)
	var inset: float = t + round(2.0 * _ui)
	var x: float = _rect.position.x + _frame_w + gap
	while x + d < _rect.end.x - _frame_w - gap:
		draw_rect(Rect2(x, _rect.position.y + inset, d, _frame_w - inset * 1.7), STONE_LO.lerp(STONE, 0.62), true)
		draw_rect(Rect2(x, _rect.position.y + inset, d, maxf(1.0, t * 0.7)), STONE_HI.lerp(STONE, 0.30), true)
		draw_rect(Rect2(x, _rect.end.y - _frame_w + inset * 0.5, d, _frame_w - inset * 1.7), STONE_LO.lerp(STONE, 0.72), true)
		x += gap + d

	# Cornerstones.
	var cs: float = _frame_w * 1.75
	for cnr in [
		Vector2(_rect.position.x, _rect.position.y),
		Vector2(_rect.end.x - cs, _rect.position.y),
		Vector2(_rect.position.x, _rect.end.y - cs),
		Vector2(_rect.end.x - cs, _rect.end.y - cs)
	]:
		draw_rect(Rect2(cnr, Vector2(cs, cs)), STONE.lerp(STONE_HI, 0.25), true)
		draw_rect(Rect2(cnr + Vector2(t, t), Vector2(cs - t * 2.0, cs - t * 2.0)), STONE.lerp(STONE_LO, 0.30), false, t)

	# Bevels last: a lit top-left and a shadowed bottom-right, so the slab has a
	# direction of light instead of reading as a flat border.
	draw_rect(Rect2(_rect.position, Vector2(_rect.size.x, t)), STONE_HI, true)
	draw_rect(Rect2(_rect.position, Vector2(t, _rect.size.y)), STONE_HI.lerp(STONE, 0.35), true)
	draw_rect(Rect2(Vector2(_rect.position.x, _rect.end.y - t), Vector2(_rect.size.x, t)), STONE_LO, true)
	draw_rect(Rect2(Vector2(_rect.end.x - t, _rect.position.y), Vector2(t, _rect.size.y)), STONE_LO, true)


func _draw_parchment(inner: Rect2) -> void:
	# A vertical wash from bleached top to a warmer, shadowed foot.
	var bands: int = 26
	for i in range(bands):
		var t0: float = float(i) / float(bands)
		var t1: float = float(i + 1) / float(bands)
		var c := PARCH_TOP.lerp(PARCH_BOT, t0 * t0 * 0.75 + t0 * 0.25)
		draw_rect(Rect2(inner.position.x, inner.position.y + inner.size.y * t0, inner.size.x, inner.size.y * (t1 - t0) + 1.0), c, true)

	# Laid-paper fibre: a few very faint horizontal lines. Almost invisible, which is
	# the point — it stops the fill reading as a flat swatch.
	var step: float = round(7.0 * _ui)
	var yy: float = inner.position.y + step
	var k: int = 0
	while yy < inner.end.y:
		k += 1
		if k % 3 != 0:
			draw_rect(
				Rect2(inner.position.x + round(6.0 * _ui), yy, inner.size.x - round(12.0 * _ui), 1.0), Color(0.45, 0.36, 0.24, 0.05), true
			)
		yy += step

	# Corner shading, so the leaf looks like it lies in the frame.
	var vg: float = round(30.0 * _ui)
	for i in range(int(vg)):
		var a: float = 0.055 * (1.0 - float(i) / vg)
		draw_rect(Rect2(inner.position.x + float(i), inner.position.y, 1.0, inner.size.y), Color(0.36, 0.27, 0.16, a), true)
		draw_rect(Rect2(inner.end.x - float(i) - 1.0, inner.position.y, 1.0, inner.size.y), Color(0.36, 0.27, 0.16, a), true)

	# Chamfer the corners so the leaf reads as cut, not as a rectangle.
	var ch: float = round(10.0 * _ui)
	var corners := [
		[inner.position, Vector2(ch, 0), Vector2(0, ch)],
		[Vector2(inner.end.x, inner.position.y), Vector2(-ch, 0), Vector2(0, ch)],
		[inner.end, Vector2(-ch, 0), Vector2(0, -ch)],
		[Vector2(inner.position.x, inner.end.y), Vector2(ch, 0), Vector2(0, -ch)],
	]
	for c in corners:
		var o: Vector2 = c[0]
		draw_colored_polygon(PackedVector2Array([o, o + c[1], o + c[2]]), STONE)

	# Brass hairline just inside the stone, and the shadow it casts on the leaf.
	draw_rect(inner.grow(-round(3.0 * _ui)), Color(BRASS.r, BRASS.g, BRASS.b, 0.62), false, maxf(1.0, round(1.5 * _ui)))
	for i in range(6):
		draw_rect(
			Rect2(inner.position.x, inner.position.y + float(i), inner.size.x, 1.0), Color(0.35, 0.26, 0.16, 0.13 - float(i) * 0.021), true
		)


func _draw_name_plate() -> void:
	if _speaker == "":
		return
	var r := _name_rect
	var t: float = maxf(1.0, round(2.0 * _ui))
	draw_rect(r, STONE, true)
	draw_rect(Rect2(r.position, Vector2(r.size.x, t)), STONE_HI, true)
	draw_rect(Rect2(Vector2(r.position.x, r.end.y - t), Vector2(r.size.x, t)), STONE_LO, true)
	var inner := r.grow(-round(4.0 * _ui))
	var bands: int = 10
	for i in range(bands):
		var t0: float = float(i) / float(bands)
		var c := SAFFRON.lerp(Color(0.478, 0.196, 0.063), t0 * t0)
		draw_rect(Rect2(inner.position.x, inner.position.y + inner.size.y * t0, inner.size.x, inner.size.y / float(bands) + 1.0), c, true)
	draw_rect(Rect2(inner.position.x, inner.position.y, inner.size.x, maxf(1.0, t * 0.7)), Color(1.0, 0.78, 0.45, 0.55), true)
	draw_rect(Rect2(inner.position.x, inner.end.y - t, inner.size.x, t), BRASS, true)

	# A small brass petal at the head of the plate.
	var px: float = inner.position.x + round(11.0 * _ui)
	var py: float = inner.position.y + inner.size.y * 0.5
	var ps: float = round(4.5 * _ui)
	draw_colored_polygon(
		PackedVector2Array([Vector2(px, py - ps), Vector2(px + ps * 0.7, py), Vector2(px, py + ps), Vector2(px - ps * 0.7, py)]), BRASS
	)

	var font := _font()
	var asc: float = font.get_ascent(_fs_name)
	var tx: float = px + ps + round(9.0 * _ui)
	var ty: float = inner.position.y + (inner.size.y - float(_fs_name)) * 0.5 + asc * 0.94
	draw_string(font, Vector2(tx + 1.0, ty + 1.0), _speaker, HORIZONTAL_ALIGNMENT_LEFT, -1, _fs_name, Color(0.25, 0.09, 0.02, 0.55))
	draw_string(font, Vector2(tx, ty), _speaker, HORIZONTAL_ALIGNMENT_LEFT, -1, _fs_name, NAME_INK)


func _draw_text(_inner: Rect2) -> void:
	var font := _font()
	var asc: float = font.get_ascent(_fs_body)
	var x: float = _rect.position.x + _pad
	var y: float = _rect.position.y + _pad + asc
	var left: int = int(_reveal)
	for line in _lines:
		var n: int = line.length()
		var shown: String = line if left >= n else line.substr(0, maxi(0, left))
		if shown != "":
			draw_string(font, Vector2(x + 1.0, y + 1.0), shown, HORIZONTAL_ALIGNMENT_LEFT, -1, _fs_body, Color(0.42, 0.33, 0.21, 0.30))
			draw_string(font, Vector2(x, y), shown, HORIZONTAL_ALIGNMENT_LEFT, -1, _fs_body, INK)
		left -= n
		y += _line_h
		if left <= 0:
			break


func _choices_top() -> float:
	var text_h: float = maxf(1.0, float(_lines.size())) * _line_h
	return _rect.position.y + _pad + text_h + round(14.0 * _ui)


func _draw_choices(_inner: Rect2) -> void:
	_choice_rects.clear()
	var font := _font()
	var asc: float = font.get_ascent(_fs_choice)
	var x: float = _rect.position.x + _pad
	var w: float = _rect.size.x - _pad * 2.0
	var y: float = _choices_top()
	var pulse: float = 0.5 + 0.5 * sin(_hint_t * 3.4)
	for i in range(_choices.size()):
		var row := Rect2(x - round(10.0 * _ui), y, w + round(20.0 * _ui), _row_h - round(4.0 * _ui))
		_choice_rects.append(row)
		if i == _sel:
			draw_rect(row, Color(SAFFRON.r, SAFFRON.g, SAFFRON.b, 0.13), true)
			draw_rect(Rect2(row.position, Vector2(round(3.0 * _ui), row.size.y)), SAFFRON.lerp(BRASS, 0.35), true)
			# A small brass lozenge for the cursor.
			var cx: float = x + round(9.0 * _ui)
			var cy: float = y + row.size.y * 0.5
			var s: float = round(5.0 * _ui) * (0.85 + 0.15 * pulse)
			draw_colored_polygon(
				PackedVector2Array([Vector2(cx, cy - s), Vector2(cx + s * 0.78, cy), Vector2(cx, cy + s), Vector2(cx - s * 0.78, cy)]),
				BRASS
			)
			draw_rect(
				Rect2(row.position.x + round(3.0 * _ui), row.end.y - 1.0, row.size.x - round(6.0 * _ui), maxf(1.0, round(1.2 * _ui))),
				Color(BRASS.r, BRASS.g, BRASS.b, 0.55),
				true
			)
		else:
			draw_rect(Rect2(row.position.x, row.end.y - 1.0, row.size.x, 1.0), Color(0.35, 0.27, 0.17, 0.14), true)
		var col: Color = INK if i == _sel else INK_SOFT
		draw_string(
			font,
			Vector2(x + round(26.0 * _ui), y + (row.size.y - float(_fs_choice)) * 0.5 + asc * 0.94),
			_choices[i],
			HORIZONTAL_ALIGNMENT_LEFT,
			w - round(30.0 * _ui),
			_fs_choice,
			col
		)
		y += _row_h


func _draw_hint(inner: Rect2) -> void:
	var font := _font()
	var bob: float = sin(_hint_t * 4.2) * 2.2 * _ui
	var cx: float = inner.end.x - round(24.0 * _ui)
	var cy: float = inner.end.y - round(17.0 * _ui) + bob
	var s: float = round(5.0 * _ui)
	draw_colored_polygon(
		PackedVector2Array([Vector2(cx - s, cy - s * 0.6), Vector2(cx + s, cy - s * 0.6), Vector2(cx, cy + s * 0.7)]),
		Color(INK.r, INK.g, INK.b, 0.55)
	)
	var label := "E"
	var tw: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, _fs_hint).x
	draw_string(
		font,
		Vector2(cx - s - round(9.0 * _ui) - tw, cy + font.get_ascent(_fs_hint) * 0.42),
		label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		_fs_hint,
		Color(INK.r, INK.g, INK.b, 0.45)
	)
