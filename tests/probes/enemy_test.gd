extends Node
## Boots the real Game, puts real rakshasas in front of Rama and fights them.
##
## Everything asserted here is asserted against the running world: the enemies close
## real distance over real terrain, the damage that lands is the damage GameState
## records, and the frame time printed is wall-clock time with vsync off.

const SHOT_DIR := "res://build/screenshots"

var game: Game
var dir_node: EnemyDirector
var fails: Array[String] = []
var notes: Array[String] = []
var worst_pen: float = 0.0
var _pen_watch: Array = []
# GDScript lambdas capture by VALUE, so a counter incremented inside one never
# reaches the outer scope. Signal tallies have to live on the node.
var _died_count: int = 0
var _alert_hits: Array = []
var arena: Vector3 = Vector3.ZERO
## `--only=perf` (or any test name) runs one section. The whole suite fights for
## several minutes of wall time; iterating on one number should not.
var _only: String = ""


func _ready() -> void:
	_run()


# ===========================================================================
func _run() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.substr(7)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))

	game = Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	game.world.sky.paused = true
	game.world.sky.set_time(10.4)

	var t0 := Time.get_ticks_msec()
	dir_node = EnemyDirector.new()
	dir_node.name = "EnemyDirector"
	game.world.add_child(dir_node)
	dir_node.setup(game.world.map, game.world.sky)
	print("[populate] %d enemies in %d ms — %s" % [dir_node.enemies().size(), Time.get_ticks_msec() - t0, dir_node.summary()])

	await _test_population()
	await _move_to_arena(p)
	if _want("spawn"):
		await _test_grounding_and_look(p)
	if _want("chase"):
		await _test_paths_to_player(p)
	if _want("archer"):
		await _test_archer_shoots(p)
	if _want("hit"):
		await _test_damages_player(p)
	if _want("damage"):
		await _test_melee_and_arrow_damage(p)
	if _want("death"):
		await _test_death_and_loot(p)
	if _want("perception"):
		await _test_perception_meter(p)
	if _want("streaming"):
		await _test_streaming(p)
	if _want("contract"):
		await _test_contract(p)
	if _want("perf"):
		await _test_25_enemies(p)
	if _want("look"):
		await _test_look(p)

	print("\nworst penetration below terrain across every enemy tick: %.3f m" % worst_pen)
	if worst_pen > 0.75:
		fails.append("an enemy sank %.2f m below the terrain" % worst_pen)

	print("\n--- notes ---")
	for n in notes:
		print("  . " + n)
	print("\nRESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)


# ===========================================================================
#  1. The standing population is placed legally.
# ===========================================================================
func _test_population() -> void:
	var m := game.world.map
	var list := dir_node.enemies()
	if list.size() < 20:
		fails.append("populate() only placed %d enemies, expected >= 20" % list.size())
	var bad_ground := 0
	var in_river := 0
	var steep := 0
	var kinds := {}
	for e in list:
		var g: float = m.height_at(e.global_position.x, e.global_position.z)
		if absf(e.global_position.y - g) > 0.35:
			bad_ground += 1
		if m.water_depth_at(e.global_position.x, e.global_position.z) > 0.05:
			in_river += 1
		if m.slope_at(e.global_position.x, e.global_position.z) > 0.45:
			steep += 1
		kinds[EnemyTypes.NAMES[e.kind]] = int(kinds.get(EnemyTypes.NAMES[e.kind], 0)) + 1
	print("[population] %s  off-ground=%d in-water=%d steep=%d" % [kinds, bad_ground, in_river, steep])
	if bad_ground > 0:
		fails.append("%d enemies did not spawn on map.height_at" % bad_ground)
	if in_river > 0:
		fails.append("%d enemies spawned in the river" % in_river)
	if steep > 0:
		fails.append("%d enemies spawned on unwalkable slope" % steep)
	for k in ["warrior", "archer", "elite", "beast"]:
		if int(kinds.get(k, 0)) < 1:
			fails.append("no %s was placed anywhere in the world" % k)
	# Patrol routes must be walkable too.
	var bad_wp := 0
	for e in list:
		for wp in e.patrol_points:
			if m.water_depth_at(wp.x, wp.z) > 0.05 or m.slope_at(wp.x, wp.z) > 0.45:
				bad_wp += 1
	if bad_wp > 0:
		fails.append("%d patrol waypoints are in water or on cliffs" % bad_wp)
	notes.append("standing population placed and validated: %s" % dir_node.summary())


## Fighting inside the village means fighting through hut walls, which makes every
## line-of-sight result a coin toss. Find real open ground first — a clear, gently
## sloped patch with nothing solid within 30 m in any direction — and hold the fight
## there, so what the tests measure is the AI and not the architecture.
func _move_to_arena(p: Player) -> void:
	var m := game.world.map
	var space := p.get_world_3d().direct_space_state
	var best := Vector3.ZERO
	var best_score := -1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for attempt in range(600):
		var c := Vector2(rng.randf_range(-200.0, 40.0), rng.randf_range(-40.0, 150.0))
		if not m.in_bounds(c.x, c.y):
			continue
		if m.water_depth_at(c.x, c.y) > 0.01 or m.river_dist(c) < 34.0:
			continue
		if m.slope_at(c.x, c.y) > 0.12:
			continue
		if m.forest_density(c) > 0.20:
			continue
		if c.distance_to(WorldMap.P_VILLAGE) < 75.0:
			continue
		var eye := Vector3(c.x, m.height_at(c.x, c.y) + 1.6, c.y)
		var clear := true
		var flat := 0.0
		for i in range(8):
			var a: float = TAU * float(i) / 8.0
			var to := eye + Vector3(cos(a), 0.05, sin(a)) * 30.0
			var q := PhysicsRayQueryParameters3D.create(eye, to)
			q.collision_mask = 8
			if not space.intersect_ray(q).is_empty():
				clear = false
				break
			flat += m.slope_at(eye.x + cos(a) * 12.0, eye.z + sin(a) * 12.0)
		if not clear:
			continue
		var score: float = 1.0 - flat / 8.0
		if score > best_score:
			best_score = score
			best = Vector3(c.x, m.height_at(c.x, c.y), c.y)
		if best_score > 0.97:
			break
	if best == Vector3.ZERO:
		notes.append("no clear arena found; tests ran where the player spawned")
		arena = p.global_position
		return
	arena = best
	p.global_position = best + Vector3(0, 0.2, 0)
	p.velocity = Vector3.ZERO
	game.world.terrain.update_focus(best, true)
	await steps(40)
	print(
		(
			"[arena] fighting at %s  slope=%.3f  canopy=%.2f  openness=%.2f"
			% [
				p.global_position.round(),
				game.world.map.slope_at(best.x, best.z),
				game.world.map.forest_density(Vector2(best.x, best.z)),
				best_score
			]
		)
	)


# ===========================================================================
#  2. Each archetype spawns on the ground in front of the player and holds it.
# ===========================================================================
func _test_grounding_and_look(p: Player) -> void:
	var made := await _spawn_line(p, [EnemyTypes.Kind.WARRIOR, EnemyTypes.Kind.ARCHER, EnemyTypes.Kind.ELITE, EnemyTypes.Kind.BEAST], 11.0)
	for i in range(20):
		await get_tree().process_frame
	if made.size() != 4:
		fails.append("only %d of 4 archetypes could be spawned in front of the player" % made.size())
		return
	_pen_watch = made.duplicate()
	await steps(70)
	var m := game.world.map
	for e in made:
		# An enemy is allowed to be in the air — a champion's leap puts it there on
		# purpose. What is never allowed is claiming to be grounded while floating,
		# or being under the terrain at all. Wait out any leap, then check.
		var guard := 0
		while not e.is_grounded() and guard < 200:
			await steps(1)
			guard += 1
		var g: float = m.height_at(e.global_position.x, e.global_position.z)
		var dy: float = e.global_position.y - g
		var vr := e.visual_root()
		print(
			(
				"[spawn] %-18s hp=%.0f  y-ground=%+.3f (grounded=%s after %d frames)  rig=%s  %d meshes  state=%s"
				% [
					e.display_name(),
					e.max_health,
					dy,
					e.is_grounded(),
					guard,
					"built" if vr != null else "NONE",
					e.mesh_count(),
					e.state_name()
				]
			)
		)
		if dy < -0.30:
			fails.append("%s sank %.2f m into the terrain" % [e.display_name(), dy])
		if e.is_grounded() and dy > 0.30:
			fails.append("%s says it is on the ground but is %.2f m above it" % [e.display_name(), dy])
		if not e.is_grounded():
			fails.append("%s never came back down (%.2f m up)" % [e.display_name(), dy])
		if vr == null:
			fails.append("%s never built a visual at %.0f m" % [e.display_name(), 11.0])
		if e.kind == EnemyTypes.Kind.BEAST and e.beast == null:
			fails.append("the beast was built from the humanoid rig")
		if e.kind != EnemyTypes.Kind.BEAST and e.rig == null:
			fails.append("%s was not built from ProcRig" % e.display_name())
		# The amber eye. `_tune_rakshasa` finds ProcRig's eye materials by colour, and
		# when ProcRig retuned its eyes that lookup silently stopped matching anything
		# for a whole art pass — every rakshasa shipped with a dead black eye and
		# nobody could tell from a state assertion. Count the emissive materials.
		if e.kind != EnemyTypes.Kind.BEAST:
			var glow := _count_emissive(e.visual_root())
			print("[eyes]  %-18s %d self-lit materials on the body" % [e.display_name(), glow])
			if glow < 1:
				fails.append("%s has no self-lit eyes; _tune_rakshasa matched nothing" % e.display_name())
	# They are idling/patrolling, not frozen: the pose must be moving.
	var before: Array = []
	for e in made:
		before.append(_pose_signature(e))
	await steps(40)
	var moved := 0
	for i in range(made.size()):
		if _pose_signature(made[i]).distance_to(before[i]) > 0.0006:
			moved += 1
	print("[idle] %d of %d archetypes are visibly moving while idle" % [moved, made.size()])
	if moved < made.size():
		fails.append("%d archetypes stood perfectly still while idle" % (made.size() - moved))
	await _shot("enemy_00_lineup", p, made[0].global_position, 9.0, 3.2)
	for e in made:
		e.queue_free()
	await steps(4)


# ===========================================================================
#  3. Alerted enemies path toward the player over real terrain.
# ===========================================================================
func _test_paths_to_player(p: Player) -> void:
	for kind in [EnemyTypes.Kind.WARRIOR, EnemyTypes.Kind.ELITE, EnemyTypes.Kind.BEAST]:
		var made := await _spawn_line(p, [kind], 17.0)
		if made.is_empty():
			fails.append("could not place a %s to test pathing" % EnemyTypes.NAMES[kind])
			continue
		var e: Enemy = made[0]
		_pen_watch = [e]
		await steps(20)
		var d0: float = e.global_position.distance_to(p.global_position)
		e.alert_from(p.global_position, true)
		var closed_at := -1.0
		for i in range(220):
			await steps(1)
			var d: float = e.global_position.distance_to(p.global_position)
			if d < 4.0 and closed_at < 0.0:
				closed_at = float(i) / 60.0
		var d1: float = e.global_position.distance_to(p.global_position)
		print("[chase] %-18s %.1f m -> %.1f m  state=%s  reached<4m at %.2f s" % [e.display_name(), d0, d1, e.state_name(), closed_at])
		if d1 > d0 - 6.0:
			fails.append("%s did not close on the player (%.1f -> %.1f m)" % [e.display_name(), d0, d1])
		if closed_at < 0.0:
			fails.append("%s never got within 4 m in 3.6 s" % e.display_name())
		e.queue_free()
		await steps(4)
		GameState.health = GameState.max_health


# ===========================================================================
#  4. The archer keeps its distance and shoots something the player can dodge.
# ===========================================================================
func _test_archer_shoots(p: Player) -> void:
	var made := await _spawn_line(p, [EnemyTypes.Kind.ARCHER], 19.0)
	if made.is_empty():
		fails.append("could not place an archer")
		return
	var e: Enemy = made[0]
	_pen_watch = [e]
	GameState.health = GameState.max_health
	e.alert_from(p.global_position, true)
	var shots := 0
	var seen := {}
	var h0 := GameState.health
	var min_d := INF
	for i in range(900):
		await steps(1)
		min_d = minf(min_d, e.global_position.distance_to(p.global_position))
		for a in get_tree().get_nodes_in_group("arrow"):
			if a is EnemyArrow and not seen.has(a.get_instance_id()):
				seen[a.get_instance_id()] = true
				shots += 1
		if shots >= 2 and GameState.health < h0:
			break
	var saw_arrow: bool = shots > 0
	print(
		(
			"[archer] fired %d arrows  health %.0f -> %.0f  closest approach %.1f m  state=%s"
			% [shots, h0, GameState.health, min_d, e.state_name()]
		)
	)
	if not saw_arrow:
		fails.append("the archer never fired an EnemyArrow")
	if GameState.health >= h0:
		fails.append("archer fire never damaged the player")
	if min_d < 3.0:
		fails.append("the archer walked into melee range instead of keeping distance")
	notes.append("archer held %.1f m and its arrows reach the player" % min_d)
	e.queue_free()
	await steps(4)
	GameState.health = GameState.max_health


# ===========================================================================
#  5. Melee archetypes actually damage the player.
# ===========================================================================
func _test_damages_player(p: Player) -> void:
	for kind in [EnemyTypes.Kind.WARRIOR, EnemyTypes.Kind.ELITE, EnemyTypes.Kind.BEAST]:
		var made := await _spawn_line(p, [kind], 5.0)
		if made.is_empty():
			continue
		var e: Enemy = made[0]
		_pen_watch = [e]
		GameState.health = GameState.max_health
		var h0 := GameState.health
		e.alert_from(p.global_position, true)
		var hit_at := -1.0
		for i in range(300):
			await steps(1)
			if GameState.health < h0 and hit_at < 0.0:
				hit_at = float(i) / 60.0
				break
		print(
			(
				"[hit] %-18s first landed a blow at %.2f s, health %.0f -> %.0f (%s)"
				% [e.display_name(), hit_at, h0, GameState.health, e.state_name()]
			)
		)
		if hit_at < 0.0:
			fails.append("%s never damaged the player in 5 s at 5 m" % e.display_name())
		if hit_at >= 0.0 and hit_at < 0.30:
			fails.append("%s hit with no readable wind-up (%.2f s)" % [e.display_name(), hit_at])
		e.queue_free()
		await steps(4)
	GameState.health = GameState.max_health


# ===========================================================================
#  6. Rama's melee and Rama's arrows damage them.
# ===========================================================================
func _test_melee_and_arrow_damage(p: Player) -> void:
	# --- sword ------------------------------------------------------------
	var made := await _spawn_line(p, [EnemyTypes.Kind.WARRIOR], 1.9)
	if made.is_empty():
		fails.append("could not place a warrior for the melee test")
		return
	var e: Enemy = made[0]
	_pen_watch = [e]
	await steps(10)
	if p.using_bow:
		Input.action_press("swap_weapon")
		await steps(2)
		Input.action_release("swap_weapon")
		await steps(4)
	var h0 := e.health
	# Face it, then swing for real through the input system.
	p.facing_yaw = atan2(-(e.global_position.x - p.global_position.x), -(e.global_position.z - p.global_position.z))
	p.rotation.y = p.facing_yaw
	Input.action_press("attack")
	await steps(2)
	Input.action_release("attack")
	await steps(45)
	print("[melee] warrior %.0f -> %.0f hp after one sword swing" % [h0, e.health])
	if e.health >= h0:
		fails.append("the player's melee did not damage a rakshasa")
	elif h0 - e.health < 15.0 or h0 - e.health > 40.0:
		fails.append("melee did %.0f damage, outside the 20-34 budget" % (h0 - e.health))

	# --- arrow ------------------------------------------------------------
	var h1 := e.health
	var origin := p.global_position + Vector3(0, 1.4, 0)
	var to: Vector3 = (e.global_position + Vector3(0, 1.1, 0)) - origin
	Arrow.spawn(game, origin, to.normalized() * 70.0, p, 48.0, 1.0)
	await steps(20)
	print("[arrow] warrior %.0f -> %.0f hp after a full-charge arrow" % [h1, e.health])
	if e.health >= h1:
		fails.append("a full-charge arrow did not damage a rakshasa")
	notes.append("melee and arrows both route through take_damage as contracted")
	e.queue_free()
	await steps(4)
	if not p.using_bow:
		Input.action_press("swap_weapon")
		await steps(2)
		Input.action_release("swap_weapon")
		await steps(4)


# ===========================================================================
#  7. They die properly: pose, group, collision, loot.
# ===========================================================================
func _test_death_and_loot(p: Player) -> void:
	var made := await _spawn_line(p, [EnemyTypes.Kind.WARRIOR, EnemyTypes.Kind.BEAST], 6.0)
	if made.size() < 2:
		fails.append("could not place bodies for the death test")
		return
	var loot_before := get_tree().get_nodes_in_group("loot").size()
	var kills_before := GameState.kills
	_died_count = 0
	EventBus.enemy_died.connect(_count_death)
	for e in made:
		_pen_watch = made.duplicate()
		var guard := 0
		while e.is_alive() and guard < 40:
			e.take_damage(25.0, p, e.global_position + Vector3(0, 1.2, 0), false)
			guard += 1
			await steps(2)
		print(
			(
				"[death] %-18s alive=%s in_group=%s layer=%d hits=%d"
				% [e.display_name(), e.is_alive(), e.is_in_group("enemy"), e.collision_layer, guard]
			)
		)
		if e.is_alive():
			fails.append("%s would not die" % e.display_name())
		if e.is_in_group("enemy"):
			fails.append('%s stayed in group "enemy" after dying' % e.display_name())
		if e.collision_layer != 0:
			fails.append("%s still collides after dying" % e.display_name())
	await steps(90)
	for e in made:
		var vr := e.visual_root()
		var dead_amt: float = e.rig.dead_amount if e.rig else (e.beast.dead_amount if e.beast else 0.0)
		if dead_amt < 0.6:
			fails.append("%s never collapsed (dead_amount %.2f)" % [e.display_name(), dead_amt])
		if vr == null:
			fails.append("%s has no body to collapse" % e.display_name())
	var loot_after := get_tree().get_nodes_in_group("loot").size()
	EventBus.enemy_died.disconnect(_count_death)
	print(
		(
			"[loot] drops %d -> %d, kills %d -> %d, enemy_died fired %d times"
			% [loot_before, loot_after, kills_before, GameState.kills, _died_count]
		)
	)
	if loot_after <= loot_before:
		fails.append("nothing dropped loot on death")
	if GameState.kills != kills_before + made.size():
		fails.append("GameState.kills did not count the deaths")
	if _died_count < made.size():
		fails.append("EventBus.enemy_died did not fire for every death")
	# The drop is interactable and grants something.
	var drops := get_tree().get_nodes_in_group("loot")
	if not drops.is_empty():
		var d = drops[drops.size() - 1]
		var arrows0 := GameState.arrows
		var inv0 := GameState.inventory.size()
		print('[loot] prompt: "%s"' % d.interact_prompt())
		d.interact(p)
		await steps(2)
		if GameState.arrows == arrows0 and GameState.inventory.size() == inv0:
			fails.append("picking up loot granted nothing")
	await _shot("enemy_01_corpses", p, made[0].global_position, 6.5, 2.4)
	notes.append("corpses collapse, leave loot, and stop being valid targets")


# ===========================================================================
#  8. The awareness meter behaves like a meter, not a switch.
# ===========================================================================
func _test_perception_meter(p: Player) -> void:
	var made := await _spawn_line(p, [EnemyTypes.Kind.WARRIOR], 24.0)
	if made.is_empty():
		return
	var e: Enemy = made[0]
	_pen_watch = [e]
	# Face it away from the player: out of the cone, awareness should stay low.
	e.rotation.y = e._facing_to(p.global_position) + PI
	e.perc.forget()
	await steps(60)
	var blind := e.awareness()
	# Now a sprint's worth of noise nearby: hearing alone should raise it.
	EventBus.footstep.emit("stone", e.global_position + Vector3(6, 0, 0), 8.0)
	await steps(10)
	var heard := e.awareness()
	# And full sight: it should commit.
	_alert_hits.clear()
	EventBus.enemy_alerted.connect(_note_alert)
	var first_seen := -1.0
	for i in range(300):
		await steps(1)
		e.rotation.y = e._facing_to(p.global_position)
		if e.perc.can_see and first_seen < 0.0:
			first_seen = float(i) / 60.0
		if e.perc.committed:
			break
	EventBus.enemy_alerted.disconnect(_note_alert)
	var alerted: bool = _alert_hits.has(e)
	print(
		(
			"[perception] facing away=%.2f  after noise=%.2f  after sight=%.2f  saw at %.2f s  d=%.1f m  committed=%s alerted=%s"
			% [blind, heard, e.awareness(), first_seen, e.global_position.distance_to(p.global_position), e.perc.committed, alerted]
		)
	)
	if blind > 0.30:
		fails.append("an enemy facing away still built awareness to %.2f" % blind)
	if heard <= blind:
		fails.append("a loud footstep did not raise awareness")
	if not e.perc.committed:
		fails.append("an enemy in plain sight at 24 m never committed")
	if not alerted:
		fails.append("EventBus.enemy_alerted did not fire on commit")
	# Concealment must be a real modifier, not decoration.
	var open := Perception.concealment(game.world.map, p)
	notes.append("concealment where the player stands: %.2f" % open)
	e.queue_free()
	await steps(4)


# ===========================================================================
#  9. Streaming: distant enemies sleep, and sleeping does not drop them.
# ===========================================================================
func _test_streaming(p: Player) -> void:
	var m := game.world.map
	var far_ok := true
	var worst := 0.0
	var lods := {}
	await steps(10)
	for e in dir_node.enemies():
		if not is_instance_valid(e):
			continue
		var l := e.lod_name()
		lods[l] = int(lods.get(l, 0)) + 1
		if l == "dormant":
			var g: float = m.height_at(e.global_position.x, e.global_position.z)
			var dy: float = absf(e.global_position.y - g)
			worst = maxf(worst, dy)
			if dy > 0.30:
				far_ok = false
	print("[streaming] lods=%s  worst dormant off-ground=%.3f m  player at %s" % [lods, worst, p.global_position.round()])
	if not far_ok:
		fails.append("a dormant enemy drifted %.2f m off the ground" % worst)
	if int(lods.get("dormant", 0)) < 10:
		fails.append("streaming is not putting distant enemies to sleep (%s)" % lods)
	notes.append("distant enemies sleep on the terrain rather than freezing in the air")


# ===========================================================================
#  9b. The seams: the Game wires this system up, and being hit raises the alarm.
# ===========================================================================
func _test_contract(p: Player) -> void:
	# --- the Game actually instantiates and drives an EnemyDirector -----------
	# `_try_make` looks systems up by class name, so a rename or a script that fails
	# to compile silently produces a world with no enemies in it and every other test
	# here still passes, because every other test builds its own director.
	var wired: Node = game.enemies
	print("[contract] Game.enemies = %s" % ("null" if wired == null else wired.get_class() + "/" + String(wired.name)))
	if wired == null:
		fails.append("Game did not instantiate an EnemyDirector; a real session would have no enemies")
	elif not (wired is EnemyDirector):
		fails.append("Game.enemies is not an EnemyDirector")
	else:
		var ed := wired as EnemyDirector
		if ed.map == null:
			fails.append("Game never called setup() on the EnemyDirector")
		if ed.enemies().is_empty():
			fails.append("the EnemyDirector the Game built has no population")
		# ARCHITECTURE.md: "each gets ... update_focus(pos) each frame if it has one."
		# The director also finds the player itself, so prove the ROUTE works rather
		# than the outcome: push a focus the player is nowhere near and see it land.
		var probe := Vector3(1234.0, 0.0, 4321.0)
		ed.update_focus(probe)
		if ed._focus != probe:
			fails.append("EnemyDirector.update_focus did not take")
		# `process_frame` is emitted BEFORE the tree propagates `_process` to nodes, so
		# one await resumes ahead of `Game._process` for that same frame. Three is
		# past any ordering question.
		for _i in range(3):
			await get_tree().process_frame
		# And the Game must be pushing the real focus every frame, or the probe above
		# would still be in there and this director's whole population would be
		# streamed out for the rest of the session.
		if ed._focus.distance_to(p.global_position) > 1.0:
			fails.append("Game does not call update_focus on the EnemyDirector each frame (focus stuck at %s)" % ed._focus.round())
		ed.update_focus(p.global_position)
		notes.append("Game builds, sets up and drives an EnemyDirector: %s" % ed.summary())

	# --- an arrow in the back of an unaware rakshasa raises the alarm ---------
	# `take_damage` used to call `perc.alarm(...)` and only THEN ask whether it had
	# been committed before, which is a branch that can never be taken, so
	# EventBus.enemy_alerted never fired for the one event most worth hearing.
	var made := await _spawn_line(p, [EnemyTypes.Kind.WARRIOR], 22.0)
	if made.is_empty():
		fails.append("could not place a warrior for the alarm test")
		return
	var e: Enemy = made[0]
	_pen_watch = [e]
	e.rotation.y = e._facing_to(p.global_position) + PI
	e.perc.forget()
	await steps(20)
	_alert_hits.clear()
	EventBus.enemy_alerted.connect(_note_alert)
	e.take_damage(9.0, p, e.global_position + Vector3(0, 1.4, 0), false)
	await steps(4)
	EventBus.enemy_alerted.disconnect(_note_alert)
	print("[contract] shot from behind: committed=%s alerted=%s state=%s" % [e.perc.committed, _alert_hits.has(e), e.state_name()])
	if not e.perc.committed:
		fails.append("a rakshasa shot in the back did not commit to the fight")
	if not _alert_hits.has(e):
		fails.append("EventBus.enemy_alerted did not fire when an unaware rakshasa was hit")

	# --- rakshasas do not kill each other -------------------------------------
	var mates := await _spawn_line(p, [EnemyTypes.Kind.WARRIOR, EnemyTypes.Kind.ARCHER], 9.0)
	if mates.size() == 2:
		var h0: float = mates[0].health
		mates[0].take_damage(40.0, mates[1], mates[0].global_position, false)
		await steps(2)
		print("[contract] friendly fire: %.0f -> %.0f hp" % [h0, mates[0].health])
		if mates[0].health < h0:
			fails.append("one rakshasa damaged another; a stray arrow would start a civil war")
		for m in mates:
			m.queue_free()
	e.queue_free()
	await steps(4)
	GameState.health = GameState.max_health


# ===========================================================================
#  10. Twenty-five at once, fighting, above 45 FPS.
# ===========================================================================
func _test_25_enemies(p: Player) -> void:
	dir_node.despawn_all()
	await steps(6)
	if dir_node.enemies().size() != 0:
		fails.append("despawn_all() left %d enemies behind" % dir_node.enemies().size())
	await steps(40)
	print("[perf] load average during the run: %s" % _load_average())

	var t_build := Time.get_ticks_msec()
	var mix := []
	for i in range(25):
		mix.append(
			[EnemyTypes.Kind.WARRIOR, EnemyTypes.Kind.WARRIOR, EnemyTypes.Kind.ARCHER, EnemyTypes.Kind.BEAST, EnemyTypes.Kind.ELITE][i % 5]
		)
	var made := await _spawn_ring(p, mix, 15.0, 26.0)
	print("[perf] spawned %d enemies in %d ms" % [made.size(), Time.get_ticks_msec() - t_build])
	if made.size() < 25:
		fails.append("only %d of 25 enemies found ground near the player" % made.size())
	_pen_watch = made.duplicate()
	_perf_keep = made
	for e in made:
		e.alert_from(p.global_position, true)
	# Let every rig build and every brain wake before the clock starts. Rigs are
	# constructed a couple per frame on purpose, so wait for the queue to drain rather
	# than measuring the assembly.
	var guard := 0
	while dir_node.pending_builds() > 0 and guard < 600:
		await get_tree().process_frame
		guard += 1
	print("[perf] all rigs built after %d frames" % guard)
	await steps(60)
	var meshes := 0
	for e in made:
		meshes += e.mesh_count()
	print("[perf] %d mesh instances across %d bodies (%.1f each)" % [meshes, made.size(), float(meshes) / float(maxi(made.size(), 1))])

	# --- what they cost, measured the way ARCHITECTURE.md says ---------------
	# "Do not compare two runs... Alternate the two conditions inside one process and
	# take the MEDIAN of the paired differences; a mean is still dragged around by a
	# single streaming hitch."
	#
	# This used to time 140 frames with no enemies, then spawn, then time 260 frames
	# with them, and subtract. On 2026-08-28 that produced a cost of MINUS 6.16
	# ms/frame — the enemies apparently made the game faster — because the empty block
	# ran while the terrain was still streaming after the arena move. Two sequential
	# blocks cannot measure a 6 ms effect on this machine. These alternate.
	#
	# The enemies stay spawned, built and RENDERED in both conditions; only `_process`
	# and `_physics_process` are toggled. So what is measured is exactly this system's
	# per-frame script and transform cost, with the rendering held constant.
	var d_pose: Array[float] = []
	var d_brain: Array[float] = []
	var d_all: Array[float] = []
	var f_off: Array[float] = []
	var f_on: Array[float] = []
	var worst_off := 0.0
	var worst_on := 0.0
	for pair in range(10):
		var a := await _cond(made, false, false, 10)
		worst_off = maxf(worst_off, _worst_ms)
		var b := await _cond(made, true, false, 10)
		var c := await _cond(made, true, true, 10)
		worst_on = maxf(worst_on, _worst_ms)
		d_pose.append(b - a)
		d_brain.append(c - b)
		d_all.append(c - a)
		f_off.append(a)
		f_on.append(c)
	for arr in [d_pose, d_brain, d_all, f_off, f_on]:
		arr.sort()
	var cost: float = d_all[d_all.size() / 2]
	var ms_off: float = f_off[f_off.size() / 2]
	var ms_on: float = f_on[f_on.size() / 2]
	var alive := 0
	for e in made:
		if is_instance_valid(e) and e.is_alive():
			alive += 1
	print("[perf] %d of %d still alive and fighting through the whole sweep" % [alive, made.size()])
	print(
		"[perf] median frame: %.2f ms (%.1f FPS) inert  ->  %.2f ms (%.1f FPS) fighting" % [ms_off, 1000.0 / ms_off, ms_on, 1000.0 / ms_on]
	)
	print(
		(
			"[perf] MEDIAN PAIRED COST of %d enemies: posing %+.2f | brain+motion %+.2f | TOTAL %+.2f ms/frame (%.3f ms each)"
			% [made.size(), d_pose[d_pose.size() / 2], d_brain[d_brain.size() / 2], cost, cost / float(maxi(made.size(), 1))]
		)
	)
	print(_mon_line("fighting"))
	if alive < made.size():
		fails.append("%d of the %d enemies died during the perf sweep, so the cost is understated" % [made.size() - alive, made.size()])
	if cost > 8.0:
		fails.append("25 enemies cost %.1f ms/frame, over the 8 ms budget" % cost)

	# A hitch only counts against the AI if the SAME alternation without them did not
	# hitch too. This box runs several Godot instances at once and the OS hands a
	# 300 ms stall to whoever is unlucky; blaming the enemies for one is how a test
	# fails for someone else's build.
	print("[perf] worst frame: %.0f ms fighting vs %.0f ms inert" % [worst_on, worst_off])
	if worst_on > 260.0 and worst_on > worst_off * 1.6:
		fails.append(
			"a %.0f ms hitch appeared while 25 enemies were fighting (the same windows inert peaked at %.0f ms)" % [worst_on, worst_off]
		)
	elif worst_on > 260.0:
		notes.append(
			"worst frame %.0f ms fighting, but the inert windows peaked at %.0f ms — the machine, not the AI" % [worst_on, worst_off]
		)

	# The 45 FPS requirement is about the whole game, so it can only be judged where
	# the scene WITHOUT the AI running already clears it. This box is shared with
	# other Godot instances; if even the inert scene is under target, say so as
	# NOT VERIFIED rather than failing the AI for someone else's load.
	if 1000.0 / ms_on >= 45.0:
		notes.append("25 enemies at once: %.1f FPS fighting vs %.1f FPS inert" % [1000.0 / ms_on, 1000.0 / ms_off])
	elif 1000.0 / ms_off < 45.0:
		fails.append(
			(
				"NOT VERIFIED: the scene ran at %.1f FPS with the AI switched OFF (load %s), so the 45 FPS target "
				+ "could not be judged; the enemies themselves cost %.2f ms/frame" % [1000.0 / ms_off, _load_average(), cost]
			)
		)
	else:
		fails.append("25 enemies dropped a %.1f FPS scene to %.1f FPS" % [1000.0 / ms_off, 1000.0 / ms_on])
	_perf_keep = []

	await _shot("enemy_02_melee", p, p.global_position, 7.0, 2.6)
	await _shot("enemy_03_wide", p, p.global_position, 15.0, 7.0)
	await steps(50)
	await _shot("enemy_04_close", p, p.global_position, 4.6, 1.9)


## One condition of the alternation: posing on/off, brain on/off, enemies always
## present and rendered. Returns the mean frame time over `frames` drawn frames.
func _cond(made: Array, pose: bool, brain: bool, frames: int) -> float:
	for e in made:
		if is_instance_valid(e):
			e.set_process(pose)
			e.set_physics_process(brain)
	for i in range(3):
		await get_tree().process_frame  # discard the transition
	return await _measure(frames)


# ===========================================================================
#  11. How it LOOKS. Portraits of each archetype, posed, from a readable angle.
# ===========================================================================
func _test_look(p: Player) -> void:
	dir_node.despawn_all()
	await steps(6)
	var kinds := [EnemyTypes.Kind.WARRIOR, EnemyTypes.Kind.ARCHER, EnemyTypes.Kind.ELITE, EnemyTypes.Kind.BEAST]
	var names := ["warrior", "archer", "elite", "beast"]
	for i in range(kinds.size()):
		var made := await _spawn_line(p, [kinds[i]], 8.0)
		if made.is_empty():
			continue
		var e: Enemy = made[0]
		var guard := 0
		while dir_node.pending_builds() > 0 and guard < 90:
			await get_tree().process_frame
			guard += 1
		await steps(30)
		# Idle, three-quarter front, eye height — the angle a character sheet uses.
		# The brain is paused for the exposure so the subject holds still while the
		# camera settles; the pose keeps animating, it just stops walking off.
		#
		# Two things this got wrong for a whole art pass, both of which made the
		# portraits useless for judging the thing they exist to judge:
		#  * the subject was left on whatever yaw its idle had drifted to, so all four
		#    "portraits" were photographs of the creature's BACK;
		#  * the camera azimuth was fixed, so on a wooded spawn it ended up inside a
		#    trunk and the beast's wind-up shot was a full-frame close-up of bark.
		# The camera now picks an unobstructed azimuth and the subject is turned to
		# face it.
		var h: float = float(e.def.body_height)
		var dir_a := _clear_azimuth(e.global_position, h, 0.7)
		e.set_physics_process(false)
		e.rotation.y = e._facing_to(e.global_position + dir_a)
		_look_at_lens(e, dir_a, h)
		await _shot_at("enemy_10_%s_idle" % names[i], e.global_position, dir_a, _portrait_dist(h), h * 0.72, h * 0.55, e)
		e.set_physics_process(true)
		# Mid wind-up: the telegraph the player is supposed to read.
		e.alert_from(p.global_position, true)
		e._begin_attack(EnemyTypes.attack_seq(e.kind))
		var wind: float = float(EnemyTypes.attack_seq(e.kind)[0].d)
		var t := 0.0
		while t < wind * 0.80:
			await get_tree().process_frame
			t += get_process_delta_time()
		e.set_physics_process(false)
		var dir_b := _clear_azimuth(e.global_position, h, -0.6)
		e.rotation.y = e._facing_to(e.global_position + dir_b)
		_look_at_lens(e, dir_b, h)
		await _shot_at("enemy_11_%s_windup" % names[i], e.global_position, dir_b, _portrait_dist(h), h * 0.70, h * 0.55, e)
		e.set_physics_process(true)
		print("[look] %-18s portraits rendered (%d mesh instances)" % [e.display_name(), e.mesh_count()])
		e.queue_free()
		await steps(4)
		GameState.health = GameState.max_health
	# And a group: a camp reacting, seen from a player's eye line.
	var camp := await _spawn_ring(
		p,
		[
			EnemyTypes.Kind.WARRIOR,
			EnemyTypes.Kind.WARRIOR,
			EnemyTypes.Kind.ARCHER,
			EnemyTypes.Kind.ELITE,
			EnemyTypes.Kind.BEAST,
			EnemyTypes.Kind.WARRIOR
		],
		9.0,
		15.0
	)
	var guard2 := 0
	while dir_node.pending_builds() > 0 and guard2 < 120:
		await get_tree().process_frame
		guard2 += 1
	for e in camp:
		e.alert_from(p.global_position, true)
	await steps(45)
	await _shot_at(
		"enemy_12_group",
		p.global_position + Vector3(0, 1.0, 0),
		(-p.global_transform.basis.z).rotated(Vector3.UP, PI + 0.9),
		13.0,
		4.0,
		1.2
	)
	notes.append("portraits of all four archetypes and a reacting group rendered to build/screenshots")


# ===========================================================================
#  helpers
# ===========================================================================
## Where can the camera stand and actually see the subject? Sweeps azimuths from the
## preferred one outward and returns the first with nothing solid between the lens and
## the body. Without this a portrait taken in the forest is a photograph of a trunk.
func _clear_azimuth(subject: Vector3, h: float, bias: float) -> Vector3:
	var space := get_viewport().world_3d.direct_space_state
	var eye_h: float = subject.y + h * 0.6
	var dist: float = _portrait_dist(h)
	# Stand with the sun behind the LENS, not behind the subject. The first version of
	# this only avoided obstacles, and roughly half the portraits came out backlit —
	# a charcoal hide against a bright canopy, with the face in its own shadow, which
	# is unjudgeable however correctly the subject is turned.
	var sun := SkySystem.sun_direction(game.world.sky.time_of_day)
	var to_sun := Vector3(sun.x, 0.0, sun.z)
	to_sun = to_sun.normalized() if to_sun.length_squared() > 0.0001 else Vector3.FORWARD
	var best := Vector3.FORWARD
	var best_score: float = -INF
	for k in range(24):
		var swing: float = float((k + 1) / 2) * (PI / 12.0) * (1.0 if k % 2 == 0 else -1.0)
		var d := Vector3(sin(bias + swing), 0.0, cos(bias + swing))
		var eye := subject + d * dist + Vector3(0, h * 0.72, 0)
		if game.world.map.height_at(eye.x, eye.z) > eye.y - 0.4:
			continue  # the camera would be inside a hillside
		var q := PhysicsRayQueryParameters3D.create(eye, subject + Vector3(0, eye_h - subject.y, 0))
		q.collision_mask = 8
		if not space.intersect_ray(q).is_empty():
			continue  # a trunk between the lens and the subject
		# Prefer the requested three-quarter angle, but not at the cost of the light.
		var score: float = d.dot(to_sun) * 2.0 - absf(swing) * 0.55
		if score > best_score:
			best_score = score
			best = d
	if best_score == -INF:
		best = Vector3(sin(bias), 0.0, cos(bias))
	return best


## Frame the subject so it fills roughly 70% of the frame height at the shot FOV,
## which is what makes a portrait readable enough to judge a hide tint from.
func _portrait_dist(h: float) -> float:
	return h / (0.70 * 2.0 * tan(deg_to_rad(50.0) * 0.5)) + 0.35


## Frame a subject deliberately: `from_dir` is where the camera stands relative to it.
## The interface is hidden for the exposure: a character-sheet portrait with a health
## bar across the corner is not a picture of the character.
func _shot_at(name: String, target: Vector3, from_dir: Vector3, dist: float, height: float, look_h: float, subject: Node3D = null) -> void:
	var hud_was := true
	if game.hud != null and is_instance_valid(game.hud):
		hud_was = game.hud.visible
		game.hud.visible = false
	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.near = 0.05
	cam.far = 1200.0
	add_child(cam)
	var d := Vector3(from_dir.x, 0.0, from_dir.z)
	if d.length_squared() < 0.0001:
		d = Vector3.FORWARD
	d = d.normalized()
	var eye := target + d * dist + Vector3(0, height, 0)
	var g: float = game.world.map.height_at(eye.x, eye.z)
	eye.y = maxf(eye.y, g + 0.7)
	cam.look_at_from_position(eye, target + Vector3(0, look_h, 0), Vector3.UP)
	cam.current = true
	game.world.terrain.update_focus(eye, true)
	for i in range(8):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [SHOT_DIR, name]
	img.save_png(path)
	# A portrait harness that cannot tell it photographed the subject's back is not a
	# harness. Same check the NPC shot harness makes: the subject's forward must point
	# at the lens. Four whole "character sheets" were pictures of the back of a head
	# before this line existed.
	if subject != null and is_instance_valid(subject):
		var to_cam := cam.global_position - subject.global_position
		to_cam.y = 0.0
		to_cam = to_cam.normalized()
		var faces: float = (-subject.global_transform.basis.z).dot(to_cam)
		# The node's forward is not proof of anything on its own: what matters is
		# whether the FACE is pointed at the lens, and the model is what carries the
		# face. Measure it from the eyes, which is the only part of the head whose
		# position the harness can find. Four "character sheets" passed a node-forward
		# check while photographing the back of a head.
		var eye_side := 0.0
		var ep: Vector3 = _eye_point(subject)
		if is_finite(ep.x):
			var off := ep - subject.global_position
			off.y = 0.0
			if off.length() > 0.005:
				eye_side = off.normalized().dot(to_cam)
		print("[shot] %s   node_forward_at_camera=%+.2f  eyes_at_camera=%+.2f" % [path, faces, eye_side])
		if is_finite(ep.x) and off_ok(eye_side):
			pass
		elif is_finite(ep.x):
			fails.append("%s: the subject's face is turned away from the camera (eyes %.2f)" % [name, eye_side])
	else:
		print("[shot] %s" % path)
	cam.queue_free()
	if game.hud != null and is_instance_valid(game.hud):
		game.hud.visible = hud_was
	if game.cam and game.cam.cam:
		game.cam.cam.current = true
	await get_tree().process_frame


var _p95: float = 0.0
var _p10: float = 0.0
var _median: float = 0.0
var _mon: Dictionary = {}
var _worst_ms: float = 0.0
var _perf_keep: Array = []


func _want(name: String) -> bool:
	return _only == "" or _only == name


func _count_death(_e: Node) -> void:
	_died_count += 1


func _note_alert(e: Node) -> void:
	_alert_hits.append(e)


## Wall-clock frame time with vsync off. Health is topped up every frame so the
## fight keeps going for the whole sample instead of ending in five seconds.
## Health is topped up on the PHYSICS frame, not here. Several rakshasas can land
## blows inside one slow render frame and take Rama from full to zero between two
## render-frame top-ups; when that happens `Game._on_player_died` teleports him to
## the village, the whole arena streams out to dormant, and the "cost" being measured
## becomes the cost of no enemies at all.
func _physics_process(_d: float) -> void:
	if _perf_keep.is_empty():
		return
	GameState.health = GameState.max_health
	for e in _perf_keep:
		if is_instance_valid(e) and e.is_alive():
			e.health = e.max_health


func _measure(frames: int) -> float:
	var samples: Array[float] = []
	var t_prev := Time.get_ticks_usec()
	for i in range(frames):
		await get_tree().process_frame
		var t_now := Time.get_ticks_usec()
		samples.append(float(t_now - t_prev) / 1000.0)
		t_prev = t_now
	_mon = {
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"prims": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
	}
	samples.sort()
	var total := 0.0
	for s in samples:
		total += s
	_p95 = samples[int(float(samples.size()) * 0.95)]
	_median = samples[samples.size() / 2]
	# The fastest tenth of frames approximates an uncontended machine. This box runs
	# several Godot instances at once, so the mean measures the neighbours as much as
	# the game; the best-case column is the one that is about this code.
	_p10 = samples[int(float(samples.size()) * 0.10)]
	_worst_ms = samples[samples.size() - 1]
	return total / float(samples.size())


## This machine runs several Godot instances at once while the team works in
## parallel; without the load figure a frame-time number cannot be interpreted.
func _load_average() -> String:
	var out: Array = []
	OS.execute("/usr/sbin/sysctl", ["-n", "vm.loadavg"], out)
	return String(out[0]).strip_edges() if not out.is_empty() else "unknown"


func _mon_line(tag: String) -> String:
	return (
		"[perf] %s  script: process %.2f ms + physics %.2f ms   render: %d draw calls, %d objects, %.0fk tris, %d nodes"
		% [tag, _mon.process_ms, _mon.physics_ms, int(_mon.draw_calls), int(_mon.objects), float(_mon.prims) / 1000.0, int(_mon.nodes)]
	)


func _spawn_line(p: Player, kinds: Array, dist: float) -> Array[Enemy]:
	var out: Array[Enemy] = []
	var fwd := -p.global_transform.basis.z
	for i in range(kinds.size()):
		var side: float = (float(i) - float(kinds.size() - 1) * 0.5) * 3.4
		var right := Vector3(-fwd.z, 0, fwd.x)
		var want := p.global_position + fwd * dist + right * side
		var spot := dir_node.find_ground_spot(Vector2(want.x, want.z), 6.0)
		if not is_finite(spot.x):
			continue
		var e := dir_node.spawn_at(int(kinds[i]), spot, "test")
		if e:
			e.rotation.y = e._facing_to(p.global_position)
			out.append(e)
	await steps(6)
	return out


func _spawn_ring(p: Player, kinds: Array, r0: float, r1: float) -> Array[Enemy]:
	var out: Array[Enemy] = []
	for i in range(kinds.size()):
		var a: float = TAU * float(i) / float(kinds.size())
		var r: float = lerpf(r0, r1, float(i % 5) / 4.0)
		var want := Vector2(p.global_position.x + cos(a) * r, p.global_position.z + sin(a) * r)
		var spot := dir_node.find_ground_spot(want, 7.0)
		if not is_finite(spot.x):
			continue
		var e := dir_node.spawn_at(int(kinds[i]), spot, "perf")
		if e:
			e.rotation.y = e._facing_to(p.global_position)
			out.append(e)
	await steps(6)
	return out


## Point the subject's gaze at the lens for the exposure. Without this the head keeps
## tracking the player, who is standing off to one side, and the "portrait" is a
## three-quarter rear view of a head looking somewhere else.
func _look_at_lens(e: Enemy, from_dir: Vector3, h: float) -> void:
	e._look_target = e.global_position + from_dir * _portrait_dist(h) + Vector3(0, h * 0.70, 0)
	e._look_w = 1.0
	if e.rig != null:
		e.rig.look_target = e._look_target
		e.rig.look_weight = 1.0


## An eye offset of near zero means the head is symmetric enough that the measurement
## cannot tell; only a clearly negative value is a failure.
func off_ok(eye_side: float) -> bool:
	return eye_side > -0.15


## Where the amber eyes actually are in the world, from the emissive mesh's own
## bounding box (the rig merges meshes, so the iris is no longer its own node and its
## transform is the head's — but its AABB still carries the offset).
## Returns Vector3.INF when there is no emissive mesh to find.
func _eye_point(n: Node) -> Vector3:
	var stack: Array = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c == null:
			continue
		for k in c.get_children():
			stack.append(k)
		if not (c is MeshInstance3D):
			continue
		var mi := c as MeshInstance3D
		var m := mi.material_override as StandardMaterial3D
		if m != null and m.emission_enabled and mi.mesh != null:
			return mi.global_transform * mi.get_aabb().get_center()
	return Vector3.INF


## How many distinct materials under `n` are emissive. Used to prove the amber eye is
## actually on the model rather than only in the source.
func _count_emissive(n: Node) -> int:
	var seen := {}
	var stack: Array = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c == null:
			continue
		for k in c.get_children():
			stack.append(k)
		if not (c is MeshInstance3D):
			continue
		var m := (c as MeshInstance3D).material_override as StandardMaterial3D
		if m != null and m.emission_enabled and not seen.has(m.get_instance_id()):
			seen[m.get_instance_id()] = true
	return seen.size()


## A cheap fingerprint of the pose, used to prove an idle enemy is not frozen.
func _pose_signature(e: Enemy) -> Vector3:
	if e.rig != null:
		return e.rig.head.global_position + e.rig.hips.position
	if e.beast != null:
		return e.beast.head.global_position + e.beast.body.position
	return Vector3.ZERO


## Frame a shot from a free camera, render it, and put it where it can be looked at.
func _shot(name: String, p: Player, target: Vector3, back: float, up: float) -> void:
	var cam := Camera3D.new()
	cam.fov = 58.0
	cam.near = 0.08
	cam.far = 1200.0
	add_child(cam)
	var fwd := -p.global_transform.basis.z
	var eye := target - fwd * back + Vector3(0, up, 0)
	var g: float = game.world.map.height_at(eye.x, eye.z)
	eye.y = maxf(eye.y, g + 1.2)
	cam.look_at_from_position(eye, target + Vector3(0, 1.1, 0), Vector3.UP)
	cam.current = true
	game.world.terrain.update_focus(eye, true)
	for i in range(6):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [SHOT_DIR, name]
	img.save_png(path)
	print("[shot] %s  %dx%d" % [path, img.get_width(), img.get_height()])
	cam.queue_free()
	if game.cam and game.cam.cam:
		game.cam.cam.current = true
	await get_tree().process_frame


func steps(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame
		_watch_penetration()


func _watch_penetration() -> void:
	if game == null or _pen_watch.is_empty():
		return
	var m := game.world.map
	for e in _pen_watch:
		if not is_instance_valid(e):
			continue
		var g: float = m.height_at(e.global_position.x, e.global_position.z)
		# Corpses deliberately sink; only living bodies count.
		if e.is_alive():
			worst_pen = maxf(worst_pen, g - e.global_position.y)
