class_name QuestSystem
extends Node3D
## Data-driven quests.
##
## State lives entirely in `GameState.quests`, in the shape the journal already
## reads — `{quest_id: {state, objectives: {objective_id: progress_int}}}` — so a
## save round-trips with no extra code. Objectives advance from EventBus signals and
## from world objects calling `notify_interact`; nothing outside this file writes the
## log.
##
## Every objective of an active quest is seeded into that dictionary at 0 the moment
## the quest starts, even before it has any progress. The journal draws exactly the
## keys it finds there, so without the seed a freshly accepted quest reads as a title
## with nothing under it — which is what it did before 2026-08-28.
##
## Implements the interface the HUD and journal look for by capability rather than by
## class: `quest_title`, `quest_summary`, `objective_text`, `objective_total`,
## `start_quest`, `complete_quest`, `advance_quest`, `notify_interact`, `notify_talk`,
## `save_into`, `load_from`.

signal marker_moved(position: Vector3, active: bool)

const POLL := 0.3  # seconds between position checks
const WELCOME_RANGE := 42.0  # villagers this close join in when a quest ends

var map: WorldMap
var _player: Node3D
var _enemies: Node
var _interactables: Node

var _marker: Node3D
var _marker_mesh: MeshInstance3D
var _marker_mat: StandardMaterial3D
var _marker_puff: GPUParticles3D
var _marker_at: Vector3 = Vector3.ZERO
var _marker_active: bool = false

## "quest/objective" -> true, so an ambush is put in the world exactly once.
var _spawned: Dictionary = {}
## Instance ids of enemies a KILL objective spawned, so they count wherever they die.
var _spawn_ids: Dictionary = {}  # "quest/objective" -> {instance_id: true}
var _focus: String = ""  # quest the marker is following
var _talking_to: String = ""  # npc id of the conversation in progress
var _backfilling: bool = false
var _poll: float = 0.0


# ===========================================================================
#  Wiring
# ===========================================================================
func _ready() -> void:
	add_to_group("quest_system")


func setup(world_map: WorldMap) -> void:
	map = world_map
	_build_marker()
	EventBus.enemy_died.connect(_on_enemy_died)
	EventBus.item_gained.connect(_on_item_gained)
	EventBus.location_discovered.connect(_on_location)
	EventBus.dialogue_started.connect(_on_dialogue_started)
	EventBus.dialogue_ended.connect(_on_dialogue_ended)


func bind(player: Node3D, enemies: Node) -> void:
	_player = player
	_enemies = enemies


## Interactables register themselves so the system can put the world back the way a
## loaded save says it should be (lit lamps, taken pickups, an opened gate).
func bind_interactables(n: Node) -> void:
	_interactables = n


# ===========================================================================
#  State
# ===========================================================================
func _q(qid: String) -> Dictionary:
	var raw: Variant = GameState.quests.get(qid, null)
	if typeof(raw) == TYPE_DICTIONARY:
		return raw
	return {}


func _objs(qid: String) -> Dictionary:
	var d := _q(qid)
	var raw: Variant = d.get("objectives", null)
	if typeof(raw) == TYPE_DICTIONARY:
		return raw
	return {}


func state_of(qid: String) -> String:
	var d := _q(qid)
	if d.is_empty():
		return Quest.STATE_NOT_STARTED
	return String(d.get("state", Quest.STATE_ACTIVE))


func is_active(qid: String) -> bool:
	return state_of(qid) == Quest.STATE_ACTIVE


func is_complete(qid: String) -> bool:
	return state_of(qid) == Quest.STATE_COMPLETE


func progress(qid: String, oid: String) -> int:
	return int(_objs(qid).get(oid, 0))


func objective_total(qid: String, oid: String) -> int:
	var o := QuestData.objective_def(qid, oid)
	return maxi(1, o.count) if o != null else 1


func objective_done(qid: String, oid: String) -> bool:
	return progress(qid, oid) >= objective_total(qid, oid)


## True when every step this one waits on is finished.
func objective_unlocked(qid: String, oid: String) -> bool:
	var o := QuestData.objective_def(qid, oid)
	if o == null:
		return false
	for g in o.gates():
		if not objective_done(qid, String(g)):
			return false
	return true


