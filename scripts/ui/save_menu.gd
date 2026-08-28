class_name SaveMenu
extends Control
## Three slots, in either direction. Each card shows what the save actually is —
## which day, what hour, how much of the world has been found — so choosing one is a
## decision about a story rather than about a file.

signal closed
signal slot_used(slot: int, mode: String)

const SLOTS := 3
const CARD_H := 108.0
const CARD_GAP := 12.0

var mode: String = "save"  # "save" | "load"

var _hover: int = -1
var _sel: int = 0
var _panel: StyleBoxTexture
var _card: StyleBoxFlat
var _card_hi: StyleBoxFlat
var _summaries: Array = []
var _flash: float = 0.0
var _flash_slot: int = -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# `_gui_input` only ever sees a key event on a Control that can hold focus, so
	# without this the up/down/enter handling below is unreachable and the panel is
	# mouse-only.
	focus_mode = Control.FOCUS_ALL
	# Offsets must be reset too: setting anchors alone on a node that is already
	# in the tree preserves the current (zero) rect and the panel never grows.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme()
	_panel = UITheme.panel_style(Color(0.066, 0.052, 0.043, 0.96), 26)
	_card = UITheme.flat_style(
		Color(0.043, 0.035, 0.031, 0.75), 3, 1.0, Color(UITheme.BRASS_DIM.r, UITheme.BRASS_DIM.g, UITheme.BRASS_DIM.b, 0.45), 0, 0
	)
	_card_hi = UITheme.flat_style(
		Color(0.176, 0.121, 0.055, 0.88), 3, 1.0, Color(UITheme.SAFFRON.r, UITheme.SAFFRON.g, UITheme.SAFFRON.b, 0.95), 0, 0
	)
	set_process(true)
	refresh()


func open_as(m: String) -> void:
	mode = m
	_hover = -1
	refresh()
	show()


## The HUD owns the escape key, so it closes this panel through here.
func request_close() -> void:
	AudioDirector.play_ui("ui_close")
	closed.emit()


func refresh() -> void:
	_summaries.clear()
	for i in range(SLOTS):
		_summaries.append(GameState.slot_summary(i))
	queue_redraw()


func filled_slots() -> int:
	var n := 0
	for s in _summaries:
		if not (s as Dictionary).is_empty():
			n += 1
	return n


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 1.6)
		queue_redraw()


# --- layout ---------------------------------------------------------------
func _panel_rect() -> Rect2:
	var w: float = 640.0
	var h: float = 118.0 + SLOTS * CARD_H + (SLOTS - 1) * CARD_GAP + 74.0
	return Rect2(Vector2((size.x - w) * 0.5, (size.y - h) * 0.5), Vector2(w, h))


func _card_rect(i: int, pr: Rect2) -> Rect2:
	return Rect2(pr.position + Vector2(28.0, 106.0 + i * (CARD_H + CARD_GAP)), Vector2(pr.size.x - 56.0, CARD_H))


func _gui_input(e: InputEvent) -> void:
	var pr := _panel_rect()
	if e is InputEventMouseMotion:
		var was := _hover
		_hover = -1
		for i in range(SLOTS):
			if _card_rect(i, pr).has_point((e as InputEventMouseMotion).position):
				_hover = i
		if _hover != was and _hover >= 0:
			AudioDirector.play_ui("ui_hover")
		queue_redraw()
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			for i in range(SLOTS):
				if _card_rect(i, pr).has_point(mb.position):
					use_slot(i)
					accept_event()
					return
	if e is InputEventKey and (e as InputEventKey).pressed:
		var k := (e as InputEventKey).keycode
		if k == KEY_DOWN:
			_sel = (_sel + 1) % SLOTS
			queue_redraw()
			accept_event()
		elif k == KEY_UP:
			_sel = (_sel + SLOTS - 1) % SLOTS
			queue_redraw()
			accept_event()
		elif k == KEY_ENTER or k == KEY_KP_ENTER or k == KEY_SPACE:
			use_slot(_sel)
			accept_event()


