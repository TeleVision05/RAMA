class_name QuestData
extends RefCounted
## The quests, the discoverable places and the quest items, as authored data.
##
## Quest ids and objective ids match the hooks already written into
## `dialogue_data.gd` (`quest_start:q_lost_goat`, `quest_advance:q_shrine:lamp:1`,
## `quest_complete:q_lost_goat`), so a conversation and the quest log cannot drift
## apart. Where a conversation offers to close a quest that is genuinely unfinished,
## the quest carries `strict` and the system refuses — see `Quest.strict`.
##
## Objective kinds (`Quest.Kind`):
##   talk_to   a conversation with `target` (an npc id) ends
##   go_to     the player comes within `radius` of `where`
##   kill      an enemy dies inside `radius` of `where`, or one of this step's own
##             spawned group dies anywhere
##   collect   `target` items arrive in the inventory
##   interact  a world object calls `QuestSystem.notify_interact(target)`
##   discover  `target` place is entered for the first time
##   escort    the escortee `target` reaches `where` with the player
##   return    the player comes back to the npc `target` (carrying `carry`, if set)

const QUESTS := {
	# =======================================================================
	"q_lost_goat":
	{
		"title": "The Path Through the Forest",
		"summary": "Gopa has lost two goats up the west track, and it was not a tiger.",
		"objectives":
		[
			{
				"id": "speak",
				"kind": "talk_to",
				"target": "gopa",
				"description": "Hear out Gopa the herder",
				"where": Vector2(-120.0, 44.0),
				"radius": 24.0
			},
			{
				"id": "travel",
				"kind": "go_to",
				"after": ["speak"],
				"description": "Follow the west track into the forest",
				"where": Vector2(-184.0, -14.0),
				"radius": 17.0
			},
			{
				"id": "investigate",
				"kind": "interact",
				"target": "forest_evidence",
				"count": 2,
				"after": ["travel"],
				"description": "Search the cart and the tree beside it",
				"where": Vector2(-183.6, -15.8),
				"radius": 17.0
			},
			{
				"id": "defeat",
				"kind": "kill",
				"count": 4,
				"after": ["investigate"],
				"description": "Drive off what has been living in the wood",
				"where": Vector2(-189.0, -23.0),
				"radius": 60.0,
				"spawn": {"kind": 0, "at": Vector2(-189.0, -23.0), "count": 4}
			},
			{
				"id": "bell",
				"kind": "collect",
				"target": "goat_bell",
				"after": ["travel"],
				"description": "Find Bindu's brass bell in the wreckage",
				"where": Vector2(-184.6, -14.8),
				"radius": 17.0
			},
			{
				"id": "bindu",
				"kind": "escort",
				"target": "bindu",
				"optional": true,
				"after": ["defeat"],
				"description": "Cut Bindu loose and walk her home",
				"where": Vector2(-120.0, 44.0),
				"radius": 26.0,
				"reward": {"items": {"healing_salve": 1}, "arrows": 6, "note": "Bindu walks straight to the water trough and drinks."}
			},
			{
				"id": "report",
				"kind": "return",
				"target": "gopa",
				"carry": "goat_bell",
				"after": ["defeat", "bell"],
				"description": "Carry the bell back to Gopa in Panchavati",
				"where": Vector2(-120.0, 44.0),
				"radius": 24.0
			},
		],
		"rewards":
		{
			"items": {"arrow_bundle": 2, "healing_salve": 1},
			"arrows": 12,
			"flag": {"forest_answered": true},
			"welcome": "The village will not forget the west track.",
			"notify": "Gopa presses a bundle of arrows into your hands, and will not " + "hear a word against it.",
		},
	},
	# =======================================================================
	"q_shrine":
	{
		"title": "The Forgotten Shrine",
		"summary": "Untended for a generation: the lamps are cold and the bell is gone.",
		"strict": true,
		"opens_on_discovery": ["shrine"],
		"objectives":
		[
			{
				"id": "find",
				"kind": "discover",
				"target": "shrine",
				"description": "Climb the knoll to the shrine",
				"where": Vector2(158.0, -66.0),
				"radius": 26.0
			},
			{
				"id": "inscription",
				"kind": "interact",
				"target": "shrine_inscription",
				"after": ["find"],
				"description": "Read the inscription on the forecourt",
				"where": Vector2(165.0, -78.5),
				"radius": 12.0
			},
			{
				"id": "bell",
				"kind": "collect",
				"target": "temple_bell",
				"after": ["inscription"],
				"description": "Find the bell in the ruins to the west",
				"where": Vector2(-155.0, -145.5),
				"radius": 26.0
			},
			{
				"id": "lamps",
				"kind": "interact",
				"target": "shrine_lamp",
				"count": 3,
				"after": ["inscription"],
				"description": "Light the three lamps in their own order",
				"where": Vector2(166.6, -78.5),
				"radius": 12.0
			},
			{
				"id": "lamp",
				"kind": "interact",
				"target": "threshold_lamp",
				"optional": true,
				"after": ["find"],
				"description": "Light the lamp on the shrine threshold",
				"where": Vector2(163.2, -78.5),
				"radius": 12.0,
				"reward": {"note": "A small orange light, visible from the ford."}
			},
			{
				"id": "restore",
				"kind": "interact",
				"target": "shrine_bell_mount",
				"after": ["bell", "lamps"],
				"description": "Hang the bell in its frame and ring it",
				"where": Vector2(164.6, -74.4),
				"radius": 12.0
			},
		],
		"rewards":
		{
			"max_health": 20.0,
			"heal": 999.0,
			"flag": {"blessing_of_the_bell": true},
			"notify": "The bell answers, and goes on answering after it is quiet. " + "Something in you settles.",
		},
	},
	# =======================================================================
	"q_wild":
	{
		"title": "Into the Wild",
		"summary": "A grove nobody can find, and three places to read the valley from.",
		"prerequisites": {"discovered": ["shrine"]},
		"opens_on_discovery": ["waterfall", "lookout", "badlands"],
		"opens_on_talk": ["vamadeva"],
		"objectives":
		[
			{
				"id": "falls",
				"kind": "discover",
				"target": "waterfall",
				"description": "Stand under the falls in the north",
				"where": Vector2(38.0, -186.0),
				"radius": 30.0
			},
			{
				"id": "lookout",
				"kind": "discover",
				"target": "lookout",
				"description": "Climb the lookout above the valley",
				"where": Vector2(96.0, -150.0),
				"radius": 30.0
			},
			{
				"id": "badlands",
				"kind": "discover",
				"target": "badlands",
				"description": "Cross the eroded country in the south-east",
				"where": Vector2(214.0, 178.0),
				"radius": 36.0
			},
			{
				"id": "grove",
				"kind": "discover",
				"target": "hidden_grove",
				"hidden_until": ["falls", "lookout", "badlands"],
				"description": "The grove lies far to the west",
				"where": Vector2(-322.0, 118.0),
				"radius": 34.0
			},
		],
		"rewards":
		{
			"items": {"grove_seed": 1},
			"max_stamina": 30.0,
			"flag": {"found_the_grove": true},
			"notify": "You will not forget the way back. Nobody who has stood here does.",
		},
	},
}

