class_name Enemy
extends CharacterBody3D
## A hostile inhabitant of the Vale.
##
## One class drives all four archetypes; what differs between a warrior and a tiger is
## the numbers in `EnemyTypes.def()` and which rig gets built. What they share is the
## thing that makes a fight a fight:
##
##   IDLE -> PATROL -> INVESTIGATE -> CHASE -> {ATTACK, STRAFE, RETREAT} -> DEAD
##
## Two rules the whole file is built around.
##
## 1. NOTHING STANDS STILL WAITING TO BE HIT. Every state has motion in it: idle
##    breathes and shifts its weight and glances around, patrol walks a real route,
##    investigate searches, and the gap between two attacks is a STRAFE, not a pause.
##    An enemy that freezes between swings is a training dummy.
##
## 2. NOTHING LEAVES THE GROUND IT WAS PUT ON. Movement is steered against WorldMap —
##    slope, cliffs, the river — and every frame, at every level of detail including
##    the dormant one, the body is reconciled with `map.height_at`. Streaming an
##    enemy out must never be a way to fall through the world.
##
## Contract (ARCHITECTURE.md): group "enemy",
## `take_damage(amount, source, hit_pos, crit)` and `is_alive()`.

enum St { IDLE, PATROL, INVESTIGATE, CHASE, ATTACK, STRAFE, HURT, RETREAT, DEAD }

const ST_NAME := ["idle", "patrol", "investigate", "chase", "attack", "strafe", "hurt", "retreat", "dead"]

# --- streaming thresholds (metres from the player) -------------------------
const AI_DIST := 110.0  # beyond this the brain sleeps
const ANIM_DIST := 70.0  # beyond this the limbs stop moving
const BUILD_DIST := 140.0  # the rig is not even constructed until this close
const SHOW_DIST := 168.0  # beyond this, hidden
const SHADOW_DIST := 30.0  # beyond this, stops casting shadows
const MAX_SHADOW_CASTERS := 8  # only the nearest few cast, however many are close
const CROWD_FRONT := 8  # how many of a crowd get the full brain and pose rate

const DESPAWN_DELAY := 15.0  # corpse lingers, then sinks
const SINK_TIME := 4.0

signal died(enemy: Enemy)

# --- identity --------------------------------------------------------------
var kind: int = EnemyTypes.Kind.WARRIOR
var def: Dictionary = {}
var map: WorldMap
var world: WorldRoot
var sky: SkySystem
var director: Node = null
var group_id: String = ""
var boss_title: String = ""
var ten_heads: bool = false

# --- vitals ----------------------------------------------------------------
var health: float = 90.0
var max_health: float = 90.0
var _alive: bool = true
var _burn_t: float = 0.0
var _slow_t: float = 0.0

# --- brain -----------------------------------------------------------------
var perc := Perception.new()
var state: int = St.IDLE
var home: Vector3 = Vector3.ZERO
var patrol_points: Array[Vector3] = []

# --- visual ----------------------------------------------------------------
var rig: ProcRig = null
var beast: BeastRig = null
var weapon: Node3D = null

var _rng := RandomNumberGenerator.new()
var _string: Node3D = null
var _built: bool = false
var _shadows_on: bool = true
var _mesh_count: int = 0
var _focus_d: float = 1.0e9  # dormant until the director measures it
var _slow_n: int = 0
var _rank: int = 0
var _pose_acc: float = 0.0
var _pose_n: int = 0
var _slow_acc: float = 0.0
var _brain_acc: float = 0.0
var _move_acc: float = 0.0

# --- movement --------------------------------------------------------------
var _desired: Vector3 = Vector3.ZERO
var _steer_cache: Vector3 = Vector3.ZERO
var _steer_t: float = 0.0
var _sep: Vector3 = Vector3.ZERO
var _sep_t: float = 0.0
var _wet_t: float = 0.0
var _in_water: bool = false
var _has_token: bool = false
var _gravity: float = 22.0
var _air_t: float = 0.0
var _leaping: bool = false
var _leap_air: bool = false
var _leap_t: float = 0.0
var _grounded: bool = true
## The AI's authoritative position, and what was last pushed into the node.
##
## `global_position = x` on a CharacterBody3D is not a field assignment. It moves the
## body in the physics server AND marks every descendant's global transform dirty, and
## the scene tree flushes those notifications once per PHYSICS tick — so each of the
## rig's ~30 MeshInstance3Ds pushes a fresh transform to the rendering server every
## time the body moves. On a frame slow enough to run three physics ticks that is
## three times the work for one drawn frame.
##
## Measured 2026-08-28 with `tests/probes/enemy_prof.gd` (25 enemies fighting, median of
## paired in-process differences): `_physics_process` cost 11.60 ms/frame while the
## GDScript inside it accounted for only ~5.5 ms. The rest was this.
##
## So motion integrates at the physics rate into `_pos` — no loss of fidelity, no
## bigger timestep — and the node is moved at most ONCE per drawn frame, which is the
## only rate at which moving it can be seen. Everything else in the file keeps reading
## `global_position` and is at most one frame behind, which for a look-at, a steering
## fan or a perception cone is nothing.
var _pos: Vector3 = Vector3.ZERO
var _pos_pushed: Vector3 = Vector3.ZERO
var _pos_frame: int = -1

# --- state timers ----------------------------------------------------------
var _pi: int = 0
var _idle_t: float = 0.0
var _idle_yaw: float = 0.0
var _glance_t: float = 0.0
var _look_target: Vector3 = Vector3.ZERO
var _look_w: float = 0.0
var _invest_t: float = 0.0
var _scan_t: float = 0.0
var _strafe_dir: float = 1.0
var _strafe_t: float = 0.0
var _retreat_t: float = 0.0
var _hurt_t: float = 0.0
var _growl_t: float = 0.0

# --- attack ----------------------------------------------------------------
var _atk_seq: Array = []
var _atk_i: int = 0
var _atk_t: float = 0.0
var _atk_hit: bool = false
var _atk_cd: float = 0.0
var _leap_cd: float = 0.0
var _swing: float = 0.0
var _aim_w: float = 0.0
var _aim_dir: Vector3 = Vector3.FORWARD
var _pounce: float = 0.0
var _maw: float = 0.0

# --- death -----------------------------------------------------------------
var _dead_t: float = 0.0
var _sunk: float = 0.0

var _player: Node3D = null


# ===========================================================================
#  SETUP
# ===========================================================================
func _ready() -> void:
	add_to_group("enemy")
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_max_angle = deg_to_rad(56.0)
	floor_snap_length = 0.55
	slide_on_ceiling = true
	# Layer 4 is the character layer the player and the aim ray already look for, and
	# the camera's spring arm already ignores; putting rakshasas anywhere else would
	# either make the camera jump over them or make them unaimable.
	collision_layer = 4
	collision_mask = 1 | 8
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 22.0))
	EventBus.footstep.connect(_on_world_footstep)
	EventBus.arrow_fired.connect(_on_arrow_fired)


