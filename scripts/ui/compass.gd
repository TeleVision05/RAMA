class_name Compass
extends Control
## A slim heading strip along the top of the screen.
##
## Not a minimap: it shows which way you are looking, where the places you have found
## lie, and where the current objective is. Everything is drawn by hand so the marks
## can fade individually towards the ends of the strip, which is what stops it reading
## as a HUD gadget bolted onto an atmospheric game.
##
## Bearings are clockwise from north, and north is -Z. The player's yaw runs the other
## way (forward is `Vector3(-sin(yaw), 0, -cos(yaw))`), so heading = -yaw.

const SPAN_DEG := 104.0  # half-width of the visible arc, in degrees
const CARDINALS := {
	0.0: "N",
	45.0: "NE",
	90.0: "E",
	135.0: "SE",
	180.0: "S",
	225.0: "SW",
	270.0: "W",
	315.0: "NW",
}

## World positions of the places the game can talk about. Ids come through
## `EventBus.location_discovered`; anything not in here still notifies, it simply has
## no bearing to point at.
const PLACES := {
	"village": Vector2(-120, 44),
	"panchavati": Vector2(-120, 44),
	"shrine": Vector2(158, -66),
	"temple": Vector2(158, -66),
	"ruins": Vector2(-168, -148),
	"waterfall": Vector2(38, -196),
	"falls": Vector2(38, -196),
	"ford": Vector2(-34, 8),
	"forest_camp": Vector2(-196, -34),
	"camp": Vector2(-196, -34),
	"hidden_grove": Vector2(-322, 118),
	"grove": Vector2(-322, 118),
	"badlands": Vector2(214, 178),
	"fields": Vector2(-92, 6),
	"lookout": Vector2(96, -150),
}

var heading_deg: float = 0.0  # smoothed, what is actually drawn
var _heading_target: float = 0.0
var origin: Vector2 = Vector2.ZERO  # player position in world XZ
var fade: float = 1.0  # global opacity, driven by the HUD

var _marks: Array = []  # {pos: Vector2, name: String, kind: String}
var _objective: Dictionary = {}  # {pos: Vector2, name: String} or empty
var _pulse: float = 0.0

var _font_small: Font
var _font_eyebrow: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(660, 58)
	_font_small = UITheme.font(0, 0.0)
	_font_eyebrow = UITheme.eyebrow_font()
	set_process(true)


func _process(delta: float) -> void:
	# Shortest-arc smoothing so crossing north does not spin the strip.
	var d: float = wrapf(_heading_target - heading_deg, -180.0, 180.0)
	heading_deg = wrapf(heading_deg + d * clampf(delta * 14.0, 0.0, 1.0), 0.0, 360.0)
	_pulse += delta
	queue_redraw()


## Called every frame by the HUD with the camera yaw and the player's ground position.
func set_view(yaw_radians: float, world_xz: Vector2) -> void:
	_heading_target = wrapf(-rad_to_deg(yaw_radians), 0.0, 360.0)
	origin = world_xz


func add_place(id: String, display_name: String) -> void:
	var key := id.to_lower()
	var pos: Vector2 = PLACES.get(key, Vector2.INF)
	if pos == Vector2.INF:
		# Try the last word: "the_hidden_grove" still lands on "grove".
		for k in PLACES.keys():
			if key.ends_with(String(k)):
				pos = PLACES[k]
				break
	if pos == Vector2.INF:
		return
	for m in _marks:
		if m.id == key:
			return
	(
		_marks
		. append(
			{
				"id": key,
				"pos": pos,
				"name": display_name if display_name != "" else UITheme.prettify(id),
				"kind": "place",
			}
		)
	)


func clear_places() -> void:
	_marks.clear()


func set_objective(world_pos: Vector3, label: String, active: bool = true) -> void:
	if not active:
		_objective = {}
		return
	_objective = {"pos": Vector2(world_pos.x, world_pos.z), "name": label}


func has_objective() -> bool:
	return not _objective.is_empty()


