class_name NPCDirector
extends Node3D
## Populates Panchavati and keeps it running cheaply.
##
## Every villager is placed by querying the WorldMap: homes on a ring around the
## square, the potter and the weaver just off it, the farmer out at the field edge,
## the fisherman on the dry side of the bank, the guard on the road where it enters
## the village, and the hermit up on the shrine knoll. Nothing is hand-typed as a
## world coordinate that could end up in the river when the terrain generator changes;
## every spot is settled onto walkable ground first.
##
## Only NPCs within STREAM_IN of the player think or draw. Coming back into range does
## not resume yesterday's errand — they are snapped onto whatever the clock says they
## should be doing, which is both cheaper and more convincing than simulating an empty
## village.

const STREAM_IN := 120.0
const STREAM_OUT := 138.0
const STREAM_PERIOD := 0.25

var map: WorldMap
var sky: SkySystem
var dialogue: DialogueSystem
var npcs: Array[NPC] = []

## Seeded, not global `randf()`: the social spots are part of the village's layout and
## a village that stands somewhere different on every boot cannot be regression-tested.
var _rng := RandomNumberGenerator.new()
var _focus: Vector3 = Vector3(WorldMap.P_VILLAGE.x, 0.0, WorldMap.P_VILLAGE.y)
var _stream_t: float = 0.0
var _player: Node3D = null

# ===========================================================================
#  the people of Panchavati
# ===========================================================================
## Warm cotton in three dyes: saffron for the festival-minded, indigo for the ones who
## can afford Ratnavali's work, undyed white for everyone else.
## Skin tints multiply the shared skin_warm texture, so they stay close to neutral —
## anything saturated pushes the whole village orange.
const SKIN_A := Color(1.00, 0.97, 0.95)
const SKIN_B := Color(0.90, 0.86, 0.83)
const SKIN_C := Color(0.80, 0.75, 0.71)
const SKIN_D := Color(0.95, 0.92, 0.90)
const HAIR_BLACK := Color(0.062, 0.050, 0.046)
const HAIR_GREY := Color(0.44, 0.42, 0.40)
const HAIR_SILVER := Color(0.50, 0.485, 0.47)


func setup(m: WorldMap, s: SkySystem = null) -> void:
	_rng.seed = 0x50414e43  # "PANC"
	map = m
	sky = s if s != null else _find_sky()
	dialogue = DialogueSystem.instance(self)
	_populate()


func _find_sky() -> SkySystem:
	var n: Node = get_parent()
	while n != null:
		if n is WorldRoot and (n as WorldRoot).sky != null:
			return (n as WorldRoot).sky
		n = n.get_parent()
	for c in get_tree().get_nodes_in_group("sky"):
		if c is SkySystem:
			return c
	return null


