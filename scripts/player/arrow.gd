class_name Arrow
extends Node3D
## A ballistic arrow. Moves by swept raycast rather than by physics body so it cannot
## tunnel through a thin target at 74 m/s, and so the hit point is exact.

var velocity: Vector3 = Vector3.ZERO
var damage: float = 20.0
var charge: float = 1.0
var astra_kind: int = 0
var pierced_ids: Dictionary = {}
var shooter: Node = null
var world: WorldRoot = null
var gravity: float = 13.0
var life: float = 12.0
var stuck: bool = false
var _stuck_t: float = 0.0
var _trail: Node3D
var _chakra_a: Node3D = null
var _chakra_b: Node3D = null


static func spawn(
	parent: Node, origin: Vector3, vel: Vector3, shooter_n: Node, dmg: float, chg: float, astra: int = 0
) -> Arrow:
	var a := Arrow.new()
	a.velocity = vel
	a.damage = dmg
	a.charge = chg
	a.shooter = shooter_n
	a.astra_kind = astra
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
	# Style trail and arrowhead glow based on astra_kind.
	var trail_col := Color(1.0, 0.94, 0.78, 0.38)
	var trail_w := 0.035
	var trail_len := 1.4
	if astra_kind == 1:
		trail_col = Color(1.0, 0.45, 0.08, 0.72)
		trail_w = 0.085
		trail_len = 2.1
		_add_astra_head_vfx(Color(1.0, 0.52, 0.12, 0.85), 0.11, 2.2, 5.5, false)
	elif astra_kind == 2:
		trail_col = Color(0.18, 0.78, 1.0, 0.68)
		trail_w = 0.080
		trail_len = 2.0
		_add_astra_head_vfx(Color(0.22, 0.82, 1.0, 0.82), 0.10, 1.8, 5.0, true)
	elif astra_kind == 3:
		trail_col = Color(0.55, 1.0, 0.82, 0.70)
		trail_w = 0.095
		trail_len = 2.6
		gravity = 2.5
		_add_astra_head_vfx(Color(0.62, 1.0, 0.86, 0.80), 0.09, 1.6, 4.5, true)
	elif astra_kind == 4:
		trail_col = Color(1.0, 0.92, 0.42, 0.88)
		trail_w = 0.14
		trail_len = 3.2
		gravity = 1.5
		_add_astra_head_vfx(Color(1.0, 0.95, 0.55, 0.92), 0.16, 3.6, 8.0, true)

	var tr := MeshInstance3D.new()
	tr.mesh = MeshKit.quad(trail_w, trail_len)
	var m := StandardMaterial3D.new()
	m.albedo_color = trail_col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	tr.material_override = m
	tr.position = Vector3(0, 0, 0.75)
	tr.rotation = Vector3(PI * 0.5, 0, 0)
	add_child(tr)
	_trail = tr
	AudioDirector.play_3d("arrow_flight", global_position, -14.0 if astra_kind == 0 else -8.0)


func _add_astra_head_vfx(col: Color, radius: float, energy: float, light_range: float, rings: bool) -> void:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var corona := MeshInstance3D.new()
	corona.mesh = MeshKit.sphere(radius, 12, 8)
	corona.material_override = m
	corona.position = Vector3(0, 0, -0.40)
	add_child(corona)
	if rings:
		var r1 := MeshInstance3D.new()
		r1.mesh = MeshKit.tube(0.025, [[0.0, radius * 1.65], [1.0, radius * 1.65]], 14)
		r1.material_override = m
		r1.position = Vector3(0, 0, -0.38)
		r1.rotation = Vector3(PI * 0.5, 0, 0)
		add_child(r1)
		_chakra_a = r1
		if astra_kind == 4:
			var r2 := MeshInstance3D.new()
			r2.mesh = MeshKit.tube(0.025, [[0.0, radius * 2.25], [1.0, radius * 2.25]], 16)
			r2.material_override = m
			r2.position = Vector3(0, 0, -0.38)
			r2.rotation = Vector3(0.6, 0.4, 0.0)
			add_child(r2)
			_chakra_b = r2
	var light := OmniLight3D.new()
	light.light_color = Color(col.r, col.g, col.b)
	light.light_energy = energy
	light.omni_range = light_range
	light.position = Vector3(0, 0, -0.40)
	add_child(light)


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

	if _chakra_a != null:
		_chakra_a.rotate_z(delta * 10.0)
	if _chakra_b != null:
		_chakra_b.rotate_x(delta * 8.0)

	velocity.y -= gravity * delta
	var from := global_position
	var to := from + velocity * delta

	# Check sacred or environmental arrow targets (e.g. Sapta Tala trees, shrine targets).
	for tgt in get_tree().get_nodes_in_group("arrow_target"):
		if not is_instance_valid(tgt) or not (tgt is Node3D):
			continue
		var tid: int = tgt.get_instance_id()
		if pierced_ids.has(tid):
			continue
		var thit := _segment_capsule(from, to, (tgt as Node3D).global_position, 0.9, 4.5)
		if thit.hit:
			pierced_ids[tid] = true
			if tgt.has_method("on_arrow_hit"):
				tgt.on_arrow_hit(astra_kind, self)
			if astra_kind < 3:
				if astra_kind >= 1:
					_spawn_astra_explosion(thit.point)
				queue_free()
				return

	# Enemies first: a direct hit should register even if terrain is just behind.
	var best_d := INF
	var best_e: Node = null
	var best_p := Vector3.ZERO
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node3D) or e == shooter:
			continue
		if pierced_ids.has(e.get_instance_id()):
			continue
		var hit := _segment_capsule(from, to, (e as Node3D).global_position, 0.55, 1.85)
		if hit.hit and hit.t < best_d:
			best_d = hit.t
			best_e = e
			best_p = hit.point
	if best_e:
		_impact_enemy(best_e, best_p)
		if is_queued_for_deletion():
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
	var mult := 1.85 if head else 1.0
	if astra_kind == 4:
		mult *= 1.5
	var dmg := damage * mult
	if e.has_method("take_damage"):
		e.take_damage(dmg, shooter, p, head or astra_kind == 4)
	AudioDirector.play_3d("arrow_hit_flesh", p, 0.0)
	EventBus.hit_feedback.emit(p, 0.6 + charge * 0.4, "arrow_hit")
	if astra_kind >= 1:
		_spawn_astra_explosion(p)
	if astra_kind == 3 or astra_kind == 4:
		pierced_ids[e.get_instance_id()] = true
		if e is CharacterBody3D and velocity.length_squared() > 0.01:
			(e as CharacterBody3D).velocity += velocity.normalized() * 7.5 + Vector3.UP * 2.0
		if pierced_ids.size() < 7:
			return
	queue_free()