## True when the journal should be showing this step at all.
func objective_visible(qid: String, oid: String) -> bool:
	var o := QuestData.objective_def(qid, oid)
	if o == null:
		return false
	for g in o.hidden_until:
		if not objective_done(qid, String(g)):
			return false
	return true


## Every step that can take progress right now: revealed, unlocked and unfinished.
func live_objectives(qid: String) -> Array:
	var out: Array = []
	if not is_active(qid):
		return out
	for o in QuestData.objective_list(qid):
		var oo: Quest.Objective = o
		if objective_done(qid, oo.id):
			continue
		if not objective_visible(qid, oo.id) or not objective_unlocked(qid, oo.id):
			continue
		out.append(oo)
	return out


## The one step to point the player at: the first live required step, or the first
## live optional one if the required list is momentarily empty.
func current_objective(qid: String) -> Quest.Objective:
	var live := live_objectives(qid)
	for o in live:
		if not (o as Quest.Objective).optional:
			return o
	return live[0] if not live.is_empty() else null


func active_quests() -> Array:
	var out: Array = []
	for qid in QuestData.quest_ids():
		if is_active(String(qid)):
			out.append(String(qid))
	return out


## Does the world satisfy this prerequisite block? Clauses: `discovered` (place ids
## the player has entered) and `quests` (quest ids already complete).
func prereq_met(spec: Dictionary) -> bool:
	for place in spec.get("discovered", []):
		if not GameState.discovered.has(String(place)):
			return false
	for other in spec.get("quests", []):
		if state_of(String(other)) != Quest.STATE_COMPLETE:
			return false
	return true


func can_start(qid: String) -> bool:
	var q := QuestData.quest(qid)
	if q == null:
		return false
	if state_of(qid) != Quest.STATE_NOT_STARTED:
		return false
	return prereq_met(q.prerequisites)


# ===========================================================================
#  Public API — dialogue actions, world objects, tests
# ===========================================================================
func start_quest(qid: String) -> bool:
	var q := QuestData.quest(qid)
	if q == null:
		push_warning("[quest] unknown quest: " + qid)
		return false
	if state_of(qid) != Quest.STATE_NOT_STARTED:
		return false
	if not prereq_met(q.prerequisites):
		return false
	GameState.quests[qid] = {"state": Quest.STATE_ACTIVE, "objectives": {}}
	_reveal(qid)
	_focus = qid
	# The interface raises its own "Quest started" card from this signal. Raising a
	# second `notify` here put two cards on screen for one event (seen 2026-08-28).
	EventBus.quest_started.emit(qid)
	AudioDirector.play_2d("quest_accept", -5.0)
	_backfill(qid)
	_sync_world()
	_update_marker(true)
	return true


func advance_quest(qid: String, oid: String, amount: int = 1) -> void:
	if not is_active(qid):
		return
	var o := QuestData.objective_def(qid, oid)
	if o == null:
		push_warning("[quest] %s has no objective %s" % [qid, oid])
		return
	var total := maxi(1, o.count)
	var have := progress(qid, oid)
	if have >= total:
		return
	have = mini(total, have + maxi(1, amount))
	_write(qid, oid, have)
	_focus = qid
	EventBus.quest_objective_changed.emit(qid, oid, have, total)
	if have >= total:
		EventBus.quest_objective_completed.emit(qid, oid)
		AudioDirector.play_2d("objective_complete", -6.0)
		_grant(o.reward, "%s — %s" % [quest_title(qid), o.description])
		_reveal(qid)
		_backfill(qid)
		if _all_required_done(qid):
			complete_quest(qid)
			return
	_sync_world()
	_update_marker(true)


## Put a counted objective back to zero. The shrine lamps use it: light them out of
## the order the inscription names and every flame goes out together.
func reset_objective(qid: String, oid: String) -> void:
	if not is_active(qid) or progress(qid, oid) <= 0:
		return
	_write(qid, oid, 0)
	EventBus.quest_objective_changed.emit(qid, oid, 0, objective_total(qid, oid))
	_update_marker(true)


