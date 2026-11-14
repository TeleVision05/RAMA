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


## Parse the text of a save file. Returns {"ok": bool, "data": Dictionary, "message": String}.
static func parse_text(text: String, source: String = "save") -> Dictionary:
	var json := JSON.new()
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
	if d.has("pos"):
		var p: Variant = d["pos"]
		if typeof(p) != TYPE_ARRAY or (p as Array).size() != 3:
			return "pos is not three numbers"
		for c in p:
			if not _is_number(c):
				return "pos holds a non-number"
	for q in (d.get("quests", {}) as Dictionary).values():
		if typeof(q) != TYPE_DICTIONARY:
			return "a quest entry is not an object"
		var o: Variant = (q as Dictionary).get("objectives", {})
		if typeof(o) != TYPE_DICTIONARY:
			return "a quest's objectives are not an object"
	return ""


static func _is_number(v: Variant) -> bool:
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return false
	return not is_nan(float(v)) and not is_inf(float(v))


static func _fail(message: String, detail: String) -> Dictionary:
	push_warning("[save] rejected: " + detail)
	return {"ok": false, "data": {}, "message": message}
