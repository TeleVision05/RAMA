class_name InventoryPanel
extends Control
## Rama's satchel. A small grid, not an RPG spreadsheet.
##
## Icons are synthesised: each one is a handful of signed-distance shapes evaluated
## into a 64x64 ImageTexture the first time it is asked for, then cached for the rest
## of the process. That keeps the project license-clean and means a content system can
## invent an item id at runtime and still get something legible on screen.

const COLS := 5
const SLOT := 92.0
const SLOT_GAP := 10.0
const ICON_PX := 64

## id -> {name, desc, icon, tint}. Anything not listed still shows up, with a
## prettified name and the lotus fallback icon.
const CATALOGUE := {
	"arrow": {
		"name": "Arrow",
		"desc": "Cane shaft, iron head. Steady in a crosswind.",
		"icon": "arrow",
		"tint": "brass",
	},
	"arrows": {
		"name": "Arrows",
		"desc": "A bundle bound with waxed thread.",
		"icon": "arrow",
		"tint": "brass",
	},
	"arrow_bundle": {
		"name": "Quiver of Arrows",
		"desc": "Eight cane-shafted arrows fletched with river-heron plume. Use to replenish your quiver.",
		"icon": "arrow",
		"tint": "brass",
	},
	"healing_herb": {
		"name": "Sanjivani Herb",
		"desc": "Bitter leaf from the riverbank infused with forest vitality. Restores Jiva (Health).",
		"icon": "leaf",
		"tint": "jade",
	},
	"herb": {
		"name": "River Herb",
		"desc": "Gathered at the water's edge, still damp. Closes small wounds.",
		"icon": "leaf",
		"tint": "jade",
	},
	"healing_salve": {
		"name": "Ashram Healing Salve",
		"desc": "Clarified ghee steeped with crushed neem and turmeric. Restores deep wounds.",
		"icon": "vial",
		"tint": "jade",
	},
	"shabari_berries": {
		"name": "Shabari's Sweet Berries",
		"desc": "Tasted and offered with pure devotion at Matanga Ashram. Restores Health, Stamina, and Prana.",
		"icon": "fruit",
		"tint": "saffron",
	},
	"soma_tulsi": {
		"name": "Sacred Soma-Tulsi",
		"desc": "Fragrant basil leaf blessed by the Rishis. Restores celestial Prana for invoking Divya Astras.",
		"icon": "leaf",
		"tint": "indigo",
	},
	"lotus": {
		"name": "Sacred Lotus",
		"desc": "Padma offered at the hilltop shrine. It opens at first light.",
		"icon": "flower",
		"tint": "parchment",
	},
	"blue_lotus": {
		"name": "Nilotpala Blue Lotus",
		"desc": "Rare in still water. The sages ask for it by name for twilight puja.",
		"icon": "flower",
		"tint": "indigo",
	},
	"grove_seed": {
		"name": "Panchavati Banyan Seed",
		"desc": "A living seed from the five sacred trees of the quiet grove, warm with ancient prana.",
		"icon": "fruit",
		"tint": "jade",
	},
	"mango": {
		"name": "Ripe Mango",
		"desc": "Sun-warm and heavy from the Godavari orchard. Restores vigour for the walk back.",
		"icon": "fruit",
		"tint": "saffron",
	},
	"rice": {
		"name": "Measure of Rice",
		"desc": "Unpolished grain from the terraced fields below Panchavati.",
		"icon": "bowl",
		"tint": "parchment",
	},
	"ghee": {
		"name": "Clarified Ghee",
		"desc": "Pure butter in a stoppered clay pot. Temple lamp fuel and strengthening food.",
		"icon": "vial",
		"tint": "saffron",
	},
	"lamp_oil": {
		"name": "Sesame Lamp Oil",
		"desc": "Pressed oil for the stone dipastambha lamps that ward off the night shadows.",
		"icon": "vial",
		"tint": "saffron",
	},
	"honey": {
		"name": "Wild Forest Honey",
		"desc": "Cut from a high bough above the ford. Restores stamina and breath.",
		"icon": "vial",
		"tint": "brass",
	},
	"water_skin": {
		"name": "Godavari Water Skin",
		"desc": "Filled at the sacred ford. Cool and refreshing for a long march.",
		"icon": "vial",
		"tint": "jade",
	},
	"brass_bell": {
		"name": "Brass Ghanta",
		"desc": "Cast in bronze and brass; its clear note carries further than a shout.",
		"icon": "bell",
		"tint": "brass",
	},
	"temple_bell": {
		"name": "Sanctum Temple Bell",
		"desc": "The stolen bronze ghanta of the hilltop shrine, inscribed with solar verses.",
		"icon": "bell",
		"tint": "brass",
	},
	"goat_bell": {
		"name": "Herdsman's Copper Bell",
		"desc": "Tied to a stray goat's collar on the eastern pasture.",
		"icon": "bell",
		"tint": "saffron",
	},
	"oil_lamp": {
		"name": "Clay Diya",
		"desc": "An earthen lamp with cotton wick. Enough oil for one long watch.",
		"icon": "lamp",
		"tint": "saffron",
	},
	"amulet": {
		"name": "Suryavamsha Kavacha",
		"desc": "Solar talisman of the Ikshvaku lineage on a three-strand cord. Channels Prana.",
		"icon": "gem",
		"tint": "indigo",
	},
	"chudamani": {
		"name": "Sita's Chudamani Crest-Jewel",
		"desc": "Luminous crest-gem of Janaki, token of unwavering hope across the ocean.",
		"icon": "gem",
		"tint": "saffron",
	},
	"rama_paduka": {
		"name": "Golden Paduka of Rama",
		"desc": "Consecrated sandals entrusted to Bharata as the regent symbol of Dharma in Ayodhya.",
		"icon": "ring",
		"tint": "brass",
	},
	"ruby": {
		"name": "Uncut Manikya Ruby",
		"desc": "Cut in the old style, recovered from the sunken mandapa ruins.",
		"icon": "gem",
		"tint": "crimson",
	},
	"gold_coin": {
		"name": "Nishka Gold Coin",
		"desc": "Punch-marked solar gold, older than the forest settlement.",
		"icon": "coin",
		"tint": "brass",
	},
	"coin": {
		"name": "Karshapana Coin",
		"desc": "Stamped silver and copper from the Dakshinapatha trade road.",
		"icon": "coin",
		"tint": "brass",
	},
	"rope": {
		"name": "Coir Rope",
		"desc": "Braided coconut fibre, three fathoms. Strong enough to hold a climber.",
		"icon": "ring",
		"tint": "parchment",
	},
	"sacred_thread": {
		"name": "Yajnopavita Thread",
		"desc": "Three spun cotton strands worn over the left shoulder.",
		"icon": "ring",
		"tint": "parchment",
	},
	"palm_leaf": {
		"name": "Tala-Patra Folio",
		"desc": "Incised with an iron stylus and rubbed with lampblack. Verses of the Adi Kavya.",
		"icon": "scroll",
		"tint": "parchment",
	},
	"scroll": {
		"name": "Birch-Bark Scroll",
		"desc": "Rolled bhurjapatra tied with red thread. A sage's commentary on the Astras.",
		"icon": "scroll",
		"tint": "parchment",
	},
	"key": {
		"name": "Sanctum Iron Key",
		"desc": "Heavy wrought iron. Opens an old chest in the ruined mandapa.",
		"icon": "key",
		"tint": "brass",
	},
	"iron_scrap": {
		"name": "Forged Loham Iron",
		"desc": "Fragments of dark meteoric iron suitable for arrowheads and smithing.",
		"icon": "blade",
		"tint": "parchment",
	},
	"rakshasa_fang": {
		"name": "Rakshasa Fang",
		"desc": "Jagged trophy from a night-stalker of Dandakaranya.",
		"icon": "fang",
		"tint": "parchment",
	},
	"rakshasa_horn": {
		"name": "Rakshasa War-Horn",
		"desc": "Curved black horn of a Lanka vanguard captain, etched with ash.",
		"icon": "fang",
		"tint": "crimson",
	},
	"beast_claw": {
		"name": "Dandaka Beast Claw",
		"desc": "Hooked talon shed by a predator in the ravines.",
		"icon": "fang",
		"tint": "brass",
	},
	"beast_pelt": {
		"name": "Spotted Forest Pelt",
		"desc": "Thick hide cured with bark tannin against the monsoon chill.",
		"icon": "scroll",
		"tint": "saffron",
	},
	"bow_string": {
		"name": "Kodanda Bowstring",
		"desc": "Twisted sinew and silk, waxed against the river damp.",
		"icon": "ring",
		"tint": "brass",
	},
	"torch": {
		"name": "Resin Torch",
		"desc": "Dammar-resin cloth bound to a sal-wood shaft.",
		"icon": "lamp",
		"tint": "crimson",
	},
	"flint": {
		"name": "Chakmak Flint",
		"desc": "A struck quartz edge and dry tinder.",
		"icon": "gem",
		"tint": "parchment",
	},
	"sandalwood": {
		"name": "Malaya Sandalwood",
		"desc": "Heartwood billet from the southern hills. Scents everything it touches.",
		"icon": "blade",
		"tint": "brass",
	},
}

