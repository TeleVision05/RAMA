class_name JournalPanel
extends Control
## Rama's journal: what he has been asked to do, and where he has been.
##
## Everything is read from GameState. Titles and objective wording come from a
## QuestSystem if one exists — found at runtime by capability, never by a hard
## reference — so the journal is useful on its own and gets better when the quest
## content lands.

const TAB_QUESTS := 0
const TAB_PLACES := 1
const TAB_KANDAS := 2

## Fallback flavour for the ten named places in the world, used until a content
## system registers something better.
const PLACE_BLURB := {
	"village": "Panchavati Ashram & Hamlet. Built beside the five sacred banyans above the Godavari flood line.",
	"panchavati": "Panchavati Ashram & Hamlet. Built beside the five sacred banyans above the Godavari flood line.",
	"shrine": "Surya-Shiva Mandapa on the eastern rise. Its bronze ghanta echoes across the Dandaka valley.",
	"temple": "Surya-Shiva Mandapa on the eastern rise. Its bronze ghanta echoes across the Dandaka valley.",
	"ruins": "Ancient Ikshvaku & Rishi pillar ruins, older than the settlement and carved with forgotten hymns.",
	"waterfall": "Godavari Cataract. The sacred river plunges forty paces into mist where sages perform sandhya.",
	"falls": "Godavari Cataract. The sacred river plunges forty paces into mist where sages perform sandhya.",
	"ford": "Tamasa & Godavari Gravel Ford. Shallow crossing where exiles and pilgrims wade the currents.",
	"forest_camp": "Rakshasa Vanguard Camp. Ash, a broken fire-ring, and tracks of Khara's scouts in the red earth.",
	"camp": "Rakshasa Vanguard Camp. Ash, a broken fire-ring, and tracks of Khara's scouts in the red earth.",
	"hidden_grove": "Agastya & Shabari's Tapovana Grove. Still lotus water under ancient trees where birds fall silent.",
	"grove": "Agastya & Shabari's Tapovana Grove. Still lotus water under ancient trees where birds fall silent.",
	"badlands": "Janasthana Ravines & Lanka Causeway. Scorched red rock where the Rakshasa war-host gathers.",
	"fields": "Ashram Terraced Paddy. Fed by bamboo sluices from the Godavari, green against the forest edge.",
	"lookout": "Rishyamuka & Jatayu's Crag. A high stone shoulder with the entire Dandaka valley laid out below.",
}

