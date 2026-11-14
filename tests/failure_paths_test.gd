extends Node
## Loading and failure paths, headless.
##   * A missing, truncated, garbled or wrong-shaped save never reaches the game state and
##     is answered with a plain-language message; a good save still round-trips.
##   * The world cache: a truncated file is rejected without reading it and the map is baked
##     again, with a loading-screen progress that only moves forward and ends at 1.
##   * An unsupported renderer lowers the quality tier and says so in plain words.
## Saves go to a scratch folder and the cache to a scratch file, never the player's own.

const SAVE_DIR := "user://test_failsafe_saves"
const CACHE := "user://test_failsafe_worldmap.cache"
## Words that must never reach a player.
const TECHNICAL := ["json", "parse", "exception", "error", "null", "dictionary", "res://", "user://", "vulkan", "gl_", "forward_plus"]

var fails: Array[String] = []


func _ready() -> void:
	_run()


func _run() -> void:
	var saved_dir := GameState.save_dir
	GameState.save_dir = SAVE_DIR
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_DIR))
	_check_saves()
	GameState.save_dir = saved_dir
	_clean_saves()
	_check_renderer()
	await _check_world_cache_and_progress()
	_clean_cache()
	print("\nRESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)


# --- saves ------------------------------------------------------------------
func _write(slot: int, text: String) -> void:
	var f := FileAccess.open(GameState.slot_path(slot), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _plain(label: String, msg: String) -> void:
	if msg == "":
		fails.append("%s: no message for the player" % label)
		return
	var low := msg.to_lower()
	for w in TECHNICAL:
		if low.contains(w):
			fails.append("%s: message shows technical text '%s': %s" % [label, w, msg])


## Load `text` as slot 0. It must be refused with `want`, and the game state untouched.
func _expect_refused(label: String, text: String, want: String) -> void:
	_write(0, text)
	GameState.health = 77.0
	GameState.arrows = 5
	GameState.player_position = Vector3(1, 2, 3)
	var ok := GameState.load_from_slot(0)
	if ok:
		fails.append("%s: a bad save was accepted" % label)
	if GameState.last_load_message != want:
		fails.append("%s: message was '%s', wanted '%s'" % [label, GameState.last_load_message, want])
	_plain(label, GameState.last_load_message)
	if GameState.health != 77.0 or GameState.arrows != 5 or GameState.player_position != Vector3(1, 2, 3):
		fails.append("%s: the game state changed although the load was refused" % label)
	var sum := GameState.slot_summary(0)
	if not bool(sum.get("damaged", false)):
		fails.append("%s: the slot list would not mark this save as damaged" % label)


func _check_saves() -> void:
	# Missing.
	GameState.health = 77.0
	if GameState.load_from_slot(2):
		fails.append("a missing slot loaded")
	if GameState.last_load_message != SaveCheck.MSG_EMPTY:
		fails.append("missing slot gave '%s'" % GameState.last_load_message)
	_plain("missing slot", GameState.last_load_message)
	if not GameState.slot_summary(2).is_empty():
		fails.append("a missing slot has a summary")

	# A good save, then every way to break it.
	GameState.health = 61.0
	GameState.arrows = 9
	GameState.player_position = Vector3(10, 20, 30)
	GameState.add_item("temple_bell", 1)
	GameState.quests["forest_path"] = {"state": "active", "objectives": {"talk": 1}}
	if not GameState.save_to_slot(1):
		fails.append("save_to_slot failed in the scratch folder")
	if FileAccess.file_exists(GameState.slot_path(1) + ".tmp"):
		fails.append("a finished save left its temporary file behind")
	var good := FileAccess.get_file_as_string(GameState.slot_path(1))
	GameState.reset()
	if not GameState.load_from_slot(1) or GameState.health != 61.0 or GameState.arrows != 9 or GameState.item_count("temple_bell") != 1:
		fails.append("a good save did not round-trip")
	if GameState.last_load_message != "":
		fails.append("a successful load left message '%s'" % GameState.last_load_message)
	if bool(GameState.slot_summary(1).get("damaged", false)):
		fails.append("a good save is shown as damaged")

	_expect_refused("truncated", good.substr(0, good.length() / 2), SaveCheck.MSG_DAMAGED)
	_expect_refused("empty file", "", SaveCheck.MSG_DAMAGED)
	_expect_refused("garbage", "\u0000\u0001 not a save {{{", SaveCheck.MSG_DAMAGED)
	_expect_refused("array at top level", "[1, 2, 3]", SaveCheck.MSG_DAMAGED)
	_expect_refused("no version", '{"health": 50}', SaveCheck.MSG_DAMAGED)
	_expect_refused("position not numbers", '{"version": 3, "pos": ["a", "b", "c"]}', SaveCheck.MSG_DAMAGED)
	_expect_refused("position too short", '{"version": 3, "pos": [1, 2]}', SaveCheck.MSG_DAMAGED)
	_expect_refused("health is text", '{"version": 3, "health": "lots"}', SaveCheck.MSG_DAMAGED)
	_expect_refused("quests is a list", '{"version": 3, "quests": [1]}', SaveCheck.MSG_DAMAGED)
	_expect_refused("quest entry is a number", '{"version": 3, "quests": {"a": 5}}', SaveCheck.MSG_DAMAGED)
	_expect_refused("inventory is text", '{"version": 3, "inventory": "none"}', SaveCheck.MSG_DAMAGED)
	_expect_refused("from a newer game", '{"version": 999}', SaveCheck.MSG_NEWER)
	_check_awkward_fields()


## Fields that parse as the right JSON type but would still break the game later:
## `dialogue.gd` assigns flags.dlg_seen to a typed Dictionary, a quest's state is compared
## as text, and impossible stats or counts are not a save this game wrote.
func _check_awkward_fields() -> void:
	var cases := {
		"dlg_seen is text": '{"version": 3, "flags": {"dlg_seen": "yes"}}',
		"dlg_seen is a list": '{"version": 3, "flags": {"dlg_seen": [1]}}',
		"quest state is a number": '{"version": 3, "quests": {"a": {"state": 7, "objectives": {}}}}',
		"objective is text": '{"version": 3, "quests": {"a": {"state": "active", "objectives": {"x": "done"}}}}',
		"objective is negative": '{"version": 3, "quests": {"a": {"state": "active", "objectives": {"x": -4}}}}',
		"inventory count is a list": '{"version": 3, "inventory": {"bell": [1]}}',
		"health is astronomical": '{"version": 3, "health": 1e300}',
		"health is negative": '{"version": 3, "health": -5}',
		"arrows is a billion": '{"version": 3, "arrows": 99999999999}',
		"day is negative": '{"version": 3, "day": -1}',
		"clock past 24": '{"version": 3, "time_of_day": 31}',
		"position is far outside the world": '{"version": 3, "pos": [1e12, 0, 0]}',
	}
	for label in cases:
		_expect_refused(label, String(cases[label]), SaveCheck.MSG_DAMAGED)
	# A byte-order mark at the start is not damage; a normal save with the right fields loads.
	_write(0, "\uFEFF" + '{"version": 3, "health": 50, "flags": {"dlg_seen": {"elder/a": true}}}')
	GameState.reset()
	if not GameState.load_from_slot(0) or GameState.health != 50.0:
		fails.append("a save that starts with a byte-order mark did not load")
	elif not GameState.flags.get("dlg_seen", {}).has("elder/a"):
		fails.append("the dialogue flags of a good save were not loaded")


# --- renderer ---------------------------------------------------------------
func _check_renderer() -> void:
	for m in ["forward_plus", "mobile", "dummy"]:
		var r := RendererCheck.assess(m)
		if not bool(r["supported"]) or String(r["message"]) != "" or int(r["max_tier"]) != Quality.Tier.ULTRA:
			fails.append("renderer '%s' should be accepted silently: %s" % [m, r])
	for m in ["gl_compatibility", "", "something_new"]:
		var r := RendererCheck.assess(m)
		if bool(r["supported"]) or int(r["max_tier"]) != Quality.Tier.LOW:
			fails.append("renderer '%s' should fall back to the Low tier: %s" % [m, r])
		_plain("renderer '%s'" % m, String(r["message"]))
	# The tier the game would pick: a High request on a weak card becomes Low.
	var cap := RendererCheck.assess("gl_compatibility")
	if mini(Quality.Tier.HIGH, int(cap["max_tier"])) != Quality.Tier.LOW:
		fails.append("a High request was not lowered on an unsupported renderer")


# --- world cache and loading screen ----------------------------------------
func _check_world_cache_and_progress() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE))
	var probe := WorldMap.new()
	if probe._try_load_cache(CACHE):
		fails.append("a missing world cache was accepted")

	# A cut-off file: right header, far too short.
	var f := FileAccess.open(CACHE, FileAccess.WRITE)
	f.store_32(WorldMap.CACHE_MAGIC)
	f.store_32(WorldMap.CACHE_VERSION)
	f.store_buffer(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
	f.close()
	if probe._try_load_cache(CACHE):
		fails.append("a truncated world cache was accepted")

	var ls := LoadingScreen.open(self)
	var raw: Array = []
	var seen: Array = []
	ls.stage(0.0, 0.5)
	WorldMap.progress = func(frac: float, text: String) -> void:
		raw.append(frac)
		ls.report(frac, text)
		seen.append(ls.progress)
	var m := WorldMap.load_or_bake(false, CACHE)
	WorldMap.progress = Callable()
	_check_baked_map(m, raw)
	_check_screen(ls, seen)

	# The rewritten cache must now load, and without baking.
	var again: Array = []
	WorldMap.progress = func(frac: float, text: String) -> void: again.append(text)
	var m2 := WorldMap.load_or_bake(false, CACHE)
	WorldMap.progress = Callable()
	if again.any(func(t: String) -> bool: return t.begins_with("Shaping")):
		fails.append("the rewritten cache was not used; the map was baked again")
	if m2.heights.size() != m.heights.size() or m2.heights[1000] != m.heights[1000]:
		fails.append("the cached map differs from the baked one")


func _check_baked_map(m: WorldMap, raw: Array) -> void:
	var n := WorldMap.GRID * WorldMap.GRID
	if m.heights.size() != n or m.biomes.size() != n:
		fails.append("the map baked after a bad cache has the wrong size")
	if raw.is_empty() or float(raw[0]) != 0.0 or float(raw[raw.size() - 1]) != 1.0:
		fails.append("bake progress did not run from 0 to 1: first %s last %s" % [raw.front() if raw else "-", raw.back() if raw else "-"])
	if raw.size() < 8:
		fails.append("bake reported progress only %d times; a bar needs steady updates" % raw.size())
	for i in range(1, raw.size()):
		if float(raw[i]) < float(raw[i - 1]):
			fails.append("bake progress went backwards: %.3f then %.3f" % [raw[i - 1], raw[i]])
			break
	if FileAccess.open(CACHE, FileAccess.READ).get_length() < n * 30:
		fails.append("the cache was not rewritten in full after the re-bake")


func _check_screen(ls: LoadingScreen, seen: Array) -> void:
	for i in range(1, seen.size()):
		if float(seen[i]) < float(seen[i - 1]):
			fails.append("the loading bar went backwards: %.3f then %.3f" % [seen[i - 1], seen[i]])
			break
	if ls.progress > 0.5 + 0.0001:
		fails.append("the bake stage filled past its slice of the bar: %.3f" % ls.progress)
	ls.stage(0.0, 1.0)
	ls.report(0.2, "Going backwards")
	if ls.progress < 0.5 - 0.0001:
		fails.append("the bar moved back when a later stage reported less")
	_plain("loading text", ls.message)
	ls.finish(0.0)
	if ls.progress != 1.0:
		fails.append("finish() left the bar at %.3f" % ls.progress)


func _clean_saves() -> void:
	for i in range(4):
		for suffix in ["", ".tmp"]:
			var p := ProjectSettings.globalize_path("%s/slot_%d.json%s" % [SAVE_DIR, i, suffix])
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_DIR))


func _clean_cache() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE))
