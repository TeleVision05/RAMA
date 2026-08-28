class_name UITheme
extends RefCounted
## The single visual language of RAMA's interface.
##
## One Theme, built in code, shared by every panel. Nothing here ships as an asset:
## the carved sandstone frame, the brass slider grabber and the vignette are all
## synthesised into ImageTextures on first use and cached for the process lifetime.
##
## The palette is the world's palette — sun-baked sandstone, ink brown, saffron,
## brass, deep indigo. Restraint is the rule: interface elements sit at low contrast
## until they have something to say.

# --- palette --------------------------------------------------------------
const INK := Color(0.075, 0.058, 0.046, 1.0)  # deepest brown-black
const INK_SOFT := Color(0.128, 0.101, 0.080, 1.0)
const INK_RAISED := Color(0.176, 0.140, 0.111, 1.0)
const PARCHMENT := Color(0.937, 0.886, 0.788, 1.0)
const PARCHMENT_DIM := Color(0.741, 0.686, 0.588, 1.0)
const PARCHMENT_FAINT := Color(0.545, 0.494, 0.415, 1.0)
const SAFFRON := Color(0.909, 0.568, 0.184, 1.0)
const SAFFRON_PALE := Color(0.960, 0.752, 0.451, 1.0)
const BRASS := Color(0.784, 0.635, 0.290, 1.0)
const BRASS_DIM := Color(0.478, 0.392, 0.196, 1.0)
const INDIGO := Color(0.113, 0.141, 0.251, 1.0)
const INDIGO_LIGHT := Color(0.227, 0.274, 0.458, 1.0)
const CRIMSON := Color(0.647, 0.203, 0.152, 1.0)
const CRIMSON_PALE := Color(0.847, 0.372, 0.290, 1.0)
const JADE := Color(0.435, 0.560, 0.352, 1.0)
const HEALTH := Color(0.827, 0.317, 0.243, 1.0)
const STAMINA := Color(0.847, 0.717, 0.376, 1.0)

# --- type ------------------------------------------------------------------
const FS_TINY := 12
const FS_SMALL := 14
const FS_BODY := 16
const FS_LABEL := 18
const FS_HEAD := 22
const FS_TITLE := 30
const FS_DISPLAY := 92

const FRAME_PATCH := 28
const FRAME_SIZE := 96

static var _theme: Theme = null
static var _fonts: Dictionary = {}
static var _textures: Dictionary = {}

# ==========================================================================
# fonts
# ==========================================================================


## A variation of the engine's default face with deliberate glyph spacing and
## optional weight. Cached per (spacing, embolden) pair.
static func font(spacing: int = 0, embolden: float = 0.0) -> Font:
	var key := "%d_%0.2f" % [spacing, embolden]
	if _fonts.has(key):
		return _fonts[key]
	var base: Font = ThemeDB.fallback_font
	if base == null:
		# Should never happen in a running project, but never hand back null.
		base = SystemFont.new()
	var fv := FontVariation.new()
	fv.base_font = base
	if spacing != 0:
		fv.set_spacing(TextServer.SPACING_GLYPH, spacing)
	if absf(embolden) > 0.001:
		fv.variation_embolden = embolden
	_fonts[key] = fv
	return fv


static func body_font() -> Font:
	return font(0, 0.0)


static func label_font() -> Font:
	return font(1, 0.08)


## Small-caps eyebrow type: wide tracking, used for section labels.
static func eyebrow_font() -> Font:
	return font(4, 0.05)


static func title_font() -> Font:
	return font(9, 0.14)


## The RAMA wordmark: very generous tracking, slight weight.
static func display_font() -> Font:
	return font(30, 0.10)


# ==========================================================================
# generated textures
# ==========================================================================


## Signed inset distance from the border of a rounded rectangle, in pixels.
## Positive inside. One formula covers corners and edges, which is what makes the
## nine-patch slicing legal: along any edge strip the value depends on one axis only.
static func _rr_inset(x: float, y: float, w: float, h: float, r: float) -> float:
	var qx: float = maxf(r - x, 0.0)
	var qy: float = maxf(r - y, 0.0)
	var qx2: float = maxf(r - (w - 1.0 - x), 0.0)
	var qy2: float = maxf(r - (h - 1.0 - y), 0.0)
	var ax: float = maxf(qx, qx2)
	var ay: float = maxf(qy, qy2)
	return r - Vector2(ax, ay).length()


