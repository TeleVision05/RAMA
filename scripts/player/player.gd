class_name Player
extends CharacterBody3D
## Rama. Third-person controller: grounded movement with acceleration, sprint, jump
## with coyote time and input buffering, a dodge roll with invulnerability frames,
## bow aiming with a draw charge, a melee combo, wading and swimming.
##
## The visual is a ProcRig — no imported character, no animation clips. Everything the
## body does is computed in code, which is why the state machine below also drives the
## pose directly rather than triggering animation names.

signal state_changed(state: String)

enum S { IDLE, MOVE, JUMP, FALL, LAND, DODGE, MELEE, HURT, DEAD, SWIM }

# --- tuning ---------------------------------------------------------------
const SPEED_WALK := 2.15
const SPEED_RUN := 5.10
const SPEED_SPRINT := 8.00
const SPEED_AIM := 1.85
const SPEED_SWIM := 2.60
const ACCEL_GROUND := 28.0
const ACCEL_AIR := 8.0
const FRICTION := 16.0
const JUMP_VELOCITY := 8.6
const TURN_RATE := 13.0
const COYOTE_TIME := 0.14
const JUMP_BUFFER := 0.16
const DODGE_SPEED := 11.5
const DODGE_TIME := 0.44
const DODGE_IFRAME := Vector2(0.06, 0.32)
const WADE_DEPTH := 0.55
const SWIM_DEPTH := 1.45

const STAM_SPRINT := 11.0
const STAM_DODGE := 20.0
const STAM_DRAW := 5.0
const STAM_MELEE := 9.0
const STAM_REGEN := 19.0
const STAM_REGEN_DELAY := 0.85

const BOW_DRAW_TIME := 0.80
const ARROW_SPEED_MIN := 34.0
const ARROW_SPEED_MAX := 74.0
const MELEE_RANGE := 2.35
const MELEE_ARC := deg_to_rad(105.0)

# --- refs -----------------------------------------------------------------
var rig: ProcRig
var world: WorldRoot
var cam_rig: Node3D  # PlayerCamera, set by the game
var bow_node: Node3D
var sword_node: Node3D
var quiver_node: Node3D

# --- state ----------------------------------------------------------------
var state: int = S.IDLE
var _state_name: String = "idle"
var facing_yaw: float = 0.0
var _coyote: float = 0.0
var _jump_buf: float = 0.0
var _air_time: float = 0.0
var _dodge_t: float = -1.0
var _dodge_dir: Vector3 = Vector3.FORWARD
var _melee_t: float = -1.0
var _melee_index: int = 0
var _melee_hit_done: bool = false
var _melee_queued: bool = false
var _hurt_t: float = 0.0
var _stam_delay: float = 0.0
var _invuln: float = 0.0
var _dead: bool = false
var _land_impact: float = 0.0
var _parry_t: float = -1.0
var _parry_cd: float = 0.0
var _counter_buff: float = 0.0

var aiming: bool = false
var draw_charge: float = 0.0
var using_bow: bool = true
var crouching: bool = false
var water_depth: float = 0.0
var swimming: bool = false

var _interact_target: Node = null
var _input_locked: bool = false
var _last_footstep_surface: String = "grass"


func _ready() -> void:
	add_to_group("player")
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_max_angle = deg_to_rad(52.0)
	floor_snap_length = 0.45
	slide_on_ceiling = true
	collision_layer = 2
	collision_mask = 1 | 4 | 8

	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.34
	cap.height = 1.72
	col.shape = cap
	col.position = Vector3(0, 0.86, 0)
	add_child(col)

	rig = ProcRig.new()
	(
		rig
		. configure(
			{
				"model": "king",
				"seed": 11,
				"skin": "skin_warm",
				"skin_tint": Color(0.55, 0.72, 0.92),
				"cloth": "cloth_saffron",
				"cloth2": "cloth_white",
				"tilaka": true,
				"channavira": true,
				"topknot": true,
				"jewellery": true,
				"sash": true,
			}
		)
	)
	add_child(rig)
	rig.build()
	rig.footstep.connect(_on_footstep)

	_attach_gear()
	set_physics_process(true)


