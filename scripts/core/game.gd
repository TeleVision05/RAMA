class_name Game
extends Node3D
## Assembles a running game: world, player, camera, and whatever content systems are
## present. Content systems are looked up by class so the game still boots while they
## are being built.

signal ready_to_play

var world: WorldRoot
var player: Player
var cam: PlayerCamera
var settlement: Node3D
var solids: SolidStreamer
var vegetation: Node3D
var water: Node3D
var vfx: Node3D
var wildlife: Node3D
var enemies: Node
var npcs: Node
var quests: Node
var interactables: Node3D
var hud: CanvasLayer

var quality_tier: int = Quality.Tier.HIGH
## Build the interface as part of the game. On by default: `scenes/game.tscn` is a
## real entry point and a game with no HUD is not a shippable one. Measurement
## harnesses that want the world without the interface can turn it off before the
## Game enters the tree.
var spawn_hud: bool = true
var _spawn: Vector3 = Vector3.ZERO
var _booted: bool = false


func _ready() -> void:
	boot()


func boot() -> void:
	world = WorldRoot.new()
	world.name = "World"
	add_child(world)
	world.build(true)

	_spawn = _find_spawn()

	player = Player.new()
	player.name = "Rama"
	add_child(player)
	player.global_position = _spawn
	player.set_world(world)
	player.facing_yaw = PI * 0.15

	cam = PlayerCamera.new()
	cam.name = "PlayerCamera"
	add_child(cam)
	cam.setup(player, world)
	player.cam_rig = cam
	world.set_focus(player)

	# Particle density must be set BEFORE the VFX system builds its emitters.
	WorldVFX.density = Quality.particle_density(quality_tier)
	_spawn_content()

	Quality.apply(quality_tier, get_viewport(), world.sky)
	# Static collision for trees and buildings. Nothing else in the world has any, so
	# without this the player walks through trunks and huts and the camera's spring arm
	# passes through a trunk that then hides Rama completely.
	solids = SolidStreamer.new()
	solids.name = "Solids"
	world.add_child(solids)
	solids.harvest(vegetation, settlement)
	solids.update_focus(player.global_position, true)
	print("[solids] %d colliders registered" % solids.solid_count())

	# Collapse the settlement's static decor into far fewer draw calls. This runs
	# AFTER the collider harvest, which reads per-mesh bounds as building footprints.
	if settlement:
		var t1 := Time.get_ticks_msec()
		var mg: Array = StaticMerge.merge(settlement)
		print("[merge] settlement %d -> %d draws in %d ms" % [mg[0], mg[1], Time.get_ticks_msec() - t1])

	# Quests need the player (for discovery zones and rewards) and the enemy director
	# (to spawn an ambush when an objective calls for one). Interactables need the
	# quest system to report what the player just used.
	if quests and quests.has_method("bind"):
		quests.bind(player, enemies)
	if interactables and interactables.has_method("bind"):
		interactables.bind(quests)
	if quests and hud_marker_sink() != null and quests.has_signal("marker_moved"):
		quests.marker_moved.connect(_on_marker_moved)

	AudioDirector.bind(world, world.sky, player)
	world.sky.set_time(GameState.time_of_day)
	world.sky.phase_changed.connect(_on_phase)

	# Before `player_spawned`, so the interface is listening when it fires. The HUD
	# re-applies the saved settings on top of the quality tier chosen above, which is
	# the order the player expects: their own choices are the last word.
	_spawn_ui()

	EventBus.player_died.connect(_on_player_died)
	EventBus.player_spawned.emit(player)
	_booted = true
	ready_to_play.emit()


## Spawn on the village road, on solid dry ground, facing the square.
func _find_spawn() -> Vector3:
	var base := Vector2(WorldMap.P_VILLAGE.x + 6.0, WorldMap.P_VILLAGE.y + 22.0)
	for r in range(0, 40, 2):
		for a in range(0, 12):
			var ang: float = TAU * float(a) / 12.0
			var p := base + Vector2(cos(ang), sin(ang)) * float(r)
			if not world.map.in_bounds(p.x, p.y):
				continue
			if world.map.water_depth_at(p.x, p.y) > 0.05:
				continue
			if world.map.slope_at(p.x, p.y) > 0.28:
				continue
			return Vector3(p.x, world.map.height_at(p.x, p.y) + 0.12, p.y)
	return Vector3(base.x, world.map.height_at(base.x, base.y) + 0.5, base.y)


