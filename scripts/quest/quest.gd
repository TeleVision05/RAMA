class_name Quest
extends Resource
## A quest and its objectives as typed objects rather than loose dictionaries.
##
## `QuestData` authors quests as dictionaries — that is what a designer wants to
## edit — and `Quest.from_dict` turns each one into this, once, on first use. Every
## reader downstream (the system, the journal wording, the world marker) works off
## these fields, so a misspelled key is a single loud failure at build time instead
## of a silent `Dictionary.get()` default at twenty call sites.
##
## The lifecycle is `not_started -> active -> complete`, with `failed` as a terminal
## state a quest can be pushed into. Nothing in the three shipped quests fails —
## they are all recoverable by design — but the state is a first-class part of the
## machine: it persists, it blocks restarts, it blocks progress, and the journal
## reads it. `QuestSystem.fail_quest()` is the only way in.

enum Kind { TALK_TO, GO_TO, KILL, COLLECT, INTERACT, DISCOVER, ESCORT, RETURN }

const KIND_NAMES: Array = ["talk_to", "go_to", "kill", "collect", "interact", "discover", "escort", "return"]

const STATE_NOT_STARTED := "not_started"
const STATE_ACTIVE := "active"
const STATE_COMPLETE := "complete"
const STATE_FAILED := "failed"


# ===========================================================================
## One step of a quest. `kind` decides which signal or poll can move it, `target`
## says which one (an npc id, an item id, an interact tag, a place id, an escortee),
## and `count` is how many times.
class Objective:
	extends Resource
	var id: String = ""
	var kind: int = Quest.Kind.INTERACT
	var target: String = ""
	var count: int = 1
	var description: String = ""
	var optional: bool = false
	## Objective ids that must be finished before this one is even listed in the
	## journal. Used for the reveal at the end of "Into the Wild".
	var hidden_until: Array = []
	## Objective ids that must be finished before this one can take progress. The
	## step is listed, so the player can read where the quest is going.
	var after: Array = []
	## Where in the world this step is, for the marker and for GO_TO / RETURN.
	var where: Vector2 = Vector2.ZERO
	var has_where: bool = false
	var radius: float = 14.0
	## RETURN: what you must be carrying. KILL: an enemy kind name, "" for any.
	var carry: String = ""
	## KILL: `{kind, at, count}` — the group to put in the world once this step is live.
	var spawn: Dictionary = {}
	## Granted the moment this one step finishes: `{items: {id: n}, arrows: n, note: ""}`.
	var reward: Dictionary = {}

	func kind_name() -> String:
		return String(Quest.KIND_NAMES[clampi(kind, 0, Quest.KIND_NAMES.size() - 1)])

	## Every objective id that must be done before this one is live at all.
	func gates() -> Array:
		var out: Array = []
		for g in after:
			out.append(String(g))
		for g in hidden_until:
			if not out.has(String(g)):
				out.append(String(g))
		return out

	## "Light the three lamps (2/3)" — the journal draws its own counter, but the
	## HUD objective line and every notification want one string.
	func progress_text(have: int) -> String:
		if count <= 1:
			return description
		return "%s (%d/%d)" % [description, clampi(have, 0, count), count]

	func distance_to(p: Vector3) -> float:
		if not has_where:
			return INF
		return Vector2(p.x - where.x, p.z - where.y).length()

	static func from_dict(d: Dictionary) -> Objective:
		var o := Objective.new()
		o.id = String(d.get("id", ""))
		var k: Variant = d.get("kind", "interact")
		o.kind = Quest.kind_from_name(String(k)) if typeof(k) == TYPE_STRING else int(k)
		o.target = String(d.get("target", ""))
		o.count = maxi(1, int(d.get("count", 1)))
		o.description = String(d.get("description", ""))
		o.optional = bool(d.get("optional", false))
		o.hidden_until = (d.get("hidden_until", []) as Array).duplicate()
		o.after = (d.get("after", []) as Array).duplicate()
		if d.has("where"):
			o.where = d["where"]
			o.has_where = true
		o.radius = float(d.get("radius", 14.0))
		o.carry = String(d.get("carry", ""))
		o.spawn = (d.get("spawn", {}) as Dictionary).duplicate(true)
		o.reward = (d.get("reward", {}) as Dictionary).duplicate(true)
		if o.id == "":
			push_error("[quest] an objective was authored with no id")
		return o


# ===========================================================================
var id: String = ""
var title: String = ""
var summary: String = ""
## Array[Objective], in the order the journal lists them.
var objectives: Array = []
var rewards: Dictionary = {}
## `{discovered: [place_id...], quests: [quest_id...]}` — all clauses must hold
## before the quest can start. An empty dictionary means "always available".
var prerequisites: Dictionary = {}
## A quest that refuses a wholesale `complete_quest()` from outside while its
## objectives are unmet. "The Forgotten Shrine" sets it: a conversation elsewhere
## in the world offers to close it, and the shrine is not a thing you can be told
## you have finished.
var strict: bool = false
## Place ids whose first discovery opens this quest without anybody asking.
var opens_on_discovery: Array = []
## NPC ids whose conversation opens this quest.
var opens_on_talk: Array = []


static func kind_from_name(n: String) -> int:
	var i: int = KIND_NAMES.find(n)
	if i < 0:
		push_error("[quest] unknown objective kind: " + n)
		return Kind.INTERACT
	return i


func objective(oid: String) -> Objective:
	for o in objectives:
		if (o as Objective).id == oid:
			return o
	return null


func has_objective(oid: String) -> bool:
	return objective(oid) != null


func objective_ids() -> Array:
	var out: Array = []
	for o in objectives:
		out.append((o as Objective).id)
	return out


## The objectives that must be finished for the quest to complete.
func required_ids() -> Array:
	var out: Array = []
	for o in objectives:
		if not (o as Objective).optional:
			out.append((o as Objective).id)
	return out


static func from_dict(qid: String, d: Dictionary) -> Quest:
	var q := Quest.new()
	q.id = qid
	q.title = String(d.get("title", qid))
	q.summary = String(d.get("summary", ""))
	q.rewards = (d.get("rewards", {}) as Dictionary).duplicate(true)
	q.prerequisites = (d.get("prerequisites", {}) as Dictionary).duplicate(true)
	q.strict = bool(d.get("strict", false))
	q.opens_on_discovery = (d.get("opens_on_discovery", []) as Array).duplicate()
	q.opens_on_talk = (d.get("opens_on_talk", []) as Array).duplicate()
	var seen: Dictionary = {}
	for od in d.get("objectives", []):
		var o := Objective.from_dict(od)
		if seen.has(o.id):
			push_error("[quest] %s has two objectives called %s" % [qid, o.id])
			continue
		seen[o.id] = true
		q.objectives.append(o)
	# Every gate must name a step that exists and comes earlier, or the quest can
	# deadlock in a way no play-through would ever explain.
	var order: Array = q.objective_ids()
	for o in q.objectives:
		var oo: Objective = o
		for g in oo.gates():
			var gi: int = order.find(String(g))
			if gi < 0:
				push_error("[quest] %s/%s waits on a step that does not exist: %s" % [qid, oo.id, g])
			elif gi >= order.find(oo.id):
				push_error("[quest] %s/%s waits on a later step: %s" % [qid, oo.id, g])
	return q
