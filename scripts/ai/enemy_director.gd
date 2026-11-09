class_name EnemyDirector
extends Node3D
## Who is hostile in the Vale, where they stand, and which of them is allowed to
## think this frame.
##
## Placement obeys the one rule of this world: every spawn is resolved against
## WorldMap before it exists — on the ground, on walkable slope, out of the river,
## inside the bounds. Nothing is placed by eye and nothing re-derives its own height.
##
## Streaming is the other half of the job. Twenty-five rakshasas spread over 768 m
## must not cost twenty-five brains a frame, so once per frame the director measures
## every enemy against the player and hands it two numbers: how far away it is, and
## where it ranks in the crowd. From those the enemy decides whether to think at full
## rate, at half rate, or to sleep on the terrain — and the director itself decides,
## from the same ranking, who gets a shadow, who gets built this frame, and which two
## of them are allowed to be swinging at the player right now.

const CAMP_RADIUS := 17.0
const RUINS_RADIUS := 21.0
const MAX_LOOT := 48
const BUILD_BUDGET := 1  # rigs constructed per frame; each is many meshes
const MAX_ATTACKERS := 2  # melee rakshasas allowed to commit at the same moment

var map: WorldMap
var sky: SkySystem
var world: WorldRoot

var _enemies: Array[Enemy] = []
var _active: Array = []
## Positions and radii of `_active`, in the same order, refreshed once per frame.
## Separation and the steering fan both need every neighbour's position, and both run
## for every enemy: reading `global_position` off twenty-five nodes twenty-five times
## is 625 `get_global_transform` calls a pass, each of which can walk a dirty parent
## chain. Gathering them ONCE here makes that O(n) instead of O(n*n) and turns the
## inner loops into flat array reads. Measured 2026-08-28 with `tests/enemy_prof.gd`.
var _active_pos := PackedVector3Array()
var _active_rad := PackedFloat32Array()
var _ranked: Array = []
var _loot: Array[LootDrop] = []
var _attackers: Array = []
var _focus: Vector3 = Vector3.ZERO
var _focus_driven: bool = false
var _player: Node3D = null
var _rng := RandomNumberGenerator.new()


# ===========================================================================
func setup(world_map: WorldMap, sky_system: SkySystem = null) -> void:
	map = world_map
	sky = sky_system
	if world == null:
		var p := get_parent()
		if p is WorldRoot:
			world = p as WorldRoot
	_rng.seed = 0x52_41_4B_53  # "RAKS" — the same valley every run
	_focus = map.ground(WorldMap.P_VILLAGE.x, WorldMap.P_VILLAGE.y)
	populate()


## ARCHITECTURE.md's per-frame contract. Once the Game (or a harness) drives this,
## the director stops looking the player up for itself — otherwise the self-lookup
## silently overwrites whatever was pushed in and `update_focus` is decoration.
func update_focus(pos: Vector3) -> void:
	_focus = pos
	_focus_driven = true


func _process(_delta: float) -> void:
	if map == null:
		return
	# Fallback only. A director dropped into a scene with no Game to drive it still
	# streams correctly by finding the player itself; the moment anything calls
	# `update_focus`, that becomes the single source of the focus.
	if not _focus_driven:
		if _player == null or not is_instance_valid(_player):
			var ps := get_tree().get_nodes_in_group("player")
			_player = ps[0] as Node3D if not ps.is_empty() else null
		if _player != null:
			_focus = _player.global_position

	_active.clear()
	_active_pos.clear()
	_active_rad.clear()
	_ranked.clear()
	var write := 0
	for i in range(_enemies.size()):
		var e: Enemy = _enemies[i]
		if e == null or not is_instance_valid(e):
			continue
		_enemies[write] = e
		write += 1
		var ep: Vector3 = e.global_position
		var d: float = _focus.distance_to(ep)
		if d <= Enemy.AI_DIST:
			_active.append(e)
			_active_pos.append(ep)
			_active_rad.append(float(e.def.get("body_radius", 0.44)) if e.is_alive() else -1.0)
			_ranked.append([d, e])
		else:
			e.set_focus_distance(d, 999)
	if write != _enemies.size():
		_enemies.resize(write)
	# Shadows go to the nearest few, so a crowd cannot multiply the shadow pass.
	_ranked.sort_custom(_nearer_first)
	var budget := BUILD_BUDGET
	for i in range(_ranked.size()):
		var e: Enemy = _ranked[i][1]
		e.set_focus_distance(_ranked[i][0], i)
		# Building a ProcRig is ~40 generated meshes; twenty-five of them in one frame
		# is a four-second freeze as you walk over the ridge into a camp. Nearest
		# first, a couple per frame, and the crowd assembles over half a second
		# without ever dropping a frame.
		if budget > 0 and e.wants_build():
			e.build_visual()
			budget -= 1