## Instantiate the optional content systems if their classes exist.
func _spawn_content() -> void:
	water = _try_make("RiverWater")
	vegetation = _try_make("Vegetation")
	settlement = _try_make("Settlement")
	vfx = _try_make("WorldVFX")
	wildlife = _try_make("Wildlife")
	enemies = _try_make("EnemyDirector")
	npcs = _try_make("NPCDirector")
	quests = _try_make("QuestSystem")
	interactables = _try_make("Interactables")
	for n in [water, vegetation, settlement, vfx, wildlife, enemies, npcs, quests, interactables]:
		if n == null:
			continue
		world.add_child(n)
		if n.has_method("setup"):
			if n.get_script() and n.has_method("setup"):
				# WorldVFX wants the sky too.
				var argc: int = _arity(n, "setup")
				if argc >= 2:
					n.setup(world.map, world.sky)
				else:
					n.setup(world.map)


func _arity(n: Node, m: String) -> int:
	for d in n.get_method_list():
		if d.name == m:
			return d.args.size()
	return 1


## The interface. It is the one optional system that cannot come through `_try_make`:
## a HUD is a CanvasLayer, not a Node3D, and it belongs on the Game rather than inside
## the world so it never inherits the world's transform.
##
## A session assembled by `HUD.launch()` already owns a HUD next to the Game — adopt
## that one. Building a second gives the player two of every panel, two pause menus
## fighting over `get_tree().paused`, and two nodes writing `Input.mouse_mode`.
func _spawn_ui() -> void:
	if not spawn_hud:
		return
	if hud != null and is_instance_valid(hud):
		return
	hud = _existing_hud()
	if hud == null:
		var made := _make_node("HUD")
		if made == null:
			return  # the interface layer is not in this build
		if not (made is CanvasLayer):
			made.free()
			push_warning("[game] HUD exists but is not a CanvasLayer; not spawning it")
			return
		hud = made as CanvasLayer
		hud.name = "HUD"
		add_child(hud)
	if hud.has_method("setup"):
		hud.setup(self)


## A HUD that already exists in this session: a child of the Game, or a sibling under
## the Game's parent (which is how `HUD.launch` assembles one).
func _existing_hud() -> CanvasLayer:
	var pools: Array[Node] = [self]
	if get_parent() != null:
		pools.append(get_parent())
	for pool in pools:
		for c in pool.get_children():
			if _is_hud(c):
				return c as CanvasLayer
	return null


## Identify a HUD by its script's global name rather than by the type, so `core` keeps
## no compile-time dependency on the interface layer and still boots without it.
static func _is_hud(n: Node) -> bool:
	if not (n is CanvasLayer):
		return false
	var s: Script = n.get_script()
	return s is GDScript and String((s as GDScript).get_global_name()) == "HUD"


## `_try_make` for a system that is not a Node3D.
func _make_node(cls: String) -> Node:
	for e in ProjectSettings.get_global_class_list():
		if String(e.get("class", "")) != cls:
			continue
		var scr: Script = load(String(e["path"]))
		if scr == null:
			return null
		var inst: Variant = scr.new()
		if inst is Node:
			return inst as Node
		if inst is Object:
			(inst as Object).free()
		return null
	return null


func _try_make(cls: String) -> Node3D:
	if not ClassDB.class_exists(cls):
		# GDScript global classes are not in ClassDB; look them up in the class list.
		for e in ProjectSettings.get_global_class_list():
			if String(e.get("class", "")) == cls:
				var scr: Script = load(String(e["path"]))
				if scr:
					var inst: Variant = scr.new()
					if inst is Node3D:
						(inst as Node3D).name = cls
						return inst
					elif inst is Object:
						(inst as Object).free()
				return null
		return null
	return null


func _process(_delta: float) -> void:
	if not _booted:
		return
	GameState.time_of_day = world.sky.time_of_day
	# The HUD owns the quick-save keys whenever there is one: it consumes the event
	# and calls straight back into `save_game`. Polling them here as well wrote the
	# slot twice per press and raised two toasts for one save.
	if hud == null or not is_instance_valid(hud):
		if Input.is_action_just_pressed("quick_save"):
			save_game(0)
		elif Input.is_action_just_pressed("quick_load"):
			load_game(0)
	if Input.is_action_just_pressed("dev_screenshot"):
		DevCapture.snap("manual_%d" % Time.get_ticks_msec())
	elif Input.is_action_just_pressed("dev_time"):
		world.sky.set_time(fposmod(world.sky.time_of_day + 3.0, 24.0))
	var p := player.global_position
	# Every optional system with an `update_focus`, which is the contract in
	# ARCHITECTURE.md and already what `apply_state` does. The AI directors were
	# missing from this list and had each grown their own `get_nodes_in_group("player")`
	# to compensate — two sources of truth for the same number, and a measurement
	# harness that wants to drive the focus somewhere the player is not could not.
	for n in [vegetation, vfx, wildlife, water, enemies, npcs]:
		if n and n.has_method("update_focus"):
			n.update_focus(p)
	if solids:
		solids.update_focus(p)