func _populate() -> void:
	var c := WorldMap.P_VILLAGE
	var square := _settle(c, 10.0)
	var gate := _gate_spot(square)
	var road := _road_spot(square, gate)
	var bank := _bank_spot(square)
	var shrine := _settle(WorldMap.P_SHRINE + Vector2(3.0, 2.5), 22.0)

	var mother_home := _settle(square + _ring(118.0, 13.0), 8.0)
	# A fisherman lives within sight of his own bank; a home on the far side of the
	# village leaves him walking a slope he cannot climb every single night.
	var kevat_home := _settle(bank.lerp(square, 0.40), 12.0)
	var field := _settle(square.lerp(WorldMap.P_FIELDS, 0.45), 14.0)

	var roster: Array = [
		{
			"id": "suryadatta",
			"display_name": "Suryadatta",
			"role": NPC.Role.ELDER,
			"work_kind": NPC.Work.LEAN,
			"dialogue_id": "elder",
			"prop_kind": "staff",
			"home": _settle(square + _ring(205.0, 13.0), 8.0),
			"work": _settle(square + Vector2(2.6, -2.2), 6.0),
			"wander_radius": 3.2,
			"look":
			{
				"height": 1.71,
				"build": 0.90,
				"cloth": "cloth_white",
				"cloth2": "cloth_saffron",
				"beard": true,
				"topknot": true,
				"jewellery": false,
				"hair_color": HAIR_SILVER,
				"skin_tint": SKIN_D
			},
			"greetings": ["Peace, traveller.", "Stand in the shade."],
			"greetings_met": ["Still with us, archer?", "Mind the well rope."],
		},
		{
			"id": "ghatikara",
			"display_name": "Ghatikara",
			"role": NPC.Role.POTTER,
			"work_kind": NPC.Work.WHEEL,
			"dialogue_id": "potter",
			"prop_kind": "none",
			"home": _settle(square + _ring(250.0, 15.0), 8.0),
			"work": _settle(square + Vector2(-10.0, 8.0), 9.0),
			"wander_radius": 2.6,
			"look":
			{
				"height": 1.74,
				"build": 1.06,
				"cloth": "cloth_saffron",
				"cloth2": "cloth_white",
				"beard": true,
				"hair_color": HAIR_BLACK,
				"skin_tint": SKIN_C,
				"cloth_tint": Color(0.92, 0.84, 0.74)
			},
			"greetings": ["Mind the drying line!", "Careful — wet clay."],
			"greetings_met": ["Nine pots and counting.", "Not on the wheel, friend."],
		},
		{
			"id": "ratnavali",
			"display_name": "Ratnavali",
			"role": NPC.Role.WEAVER,
			"work_kind": NPC.Work.LOOM,
			"dialogue_id": "weaver",
			"prop_kind": "basket",
			"home": _settle(square + _ring(300.0, 14.0), 8.0),
			"work": _settle(square + Vector2(8.5, 10.0), 9.0),
			"wander_radius": 2.4,
			"look":
			{
				"height": 1.61,
				"build": 0.92,
				"cloth": "cloth_indigo",
				"cloth2": "cloth_saffron",
				"topknot": true,
				"jewellery": true,
				"hair_color": HAIR_BLACK,
				"skin_tint": SKIN_B
			},
			"greetings": ["Namaste.", "Cloth, if you need it."],
			"greetings_met": ["The indigo is dry now.", "Namaste, again."],
		},
		{
			"id": "halin",
			"display_name": "Halin",
			"role": NPC.Role.FARMER,
			"work_kind": NPC.Work.HOE,
			"dialogue_id": "farmer",
			"prop_kind": "sickle",
			"home": _settle(square + _ring(340.0, 16.0), 8.0),
			"work": field,
			"wander_radius": 6.5,
			"look":
			{
				"height": 1.78,
				"build": 1.10,
				"cloth": "cloth_white",
				"cloth2": "cloth_indigo",
				"beard": true,
				"hair_color": HAIR_BLACK,
				"skin_tint": SKIN_C
			},
			"greetings": ["Off the bund, friend.", "Good day to you."],
			"greetings_met": ["Still thin, since you ask.", "Mind the water channel."],
		},
		{
			"id": "gopa",
			"display_name": "Gopa",
			"role": NPC.Role.HERDER,
			"work_kind": NPC.Work.HERD,
			"dialogue_id": "herder",
			"prop_kind": "staff_yoke",
			"home": _settle(square + _ring(25.0, 17.0), 8.0),
			"work": _settle(square + Vector2(20.0, -13.0), 14.0),
			"wander_radius": 11.0,
			"look":
			{
				"height": 1.69,
				"build": 1.00,
				"cloth": "cloth_saffron",
				"cloth2": "cloth_indigo",
				"topknot": true,
				"hair_color": HAIR_BLACK,
				"skin_tint": SKIN_B
			},
			"greetings": ["Ho! Mind the brown one.", "Peace to you."],
			"greetings_met": ["Nineteen, still.", "She has not kicked you yet? Good."],
		},
		{
			"id": "kevat",
			"display_name": "Kevat",
			"role": NPC.Role.FISHERMAN,
			"work_kind": NPC.Work.CAST,
			"dialogue_id": "fisherman",
			"prop_kind": "net",
			"home": kevat_home,
			"work": bank,
			"wander_radius": 3.0,
			"look":
			{
				"height": 1.66,
				"build": 0.96,
				"cloth": "cloth_indigo",
				"cloth2": "cloth_white",
				"beard": true,
				"hair_color": HAIR_GREY,
				"skin_tint": SKIN_C
			},
			"greetings": ["Softly, softly.", "You will frighten them."],
			"greetings_met": ["Two this morning.", "The water is falling."],
		},
		{
			"id": "sulochana",
			"display_name": "Sulochana",
			"role": NPC.Role.MOTHER,
			"work_kind": NPC.Work.CARRY,
			"dialogue_id": "mother",
			"prop_kind": "pot_head",
			"home": mother_home,
			"work": _settle(mother_home + Vector2(2.4, 1.8), 6.0),
			"wander_radius": 4.0,
			"look":
			{
				"height": 1.62,
				"build": 0.95,
				"cloth": "cloth_saffron",
				"cloth2": "cloth_indigo",
				"topknot": true,
				"jewellery": true,
				"hair_color": HAIR_BLACK,
				"skin_tint": SKIN_A
			},
			"greetings": ["Namaste. There is rice.", "Have you eaten?"],
			"greetings_met": ["Eat something, you.", "Ila! — sorry. Namaste."],
		},
		{
			"id": "ila",
			"display_name": "Ila",
			"role": NPC.Role.CHILD,
			"work_kind": NPC.Work.PLAY,
			"dialogue_id": "child_ila",
			"prop_kind": "none",
			"home": _settle(mother_home + Vector2(1.4, 0.9), 6.0),
			"work": square,
			"wander_radius": 9.0,
			"look":
			{
				"height": 1.20,
				"build": 0.66,
				"cloth": "cloth_white",
				"cloth2": "cloth_saffron",
				"topknot": true,
				"sash": false,
				"hair_color": HAIR_BLACK,
				"skin_tint": SKIN_A
			},
			"greetings": ["Are you a soldier?", "Watch me run!"],
			"greetings_met": ["Watch! Watch!", "You are still here!"],
			"alarm_lines": ["Amma!", "Amma! Amma!"],
		},
		{
			"id": "puru",
			"display_name": "Puru",
			"role": NPC.Role.CHILD,
			"work_kind": NPC.Work.PLAY,
			"dialogue_id": "child_puru",
			"prop_kind": "none",
			"home": _settle(mother_home + Vector2(-1.1, 1.2), 6.0),
			"work": square,
			"wander_radius": 6.0,
			"look":
			{
				"height": 1.09,
				"build": 0.62,
				"cloth": "cloth_indigo",
				"cloth2": "cloth_white",
				"sash": false,
				"hair_color": HAIR_BLACK,
				"skin_tint": SKIN_B
			},
			"greetings": ["...hello.", "You are very tall."],
			"greetings_met": ["Hello again.", "...hello."],
			"alarm_lines": ["Amma!", "I told you! I told you!"],
		},
		{
			"id": "vikrama",
			"display_name": "Vikrama",
			"role": NPC.Role.GUARD,
			"work_kind": NPC.Work.WATCH,
			"dialogue_id": "guard",
			"prop_kind": "staff",
			"home": _settle(square + _ring(160.0, 16.0), 8.0),
			"work": gate,
			"wander_radius": 2.2,
			"nocturnal": true,
			"look":
			{
				"height": 1.84,
				"build": 1.16,
				"cloth": "cloth_indigo",
				"cloth2": "cloth_white",
				"beard": true,
				"jewellery": true,
				"hair_color": HAIR_BLACK,
				"skin_tint": SKIN_C
			},
			"greetings": ["Hold. ...Walk on.", "Road is clear today."],
			"greetings_met": ["Archer.", "Still quiet."],
			"alarm_lines": ["To arms! Get behind me!", "They are on the road!"],
		},
		{
			"id": "bhadra",
			"display_name": "Bhadra",
			"role": NPC.Role.TRAVELLER,
			"work_kind": NPC.Work.LEAN,
			"dialogue_id": "traveller",
			"prop_kind": "staff",
			"home": _settle(square + Vector2(3.2, 4.0), 8.0),
			"work": road,
			"night": _settle(square + Vector2(3.2, 4.0), 8.0),
			"wander_radius": 2.6,
			"nocturnal": true,
			"look":
			{
				"height": 1.75,
				"build": 1.05,
				"cloth": "cloth_indigo",
				"cloth2": "cloth_white",
				"beard": true,
				"hair_color": HAIR_GREY,
				"skin_tint": SKIN_B,
				"cloth_tint": Color(0.74, 0.72, 0.66)
			},
			"greetings": ["Ah — a face! Sit down.", "You have dust on you. Good."],
			"greetings_met": ["My feet still have opinions.", "Back already?"],
		},
		{
			"id": "vamadeva",
			"display_name": "Rishi Vamadeva",
			"role": NPC.Role.HERMIT,
			"work_kind": NPC.Work.BLESS,
			"dialogue_id": "hermit",
			"prop_kind": "kamandalu",
			"home": _settle(WorldMap.P_SHRINE + Vector2(-4.0, 3.0), 22.0),
			"work": shrine,
			"wander_radius": 3.4,
			"nocturnal": true,
			"look":
			{
				"height": 1.70,
				"build": 0.82,
				"cloth": "cloth_white",
				"cloth2": "cloth_white",
				"beard": true,
				"topknot": true,
				"jewellery": false,
				"hair_color": HAIR_SILVER,
				"skin_tint": SKIN_D
			},
			"greetings": ["Mind the last step.", "Come up, come up."],
			"greetings_met": ["The steps are still loose.", "Sit, archer."],
			"alarm_lines": ["Down the steps, quickly!"],
		},
		{
			"id": "sita",
			"display_name": "Sita (Janaki)",
			"role": NPC.Role.ELDER,
			"work_kind": NPC.Work.BLESS,
			"dialogue_id": "sita",
			"prop_kind": "none",
			"home": _settle(WorldMap.P_VILLAGE + Vector2(-8.0, 4.0), 14.0),
			"work": _settle(WorldMap.P_VILLAGE + Vector2(-8.0, 4.0), 14.0),
			"wander_radius": 2.8,
			"look":
			{
				"height": 1.65,
				"build": 0.90,
				"garment": "sari",
				"cloth": "cloth_saffron",
				"cloth2": "cloth_saffron",
				"jewellery": true,
				"hair_color": HAIR_BLACK,
				"skin_tint": SKIN_A,
				"cloth_tint": Color(1.0, 0.92, 0.72)
			},
			"greetings": ["Peace be upon this Parnashala.", "Walk with Dharma, my Lord."],
			"greetings_met": ["The Tulsi is fresh with dew.", "Did you see the golden deer in the glade?"],
		},
		{
			"id": "lakshmana",
			"display_name": "Lakshmana (Saumitri)",
			"role": NPC.Role.GUARD,
			"work_kind": NPC.Work.WATCH,
			"dialogue_id": "lakshmana",
			"prop_kind": "bow",
			"home": _settle(WorldMap.P_VILLAGE + Vector2(-6.0, 6.0), 14.0),
			"work": _settle(WorldMap.P_VILLAGE + Vector2(-6.0, 6.0), 14.0),
			"night": _settle(WorldMap.P_VILLAGE + Vector2(-6.0, 6.0), 14.0),
			"wander_radius": 2.6,
			"nocturnal": true,
			"look":
			{
				"height": 1.78,
				"build": 1.06,
				"cloth": "cloth_saffron",
				"cloth2": "cloth_saffron",
				"channavira": true,
				"topknot": true,
				"jewellery": true,
				"hair_color": HAIR_BLACK,
				"skin_tint": Color(1.04, 0.92, 0.74),
				"cloth_tint": Color(0.98, 0.86, 0.62)
			},
			"greetings": ["The Parnashala perimeter is clear, brother.", "My bow is strung and ready."],
			"greetings_met": ["Not a leaf stirs unseen, Raghava.", "Command me, elder brother."],
		},
		{
			"id": "vishvamitra",
			"display_name": "Sage Vishvamitra",
			"role": NPC.Role.HERMIT,
			"work_kind": NPC.Work.BLESS,
			"dialogue_id": "vishvamitra",
			"prop_kind": "staff",
			"home": _settle(Vector2(-136.0, 32.0), 16.0),
			"work": _settle(Vector2(-136.0, 32.0), 16.0),
			"wander_radius": 3.0,
			"nocturnal": true,
			"look":
			{
				"height": 1.76,
				"build": 0.92,
				"cloth": "cloth_white",
				"cloth2": "cloth_saffron",
				"beard": true,
				"topknot": true,
				"jewellery": false,
				"hair_color": HAIR_SILVER,
				"skin_tint": SKIN_B
			},
			"greetings": ["Come forward, scion of Raghu.", "Siddhashrama's fire awaits."],
			"greetings_met": ["Remember the Bala and Atibala mantras.", "Pinaka awaits your hand."],
		},
		{
			"id": "bharata",
			"display_name": "Prince Bharata",
			"role": NPC.Role.ELDER,
			"work_kind": NPC.Work.BLESS,
			"dialogue_id": "bharata",
			"prop_kind": "none",
			"home": _settle(WorldMap.P_SHRINE + Vector2(-2.0, 2.0), 18.0),
			"work": _settle(WorldMap.P_SHRINE + Vector2(-2.0, 2.0), 18.0),
			"wander_radius": 2.8,
			"nocturnal": true,
			"look":
			{
				"height": 1.76,
				"build": 1.0,
				"cloth": "cloth_indigo",
				"cloth2": "cloth_saffron",
				"topknot": true,
				"jewellery": true,
				"hair_color": HAIR_BLACK,
				"skin_tint": SKIN_B
			},
			"greetings": ["Arya! Kosala awaits your return.", "Let your Paduka rule Ayodhya."],
			"greetings_met": ["I keep watch for your sandals at Chitrakoot.", "Dharma alone is king."],
		},
		{
			"id": "hanuman",
			"display_name": "Hanuman (Anjaneya)",
			"role": NPC.Role.GUARD,
			"work_kind": NPC.Work.WATCH,
			"dialogue_id": "hanuman",
			"prop_kind": "gada",
			"home": _settle(Vector2(-276.0, 88.0), 18.0),
			"work": _settle(Vector2(-276.0, 88.0), 18.0),
			"wander_radius": 3.2,
			"nocturnal": true,
			"look":
			{
				"height": 1.84,
				"build": 1.18,
				"vanara": true,
				"cloth": "cloth_saffron",
				"cloth2": "cloth_saffron",
				"topknot": true,
				"jewellery": true,
				"hair_color": Color(0.58, 0.34, 0.14),
				"skin_tint": Color(0.92, 0.68, 0.36)
			},
			"greetings": ["Jai Sri Ram!", "The son of Vayu bows at your feet."],
			"greetings_met": ["Point the way, my Lord, and I shall leap the sea.", "The Seven Sala Trees await your arrow!"],
		},
		{
			"id": "agastya",
			"display_name": "Maharshi Agastya",
			"role": NPC.Role.HERMIT,
			"work_kind": NPC.Work.BLESS,
			"dialogue_id": "agastya",
			"prop_kind": "staff",
			"home": _settle(WorldMap.P_LOOKOUT + Vector2(-2.0, 4.0), 18.0),
			"work": _settle(WorldMap.P_LOOKOUT + Vector2(-2.0, 4.0), 18.0),
			"wander_radius": 3.0,
			"nocturnal": true,
			"look":
			{
				"height": 1.68,
				"build": 0.94,
				"cloth": "cloth_saffron",
				"cloth2": "cloth_white",
				"beard": true,
				"topknot": true,
				"jewellery": false,
				"hair_color": HAIR_SILVER,
				"skin_tint": SKIN_C
			},
			"greetings": ["Welcome to the high Lookout, Raghava.", "Hear the hymn of Surya."],
			"greetings_met": ["Recite the Aditya Hridayam thrice in your heart.", "The Akshaya Tunira is inexhaustible."],
		},
	]

	for r in roster:
		_spawn(r, square)