func _attach_gear() -> void:
	bow_node = Weapons.bow()
	rig.hand_attach["L"].add_child(bow_node)
	bow_node.position = Vector3(0, -0.04, 0.02)
	bow_node.rotation = Vector3(0.10, 0.0, 1.20)

	sword_node = Weapons.sword()
	rig.hand_attach["R"].add_child(sword_node)
	sword_node.position = Vector3(0, -0.06, 0.02)
	sword_node.rotation = Vector3(-0.35, 0, 0)
	sword_node.visible = false

	quiver_node = Weapons.quiver()
	rig.chest.add_child(quiver_node)
	quiver_node.position = Vector3(-0.10, -0.02, 0.13)
	quiver_node.rotation = Vector3(0.30, 0, -0.42)


func set_world(w: WorldRoot) -> void:
	world = w
	rig.ground_fn = func(x, z): return w.map.height_at(x, z)


func lock_input(locked: bool) -> void:
	_input_locked = locked
	if locked:
		aiming = false
		draw_charge = 0.0


# ==========================================================================
func _physics_process(delta: float) -> void:
	if _dead:
		velocity = velocity.move_toward(Vector3.ZERO, 30.0 * delta)
		move_and_slide()
		rig.dead_amount = minf(1.0, rig.dead_amount + delta * 2.4)
		rig.animate(delta, {"speed": 0.0, "on_floor": true})
		return

	_tick_timers(delta)
	_update_water()

	var wish := _wish_direction()
	if swimming:
		_swim(delta, wish)
	else:
		_ground_and_air(delta, wish)

	_update_combat(delta)
	_update_stamina(delta)
	_update_interaction()
	move_and_slide()
	_drive_rig(delta)
	_publish_state()


func _tick_timers(delta: float) -> void:
	if is_on_floor():
		if _air_time > 0.30:
			_land_impact = clampf(_air_time * 0.9, 0.0, 1.0)
			EventBus.hit_feedback.emit(global_position, _land_impact * 0.35, "land")
			AudioDirector.play_3d("land_hard" if _air_time > 0.6 else "land_soft", global_position, -6.0)
		_coyote = COYOTE_TIME
		_air_time = 0.0
	else:
		_coyote = maxf(0.0, _coyote - delta)
		_air_time += delta
	_jump_buf = maxf(0.0, _jump_buf - delta)
	_invuln = maxf(0.0, _invuln - delta)
	_hurt_t = maxf(0.0, _hurt_t - delta)
	_land_impact = maxf(0.0, _land_impact - delta * 2.5)
	_parry_cd = maxf(0.0, _parry_cd - delta)
	_counter_buff = maxf(0.0, _counter_buff - delta)
	if _parry_t >= 0.0:
		_parry_t += delta
		if _parry_t >= 0.38:
			_parry_t = -1.0
	if _dodge_t >= 0.0:
		_dodge_t += delta
		if _dodge_t >= DODGE_TIME:
			_dodge_t = -1.0
	if _melee_t >= 0.0:
		_melee_t += delta


func _update_water() -> void:
	if world == null:
		return
	water_depth = world.map.water_depth_at(global_position.x, global_position.z)
	var was := swimming
	swimming = water_depth > SWIM_DEPTH
	if swimming != was:
		AudioDirector.play_3d("footstep_water_1", global_position, -3.0)


func _wish_direction() -> Vector3:
	if _input_locked:
		return Vector3.ZERO
	var iv := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if iv.length_squared() < 0.0001:
		return Vector3.ZERO
	var basis_yaw: float = cam_rig.yaw if cam_rig else facing_yaw
	var fwd := Vector3(-sin(basis_yaw), 0, -cos(basis_yaw))
	var right := Vector3(cos(basis_yaw), 0, -sin(basis_yaw))
	return (right * iv.x + fwd * -iv.y).normalized()