const KANDA_CHRONICLE := [
	{
		"quest_id": "q_bala_kanda",
		"short": "I. Bala Kanda",
		"title": "I. Bala Kanda — Youth & The Bow of Shiva",
		"epigraph": "\"Tapah-svadhyaya-niratam tapasvi vag-vidam varam...\"  (Valmiki Ramayana 1.1.1)",
		"astra": "Shara & Agneyastra — Guided by Sage Vishvamitra against Tataka and Subahu.",
		"lore":
		"Born of the Solar Dynasty (Suryavamsha) in Ayodhya, young Sri Rama accompanied Brahmarshi Vishvamitra "
		+ "to guard the sacred yajna at Siddhashrama, slew the demoness Tataka, and lifted Lord Shiva's celestial "
		+ "bow Pinaka in Mithila to win the hand of Janaki (Sita).",
	},
	{
		"quest_id": "q_ayodhya_kanda",
		"short": "II. Ayodhya Kanda",
		"title": "II. Ayodhya Kanda — The Exile & Golden Paduka",
		"epigraph": "\"Ramo dvir nabhibhashate — Rama speaks not with a forked tongue.\"  (Ayodhya Kanda 2.18.30)",
		"astra": "Varunastra — Steadfast composure and Dharmic resolve upon the Chitrakuta hills.",
		"lore":
		"To honour King Dasharatha's word to Kaikeyi without hesitation, Rama relinquished the throne of Kosala "
		+ "for fourteen years of forest exile alongside Sita and Lakshmana. At Chitrakuta, Bharata received Rama's "
		+ "golden Paduka sandals to rule Ayodhya in his name.",
	},
	{
		"quest_id": "q_aranya_kanda",
		"short": "III. Aranya Kanda",
		"title": "III. Aranya Kanda — Panchavati & The Golden Deer",
		"epigraph": "\"Katham nu bhagavan ramah... dharmanuga-gatih sada.\"  (Aranya Kanda 3.16)",
		"astra": "Agneyastra — Bestowed through the grace of Sage Agastya in Dandakaranya.",
		"lore":
		"Dwelling among the five sacred banyans of Panchavati beside the Godavari, Rama protected the Rishis of "
		+ "Dandakaranya from Khara and Dushana's host, pursued Maricha in the guise of the illusory Golden Deer, "
		+ "and blessed the dying vulture-king Jatayu after Ravana's abduction of Sita.",
	},
	{
		"quest_id": "q_kishkindha_kanda",
		"short": "IV. Kishkindha & Sundara",
		"title": "IV. Kishkindha & Sundara Kanda — Hanuman & The Seven Trees",
		"epigraph": "\"Jayaty atibalo ramo lakshmanash cha mahabalah...\"  (Sundara Kanda 5.42.33)",
		"astra": "Vayavyastra — The Gale of Vayu, piercing the Seven Sala Trees in a single shaft.",
		"lore":
		"Tasting the devoted ascetic Shabari's berries at Matanga Ashram, Rama forged an eternal alliance with "
		+ "Sugriva and Hanuman at Rishyamuka, proved his might by piercing seven sala trees with one arrow, and "
		+ "received Sita's Chudamani crest-jewel after Hanuman's leap across the ocean.",
	},
	{
		"quest_id": "q_yuddha_kanda",
		"short": "V. Yuddha Kanda",
		"title": "V. Yuddha Kanda — Rama Setu & The Fall of Ravana",
		"epigraph": "\"Adityahridayam punyam sarva-shatru-vinashanam...\"  (Yuddha Kanda 6.105.4)",
		"astra": "Brahmastra — The Solar Disk of Brahma, invoked after chanting the Aditya Hridaya.",
		"lore":
		"Crossing the stone causeway of Nala's Setu with the Vanara host, Lakshmana vanquished Indrajit and "
		+ "Rama—blessed with the Aditya Hridaya hymn by Sage Agastya—released the blazing Brahmastra to pierce "
		+ "Dasagriva Ravana's heart, restoring Sita and cosmic Dharma.",
	},
]

var tab: int = TAB_QUESTS
var _sel_quest: int = 0
var _sel_kanda: int = 0
var _quests: Array = []  # [{id, title, summary, state, objectives:[...]}]
var _places: Array = []  # [{id, name, blurb}]
var _qsys: Node = null
## Whether the expensive scene-tree walk in `_find_quest_system` is worth repeating.
var _qsys_rescan: bool = true
var _panel: StyleBoxTexture
var _tab_rects: Array = []
var _row_rects: Array = []
var _hover_tab: int = -1

## What the HUD has seen come past on the event bus. Objective totals and location
## display names are not in GameState, so without this the journal can only show a
## prettified id and a tick with no denominator.
var _obj_hint: Dictionary = {}  # "quest/objective" -> {progress, total}
var _place_names: Dictionary = {}  # location id -> display name


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Offsets must be reset too: setting anchors alone on a node that is already
	# in the tree preserves the current (zero) rect and the panel never grows.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme()
	_panel = UITheme.panel_style(Color(0.066, 0.052, 0.043, 0.95), 26)
	refresh()


# --- quest system discovery ------------------------------------------------
## Find the quest system by capability rather than by class, so the journal works
## before it exists and keeps working if it is renamed.
func _find_quest_system() -> Node:
	if is_instance_valid(_qsys):
		return _qsys
	var tree := get_tree()
	if tree == null:
		return null
	# Cheap path: a system that puts itself in the group costs a dictionary lookup.
	for n in tree.get_nodes_in_group("quest_system"):
		_qsys = n
		return _qsys
	# Expensive path: walking four levels of the scene tree, which in this game means
	# the terrain chunks, every scattered prop and every settlement node. `refresh()`
	# runs on every item picked up and every location found, so the walk happens once
	# and then only when something tells us a quest system may have appeared.
	if not _qsys_rescan:
		return null
	_qsys_rescan = false
	_qsys = _search(tree.root, 0)
	return _qsys


## Look again on the next refresh. The HUD calls this when a quest signal arrives:
## something is plainly driving quests now, even if it was not there at boot.
func rescan_quest_system() -> void:
	_qsys_rescan = true


