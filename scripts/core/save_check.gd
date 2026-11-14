class_name SaveCheck
extends RefCounted
## Decides whether a save file is safe to load, and says why not in words a player can
## act on. A truncated or hand-edited file must never reach `GameState.from_dict`, which
## indexes into it and would stop the game with a script error.
##
## Every message answers two questions: what happened, and what to do next. Technical
## detail (the parse error, the field name) goes to the log, never into the message.

const MSG_EMPTY := "This slot is empty. Pick another slot or start a new game."
const MSG_DAMAGED := "This save is damaged and can't be loaded. Pick another slot or start a new game."
const MSG_NEWER := "This save was made by a newer version of RAMA. Update the game to open it, or pick another slot."
const MSG_UNREADABLE := "This save couldn't be opened. Check that the game can read its save folder, then try again."

const NUMERIC_FIELDS := [
	"health",
	"stamina",
	"prana",
	"max_health",
	"max_stamina",
	"max_prana",
	"active_astra",
	"arrows",
	"yaw",
	"time_of_day",
	"day",
	"kills",
	"play_seconds",
]
const DICT_FIELDS := ["inventory", "quests", "discovered", "flags"]
## Largest values a real game can reach, with room to spare. A hand-edited or damaged
## file that holds more (1e300 health, a billion arrows) is refused rather than loaded.
const STAT_LIMIT := 10000.0
const COUNT_LIMIT := 1000000.0
const ASTRA_LIMIT := 99
const CLOCK_LIMIT := 24.0
const COORD_LIMIT := 100000.0
const SECONDS_LIMIT := 1.0e9
const STATS := ["health", "stamina", "prana", "max_health", "max_stamina", "max_prana"]
const COUNTS := ["arrows", "kills", "day"]


## Parse the text of a save file. Returns {"ok": bool, "data": Dictionary, "message": String}.
static func parse_text(text: String, source: String = "save") -> Dictionary:
	var json := JSON.new()
	# Some editors put a byte-order mark at the start of a file; it is not part of the JSON.
	if text.begins_with("\uFEFF"):
		text = text.substr(1)
	if json.parse(text) != OK:
		return _fail(MSG_DAMAGED, "%s: not valid JSON (%s at line %d)" % [source, json.get_error_message(), json.get_error_line()])
	if typeof(json.data) != TYPE_DICTIONARY:
		return _fail(MSG_DAMAGED, "%s: top level is not an object" % source)
	var d: Dictionary = json.data
	var reason := problem_with(d)
	if reason == "newer":
		return _fail(MSG_NEWER, "%s: version %s is newer than %d" % [source, str(d.get("version")), GameState.SAVE_VERSION])
	if reason != "":
		return _fail(MSG_DAMAGED, "%s: %s" % [source, reason])
	return {"ok": true, "data": d, "message": ""}


## "" when the dictionary can be loaded, "newer" for a future version, else a developer
## description of the first thing wrong (for the log only).
static func problem_with(d: Dictionary) -> String:
	if not _is_number(d.get("version", null)):
		return "no version"
	var v := int(d["version"])
	if v < 1:
		return "version %d" % v
	if v > GameState.SAVE_VERSION:
		return "newer"
	for k in NUMERIC_FIELDS:
		if d.has(k) and not _is_number(d[k]):
			return "field %s is not a number" % k
	for k in DICT_FIELDS:
		if d.has(k) and typeof(d[k]) != TYPE_DICTIONARY:
			return "field %s is not an object" % k
	var bad := _range_problem(d)
	if bad != "":
		return bad
	if d.has("pos"):
		var p: Variant = d["pos"]
		if typeof(p) != TYPE_ARRAY or (p as Array).size() != 3:
			return "pos is not three numbers"
		for c in p:
			if not _is_number(c):
				return "pos holds a non-number"
			if absf(float(c)) > COORD_LIMIT:
				return "pos is out of range"
	return _nested_problem(d)


## A number that is present but impossible: negative, or far past anything a game reaches.
static func _range_problem(d: Dictionary) -> String:
	for k in STATS:
		if d.has(k) and (float(d[k]) < 0.0 or float(d[k]) > STAT_LIMIT):
			return "field %s is out of range" % k
	for k in COUNTS:
		if d.has(k) and (float(d[k]) < 0.0 or float(d[k]) > COUNT_LIMIT):
			return "field %s is out of range" % k
	if d.has("active_astra") and (float(d["active_astra"]) < 0.0 or float(d["active_astra"]) > ASTRA_LIMIT):
		return "active_astra is out of range"
	if d.has("time_of_day") and (float(d["time_of_day"]) < 0.0 or float(d["time_of_day"]) > CLOCK_LIMIT):
		return "time_of_day is out of range"
	if d.has("yaw") and absf(float(d["yaw"])) > 1000.0:
		return "yaw is out of range"
	if d.has("play_seconds") and (float(d["play_seconds"]) < 0.0 or float(d["play_seconds"]) > SECONDS_LIMIT):
		return "play_seconds is out of range"
	return ""


## The dictionaries inside the save: what the game indexes into when it loads them.
static func _nested_problem(d: Dictionary) -> String:
	for n in (d.get("inventory", {}) as Dictionary).values():
		if not _is_number(n) or float(n) < 0.0 or float(n) > COUNT_LIMIT:
			return "an inventory count is not a sensible number"
	var seen: Variant = (d.get("flags", {}) as Dictionary).get("dlg_seen", null)
	if seen != null and typeof(seen) != TYPE_DICTIONARY:
		return "flags.dlg_seen is not an object"
	for q in (d.get("quests", {}) as Dictionary).values():
		if typeof(q) != TYPE_DICTIONARY:
			return "a quest entry is not an object"
		var state: Variant = (q as Dictionary).get("state", "")
		if typeof(state) != TYPE_STRING:
			return "a quest's state is not text"
		var o: Variant = (q as Dictionary).get("objectives", {})
		if typeof(o) != TYPE_DICTIONARY:
			return "a quest's objectives are not an object"
		for progress in (o as Dictionary).values():
			if not _is_number(progress) or float(progress) < 0.0 or float(progress) > COUNT_LIMIT:
				return "a quest objective's progress is not a sensible number"
	return ""


static func _is_number(v: Variant) -> bool:
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return false
	return not is_nan(float(v)) and not is_inf(float(v))


static func _fail(message: String, detail: String) -> Dictionary:
	push_warning("[save] rejected: " + detail)
	return {"ok": false, "data": {}, "message": message}