func _spawn(r: Dictionary, square: Vector2) -> void:
	var home2: Vector2 = r["home"]
	var work2: Vector2 = r["work"]
	var is_local: bool = work2.distance_to(square) < 40.0 and r["id"] != "vamadeva"
	var social2: Vector2 = square if is_local else work2
	var refuge2: Vector2 = square if is_local else work2
	# Where the ones who do not sleep spend the dark hours.
	var night2: Vector2 = r.get("night", work2)

	var n := NPC.new()
	var cfg := {
		"id": r["id"],
		"display_name": r["display_name"],
		"role": r["role"],
		"work_kind": r["work_kind"],
		"dialogue_id": r["dialogue_id"],
		"prop_kind": r["prop_kind"],
		"home_pos": _ground(home2),
		"work_pos": _ground(work2),
		"social_pos": _ground(_settle(social2 + _ring(_rng.randf() * 360.0, 3.0), 6.0)),
		"night_pos": _ground(night2),
		"refuge_pos": _ground(refuge2),
		"wander_radius": float(r.get("wander_radius", 3.5)),
		"nocturnal": bool(r.get("nocturnal", false)),
		"greetings": r.get("greetings", []),
		"greetings_met": r.get("greetings_met", r.get("greetings", [])),
		"look": r["look"],
	}
	if r.has("alarm_lines"):
		cfg["alarm_lines"] = r["alarm_lines"]
	else:
		cfg["alarm_lines"] = ["Rakshasas!", "To the square! Run!", "Get inside!"]
	n.configure(cfg)
	add_child(n)
	# Start them at their work station: whatever hour you load into, the village is
	# already doing something.
	n.global_position = _ground(work2) + Vector3(0, 0.15, 0)
	n.build()
	n.set_world(map, sky)
	npcs.append(n)