static func _nearer_first(a: Array, b: Array) -> bool:
	return float(a[0]) < float(b[0])


func active_enemies() -> Array:
	return _active


## The same list as `active_enemies()`, as flat arrays. A radius of -1 marks a corpse,
## which neither pushes nor is pushed.
func active_positions() -> PackedVector3Array:
	return _active_pos


func active_radii() -> PackedFloat32Array:
	return _active_rad


func enemies() -> Array[Enemy]:
	return _enemies


## How many enemies are still waiting for a body. Tests and loading screens use it.
func pending_builds() -> int:
	var n := 0
	for e in _enemies:
		if is_instance_valid(e) and e.wants_build():
			n += 1
	return n


func count_alive() -> int:
	var n := 0
	for e in _enemies:
		if is_instance_valid(e) and e.is_alive():
			n += 1
	return n


# ===========================================================================
#  POPULATION
# ===========================================================================
## The shape of the threat across the map: a camp you can scout, loose patrols you
## can be ambushed by, predators in the wild places, and a real garrison at the ruins.
func populate() -> void:
	_camp_at(WorldMap.P_FOREST_CAMP)
	_forest_patrols()
	_wild_beasts()
	_ruins_garrison(WorldMap.P_RUINS)
	_ramayana_bosses()


## The forest camp: a standing patrol group that circles the clearing, with two
## archers holding the treeline behind them.
func _camp_at(centre: Vector2) -> void:
	var gid := "camp_forest"
	for i in range(3):
		var p := find_ground_spot(centre, CAMP_RADIUS * 0.55)
		if not is_finite(p.x):
			continue
		var e := _spawn_one(EnemyTypes.Kind.WARRIOR, p, gid)
		if e:
			e.set_patrol(make_patrol(centre, CAMP_RADIUS, 4))
	for i in range(2):
		var p := find_ground_spot(centre + Vector2(_rng.randf_range(-12.0, 12.0), _rng.randf_range(-12.0, 12.0)), 8.0)
		if not is_finite(p.x):
			continue
		var e := _spawn_one(EnemyTypes.Kind.ARCHER, p, gid)
		if e:
			e.set_patrol(make_patrol(Vector2(p.x, p.z), 11.0, 3))


## Loose pairs and trios through the deep western forest. Sites are chosen where the
## canopy actually is, so these are the enemies you meet in cover — the ones the
## concealment rules in Perception are there to make interesting.
func _forest_patrols() -> void:
	var sites: Array[Vector2] = []
	var tries := 0
	while sites.size() < 5 and tries < 400:
		tries += 1
		var c := Vector2(_rng.randf_range(-330.0, -155.0), _rng.randf_range(-150.0, 135.0))
		if not map.in_bounds(c.x, c.y):
			continue
		if map.forest_density(c) < 0.42:
			continue
		if map.river_dist(c) < 26.0:
			continue
		if c.distance_to(WorldMap.P_VILLAGE) < 70.0:
			continue
		if c.distance_to(WorldMap.P_FOREST_CAMP) < 46.0:
			continue
		var too_near := false
		for s in sites:
			if s.distance_to(c) < 58.0:
				too_near = true
		if too_near:
			continue
		sites.append(c)

	for si in range(sites.size()):
		var c: Vector2 = sites[si]
		var n: int = 2 + (1 if _rng.randf() < 0.5 else 0)
		var gid := "forest_%d" % si
		for i in range(n):
			var kind: int = EnemyTypes.Kind.ARCHER if (i == n - 1 and _rng.randf() < 0.55) else EnemyTypes.Kind.WARRIOR
			var p := find_ground_spot(c, 12.0)
			if not is_finite(p.x):
				continue
			var e := _spawn_one(kind, p, gid)
			if e:
				e.set_patrol(make_patrol(c, _rng.randf_range(16.0, 30.0), 4))


## Predators: one holding the badlands, one deep in the western woods. They range
## much further than the rakshasas do.
func _wild_beasts() -> void:
	var spots: Array[Vector2] = [WorldMap.P_BADLANDS, Vector2(-258.0, 62.0)]
	for i in range(spots.size()):
		var p := find_ground_spot(spots[i], 26.0)
		if not is_finite(p.x):
			continue
		var e := _spawn_one(EnemyTypes.Kind.BEAST, p, "beast_%d" % i)
		if e:
			e.set_patrol(make_patrol(spots[i], 40.0, 5))