## Called by EnemyDirector immediately after instancing.
func setup(k: int, m: WorldMap, spawn: Vector3, seed_v: int, opts: Dictionary = {}) -> void:
	kind = k
	map = m
	def = EnemyTypes.def(k)
	_rng.seed = seed_v
	max_health = float(def.health)
	health = max_health
	home = spawn
	global_position = spawn
	world = opts.get("world", null)
	sky = opts.get("sky", null)
	director = opts.get("director", null)
	group_id = String(opts.get("group_id", ""))

	perc.configure(def)

	var cap := CapsuleShape3D.new()
	cap.radius = float(def.body_radius)
	cap.height = maxf(float(def.body_height), cap.radius * 2.0 + 0.05)
	var col := CollisionShape3D.new()
	col.shape = cap
	col.position = Vector3(0, cap.height * 0.5, 0)
	add_child(col)

	_idle_yaw = _rng.randf() * TAU
	rotation.y = _idle_yaw
	_idle_t = _rng.randf_range(1.5, 5.0)
	_glance_t = _rng.randf_range(0.5, 3.0)
	_growl_t = _rng.randf_range(6.0, 22.0)
	# Do not open an encounter with the gap-closer: the champion has to be seen
	# walking at you once before it starts jumping the distance.
	_leap_cd = _rng.randf_range(2.5, 4.5)
	_look_target = global_position + Vector3(sin(_idle_yaw), 0.9, cos(_idle_yaw)) * 6.0
	state = St.PATROL if not patrol_points.is_empty() else St.IDLE


func set_patrol(points: Array[Vector3]) -> void:
	patrol_points = points
	if not points.is_empty():
		state = St.PATROL


## Build the body. Deferred until the player is within BUILD_DIST: a ProcRig is ~40
## generated meshes, and building 25 of them at world load costs a visible hitch for
## enemies the player may never walk to.
func build_visual() -> void:
	if _built:
		return
	_built = true
	var parts := EnemyTypes.build_body(kind, self, int(_rng.randi()))
	rig = parts.get("rig", null)
	beast = parts.get("beast", null)
	weapon = parts.get("weapon", null)
	_string = parts.get("string", null)
	var gf := func(x: float, z: float) -> float: return map.height_at(x, z)
	if rig:
		rig.ground_fn = gf
		rig.footstep.connect(_on_own_footstep)
	if beast:
		beast.ground_fn = gf
		beast.footstep.connect(_on_own_footstep)
	# Merge the meshes that share a joint and a material. Twenty-five rakshasas at
	# forty draw calls each is a thousand instances in the colour pass and another
	# thousand in every shadow split; after this it is roughly half that, and every
	# rakshasa of a kind shares the same merged resources.
	var vr := visual_root()
	if vr != null:
		var counts := RigOptimiser.flatten(vr, EnemyTypes.NAMES[kind])
		if _string != null and not is_instance_valid(_string):
			_string = null
		_mesh_count = counts.y
	if not _alive:
		if rig:
			rig.dead_amount = 1.0
		if beast:
			beast.dead_amount = 1.0


func visual_root() -> Node3D:
	return rig if rig != null else beast


## True when this enemy is close enough to deserve a body but has not been given the
## frame time to build one. The director serves these one at a time.
func wants_build() -> bool:
	return not _built and _focus_d < BUILD_DIST


# ===========================================================================
#  STREAMING
# ===========================================================================
## The director tells every enemy how far away the player is and where it ranks in
## the queue for shadows; the enemy decides what that buys it. Called every frame,
## cheap on purpose.
func set_focus_distance(d: float, shadow_rank: int = 0) -> void:
	_focus_d = d
	_rank = shadow_rank
	var vr := visual_root()
	if vr != null:
		var want_vis: bool = d < SHOW_DIST
		if vr.visible != want_vis:
			vr.visible = want_vis
		# Shadows are the most expensive thing a crowd does: every caster is redrawn
		# into every shadow split. Only the handful of enemies actually near the
		# player earn one, and only while they are inside the shadow distance.
		var want_shadow: bool = d < SHADOW_DIST and shadow_rank < MAX_SHADOW_CASTERS
		if want_shadow != _shadows_on:
			_shadows_on = want_shadow
			_set_shadows(vr, want_shadow)


func _set_shadows(n: Node, on: bool) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
	for c in n.get_children():
		_set_shadows(c, on)


func mesh_count() -> int:
	return _mesh_count


func lod_name() -> String:
	if _focus_d > AI_DIST:
		return "dormant"
	if _focus_d > ANIM_DIST:
		return "thinking"
	return "full"


# ===========================================================================
#  MAIN LOOP
# ===========================================================================
func _physics_process(delta: float) -> void:
	if not _alive:
		_tick_dead(delta)
		return
	if _burn_t > 0.0:
		_burn_t = maxf(0.0, _burn_t - delta)
		health -= 6.0 * delta
		if health <= 0.0:
			_die()
			return
	if _slow_t > 0.0:
		_slow_t = maxf(0.0, _slow_t - delta)
	if _focus_d > AI_DIST:
		_tick_dormant()
		return
	_slow_n += 1
	if _focus_d > ANIM_DIST:
		# Thinking, but at a third of the rate. The accumulated delta keeps speeds
		# honest, so a streamed-out patrol still covers ground.
		_slow_acc += delta
		if _slow_n % 3 != 0:
			return
		var dt: float = _slow_acc
		_slow_acc = 0.0
		_timers(dt)
		_perceive(dt)
		_brain(dt)
		_motion(dt)
		return
	# Close in, rank decides the rate. The director hands every enemy its position in
	# the queue by distance; the handful in the player's face think at 30 Hz and move
	# every physics tick, and the ones circling at the back of a fight of twenty-five
	# think at 15 Hz and move at 30. A decision made 16 ms later than it could have
	# been is not a decision anyone can see, and a body walking sideways twelve metres
	# away does not need its position integrated sixty times a second — the pose it is
	# drawn with is only recomputed half that often anyway.
	#
	# Measured with `tests/probes/enemy_prof.gd`, 25 enemies fighting, median of paired
	# in-process differences (ARCHITECTURE.md's rule for frame cost): moving the back
	# ranks to 30 Hz is the single largest saving in this loop, because `_motion` was
	# the only thing in the file still running at the full tick rate for everybody.
	_timers(delta)
	_brain_acc += delta
	var front: bool = _rank < CROWD_FRONT
	var period: int = 2 if front else 4
	if _slow_n % period == 0:
		var bdt: float = _brain_acc
		_brain_acc = 0.0
		_perceive(bdt)
		_brain(bdt)
	if front:
		_motion(delta)
	else:
		_move_acc += delta
		if _slow_n % 2 == 0:
			var mdt: float = _move_acc
			_move_acc = 0.0
			_motion(mdt)


## Posing happens on the RENDER frame, not the physics frame. Physics catches up by
## running several ticks in one frame when the frame is slow, and animating once per
## tick would then do the same visual work three times over for a pose that is drawn
## once. This is both cheaper and more correct.
func _process(delta: float) -> void:
	if _focus_d > ANIM_DIST:
		return
	# Distance decides the pose rate, and it has its own counter. Sharing `_slow_n`
	# with `_physics_process` meant the pose's "every other frame" was really "every
	# other *event*, whichever loop got there first", so the cadence changed with the
	# machine's frame rate rather than with the thing it is supposed to depend on.
	#
	# Two-bone IK on four limbs, plus the transform write for every joint it moves, is
	# the whole of the posing cost. Close enough to read a wind-up: every frame. In
	# the middle of a fight: every other. At the back: every third. Twenty metres out
	# a body posed at 20 Hz is indistinguishable from one posed at 60.
	if _focus_d > 12.0:
		_pose_n += 1
		var pp: int = 2 if _focus_d < 30.0 else 3
		_pose_acc += delta
		if _pose_n % pp != 0:
			return
		delta = _pose_acc
		_pose_acc = 0.0
	if not _alive:
		_animate_dead(delta)
		return
	_animate(delta)