func _search(n: Node, depth: int) -> Node:
	if depth > 4:
		return null
	for c in n.get_children():
		var s: Script = c.get_script()
		if s != null and s is GDScript:
			var gname := String((s as GDScript).get_global_name())
			if gname == "QuestSystem":
				return c
		if c.has_method("quest_title") and c.has_method("objective_text"):
			return c
		var r := _search(c, depth + 1)
		if r != null:
			return r
	return null


func _ask(method: String, args: Array, fallback: Variant) -> Variant:
	var q := _find_quest_system()
	if q == null or not q.has_method(method):
		return fallback
	var v: Variant = q.callv(method, args)
	if v == null:
		return fallback
	if v is String and String(v) == "":
		return fallback
	return v


# --- data ------------------------------------------------------------------
func refresh() -> void:
	_quests.clear()
	_places.clear()

	for id in GameState.quests.keys():
		var raw: Variant = GameState.quests[id]
		var d: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {}
		var state := String(d.get("state", "active"))
		var title := String(_ask("quest_title", [id], UITheme.prettify(String(id))))
		var summary := String(_ask("quest_summary", [id], ""))
		var objs: Array = []
		var obj_src: Variant = d.get("objectives", {})
		if typeof(obj_src) == TYPE_DICTIONARY:
			for oid in (obj_src as Dictionary).keys():
				var prog: Variant = (obj_src as Dictionary)[oid]
				var have := 0
				var need := 1
				var done := false
				if typeof(prog) == TYPE_DICTIONARY:
					have = int((prog as Dictionary).get("progress", 0))
					need = maxi(1, int((prog as Dictionary).get("total", 1)))
					done = bool((prog as Dictionary).get("done", have >= need))
				elif typeof(prog) == TYPE_BOOL:
					done = bool(prog)
					have = 1 if done else 0
				else:
					have = int(prog)
					var hint: Dictionary = _obj_hint.get("%s/%s" % [id, oid], {})
					if hint.has("total"):
						need = int(hint["total"])
					else:
						need = maxi(1, int(_ask("objective_total", [id, oid], 1)))
					done = have >= need
				(
					objs
					. append(
						{
							"id": String(oid),
							"text": String(_ask("objective_text", [id, oid], UITheme.prettify(String(oid)))),
							"have": have,
							"need": need,
							"done": done,
						}
					)
				)
		(
			_quests
			. append(
				{
					"id": String(id),
					"title": title,
					"summary": summary,
					"state": state,
					"objectives": objs,
				}
			)
		)

	# Active first, then completed; alphabetical inside each group.
	_quests.sort_custom(
		func(a, b):
			var ra: int = 0 if String(a.state) != "complete" else 1
			var rb: int = 0 if String(b.state) != "complete" else 1
			if ra != rb:
				return ra < rb
			return String(a.title) < String(b.title)
	)

	var ids: Array = GameState.discovered.keys()
	ids.sort()
	for id in ids:
		var key := String(id).to_lower()
		(
			_places
			. append(
				{
					"id": String(id),
					"name": String(_place_names.get(id, _ask("location_name", [id], UITheme.prettify(String(id))))),
					"blurb": String(PLACE_BLURB.get(key, "A place you have walked to and come back from.")),
				}
			)
		)

	_sel_quest = clampi(_sel_quest, 0, maxi(_quests.size() - 1, 0))
	queue_redraw()


## Called by the HUD when `quest_objective_changed` fires.
func note_objective(quest_id: String, objective_id: String, progress: int, total: int) -> void:
	_obj_hint["%s/%s" % [quest_id, objective_id]] = {"progress": progress, "total": maxi(total, 1)}


## Called by the HUD when `location_discovered` fires.
func note_location(id: String, display_name: String) -> void:
	if display_name != "":
		_place_names[id] = display_name


func quest_count() -> int:
	return _quests.size()


func place_count() -> int:
	return _places.size()


func set_tab(t: int) -> void:
	if t == tab:
		return
	tab = clampi(t, TAB_QUESTS, TAB_KANDAS)
	AudioDirector.play_ui("ui_click")
	queue_redraw()