func _target_speed() -> float:
	if aiming:
		return SPEED_AIM
	if crouching:
		return SPEED_WALK * 0.92
	if Input.is_action_pressed("sprint") and GameState.stamina > 1.0 and not _input_locked:
		return SPEED_SPRINT
	return SPEED_RUN


func _ground_and_air(delta: float, wish: Vector3) -> void:
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 22.0) * delta
	# Wading slows you down and makes the water splash.
	var wade: float = clampf(water_depth / SWIM_DEPTH, 0.0, 1.0)

	if not _input_locked and Input.is_action_just_pressed("crouch"):
		crouching = not crouching
	if not _input_locked and Input.is_action_pressed("sprint") and wish.length_squared() > 0.01:
		crouching = false

	if not _input_locked and Input.is_action_just_pressed("jump"):
		_jump_buf = JUMP_BUFFER
		crouching = false
	if _jump_buf > 0.0 and _coyote > 0.0 and _dodge_t < 0.0 and _melee_t < 0.0:
		velocity.y = JUMP_VELOCITY * lerpf(1.0, 0.6, wade)
		_jump_buf = 0.0
		_coyote = 0.0
		_set_state(S.JUMP)
		AudioDirector.play_3d("jump", global_position, -8.0)

	if not _input_locked and Input.is_action_just_pressed("dodge") and _dodge_t < 0.0 and is_on_floor() and GameState.stamina >= STAM_DODGE:
		_dodge_t = 0.0
		crouching = false
		_dodge_dir = wish if wish.length_squared() > 0.01 else -global_transform.basis.z
		GameState.stamina -= STAM_DODGE
		_stam_delay = STAM_REGEN_DELAY
		_invuln = DODGE_IFRAME.y
		aiming = false
		draw_charge = 0.0
		_set_state(S.DODGE)
		AudioDirector.play_3d("sword_swing_1", global_position, -12.0)

	var horiz := Vector3(velocity.x, 0, velocity.z)
	if _dodge_t >= 0.0:
		var t: float = _dodge_t / DODGE_TIME
		var sp: float = DODGE_SPEED * (1.0 - smoothstep(0.35, 1.0, t))
		horiz = _dodge_dir * sp
		facing_yaw = atan2(-_dodge_dir.x, -_dodge_dir.z)
	elif wish.length_squared() > 0.001:
		var speed := _target_speed() * lerpf(1.0, 0.42, wade)
		if _melee_t >= 0.0:
			speed *= 0.35
		var accel: float = ACCEL_GROUND if is_on_floor() else ACCEL_AIR
		horiz = horiz.move_toward(wish * speed, accel * delta)
		if not aiming:
			var want := atan2(-wish.x, -wish.z)
			facing_yaw = _approach_angle(facing_yaw, want, TURN_RATE * delta)
	else:
		var f: float = FRICTION if is_on_floor() else 1.2
		horiz = horiz.move_toward(Vector3.ZERO, f * delta)

	if aiming and cam_rig:
		facing_yaw = _approach_angle(facing_yaw, cam_rig.yaw, 18.0 * delta)

	velocity.x = horiz.x
	velocity.z = horiz.z
	rotation.y = facing_yaw

	if is_on_floor() and _dodge_t < 0.0 and _melee_t < 0.0 and _hurt_t <= 0.0:
		_set_state(S.MOVE if horiz.length() > 0.25 else S.IDLE)
	elif not is_on_floor() and _dodge_t < 0.0:
		_set_state(S.JUMP if velocity.y > 0.5 else S.FALL)


