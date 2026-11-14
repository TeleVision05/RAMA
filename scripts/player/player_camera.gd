class_name PlayerCamera
extends Node3D
## Third-person camera. A spring arm that swings out of walls, a separate over-the-
## shoulder framing while aiming, speed-reactive field of view, and noise-based shake
## so hits land physically.

const PITCH_MIN := deg_to_rad(-62.0)
const PITCH_MAX := deg_to_rad(48.0)

@export var mouse_sensitivity: float = 0.0026
@export var joy_sensitivity: float = 2.6
@export var invert_y: bool = false

var yaw: float = 0.0
var pitch: float = deg_to_rad(-9.0)
var target: Node3D
var world: WorldRoot

var arm: SpringArm3D
var cam: Camera3D
var _pivot: Node3D

# framing
const FREE := {"dist": 4.35, "height": 1.62, "side": 0.42, "fov": 64.0}
const AIMED := {"dist": 1.75, "height": 1.58, "side": 0.62, "fov": 46.0}
var _blend: float = 0.0
var _shake: float = 0.0
var _shake_t: float = 0.0
var _noise: FastNoiseLite
var _fov_extra: float = 0.0
var _follow: Vector3 = Vector3.ZERO
var _enabled: bool = true


func _ready() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = 991
	_noise.frequency = 1.6

	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	add_child(_pivot)

	arm = SpringArm3D.new()
	arm.spring_length = FREE.dist
	arm.margin = 0.32
	# Collide with world geometry only, never with the player or with enemies.
	arm.collision_mask = 1 | 8
	_pivot.add_child(arm)

	cam = Camera3D.new()
	cam.fov = FREE.fov
	cam.near = 0.08
	cam.far = 2200.0
	arm.add_child(cam)
	cam.current = true

	EventBus.hit_feedback.connect(_on_hit_feedback)
	QuietMode.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func setup(t: Node3D, w: WorldRoot) -> void:
	target = t
	world = w
	if t:
		yaw = t.rotation.y
		_follow = t.global_position


func set_enabled(on: bool) -> void:
	_enabled = on


func _unhandled_input(e: InputEvent) -> void:
	if not _enabled:
		return
	if e is InputEventMouseMotion and QuietMode.is_mouse_look():
		var mm := e as InputEventMouseMotion
		yaw -= mm.relative.x * mouse_sensitivity
		pitch += mm.relative.y * mouse_sensitivity * (1.0 if invert_y else -1.0)
		pitch = clampf(pitch, PITCH_MIN, PITCH_MAX)


func _process(delta: float) -> void:
	if target == null:
		return
	if _enabled:
		var look := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
		if look.length() > 0.18:
			yaw -= look.x * joy_sensitivity * delta
			pitch += look.y * joy_sensitivity * delta * (1.0 if invert_y else -1.0)
			pitch = clampf(pitch, PITCH_MIN, PITCH_MAX)

	var p := target as Player
	var aiming: bool = p != null and p.aiming
	_blend = lerpf(_blend, 1.0 if aiming else 0.0, 1.0 - pow(0.0006, delta))

	var dist: float = lerpf(FREE.dist, AIMED.dist, _blend)
	var height: float = lerpf(FREE.height, AIMED.height, _blend)
	var side: float = lerpf(FREE.side, AIMED.side, _blend)
	var base_fov: float = lerpf(FREE.fov, AIMED.fov, _blend)

	# Widen slightly at speed: it reads as effort without being a gimmick.
	var speed: float = Vector3(target.velocity.x, 0, target.velocity.z).length() if target is CharacterBody3D else 0.0
	_fov_extra = lerpf(_fov_extra, clampf((speed - 5.0) * 1.35, 0.0, 7.0), 1.0 - pow(0.02, delta))

	# The camera follows a smoothed point, but vertically it tracks faster so the
	# player never slides out of frame going down a slope.
	var want := target.global_position
	_follow.x = lerpf(_follow.x, want.x, 1.0 - pow(0.00003, delta))
	_follow.z = lerpf(_follow.z, want.z, 1.0 - pow(0.00003, delta))
	_follow.y = lerpf(_follow.y, want.y, 1.0 - pow(0.0000004, delta))
	global_position = _follow + Vector3(0, height, 0)

	_pivot.rotation = Vector3(pitch, yaw, 0.0)
	arm.spring_length = dist
	cam.position = Vector3(side, 0.0, 0.0)

	# --- shake ------------------------------------------------------------
	if _shake > 0.001:
		_shake_t += delta
		_shake = maxf(0.0, _shake - delta * 2.6)
		var s: float = _shake * _shake
		var nx := _noise.get_noise_2d(_shake_t * 34.0, 0.0)
		var ny := _noise.get_noise_2d(0.0, _shake_t * 34.0)
		var nz := _noise.get_noise_2d(_shake_t * 21.0, 71.0)
		cam.rotation = Vector3(ny * s * 0.10, nx * s * 0.10, nz * s * 0.16)
		cam.position += Vector3(nx, ny, 0.0) * s * 0.14
	else:
		cam.rotation = cam.rotation.lerp(Vector3.ZERO, 1.0 - pow(0.001, delta))

	cam.fov = lerpf(cam.fov, base_fov + _fov_extra, 1.0 - pow(0.004, delta))

	# Never let the camera end up under the ground.
	if world:
		var g: float = world.map.height_at(cam.global_position.x, cam.global_position.z) + 0.42
		if cam.global_position.y < g:
			var gp := cam.global_position
			gp.y = g
			cam.global_position = gp


func _on_hit_feedback(_pos: Vector3, strength: float, kind: String) -> void:
	var mult := 1.0
	match kind:
		"hurt":
			mult = 1.5
		"arrow_hit":
			mult = 0.55
		"melee":
			mult = 0.8
		"shoot":
			mult = 0.4
		"whiff":
			mult = 0.25
		"land":
			mult = 0.9
	add_shake(strength * mult)


func add_shake(amount: float) -> void:
	_shake = clampf(maxf(_shake, amount), 0.0, 1.6)


## Where the crosshair is pointing in the world, and the direction to it.
func aim_ray(max_dist: float = 320.0) -> Dictionary:
	var from := cam.global_position
	var dir := -cam.global_transform.basis.z
	var space := cam.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * max_dist)
	q.collision_mask = 1 | 4 | 8
	if target:
		q.exclude = [target.get_rid()]
	var r := space.intersect_ray(q)
	if r:
		return {"point": r.position, "dir": dir, "hit": true, "collider": r.get("collider")}
	return {"point": from + dir * max_dist, "dir": dir, "hit": false, "collider": null}


func camera() -> Camera3D:
	return cam