## The carved sandstone frame used by every panel. 96x96 with a 28 px nine-patch
## margin: a 2 px brass outer rule, a hairline inner rule, a translucent ink field
## and a small diamond rosette carved into each corner.
static func frame_texture(
	fill: Color = Color(0.075, 0.058, 0.046, 0.93), rule: Color = Color(0.784, 0.635, 0.290, 1.0)
) -> Texture2D:
	var key := "frame_%s_%s" % [fill.to_html(), rule.to_html()]
	if _textures.has(key):
		return _textures[key]
	var s := FRAME_SIZE
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var r := 15.0
	for y in range(s):
		for x in range(s):
			var d := _rr_inset(float(x), float(y), float(s), float(s), r)
			if d < 1.0:
				continue
			var c := Color(0, 0, 0, 0)
			# outer rule, softened at both of its edges
			var outer: float = smoothstep(1.0, 2.2, d) * (1.0 - smoothstep(3.6, 4.8, d))
			# body fill begins just under the rule
			var body: float = smoothstep(2.4, 4.2, d)
			# hairline inner rule
			var inner: float = smoothstep(7.4, 8.1, d) * (1.0 - smoothstep(8.9, 9.6, d))
			# a faint bevel of light just inside the outer rule
			var bevel: float = smoothstep(4.4, 5.2, d) * (1.0 - smoothstep(6.0, 7.0, d))

			c = _over(c, Color(fill.r, fill.g, fill.b, fill.a * body))
			c = _over(c, Color(rule.r * 1.15, rule.g * 1.15, rule.b * 1.15, bevel * 0.10))
			c = _over(c, Color(rule.r, rule.g, rule.b, inner * 0.26))
			c = _over(c, Color(rule.r, rule.g, rule.b, outer * 0.85))

			# corner rosette: only ever inside a corner patch, so stretching is safe
			var cx: float = -1.0
			var cy: float = -1.0
			if x < FRAME_PATCH:
				cx = float(x)
			elif x >= s - FRAME_PATCH:
				cx = float(s - 1 - x)
			if y < FRAME_PATCH:
				cy = float(y)
			elif y >= s - FRAME_PATCH:
				cy = float(s - 1 - y)
			if cx >= 0.0 and cy >= 0.0:
				var u: float = cx - 14.0
				var v: float = cy - 14.0
				var dia: float = absf(u) + absf(v)
				var ring: float = smoothstep(4.4, 5.0, dia) * (1.0 - smoothstep(6.2, 6.9, dia))
				var pip: float = 1.0 - smoothstep(1.2, 2.1, dia)
				c = _over(c, Color(rule.r, rule.g, rule.b, ring * 0.40 + pip * 0.55))
			img.set_pixel(x, y, c)
	var t := ImageTexture.create_from_image(img)
	_textures[key] = t
	return t


static func _over(dst: Color, src: Color) -> Color:
	var a: float = src.a + dst.a * (1.0 - src.a)
	if a <= 0.0001:
		return Color(0, 0, 0, 0)
	var rr: float = (src.r * src.a + dst.r * dst.a * (1.0 - src.a)) / a
	var gg: float = (src.g * src.a + dst.g * dst.a * (1.0 - src.a)) / a
	var bb: float = (src.b * src.a + dst.b * dst.a * (1.0 - src.a)) / a
	return Color(rr, gg, bb, a)


## A small brass lozenge, used as the slider grabber.
static func grabber_texture(bright: bool = false) -> Texture2D:
	var key := "grab_%s" % bright
	if _textures.has(key):
		return _textures[key]
	var s := 22
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c: float = (s - 1) * 0.5
	var body: Color = SAFFRON_PALE if bright else BRASS
	for y in range(s):
		for x in range(s):
			var u: float = (float(x) - c) / c
			var v: float = (float(y) - c) / c
			var dia: float = absf(u) + absf(v)
			var a: float = 1.0 - smoothstep(0.74, 0.90, dia)
			if a <= 0.002:
				continue
			var edge: float = smoothstep(0.52, 0.74, dia)
			var col: Color = body.lerp(INK, edge * 0.55)
			if v < -0.1:
				col = col.lerp(Color(1, 1, 1), 0.16 * (1.0 - edge))
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	var t := ImageTexture.create_from_image(img)
	_textures[key] = t
	return t