func _swim(delta: float, wish: Vector3) -> void:
	_set_state(S.SWIM)
	crouching = false
	var surface := world.map.water_y_at(global_position.x, global_position.z)
	var target_y := surface - 0.55
	velocity.y = lerpf(velocity.y, (target_y - global_position.y) * 4.0, 1.0 - pow(0.001, delta))
	if not _input_locked and Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY * 0.75
		AudioDirector.play_3d("jump", global_position, -6.0)
	var horiz := Vector3(velocity.x, 0, velocity.z)
	if wish.length_squared() > 0.001:
		horiz = horiz.move_toward(wish * SPEED_SWIM, 6.0 * delta)
		facing_yaw = _approach_angle(facing_yaw, atan2(-wish.x, -wish.z), 6.0 * delta)
	else:
		horiz = horiz.move_toward(Vector3.ZERO, 4.0 * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z
	rotation.y = facing_yaw


static func _approach_angle(cur: float, target: float, max_step: float) -> float:
	var d: float = wrapf(target - cur, -PI, PI)
	return cur + clampf(d, -max_step, max_step)


# --- combat ---------------------------------------------------------------
func _update_combat(delta: float) -> void:
	if _input_locked or _dodge_t >= 0.0:
		aiming = false
		draw_charge = maxf(0.0, draw_charge - delta * 3.0)
		return

	_handle_hotkeys()

	if Input.is_action_just_pressed("swap_weapon"):
		using_bow = not using_bow
		bow_node.visible = using_bow
		sword_node.visible = not using_bow
		aiming = false
		draw_charge = 0.0
		AudioDirector.play_2d("sword_unsheathe" if not using_bow else "arrow_pickup", -8.0)

	# Kshatriya Parry (F, or RMB when wielding the Nandaka sword).
	var want_parry: bool = Input.is_action_just_pressed("parry") or (not using_bow and Input.is_action_just_pressed("aim"))
	if want_parry and _parry_cd <= 0.0 and _parry_t < 0.0:
		_start_parry()

	if using_bow:
		var want_aim: bool = Input.is_action_pressed("aim") and GameState.stamina > 0.5
		if want_aim and not aiming:
			AudioDirector.play_2d("bow_draw", -6.0)
		# Allow LMB while aiming to loose immediately and keep drawing the next arrow,
		# OR releasing RMB to loose (keeping playtest.gd & acceptance_test.gd 100% compatible).
		if aiming and Input.is_action_just_pressed("attack") and draw_charge > 0.16:
			_fire_arrow()
		elif aiming and not want_aim and draw_charge > 0.16:
			_fire_arrow()
		aiming = want_aim
		if aiming:
			var was := draw_charge
			draw_charge = minf(1.0, draw_charge + delta / BOW_DRAW_TIME)
			if was < 1.0 and draw_charge >= 1.0:
				AudioDirector.play_2d("bow_full", -14.0)
			GameState.stamina = maxf(0.0, GameState.stamina - STAM_DRAW * delta)
			_stam_delay = STAM_REGEN_DELAY
		else:
			draw_charge = maxf(0.0, draw_charge - delta * 3.0)
	else:
		aiming = false
		draw_charge = 0.0
		if Input.is_action_just_pressed("attack"):
			if _melee_t < 0.0 and GameState.stamina >= STAM_MELEE:
				_start_melee()
			elif _melee_t > 0.35:
				_melee_queued = true

	if _melee_t >= 0.0:
		var dur := _melee_duration()
		var norm: float = _melee_t / dur
		if not _melee_hit_done and norm > 0.34 and norm < 0.62:
			_melee_hit_done = true
			_do_melee_hit()
		if _melee_t >= dur:
			if _melee_queued and GameState.stamina >= STAM_MELEE:
				_melee_queued = false
				_start_melee()
			else:
				_melee_t = -1.0
				_melee_index = 0
				_melee_queued = false


func _handle_hotkeys() -> void:
	if Input.is_action_just_pressed("quick_heal"):
		var used := false
		for item_id in ["healing_salve", "healing_herb", "herb", "shabari_berries", "mango"]:
			if GameState.use_item(item_id):
				used = true
				break
		if not used:
			AudioDirector.play_2d("ui_close", -10.0)
			EventBus.notify.emit("No Healing Provisions", "Gather herbs or salves to heal.", "warn")

	var next_astra := -1
	if Input.is_action_just_pressed("cycle_astra"):
		next_astra = (GameState.active_astra + 1) % 5
	elif Input.is_action_just_pressed("astra_1"):
		next_astra = 0
	elif Input.is_action_just_pressed("astra_2"):
		next_astra = 1
	elif Input.is_action_just_pressed("astra_3"):
		next_astra = 2
	elif Input.is_action_just_pressed("astra_4"):
		next_astra = 3
	elif Input.is_action_just_pressed("astra_5"):
		next_astra = 4
	if next_astra >= 0 and next_astra != GameState.active_astra:
		GameState.active_astra = next_astra
		AudioDirector.play_2d("ui_click", -6.0)
		var aname: String = GameState.ASTRA_NAMES[next_astra]
		var mantra: String = GameState.ASTRA_MANTRAS[next_astra]
		var sub: String = GameState.ASTRA_SUBTITLES[next_astra]
		EventBus.notify.emit(aname + " — " + mantra, sub, "info")


func _start_parry() -> void:
	_parry_t = 0.0
	_parry_cd = 0.65
	AudioDirector.play_3d("sword_swing_2", global_position, -6.0)
	if get_parent():
		var ward := MeshInstance3D.new()
		ward.mesh = MeshKit.tube(0.05, [[0.0, 0.72], [0.5, 0.76], [1.0, 0.72]], 18)
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(1.0, 0.85, 0.32, 0.78)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		ward.material_override = m
		get_parent().add_child(ward)
		ward.global_position = global_position + Vector3(0, 1.05, 0)
		var tw := ward.create_tween()
		tw.set_parallel(true)
		tw.tween_property(ward, "scale", Vector3.ONE * 1.45, 0.35)
		tw.tween_property(m, "albedo_color:a", 0.0, 0.35)
		tw.chain().tween_callback(ward.queue_free)


func _melee_duration() -> float:
	return [0.62, 0.58, 0.78][_melee_index % 3]


func _start_melee() -> void:
	_melee_t = 0.0
	_melee_hit_done = false
	_melee_index = (_melee_index + 1) % 3
	crouching = false
	GameState.stamina -= STAM_MELEE
	_stam_delay = STAM_REGEN_DELAY
	_set_state(S.MELEE)
	EventBus.melee_swing.emit(_melee_index)
	AudioDirector.play_3d("sword_swing_%d" % (1 + _melee_index % 3), global_position, -4.0)
	_spawn_sword_slash_arc()


func _spawn_sword_slash_arc() -> void:
	if get_parent() == null:
		return
	var arc := MeshInstance3D.new()
	var path := PackedVector3Array()
	var rads := PackedFloat32Array()
	var steps := 9
	var dir_sign := 1.0 if (_melee_index % 2 == 1) else -1.0
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var ang: float = lerpf(-1.05, 1.05, t) * dir_sign
		var dy: float = lerpf(0.28, -0.22, t) if (_melee_index % 3 != 2) else lerpf(0.45, -0.35, t)
		path.append(Vector3(sin(ang) * 1.35, dy, -cos(ang) * 1.35))
		rads.append(sin(t * PI) * 0.065 + 0.006)
	arc.mesh = MeshKit.sweep(path, rads, 6, 0.22, Vector3.UP)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.88, 0.42, 0.85) if _counter_buff > 0.0 else Color(0.92, 0.95, 1.0, 0.68)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	arc.material_override = m
	get_parent().add_child(arc)
	arc.global_position = global_position + Vector3(0, 1.15, 0)
	arc.rotation.y = facing_yaw
	var tw := arc.create_tween()
	tw.set_parallel(true)
	tw.tween_property(arc, "scale", Vector3.ONE * 1.18, 0.25)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.25)
	tw.chain().tween_callback(arc.queue_free)


