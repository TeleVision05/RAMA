class_name DialogueSystem
extends Node
## Walks a dialogue graph and drives the DialogueBox.
##
## The graph itself lives in DialogueData; this is the interpreter. It owns exactly
## three responsibilities: pick the entry node for a tree given the world state, walk
## nodes and choices, and evaluate the little condition/action language that lets the
## writing react to quests, flags and the pack.
##
## CONDITIONS (a String, or an Array of Strings meaning "all of these")
##     flag:<key>                 GameState flag is truthy
##     seen:<node>                this node has been visited, in THIS tree
##     seen:<tree>:<node>         ... in another tree
##     item:<id>[:<n>]            the player carries at least n (default 1)
##     quest:<id>:<state>         state is one of none / active / complete
##     met:<npc_id>               you have spoken to that villager
##     night / day                the sky clock
##     any of the above prefixed with `!` inverts it
##
## ACTIONS (a String, or an Array of Strings run in order)
##     flag:<key>=<value>         value parses as true/false/number/string
##     give:<item>[:<n>]          take:<item>[:<n>]
##     quest_start:<id>           quest_complete:<id>
##     quest_advance:<id>:<objective>[:<n>]
##     heal:<amount>              sound:<sfx>            event:<name>
##     notify:<title>|<body>
##
## A quest action prefers a live QuestSystem (a node in group `quest_system` exposing
## start_quest / complete_quest / advance_quest) and falls back to writing GameState
## directly, so conversations work whether or not the quest module is present.

signal started(tree_id: String)
signal ended(tree_id: String)
signal node_entered(node_id: String)
signal choice_made(node_id: String, index: int)

static var _inst: DialogueSystem = null

var box: DialogueBox
var layer: CanvasLayer
var active: bool = false
var current_tree: String = ""
var current_node_id: String = ""
var current_choices: Array = []

var _tree: Dictionary = {}
var _nodes: Dictionary = {}
var _npc: Node = null
var _player: Node = null
var _rng := RandomNumberGenerator.new()


## The one DialogueSystem, created on first use. There is no autoload for it because
## project.godot belongs to the lead; this keeps the module self-contained.
##
## It parents to the CALLER, not to the scene root. Game builds its content systems
## from inside `_ready`, and at that moment the root is busy adding children, so
## `root.add_child()` is refused — which left the panel unbuilt and every line of
## dialogue calling into a null box. The caller is already in the tree and is not busy.
static func instance(ctx: Node) -> DialogueSystem:
	if _inst != null and is_instance_valid(_inst) and _inst.is_inside_tree():
		return _inst
	var d := DialogueSystem.new()
	d.name = "DialogueSystem"
	var host: Node = ctx
	if host == null or not host.is_inside_tree():
		host = ctx.get_tree().root
	host.add_child(d)
	_inst = d
	return d


static func get_instance() -> DialogueSystem:
	if _inst != null and is_instance_valid(_inst) and _inst.is_inside_tree():
		return _inst
	return null


func _ready() -> void:
	_inst = self
	QuietMode.seed_rng(_rng)
	add_to_group("dialogue_system")
	_ensure_ui()


## Build the panel. Idempotent, and called again from `start` so a system that somehow
## reached a conversation without a _ready still has something to draw into.
func _ensure_ui() -> void:
	if box != null and is_instance_valid(box):
		return
	layer = CanvasLayer.new()
	layer.name = "DialogueLayer"
	# Above the HUD (layer 10) and below the menus (20): a conversation panel must not
	# be crossed by a stamina bar, and a pause menu must still cover it.
	layer.layer = 14
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	box = DialogueBox.new()
	layer.add_child(box)


func _exit_tree() -> void:
	if _inst == self:
		_inst = null


# ===========================================================================
#  running a conversation
# ===========================================================================
func start(tree_id: String, npc: Node = null, player: Node = null) -> bool:
	if active:
		return false
	var t: Dictionary = DialogueData.tree(tree_id)
	if t.is_empty():
		push_warning("[dialogue] no such tree: %s" % tree_id)
		return false
	_ensure_ui()
	if box == null:
		push_error("[dialogue] no panel to draw into")
		return false
	current_tree = tree_id
	_tree = t
	_nodes = t.get("nodes", {})
	_npc = npc
	_player = player
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")

	var start_id := entry_node()
	if start_id == "":
		push_warning("[dialogue] tree %s has no reachable entry" % tree_id)
		return false

	active = true
	if _npc != null:
		var nid: Variant = _npc.get("id")
		if nid != null:
			GameState.set_flag("met_" + String(nid), true)
		if _npc.has_method("set_talking"):
			_npc.set_talking(true)
	if _player != null and _player.has_method("lock_input"):
		_player.lock_input(true)

	box.open()
	AudioDirector.play_ui("ui_open")
	EventBus.dialogue_started.emit(default_speaker(), start_id)
	started.emit(tree_id)
	_walk(start_id)
	return true