## Places the player can discover, with the name shown when they do.
const PLACES := {
	"village": {"at": WorldMap.P_VILLAGE, "r": 46.0, "name": "Panchavati"},
	"shrine": {"at": WorldMap.P_SHRINE, "r": 26.0, "name": "The Forgotten Shrine"},
	"ruins": {"at": WorldMap.P_RUINS, "r": 34.0, "name": "The Old Ruins"},
	"waterfall": {"at": WorldMap.P_WATERFALL, "r": 34.0, "name": "The Falls"},
	"ford": {"at": WorldMap.P_FORD, "r": 20.0, "name": "The Ford"},
	"forest_camp": {"at": WorldMap.P_FOREST_CAMP, "r": 26.0, "name": "The Rakshasa Camp"},
	"hidden_grove": {"at": WorldMap.P_HIDDEN_GROVE, "r": 34.0, "name": "The Hidden Grove"},
	"badlands": {"at": WorldMap.P_BADLANDS, "r": 40.0, "name": "The Eroded Country"},
	"fields": {"at": WorldMap.P_FIELDS, "r": 30.0, "name": "The Paddy Fields"},
	"lookout": {"at": WorldMap.P_LOOKOUT, "r": 30.0, "name": "The Lookout"},
}

## Quest items, for the notification that fires when one is picked up.
const ITEMS := {
	"temple_bell": {"name": "Bronze Bell", "desc": "Cold, heavy, and older than the village that forgot it."},
	"goat_bell": {"name": "Bindu's Bell", "desc": "Brass, with a split lip. It still rings, badly."},
	"arrow_bundle": {"name": "Bundle of Arrows", "desc": "Cane shafts, iron heads, orange fletching."},
	"grove_seed": {"name": "Seed of the Grove", "desc": "It has not dried in a hundred years."},
	"healing_salve": {"name": "Healing Salve", "desc": "Turmeric and neem, ground fine and kept in a leaf."},
	"lamp_oil": {"name": "Til Oil", "desc": "A traveller's flask, kept for a road that had no light on it."},
	"amulet": {"name": "Amulet", "desc": "Kaustubha glass on a knotted cord. Warm to hold."},
}