## Finish a quest. A `strict` quest refuses while any required step is unmet — a
## conversation on the far side of the valley does not get to decide that the shrine
## has been put right.
func complete_quest(qid: String) -> bool:
	if state_of(qid) != Quest.STATE_ACTIVE:
		return false
	var q := QuestData.quest(qid)
	if q == null:
		return false
	if q.strict and not _all_required_done(qid):
		return false
	var d := _q(qid)
	var objs: Dictionary = d.get("objectives", {})
	for o in q.objectives:
		var oo: Quest.Objective = o
		if objs.has(oo.id) or not oo.optional:
			objs[oo.id] = maxi(int(objs.get(oo.id, 0)), oo.count)
	d["objectives"] = objs
	d["state"] = Quest.STATE_COMPLETE
	GameState.quests[qid] = d
	# Same as `start_quest`: the interface's own card comes off this signal, and the
	# reward's line is the second and last thing the player is told — in that order,
	# so the cards read "Quest complete" and then what it was worth.
	EventBus.quest_completed.emit(qid)
	AudioDirector.play_2d("sting_quest", -3.0)
	_grant(q.rewards, q.title)
	if String(q.rewards.get("welcome", "")) != "":
		_villagers_welcome(String(q.rewards["welcome"]))
	if _focus == qid:
		_focus = ""
	_sync_world()
	_update_marker(true)
	return true


## Push an active quest into its terminal failure state. Nothing in the three shipped
## quests calls this — they are all recoverable — but the state is real: it persists,
## it blocks any further progress, and it cannot be restarted.
func fail_quest(qid: String) -> bool:
	if state_of(qid) != Quest.STATE_ACTIVE:
		return false
	var d := _q(qid)
	d["state"] = Quest.STATE_FAILED
	GameState.quests[qid] = d
	EventBus.notify.emit("Quest failed", quest_title(qid), "warn")
	AudioDirector.play_2d("ui_close", -4.0)
	if _focus == qid:
		_focus = ""
	_update_marker(true)
	return true


## Called by world objects when they are used. Returns true if anything moved.
func notify_interact(tag: String) -> bool:
	return _advance_matching(Quest.Kind.INTERACT, tag, 1)


## Called by an NPC's conversation ending.
func notify_talk(npc_id: String) -> void:
	if npc_id == "":
		return
	for qid in QuestData.quest_ids():
		var q := QuestData.quest(String(qid))
		if q.opens_on_talk.has(npc_id) and can_start(String(qid)):
			start_quest(String(qid))
	_advance_matching(Quest.Kind.TALK_TO, npc_id, 1)
	# Coming back to the person who sent you is what closes a RETURN step; the
	# proximity poll does the same thing, but a conversation should not have to
	# wait for it.
	_check_return_talk(npc_id)


## Called by an escortee when it reaches somewhere. Also polled, so a follower that
## arrives while the player is looking elsewhere still counts.
func notify_escort(escort_id: String) -> void:
	_advance_matching(Quest.Kind.ESCORT, escort_id, 1)


func _advance_matching(kind: int, target: String, amount: int) -> bool:
	var hit := false
	for qid in active_quests():
		for o in live_objectives(qid):
			var oo: Quest.Objective = o
			if oo.kind != kind or oo.target != target:
				continue
			advance_quest(qid, oo.id, amount)
			hit = true
	return hit


func _write(qid: String, oid: String, value: int) -> void:
	var d := _q(qid)
	var objs: Dictionary = d.get("objectives", {})
	objs[oid] = value
	d["objectives"] = objs
	GameState.quests[qid] = d


## Seed every visible objective into the log so the journal has something to draw,
## and reveal any that have just come out of hiding.
func _reveal(qid: String) -> void:
	var d := _q(qid)
	if d.is_empty():
		return
	var objs: Dictionary = d.get("objectives", {})
	var added := false
	for o in QuestData.objective_list(qid):
		var oo: Quest.Objective = o
		if objs.has(oo.id) or not objective_visible(qid, oo.id):
			continue
		objs[oo.id] = 0
		added = true
	if added:
		d["objectives"] = objs
		GameState.quests[qid] = d


## Credit a step against state the player already has. A quest can name a place they
## have stood in, and a step can come out from behind its gate at the moment the thing
## it asks for is already in the pack — which is exactly what happens when the bell is
## found inside the cart that was the step before it. Without this the signal has
## already gone past and the step waits forever for an item the player is carrying.
func _backfill(qid: String) -> void:
	if _backfilling or not is_active(qid):
		return
	_backfilling = true
	var again := true
	var guard := 0
	while again and guard < 12:
		again = false
		guard += 1
		for o in live_objectives(qid):
			var oo: Quest.Objective = o
			var hit := false
			if oo.kind == Quest.Kind.DISCOVER and GameState.discovered.has(oo.target):
				hit = true
			elif oo.kind == Quest.Kind.COLLECT and GameState.has_item(oo.target, oo.count):
				hit = true
			if hit:
				# The nested advance is deliberately left blocked from re-entering
				# here; the loop below rescans instead, so the depth stays flat.
				advance_quest(qid, oo.id, oo.count)
				again = true
				break
	_backfilling = false


