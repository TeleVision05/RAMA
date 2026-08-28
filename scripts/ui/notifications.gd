class_name Notifications
extends Control
## Transient cards for the things worth interrupting a walk for: a place found, a
## quest taken, an objective closed, something picked up.
##
## Never more than three on screen; anything else waits its turn. Each card slides in
## from the right, holds, then fades. The stack reflows smoothly rather than snapping,
## which is the difference between "a game told me something" and "a log line".

const MAX_VISIBLE := 3
const CARD_W := 330.0
const CARD_H := 62.0
const GAP := 10.0
const IN_TIME := 0.34
const OUT_TIME := 0.55
const HOLD := 3.8

const KINDS := {
	"info": {"accent": Color(0.784, 0.635, 0.290), "sound": ""},
	"quest": {"accent": Color(0.909, 0.568, 0.184), "sound": "sting_quest"},
	"objective": {"accent": Color(0.435, 0.560, 0.352), "sound": "objective_complete"},
	"discovery": {"accent": Color(0.960, 0.752, 0.451), "sound": "sting_discovery"},
	"item": {"accent": Color(0.741, 0.686, 0.588), "sound": "pickup_item"},
	"warn": {"accent": Color(0.847, 0.372, 0.290), "sound": ""},
}

var fade: float = 1.0
var mute: bool = false  # the test harness drives events far faster than life

var _cards: Array = []  # live cards, oldest first
var _queue: Array = []  # waiting cards
var _font_title: Font
var _font_body: Font
var _card_style: StyleBoxFlat
## One scratch box, re-tinted per card per frame. Duplicating the style box inside
## `_draw_card` allocated a Resource for every card on every frame.
var _card_scratch: StyleBoxFlat
## Whether the last frame drew anything, so the clearing redraw still happens once.
var _drawn: bool = false
var _pushed_total: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font_title = UITheme.font(2, 0.10)
	_font_body = UITheme.body_font()
	_card_style = UITheme.flat_style(
		Color(0.062, 0.049, 0.040, 0.90), 3, 1.0, Color(UITheme.BRASS_DIM.r, UITheme.BRASS_DIM.g, UITheme.BRASS_DIM.b, 0.55), 0, 0
	)
	_card_style.shadow_size = 10
	_card_style.shadow_color = Color(0, 0, 0, 0.45)
	_card_style.shadow_offset = Vector2(0, 3)
	_card_scratch = _card_style.duplicate() as StyleBoxFlat
	set_process(true)


func push(title: String, body: String, kind: String = "info") -> void:
	var k: String = kind if KINDS.has(kind) else "info"
	# Collapse a repeat of the same headline into the newest card instead of stacking.
	for c in _cards:
		if c.title == title and c.body == body and c.age < HOLD * 0.6:
			c.age = 0.0
			c.repeat += 1
			return
	var card := {
		"title": title,
		"body": body,
		"kind": k,
		"age": 0.0,
		"state": 0,
		"out": 0.0,
		"y": -1.0,
		"repeat": 0,
	}
	_pushed_total += 1
	if _cards.size() >= MAX_VISIBLE:
		_queue.append(card)
		return
	_admit(card)


func _admit(card: Dictionary) -> void:
	_cards.append(card)
	var snd: String = KINDS[card.kind].sound
	if snd != "" and not mute:
		AudioDirector.play_2d(snd, -9.0)
	elif not mute:
		AudioDirector.play_ui("ui_open")


func clear_all() -> void:
	_cards.clear()
	_queue.clear()


func visible_count() -> int:
	return _cards.size()


func total_pushed() -> int:
	return _pushed_total


func _process(delta: float) -> void:
	var i := 0
	while i < _cards.size():
		var c: Dictionary = _cards[i]
		c.age += delta
		if c.age > HOLD:
			c.out += delta
			if c.out >= OUT_TIME:
				_cards.remove_at(i)
				continue
		# Reflow: each card eases towards its slot rather than jumping.
		var target_y: float = float(i) * (CARD_H + GAP)
		if c.y < 0.0:
			c.y = target_y
		else:
			c.y = lerpf(c.y, target_y, clampf(delta * 9.0, 0.0, 1.0))
		i += 1
	while _cards.size() < MAX_VISIBLE and not _queue.is_empty():
		_admit(_queue.pop_front())
	# Nothing on screen and nothing waiting: there is nothing to redraw. This runs on
	# every frame of the game, and most of them have no notifications in them.
	if not _cards.is_empty() or _drawn:
		_drawn = not _cards.is_empty()
		queue_redraw()


func _draw() -> void:
	if fade <= 0.004:
		return
	for c in _cards:
		_draw_card(c)


func _draw_card(c: Dictionary) -> void:
	var t_in: float = clampf(c.age / IN_TIME, 0.0, 1.0)
	var ease_in: float = 1.0 - pow(1.0 - t_in, 3.0)
	var t_out: float = clampf(c.out / OUT_TIME, 0.0, 1.0)
	var alpha: float = ease_in * (1.0 - t_out) * fade
	if alpha <= 0.004:
		return
	# Slide in from the right, drift out to the right.
	var slide: float = (1.0 - ease_in) * 46.0 + t_out * 22.0
	var x: float = size.x - CARD_W + slide
	var rect := Rect2(Vector2(x, c.y), Vector2(CARD_W, CARD_H))

	var accent: Color = KINDS[c.kind].accent

	# A StyleBox takes no per-draw alpha, so the fade is baked into the colours. One
	# scratch box is re-tinted rather than duplicated: duplicating allocated a
	# Resource per card per frame, for every frame a card was on screen.
	var sb := _card_scratch
	var base := _card_style.bg_color
	var bord := _card_style.border_color
	sb.bg_color = Color(base.r, base.g, base.b, base.a * alpha)
	sb.border_color = Color(bord.r, bord.g, bord.b, bord.a * alpha)
	sb.shadow_color = Color(0, 0, 0, 0.45 * alpha)
	draw_style_box(sb, rect)

	# accent edge
	draw_rect(Rect2(rect.position + Vector2(1, 3), Vector2(2.5, rect.size.y - 6)), Color(accent.r, accent.g, accent.b, alpha), true)

	var tx: float = rect.position.x + 18.0
	var title: String = c.title
	if c.repeat > 0:
		title = "%s  x%d" % [c.title, c.repeat + 1]
	UITheme.draw_text(
		self,
		_font_title,
		Vector2(tx, rect.position.y + 26.0),
		title.to_upper(),
		UITheme.FS_TINY,
		Color(accent.r, accent.g, accent.b, alpha)
	)
	if String(c.body) != "":
		UITheme.draw_text(
			self,
			_font_body,
			Vector2(tx, rect.position.y + 46.0),
			c.body,
			UITheme.FS_SMALL,
			Color(UITheme.PARCHMENT.r, UITheme.PARCHMENT.g, UITheme.PARCHMENT.b, alpha * 0.94)
		)
