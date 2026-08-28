class_name EnemyArrow
extends Arrow
## A rakshasa archer's arrow.
##
## It IS an `Arrow` — same swept-raycast ballistics, same generated shaft and
## fletching, same terrain embedding and impact sounds — but it looks for the PLAYER
## instead of for the group "enemy". Arrow's own sweep tests `get_nodes_in_group
## ("enemy")` and raycasts layers 1|8, and the player is on layer 2, so an unmodified
## Arrow fired by a rakshasa would sail straight through Rama and then shoot the
## rakshasa standing behind him. Subclassing is how that is fixed without touching
## the shared projectile.
##
## The flight is deliberately slower than Rama's (30 m/s against 34-74), which is what
## makes an incoming arrow something you can see and side-step rather than a hitscan.

var _player: Node3D = null
var _spawn_grace: float = 0.04  # do not clip the archer's own bow arm


static func shoot(
	parent: Node, origin: Vector3, vel: Vector3, archer: Node, dmg: float, w: WorldRoot = null
) -> EnemyArrow:
	var a := EnemyArrow.new()
	a.velocity = vel
	a.damage = dmg
	a.charge = 0.85
	a.shooter = archer
	a.gravity = 11.0
	a.life = 8.0
	a.world = w
	parent.add_child(a)
	a.global_position = origin
	if vel.length_squared() > 0.001:
		a.look_at(origin + vel, Vector3.UP)
	a._build()
	return a


func _physics_process(delta: float) -> void:
	if stuck:
		super._physics_process(delta)
		return
	life -= delta
	if life <= 0.0:
		queue_free()
		return
	_spawn_grace = maxf(0.0, _spawn_grace - delta)

	velocity.y -= gravity * delta
	var from := global_position
	var to := from + velocity * delta

	if _spawn_grace <= 0.0:
		var pl := _find_player()
		if pl != null and not (pl.has_method("is_dead") and pl.is_dead()):
			# Same swept capsule test the player's arrows use on rakshasas, so a fast
			# arrow cannot tunnel through a target between two physics frames.
			var hit: Dictionary = Arrow._segment_capsule(from, to, pl.global_position, 0.48, 1.78)
			if hit.hit:
				_hit_player(pl, hit.point)
				return

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


func _hit_player(pl: Node3D, p: Vector3) -> void:
	# The archer can die, or be streamed out, while its arrow is still in the air.
	# Passing a freed object as the damage source is a typed-argument error at the
	# other end, so the shot lands with no attributable source instead.
	var src: Node = shooter if is_instance_valid(shooter) else null
	if pl.has_method("take_damage"):
		pl.take_damage(damage, src, p, false)
	AudioDirector.play_3d("arrow_hit_flesh", p, -1.0)
	EventBus.hit_feedback.emit(p, 0.7, "hurt")
	queue_free()


func _find_player() -> Node3D:
	if _player != null and is_instance_valid(_player):
		return _player
	var ps := get_tree().get_nodes_in_group("player")
	if ps.is_empty():
		return null
	_player = ps[0] as Node3D
	return _player