## Do the thing the card promises. Returns true if it happened.
func use_slot(i: int) -> bool:
	_sel = i
	if mode == "save":
		var ok := GameState.save_to_slot(i)
		if ok:
			AudioDirector.play_2d("quest_accept", -10.0)
			_flash = 1.0
			_flash_slot = i
			refresh()
			slot_used.emit(i, "save")
		else:
			AudioDirector.play_ui("ui_close")
		return ok
	if (_summaries[i] as Dictionary).is_empty():
		AudioDirector.play_ui("ui_close")
		return false
	var loaded := GameState.load_from_slot(i)
	if loaded:
		AudioDirector.play_2d("shrine_activate", -10.0)
		_flash = 1.0
		_flash_slot = i
		slot_used.emit(i, "load")
	return loaded


## Put a freshly loaded GameState back into a running game. Called by the HUD once
## `EventBus.game_loaded` has fired, because GameState alone cannot move the player.
static func apply_loaded_state(game: Node) -> void:
	if game == null or not is_instance_valid(game):
		return
	var p: Node = game.get("player")
	if p != null and is_instance_valid(p) and p is Node3D:
		var n3 := p as Node3D
		if GameState.player_position.length_squared() > 0.01:
			n3.global_position = GameState.player_position
		if p is CharacterBody3D:
			(p as CharacterBody3D).velocity = Vector3.ZERO
		p.set("facing_yaw", GameState.player_yaw)
		n3.rotation.y = GameState.player_yaw
		var cam: Node = p.get("cam_rig")
		if cam != null and is_instance_valid(cam):
			cam.set("yaw", GameState.player_yaw)
	var world: Node = game.get("world")
	if world != null and is_instance_valid(world):
		var sky: Node = world.get("sky")
		if sky != null and is_instance_valid(sky) and sky.has_method("set_time"):
			sky.set_time(GameState.time_of_day)


# --- drawing --------------------------------------------------------------
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.020, 0.016, 0.012, 0.68), true)
	var pr := _panel_rect()
	draw_style_box(_panel, pr)

	var f_eyebrow := UITheme.eyebrow_font()
	var f_head := UITheme.label_font()
	var f_body := UITheme.body_font()

	UITheme.draw_text(self, f_eyebrow, pr.position + Vector2(30, 44), "SAVE" if mode == "save" else "LOAD", UITheme.FS_TINY, UITheme.BRASS)
	var sub: String = "Choose where to set this down." if mode == "save" else "Choose a road already walked."
	UITheme.draw_text(self, f_body, pr.position + Vector2(90, 45), sub, UITheme.FS_SMALL, UITheme.PARCHMENT_FAINT)
	UITheme.carved_rule(self, pr.position + Vector2(30, 64), pr.size.x - 60)

	for i in range(SLOTS):
		_draw_card(i, _card_rect(i, pr), f_eyebrow, f_head, f_body)

	var hint := "ESC  BACK"
	var hw := UITheme.text_width(f_eyebrow, hint, UITheme.FS_TINY)
	UITheme.draw_text(self, f_eyebrow, Vector2(pr.end.x - 30 - hw, pr.end.y - 24), hint, UITheme.FS_TINY, UITheme.PARCHMENT_FAINT)