func _do_melee_hit() -> void:
	var origin := global_position + Vector3(0, 1.0, 0)
	var fwd := -global_transform.basis.z
	var hit_any := false
	var countered := _counter_buff > 0.0
	if countered:
		_counter_buff = 0.0
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node3D):
			continue
		var to: Vector3 = e.global_position - origin
		to.y *= 0.55
		var d: float = to.length()
		if d > MELEE_RANGE:
			continue
		if fwd.angle_to(to.normalized()) > MELEE_ARC * 0.5:
			continue
		var dmg: float = [22.0, 20.0, 34.0][_melee_index % 3] * (2.0 if countered else 1.0)
		var crit: bool = (_melee_index % 3 == 2) or countered
		if e.has_method("take_damage"):
			e.take_damage(dmg, self, e.global_position + Vector3(0, 1.0, 0), crit)
		hit_any = true
	if hit_any:
		GameState.prana = minf(GameState.max_prana, GameState.prana + 6.0)
		AudioDirector.play_3d("sword_hit_flesh", global_position + fwd * 1.2, -2.0)
		EventBus.hit_feedback.emit(global_position + fwd * 1.4, 0.75, "melee")
	else:
		# A whiffed swing should still feel like effort.
		EventBus.hit_feedback.emit(global_position, 0.12, "whiff")