## Out of range: no brain, no physics, no animation — but still ON the terrain.
## Snapping to `map.height_at` here is the reason a streamed-out enemy cannot be
## found later hanging in the air or buried in a hill.
func _tick_dormant() -> void:
	velocity = Vector3.ZERO
	_slow_acc = 0.0
	_brain_acc = 0.0
	var pos: Vector3 = _read_pos()
	var gy: float = map.height_at(pos.x, pos.z)
	# A dormant enemy never moves, so after the first snap this is the same number
	# every tick, and writing it anyway is a full `set_global_transform` for each of
	# the twenty-six enemies the player is nowhere near.
	if absf(pos.y - gy) > 0.0005:
		pos.y = gy
		_write_pos(pos)
	_grounded = true
	_air_t = 0.0


func _timers(dt: float) -> void:
	_atk_cd = maxf(0.0, _atk_cd - dt)
	_leap_cd = maxf(0.0, _leap_cd - dt)
	_growl_t -= dt
	_update_separation(dt)
	if _grounded:
		_air_t = 0.0
	else:
		_air_t += dt
	if _growl_t <= 0.0:
		_growl_t = _rng.randf_range(9.0, 26.0)
		if _focus_d < 40.0:
			var pool: Array = def.idle_sfx if state <= St.PATROL else def.alert_sfx
			AudioDirector.play_3d(String(pool[_rng.randi() % pool.size()]), global_position + Vector3(0, float(def.eye_h), 0), -14.0)


# --- perception ------------------------------------------------------------
func _perceive(dt: float) -> void:
	var p := _find_player()
	var eye := global_position + Vector3(0, float(def.eye_h), 0)
	var fwd := -global_transform.basis.z
	var light: float = sky.light_level() if sky != null else 1.0
	var was_committed := perc.committed
	perc.update(dt, eye, fwd, p, get_world_3d().direct_space_state, map, light)
	if perc.committed and not was_committed:
		_on_commit()


func _on_commit() -> void:
	EventBus.enemy_alerted.emit(self)
	var pool: Array = def.alert_sfx
	AudioDirector.play_3d(String(pool[_rng.randi() % pool.size()]), global_position + Vector3(0, float(def.eye_h), 0), -2.0)
	if director != null and director.has_method("alert_near"):
		director.alert_near(global_position, 24.0, self, perc.last_known)


## Somebody walked past. Loud on stone or at a sprint, nearly silent creeping on grass.
func _on_world_footstep(surface: String, pos: Vector3, speed: float) -> void:
	if not _alive or _focus_d > AI_DIST:
		return
	var loud: float = Perception.footstep_loudness(surface, speed)
	# Under the canopy, sound carries less usefully — it is harder to place.
	loud *= 1.0 - Perception.concealment(map, _find_player()) * 0.45
	perc.hear(global_position, pos, loud)


## A bowstring is loud, and the release gives away a direction.
func _on_arrow_fired(from: Vector3, _dir: Vector3, charge: float) -> void:
	if not _alive or _focus_d > AI_DIST:
		return
	perc.hear(global_position, from, 0.55 + charge * 0.35)


# ===========================================================================
#  STATE MACHINE
# ===========================================================================
func _enter(s: int) -> void:
	if state == s:
		return
	if state == St.ATTACK:
		_release_attack()
	state = s
	match s:
		St.IDLE:
			_idle_t = _rng.randf_range(1.6, 4.2)
			_glance_t = _rng.randf_range(0.4, 1.6)
		St.INVESTIGATE:
			_invest_t = 0.0
			_scan_t = 0.0
		St.STRAFE:
			_strafe_t = _rng.randf_range(1.0, 2.2)
			_strafe_dir = 1.0 if _rng.randf() < 0.5 else -1.0
		St.RETREAT:
			_retreat_t = _rng.randf_range(1.8, 3.4)
		St.HURT:
			_hurt_t = 0.30
	if s != St.ATTACK:
		_swing = 0.0
		_pounce = 0.0
		_maw = 0.0


func _brain(dt: float) -> void:
	match state:
		St.IDLE:
			_st_idle(dt)
		St.PATROL:
			_st_patrol(dt)
		St.INVESTIGATE:
			_st_investigate(dt)
		St.CHASE:
			_st_chase(dt)
		St.STRAFE:
			_st_strafe(dt)
		St.ATTACK:
			_st_attack(dt)
		St.RETREAT:
			_st_retreat(dt)
		St.HURT:
			_st_hurt(dt)


## Shared escalation: any calm state drops everything the moment awareness rises.
func _escalated() -> bool:
	if perc.committed:
		_enter(St.CHASE)
		return true
	if perc.level() >= 2 and perc.has_last_known:
		_enter(St.INVESTIGATE)
		return true
	return false


# --- IDLE ------------------------------------------------------------------
## Standing still is still doing something: breathing (the rig does that on its own),
## glancing around, and shifting stance every few seconds.
func _st_idle(dt: float) -> void:
	if _escalated():
		return
	_desired = Vector3.ZERO
	_idle_t -= dt
	_glance_t -= dt
	if _glance_t <= 0.0:
		_glance_t = _rng.randf_range(1.6, 4.5)
		var a: float = rotation.y + _rng.randf_range(-1.5, 1.5)
		_look_target = (
			global_position + Vector3(-sin(a), 0.0, -cos(a)) * 9.0 + Vector3(0, float(def.eye_h) + _rng.randf_range(-0.6, 0.6), 0)
		)
	_look_w = lerpf(_look_w, 0.55, 1.0 - pow(0.02, dt))
	# The weight shift: a slow drift of the whole body toward a new facing.
	if perc.level() >= 1 and perc.has_last_known:
		_look_target = perc.last_known + Vector3(0, 1.2, 0)
		_look_w = 1.0
		_face_point(perc.last_known, dt, 2.4)
	else:
		_face(_idle_yaw, dt, 1.1)
	if _idle_t <= 0.0:
		if not patrol_points.is_empty():
			_enter(St.PATROL)
		else:
			_idle_t = _rng.randf_range(2.5, 6.0)
			_idle_yaw = wrapf(_idle_yaw + _rng.randf_range(-1.9, 1.9), -PI, PI)


# --- PATROL ----------------------------------------------------------------
func _st_patrol(dt: float) -> void:
	if _escalated():
		return
	if patrol_points.is_empty():
		_enter(St.IDLE)
		return
	var tgt: Vector3 = patrol_points[_pi % patrol_points.size()]
	var to := tgt - global_position
	to.y = 0.0
	if to.length() < 1.9:
		_pi = (_pi + 1) % patrol_points.size()
		_enter(St.IDLE)
		return
	var dir := _steer(dt, to)
	_desired = dir * float(def.walk)
	_look_w = lerpf(_look_w, 0.25, 1.0 - pow(0.05, dt))
	if dir.length_squared() > 0.001:
		_face_dir(dir, dt, float(def.turn) * 0.7)
		_look_target = global_position + dir * 8.0 + Vector3(0, float(def.eye_h), 0)