func _impact_world(p: Vector3, n: Vector3, collider: Object) -> void:
	if astra_kind >= 1:
		_spawn_astra_explosion(p)
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


func _spawn_astra_explosion(pos: Vector3) -> void:
	if get_parent() == null:
		return
	var col := Color(1.0, 0.55, 0.12, 0.78)
	var radius := 4.8
	if astra_kind == 2:
		col = Color(0.18, 0.80, 1.0, 0.75)
		radius = 4.8
	elif astra_kind == 3:
		col = Color(0.55, 1.0, 0.82, 0.72)
		radius = 4.2
	elif astra_kind == 4:
		col = Color(1.0, 0.94, 0.45, 0.88)
		radius = 7.5

	# Short-lived expanding burst visual.
	var burst := MeshInstance3D.new()
	burst.mesh = MeshKit.sphere(0.65, 14, 10)
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	burst.material_override = m
	get_parent().add_child(burst)
	burst.global_position = pos
	var tw := burst.create_tween()
	var end_scale := radius * 1.15
	tw.set_parallel(true)
	tw.tween_property(burst, "scale", Vector3.ONE * end_scale, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.45)
	tw.chain().tween_callback(burst.queue_free)

	# Divya Astra elemental area effects.
	for e in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node3D) or e == shooter:
			continue
		var ep: Vector3 = (e as Node3D).global_position
		var dist: float = ep.distance_to(pos)
		if dist > radius:
			continue
		if astra_kind == 1:
			if e.has_method("take_damage"):
				e.take_damage(damage * 0.75, shooter, ep + Vector3(0, 1.0, 0), false)
			if e.has_method("apply_status"):
				e.apply_status("burn", 4.0)
		elif astra_kind == 2:
			if e.has_method("take_damage"):
				e.take_damage(damage * 0.55, shooter, ep + Vector3(0, 1.0, 0), false)
			if e.has_method("apply_status"):
				e.apply_status("slow", 5.0)
		elif astra_kind == 3:
			var push_dir := (ep - pos).normalized()
			push_dir.y = 0.35
			if e is CharacterBody3D:
				(e as CharacterBody3D).velocity += push_dir.normalized() * 12.0
			if e.has_method("apply_status"):
				e.apply_status("stagger", 2.0)
		elif astra_kind == 4:
			if e.has_method("take_damage"):
				e.take_damage(damage * 1.35, shooter, ep + Vector3(0, 1.0, 0), true)
			if e.has_method("apply_status"):
				e.apply_status("stun", 3.5)

	if astra_kind == 1:
		# Ignite any nearby lamp or campfire.
		for n in get_tree().get_nodes_in_group("interactable"):
			if is_instance_valid(n) and n is Node3D and (n as Node3D).global_position.distance_to(pos) <= radius + 1.5:
				if n.has_method("ignite_from_astra"):
					n.ignite_from_astra()
	elif astra_kind == 2:
		# Varunastra's healing mist restores grace to the shooter.
		if is_instance_valid(shooter) and shooter.has_method("heal"):
			shooter.heal(12.0)
			GameState.stamina = minf(GameState.max_stamina, GameState.stamina + 20.0)


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