## The order the shrine inscription names the lamps in. The lamps carry these
## emblems carved on their bases, so the puzzle is read off the world.
const LAMP_ORDER: Array = ["sun", "river", "fig"]

const LAMP_EMBLEM_NAMES := {
	"sun": "the rising sun",
	"river": "the river",
	"fig": "the fig leaf",
}

static var _built: Dictionary = {}
static var _dot: ImageTexture = null


## A soft round dot with a radial alpha falloff, built once and shared.
##
## A particle quad with no texture draws as a hard-edged SQUARE however carefully its
## colour ramp fades — which is what the hidden grove's motes and the objective
## marker's motes were on 2026-08-28: a scatter of white boxes hanging in the trees.
## The alpha ramp was working the whole time; there was simply nothing round to fade.
static func soft_dot() -> ImageTexture:
	if _dot != null:
		return _dot
	var n := 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var mid := float(n - 1) * 0.5
	for y in range(n):
		for x in range(n):
			var d: float = Vector2(float(x) - mid, float(y) - mid).length() / mid
			var a: float = pow(clampf(1.0 - d, 0.0, 1.0), 1.9)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	_dot = ImageTexture.create_from_image(img)
	return _dot


## Every quest, built once, as `Quest` objects.
static func all() -> Dictionary:
	if _built.is_empty():
		for qid in QUESTS:
			_built[qid] = Quest.from_dict(String(qid), QUESTS[qid])
	return _built


static func quest(qid: String) -> Quest:
	var q: Variant = all().get(qid, null)
	return q as Quest


static func has(qid: String) -> bool:
	return all().has(qid)


static func quest_ids() -> Array:
	return all().keys()


static func objective_list(qid: String) -> Array:
	var q := quest(qid)
	return q.objectives if q != null else []


static func objective_def(qid: String, oid: String) -> Quest.Objective:
	var q := quest(qid)
	return q.objective(oid) if q != null else null


static func item_name(item_id: String) -> String:
	var d: Dictionary = ITEMS.get(item_id, {})
	if d.has("name"):
		return String(d["name"])
	return item_id.capitalize()


static func place_name(place_id: String) -> String:
	var d: Dictionary = PLACES.get(place_id, {})
	if d.has("name"):
		return String(d["name"])
	return place_id.capitalize()