# --- INVESTIGATE -----------------------------------------------------------
## Walk to where the noise came from, then stand there and sweep. Giving up is a
## real transition, not a timeout into nothing: awareness is knocked back down so the
## same faint noise does not immediately re-trigger.
func _st_investigate(dt: float) -> void:
	if perc.committed:
		_enter(St.CHASE)
		return
	_invest_t += dt
	if not perc.has_last_known or _invest_t > 11.0:
		perc.awareness *= 0.35
		perc.has_last_known = false
		_enter(St.PATROL if not patrol_points.is_empty() else St.IDLE)
		return

	var to: Vector3 = perc.last_known - global_position
	to.y = 0.0
	_look_target = perc.last_known + Vector3(0, 1.2, 0)
	_look_w = lerpf(_look_w, 1.0, 1.0 - pow(0.01, dt))
	if to.length() > 2.2 and _scan_t <= 0.0:
		var dir := _steer(dt, to)
		_desired = dir * float(def.walk) * 1.75
		if dir.length_squared() > 0.001:
			_face_dir(dir, dt, float(def.turn))
	else:
		# Arrived. Sweep the area.
		_scan_t += dt
		_desired = Vector3.ZERO
		var sweep: float = sin(_scan_t * 1.35) * 1.15
		_face(_facing_to(perc.last_known) + sweep, dt, 2.2)
		_look_target = (global_position + Vector3(-sin(rotation.y), 0.0, -cos(rotation.y)) * 10.0 + Vector3(0, float(def.eye_h), 0))
		if _scan_t > 4.5:
			perc.awareness *= 0.4
			perc.has_last_known = false
			_enter(St.PATROL if not patrol_points.is_empty() else St.IDLE)


# --- CHASE -----------------------------------------------------------------
func _st_chase(dt: float) -> void:
	var p := _find_player()
	if p == null or (p.has_method("is_dead") and p.is_dead()):
		perc.forget()
		_enter(St.PATROL if not patrol_points.is_empty() else St.IDLE)
		return
	if not perc.committed:
		_enter(St.INVESTIGATE)
		return

	var to: Vector3 = p.global_position - global_position
	to.y = 0.0
	var d: float = to.length()
	_look_target = p.global_position + Vector3(0, 1.3, 0)
	_look_w = 1.0
	_face_point(p.global_position, dt, float(def.turn))

	if _should_retreat(d):
		_enter(St.RETREAT)
		return
	# The champion closes a gap by jumping it.
	if def.has("leap_range") and _leap_cd <= 0.0 and _atk_cd <= 0.0:
		var lr: Vector2 = def.leap_range
		if d > lr.x and d < lr.y and perc.can_see and _claim_attack():
			_leap_cd = float(def.leap_cd)
			_begin_attack(EnemyTypes.leap_seq())
			return
	if d <= float(def.attack_range) and _atk_cd <= 0.0 and perc.can_see:
		if _claim_attack():
			_begin_attack(EnemyTypes.attack_seq(kind))
			return
		# Ready to swing but no slot free: fall back to circling rather than pressing
		# in. Without this the whole mob walks into the player and stands there.
		_enter(St.STRAFE)
		return
	if d <= float(def.attack_range) * (1.05 if kind == EnemyTypes.Kind.ARCHER else 1.5):
		_enter(St.STRAFE)
		return
	var dir := _steer(dt, to)
	_desired = dir * float(def.run)


# --- STRAFE ----------------------------------------------------------------
## The rhythm of a fight lives here: after a swing, circle rather than stand. Melee
## types orbit just outside their reach; archers hold their preferred range and
## sidestep while the draw comes back up.
func _st_strafe(dt: float) -> void:
	var p := _find_player()
	if p == null or not perc.committed:
		_enter(St.CHASE)
		return
	var to: Vector3 = p.global_position - global_position
	to.y = 0.0
	var d: float = maxf(to.length(), 0.01)
	_look_target = p.global_position + Vector3(0, 1.3, 0)
	_look_w = 1.0
	_face_point(p.global_position, dt, float(def.turn) * 1.3)

	if _should_retreat(d):
		_enter(St.RETREAT)
		return
	_strafe_t -= dt
	if _strafe_t <= 0.0:
		_strafe_t = _rng.randf_range(1.0, 2.3)
		_strafe_dir = -_strafe_dir

	# Hold the circling distance while recovering, then tighten it as the attack comes
	# back up, so the enemy is already inside its reach the moment it can swing.
	#
	# Crowd rank widens the ring: the nearest few orbit at their own reach and the
	# rest hold further out, which turns a mob of twenty-five from one solid scrum
	# into concentric rings the player can actually read and fight through.
	var pref: float = float(def.strafe_dist) + float(mini(_rank, 14)) * 0.80
	if _atk_cd < 0.45 and (_rank < CROWD_FRONT or director == null):
		pref = minf(pref, float(def.attack_range) * 0.70)
	var radial := (to / d) * clampf((d - pref) / maxf(pref * 0.5, 1.0), -1.0, 1.0)
	var tangent := Vector3.UP.cross(to / d) * _strafe_dir
	var want := tangent + radial * 0.95
	if want.length_squared() > 0.0001:
		var dir := _steer(dt, want.normalized())
		_desired = dir * float(def.run) * 0.60
	else:
		_desired = Vector3.ZERO

	if _atk_cd <= 0.0 and d <= float(def.attack_range) and perc.can_see and _claim_attack():
		_begin_attack(EnemyTypes.attack_seq(kind))
		return
	if d > float(def.attack_range) * 1.25 or (kind == EnemyTypes.Kind.ARCHER and not perc.can_see):
		_enter(St.CHASE)


# --- RETREAT ---------------------------------------------------------------
## Back off, keep facing the threat, then come back. Archers do it when the player
## closes; beasts do it when they are hurt. It is a re-engagement, not a rout.
func _st_retreat(dt: float) -> void:
	var p := _find_player()
	if p == null or not perc.committed:
		_enter(St.CHASE)
		return
	var to: Vector3 = p.global_position - global_position
	to.y = 0.0
	var d: float = maxf(to.length(), 0.01)
	_look_target = p.global_position + Vector3(0, 1.3, 0)
	_look_w = 1.0
	_retreat_t -= dt

	var away := -(to / d)
	# Break the line as well as the distance, so retreating is not a straight
	# backpedal the player can simply out-sprint.
	var side := Vector3.UP.cross(to / d) * _strafe_dir * 0.45
	var dir := _steer(dt, (away + side).normalized())
	_desired = dir * float(def.run) * 0.92
	if kind == EnemyTypes.Kind.ARCHER:
		_face_point(p.global_position, dt, float(def.turn))
	else:
		_face_dir(dir, dt, float(def.turn))

	var safe: float = maxf(float(def.retreat_dist), float(def.attack_min)) * 1.25
	if d >= safe or _retreat_t <= 0.0:
		_enter(St.STRAFE if d <= float(def.attack_range) else St.CHASE)


func _should_retreat(d: float) -> bool:
	if not bool(def.retreats):
		return false
	if d < float(def.attack_min):
		return true
	return health < max_health * float(def.retreat_health) and d < float(def.retreat_dist)


# --- HURT ------------------------------------------------------------------
func _st_hurt(dt: float) -> void:
	_hurt_t -= dt
	_desired = Vector3.ZERO
	if _hurt_t <= 0.0:
		_enter(St.CHASE if perc.committed else St.INVESTIGATE)


# ===========================================================================
#  ATTACKS
# ===========================================================================
## Melee archetypes need a slot from the director before they may commit. Six
## rakshasas all swinging at once is not a fight, it is a blender: the player cannot
## read six wind-ups, and dodging one puts them inside another. The rest keep
## circling, which is what makes a group encounter legible.
func _claim_attack() -> bool:
	if kind == EnemyTypes.Kind.ARCHER:
		return true
	if director == null or not director.has_method("request_attack_token"):
		return true
	_has_token = director.request_attack_token(self)
	return _has_token