func _all_required_done(qid: String) -> bool:
	var q := QuestData.quest(qid)
	if q == null:
		return false
	for oid in q.required_ids():
		if not objective_done(qid, String(oid)):
			return false
	return true


# ===========================================================================
#  Rewards
# ===========================================================================
func _grant(r: Dictionary, source: String) -> void:
	if r.is_empty():
		return
	for item in r.get("items", {}):
		GameState.add_item(String(item), int(r["items"][item]))
	if r.has("arrows"):
		GameState.arrows = mini(GameState.max_arrows, GameState.arrows + int(r["arrows"]))
	if r.has("max_health"):
		GameState.max_health += float(r["max_health"])
		GameState.health = GameState.max_health
	if r.has("max_stamina"):
		GameState.max_stamina += float(r["max_stamina"])
		GameState.stamina = GameState.max_stamina
	if r.has("heal") and _player != null and _player.has_method("heal"):
		_player.call("heal", float(r["heal"]))
	for key in r.get("flag", {}):
		GameState.set_flag(String(key), r["flag"][key])
	if r.has("notify"):
		EventBus.notify.emit(source, String(r["notify"]), "quest")
	elif r.has("note"):
		EventBus.notify.emit(source, String(r["note"]), "quest")
	EventBus.player_stat_changed.emit(GameState.health, GameState.max_health, GameState.stamina, GameState.max_stamina)


## The villagers say something when you come back having done a thing for them.
func _villagers_welcome(line: String) -> void:
	if _player == null:
		return
	var said := 0
	for n in get_tree().get_nodes_in_group("npc"):
		if said >= 3 or not is_instance_valid(n) or not (n is Node3D):
			continue
		if (n as Node3D).global_position.distance_to(_player.global_position) > WELCOME_RANGE:
			continue
		if not n.has_method("say"):
			continue
		n.call("say", line)
		said += 1


# ===========================================================================
#  Signal-driven objectives
# ===========================================================================
func _on_enemy_died(enemy: Node) -> void:
	var at := Vector3.INF
	if is_instance_valid(enemy) and enemy is Node3D:
		at = (enemy as Node3D).global_position
	var eid: int = enemy.get_instance_id() if is_instance_valid(enemy) else 0
	for qid in active_quests():
		for o in live_objectives(qid):
			var oo: Quest.Objective = o
			if oo.kind != Quest.Kind.KILL:
				continue
			if not _kill_counts(qid, oo, eid, at):
				continue
			advance_quest(qid, oo.id, 1)


## A kill counts if it was one of this objective's own spawned group (wherever it
## wandered to before it died) or if it died inside the objective's radius.
func _kill_counts(qid: String, o: Quest.Objective, eid: int, at: Vector3) -> bool:
	var key := "%s/%s" % [qid, o.id]
	var mine: Dictionary = _spawn_ids.get(key, {})
	if mine.has(eid):
		return true
	if not o.has_where or at == Vector3.INF:
		return not o.has_where
	return o.distance_to(at) <= o.radius


func _on_item_gained(item_id: String, count: int) -> void:
	_advance_matching(Quest.Kind.COLLECT, item_id, count)


func _on_location(place_id: String, _display: String) -> void:
	for qid in QuestData.quest_ids():
		var q := QuestData.quest(String(qid))
		if q.opens_on_discovery.has(place_id) and can_start(String(qid)):
			start_quest(String(qid))
	_advance_matching(Quest.Kind.DISCOVER, place_id, 1)


## Which villager is this conversation with? The player's own interact target is the
## authority — the dialogue system hands out a display name, and two people can share
## one of those.
func _on_dialogue_started(speaker: String, _node_id: String) -> void:
	_talking_to = ""
	if _player != null and _player.has_method("current_interactable"):
		var t: Variant = _player.call("current_interactable")
		if t is Node and is_instance_valid(t) and (t as Node).is_in_group("npc"):
			var nid: Variant = (t as Node).get("id")
			if nid != null:
				_talking_to = String(nid)
	if _talking_to == "":
		for n in get_tree().get_nodes_in_group("npc"):
			if String(n.get("display_name")) == speaker:
				_talking_to = String(n.get("id"))
				break