const TINTS := {
	"brass": Color(0.784, 0.635, 0.290),
	"saffron": Color(0.909, 0.568, 0.184),
	"jade": Color(0.435, 0.560, 0.352),
	"crimson": Color(0.647, 0.203, 0.152),
	"indigo": Color(0.302, 0.372, 0.612),
	"parchment": Color(0.800, 0.752, 0.658),
}

static var _icon_cache: Dictionary = {}

var _entries: Array = []  # [{id, count, name, desc, icon, tint}]
var _selected: int = 0
var _hover: int = -1
var _hover_use: bool = false
var _use_rect := Rect2()
var _panel: StyleBoxTexture
var _slot_style: StyleBoxFlat
var _slot_sel: StyleBoxFlat
var _t: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Offsets must be reset too: setting anchors alone on a node that is already
	# in the tree preserves the current (zero) rect and the panel never grows.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme()
	_panel = UITheme.panel_style(Color(0.066, 0.052, 0.043, 0.95), 26)
	_slot_style = UITheme.flat_style(
		Color(0.043, 0.035, 0.031, 0.72), 3, 1.0, Color(UITheme.BRASS_DIM.r, UITheme.BRASS_DIM.g, UITheme.BRASS_DIM.b, 0.42), 0, 0
	)
	_slot_sel = UITheme.flat_style(
		Color(0.192, 0.133, 0.062, 0.86), 3, 1.0, Color(UITheme.SAFFRON.r, UITheme.SAFFRON.g, UITheme.SAFFRON.b, 0.95), 0, 0
	)
	set_process(true)
	refresh()