func _release_attack() -> void:
	if _has_token and director != null and director.has_method("release_attack_token"):
		director.release_attack_token(self)
	_has_token = false


func _begin_attack(seq: Array) -> void:
	_atk_seq = seq
	_atk_i = 0
	_atk_t = 0.0
	_atk_hit = false
	state = St.ATTACK
	_phase_enter()


func _phase_enter() -> void:
	var ph: Dictionary = _atk_seq[_atk_i]
	_atk_hit = false
	if ph.has("sfx"):
		AudioDirector.play_3d(String(ph.sfx), global_position + Vector3(0, float(def.eye_h), 0), float(ph.get("sfx_db", -4.0)))
	match String(ph.p):
		"shoot":
			_fire_arrow(float(ph.get("dmg", 10.0)))
		"leap":
			_launch(float(ph.get("speed", 12.0)), float(ph.get("up", 4.0)))


func _st_attack(dt: float) -> void:
	if _atk_seq.is_empty():
		_enter(St.CHASE)
		return
	var ph: Dictionary = _atk_seq[_atk_i]
	var dur: float = float(ph.d)
	_atk_t += dt
	var t: float = clampf(_atk_t / maxf(dur, 0.001), 0.0, 1.0)
	var p := _find_player()

	match String(ph.p):
		"wind":
			# ProcRig's melee arc and its bow-draw pose both claim the right arm, and
			# the melee layer wins. An archer must drive ONLY the aim layer or it
			# raises its bow overhead like a club.
			_swing = 0.0 if kind == EnemyTypes.Kind.ARCHER else 0.30 * t
			# Negative is the gather; the spring flips it positive on the leap.
			_pounce = -t if kind == EnemyTypes.Kind.BEAST else 0.0
			_maw = t * 0.8 if kind == EnemyTypes.Kind.BEAST else 0.0
			if kind == EnemyTypes.Kind.ARCHER:
				_aim_w = t
				if p != null:
					_aim_dir = _shot_direction(p)
			# Tracking during the wind-up, but slowly: this is the window the player
			# is meant to read and step out of.
			if p != null:
				_face_point(p.global_position, dt, float(def.turn) * 0.5)
			_desired = Vector3.ZERO
		"hit":
			_swing = 0.30 + 0.40 * t
			_desired = Vector3.ZERO
			_try_hit(ph)
		"leap":
			_swing = 0.0 if kind == EnemyTypes.Kind.BEAST else 0.30 + 0.40 * t
			_pounce = 1.0 - t * 0.45
			_maw = 1.0
			_try_hit(ph)
		"shoot":
			_swing = 0.0
			_aim_w = maxf(0.0, 1.0 - t * 1.4)
			_desired = Vector3.ZERO
		"rec":
			_swing = 0.0 if kind == EnemyTypes.Kind.ARCHER else 0.70 + 0.30 * t
			_aim_w = lerpf(_aim_w, 0.0, 1.0 - pow(0.001, dt))
			_pounce = lerpf(_pounce, 0.0, 1.0 - pow(0.001, dt))
			_maw = lerpf(_maw, 0.0, 1.0 - pow(0.01, dt))
			# Even recovering, it drifts — a half step back out of reach.
			if p != null:
				var away := global_position - p.global_position
				away.y = 0.0
				if away.length_squared() > 0.01:
					_desired = away.normalized() * float(def.walk) * 0.55
			_look_w = 1.0

	if _atk_t >= dur:
		_atk_i += 1
		_atk_t = 0.0
		if _atk_i >= _atk_seq.size():
			_release_attack()
			_atk_cd = float(def.attack_cd) * _rng.randf_range(0.85, 1.3)
			_swing = 0.0
			_aim_w = 0.0
			_leaping = false
			_enter(St.STRAFE if perc.committed else St.INVESTIGATE)
		else:
			_phase_enter()


## The damage sphere. Forward-biased so an enemy cannot hit what is behind it, and
## height-tolerant so a tiger at your ankles still connects.
func _try_hit(ph: Dictionary) -> void:
	if _atk_hit:
		return
	var p := _find_player()
	if p == null or (p.has_method("is_dead") and p.is_dead()):
		return
	var origin := global_position + Vector3(0, float(def.eye_h) * 0.62, 0)
	var to: Vector3 = (p.global_position + Vector3(0, 0.9, 0)) - origin
	var flat := Vector3(to.x, 0.0, to.z)
	var reach: float = float(ph.get("rng", 2.8)) + float(def.body_radius)
	if flat.length() > reach or absf(to.y) > 2.2:
		return
	var fwd := -global_transform.basis.z
	if flat.length_squared() > 0.0001 and fwd.angle_to(flat.normalized()) > float(ph.get("arc", 1.5)) * 0.5:
		return
	_atk_hit = true
	var dmg: float = float(ph.get("dmg", 10.0))
	if p.has_method("take_damage"):
		p.take_damage(dmg, self, p.global_position + Vector3(0, 1.1, 0), false)
	AudioDirector.play_3d("sword_hit_flesh" if kind != EnemyTypes.Kind.BEAST else "sword_hit_block", p.global_position, -3.0)


func _launch(speed: float, up: float) -> void:
	var p := _find_player()
	var dir := -global_transform.basis.z
	if p != null:
		var to: Vector3 = p.global_position - global_position
		to.y = 0.0
		if to.length_squared() > 0.01:
			dir = to.normalized()
	_leaping = true
	_leap_air = false
	_leap_t = 0.0
	velocity = dir * speed + Vector3.UP * up
	_face_dir(dir, 1.0, 100.0)


func _fire_arrow(dmg: float) -> void:
	var p := _find_player()
	if p == null:
		return
	var origin := global_position + Vector3(0, float(def.eye_h) * 0.95, 0)
	if rig != null:
		origin = (rig.hand_attach["L"] as Node3D).global_position + Vector3(0, 0.04, 0)
	var dir := _shot_direction(p)
	var parent: Node = get_parent()
	if parent == null:
		return
	EnemyArrow.shoot(parent, origin, dir * 30.0, self, dmg, world)
	AudioDirector.play_3d("bow_release", global_position, -6.0)


## Aim with a lead and a drop compensation, plus a small spread so a volley is not a
## laser. The lead is what makes standing still against archers a bad idea.
func _shot_direction(p: Node3D) -> Vector3:
	var target: Vector3 = p.global_position + Vector3(0, 1.15, 0)
	var pv: Variant = p.get("velocity")
	if typeof(pv) == TYPE_VECTOR3:
		var flight: float = global_position.distance_to(target) / 30.0
		var v: Vector3 = pv
		target += Vector3(v.x, 0.0, v.z) * flight * 0.65
	var from := global_position + Vector3(0, float(def.eye_h) * 0.95, 0)
	var to := target - from
	var dist: float = to.length()
	# Ballistic lift: 11 m/s^2 over the flight time, halved because the arrow only
	# spends half that time falling before it arrives.
	to.y += 0.5 * 11.0 * pow(dist / 30.0, 2.0)
	var dir := to.normalized()
	var spread: float = 0.017
	dir = ((dir + Vector3(_rng.randfn(0.0, spread), _rng.randfn(0.0, spread * 0.6), _rng.randfn(0.0, spread))).normalized())
	return dir