## The first entry whose condition passes. Entries are ordered most-specific first,
## which is how an NPC stops re-introducing themselves.
func entry_node() -> String:
	var entries: Array = _tree.get("entries", [])
	for e in entries:
		if typeof(e) == TYPE_STRING:
			return String(e)
		var d: Dictionary = e
		if check(d.get("condition", null)):
			return String(d.get("node", ""))
	if _nodes.is_empty():
		return ""
	return String(_nodes.keys()[0])


func default_speaker() -> String:
	if _npc != null:
		var dn: Variant = _npc.get("display_name")
		if dn != null and String(dn) != "":
			return String(dn)
	return String(_tree.get("speaker", "Villager"))


func _walk(node_id: String) -> void:
	var guard := 0
	while node_id != "" and active and guard < 512:
		guard += 1
		if not _nodes.has(node_id):
			push_warning("[dialogue] %s: missing node '%s'" % [current_tree, node_id])
			break
		var n: Dictionary = _nodes[node_id]
		current_node_id = node_id
		mark_seen(current_tree, node_id)
		node_entered.emit(node_id)
		EventBus.dialogue_node_entered.emit(current_tree, node_id)
		if n.has("action"):
			act(n["action"])

		var speaker := String(n.get("speaker", default_speaker()))
		var text := pick_text(n.get("text", ""))
		var vis := visible_choices(n)
		current_choices = vis
		var labels: Array = []
		for c in vis:
			labels.append(String(c.get("text", "...")))

		var idx: int = await box.show_line(speaker, text, labels)
		if not active:
			return
		if vis.is_empty():
			node_id = String(n.get("next", ""))
		else:
			var pick: int = clampi(idx, 0, vis.size() - 1)
			var c: Dictionary = vis[pick]
			choice_made.emit(node_id, pick)
			EventBus.dialogue_choice_made.emit(current_tree, node_id, pick, String(c.get("text", "")))
			if c.has("action"):
				act(c["action"])
			node_id = String(c.get("next", ""))
	_close()


## Choices whose condition passes, in order. A hidden option leaves no gap.
func visible_choices(n: Dictionary) -> Array:
	var out: Array = []
	for c in n.get("choices", []):
		var d: Dictionary = c
		if check(d.get("condition", null)):
			out.append(d)
	return out


func pick_text(t: Variant) -> String:
	if t is Array:
		var arr: Array = t
		if arr.is_empty():
			return ""
		return String(arr[_rng.randi() % arr.size()])
	return String(t)


func _close() -> void:
	if not active:
		return
	var tid := current_tree
	active = false
	current_node_id = ""
	current_choices = []
	box.close()
	if _player != null and is_instance_valid(_player) and _player.has_method("lock_input"):
		_player.lock_input(false)
	if _npc != null and is_instance_valid(_npc) and _npc.has_method("set_talking"):
		_npc.set_talking(false)
	_npc = null
	AudioDirector.play_ui("ui_close")
	EventBus.dialogue_ended.emit()
	ended.emit(tid)


## Force the conversation shut (death, a cutscene, a pause menu).
func cancel() -> void:
	if active:
		_close()


func is_active() -> bool:
	return active


# --- convenience for scripted input and tests -------------------------------
## Scripted advance: finish the reveal and commit, in one call. A human pressing the
## key twice gets the same result; this is what quests and tests should use.
func advance() -> void:
	if active:
		box.skip_typing()
		box.press_confirm()


func choose(index: int) -> void:
	if not active:
		return
	box.skip_typing()
	box.select(index)
	box.press_confirm()


func choice_labels() -> Array:
	var out: Array = []
	for c in current_choices:
		out.append(String((c as Dictionary).get("text", "")))
	return out


# ===========================================================================
#  conditions
# ===========================================================================
func check(cond: Variant) -> bool:
	if cond == null:
		return true
	if cond is Array:
		for c in cond:
			if not check(c):
				return false
		return true
	var s := String(cond).strip_edges()
	if s == "":
		return true
	if s.begins_with("!"):
		return not check(s.substr(1))
	var p := s.split(":")
	var head := p[0]
	match head:
		"flag":
			return p.size() > 1 and _truthy(GameState.get_flag(p[1], false))
		"seen":
			if p.size() > 2:
				return has_seen(p[1], p[2])
			return p.size() > 1 and has_seen(current_tree, p[1])
		"item":
			if p.size() < 2:
				return false
			var need: int = int(p[2]) if p.size() > 2 else 1
			return GameState.item_count(p[1]) >= need
		"quest":
			if p.size() < 3:
				return false
			return quest_state(p[1]) == p[2]
		"met":
			return p.size() > 1 and _truthy(GameState.get_flag("met_" + p[1], false))
		"night":
			return _is_night()
		"day":
			return not _is_night()
	push_warning("[dialogue] unknown condition: %s" % s)
	return true