func _fire_arrow() -> void:
	if GameState.arrows <= 0:
		AudioDirector.play_2d("ui_close", -10.0)
		EventBus.notify.emit("Out of arrows", "Gather more, or use the sword (Q).", "warn")
		return
	if bool(GameState.get_flag("akshaya_tunira", false)):
		GameState.arrows = maxi(1, GameState.arrows - 1)
	else:
		GameState.arrows -= 1
	var charge := draw_charge
	draw_charge = 0.0
	var astra := GameState.active_astra
	var cost: float = float(GameState.ASTRA_COSTS[clampi(astra, 0, 4)])
	if astra > 0:
		if GameState.prana >= cost:
			GameState.prana -= cost
		else:
			astra = 0
			EventBus.notify.emit("Low Prana", "Fired standard Shara shaft.", "warn")
	var origin: Vector3 = (rig.hand_attach["L"] as Node3D).global_position + Vector3(0, 0.05, 0)
	var dir := aim_direction()
	var speed: float = lerpf(ARROW_SPEED_MIN, ARROW_SPEED_MAX, charge) * (1.22 if astra >= 3 else 1.0)
	var base_dmg: float = lerpf(14.0, 48.0, charge) * (1.35 if astra == 4 else (1.15 if astra > 0 else 1.0))
	var a := Arrow.spawn(get_parent(), origin, dir * speed, self, base_dmg, charge, astra)
	if a and world:
		a.world = world
	EventBus.arrow_fired.emit(origin, dir, charge)
	AudioDirector.play_3d("bow_release", global_position, -2.0)
	EventBus.hit_feedback.emit(global_position, 0.20 + charge * 0.28 + (0.20 if astra > 0 else 0.0), "shoot")


## Where the bow is pointing: the camera's aim ray, so what the crosshair covers is
## what gets hit.
func aim_direction() -> Vector3:
	if cam_rig and cam_rig.has_method("aim_ray"):
		var r: Dictionary = cam_rig.aim_ray()
		var from: Vector3 = (rig.hand_attach["L"] as Node3D).global_position
		return (r.point - from).normalized()
	return -global_transform.basis.z


# --- stamina / damage -----------------------------------------------------
func _update_stamina(delta: float) -> void:
	var sprinting: bool = (
		Input.is_action_pressed("sprint") and not _input_locked and Vector3(velocity.x, 0, velocity.z).length() > 3.0 and is_on_floor()
	)
	if sprinting:
		GameState.stamina = maxf(0.0, GameState.stamina - STAM_SPRINT * delta)
		_stam_delay = STAM_REGEN_DELAY
	elif _stam_delay > 0.0:
		_stam_delay -= delta
	else:
		GameState.stamina = minf(GameState.max_stamina, GameState.stamina + STAM_REGEN * delta)

	if GameState.health < GameState.max_health and not GameState.in_combat:
		GameState.health = minf(GameState.max_health, GameState.health + 2.6 * delta)

	var is_day: bool = GameState.time_of_day >= 6.0 and GameState.time_of_day <= 18.5
	var prana_rate: float = 5.5 if is_day else 3.5
	if GameState.prana < GameState.max_prana:
		GameState.prana = minf(GameState.max_prana, GameState.prana + prana_rate * delta)