## Screen-edge vignette. Alpha only; tint it with modulate at draw time.
static func vignette_texture() -> Texture2D:
	if _textures.has("vignette"):
		return _textures["vignette"]
	var w := 160
	var h := 90
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var u: float = (float(x) / float(w - 1)) * 2.0 - 1.0
			var v: float = (float(y) / float(h - 1)) * 2.0 - 1.0
			# elliptical falloff, biased so the corners bite hardest
			var d: float = sqrt(u * u * 0.86 + v * v)
			var a: float = smoothstep(0.34, 1.16, d)
			a = pow(a, 1.35)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	var t := ImageTexture.create_from_image(img)
	_textures["vignette"] = t
	return t


## Soft round falloff, used for glows behind small elements.
static func glow_texture() -> Texture2D:
	if _textures.has("glow"):
		return _textures["glow"]
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c: float = (s - 1) * 0.5
	for y in range(s):
		for x in range(s):
			var d: float = Vector2(float(x) - c, float(y) - c).length() / c
			var a: float = pow(clampf(1.0 - d, 0.0, 1.0), 2.2)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	var t := ImageTexture.create_from_image(img)
	_textures["glow"] = t
	return t


# ==========================================================================
# style boxes
# ==========================================================================


static func panel_style(fill: Color = Color(0.075, 0.058, 0.046, 0.93), pad: int = 22) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = frame_texture(fill)
	sb.set_texture_margin_all(FRAME_PATCH)
	sb.set_content_margin_all(pad)
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	return sb


static func flat_style(
	fill: Color, radius: int = 3, border: float = 0.0, border_col: Color = BRASS_DIM, pad_x: int = 14, pad_y: int = 8
) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 6
	if border > 0.0:
		sb.set_border_width_all(int(border))
		sb.border_color = border_col
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	sb.anti_aliasing = true
	return sb


static func empty_style(pad_x: int = 14, pad_y: int = 8) -> StyleBoxEmpty:
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


# ==========================================================================
# the theme
# ==========================================================================