## The ruins are guarded, and the champion is the reason you do not walk in at level
## one: a bodyguard of warriors, archers on the walls, and something bigger behind.
func _ruins_garrison(centre: Vector2) -> void:
	var gid := "ruins"
	var pe := find_ground_spot(centre, 9.0)
	if is_finite(pe.x):
		var elite := _spawn_one(EnemyTypes.Kind.ELITE, pe, gid)
		if elite:
			elite.set_patrol(make_patrol(centre, 13.0, 3))
	for i in range(3):
		var p := find_ground_spot(centre, RUINS_RADIUS * 0.7)
		if not is_finite(p.x):
			continue
		var e := _spawn_one(EnemyTypes.Kind.WARRIOR, p, gid)
		if e:
			e.set_patrol(make_patrol(centre, RUINS_RADIUS, 5))
	for i in range(2):
		var p := find_ground_spot(centre + Vector2(_rng.randf_range(-16.0, 16.0), _rng.randf_range(-16.0, 16.0)), 8.0)
		if not is_finite(p.x):
			continue
		var e := _spawn_one(EnemyTypes.Kind.ARCHER, p, gid)
		if e:
			e.set_patrol(make_patrol(Vector2(p.x, p.z), 12.0, 3))


## Named Ramayana Bosses placed at key Kanda story sites across the valley.
func _ramayana_bosses() -> void:
	var bosses := [
		{
			"at": Vector2(-172.0, 12.0),
			"title": "Tataka — Cursed Yakshini of the Wood",
			"scale": 1.35,
			"ten_heads": false,
			"gid": "boss_tataka",
		},
		{
			"at": WorldMap.P_FOREST_CAMP + Vector2(-6.0, -6.0),
			"title": "Khara — Warlord of Janasthana",
			"scale": 1.22,
			"ten_heads": false,
			"gid": "boss_khara",
		},
		{
			"at": WorldMap.P_BADLANDS + Vector2(-10.0, -8.0),
			"title": "Kumbhakarna — The Sleeping Mountain",
			"scale": 1.65,
			"ten_heads": false,
			"gid": "boss_kumbhakarna",
		},
		{
			"at": WorldMap.P_BADLANDS,
			"title": "Dasagriva Ravana — Lord of Lanka",
			"scale": 1.45,
			"ten_heads": true,
			"gid": "boss_ravana",
		},
	]
	for b in bosses:
		var centre: Vector2 = b["at"]
		var p := find_ground_spot(centre, 8.0)
		if not is_finite(p.x):
			p = Vector3(centre.x, map.height_at(centre.x, centre.y), centre.y)
		var e := _spawn_one(EnemyTypes.Kind.ELITE, p, String(b["gid"]))
		if e == null:
			continue
		e.boss_title = String(b["title"])
		e.ten_heads = bool(b["ten_heads"])
		e.scale = Vector3.ONE * float(b["scale"])
		e.set_patrol(make_patrol(centre, 10.0, 3))


# ===========================================================================
#  PUBLIC SPAWNING  (quests use this)
# ===========================================================================
## Spawn `count` of `kind` around `centre`. `kind` may be an EnemyTypes.Kind or its
## name ("warrior", "archer", "elite", "beast"); `centre` may be a Vector2 in world XZ
## or a Vector3 whose Y is ignored. Returns the enemies that found valid ground.
func spawn_group(kind: Variant, centre: Variant, count: int) -> Array[Enemy]:
	var k: int = EnemyTypes.kind_from_name(String(kind)) if typeof(kind) == TYPE_STRING else int(kind)
	var c := Vector2.ZERO
	if typeof(centre) == TYPE_VECTOR3:
		var v: Vector3 = centre
		c = Vector2(v.x, v.z)
	else:
		c = centre
	var out: Array[Enemy] = []
	var gid := "spawned_%d" % Time.get_ticks_msec()
	var radius: float = clampf(4.0 + float(count) * 2.2, 6.0, 22.0)
	for i in range(count):
		var p := find_ground_spot(c, radius)
		if not is_finite(p.x):
			continue
		var e := _spawn_one(k, p, gid)
		if e == null:
			continue
		e.set_patrol(make_patrol(c, radius + 8.0, 4))
		out.append(e)
	return out


## Wipe every enemy and every drop. The save system calls this before loading.
func despawn_all() -> void:
	_attackers.clear()
	for e in _enemies:
		if is_instance_valid(e):
			e.queue_free()
	_enemies.clear()
	_active.clear()
	for l in _loot:
		if is_instance_valid(l):
			l.queue_free()
	_loot.clear()


## Rebuild the world's standing population from scratch, deterministically — the same
## seed puts the same rakshasa on the same rock.
func respawn_all() -> void:
	despawn_all()
	_rng.seed = 0x52_41_4B_53
	populate()


