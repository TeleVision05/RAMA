class_name Perception
extends RefCounted
## What an enemy knows, and how sure it is.
##
## Detection is a METER, not a boolean. Sight and sound both push it up; nothing
## pushing it makes it fall. That single number is what turns a guard from a trigger
## volume into something that notices, hesitates, comes to look, and only then
## commits — which is the whole difference between an alarm and an opponent.
##
##   0.00 .. 0.32   unaware       carries on patrolling
##   0.32 .. 0.72   suspicious    breaks off and looks toward the disturbance
##   0.72 .. 1.00   alert         walks to the last known position to investigate
##   1.00           committed     CHASE, and EventBus.enemy_alerted fires
##
## Concealment (forest canopy, tall meadow grass, crouching, moving slowly) multiplies
## the sight term down, so the same approach that gets you spotted in the open gets
## you within a few metres under the canopy.

const SUSPECT := 0.32
const ALERT := 0.72
const COMMIT := 1.0

# How fast a perfect, unobstructed, dead-centre view fills the meter (per second).
const SEE_GAIN := 1.45
# Decay when nothing is feeding it. Slower than the gain, so a lost target keeps an
# enemy nervous for a while rather than snapping back to oblivious.
const DECAY := 0.24
# Once committed, how long the target can stay out of sight before the enemy gives
# up the chase and falls back to investigating the last place it saw them.
const LOSE_TIME := 4.0

var vision: float = 30.0
var fov: float = deg_to_rad(124.0)
var hearing: float = 30.0

var awareness: float = 0.0
var can_see: bool = false
var last_known: Vector3 = Vector3.ZERO
var has_last_known: bool = false
var lost_time: float = 0.0
var committed: bool = false
var target_dist: float = INF

var _noise: float = 0.0  # decaying hearing impulse
var _los_t: float = 0.0  # raycast throttle
var _los_clear: bool = false
var _conceal: float = 0.0  # cached with the raycast; both are 8 Hz work


func configure(d: Dictionary) -> void:
	vision = float(d.get("vision", vision))
	fov = deg_to_rad(float(d.get("fov_deg", 124.0)))
	hearing = float(d.get("hearing", hearing))


## One perception tick. `light` is 0..1 from SkySystem; night halves effective range.
func update(
	delta: float, eye: Vector3, fwd: Vector3, target: Node3D, space: PhysicsDirectSpaceState3D, map: WorldMap, light: float
) -> void:
	var see := 0.0
	can_see = false
	target_dist = INF

	if target != null and is_instance_valid(target):
		var tp: Vector3 = target.global_position + Vector3(0, 1.25, 0)
		var to := tp - eye
		var dist := to.length()
		target_dist = dist
		var reach: float = vision * lerpf(0.55, 1.0, clampf(light, 0.0, 1.0))
		if dist < reach and dist > 0.01:
			var dir := to / dist
			var flat_fwd := Vector3(fwd.x, 0, fwd.z).normalized()
			var flat_dir := Vector3(dir.x, 0, dir.z)
			var ang: float = PI
			if flat_dir.length_squared() > 0.0001 and flat_fwd.length_squared() > 0.0001:
				ang = flat_fwd.angle_to(flat_dir.normalized())
			if ang < fov * 0.5:
				_los_t -= delta
				if _los_t <= 0.0:
					_los_t = 0.12
					_los_clear = _line_of_sight(space, eye, tp)
					_conceal = concealment(map, target)
				if _los_clear:
					can_see = true
					# Near, centred and exposed fills fast; far, peripheral and
					# hidden barely moves the needle.
					var closeness: float = 1.0 - pow(dist / reach, 1.35)
					var centred: float = 1.0 - ang / (fov * 0.5)
					var conceal: float = _conceal
					see = clampf(0.18 + closeness * 0.82, 0.0, 1.0) * lerpf(0.30, 1.0, centred) * (1.0 - conceal)

	var drive: float = see * SEE_GAIN + _noise
	if drive > 0.0:
		awareness = minf(COMMIT, awareness + drive * delta)
		if can_see and target != null:
			last_known = target.global_position
			has_last_known = true
	else:
		awareness = maxf(0.0, awareness - DECAY * delta)

	_noise = maxf(0.0, _noise - delta * 1.6)

	if awareness >= COMMIT:
		committed = true
	if committed:
		if can_see:
			lost_time = 0.0
		else:
			lost_time += delta
			if lost_time > LOSE_TIME:
				committed = false
				awareness = minf(awareness, ALERT * 0.98)