static func get_theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = body_font()
	t.default_font_size = FS_BODY

	# --- Label ------------------------------------------------------------
	t.set_type_variation("Eyebrow", "Label")
	t.set_type_variation("Dim", "Label")
	t.set_type_variation("Head", "Label")
	t.set_type_variation("Title", "Label")
	t.set_type_variation("Display", "Label")
	t.set_type_variation("Value", "Label")

	t.set_color("font_color", "Label", PARCHMENT)
	t.set_font("font", "Label", body_font())
	t.set_font_size("font_size", "Label", FS_BODY)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.55))
	t.set_constant("shadow_offset_x", "Label", 0)
	t.set_constant("shadow_offset_y", "Label", 1)
	t.set_constant("shadow_outline_size", "Label", 1)

	t.set_font("font", "Eyebrow", eyebrow_font())
	t.set_font_size("font_size", "Eyebrow", FS_TINY)
	t.set_color("font_color", "Eyebrow", BRASS)

	t.set_font("font", "Dim", body_font())
	t.set_font_size("font_size", "Dim", FS_SMALL)
	t.set_color("font_color", "Dim", PARCHMENT_DIM)

	t.set_font("font", "Head", label_font())
	t.set_font_size("font_size", "Head", FS_HEAD)
	t.set_color("font_color", "Head", PARCHMENT)

	t.set_font("font", "Title", title_font())
	t.set_font_size("font_size", "Title", FS_TITLE)
	t.set_color("font_color", "Title", SAFFRON_PALE)

	t.set_font("font", "Display", display_font())
	t.set_font_size("font_size", "Display", FS_DISPLAY)
	t.set_color("font_color", "Display", PARCHMENT)

	t.set_font("font", "Value", label_font())
	t.set_font_size("font_size", "Value", FS_SMALL)
	t.set_color("font_color", "Value", BRASS)

	# --- Panel ------------------------------------------------------------
	t.set_stylebox("panel", "Panel", panel_style())
	t.set_stylebox("panel", "PanelContainer", panel_style())
	t.set_type_variation("Inset", "PanelContainer")
	t.set_stylebox(
		"panel",
		"Inset",
		flat_style(Color(0.043, 0.035, 0.031, 0.62), 3, 1.0, Color(BRASS_DIM.r, BRASS_DIM.g, BRASS_DIM.b, 0.35), 16, 12)
	)

	# --- Button -----------------------------------------------------------
	var b_normal := flat_style(
		Color(INK_SOFT.r, INK_SOFT.g, INK_SOFT.b, 0.72),
		3,
		1.0,
		Color(BRASS_DIM.r, BRASS_DIM.g, BRASS_DIM.b, 0.55),
		18,
		10
	)
	var b_hover := flat_style(Color(0.243, 0.176, 0.098, 0.88), 3, 1.0, Color(BRASS.r, BRASS.g, BRASS.b, 0.85), 18, 10)
	var b_press := flat_style(
		Color(0.302, 0.192, 0.078, 0.95), 3, 1.0, Color(SAFFRON.r, SAFFRON.g, SAFFRON.b, 0.95), 18, 10
	)
	var b_disabled := flat_style(Color(0.086, 0.074, 0.066, 0.55), 3, 1.0, Color(0.28, 0.25, 0.21, 0.35), 18, 10)
	var b_focus := StyleBoxFlat.new()
	b_focus.bg_color = Color(0, 0, 0, 0)
	b_focus.set_corner_radius_all(3)
	b_focus.set_border_width_all(1)
	b_focus.border_color = Color(SAFFRON_PALE.r, SAFFRON_PALE.g, SAFFRON_PALE.b, 0.9)
	b_focus.expand_margin_left = 3
	b_focus.expand_margin_right = 3
	b_focus.expand_margin_top = 2
	b_focus.expand_margin_bottom = 2
	b_focus.anti_aliasing = true

	for ty in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", ty, b_normal)
		t.set_stylebox("hover", ty, b_hover)
		t.set_stylebox("pressed", ty, b_press)
		t.set_stylebox("disabled", ty, b_disabled)
		t.set_stylebox("focus", ty, b_focus)
		t.set_font("font", ty, label_font())
		t.set_font_size("font_size", ty, FS_BODY)
		t.set_color("font_color", ty, PARCHMENT_DIM)
		t.set_color("font_hover_color", ty, PARCHMENT)
		t.set_color("font_pressed_color", ty, SAFFRON_PALE)
		t.set_color("font_focus_color", ty, PARCHMENT)
		t.set_color("font_disabled_color", ty, Color(0.42, 0.38, 0.33, 0.75))

	# A quieter button: no plate, just type with a saffron rule that lights on hover.
	t.set_type_variation("Menu", "Button")
	var m_normal := empty_style(6, 9)
	var m_hover := StyleBoxFlat.new()
	m_hover.bg_color = Color(SAFFRON.r, SAFFRON.g, SAFFRON.b, 0.10)
	m_hover.border_width_left = 2
	m_hover.border_color = SAFFRON
	m_hover.content_margin_left = 12
	m_hover.content_margin_right = 6
	m_hover.content_margin_top = 9
	m_hover.content_margin_bottom = 9
	m_hover.set_corner_radius_all(2)
	m_hover.anti_aliasing = true
	var m_press := m_hover.duplicate() as StyleBoxFlat
	m_press.bg_color = Color(SAFFRON.r, SAFFRON.g, SAFFRON.b, 0.20)
	var m_focus := StyleBoxFlat.new()
	m_focus.bg_color = Color(0, 0, 0, 0)
	m_focus.border_width_left = 2
	m_focus.border_color = Color(BRASS.r, BRASS.g, BRASS.b, 0.8)
	m_focus.content_margin_left = 12
	m_focus.content_margin_right = 6
	m_focus.content_margin_top = 9
	m_focus.content_margin_bottom = 9
	t.set_stylebox("normal", "Menu", m_normal)
	t.set_stylebox("hover", "Menu", m_hover)
	t.set_stylebox("pressed", "Menu", m_press)
	t.set_stylebox("focus", "Menu", m_focus)
	t.set_stylebox("disabled", "Menu", empty_style(6, 9))
	t.set_font("font", "Menu", font(3, 0.06))
	t.set_font_size("font_size", "Menu", FS_LABEL)
	t.set_color("font_color", "Menu", PARCHMENT_DIM)
	t.set_color("font_hover_color", "Menu", SAFFRON_PALE)
	t.set_color("font_pressed_color", "Menu", SAFFRON)
	t.set_color("font_focus_color", "Menu", PARCHMENT)
	t.set_color("font_disabled_color", "Menu", Color(0.38, 0.34, 0.30, 0.8))

	# --- HSlider ----------------------------------------------------------
	# The track needs real content margins: an HSlider takes its height from the
	# stylebox's minimum size, and a box with none draws as nothing at all.
	var s_bg := StyleBoxFlat.new()
	s_bg.bg_color = Color(0.031, 0.027, 0.023, 0.88)
	s_bg.set_corner_radius_all(3)
	s_bg.corner_detail = 6
	s_bg.set_border_width_all(1)
	s_bg.border_color = Color(BRASS_DIM.r, BRASS_DIM.g, BRASS_DIM.b, 0.55)
	s_bg.content_margin_left = 0
	s_bg.content_margin_right = 0
	s_bg.content_margin_top = 3
	s_bg.content_margin_bottom = 3
	s_bg.anti_aliasing = true

	var s_fill := StyleBoxFlat.new()
	s_fill.bg_color = Color(0.588, 0.427, 0.156, 0.95)
	s_fill.set_corner_radius_all(3)
	s_fill.corner_detail = 6
	s_fill.content_margin_left = 0
	s_fill.content_margin_right = 0
	s_fill.content_margin_top = 3
	s_fill.content_margin_bottom = 3
	s_fill.anti_aliasing = true

	var s_fill_hi := s_fill.duplicate() as StyleBoxFlat
	s_fill_hi.bg_color = Color(0.752, 0.545, 0.196, 1.0)

	t.set_stylebox("slider", "HSlider", s_bg)
	t.set_stylebox("grabber_area", "HSlider", s_fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", s_fill_hi)
	t.set_icon("grabber", "HSlider", grabber_texture(false))
	t.set_icon("grabber_highlight", "HSlider", grabber_texture(true))
	t.set_constant("center_grabber", "HSlider", 1)

	# --- Scroll -----------------------------------------------------------
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("scroll", "VScrollBar", flat_style(Color(0.031, 0.027, 0.023, 0.5), 3, 0.0, BRASS, 0, 0))
	t.set_stylebox(
		"grabber", "VScrollBar", flat_style(Color(BRASS_DIM.r, BRASS_DIM.g, BRASS_DIM.b, 0.8), 3, 0.0, BRASS, 0, 0)
	)
	t.set_stylebox(
		"grabber_highlight", "VScrollBar", flat_style(Color(BRASS.r, BRASS.g, BRASS.b, 0.9), 3, 0.0, BRASS, 0, 0)
	)
	t.set_stylebox(
		"grabber_pressed", "VScrollBar", flat_style(Color(SAFFRON.r, SAFFRON.g, SAFFRON.b, 0.9), 3, 0.0, BRASS, 0, 0)
	)

	# --- Separator --------------------------------------------------------
	var sep := StyleBoxLine.new()
	sep.color = Color(BRASS_DIM.r, BRASS_DIM.g, BRASS_DIM.b, 0.55)
	sep.thickness = 1
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 10)

	_theme = t
	return t