# ===========================================================================
#  PLACEMENT
# ===========================================================================
## Rejection-sample a spawn point around `centre`. Returns Vector3(INF,..) if the
## area is unusable, which callers check with `is_finite()` — spawning anyway is how
## enemies end up in the river or embedded in a cliff.
func find_ground_spot(centre: Vector2, radius: float, max_slope: float = 0.40) -> Vector3:
	for attempt in range(64):
		var widen: float = 1.0 + float(attempt) / 32.0
		var a: float = _rng.randf() * TAU
		var r: float = sqrt(_rng.randf()) * radius * widen
		var p := centre + Vector2(cos(a), sin(a)) * r
		if not map.in_bounds(p.x, p.y):
			continue
		if map.water_depth_at(p.x, p.y) > 0.02:
			continue
		if map.river_dist(p) < 7.0:
			continue
		if map.slope_at(p.x, p.y) > max_slope:
			continue
		return Vector3(p.x, map.height_at(p.x, p.y), p.y)
	return Vector3(INF, INF, INF)


## A closed walking route around `centre`. Each waypoint is validated the same way a
## spawn is, so a patrol can never be handed a leg that ends in the water.
func make_patrol(centre: Vector2, radius: float, n: int) -> Array[Vector3]:
	var pts: Array[Vector3] = []
	var start: float = _rng.randf() * TAU
	for i in range(n):
		var a: float = start + TAU * float(i) / float(n) + _rng.randf_range(-0.35, 0.35)
		var r: float = radius * _rng.randf_range(0.55, 1.0)
		var want := centre + Vector2(cos(a), sin(a)) * r
		var p := find_ground_spot(want, maxf(radius * 0.35, 4.0), 0.36)
		if is_finite(p.x):
			pts.append(p)
	if pts.size() < 2:
		var c := find_ground_spot(centre, maxf(radius, 6.0), 0.44)
		if is_finite(c.x):
			pts.append(c)
	return pts


func _spawn_one(kind: int, pos: Vector3, gid: String) -> Enemy:
	var e := Enemy.new()
	e.name = "%s_%d" % [EnemyTypes.NAMES[kind], _enemies.size()]
	add_child(e)
	(
		e
		. setup(
			kind,
			map,
			pos + Vector3(0, 0.05, 0),
			int(_rng.randi()),
			{
				"world": world,
				"sky": sky,
				"director": self,
				"group_id": gid,
			}
		)
	)
	_enemies.append(e)
	return e


# ===========================================================================
#  SQUAD BEHAVIOUR
# ===========================================================================
## One rakshasa noticing is the whole camp noticing a moment later. Allies inside
## `radius` are pulled to ALERT (they come to look) rather than straight to CHASE,
## unless they are close enough to have seen it happen too.
func alert_near(pos: Vector3, radius: float, exclude: Node, at: Vector3) -> void:
	for e in _active:
		if e == exclude or not is_instance_valid(e) or not e.is_alive():
			continue
		var d: float = e.global_position.distance_to(pos)
		if d > radius:
			continue
		e.alert_from(at, d < radius * 0.45)


## The attack token. A crowd that all swings at once is unreadable and unfair, so
## only a couple of melee rakshasas may be committed at any moment; the rest circle.
## The token is released by the holder when its attack ends, when it changes state,
## and when it dies, and stale holders are swept here as a backstop.
func request_attack_token(e: Enemy) -> bool:
	_prune_attackers()
	if _attackers.has(e):
		return true
	if _attackers.size() >= MAX_ATTACKERS:
		return false
	_attackers.append(e)
	return true


func release_attack_token(e: Enemy) -> void:
	_attackers.erase(e)


func attackers() -> int:
	_prune_attackers()
	return _attackers.size()


func _prune_attackers() -> void:
	var write := 0
	for i in range(_attackers.size()):
		var e = _attackers[i]
		if is_instance_valid(e) and e.is_alive() and e.state == Enemy.St.ATTACK:
			_attackers[write] = e
			write += 1
	_attackers.resize(write)


func register_loot(l: LootDrop) -> void:
	_loot.append(l)
	var write := 0
	for i in range(_loot.size()):
		var d: LootDrop = _loot[i]
		if is_instance_valid(d):
			_loot[write] = d
			write += 1
	_loot.resize(write)
	while _loot.size() > MAX_LOOT:
		var oldest: LootDrop = _loot.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()


# ===========================================================================
#  DEBUG / TEST SUPPORT
# ===========================================================================
## Drop one enemy at an exact spot, for tests and scripted encounters.
func spawn_at(kind: int, pos: Vector3, gid: String = "scripted") -> Enemy:
	var p := pos
	p.y = map.height_at(p.x, p.z)
	return _spawn_one(kind, p, gid)


func summary() -> String:
	var counts := {"warrior": 0, "archer": 0, "elite": 0, "beast": 0}
	for e in _enemies:
		if is_instance_valid(e) and e.is_alive():
			counts[EnemyTypes.NAMES[e.kind]] += 1
	return (
		"warriors=%d archers=%d elites=%d beasts=%d (active=%d)"
		% [counts.warrior, counts.archer, counts.elite, counts.beast, _active.size()]
	)