func _on_phase(phase: String) -> void:
	EventBus.time_phase_changed.emit(phase)


# ===========================================================================
#  Save / load / death
# ===========================================================================
## Write the live world into GameState, then persist it.
func save_game(slot: int) -> bool:
	GameState.player_position = player.global_position
	GameState.player_yaw = player.facing_yaw
	GameState.time_of_day = world.sky.time_of_day
	if quests and quests.has_method("save_into"):
		quests.save_into(GameState)
	var ok := GameState.save_to_slot(slot)
	if ok:
		# `save_to_slot` raises `game_saved`, and the interface turns that into the
		# toast. Raising `notify` here as well produced "SAVED x2" on every save.
		AudioDirector.play_ui("ui_click")
	return ok


## Restore a slot into the LIVE world: position, time, and every system's state.
func load_game(slot: int) -> bool:
	if not GameState.load_from_slot(slot):
		EventBus.notify.emit("No save", "Slot %d is empty." % (slot + 1), "warn")
		return false
	# `load_from_slot` raises `game_loaded`; the interface owns the toast for it, the
	# same way it owns the one for a save.
	apply_state()
	return true


## Push GameState onto the running world. Called after a load and after a new game.
func apply_state() -> void:
	var p := GameState.player_position
	if p == Vector3.ZERO or not world.map.in_bounds(p.x, p.z):
		p = _spawn
	# Never trust a stored Y: the terrain generator may have changed under the save.
	p.y = maxf(p.y, world.map.height_at(p.x, p.z) + 0.1)
	player.global_position = p
	player.velocity = Vector3.ZERO
	player.facing_yaw = GameState.player_yaw
	player.rotation.y = GameState.player_yaw
	if player.is_dead():
		player.revive_at(p)
	if cam:
		cam.yaw = GameState.player_yaw
		cam.setup(player, world)
	world.sky.set_time(GameState.time_of_day)
	world.terrain.update_focus(p, true)
	for n in [vegetation, vfx, wildlife, water, enemies, npcs]:
		if n and n.has_method("update_focus"):
			n.update_focus(p)
	if quests and quests.has_method("load_from"):
		quests.load_from(GameState)
	if enemies and enemies.has_method("respawn_all"):
		enemies.respawn_all()


func new_game() -> void:
	GameState.reset()
	GameState.player_position = _spawn
	GameState.player_yaw = PI * 0.15
	apply_state()


## Death: fade, then wake at the last shrine or at the village.
func _on_player_died() -> void:
	await get_tree().create_timer(3.2).timeout
	# Shrines store the respawn point; a loaded save round-trips it through JSON as an
	# array, so accept either form.
	var stored: Variant = GameState.get_flag("respawn_point", _spawn)
	var respawn := _spawn
	if typeof(stored) == TYPE_ARRAY and (stored as Array).size() == 3:
		var a: Array = stored
		respawn = Vector3(a[0], a[1], a[2])
	elif typeof(stored) == TYPE_VECTOR3:
		respawn = stored
	if not world.map.in_bounds(respawn.x, respawn.z):
		respawn = _spawn
	respawn.y = world.map.height_at(respawn.x, respawn.z) + 0.15
	player.revive_at(respawn)
	world.terrain.update_focus(respawn, true)
	EventBus.notify.emit("You awaken", "Someone carried you back.", "info")


func set_quality(t: int) -> void:
	quality_tier = t
	if world and world.sky:
		Quality.apply(t, get_viewport(), world.sky)


## The HUD, if one exists, wants to know where the objective marker is.
func hud_marker_sink() -> Node:
	for n in get_tree().get_nodes_in_group("hud"):
		return n
	var p := get_parent()
	if p:
		return p.get_node_or_null("HUD")
	return null


func _on_marker_moved(pos: Vector3, active: bool) -> void:
	var h := hud_marker_sink()
	if h == null:
		return
	if active and h.has_method("set_objective_marker"):
		h.call("set_objective_marker", pos)
	elif not active and h.has_method("clear_objective_marker"):
		h.call("clear_objective_marker")


func spawn_point() -> Vector3:
	return _spawn