# ===========================================================================
#  placement helpers — everything is settled onto ground the map approves of
# ===========================================================================
static func _ring(deg: float, r: float) -> Vector2:
	var a := deg_to_rad(deg)
	return Vector2(cos(a), sin(a)) * r


func _ground(p: Vector2) -> Vector3:
	return Vector3(p.x, map.height_at(p.x, p.y), p.y)


func _ok(p: Vector2, river_min: float = 5.0) -> bool:
	if not map.in_bounds(p.x, p.y):
		return false
	if map.water_depth_at(p.x, p.y) > 0.05:
		return false
	if map.slope_at(p.x, p.y) > 0.32:
		return false
	if map.river_dist(p) < river_min:
		return false
	return true


## Spiral outward until the ground is flat, dry and off the river.
func _settle(p: Vector2, max_r: float, river_min: float = 5.0) -> Vector2:
	if _ok(p, river_min):
		return p
	var r: float = 1.0
	while r <= max_r:
		for i in range(12):
			var a: float = TAU * float(i) / 12.0 + r * 0.7
			var q := p + Vector2(cos(a), sin(a)) * r
			if _ok(q, river_min):
				return q
		r += 1.2
	return p


## Where the road comes into the village — the guard's post.
func _gate_spot(square: Vector2) -> Vector2:
	var best := square + Vector2(0.0, 20.0)
	var score := 1.0e9
	for poly in map.paths():
		for p in poly:
			var d: float = p.distance_to(square)
			if d < 14.0 or d > 34.0:
				continue
			var s: float = absf(d - 22.0)
			if s < score and _ok(p):
				score = s
				best = p
	return _settle(best, 14.0)