static func _truthy(v: Variant) -> bool:
	match typeof(v):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return absf(float(v)) > 0.0001
		TYPE_STRING:
			return String(v) != "" and String(v) != "false"
	return v != null


func _is_night() -> bool:
	for w in get_tree().get_nodes_in_group("sky"):
		if w.has_method("is_night"):
			return w.is_night()
	var h: float = GameState.time_of_day
	return h < 5.0 or h >= 20.4


func quest_state(id: String) -> String:
	var q: Variant = GameState.quests.get(id, null)
	if q == null:
		return "none"
	if typeof(q) == TYPE_DICTIONARY:
		return String((q as Dictionary).get("state", "active"))
	return String(q)


func mark_seen(tree_id: String, node_id: String) -> void:
	var d: Dictionary = GameState.flags.get("dlg_seen", {})
	d[tree_id + "/" + node_id] = true
	GameState.flags["dlg_seen"] = d


func has_seen(tree_id: String, node_id: String) -> bool:
	var d: Dictionary = GameState.flags.get("dlg_seen", {})
	return d.has(tree_id + "/" + node_id)


# ===========================================================================
#  actions
# ===========================================================================
func act(a: Variant) -> void:
	if a == null:
		return
	if a is Array:
		for x in a:
			act(x)
		return
	var s := String(a).strip_edges()
	if s == "":
		return
	var p := s.split(":")
	match p[0]:
		"flag":
			var body := s.substr(5)
			var key := body
			var val: Variant = true
			var eq := body.find("=")
			if eq >= 0:
				key = body.substr(0, eq).strip_edges()
				val = _parse_value(body.substr(eq + 1).strip_edges())
			GameState.set_flag(key, val)
		"give":
			if p.size() > 1:
				GameState.add_item(p[1], int(p[2]) if p.size() > 2 else 1)
				AudioDirector.play_2d("pickup_item", -7.0)
		"take":
			if p.size() > 1:
				GameState.remove_item(p[1], int(p[2]) if p.size() > 2 else 1)
		"quest_start":
			if p.size() > 1:
				_quest_start(p[1])
		"quest_complete":
			if p.size() > 1:
				_quest_complete(p[1])
		"quest_advance":
			if p.size() > 2:
				_quest_advance(p[1], p[2], int(p[3]) if p.size() > 3 else 1)
		"heal":
			if p.size() > 1 and _player != null and _player.has_method("heal"):
				_player.heal(float(p[1]))
		"sound":
			if p.size() > 1:
				AudioDirector.play_2d(p[1], -5.0)
		"event":
			if p.size() > 1:
				EventBus.dialogue_event.emit(p[1], current_tree)
		"notify":
			var body2 := s.substr(7)
			var bits := body2.split("|")
			EventBus.notify.emit(bits[0], bits[1] if bits.size() > 1 else "", "info")
		_:
			push_warning("[dialogue] unknown action: %s" % s)


static func _parse_value(v: String) -> Variant:
	var low := v.to_lower()
	if low == "true":
		return true
	if low == "false":
		return false
	if v.is_valid_int():
		return int(v)
	if v.is_valid_float():
		return float(v)
	return v


func _quest_node() -> Node:
	for n in get_tree().get_nodes_in_group("quest_system"):
		if n.has_method("start_quest"):
			return n
	return null


func _quest_start(id: String) -> void:
	var qs := _quest_node()
	if qs != null:
		qs.start_quest(id)
		return
	if quest_state(id) != "none":
		return
	GameState.quests[id] = {"state": "active", "objectives": {}}
	EventBus.quest_started.emit(id)
	AudioDirector.play_2d("quest_accept", -5.0)


func _quest_complete(id: String) -> void:
	var qs := _quest_node()
	if qs != null and qs.has_method("complete_quest"):
		qs.complete_quest(id)
		return
	var q: Dictionary = GameState.quests.get(id, {"state": "active", "objectives": {}})
	q["state"] = "complete"
	GameState.quests[id] = q
	EventBus.quest_completed.emit(id)
	AudioDirector.play_2d("objective_complete", -5.0)


func _quest_advance(id: String, objective: String, amount: int) -> void:
	var qs := _quest_node()
	if qs != null and qs.has_method("advance_quest"):
		qs.advance_quest(id, objective, amount)
		return
	var q: Dictionary = GameState.quests.get(id, {"state": "active", "objectives": {}})
	var obj: Dictionary = q.get("objectives", {})
	obj[objective] = int(obj.get(objective, 0)) + amount
	q["objectives"] = obj
	q["state"] = "active"
	GameState.quests[id] = q
	EventBus.quest_objective_changed.emit(id, objective, int(obj[objective]), 1)