func place_count() -> int:
	return _marks.size()


## Screen x for a bearing, plus how visible it is at that x. Returns Vector2(x, alpha).
func _project(bearing_deg: float) -> Vector2:
	var rel: float = wrapf(bearing_deg - heading_deg, -180.0, 180.0)
	if absf(rel) > SPAN_DEG:
		return Vector2(-1.0, 0.0)
	var x: float = size.x * 0.5 + (rel / SPAN_DEG) * (size.x * 0.5)
	var edge: float = clampf(1.0 - (absf(rel) / SPAN_DEG - 0.62) / 0.38, 0.0, 1.0)
	return Vector2(x, edge)


static func bearing_to(from: Vector2, to: Vector2) -> float:
	var d := to - from
	if d.length_squared() < 0.0001:
		return 0.0
	return wrapf(rad_to_deg(atan2(d.x, -d.y)), 0.0, 360.0)


func _draw() -> void:
	if fade <= 0.004:
		return
	var w := size.x
	var h := size.y
	var base_y := h * 0.58
	var a := fade

	# --- the rule the marks hang from ------------------------------------
	# Faded at both ends by drawing it in segments with falling alpha.
	var segs := 48
	for i in range(segs):
		var t0: float = float(i) / float(segs)
		var t1: float = float(i + 1) / float(segs)
		var mid: float = (t0 + t1) * 0.5
		var e: float = clampf(1.0 - absf(mid - 0.5) * 2.24, 0.0, 1.0)
		e = pow(e, 0.8)
		if e <= 0.01:
			continue
		_ink_line(
			Vector2(t0 * w, base_y),
			Vector2(t1 * w, base_y),
			Color(UITheme.PARCHMENT.r, UITheme.PARCHMENT.g, UITheme.PARCHMENT.b, 0.30 * e * a)
		)

	# --- degree ticks every 15 deg ---------------------------------------
	var start: int = int(floor((heading_deg - SPAN_DEG) / 15.0)) * 15
	var stop: int = int(ceil((heading_deg + SPAN_DEG) / 15.0)) * 15
	var deg := start
	while deg <= stop:
		var p := _project(float(deg))
		if p.y > 0.0:
			var major: bool = (deg % 45) == 0
			var tick: float = 6.0 if major else 3.0
			_ink_line(
				Vector2(p.x, base_y - tick),
				Vector2(p.x, base_y),
				Color(
					UITheme.PARCHMENT.r, UITheme.PARCHMENT.g, UITheme.PARCHMENT.b, (0.50 if major else 0.26) * p.y * a
				)
			)
		deg += 15

	# --- cardinal letters -------------------------------------------------
	for key in CARDINALS.keys():
		var p := _project(float(key))
		if p.y <= 0.0:
			continue
		var txt: String = CARDINALS[key]
		var cardinal: bool = txt.length() == 1
		var fs: int = UITheme.FS_SMALL if cardinal else UITheme.FS_TINY
		var col: Color = UITheme.PARCHMENT if cardinal else UITheme.PARCHMENT_FAINT
		if txt == "N":
			col = UITheme.SAFFRON_PALE
		var tw: float = _font_eyebrow.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		UITheme.draw_text(
			self,
			_font_eyebrow,
			Vector2(p.x - tw * 0.5, base_y - 11.0),
			txt,
			fs,
			Color(col.r, col.g, col.b, p.y * a * (1.0 if cardinal else 0.7))
		)

	# --- discovered places ------------------------------------------------
	for m in _marks:
		var b := bearing_to(origin, m.pos)
		var p := _project(b)
		if p.y <= 0.0:
			continue
		var col := UITheme.BRASS
		_diamond(Vector2(p.x, base_y + 7.0), 3.4, Color(col.r, col.g, col.b, p.y * a * 0.9))
		# Name only for the one nearest the centre of the strip.
		if absf(p.x - w * 0.5) < 26.0:
			var dist: float = origin.distance_to(m.pos)
			var lbl: String = "%s  %d m" % [m.name, int(dist)]
			var lw: float = _font_small.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_TINY).x
			UITheme.draw_text(
				self,
				_font_small,
				Vector2(p.x - lw * 0.5, base_y + 24.0),
				lbl,
				UITheme.FS_TINY,
				Color(col.r, col.g, col.b, p.y * a * 0.95)
			)

	# --- the objective ----------------------------------------------------
	if not _objective.is_empty():
		var b := bearing_to(origin, _objective.pos)
		var p := _project(b)
		var pulse: float = 0.72 + 0.28 * sin(_pulse * 2.4)
		if p.y > 0.0:
			var col := UITheme.SAFFRON
			_chevron(Vector2(p.x, base_y + 9.0), 5.2, Color(col.r, col.g, col.b, p.y * a * pulse))
			var dist: float = origin.distance_to(_objective.pos)
			var lbl: String = "%d m" % int(dist)
			var lw: float = _font_small.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_TINY).x
			UITheme.draw_text(
				self,
				_font_small,
				Vector2(p.x - lw * 0.5, base_y + 26.0),
				lbl,
				UITheme.FS_TINY,
				Color(col.r, col.g, col.b, p.y * a * 0.9)
			)
		else:
			# Off the strip: pin an arrow to whichever end is closer.
			var rel: float = wrapf(b - heading_deg, -180.0, 180.0)
			var x: float = 6.0 if rel < 0.0 else w - 6.0
			var col2 := UITheme.SAFFRON
			_side_arrow(Vector2(x, base_y + 8.0), rel < 0.0, Color(col2.r, col2.g, col2.b, a * 0.55 * pulse))

	# --- the centre reticle ----------------------------------------------
	var cx := w * 0.5
	_ink_line(
		Vector2(cx, base_y - 11.0),
		Vector2(cx, base_y + 4.0),
		Color(UITheme.SAFFRON_PALE.r, UITheme.SAFFRON_PALE.g, UITheme.SAFFRON_PALE.b, 0.70 * a)
	)
	_diamond(
		Vector2(cx, base_y - 13.0),
		3.0,
		Color(UITheme.SAFFRON_PALE.r, UITheme.SAFFRON_PALE.g, UITheme.SAFFRON_PALE.b, 0.85 * a)
	)