func _draw_card(i: int, r: Rect2, f_eyebrow: Font, f_head: Font, f_body: Font) -> void:
	var s: Dictionary = _summaries[i]
	var empty: bool = s.is_empty()
	var active: bool = (i == _hover) or (i == _sel and _hover < 0)
	var usable: bool = mode == "save" or not empty

	var sb: StyleBoxFlat = _card
	if active and usable:
		sb = _card_hi
	elif not usable:
		sb = _card.duplicate() as StyleBoxFlat
		sb.bg_color = Color(0.031, 0.027, 0.023, 0.55)
		sb.border_color = Color(0.28, 0.25, 0.21, 0.35)
	draw_style_box(sb, r)

	if _flash > 0.0 and i == _flash_slot:
		var g := UITheme.glow_texture()
		draw_texture_rect(g, r.grow(18.0), false, Color(UITheme.SAFFRON.r, UITheme.SAFFRON.g, UITheme.SAFFRON.b, _flash * 0.28))

	UITheme.draw_text(
		self,
		f_eyebrow,
		r.position + Vector2(20, 30),
		"SLOT %d" % (i + 1),
		UITheme.FS_TINY,
		UITheme.BRASS if usable else UITheme.PARCHMENT_FAINT
	)

	if empty:
		UITheme.draw_text(self, f_head, r.position + Vector2(20, 66), "Empty", UITheme.FS_HEAD, UITheme.PARCHMENT_FAINT)
		if mode == "save":
			UITheme.draw_text(
				self, f_body, r.position + Vector2(110, 64), "— write a new chapter here", UITheme.FS_SMALL, UITheme.PARCHMENT_FAINT
			)
		return

	var day: int = int(s.get("day", 1))
	var tod: float = float(s.get("time", 7.4))
	UITheme.draw_text(self, f_head, r.position + Vector2(20, 66), "Day %d" % day, UITheme.FS_HEAD, UITheme.PARCHMENT)
	UITheme.draw_text(
		self,
		f_body,
		r.position + Vector2(112, 64),
		"%s  ·  %s" % [UITheme.clock(tod), _phase_name(tod)],
		UITheme.FS_SMALL,
		UITheme.SAFFRON_PALE
	)

	var nq: int = int(s.get("quests_done", 0))
	var np: int = int(s.get("discovered", 0))
	var stats := (
		"%d %s  ·  %d %s  ·  %s"
		% [nq, "quest" if nq == 1 else "quests", np, "place" if np == 1 else "places", UITheme.duration(float(s.get("play_seconds", 0.0)))]
	)
	UITheme.draw_text(self, f_body, r.position + Vector2(20, 90), stats, UITheme.FS_SMALL, UITheme.PARCHMENT_DIM)

	var when: int = int(s.get("modified", 0))
	if when > 0:
		# `get_datetime_dict_from_unix_time` is UTC. A player who saved at 03:43 was
		# being shown 10:49, which reads as someone else's save file. Shift by the
		# system's own offset so the stamp says the time they remember.
		var tz: Dictionary = Time.get_time_zone_from_system()
		var d := Time.get_datetime_dict_from_unix_time(when + int(tz.get("bias", 0)) * 60)
		var stamp := "%04d-%02d-%02d  %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]
		var w := UITheme.text_width(f_eyebrow, stamp, UITheme.FS_TINY)
		UITheme.draw_text(self, f_eyebrow, Vector2(r.end.x - 20 - w, r.position.y + 30), stamp, UITheme.FS_TINY, UITheme.PARCHMENT_FAINT)

	if mode == "save":
		var warn := "OVERWRITE"
		var ww := UITheme.text_width(f_eyebrow, warn, UITheme.FS_TINY)
		UITheme.draw_text(
			self,
			f_eyebrow,
			Vector2(r.end.x - 20 - ww, r.end.y - 22),
			warn,
			UITheme.FS_TINY,
			Color(UITheme.CRIMSON_PALE.r, UITheme.CRIMSON_PALE.g, UITheme.CRIMSON_PALE.b, 0.85)
		)


static func _phase_name(hours: float) -> String:
	var h: float = fposmod(hours, 24.0)
	if h < 5.0:
		return "night"
	if h < 7.0:
		return "dawn"
	if h < 11.0:
		return "morning"
	if h < 15.0:
		return "midday"
	if h < 18.0:
		return "afternoon"
	if h < 20.0:
		return "dusk"
	return "night"