# ===========================================================================
#  MOVEMENT
# ===========================================================================
## Movement is integrated against WorldMap, not resolved by `move_and_slide`.
##
## Measured on an M2 Max, 2026-08-28: sweeping a capsule against the world's single
## 769x769 HeightMapShape3D costs ~2.5 ms per body per physics tick, so twenty-five
## rakshasas walking cost ~60 ms a frame in the physics server alone and put the
## engine into a catch-up spiral. But this world already knows exactly where its
## ground is — `map.height_at` is the canonical query every other system uses — so a
## walker does not need to discover it by collision. Integrating directly is two
## array lookups instead of a shape cast, it cannot tunnel, and it cannot fall
## through the world, which is the one rule.
##
## The body stays a CharacterBody3D with a real capsule, so Rama still bumps into a
## rakshasa and the camera's aim ray still finds one; only the resolution of its own
## movement is done by hand. Buildings are avoided by the steering fan, which is
## where an enemy should be dealing with them anyway.
const CLIMB_GRADE := 1.25  # metres of rise it will walk up per metre travelled (~51 deg)
const STEP_TOLERANCE := 0.06  # small ledges it steps over rather than stopping at
const GROUND_GLUE := 0.10  # tolerance before it counts as airborne


## `global_position` is read ONCE into a local, integrated entirely in that local, and
## written back ONCE. Measured 2026-08-28 with `tests/probes/enemy_prof.gd`: the previous
## version touched `global_position.x`, `.z` and `.y` as three separate property
## writes, and every one of them is a full `set_global_transform` that dirties the
## physics server AND every one of the ~30 mesh instances hanging off the rig. Three
## writes a tick times twenty-five bodies times three physics ticks in a slow frame is
## most of what the movement code cost. One write is one dirty.
func _motion(dt: float) -> void:
	var pos: Vector3 = _read_pos()
	var gy: float = map.height_at(pos.x, pos.z)

	if _leaping:
		_leap_t += dt
		velocity.y -= _gravity * dt
		if pos.y > gy + GROUND_GLUE:
			_leap_air = true
		elif _leap_air or _leap_t > 1.4:
			_leaping = false
			velocity.x *= 0.30
			velocity.z *= 0.30
	elif _grounded:
		var h := Vector3(velocity.x, 0.0, velocity.z)
		var accel: float = float(def.accel) * (0.55 if state == St.HURT else 1.0)
		var target_vel := _desired * (0.5 if _slow_t > 0.0 else 1.0)
		h = h.move_toward(target_vel, accel * dt)
		velocity.x = h.x
		velocity.z = h.z
	else:
		velocity.y -= _gravity * dt

	# --- horizontal, blocked by anything too steep to walk up --------------
	# Separation rides on top of the steered velocity rather than inside it, so it
	# applies even mid-swing when the brain has asked for no movement at all.
	var vel_h := Vector3(velocity.x, 0.0, velocity.z)
	if not _leaping:
		vel_h += _sep * SEP_SPEED
	var step := vel_h * dt
	var moved: float = step.length()
	if moved > 0.00001:
		var np := pos + step
		if not map.in_bounds(np.x, np.z):
			step = Vector3.ZERO
		else:
			var ngy: float = map.height_at(np.x, np.z)
			if ngy - gy > moved * CLIMB_GRADE + STEP_TOLERANCE:
				# Slide along the contour rather than stopping dead against a bank.
				var n := map.normal_at(np.x, np.z)
				var uphill := Vector3(-n.x, 0.0, -n.z)
				if uphill.length_squared() > 0.000001:
					uphill = uphill.normalized()
					step -= uphill * maxf(step.dot(uphill), 0.0)
				np = pos + step
				if not map.in_bounds(np.x, np.z):
					step = Vector3.ZERO
		if step != Vector3.ZERO:
			pos.x += step.x
			pos.z += step.z
			gy = map.height_at(pos.x, pos.z)

	# --- vertical ----------------------------------------------------------
	if _leaping or pos.y > gy + GROUND_GLUE:
		pos.y += velocity.y * dt
		if pos.y <= gy:
			pos.y = gy
			velocity.y = 0.0
			_grounded = true
		else:
			_grounded = false
	else:
		pos.y = gy
		velocity.y = 0.0
		_grounded = true

	# Rakshasas do not swim. If one is shouldered into the channel, it wades out.
	# Checked six times a second rather than sixty: the river does not move, and this
	# query is a distance-field sample plus two heightfield lookups.
	_wet_t -= dt
	if _wet_t <= 0.0:
		_wet_t = 0.16
		_in_water = map.water_depth_at(pos.x, pos.z) > 1.1
	if _in_water:
		var out := _shallow_direction()
		velocity.x = lerpf(velocity.x, out.x * float(def.walk) * 1.4, 1.0 - pow(0.01, dt))
		velocity.z = lerpf(velocity.z, out.z * float(def.walk) * 1.4, 1.0 - pow(0.01, dt))

	_write_pos(pos)


## Read the position the AI should integrate from. Normally that is `_pos`, which may
## be a physics tick ahead of the node; but anything else in the game may have moved
## the body outright — `setup()` places it, a test teleports it, a save restores it —
## and the node is the truth whenever it disagrees with what we last pushed.
func _read_pos() -> Vector3:
	var gp: Vector3 = global_position
	if gp != _pos_pushed:
		_pos = gp
		_pos_pushed = gp
	return _pos


## Move the body at most once per drawn frame. Skipping the write when nothing moved
## is what makes a standing crowd free: an idle rakshasa stops re-dirtying its own
## thirty mesh instances sixty times a second for a pose that never changes.
func _write_pos(pos: Vector3) -> void:
	_pos = pos
	var f: int = Engine.get_frames_drawn()
	if f == _pos_frame:
		return
	_pos_frame = f
	if pos != _pos_pushed:
		global_position = pos
		_pos_pushed = pos


## Crowd separation, applied as its own velocity rather than folded into the
## steering. Steering only runs in the states that move; an enemy standing in an
## attack wind-up has no steering at all, which is exactly when six of them pile into
## one solid block behind the player. This runs in every state, always.
const SEP_SPEED := 2.6
const SEP_MARGIN := 0.72


func _update_separation(dt: float) -> void:
	_sep_t -= dt
	if _sep_t > 0.0:
		return
	_sep_t = 0.18
	var acc := Vector3.ZERO
	var pos: Vector3 = global_position
	var mine: float = float(def.body_radius)
	var pts := _neighbour_points()
	var rads := _neighbour_radii()
	# The two lists can come from different sources: positions from the director's
	# active set, radii from a walk of the group when the director's cache is stale.
	# A quest spawning a new group mid-frame makes them disagree, which read past the
	# end of the radius array. Trust neither length; use the shorter.
	var n: int = mini(pts.size(), rads.size())
	for i in range(n):
		var orad: float = rads[i]
		if orad < 0.0:  # a corpse: neither pushes nor is pushed
			continue
		var dv: Vector3 = pos - pts[i]
		dv.y = 0.0
		var dl: float = dv.length()
		var want: float = mine + orad + SEP_MARGIN
		if dl > want:
			continue
		if dl < 0.001:
			# Either this enemy itself (its own entry is in the list) or one exactly
			# coincident with it. Self contributes nothing; a genuine overlap gets a
			# deterministic direction so two bodies do not both pick the same one and
			# stay welded together.
			if i == _sep_self:
				continue
			var a: float = float(get_instance_id() % 32)
			dv = Vector3(cos(a), 0.0, sin(a))
			dl = 0.001
		acc += dv.normalized() * (1.0 - dl / want)
	_sep = acc.limit_length(1.0)


func _shallow_direction() -> Vector3:
	var best := Vector3.ZERO
	var best_d := INF
	for i in range(8):
		var a: float = TAU * float(i) / 8.0
		var d := Vector3(cos(a), 0, sin(a))
		var q := global_position + d * 5.0
		var depth: float = map.water_depth_at(q.x, q.z)
		if depth < best_d:
			best_d = depth
			best = d
	return best


