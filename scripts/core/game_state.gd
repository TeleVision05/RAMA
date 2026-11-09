extends Node
## Authoritative, serialisable game state. Everything the save file needs lives here
## and nowhere else, so saving is a matter of writing this out.

const MAX_HEALTH := 100.0
const MAX_STAMINA := 100.0
const MAX_PRANA := 100.0
const SAVE_DIR := "user://saves"
const SAVE_VERSION := 3

const ASTRA_NAMES := ["Shara", "Agneyastra", "Varunastra", "Vayavyastra", "Brahmastra"]
const ASTRA_SUBTITLES := [
	"Sacred Shaft of Akshaya Tunira",
	"Fire of Agni — Explosive Burn",
	"Torrent of Varuna — Healing Mist & Slow",
	"Gale of Vayu — Piercing Wind",
	"Supreme Solar Weapon of Brahma",
]
const ASTRA_MANTRAS := [
	"Om Ramaya Namah",
	"Om Agnaye Swaha",
	"Om Varunaya Namah",
	"Om Vayave Namah",
	"Om Aditya Hridayam Punyam",
]
const ASTRA_COSTS := [0.0, 18.0, 18.0, 20.0, 40.0]

var health: float = MAX_HEALTH
var stamina: float = MAX_STAMINA
var prana: float = MAX_PRANA
var max_health: float = MAX_HEALTH
var max_stamina: float = MAX_STAMINA
var max_prana: float = MAX_PRANA
var active_astra: int = 0
var unlocked_astras: Array = [0, 1, 2, 3, 4]
var arrows: int = 24
var max_arrows: int = 40

var player_position: Vector3 = Vector3.ZERO
var player_yaw: float = 0.0
var time_of_day: float = 7.4
var day: int = 1

var inventory: Dictionary = {}  # id -> count
var quests: Dictionary = {}  # id -> {state, objectives:{id: progress}}
var discovered: Dictionary = {}  # location id -> true
var flags: Dictionary = {}  # arbitrary world state
var kills: int = 0
var play_seconds: float = 0.0

var in_combat: bool = false
var _combat_timer: float = 0.0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_DIR))
	EventBus.enemy_alerted.connect(func(_e): mark_combat())
	EventBus.enemy_damaged.connect(func(_e, _a, _c, _p): mark_combat())
	EventBus.player_damaged.connect(func(_a, _s): mark_combat())


func _process(delta: float) -> void:
	play_seconds += delta
	if _combat_timer > 0.0:
		_combat_timer -= delta
		if _combat_timer <= 0.0 and in_combat:
			in_combat = false
			EventBus.combat_state_changed.emit(false)


func mark_combat(duration: float = 7.0) -> void:
	_combat_timer = maxf(_combat_timer, duration)
	if not in_combat:
		in_combat = true
		EventBus.combat_state_changed.emit(true)


# --- items ----------------------------------------------------------------
func add_item(id: String, count: int = 1) -> void:
	inventory[id] = int(inventory.get(id, 0)) + count
	EventBus.item_gained.emit(id, count)


func remove_item(id: String, count: int = 1) -> bool:
	var have: int = int(inventory.get(id, 0))
	if have < count:
		return false
	if have == count:
		inventory.erase(id)
	else:
		inventory[id] = have - count
	EventBus.item_lost.emit(id, count)
	return true


func item_count(id: String) -> int:
	return int(inventory.get(id, 0))


func has_item(id: String, count: int = 1) -> bool:
	return item_count(id) >= count


func use_item(id: String) -> bool:
	if not has_item(id):
		return false
	match id:
		"healing_salve":
			health = minf(max_health, health + 45.0)
			prana = minf(max_prana, prana + 15.0)
			remove_item(id, 1)
			AudioDirector.play_2d("heal", -4.0)
			EventBus.player_healed.emit(45.0)
			EventBus.notify.emit("Healing Salve used", "Restored 45 Health and 15 Prana.", "info")
		"healing_herb", "herb":
			health = minf(max_health, health + 28.0)
			remove_item(id, 1)
			AudioDirector.play_2d("heal", -4.0)
			EventBus.player_healed.emit(28.0)
			EventBus.notify.emit("Healing Herb used", "Restored 28 Health.", "info")
		"mango", "rice", "honey", "ghee", "water_skin":
			health = minf(max_health, health + 18.0)
			stamina = minf(max_stamina, stamina + 40.0)
			prana = minf(max_prana, prana + 15.0)
			remove_item(id, 1)
			AudioDirector.play_2d("heal", -4.0)
			EventBus.player_healed.emit(18.0)
			EventBus.notify.emit("Sacred Provision used", "Restored vitality and stamina.", "info")
		"shabari_berries", "soma_tulsi", "lotus", "blue_lotus":
			health = minf(max_health, health + 40.0)
			prana = minf(max_prana, prana + 60.0)
			stamina = minf(max_stamina, stamina + 40.0)
			remove_item(id, 1)
			AudioDirector.play_2d("heal", -3.0)
			EventBus.player_healed.emit(40.0)
			EventBus.notify.emit("Sacred Offering consumed", "Shabari's devotion fills you with Prana.", "quest")
		"arrow_bundle", "arrows":
			arrows = mini(max_arrows, arrows + 12)
			remove_item(id, 1)
			AudioDirector.play_2d("arrow_pickup", -4.0)
			EventBus.notify.emit("Arrows replenished", "+12 Arrows added to your quiver.", "info")
		"amulet", "chudamani", "grove_seed", "rama_paduka":
			if bool(get_flag("blessed_" + id, false)):
				return false
			set_flag("blessed_" + id, true)
			max_health += 15.0
			max_prana += 15.0
			health = max_health
			prana = max_prana
			AudioDirector.play_2d("objective_complete", -3.0)
			EventBus.player_healed.emit(15.0)
			EventBus.notify.emit("Sacred Relic Attuned", "Permanent +15 Max Health & +15 Max Prana!", "quest")
		_:
			return false
	EventBus.player_stat_changed.emit(health, max_health, stamina, max_stamina)
	return true