## Every mark on this strip is pale, and the strip sits across the top of the screen —
## which in this game is sky and sunlit rock about as often as it is thatch. Pale on
## pale is invisible: against the village at noon the whole compass read as a smudge.
## The type already carries an ink shadow; the linework needs the same, or the letters
## float over nothing.
func _ink_line(a: Vector2, b: Vector2, col: Color, width: float = 1.0) -> void:
	draw_line(a + Vector2(0, 1), b + Vector2(0, 1), Color(0.0, 0.0, 0.0, col.a * 0.7), width, true)
	draw_line(a, b, col, width, true)


func _diamond(c: Vector2, r: float, col: Color) -> void:
	# A dark diamond one pixel out, so the brass one has an edge against the sky.
	draw_colored_polygon(
		PackedVector2Array(
			[c + Vector2(0, -r - 1.0), c + Vector2(r + 1.0, 0), c + Vector2(0, r + 1.0), c + Vector2(-r - 1.0, 0)]
		),
		Color(0.0, 0.0, 0.0, col.a * 0.6)
	)
	draw_colored_polygon(
		PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)]), col
	)


func _chevron(c: Vector2, r: float, col: Color) -> void:
	draw_colored_polygon(
		PackedVector2Array(
			[c + Vector2(0, r), c + Vector2(r, -r * 0.85), c + Vector2(0, -r * 0.25), c + Vector2(-r, -r * 0.85)]
		),
		col
	)


func _side_arrow(c: Vector2, left: bool, col: Color) -> void:
	var s: float = -1.0 if left else 1.0
	draw_colored_polygon(
		PackedVector2Array([c + Vector2(5.0 * s, 0), c + Vector2(-2.0 * s, -5.0), c + Vector2(-2.0 * s, 5.0)]), col
	)