## Context steering. Fan candidate headings around what the brain wants, score each
## against the terrain the enemy would actually walk into, take the best. This is why
## a chase runs around a bluff instead of grinding into it, and why nothing walks
## into the river.
func _steer(dt: float, want: Vector3) -> Vector3:
	var base := Vector3(want.x, 0.0, want.z)
	if base.length_squared() < 0.0001:
		return Vector3.ZERO
	base = base.normalized()
	_steer_t -= dt
	if _steer_t > 0.0:
		return _steer_cache
	# The rank rule the brain and the pose already use: the handful in the player's
	# face re-plan seven times a second, the ones circling at the back of a crowd of
	# twenty-five do it half as often. A heading chosen 70 ms later than it could have
	# been is not a heading anyone can see on a body eight metres away.
	_steer_t = 0.14 if _rank < CROWD_FRONT else 0.28

	# Neighbours to push away from, gathered once for the whole fan — from the
	# director's per-frame position array rather than by reading twenty-five nodes'
	# global transforms inside every enemy's steer.
	var repel: Array[Vector3] = []
	var here: Vector3 = global_position
	var npts := _neighbour_points()
	for i in range(npts.size()):
		var dv: Vector3 = here - npts[i]
		dv.y = 0.0
		var dl: float = dv.length()
		if dl > 2.4 or dl < 0.001:
			continue
		repel.append(dv.normalized() * (1.0 - dl / 2.4))

	# Score the fan against the terrain first, WITHOUT touching the physics server.
	# Three economies, all measured with `tests/probes/enemy_prof.gd` on 2026-08-28 (25
	# enemies fighting, median of paired in-process differences):
	#
	#  * `slope_at` is four `height_at` calls behind a `normalized()`, and this loop
	#    already has the height difference along the candidate. `absf(dh)` over a
	#    fixed 2.4 m probe IS that gradient, so the extra thirty-six heightfield
	#    lookups per steer bought nothing the fan did not already know.
	#  * `water_depth_at` is a field sample PLUS a half-width PLUS a second field
	#    sample PLUS a heightfield lookup. `river_dist` alone answers "am I anywhere
	#    near the channel" in one sample, and only the candidates that actually are
	#    pay for the exact depth.
	#  * a ray per candidate is nine physics queries per steer. The terrain score
	#    already orders the fan, so only the best few are worth asking about and the
	#    first clear one wins.
	var pos: Vector3 = global_position
	var probe: float = 2.4
	var dirs: Array[Vector3] = []
	var scores := PackedFloat32Array()
	for i in range(9):
		var ang: float = deg_to_rad(-84.0 + 21.0 * float(i))
		var d := base.rotated(Vector3.UP, ang)
		var s: float = d.dot(base) * 1.6
		var q := pos + d * probe
		if not map.in_bounds(q.x, q.z):
			s -= 9.0
		else:
			var gy: float = map.height_at(q.x, q.z)
			var dh: float = gy - pos.y
			if dh > 1.6:
				s -= 4.5
			elif dh > 0.95:
				s -= 1.7
			if dh < -2.4:
				s -= 3.2
			s -= absf(dh) * 0.9
			if map.river_dist(Vector2(q.x, q.z)) < 22.0:
				var depth: float = map.water_depth_at(q.x, q.z)
				if depth > 0.55:
					s -= 7.0
				elif depth > 0.15:
					s -= 1.2
		for r in repel:
			s -= maxf(0.0, d.dot(r)) * 2.2
		dirs.append(d)
		scores.append(s)

	# Buildings and other solid props are on layer 8. Since movement no longer slides
	# along them, the steering has to see them — but only for the candidates the
	# terrain would actually pick.
	var order := [0, 1, 2, 3, 4, 5, 6, 7, 8]
	order.sort_custom(func(a: int, b: int) -> bool: return scores[a] > scores[b])
	var space := get_world_3d().direct_space_state
	var eye := pos + Vector3(0, float(def.eye_h) * 0.55, 0)
	var reach: float = probe + float(def.body_radius)
	var best: Vector3 = dirs[order[0]]
	for k in range(3):
		var d: Vector3 = dirs[order[k]]
		var rq := PhysicsRayQueryParameters3D.create(eye, eye + d * reach)
		rq.collision_mask = 8
		if space.intersect_ray(rq).is_empty():
			best = d
			break
	_steer_cache = best
	return best


func _neighbours() -> Array:
	if director != null and director.has_method("active_enemies"):
		return director.active_enemies()
	return get_tree().get_nodes_in_group("enemy")


## Neighbour positions as a flat array. The director gathers every active enemy's
## position once per frame; without it, separation and the steering fan each read
## `global_position` off every other enemy, which is O(n*n) `get_global_transform`
## calls per pass and was the largest single cost in a crowd of twenty-five.
## Falls back to walking the group when there is no director (tests, scripted scenes).
var _sep_self: int = -1


func _neighbour_points() -> PackedVector3Array:
	if director != null and director.has_method("active_positions"):
		var pts: PackedVector3Array = director.active_positions()
		var list: Array = director.active_enemies()
		_sep_self = list.find(self)
		if pts.size() == list.size():
			return pts
	var out := PackedVector3Array()
	var group := get_tree().get_nodes_in_group("enemy")
	_sep_self = group.find(self)
	for o in group:
		out.append((o as Node3D).global_position)
	return out


func _neighbour_radii() -> PackedFloat32Array:
	if director != null and director.has_method("active_radii"):
		var r: PackedFloat32Array = director.active_radii()
		if r.size() == _neighbour_count():
			return r
	var out := PackedFloat32Array()
	for o in get_tree().get_nodes_in_group("enemy"):
		var oe := o as Enemy
		out.append(float(oe.def.get("body_radius", 0.44)) if oe != null and oe.is_alive() else -1.0)
	return out


func _neighbour_count() -> int:
	if director != null and director.has_method("active_positions"):
		return (director.active_positions() as PackedVector3Array).size()
	return get_tree().get_nodes_in_group("enemy").size()


# --- facing ----------------------------------------------------------------
static func _approach_angle(cur: float, target: float, max_step: float) -> float:
	var d: float = wrapf(target - cur, -PI, PI)
	return cur + clampf(d, -max_step, max_step)


func _face(target_yaw: float, dt: float, rate: float) -> void:
	rotation.y = _approach_angle(rotation.y, target_yaw, rate * dt)


func _face_dir(dir: Vector3, dt: float, rate: float) -> void:
	if dir.length_squared() < 0.0001:
		return
	_face(atan2(-dir.x, -dir.z), dt, rate)


func _face_point(p: Vector3, dt: float, rate: float) -> void:
	var to := p - global_position
	to.y = 0.0
	_face_dir(to, dt, rate)


func _facing_to(p: Vector3) -> float:
	var to := p - global_position
	return atan2(-to.x, -to.z)