func _process(delta: float) -> void:
	_t += delta
	if visible:
		queue_redraw()


## Rebuild from GameState. Arrows are shown first because they are the resource the
## player actually watches.
func refresh() -> void:
	_entries.clear()
	if GameState.arrows > 0:
		_entries.append(_entry("arrow", GameState.arrows))
	var ids: Array = GameState.inventory.keys()
	ids.sort()
	for id in ids:
		var c: int = int(GameState.inventory[id])
		if c <= 0:
			continue
		_entries.append(_entry(String(id), c))
	_selected = clampi(_selected, 0, maxi(_entries.size() - 1, 0))
	queue_redraw()


func entry_count() -> int:
	return _entries.size()


func selected_id() -> String:
	if _selected < 0 or _selected >= _entries.size():
		return ""
	return _entries[_selected].id


static func _entry(id: String, count: int) -> Dictionary:
	var meta: Dictionary = CATALOGUE.get(id, {})
	return {
		"id": id,
		"count": count,
		"name": String(meta.get("name", UITheme.prettify(id))),
		"desc": String(meta.get("desc", "Something picked up along the road.")),
		"icon": String(meta.get("icon", "lotus")),
		"tint": String(meta.get("tint", "parchment")),
	}


## Public so notifications and the journal can show the same icon for an item.
static func icon_for(id: String) -> Texture2D:
	var meta: Dictionary = CATALOGUE.get(id, {})
	var kind: String = String(meta.get("icon", "lotus"))
	var tint: String = String(meta.get("tint", "parchment"))
	return icon_texture(kind, tint)