func take_damage(amount: float, source: Node = null, _hit_pos: Vector3 = Vector3.ZERO, _crit: bool = false) -> void:
	if _dead or _invuln > 0.0:
		return
	if _dodge_t >= DODGE_IFRAME.x and _dodge_t <= DODGE_IFRAME.y:
		return
	if _parry_t >= 0.0:
		_parry_t = -1.0
		_invuln = 0.50
		_counter_buff = 3.5
		GameState.prana = minf(GameState.max_prana, GameState.prana + 22.0)
		GameState.stamina = minf(GameState.max_stamina, GameState.stamina + 18.0)
		AudioDirector.play_3d("bell_temple", global_position, -4.0)
		EventBus.hit_feedback.emit(global_position, 0.9, "block")
		EventBus.notify.emit("Kshatriya Parry!", "Attack deflected — Counter-Strike primed (+22 Prana).", "quest")
		if source and is_instance_valid(source) and source.has_method("take_damage"):
			var src_pos: Vector3 = (source as Node3D).global_position if source is Node3D else global_position
			source.take_damage(15.0, self, src_pos + Vector3(0, 1.0, 0), true)
		return
	GameState.health = maxf(0.0, GameState.health - amount)
	_hurt_t = 0.34
	_invuln = 0.45
	rig.hurt_amount = clampf(amount / 25.0, 0.25, 1.0)
	EventBus.player_damaged.emit(amount, source)
	EventBus.hit_feedback.emit(global_position, clampf(amount / 20.0, 0.3, 1.2), "hurt")
	AudioDirector.play_2d("player_hurt_%d" % (1 + randi() % 3), -3.0)
	if source is Node3D:
		var away: Vector3 = (global_position - (source as Node3D).global_position).normalized()
		velocity += away * 3.4 + Vector3.UP * 1.6
	if GameState.health <= 0.0:
		_die()


func heal(amount: float) -> void:
	GameState.health = minf(GameState.max_health, GameState.health + amount)
	EventBus.player_healed.emit(amount)
	AudioDirector.play_2d("heal", -5.0)


func _die() -> void:
	_dead = true
	_set_state(S.DEAD)
	aiming = false
	EventBus.player_died.emit()
	AudioDirector.play_2d("player_death", -1.0)


func revive_at(pos: Vector3) -> void:
	_dead = false
	rig.dead_amount = 0.0
	GameState.health = GameState.max_health * 0.6
	GameState.stamina = GameState.max_stamina
	global_position = pos
	velocity = Vector3.ZERO
	_set_state(S.IDLE)


# --- interaction ----------------------------------------------------------
func _update_interaction() -> void:
	var best: Node = null
	var best_score := -1.0
	var eye := global_position + Vector3(0, 1.5, 0)
	var fwd := -global_transform.basis.z
	for n in get_tree().get_nodes_in_group("interactable"):
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		var np: Vector3 = (n as Node3D).global_position
		var to := np - eye
		var d := to.length()
		var range_v: float = n.get("interact_range") if n.get("interact_range") != null else 3.2
		if d > range_v:
			continue
		if n.has_method("can_interact") and not n.can_interact(self):
			continue
		var align: float = fwd.dot(to.normalized())
		if align < 0.10:
			continue
		var score: float = align * 2.0 - d / range_v
		if score > best_score:
			best_score = score
			best = n
	if best != _interact_target:
		_interact_target = best
		var prompt := ""
		if best and best.has_method("interact_prompt"):
			prompt = best.interact_prompt()
		EventBus.interact_target_changed.emit(best, prompt)
	if best and not _input_locked and Input.is_action_just_pressed("interact"):
		if best.has_method("interact"):
			best.interact(self)


func current_interactable() -> Node:
	return _interact_target