# ==========================================================================
# shared drawing helpers
# ==========================================================================


## A carved horizontal rule: two hairlines with a small diamond at the centre.
## Used to divide sections without a heavy border.
static func carved_rule(
	ci: CanvasItem, from: Vector2, width: float, col: Color = BRASS_DIM, alpha: float = 0.7
) -> void:
	var c := Color(col.r, col.g, col.b, col.a * alpha)
	var faint := Color(col.r, col.g, col.b, col.a * alpha * 0.35)
	var mid := from.x + width * 0.5
	ci.draw_line(from, Vector2(mid - 9.0, from.y), c, 1.0, true)
	ci.draw_line(Vector2(mid + 9.0, from.y), Vector2(from.x + width, from.y), c, 1.0, true)
	ci.draw_line(from + Vector2(0, 2), Vector2(mid - 9.0, from.y + 2), faint, 1.0, true)
	ci.draw_line(Vector2(mid + 9.0, from.y + 2), Vector2(from.x + width, from.y + 2), faint, 1.0, true)
	var pts := PackedVector2Array(
		[
			Vector2(mid, from.y - 4.0),
			Vector2(mid + 4.5, from.y + 1.0),
			Vector2(mid, from.y + 6.0),
			Vector2(mid - 4.5, from.y + 1.0)
		]
	)
	ci.draw_colored_polygon(pts, c)