func _on_dialogue_ended() -> void:
	var who := _talking_to
	_talking_to = ""
	notify_talk(who)


# ===========================================================================
#  Position-driven objectives, and discovery
# ===========================================================================
func _process(delta: float) -> void:
	if _player == null or map == null:
		return
	_poll -= delta
	if _poll <= 0.0:
		_poll = POLL
		_check_places()
		_check_positions()
		_check_spawns()
	_update_marker(false)


func _check_places() -> void:
	var p := _player.global_position
	for pid in QuestData.PLACES:
		if GameState.discovered.has(pid):
			continue
		var d: Dictionary = QuestData.PLACES[pid]
		var at: Vector2 = d["at"]
		if Vector2(p.x - at.x, p.z - at.y).length() > float(d["r"]):
			continue
		if GameState.discover(String(pid), String(d["name"])):
			AudioDirector.play_2d("sting_discovery", -4.0)


func _check_positions() -> void:
	var p := _player.global_position
	for qid in active_quests():
		for o in live_objectives(qid):
			var oo: Quest.Objective = o
			match oo.kind:
				Quest.Kind.GO_TO:
					if oo.has_where and oo.distance_to(p) <= oo.radius:
						advance_quest(qid, oo.id, oo.count)
				Quest.Kind.RETURN:
					if _return_satisfied(oo, p):
						advance_quest(qid, oo.id, oo.count)
				Quest.Kind.ESCORT:
					if _escort_arrived(oo, p):
						advance_quest(qid, oo.id, oo.count)
				_:
					pass


## Coming back means standing where you were sent back to, or standing next to the
## person who sent you. Not both: a villager on a daily schedule can be anywhere in
## his own settlement, and measured on 2026-08-28 Gopa's work spot sat 25.7 m from
## the village centre, which is outside the objective's own radius. Requiring the
## person alone made "return to Gopa in Panchavati" impossible to satisfy while
## standing in Panchavati looking at Gopa.
func _return_satisfied(o: Quest.Objective, p: Vector3) -> bool:
	if o.carry != "" and not GameState.has_item(o.carry):
		return false
	if o.has_where and o.distance_to(p) <= o.radius:
		return true
	var target := _npc_position(o.target)
	return target != Vector3.INF and p.distance_to(target) <= maxf(o.radius, 6.0)


## A RETURN step also closes when you actually speak to the person, which is what a
## player thinks "return to Gopa" means.
func _check_return_talk(npc_id: String) -> void:
	if _player == null:
		return
	var p := _player.global_position
	for qid in active_quests():
		for o in live_objectives(qid):
			var oo: Quest.Objective = o
			if oo.kind != Quest.Kind.RETURN or oo.target != npc_id:
				continue
			if oo.carry != "" and not GameState.has_item(oo.carry):
				continue
			if oo.has_where and oo.distance_to(p) > oo.radius * 2.0:
				continue
			advance_quest(qid, oo.id, oo.count)


func _escort_arrived(o: Quest.Objective, p: Vector3) -> bool:
	var e := _escortee(o.target)
	if e == null:
		return false
	if e.has_method("is_following") and not e.call("is_following"):
		return false
	if not o.has_where:
		return false
	var d := Vector2(e.global_position.x - o.where.x, e.global_position.z - o.where.y).length()
	return d <= o.radius and e.global_position.distance_to(p) <= 28.0


func _escortee(escort_id: String) -> Node3D:
	for n in get_tree().get_nodes_in_group("escortee"):
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		if String(n.get("escort_id")) == escort_id:
			return n
	return null


func _npc_position(npc_id: String) -> Vector3:
	for n in get_tree().get_nodes_in_group("npc"):
		if is_instance_valid(n) and n is Node3D and String(n.get("id")) == npc_id:
			return (n as Node3D).global_position
	return Vector3.INF