## A disturbance at `pos` with 0..1 loudness. Footsteps and bowshots come through
## here; the enemy does not need to see anything to start walking over.
func hear(self_pos: Vector3, pos: Vector3, loudness: float) -> bool:
	var reach: float = hearing * clampf(loudness, 0.05, 1.0)
	var d := self_pos.distance_to(pos)
	if d > reach:
		return false
	var strength: float = loudness * (1.0 - d / maxf(reach, 0.01))
	if strength <= 0.001:
		return false
	_noise = maxf(_noise, strength * 1.5)
	# Sound localises loosely: you know roughly where, not exactly.
	if not committed:
		var jitter: float = lerpf(4.0, 0.6, strength)
		last_known = pos + Vector3(randf_range(-jitter, jitter), 0.0, randf_range(-jitter, jitter))
		has_last_known = true
	return true


## Being hit, or seeing an ally die, skips straight past the meter.
func alarm(pos: Vector3, full: bool = true) -> void:
	last_known = pos
	has_last_known = true
	awareness = COMMIT if full else maxf(awareness, ALERT)
	if full:
		committed = true
		lost_time = 0.0


func forget() -> void:
	has_last_known = false
	committed = false
	awareness = 0.0
	lost_time = 0.0


func level() -> int:
	if awareness >= COMMIT or committed:
		return 3
	if awareness >= ALERT:
		return 2
	if awareness >= SUSPECT:
		return 1
	return 0


# --- helpers ---------------------------------------------------------------
## Terrain and solid props block sight. Layer 1 is the heightfield, layer 8 is
## world geometry; the player (layer 2) and other enemies (layer 4) are deliberately
## NOT in the mask, or a rakshasa's own squad would blind it.
static func _line_of_sight(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> bool:
	if space == null:
		return true
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1 | 8
	var r := space.intersect_ray(q)
	return r.is_empty()


## 0 = standing in the open, 0.85 = as hidden as this world allows.
## Canopy and tall grass do most of the work; moving slowly and crouching do the rest.
static func concealment(map: WorldMap, target: Node3D) -> float:
	if map == null or target == null:
		return 0.0
	var p := target.global_position
	var c: float = map.forest_density(Vector2(p.x, p.z)) * 0.44
	match map.biome_at(p.x, p.z):
		WorldMap.Biome.FOREST:
			c += 0.20
		WorldMap.Biome.MEADOW:
			c += 0.10
		WorldMap.Biome.ROCK, WorldMap.Biome.MOUNTAIN:
			c += 0.04
	# Speed: sprinting through the open is as good as shouting.
	var speed := 0.0
	var v: Variant = target.get("velocity")
	if v != null and typeof(v) == TYPE_VECTOR3:
		speed = Vector3(v.x, 0.0, v.z).length()
	if speed < 0.6:
		c += 0.16
	elif speed < 2.6:
		c += 0.09
	elif speed > 6.5:
		c -= 0.12
	# Crouching, when the controller offers it.
	var cr: Variant = target.get("crouching")
	if typeof(cr) == TYPE_BOOL and cr:
		c += 0.26
	return clampf(c, 0.0, 0.85)


## Loudness 0..1 for a footstep on a given surface at a given speed.
static func footstep_loudness(surface: String, speed: float) -> float:
	var l: float = clampf(speed / 8.0, 0.0, 1.0)
	l = l * l * 0.92 + 0.06
	match surface:
		"stone":
			l *= 1.25
		"water":
			l *= 1.35
		"dirt":
			l *= 1.0
		_:
			l *= 0.78
	return clampf(l, 0.0, 1.0)