# --- discovery ------------------------------------------------------------
func discover(id: String, display_name: String) -> bool:
	if discovered.has(id):
		return false
	discovered[id] = true
	EventBus.location_discovered.emit(id, display_name)
	return true


func set_flag(key: String, value: Variant) -> void:
	flags[key] = value


func get_flag(key: String, default_v: Variant = false) -> Variant:
	return flags.get(key, default_v)


# --- save / load ----------------------------------------------------------
func slot_path(slot: int) -> String:
	return "%s/slot_%d.json" % [SAVE_DIR, slot]


func to_dict() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"health": health,
		"stamina": stamina,
		"prana": prana,
		"max_health": max_health,
		"max_stamina": max_stamina,
		"max_prana": max_prana,
		"active_astra": active_astra,
		"arrows": arrows,
		"pos": [player_position.x, player_position.y, player_position.z],
		"yaw": player_yaw,
		"time_of_day": time_of_day,
		"day": day,
		"inventory": inventory,
		"quests": quests,
		"discovered": discovered,
		"flags": flags,
		"kills": kills,
		"play_seconds": play_seconds,
	}


func from_dict(d: Dictionary) -> bool:
	if int(d.get("version", 0)) < 1:
		return false
	health = float(d.get("health", MAX_HEALTH))
	stamina = float(d.get("stamina", MAX_STAMINA))
	prana = float(d.get("prana", MAX_PRANA))
	max_health = float(d.get("max_health", MAX_HEALTH))
	max_stamina = float(d.get("max_stamina", MAX_STAMINA))
	max_prana = float(d.get("max_prana", MAX_PRANA))
	active_astra = int(d.get("active_astra", 0))
	arrows = int(d.get("arrows", 24))
	var p: Array = d.get("pos", [0, 0, 0])
	player_position = Vector3(p[0], p[1], p[2])
	player_yaw = float(d.get("yaw", 0.0))
	time_of_day = float(d.get("time_of_day", 7.4))
	day = int(d.get("day", 1))
	inventory = d.get("inventory", {})
	quests = d.get("quests", {})
	discovered = d.get("discovered", {})
	flags = d.get("flags", {})
	kills = int(d.get("kills", 0))
	play_seconds = float(d.get("play_seconds", 0.0))
	return true


func save_to_slot(slot: int) -> bool:
	var f := FileAccess.open(slot_path(slot), FileAccess.WRITE)
	if f == null:
		push_error("[save] cannot write slot %d" % slot)
		return false
	f.store_string(JSON.stringify(to_dict(), "  "))
	f.close()
	EventBus.game_saved.emit(slot)
	return true


func load_from_slot(slot: int) -> bool:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[save] slot %d is corrupt" % slot)
		return false
	if not from_dict(parsed):
		return false
	EventBus.game_loaded.emit(slot)
	return true


func slot_summary(slot: int) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = parsed
	var done := 0
	for q in d.get("quests", {}).values():
		if typeof(q) == TYPE_DICTIONARY and q.get("state", "") == "complete":
			done += 1
	return {
		"day": int(d.get("day", 1)),
		"time": float(d.get("time_of_day", 7.4)),
		"quests_done": done,
		"discovered": d.get("discovered", {}).size(),
		"play_seconds": float(d.get("play_seconds", 0.0)),
		"modified": FileAccess.get_modified_time(path),
	}


func has_slot(slot: int) -> bool:
	return FileAccess.file_exists(slot_path(slot))


func reset() -> void:
	health = MAX_HEALTH
	stamina = MAX_STAMINA
	prana = MAX_PRANA
	max_health = MAX_HEALTH
	max_stamina = MAX_STAMINA
	max_prana = MAX_PRANA
	active_astra = 0
	arrows = 24
	inventory = {}
	quests = {}
	discovered = {}
	flags = {}
	kills = 0
	play_seconds = 0.0
	time_of_day = 7.4
	day = 1
	in_combat = false
	_combat_timer = 0.0