# ===========================================================================
#  Ambushes
# ===========================================================================
## Put a KILL objective's group in the world the first time that step goes live.
func _check_spawns() -> void:
	for qid in active_quests():
		for o in live_objectives(qid):
			var oo: Quest.Objective = o
			if oo.kind != Quest.Kind.KILL or oo.spawn.is_empty():
				continue
			_spawn_group(qid, oo)


func _spawn_group(qid: String, o: Quest.Objective) -> void:
	var key := "%s/%s" % [qid, o.id]
	if _spawned.has(key):
		return
	if _enemies == null or not _enemies.has_method("spawn_group") or map == null:
		return
	var at: Vector2 = o.spawn.get("at", o.where)
	var centre := Vector3(at.x, map.height_at(at.x, at.y), at.y)
	var made: Variant = _enemies.call("spawn_group", int(o.spawn.get("kind", 0)), centre, int(o.spawn.get("count", 3)))
	_spawned[key] = true
	var ids: Dictionary = {}
	if made is Array:
		for e in made as Array:
			if is_instance_valid(e):
				ids[e.get_instance_id()] = true
	_spawn_ids[key] = ids
	if not ids.is_empty():
		EventBus.notify.emit("They were waiting", "Something moves in the trees.", "warn")
		AudioDirector.play_3d("enemy_growl_1", centre, -2.0)


## A world object that wakes something up — the ruin gate has rakshasas behind it.
## Returns how many actually found ground to stand on.
func spawn_at(kind: int, centre: Vector3, count: int) -> int:
	if _enemies == null or not _enemies.has_method("spawn_group"):
		return 0
	var made: Variant = _enemies.call("spawn_group", kind, centre, count)
	return (made as Array).size() if made is Array else 0


## Is this exact step of this quest something the player can act on right now? World
## objects ask before offering themselves — a goat pen is not a pen you can open
## before you have any reason to.
func is_objective_live(qid: String, oid: String) -> bool:
	for o in live_objectives(qid):
		if (o as Quest.Objective).id == oid:
			return true
	return false


# ===========================================================================
#  The world marker: a shaft of warm light with motes rising through it
# ===========================================================================
func _build_marker() -> void:
	_marker = Node3D.new()
	_marker.name = "ObjectiveMarker"
	add_child(_marker)

	_marker_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.08
	cyl.bottom_radius = 1.05
	cyl.height = 30.0
	cyl.radial_segments = 16
	cyl.rings = 1
	_marker_mesh.mesh = cyl
	_marker_mat = StandardMaterial3D.new()
	_marker_mat.albedo_color = Color(1.0, 0.82, 0.46, 0.22)
	_marker_mat.emission_enabled = true
	_marker_mat.emission = Color(1.0, 0.76, 0.38)
	_marker_mat.emission_energy_multiplier = 2.4
	_marker_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_marker_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_mat.cull_mode = BaseMaterial3D.CULL_BACK
	_marker_mat.disable_receive_shadows = true
	_marker_mesh.mesh.surface_set_material(0, _marker_mat)
	_marker_mesh.position = Vector3(0, 15.0, 0)
	_marker_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker.add_child(_marker_mesh)

	# Slow motes drifting up the shaft. `lifetime_randomness` is on the process
	# material, not on the emitter — the emitter refuses the assignment outright.
	_marker_puff = GPUParticles3D.new()
	_marker_puff.amount = 26
	_marker_puff.lifetime = 5.0
	_marker_puff.preprocess = 3.0
	_marker_puff.visibility_aabb = AABB(Vector3(-2.5, 0.0, -2.5), Vector3(5.0, 14.0, 5.0))
	var pm := ParticleProcessMaterial.new()
	pm.lifetime_randomness = 0.45
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	pm.emission_sphere_radius = 0.9
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 8.0
	pm.initial_velocity_min = 0.7
	pm.initial_velocity_max = 1.5
	pm.gravity = Vector3(0, 0.05, 0)
	pm.scale_min = 0.05
	pm.scale_max = 0.14
	pm.color = Color(1.0, 0.84, 0.50, 0.85)
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.86, 0.52, 0.0))
	ramp.set_color(1, Color(1.0, 0.62, 0.26, 0.0))
	ramp.add_point(0.25, Color(1.0, 0.84, 0.48, 1.0))
	ramp.add_point(0.7, Color(1.0, 0.72, 0.34, 0.7))
	var tex := GradientTexture1D.new()
	tex.gradient = ramp
	pm.color_ramp = tex
	_marker_puff.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.26, 0.26)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.albedo_color = Color(1.0, 1.0, 1.0)
	# Two things a mote needs. A round TEXTURE, or the quad is a hard-edged square
	# whatever its alpha says; and `vertex_color_use_as_albedo`, or the process
	# material's colour ramp never reaches the shader at all.
	qm.albedo_texture = QuestData.soft_dot()
	qm.vertex_color_use_as_albedo = true
	qm.emission_enabled = false
	qm.disable_receive_shadows = true
	quad.material = qm
	_marker_puff.draw_pass_1 = quad
	_marker_puff.position = Vector3(0, 0.4, 0)
	_marker_puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker.add_child(_marker_puff)

	_marker.visible = false