# --- layout ----------------------------------------------------------------
func _panel_rect() -> Rect2:
	var w: float = minf(size.x - 260.0, 940.0)
	var h: float = minf(size.y - 240.0, 500.0)
	return Rect2(Vector2((size.x - w) * 0.5, (size.y - h) * 0.5), Vector2(w, h))


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var mp: Vector2 = (e as InputEventMouseMotion).position
		var was := _hover_tab
		_hover_tab = -1
		for i in range(_tab_rects.size()):
			if (_tab_rects[i] as Rect2).has_point(mp):
				_hover_tab = i
		if _hover_tab != was and _hover_tab >= 0:
			AudioDirector.play_ui("ui_hover")
		queue_redraw()
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if not (mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT):
			return
		for i in range(_tab_rects.size()):
			if (_tab_rects[i] as Rect2).has_point(mb.position):
				set_tab(i)
				accept_event()
				return
		if tab == TAB_QUESTS:
			for i in range(_row_rects.size()):
				if (_row_rects[i] as Rect2).has_point(mb.position):
					_select_quest(i)
					accept_event()
					return
		elif tab == TAB_KANDAS:
			for i in range(_row_rects.size()):
				if (_row_rects[i] as Rect2).has_point(mb.position):
					_select_kanda(i)
					accept_event()
					return
	if e is InputEventKey and (e as InputEventKey).pressed:
		var k := (e as InputEventKey).keycode
		if k == KEY_DOWN:
			if tab == TAB_KANDAS:
				_select_kanda(_sel_kanda + 1)
			else:
				_select_quest(_sel_quest + 1)
			accept_event()
		elif k == KEY_UP:
			if tab == TAB_KANDAS:
				_select_kanda(_sel_kanda - 1)
			else:
				_select_quest(_sel_quest - 1)
			accept_event()
		elif k == KEY_TAB:
			set_tab((tab + 1) % 3)
			accept_event()


func _select_quest(i: int) -> void:
	if _quests.is_empty():
		return
	var n := clampi(i, 0, _quests.size() - 1)
	if n != _sel_quest:
		_sel_quest = n
		AudioDirector.play_ui("ui_click")
	queue_redraw()


func _select_kanda(i: int) -> void:
	var n := clampi(i, 0, KANDA_CHRONICLE.size() - 1)
	if n != _sel_kanda:
		_sel_kanda = n
		AudioDirector.play_ui("ui_click")
	queue_redraw()


func _kanda_state(quest_id: String) -> String:
	if GameState.quests.has(quest_id):
		var raw: Variant = GameState.quests[quest_id]
		if typeof(raw) == TYPE_DICTIONARY:
			var st := String((raw as Dictionary).get("state", "active"))
			if st == "complete":
				return "Completed"
			return "In Progress"
	return "Awaiting"


# --- drawing ---------------------------------------------------------------
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.020, 0.016, 0.012, 0.66), true)
	var pr := _panel_rect()
	draw_style_box(_panel, pr)

	var f_eyebrow := UITheme.eyebrow_font()
	var f_head := UITheme.label_font()
	var f_body := UITheme.body_font()

	UITheme.draw_text(self, f_eyebrow, pr.position + Vector2(32, 44), "TALA-PATRA CHRONICLE", UITheme.FS_TINY, UITheme.BRASS)

	# --- tabs -------------------------------------------------------------
	_tab_rects.clear()
	var kandas_done := 0
	for k in KANDA_CHRONICLE:
		if _kanda_state(String(k["quest_id"])) == "Completed":
			kandas_done += 1
	var labels := [
		"DHARMA & QUESTS  %d" % _quests.size(),
		"SACRED PLACES  %d" % _places.size(),
		"THE FIVE KANDAS  %d/5" % kandas_done,
	]
	var tx: float = pr.position.x + 236.0
	for i in range(labels.size()):
		var label: String = labels[i]
		var tw := UITheme.text_width(f_eyebrow, label, UITheme.FS_TINY)
		var r := Rect2(Vector2(tx - 10.0, pr.position.y + 26.0), Vector2(tw + 20.0, 28.0))
		_tab_rects.append(r)
		var on: bool = tab == i
		var col: Color = UITheme.PARCHMENT if on else UITheme.PARCHMENT_FAINT
		if not on and _hover_tab == i:
			col = UITheme.PARCHMENT_DIM
		UITheme.draw_text(self, f_eyebrow, Vector2(tx, pr.position.y + 44.0), label, UITheme.FS_TINY, col)
		if on:
			draw_line(Vector2(tx, pr.position.y + 52.0), Vector2(tx + tw, pr.position.y + 52.0), UITheme.SAFFRON, 2.0, true)
		tx += tw + 34.0

	UITheme.carved_rule(self, pr.position + Vector2(32, 62), pr.size.x - 64)

	if tab == TAB_QUESTS:
		_draw_quests(pr, f_eyebrow, f_head, f_body)
	elif tab == TAB_PLACES:
		_draw_places(pr, f_eyebrow, f_head, f_body)
	else:
		_draw_kandas(pr, f_eyebrow, f_head, f_body)

	var hint := "TAB  SWITCH      UP/DOWN  SELECT      J  CLOSE"
	var hw := UITheme.text_width(f_eyebrow, hint, UITheme.FS_TINY)
	UITheme.draw_text(self, f_eyebrow, Vector2(pr.end.x - 32 - hw, pr.end.y - 22), hint, UITheme.FS_TINY, UITheme.PARCHMENT_FAINT)