# ===========================================================================
#  PRESENTATION
# ===========================================================================
func _animate(dt: float) -> void:
	var sp := Vector3(velocity.x, 0.0, velocity.z).length()
	if rig != null:
		rig.look_target = _look_target
		rig.look_weight = _look_w
		rig.attack_swing = _swing
		rig.aim_weight = _aim_w
		rig.aim_dir = _aim_dir
		(
			rig
			. animate(
				dt,
				{
					"speed": sp,
					"on_floor": _grounded,
					"air_time": _air_t,
					"dodge": 0.0,
					"crouch": 0.0,
				}
			)
		)
		if _string != null:
			var pull: float = _aim_w
			_string.position.z = 0.14 - pull * 0.19
			_string.scale = Vector3(1.0, 1.0, 1.0 + pull * 0.4)
	elif beast != null:
		beast.look_target = _look_target
		beast.look_weight = _look_w
		beast.lunge = _pounce
		beast.maw = _maw
		beast.animate(dt, {"speed": sp, "on_floor": _grounded})


## The collapse, driven on the render frame like every other pose.
func _animate_dead(dt: float) -> void:
	if rig != null:
		rig.dead_amount = minf(1.0, rig.dead_amount + dt * 1.7)
		rig.animate(dt, {"speed": 0.0, "on_floor": true})
	elif beast != null:
		beast.dead_amount = minf(1.0, beast.dead_amount + dt * 1.7)
		beast.animate(dt, {"speed": 0.0, "on_floor": true})


func _on_own_footstep(_side: String, pos: Vector3, sp: float) -> void:
	if _focus_d > 34.0 or sp < 0.5 or not _grounded:
		return
	var surf := "grass"
	match map.biome_at(pos.x, pos.z):
		WorldMap.Biome.PATH, WorldMap.Biome.VILLAGE, WorldMap.Biome.FIELD:
			surf = "dirt"
		WorldMap.Biome.ROCK, WorldMap.Biome.MOUNTAIN:
			surf = "stone"
		WorldMap.Biome.SAND, WorldMap.Biome.RIVERBED:
			surf = "dirt"
	AudioDirector.play_3d("footstep_%s_%d" % [surf, 1 + _rng.randi() % 4], pos, lerpf(-20.0, -11.0, clampf(sp / 8.0, 0.0, 1.0)))


# ===========================================================================
#  DAMAGE / DEATH  — the ARCHITECTURE.md contract
# ===========================================================================
func take_damage(amount: float, source: Node = null, hit_pos: Vector3 = Vector3.ZERO, crit: bool = false) -> void:
	if not _alive:
		return
	# Rakshasas do not kill each other; a stray arrow from an ally is not a fight.
	if source is Enemy:
		return
	health -= amount
	EventBus.enemy_damaged.emit(self, amount, crit, hit_pos)
	AudioDirector.play_3d(String(def.hurt_sfx[_rng.randi() % def.hurt_sfx.size()]), global_position + Vector3(0, float(def.eye_h), 0), -3.0)

	if source is Node3D:
		var sp: Vector3 = (source as Node3D).global_position
		# Capture BEFORE the alarm. `alarm(pos, true)` sets `committed`, so testing it
		# afterwards is a branch that can never be taken: an arrow in the back of an
		# unaware rakshasa ran the commit path zero times and `EventBus.enemy_alerted`
		# never fired for the one event most worth hearing. `alert_from` had this
		# right; this did not.
		var was_committed := perc.committed
		perc.alarm(sp, true)
		if not was_committed:
			_on_commit()
		var away := global_position - sp
		away.y = 0.0
		if away.length_squared() > 0.001:
			var kb: float = float(def.knockback) * clampf(amount / 25.0, 0.4, 1.6)
			away = away.normalized()
			velocity.x += away.x * kb
			velocity.z += away.z * kb
	if director != null and director.has_method("alert_near"):
		director.alert_near(global_position, 20.0, self, hit_pos)

	if health <= 0.0:
		_die()
		return

	# Poise: a champion shrugs off a light hit and keeps swinging; a beast never does.
	if crit or amount >= float(def.poise) or state == St.IDLE or state == St.PATROL:
		if rig != null:
			rig.hurt_amount = clampf(amount / 28.0, 0.3, 1.0)
		if beast != null:
			beast.hurt_amount = clampf(amount / 28.0, 0.3, 1.0)
		if state != St.ATTACK or amount >= float(def.poise) * 1.6:
			_leaping = false
			_enter(St.HURT)
	elif state != St.ATTACK:
		_enter(St.CHASE)


func is_alive() -> bool:
	return _alive


## True when the body is resting on the terrain. False only while it is genuinely
## airborne — mid-leap, or knocked off a ledge.
func is_grounded() -> bool:
	return _grounded


func health_fraction() -> float:
	return clampf(health / maxf(max_health, 0.001), 0.0, 1.0)


func apply_status(status_kind: String, duration: float) -> void:
	if not _alive:
		return
	match status_kind:
		"burn":
			_burn_t = maxf(_burn_t, duration)
		"slow":
			_slow_t = maxf(_slow_t, duration)


func display_name() -> String:
	if boss_title != "":
		return boss_title
	return EnemyTypes.display_name(kind)


func state_name() -> String:
	return ST_NAME[state]


func awareness() -> float:
	return perc.awareness


func _die() -> void:
	_release_attack()
	_alive = false
	health = 0.0
	state = St.DEAD
	_dead_t = 0.0
	_sunk = 0.0
	_leaping = false
	velocity = Vector3.ZERO
	# Stop being a target and stop being an obstacle, but keep the node so the corpse
	# can settle and be looked at.
	remove_from_group("enemy")
	collision_layer = 0
	collision_mask = 0
	GameState.kills += 1
	AudioDirector.play_3d(
		String(def.death_sfx[_rng.randi() % def.death_sfx.size()]), global_position + Vector3(0, float(def.eye_h) * 0.6, 0), -1.0
	)
	_drop_loot()
	died.emit(self)
	EventBus.enemy_died.emit(self)


func _drop_loot() -> void:
	var items := EnemyTypes.roll_loot(kind, _rng)
	if items.is_empty():
		return
	var parent: Node = get_parent()
	if parent == null:
		return
	var p := global_position + Vector3(_rng.randf_range(-0.4, 0.4), 0.0, _rng.randf_range(-0.4, 0.4))
	p.y = map.height_at(p.x, p.z) + 0.04
	var l := LootDrop.drop(parent, p, items, kind)
	if l != null and director != null and director.has_method("register_loot"):
		director.register_loot(l)


## The corpse: collapse through ProcRig's dead pose, lie there long enough to be
## looted and looked at, then sink out of the world rather than popping.
func _tick_dead(dt: float) -> void:
	_dead_t += dt
	var pos: Vector3 = _read_pos()
	var gy: float = map.height_at(pos.x, pos.z)
	if _sunk <= 0.0:
		pos.y = lerpf(pos.y, gy, 1.0 - pow(0.001, dt))
		_write_pos(pos)
	if _focus_d >= ANIM_DIST:
		if rig != null:
			rig.dead_amount = 1.0
		if beast != null:
			beast.dead_amount = 1.0
	if _dead_t > DESPAWN_DELAY:
		_sunk += dt
		pos.y = gy - (_sunk / SINK_TIME) * 2.4
		_write_pos(pos)
		if _sunk >= SINK_TIME:
			queue_free()


# --- helpers ---------------------------------------------------------------
func _find_player() -> Node3D:
	if _player != null and is_instance_valid(_player):
		return _player
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		return null
	_player = ps[0] as Node3D
	return _player


## Used by the director to wake a squad when one of them sees something.
func alert_from(pos: Vector3, full: bool) -> void:
	if not _alive:
		return
	var was := perc.committed
	perc.alarm(pos, full)
	if perc.committed and not was:
		EventBus.enemy_alerted.emit(self)
	if state == St.IDLE or state == St.PATROL:
		_enter(St.INVESTIGATE if not full else St.CHASE)