# --- presentation ---------------------------------------------------------
func _drive_rig(delta: float) -> void:
	var sp := Vector3(velocity.x, 0, velocity.z).length()
	rig.aim_weight = lerpf(rig.aim_weight, 1.0 if aiming else 0.0, 1.0 - pow(0.0005, delta))
	rig.aim_dir = aim_direction()
	rig.attack_swing = clampf(_melee_t / _melee_duration(), 0.0, 1.0) if _melee_t >= 0.0 else 0.0
	(
		rig
		. animate(
			delta,
			{
				"speed": sp,
				"on_floor": is_on_floor() or swimming,
				"air_time": _air_time,
				"dodge": clampf(_dodge_t / DODGE_TIME, 0.0, 1.0) if _dodge_t >= 0.0 else 0.0,
				"crouch": 0.32 if swimming else (0.52 if crouching else 0.0),
			}
		)
	)
	if _parry_t >= 0.0:
		rig.shoulder["R"].basis = rig.shoulder["R"].basis.slerp(Basis.from_euler(Vector3(-1.15, 0.45, -0.75)), 0.75)
		rig.elbow["R"].basis = rig.elbow["R"].basis.slerp(Basis.from_euler(Vector3(-1.35, 0.0, 0.0)), 0.75)
	# Carried across the body; brought upright as the draw begins.
	if bow_node:
		bow_node.rotation = bow_node.rotation.lerp(Vector3(0.10, 0.0, lerpf(1.20, 0.06, rig.aim_weight)), 1.0 - pow(0.0005, delta))
		var s: Node3D = bow_node.get_node_or_null("String")
		if s:
			s.position.z = 0.14 - draw_charge * 0.19
			s.scale = Vector3(1.0, 1.0, 1.0 + draw_charge * 0.4)
		var ag := bow_node.get_node_or_null("AstraGlow") as MeshInstance3D
		if ag:
			var astra := GameState.active_astra
			ag.visible = aiming and draw_charge > 0.05 and astra > 0
			if ag.visible:
				var acol: Color = [
					Color(1.0, 0.92, 0.70, 0.6),
					Color(1.0, 0.48, 0.10, 0.82),
					Color(0.18, 0.80, 1.0, 0.80),
					Color(0.55, 1.0, 0.82, 0.80),
					Color(1.0, 0.95, 0.48, 0.92),
				][clampi(astra, 0, 4)]
				ag.scale = Vector3.ONE * (0.65 + draw_charge * 0.85)
				if ag.material_override is StandardMaterial3D:
					(ag.material_override as StandardMaterial3D).albedo_color = acol
				var alight := ag.get_node_or_null("Light") as OmniLight3D
				if alight:
					alight.light_color = Color(acol.r, acol.g, acol.b)
					alight.light_energy = 1.0 + draw_charge * 2.2


func _on_footstep(_side: String, pos: Vector3, sp: float) -> void:
	if not is_on_floor() or sp < 0.4:
		return
	var surf := "grass"
	if world:
		if water_depth > 0.05:
			surf = "water"
		else:
			match world.map.biome_at(pos.x, pos.z):
				WorldMap.Biome.PATH, WorldMap.Biome.VILLAGE, WorldMap.Biome.FIELD:
					surf = "dirt"
				WorldMap.Biome.ROCK, WorldMap.Biome.MOUNTAIN:
					surf = "stone"
				WorldMap.Biome.SAND, WorldMap.Biome.RIVERBED:
					surf = "dirt"
				_:
					surf = "grass"
	_last_footstep_surface = surf
	AudioDirector.play_3d("footstep_%s_%d" % [surf, 1 + randi() % 4], pos, lerpf(-16.0, -6.0, clampf(sp / 8.0, 0.0, 1.0)))
	EventBus.footstep.emit(surf, pos, sp)


func _set_state(s: int) -> void:
	if s == state:
		return
	state = s
	_state_name = ["idle", "move", "jump", "fall", "land", "dodge", "melee", "hurt", "dead", "swim"][s]
	state_changed.emit(_state_name)
	EventBus.player_state_changed.emit(_state_name)


func _publish_state() -> void:
	GameState.player_position = global_position
	GameState.player_yaw = facing_yaw
	EventBus.player_stat_changed.emit(GameState.health, GameState.max_health, GameState.stamina, GameState.max_stamina)


func state_name() -> String:
	return _state_name


func is_crouching() -> bool:
	return crouching


func is_dead() -> bool:
	return _dead