static func icon_texture(kind: String, tint_name: String) -> Texture2D:
	var key := kind + "|" + tint_name
	if _icon_cache.has(key):
		return _icon_cache[key]
	var tint: Color = TINTS.get(tint_name, TINTS["parchment"])
	var img := Image.create(ICON_PX, ICON_PX, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var n: float = float(ICON_PX - 1)
	for y in range(ICON_PX):
		for x in range(ICON_PX):
			var u: float = (float(x) / n) * 2.0 - 1.0
			var v: float = (float(y) / n) * 2.0 - 1.0
			var c := _shade(kind, Vector2(u, v), tint)
			if c.a > 0.002:
				img.set_pixel(x, y, c)
	var t := ImageTexture.create_from_image(img)
	_icon_cache[key] = t
	return t


# --- signed distance helpers ----------------------------------------------
static func _sd_circle(p: Vector2, r: float) -> float:
	return p.length() - r


static func _sd_box(p: Vector2, b: Vector2, r: float = 0.0) -> float:
	var d := Vector2(absf(p.x), absf(p.y)) - b + Vector2(r, r)
	return Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length() + minf(maxf(d.x, d.y), 0.0) - r


static func _sd_seg(p: Vector2, a: Vector2, b: Vector2, w: float) -> float:
	var pa := p - a
	var ba := b - a
	var h: float = clampf(pa.dot(ba) / maxf(ba.dot(ba), 0.00001), 0.0, 1.0)
	return (pa - ba * h).length() - w


static func _sd_tri(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> float:
	# Distance to the triangle's boundary, negative inside. It has to be the distance
	# to the three *segments*, not to the three lines: extending the lines lights up
	# thin streaks right across the icon, which is how the arrow first came out as an
	# X of hairlines.
	var d: float = minf(minf(_sd_seg(p, a, b, 0.0), _sd_seg(p, b, c, 0.0)), _sd_seg(p, c, a, 0.0))
	var e1 := _edge(p, a, b)
	var e2 := _edge(p, b, c)
	var e3 := _edge(p, c, a)
	var inside: bool = (e1 <= 0.0 and e2 <= 0.0 and e3 <= 0.0) or (e1 >= 0.0 and e2 >= 0.0 and e3 >= 0.0)
	return -d if inside else d


static func _edge(p: Vector2, a: Vector2, b: Vector2) -> float:
	var e := b - a
	return (p.x - a.x) * e.y - (p.y - a.y) * e.x


static func _rot(p: Vector2, a: float) -> Vector2:
	var c := cos(a)
	var s := sin(a)
	return Vector2(p.x * c - p.y * s, p.x * s + p.y * c)


static func _fill(d: float, col: Color, soft: float = 0.045) -> Color:
	var a: float = 1.0 - smoothstep(0.0, soft, d)
	return Color(col.r, col.g, col.b, col.a * clampf(a, 0.0, 1.0))


static func _blend(dst: Color, src: Color) -> Color:
	var a: float = src.a + dst.a * (1.0 - src.a)
	if a <= 0.0001:
		return Color(0, 0, 0, 0)
	return Color(
		(src.r * src.a + dst.r * dst.a * (1.0 - src.a)) / a,
		(src.g * src.a + dst.g * dst.a * (1.0 - src.a)) / a,
		(src.b * src.a + dst.b * dst.a * (1.0 - src.a)) / a,
		a
	)


## Evaluate one icon at a normalised point. Layers are composited back to front.
static func _shade(kind: String, p: Vector2, tint: Color) -> Color:
	var out := Color(0, 0, 0, 0)
	var dark := tint.darkened(0.55)
	var light := tint.lightened(0.35)
	var wood := Color(0.352, 0.243, 0.152)
	var steel := Color(0.635, 0.647, 0.658)

	match kind:
		"arrow":
			out = _blend(out, _fill(_sd_seg(p, Vector2(0, 0.78), Vector2(0, -0.44), 0.055), wood))
			out = _blend(out, _fill(_sd_tri(p, Vector2(0, -0.86), Vector2(0.20, -0.40), Vector2(-0.20, -0.40)), steel))
			out = _blend(out, _fill(_sd_tri(p, Vector2(0.05, 0.36), Vector2(0.34, 0.74), Vector2(0.05, 0.76)), tint))
			out = _blend(out, _fill(_sd_tri(p, Vector2(-0.05, 0.36), Vector2(-0.34, 0.74), Vector2(-0.05, 0.76)), tint.darkened(0.15)))
		"leaf":
			var q := _rot(p, -0.5)
			var d: float = Vector2(q.x / 0.42, q.y / 0.82).length() - 1.0
			out = _blend(out, _fill(d * 0.42, tint))
			out = _blend(out, _fill(_sd_seg(q, Vector2(0, -0.78), Vector2(0, 0.78), 0.022), dark))
			for i in range(4):
				var yy: float = -0.45 + float(i) * 0.30
				out = _blend(out, _fill(_sd_seg(q, Vector2(0, yy), Vector2(0.30, yy + 0.20), 0.014), dark))
				out = _blend(out, _fill(_sd_seg(q, Vector2(0, yy), Vector2(-0.30, yy + 0.20), 0.014), dark))
		"flower":
			var ang: float = atan2(p.y, p.x)
			var rad: float = p.length()
			var petal: float = 0.56 + 0.30 * pow(absf(cos(ang * 4.0)), 1.4)
			out = _blend(out, _fill((rad - petal) * 0.5, tint))
			out = _blend(out, _fill((rad - petal * 0.52) * 0.5, tint.lightened(0.28)))
			out = _blend(out, _fill(_sd_circle(p, 0.18), Color(0.909, 0.568, 0.184)))
			out = _blend(out, _fill(_sd_circle(p, 0.07), Color(0.960, 0.850, 0.560)))
		"vial":
			out = _blend(out, _fill(_sd_box(p + Vector2(0, -0.18), Vector2(0.34, 0.46), 0.24), Color(0.30, 0.27, 0.24, 0.92)))
			out = _blend(out, _fill(_sd_box(p + Vector2(0, -0.24), Vector2(0.26, 0.30), 0.18), tint))
			out = _blend(out, _fill(_sd_box(p + Vector2(0, 0.52), Vector2(0.13, 0.22), 0.05), Color(0.30, 0.27, 0.24)))
			out = _blend(out, _fill(_sd_box(p + Vector2(0, 0.74), Vector2(0.19, 0.09), 0.04), wood))
		"gem":
			var dd: float = absf(p.x) * 1.35 + absf(p.y) * 0.95 - 0.72
			out = _blend(out, _fill(dd * 0.6, tint))
			out = _blend(out, _fill(maxf(dd * 0.6, _edge(p, Vector2(-0.5, -0.1), Vector2(0.0, -0.62)) * 0.5), light))
			out = _blend(out, _fill(_sd_seg(p, Vector2(-0.44, -0.06), Vector2(0.44, -0.06), 0.016), dark))
		"coin":
			out = _blend(out, _fill(_sd_circle(p, 0.80), tint))
			out = _blend(out, _fill(absf(_sd_circle(p, 0.63)) - 0.030, dark))
			var a2: float = atan2(p.y, p.x)
			out = _blend(out, _fill(absf(p.length() - 0.34) - 0.05 + 0.04 * cos(a2 * 6.0), dark))
			out = _blend(out, _fill(_sd_circle(p, 0.11), dark))
		"scroll":
			out = _blend(out, _fill(_sd_box(p, Vector2(0.50, 0.62), 0.03), tint))
			out = _blend(out, _fill(_sd_box(p + Vector2(0, 0.66), Vector2(0.60, 0.13), 0.11), tint.darkened(0.22)))
			out = _blend(out, _fill(_sd_box(p + Vector2(0, -0.66), Vector2(0.60, 0.13), 0.11), tint.darkened(0.22)))
			for i in range(4):
				var ly: float = -0.34 + float(i) * 0.22
				var lw: float = 0.36 if i % 2 == 0 else 0.28
				out = _blend(out, _fill(_sd_seg(p, Vector2(-lw, ly), Vector2(lw, ly), 0.022), Color(0.25, 0.19, 0.14)))
		"bell":
			out = _blend(out, _fill(maxf(_sd_circle(p + Vector2(0, -0.10), 0.62), p.y - 0.42) * 0.9, tint))
			out = _blend(out, _fill(_sd_box(p + Vector2(0, -0.50), Vector2(0.66, 0.11), 0.06), tint.darkened(0.20)))
			out = _blend(out, _fill(_sd_circle(p + Vector2(0, -0.66), 0.11), dark))
			out = _blend(out, _fill(_sd_seg(p, Vector2(0, -0.66), Vector2(0, -0.86), 0.045), tint.darkened(0.30)))
		"lamp":
			out = _blend(out, _fill(maxf(_sd_circle(p + Vector2(0, -0.30), 0.58), -(p.y - 0.10)) * 0.9, Color(0.427, 0.278, 0.196)))
			out = _blend(out, _fill(_sd_box(p + Vector2(0, -0.12), Vector2(0.62, 0.07), 0.05), Color(0.494, 0.333, 0.235)))
			var fq := Vector2(p.x / 0.24, (p.y + 0.44) / 0.40)
			out = _blend(out, _fill((fq.length() - 1.0 + fq.y * 0.35) * 0.35, Color(0.980, 0.741, 0.317)))
			out = _blend(out, _fill((Vector2(p.x / 0.11, (p.y + 0.40) / 0.22).length() - 1.0) * 0.3, Color(1.0, 0.941, 0.760)))
		"key":
			out = _blend(out, _fill(absf(_sd_circle(p + Vector2(0, 0.46), 0.28)) - 0.075, tint))
			out = _blend(out, _fill(_sd_seg(p, Vector2(0, -0.18), Vector2(0, -0.86), 0.070), tint))
			out = _blend(out, _fill(_sd_box(p + Vector2(-0.17, 0.62), Vector2(0.17, 0.065), 0.02), tint))
			out = _blend(out, _fill(_sd_box(p + Vector2(-0.17, 0.44), Vector2(0.12, 0.060), 0.02), tint))
		"fang":
			out = _blend(out, _fill(_sd_tri(p, Vector2(0, 0.88), Vector2(0.30, -0.72), Vector2(-0.24, -0.72)), Color(0.870, 0.847, 0.784)))
			out = _blend(
				out,
				_fill(
					maxf(_sd_tri(p, Vector2(0, 0.88), Vector2(0.30, -0.72), Vector2(-0.24, -0.72)), -(p.y + 0.44)),
					Color(0.443, 0.372, 0.313)
				)
			)
		"blade":
			out = _blend(out, _fill(_sd_tri(p, Vector2(0, -0.90), Vector2(0.17, 0.26), Vector2(-0.17, 0.26)), steel))
			out = _blend(out, _fill(_sd_box(p + Vector2(0, -0.30), Vector2(0.42, 0.055), 0.03), tint))
			out = _blend(out, _fill(_sd_box(p + Vector2(0, -0.62), Vector2(0.085, 0.26), 0.05), wood))
		"bowl":
			out = _blend(out, _fill(maxf(_sd_circle(p + Vector2(0, -0.16), 0.66), -(p.y - 0.02)) * 0.9, Color(0.435, 0.313, 0.239)))
			out = _blend(out, _fill(_sd_box(p + Vector2(0, -0.02), Vector2(0.70, 0.075), 0.05), Color(0.529, 0.396, 0.290)))
			out = _blend(out, _fill(maxf(_sd_circle(p + Vector2(0, -0.02), 0.56), p.y + 0.02) * 0.9, tint))
		"fruit":
			var fp := _rot(p, 0.35)
			out = _blend(out, _fill((Vector2(fp.x / 0.62, fp.y / 0.74).length() - 1.0) * 0.5, tint))
			out = _blend(
				out,
				_fill(
					(Vector2((fp.x + 0.16) / 0.30, (fp.y + 0.16) / 0.34).length() - 1.0) * 0.5,
					Color(tint.r, tint.g, tint.b, 0.45).lightened(0.4)
				)
			)
			out = _blend(out, _fill(_sd_seg(p, Vector2(0.10, -0.66), Vector2(0.24, -0.90), 0.030), Color(0.352, 0.313, 0.196)))
		"ring":
			out = _blend(out, _fill(absf(_sd_circle(p, 0.62)) - 0.10, tint))
			out = _blend(out, _fill(absf(_sd_circle(p, 0.62)) - 0.035, light))
		_:
			# The lotus rosette: the fallback for anything a content system invents.
			var an: float = atan2(p.y, p.x)
			var rr: float = p.length()
			var pet: float = 0.50 + 0.32 * pow(absf(cos(an * 4.0 + 0.4)), 1.6)
			out = _blend(out, _fill((rr - pet) * 0.5, tint.darkened(0.25)))
			var pet2: float = 0.44 + 0.26 * pow(absf(cos(an * 4.0 - 0.39)), 1.6)
			out = _blend(out, _fill((rr - pet2) * 0.5, tint))
			out = _blend(out, _fill(absf(rr - 0.30) - 0.030, tint.darkened(0.45)))
			out = _blend(out, _fill(_sd_circle(p, 0.15), Color(0.784, 0.635, 0.290)))
			out = _blend(out, _fill(_sd_circle(p, 0.06), Color(0.960, 0.850, 0.560)))
	return out


# ==========================================================================
# layout + drawing
# ==========================================================================


func _panel_rect() -> Rect2:
	var w: float = COLS * SLOT + (COLS - 1) * SLOT_GAP + 64.0
	var rows: int = maxi(2, int(ceil(float(maxi(_entries.size(), 1)) / float(COLS))))
	rows = mini(rows, 4)
	var h: float = 106.0 + rows * SLOT + (rows - 1) * SLOT_GAP + 172.0
	return Rect2(Vector2((size.x - w) * 0.5, (size.y - h) * 0.5), Vector2(w, h))


func _grid_origin(pr: Rect2) -> Vector2:
	return pr.position + Vector2(32.0, 100.0)


func _slot_rect(i: int, pr: Rect2) -> Rect2:
	var o := _grid_origin(pr)
	var cx: int = i % COLS
	var cy: int = i / COLS
	return Rect2(o + Vector2(cx * (SLOT + SLOT_GAP), cy * (SLOT + SLOT_GAP)), Vector2(SLOT, SLOT))


func _gui_input(e: InputEvent) -> void:
	var pr := _panel_rect()
	if e is InputEventMouseMotion:
		var mp: Vector2 = (e as InputEventMouseMotion).position
		var was := _hover
		var was_use := _hover_use
		_hover = -1
		_hover_use = _use_rect.size.x > 0.0 and _use_rect.has_point(mp)
		for i in range(_entries.size()):
			if _slot_rect(i, pr).has_point(mp):
				_hover = i
				break
		if (_hover != was and _hover >= 0) or (_hover_use and not was_use):
			AudioDirector.play_ui("ui_hover")
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if _use_rect.size.x > 0.0 and _use_rect.has_point(mb.position):
				_use_selected()
				accept_event()
				return
			for i in range(_entries.size()):
				if _slot_rect(i, pr).has_point(mb.position):
					select(i)
					accept_event()
					return
	if e is InputEventKey and (e as InputEventKey).pressed:
		var k := (e as InputEventKey).keycode
		if k == KEY_RIGHT:
			select(_selected + 1)
			accept_event()
		elif k == KEY_LEFT:
			select(_selected - 1)
			accept_event()
		elif k == KEY_DOWN:
			select(_selected + COLS)
			accept_event()
		elif k == KEY_UP:
			select(_selected - COLS)
			accept_event()
		elif k in [KEY_E, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
			_use_selected()
			accept_event()


func _unhandled_input(e: InputEvent) -> void:
	if not visible:
		return
	if e is InputEventKey and (e as InputEventKey).pressed and not (e as InputEventKey).echo:
		var k := (e as InputEventKey).keycode
		if k in [KEY_E, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
			_use_selected()
			get_viewport().set_input_as_handled()


func _use_selected() -> void:
	var id := selected_id()
	if id == "" or id == "arrow":
		return
	var used := false
	if GameState.has_method("use_item"):
		used = bool(GameState.call("use_item", id))
	else:
		if id in ["healing_herb", "herb", "healing_salve", "shabari_berries", "mango", "honey", "ghee", "water_skin"]:
			var heal_amt := 45.0 if id in ["healing_salve", "shabari_berries"] else 28.0
			GameState.health = minf(GameState.max_health, GameState.health + heal_amt)
			GameState.stamina = minf(GameState.max_stamina, GameState.stamina + 35.0)
			GameState.remove_item(id, 1)
			EventBus.player_healed.emit(heal_amt)
			EventBus.player_stat_changed.emit(
				GameState.health, GameState.max_health, GameState.stamina, GameState.max_stamina
			)
			used = true
		elif id in ["arrow_bundle", "arrows"]:
			GameState.arrows = mini(GameState.max_arrows, GameState.arrows + 8)
			GameState.remove_item(id, 1)
			used = true
		elif id in ["soma_tulsi", "blue_lotus", "lotus"]:
			if GameState.get("prana") != null:
				var mp: float = float(GameState.get("max_prana")) if GameState.get("max_prana") != null else 100.0
				GameState.set("prana", minf(mp, float(GameState.get("prana")) + 40.0))
			GameState.remove_item(id, 1)
			used = true
		else:
			var meta: Dictionary = CATALOGUE.get(id, {})
			var nice := String(meta.get("name", UITheme.prettify(id)))
			EventBus.notify.emit("Inspecting Relic", nice, "info")
			used = true
	if used:
		AudioDirector.play_ui("ui_click")
	else:
		AudioDirector.play_ui("ui_close")
	refresh()


func select(i: int) -> void:
	if _entries.is_empty():
		return
	var n := clampi(i, 0, _entries.size() - 1)
	if n != _selected:
		_selected = n
		AudioDirector.play_ui("ui_click")
	queue_redraw()


func _draw() -> void:
	# Dim the world behind, so the panel reads as a held object, not an overlay.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.020, 0.016, 0.012, 0.62), true)
	var pr := _panel_rect()
	draw_style_box(_panel, pr)

	var f_eyebrow := UITheme.eyebrow_font()
	var f_head := UITheme.label_font()
	var f_body := UITheme.body_font()

	UITheme.draw_text(self, f_eyebrow, pr.position + Vector2(32, 44), "SATCHEL", UITheme.FS_TINY, UITheme.BRASS)
	var carried := 0
	for e in _entries:
		carried += int(e.count)
	var right := "%d ITEMS" % carried
	var rw := UITheme.text_width(f_eyebrow, right, UITheme.FS_TINY)
	UITheme.draw_text(self, f_eyebrow, Vector2(pr.end.x - 32 - rw, pr.position.y + 44), right, UITheme.FS_TINY, UITheme.PARCHMENT_FAINT)
	UITheme.carved_rule(self, pr.position + Vector2(32, 62), pr.size.x - 64)

	if _entries.is_empty():
		_use_rect = Rect2()
		UITheme.draw_text(self, f_body, pr.position + Vector2(32, 132), "Your satchel is empty.", UITheme.FS_BODY, UITheme.PARCHMENT_FAINT)
		return

	# --- slots ------------------------------------------------------------
	var shown: int = mini(_entries.size(), COLS * 4)
	for i in range(shown):
		var r := _slot_rect(i, pr)
		var sel: bool = i == _selected
		var sb: StyleBoxFlat = _slot_sel if sel else _slot_style
		if not sel and i == _hover:
			sb = _slot_style.duplicate() as StyleBoxFlat
			sb.bg_color = Color(0.113, 0.086, 0.062, 0.80)
			sb.border_color = Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, 0.70)
		draw_style_box(sb, r)
		var e: Dictionary = _entries[i]
		var tex := icon_texture(e.icon, e.tint)
		var pad := 15.0
		draw_texture_rect(
			tex,
			Rect2(r.position + Vector2(pad, pad - 4.0), Vector2(r.size.x - pad * 2.0, r.size.y - pad * 2.0)),
			false,
			Color(1, 1, 1, 1.0 if sel else 0.88)
		)
		if int(e.count) > 1:
			var cnt := str(e.count)
			var cw := UITheme.text_width(f_body, cnt, UITheme.FS_SMALL)
			UITheme.draw_text(
				self,
				f_body,
				Vector2(r.end.x - 9.0 - cw, r.end.y - 9.0),
				cnt,
				UITheme.FS_SMALL,
				UITheme.PARCHMENT if sel else UITheme.PARCHMENT_DIM
			)

	# --- detail -----------------------------------------------------------
	var rows: int = int(ceil(float(shown) / float(COLS)))
	var dy: float = _grid_origin(pr).y + rows * (SLOT + SLOT_GAP) + 16.0
	UITheme.carved_rule(self, Vector2(pr.position.x + 32, dy), pr.size.x - 64)
	var sel_e: Dictionary = _entries[_selected]
	UITheme.draw_text(self, f_head, Vector2(pr.position.x + 32, dy + 38.0), String(sel_e.name), UITheme.FS_HEAD, UITheme.PARCHMENT)
	if int(sel_e.count) > 1:
		var cw2 := UITheme.text_width(f_head, String(sel_e.name), UITheme.FS_HEAD)
		UITheme.draw_text(
			self,
			UITheme.font(1, 0.06),
			Vector2(pr.position.x + 42 + cw2, dy + 38.0),
			"x%d" % int(sel_e.count),
			UITheme.FS_SMALL,
			UITheme.BRASS
		)
	UITheme.draw_text(
		self,
		f_body,
		Vector2(pr.position.x + 32, dy + 64.0),
		String(sel_e.desc),
		UITheme.FS_SMALL,
		UITheme.PARCHMENT_DIM,
		HORIZONTAL_ALIGNMENT_LEFT,
		pr.size.x - 64
	)
	if String(sel_e.id) != "arrow":
		var btn_label := "[E / Enter]  Use / Attune Item"
		var bw: float = UITheme.text_width(f_eyebrow, btn_label, UITheme.FS_TINY) + 28.0
		_use_rect = Rect2(Vector2(pr.position.x + 32.0, pr.end.y - 44.0), Vector2(bw, 26.0))
		var b_bg := Color(0.24, 0.17, 0.08, 0.92) if _hover_use else Color(0.14, 0.10, 0.05, 0.84)
		var b_bd := UITheme.SAFFRON if _hover_use else UITheme.BRASS
		var b_sb := UITheme.flat_style(b_bg, 3, 1.0, b_bd, 0, 0)
		draw_style_box(b_sb, _use_rect)
		UITheme.draw_text(
			self,
			f_eyebrow,
			Vector2(_use_rect.position.x + 14.0, _use_rect.position.y + 18.0),
			btn_label,
			UITheme.FS_TINY,
			UITheme.SAFFRON_PALE if _hover_use else UITheme.PARCHMENT
		)
	else:
		_use_rect = Rect2()
	var hint := "ARROWS  SELECT      E  USE      I  CLOSE"
	var hw := UITheme.text_width(f_eyebrow, hint, UITheme.FS_TINY)
	UITheme.draw_text(self, f_eyebrow, Vector2(pr.end.x - 32 - hw, pr.end.y - 22), hint, UITheme.FS_TINY, UITheme.PARCHMENT_FAINT)