## A slim bar with a soft cap on each end. `frac` fills from the left.
## Draws as a capsule so nothing about it reads as a progress widget.
static func draw_bar(ci: CanvasItem, rect: Rect2, frac: float, fill: Color, track: Color, alpha: float = 1.0) -> void:
	var h := rect.size.y
	var r := h * 0.5
	var tc := Color(track.r, track.g, track.b, track.a * alpha)
	ci.draw_line(
		Vector2(rect.position.x + r, rect.position.y + r), Vector2(rect.end.x - r, rect.position.y + r), tc, h, true
	)
	var f: float = clampf(frac, 0.0, 1.0)
	if f <= 0.0005:
		return
	var w: float = maxf((rect.size.x - h) * f, 0.5)
	var fc := Color(fill.r, fill.g, fill.b, fill.a * alpha)
	ci.draw_line(
		Vector2(rect.position.x + r, rect.position.y + r),
		Vector2(rect.position.x + r + w, rect.position.y + r),
		fc,
		h,
		true
	)


## Text with a soft ink shadow, so parchment type stays legible over bright terrain.
## Two offset passes rather than one: a single-pixel drop shadow disappears against
## sunlit sandstone, which is most of this world.
static func draw_text(
	ci: CanvasItem,
	f: Font,
	pos: Vector2,
	text: String,
	size: int,
	col: Color,
	align: int = HORIZONTAL_ALIGNMENT_LEFT,
	width: float = -1.0
) -> void:
	if col.a <= 0.004:
		return
	var shade := Color(0.0, 0.0, 0.0, col.a * 0.55)
	ci.draw_string(f, pos + Vector2(1, 1), text, align, width, size, shade)
	ci.draw_string(f, pos + Vector2(-1, 1), text, align, width, size, shade)
	ci.draw_string(f, pos + Vector2(0, 2), text, align, width, size, Color(0.0, 0.0, 0.0, col.a * 0.35))
	ci.draw_string(f, pos, text, align, width, size, col)


static func text_width(f: Font, text: String, size: int) -> float:
	return f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## Format a 0..24 hour clock the way the journal and save slots want it.
static func clock(hours: float) -> String:
	# Round to the minute FIRST and carry, rather than rounding the minutes alone:
	# 17.999 h is 18:00, and taking the hour from `floor` while rounding the minutes
	# to 60 printed it as 17:00 — an hour out, at every hour boundary.
	var total: int = int(round(fposmod(hours, 24.0) * 60.0))
	total = posmod(total, 24 * 60)
	return "%02d:%02d" % [total / 60, total % 60]


## "2 h 14 m" / "3 m 09 s" — play time, never raw seconds.
static func duration(seconds: float) -> String:
	var s: int = int(maxf(seconds, 0.0))
	var h: int = s / 3600
	var m: int = (s % 3600) / 60
	if h > 0:
		return "%d h %02d m" % [h, m]
	return "%d m %02d s" % [m, s % 60]


## "hidden_grove" -> "Hidden Grove". The fallback whenever a content system has not
## registered a display name for an id yet.
static func prettify(id: String) -> String:
	var parts := id.replace("-", "_").split("_", false)
	var out: PackedStringArray = []
	for p in parts:
		if p.length() == 0:
			continue
		out.append(p.substr(0, 1).to_upper() + p.substr(1))
	return " ".join(out)