## Where the marker should stand: the current step of the quest the player last
## touched, falling back to the first active quest that has a place in it.
func _marker_target() -> Quest.Objective:
	var order: Array = []
	if _focus != "" and is_active(_focus):
		order.append(_focus)
	for qid in active_quests():
		if not order.has(qid):
			order.append(qid)
	for qid in order:
		var o := current_objective(String(qid))
		if o != null and o.has_where:
			return o
	return null


func _update_marker(force: bool) -> void:
	if _marker == null or map == null:
		return
	var o := _marker_target()
	if o == null:
		if _marker_active:
			_marker_active = false
			_marker.visible = false
			_marker_puff.emitting = false
			marker_moved.emit(Vector3.ZERO, false)
			EventBus.objective_marker_changed.emit(Vector3.ZERO, false)
		return
	var at := Vector3(o.where.x, map.height_at(o.where.x, o.where.y), o.where.y)
	if force or not _marker_active or at.distance_to(_marker_at) > 0.5:
		_marker_at = at
		_marker.global_position = at
		_marker_active = true
		_marker.visible = true
		_marker_puff.emitting = true
		marker_moved.emit(at, true)
		EventBus.objective_marker_changed.emit(at, true)
	if _player == null:
		return
	# Fade out as the player arrives, so it never stands inside the thing it points
	# at, and stays legible from the far side of the valley.
	var d := _player.global_position.distance_to(at)
	var near: float = clampf((d - 7.0) / 22.0, 0.0, 1.0)
	_marker_mat.albedo_color = Color(1.0, 0.82, 0.46, 0.22 * near)
	_marker_mat.emission_energy_multiplier = 2.4 * near
	_marker_puff.emitting = near > 0.05
	_marker.visible = near > 0.02


func marker_position() -> Vector3:
	return _marker_at


func marker_is_active() -> bool:
	return _marker_active and _marker.visible


# ===========================================================================
#  Journal / HUD interface
# ===========================================================================
func quest_title(qid: String) -> String:
	var q := QuestData.quest(qid)
	return q.title if q != null else ""


func quest_summary(qid: String) -> String:
	var q := QuestData.quest(qid)
	return q.summary if q != null else ""


func objective_text(qid: String, oid: String) -> String:
	var o := QuestData.objective_def(qid, oid)
	return o.description if o != null else ""


# ===========================================================================
#  Save / load
# ===========================================================================
func save_into(_gs: Node) -> void:
	GameState.set_flag("quest_spawned", _spawned.keys())


func load_from(_gs: Node) -> void:
	_spawned.clear()
	_spawn_ids.clear()
	# `Game.apply_state` rebuilds the enemy population from scratch, so a group that
	# was spawned for a step the player has NOT finished no longer exists in the
	# world. Forget it was ever spawned, or the ambush never comes back and the step
	# can never be completed. Only groups whose step is already done stay remembered.
	var keys: Variant = GameState.get_flag("quest_spawned", [])
	if keys is Array:
		for k in keys:
			var parts := String(k).split("/")
			if parts.size() == 2 and objective_done(parts[0], parts[1]):
				_spawned[String(k)] = true
	_focus = ""
	for qid in active_quests():
		_reveal(String(qid))
		_backfill(String(qid))
		_focus = String(qid)
	_sync_world()
	_update_marker(true)


## Put the world objects back the way the log says they should be — lit lamps, a
## pickup that has already been taken, a gate that is already open.
func _sync_world() -> void:
	if _interactables != null and is_instance_valid(_interactables) and _interactables.has_method("sync_from_state"):
		_interactables.call("sync_from_state")