func _draw_quests(pr: Rect2, f_eyebrow: Font, f_head: Font, f_body: Font) -> void:
	_row_rects.clear()
	var list_w: float = 300.0
	var top: float = pr.position.y + 88.0
	if _quests.is_empty():
		UITheme.draw_text(
			self,
			f_body,
			Vector2(pr.position.x + 32, top + 24.0),
			"Nothing asked of you yet. Walk, and someone will.",
			UITheme.FS_BODY,
			UITheme.PARCHMENT_FAINT
		)
		return

	# divider between list and detail
	draw_line(
		Vector2(pr.position.x + list_w + 44.0, top - 12.0),
		Vector2(pr.position.x + list_w + 44.0, pr.end.y - 46.0),
		Color(UITheme.BRASS_DIM.r, UITheme.BRASS_DIM.g, UITheme.BRASS_DIM.b, 0.45),
		1.0,
		true
	)

	# --- list -------------------------------------------------------------
	var y: float = top
	for i in range(_quests.size()):
		var q: Dictionary = _quests[i]
		var r := Rect2(Vector2(pr.position.x + 26.0, y - 4.0), Vector2(list_w, 40.0))
		_row_rects.append(r)
		var done: bool = String(q.state) == "complete"
		if i == _sel_quest:
			var sb := UITheme.flat_style(Color(0.180, 0.125, 0.058, 0.70), 3, 0.0, UITheme.BRASS, 0, 0)
			draw_style_box(sb, r)
			draw_rect(Rect2(r.position, Vector2(2.5, r.size.y)), UITheme.SAFFRON, true)
		var col: Color = UITheme.PARCHMENT if not done else UITheme.PARCHMENT_FAINT
		UITheme.draw_text(
			self,
			f_body,
			Vector2(r.position.x + 14.0, y + 22.0),
			String(q.title),
			UITheme.FS_BODY,
			col,
			HORIZONTAL_ALIGNMENT_LEFT,
			list_w - 74.0
		)
		var tag: String = "DONE" if done else "ACTIVE"
		var tc: Color = UITheme.JADE if done else UITheme.SAFFRON
		var tw := UITheme.text_width(f_eyebrow, tag, UITheme.FS_TINY)
		UITheme.draw_text(self, f_eyebrow, Vector2(r.end.x - 12.0 - tw, y + 21.0), tag, UITheme.FS_TINY, Color(tc.r, tc.g, tc.b, 0.85))
		y += 44.0

	# --- detail -----------------------------------------------------------
	var dx: float = pr.position.x + list_w + 72.0
	var dw: float = pr.end.x - 32.0 - dx
	var q2: Dictionary = _quests[_sel_quest]
	var dy: float = top + 20.0
	UITheme.draw_text(self, f_head, Vector2(dx, dy), String(q2.title), UITheme.FS_HEAD, UITheme.PARCHMENT, HORIZONTAL_ALIGNMENT_LEFT, dw)
	dy += 26.0
	if String(q2.summary) != "":
		UITheme.draw_text(
			self, f_body, Vector2(dx, dy), String(q2.summary), UITheme.FS_SMALL, UITheme.PARCHMENT_DIM, HORIZONTAL_ALIGNMENT_LEFT, dw
		)
		dy += 30.0
	dy += 10.0
	UITheme.draw_text(self, f_eyebrow, Vector2(dx, dy), "OBJECTIVES", UITheme.FS_TINY, UITheme.BRASS)
	dy += 22.0

	var objs: Array = q2.objectives
	if objs.is_empty():
		UITheme.draw_text(self, f_body, Vector2(dx, dy + 14.0), "—", UITheme.FS_SMALL, UITheme.PARCHMENT_FAINT)
		return
	for o in objs:
		var done: bool = bool(o.done)
		var cy: float = dy + 6.0
		# a small carved tick box
		if done:
			draw_colored_polygon(
				PackedVector2Array([Vector2(dx, cy - 1), Vector2(dx + 4, cy + 4), Vector2(dx + 11, cy - 6), Vector2(dx + 4, cy + 7)]),
				UITheme.JADE
			)
		else:
			draw_arc(Vector2(dx + 5, cy), 4.2, 0.0, TAU, 18, Color(UITheme.BRASS.r, UITheme.BRASS.g, UITheme.BRASS.b, 0.75), 1.2, true)
		var col: Color = UITheme.PARCHMENT_FAINT if done else UITheme.PARCHMENT
		UITheme.draw_text(
			self, f_body, Vector2(dx + 22.0, dy + 12.0), String(o.text), UITheme.FS_SMALL, col, HORIZONTAL_ALIGNMENT_LEFT, dw - 96.0
		)
		if int(o.need) > 1:
			var frac := "%d / %d" % [int(o.have), int(o.need)]
			var fw := UITheme.text_width(f_eyebrow, frac, UITheme.FS_TINY)
			UITheme.draw_text(self, f_eyebrow, Vector2(dx + dw - fw, dy + 12.0), frac, UITheme.FS_TINY, UITheme.BRASS)
			UITheme.draw_bar(
				self,
				Rect2(Vector2(dx + 22.0, dy + 25.0), Vector2(dw - 120.0, 3.0)),
				float(o.have) / float(o.need),
				UITheme.SAFFRON,
				Color(1, 1, 1, 0.10),
				0.85
			)
			dy += 16.0
		dy += 28.0


