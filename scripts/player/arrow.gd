class_name Arrow
extends Node3D
## A ballistic arrow. Moves by swept raycast rather than by physics body so it cannot
## tunnel through a thin target at 74 m/s, and so the hit point is exact.

var velocity: Vector3 = Vector3.ZERO
var damage: float = 20.0
var charge: float = 1.0
var shooter: Node = null
var world: WorldRoot = null
var gravity: float = 13.0
var life: float = 12.0
var stuck: bool = false
var _stuck_t: float = 0.0
var _trail: Node3D


static func spawn(parent: Node, origin: Vector3, vel: Vector3, shooter_n: Node, dmg: float, chg: float) -> Arrow:
	var a := Arrow.new()
	a.velocity = vel
	a.damage = dmg
	a.charge = chg
	a.shooter = shooter_n
	parent.add_child(a)
	a.global_position = origin
	if vel.length_squared() > 0.001:
		a.look_at(origin + vel, Vector3.UP)
	a._build()
	return a


func _build() -> void:
	add_to_group("arrow")
	var vis := Weapons.arrow()
	add_child(vis)
	# A short fading streak makes the shot readable at speed.
	var tr := MeshInstance3D.new()
	tr.mesh = MeshKit.quad(0.035, 1.4)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.94, 0.78, 0.34)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	tr.material_override = m
	tr.position = Vector3(0, 0, 0.75)
	tr.rotation = Vector3(PI * 0.5, 0, 0)
	add_child(tr)
	_trail = tr
	AudioDirector.play_3d("arrow_flight", global_position, -14.0)


func _physics_process(delta: float) -> void:
	if stuck:
		_stuck_t += delta
		if _stuck_t > 14.0:
			queue_free()
		return
	life -= delta
	if life <= 0.0:
		queue_free()
		return

	velocity.y -= gravity * delta
	var from := global_position
	var to := from + velocity * delta

	# Enemies first: a direct hit should register even if terrain is just behind.
	var best_d := INF
	var best_e: Node = null
	var best_p := Vector3.ZERO
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node3D) or e == shooter:
			continue
		var hit := _segment_capsule(from, to, (e as Node3D).global_position, 0.55, 1.85)
		if hit.hit and hit.t < best_d:
			best_d = hit.t
			best_e = e
			best_p = hit.point
	if best_e:
		_impact_enemy(best_e, best_p)
		return

	# Then the world.
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1 | 8
	q.exclude = [self]
	var r := space.intersect_ray(q)
	if r:
		_impact_world(r.position, r.get("normal", Vector3.UP), r.get("collider"))
		return

	global_position = to
	if velocity.length_squared() > 0.01:
		look_at(to + velocity, Vector3.UP)
	if _trail:
		_trail.scale.y = clampf(velocity.length() / 60.0, 0.3, 1.4)


func _impact_enemy(e: Node, p: Vector3) -> void:
	var head: bool = p.y > (e as Node3D).global_position.y + 1.42
	var dmg := damage * (1.85 if head else 1.0)
	if e.has_method("take_damage"):
		e.take_damage(dmg, shooter, p, head)
	AudioDirector.play_3d("arrow_hit_flesh", p, 0.0)
	EventBus.hit_feedback.emit(p, 0.6 + charge * 0.4, "arrow_hit")
	queue_free()


func _impact_world(p: Vector3, n: Vector3, collider: Object) -> void:
	stuck = true
	velocity = Vector3.ZERO
	global_position = p - (global_transform.basis.z * -0.10)
	if _trail:
		_trail.queue_free()
		_trail = null
	var stone := false
	if world:
		var b := world.map.biome_at(p.x, p.z)
		stone = b == WorldMap.Biome.ROCK or b == WorldMap.Biome.MOUNTAIN
	if collider and collider is Node and (collider as Node).is_in_group("wood"):
		AudioDirector.play_3d("arrow_hit_wood", p, -3.0)
	else:
		AudioDirector.play_3d("arrow_hit_stone" if stone else "arrow_hit_wood", p, -5.0)
	# Nudge upright a touch so it reads as embedded rather than lying on the surface.
	rotation.x += (n.dot(Vector3.UP) - 0.5) * 0.1


## Swept sphere-vs-capsule test, returning the first hit along the segment.
static func _segment_capsule(a: Vector3, b: Vector3, base: Vector3, radius: float, height: float) -> Dictionary:
	var steps := 5
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var p: Vector3 = a.lerp(b, t)
		var y: float = clampf(p.y, base.y + radius, base.y + height - radius)
		var c := Vector3(base.x, y, base.z)
		if p.distance_to(c) <= radius:
			return {"hit": true, "t": t, "point": p}
	return {"hit": false, "t": INF, "point": Vector3.ZERO}