## Further out along the road than the gate, and not on top of the guard.
func _road_spot(square: Vector2, gate: Vector2) -> Vector2:
	var best := square + Vector2(0.0, 32.0)
	var score := 1.0e9
	for poly in map.paths():
		for p in poly:
			var d: float = p.distance_to(square)
			if d < 26.0 or d > 48.0:
				continue
			if p.distance_to(gate) < 11.0:
				continue
			var s: float = absf(d - 34.0)
			if s < score and _ok(p):
				score = s
				best = p
	return _settle(best, 16.0)


## The dry side of the bank, close enough to cast from.
func _bank_spot(square: Vector2) -> Vector2:
	var pts := map.river_points()
	var near := square
	var nd := 1.0e9
	for p in pts:
		var d: float = p.distance_to(square)
		if d < nd:
			nd = d
			near = p
	var dir := square - near
	if dir.length() < 0.01:
		dir = Vector2(1.0, 0.0)
	dir = dir.normalized()
	for i in range(1, 40):
		var q := near + dir * (float(i) * 0.7)
		if map.water_depth_at(q.x, q.y) <= 0.02 and map.slope_at(q.x, q.y) < 0.34 and map.in_bounds(q.x, q.y):
			return q + dir * 1.6
	return _settle(square + Vector2(12.0, 0.0), 24.0)


# ===========================================================================
#  streaming
# ===========================================================================
func update_focus(pos: Vector3) -> void:
	_focus = pos


func _process(delta: float) -> void:
	if map == null:
		return
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D
	if _player != null:
		_focus = _player.global_position
	_stream_t -= delta
	if _stream_t > 0.0:
		return
	_stream_t = STREAM_PERIOD
	for n in npcs:
		if not is_instance_valid(n):
			continue
		var d: float = Vector2(n.global_position.x - _focus.x, n.global_position.z - _focus.z).length()
		if n.is_active():
			if d > STREAM_OUT:
				n.set_active(false)
		elif d < STREAM_IN:
			n.set_active(true)


# ===========================================================================
#  queries
# ===========================================================================
func get_npc(id: String) -> NPC:
	for n in npcs:
		if is_instance_valid(n) and n.id == id:
			return n
	return null


func active_count() -> int:
	var c := 0
	for n in npcs:
		if is_instance_valid(n) and n.is_active():
			c += 1
	return c


func stats() -> Dictionary:
	return {
		"npcs": npcs.size(),
		"active": active_count(),
		"time": sky.time_of_day if sky else -1.0,
	}