func _draw_places(pr: Rect2, _f_eyebrow: Font, f_head: Font, f_body: Font) -> void:
	var top: float = pr.position.y + 88.0
	if _places.is_empty():
		UITheme.draw_text(
			self,
			f_body,
			Vector2(pr.position.x + 32, top + 24.0),
			"You have not been anywhere worth writing down.",
			UITheme.FS_BODY,
			UITheme.PARCHMENT_FAINT
		)
		return
	var col_w: float = (pr.size.x - 64.0) * 0.5
	var y: float = top
	var col: int = 0
	var x: float = pr.position.x + 32.0
	# Balance the two columns, but let the left one overflow into the right if the
	# panel is short: the split is advisory, the bottom of the panel is not.
	var per_col: int = maxi(1, int((pr.end.y - 70.0 - top) / 56.0))
	var half: int = mini(int(ceil(float(_places.size()) / 2.0)), per_col)
	for i in range(_places.size()):
		# Next column when this one is full — by the balanced split or by the panel
		# running out of height. Breaking out here (as this did) discarded every
		# place in the right-hand column the moment the left one filled up.
		if col == 0 and (i >= half or y > pr.end.y - 70.0):
			col = 1
			x = pr.position.x + 32.0 + col_w
			y = top
		elif col == 1 and y > pr.end.y - 70.0:
			break
		var p: Dictionary = _places[i]
		draw_colored_polygon(
			PackedVector2Array([Vector2(x + 4, y + 4), Vector2(x + 8, y + 8), Vector2(x + 4, y + 12), Vector2(x, y + 8)]), UITheme.BRASS
		)
		UITheme.draw_text(
			self,
			f_head,
			Vector2(x + 18.0, y + 14.0),
			String(p.name),
			UITheme.FS_BODY,
			UITheme.PARCHMENT,
			HORIZONTAL_ALIGNMENT_LEFT,
			col_w - 40.0
		)
		UITheme.draw_text(
			self,
			f_body,
			Vector2(x + 18.0, y + 34.0),
			String(p.blurb),
			UITheme.FS_TINY,
			UITheme.PARCHMENT_FAINT,
			HORIZONTAL_ALIGNMENT_LEFT,
			col_w - 40.0
		)
		y += 56.0


func _draw_kandas(pr: Rect2, f_eyebrow: Font, f_head: Font, f_body: Font) -> void:
	_row_rects.clear()
	var list_w: float = 310.0
	var top: float = pr.position.y + 88.0

	draw_line(
		Vector2(pr.position.x + list_w + 44.0, top - 12.0),
		Vector2(pr.position.x + list_w + 44.0, pr.end.y - 46.0),
		Color(UITheme.BRASS_DIM.r, UITheme.BRASS_DIM.g, UITheme.BRASS_DIM.b, 0.45),
		1.0,
		true
	)

	var y: float = top
	for i in range(KANDA_CHRONICLE.size()):
		var k: Dictionary = KANDA_CHRONICLE[i]
		var r := Rect2(Vector2(pr.position.x + 26.0, y - 4.0), Vector2(list_w, 46.0))
		_row_rects.append(r)
		var st := _kanda_state(String(k["quest_id"]))
		if i == _sel_kanda:
			var sb := UITheme.flat_style(Color(0.180, 0.125, 0.058, 0.76), 3, 0.0, UITheme.BRASS, 0, 0)
			draw_style_box(sb, r)
			draw_rect(Rect2(r.position, Vector2(2.5, r.size.y)), UITheme.SAFFRON, true)
		var col: Color = UITheme.PARCHMENT if st != "Awaiting" else UITheme.PARCHMENT_DIM
		UITheme.draw_text(
			self,
			f_body,
			Vector2(r.position.x + 14.0, y + 25.0),
			String(k["short"]),
			UITheme.FS_BODY,
			col,
			HORIZONTAL_ALIGNMENT_LEFT,
			list_w - 104.0
		)
		var tc: Color = UITheme.PARCHMENT_FAINT
		if st == "Completed":
			tc = UITheme.JADE
		elif st == "In Progress":
			tc = UITheme.SAFFRON
		var tag := st.to_upper()
		var tw := UITheme.text_width(f_eyebrow, tag, UITheme.FS_TINY)
		UITheme.draw_text(self, f_eyebrow, Vector2(r.end.x - 12.0 - tw, y + 24.0), tag, UITheme.FS_TINY, tc)
		y += 52.0

	var dx: float = pr.position.x + list_w + 72.0
	var dw: float = pr.end.x - 32.0 - dx
	var kd: Dictionary = KANDA_CHRONICLE[clampi(_sel_kanda, 0, KANDA_CHRONICLE.size() - 1)]
	var k_st := _kanda_state(String(kd["quest_id"]))
	var dy: float = top + 16.0

	UITheme.draw_text(self, f_eyebrow, Vector2(dx, dy), "VALMIKI RAMAYANA  ·  " + k_st.to_upper(), UITheme.FS_TINY, UITheme.BRASS)
	dy += 28.0
	UITheme.draw_text(self, f_head, Vector2(dx, dy), String(kd["title"]), UITheme.FS_LABEL, UITheme.PARCHMENT, HORIZONTAL_ALIGNMENT_LEFT, dw)
	dy += 26.0
	UITheme.draw_text(
		self, f_body, Vector2(dx, dy), String(kd["epigraph"]), UITheme.FS_SMALL, UITheme.SAFFRON_PALE, HORIZONTAL_ALIGNMENT_LEFT, dw
	)
	dy += 26.0
	UITheme.carved_rule(self, Vector2(dx, dy), dw, UITheme.BRASS_DIM, 0.55)
	dy += 24.0
	dy = _draw_paragraph(f_body, Vector2(dx, dy), String(kd["lore"]), UITheme.FS_SMALL, UITheme.PARCHMENT_DIM, dw, 21.0)
	dy += 18.0
	UITheme.draw_text(self, f_eyebrow, Vector2(dx, dy), "DIVYA ASTRA ATTUNEMENT", UITheme.FS_TINY, UITheme.BRASS)
	dy += 22.0
	UITheme.draw_text(self, f_body, Vector2(dx, dy), String(kd["astra"]), UITheme.FS_SMALL, UITheme.PARCHMENT, HORIZONTAL_ALIGNMENT_LEFT, dw)


func _draw_paragraph(f: Font, pos: Vector2, text: String, fsize: int, col: Color, max_w: float, line_h: float) -> float:
	var cur := ""
	var y: float = pos.y
	for word in text.split(" ", false):
		var trial: String = word if cur == "" else cur + " " + word
		if cur == "" or UITheme.text_width(f, trial, fsize) <= max_w:
			cur = trial
		else:
			UITheme.draw_text(self, f, Vector2(pos.x, y), cur, fsize, col)
			y += line_h
			cur = word
	if cur != "":
		UITheme.draw_text(self, f, Vector2(pos.x, y), cur, fsize, col)
		y += line_h
	return y
