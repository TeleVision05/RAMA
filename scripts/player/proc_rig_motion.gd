class_name ProcRigMotion
extends ProcRigDetail
## Part 5 of 6 of ProcRig (see proc_rig.gd): locomotion, IK legs, arms, head and the
## additive poses.
## The six parts form one inheritance chain, so every caller still writes `ProcRig.name`.

## Drive the whole pose. `st` keys:
##   speed (planar m/s), vel (local-space velocity), on_floor, air_time,
##   crouch, dodge (0..1), state (String)
func animate(delta: float, st: Dictionary) -> void:
	_t += delta
	var speed: float = st.get("speed", 0.0)
	var on_floor: bool = st.get("on_floor", true)
	var dodge: float = st.get("dodge", 0.0)
	var air_t: float = st.get("air_time", 0.0)

	# --- gait phase -------------------------------------------------------
	var moving: float = clampf(speed / 1.2, 0.0, 1.0)
	if on_floor and speed > 0.12:
		stride_phase = fposmod(stride_phase + (speed / STRIDE_LEN) * delta, 1.0)
	else:
		# Settle to a clean stance rather than freezing mid-step.
		stride_phase = lerpf(stride_phase, roundf(stride_phase * 2.0) * 0.5, 1.0 - pow(0.001, delta))
	_breath += delta * lerpf(0.9, 2.6, moving)

	var stride: float = clampf(speed * 0.46, 0.0, 1.05)
	var bob: float = sin(stride_phase * TAU * 2.0) * 0.030 * moving
	var sway: float = sin(stride_phase * TAU) * 0.020 * moving
	var breathe: float = sin(_breath) * 0.008 * (1.0 - moving * 0.7)

	# --- body ------------------------------------------------------------
	var target_lean := Vector2(-clampf(speed * 0.055, 0.0, 0.22), 0.0)
	if dodge > 0.01:
		target_lean.x -= 0.45 * sin(dodge * PI)
	_lean = _lean.lerp(target_lean, 1.0 - pow(0.0008, delta))

	var air_tuck: float = clampf(air_t * 1.6, 0.0, 1.0) if not on_floor else 0.0
	_hip_y_off = lerpf(_hip_y_off, bob + breathe - air_tuck * 0.06 - st.get("crouch", 0.0) * 0.26, 1.0 - pow(0.0001, delta))
	hips.position = Vector3(sway * 0.5, cfg.hip_h + _hip_y_off, 0.0)
	hips.rotation = Vector3(_lean.x * 0.35, sin(stride_phase * TAU) * 0.10 * moving, sway * 0.6)

	spine.rotation = Vector3(_lean.x * 0.55, -sin(stride_phase * TAU) * 0.09 * moving, -sway * 0.5)
	chest.rotation = Vector3(_lean.x * 0.30 + breathe * 2.0, -sin(stride_phase * TAU) * 0.11 * moving, 0.0)

	# --- legs -------------------------------------------------------------
	if dead_amount < 0.5:
		_animate_legs(delta, speed, stride, moving, on_floor, air_tuck, dodge)

	# --- arms -------------------------------------------------------------
	_animate_arms(delta, stride_phase, moving, on_floor, air_tuck, dodge)

	# --- head -------------------------------------------------------------
	_animate_head(delta)
	# The eyes and lids are HIDDEN at LOD 1, so posing them there is pure waste — and
	# with three dozen rigs in the village it is waste thirty-seven times a frame.
	if _lod <= 0:
		_animate_face(delta)
	_animate_cloth(delta, moving)
	_lod_tick += 1
	if _lod_tick % 8 == 1:
		_update_lod()
	if _lod_tick % 17 == 3:
		_update_grip()

	# --- additive layers ---------------------------------------------------
	if hurt_amount > 0.001:
		var h: float = hurt_amount
		chest.rotation.x -= h * 0.42
		spine.rotation.x -= h * 0.22
		head.rotation.x -= h * 0.30
		hurt_amount = maxf(0.0, hurt_amount - delta * 3.2)
	if dead_amount > 0.001:
		_pose_dead(dead_amount)

	if humanoid_model != null:
		_animate_humanoid_model(delta, st)


func _hide_procedural_meshes() -> void:
	if skirt_node:
		skirt_node.visible = false
	if sash_node:
		sash_node.visible = false
	var joints: Array[Node3D] = [hips, spine, chest, neck, head]
	for side in ["L", "R"]:
		if shoulder.has(side):
			joints.append(shoulder[side])
		if elbow.has(side):
			joints.append(elbow[side])
		if hand.has(side):
			joints.append(hand[side])
		if thigh.has(side):
			joints.append(thigh[side])
		if knee.has(side):
			joints.append(knee[side])
		if ankle.has(side):
			joints.append(ankle[side])
	for j in joints:
		if j != null:
			for c in j.get_children():
				if c is MeshInstance3D:
					(c as MeshInstance3D).visible = false


func _animate_humanoid_model(_delta: float, st: Dictionary) -> void:
	if humanoid_model == null:
		return
	var speed: float = st.get("speed", 0.0)
	var on_floor: bool = st.get("on_floor", true)
	if dead_amount > 0.1:
		humanoid_model.play("death")
	elif hurt_amount > 0.1:
		humanoid_model.play("hit")
	elif attack_swing > 0.05:
		humanoid_model.play("melee_slash", 0.1, 1.4)
	elif aim_weight > 0.05:
		humanoid_model.play("bow_aim", 0.15)
	elif not on_floor:
		humanoid_model.play("jump_idle", 0.15)
	elif speed > 2.8:
		humanoid_model.play("run", 0.2, clampf(speed / 3.0, 0.8, 1.6))
	elif speed > 0.12:
		humanoid_model.play("walk", 0.2, clampf(speed / 1.4, 0.7, 1.4))
	else:
		humanoid_model.play("idle", 0.25)


func _animate_legs(_delta: float, speed: float, stride: float, moving: float, on_floor: bool, air_tuck: float, dodge: float) -> void:
	var hips_inv := hips.transform.affine_inverse()
	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		var ph: float = fposmod(stride_phase + (0.0 if side == "L" else 0.5), 1.0)

		# Foot target in RIG-LOCAL space. Forward is -Z.
		var fx: float = sx * cfg.hip_w * 1.02
		var fz: float
		var fy: float = 0.0
		if ph < STANCE_FRAC:
			# Planted: slide backwards under the body at the travel speed.
			var t: float = ph / STANCE_FRAC
			fz = lerpf(-stride * 0.5, stride * 0.5, t)
		else:
			# Swing: arc forward and lift.
			var t: float = (ph - STANCE_FRAC) / (1.0 - STANCE_FRAC)
			var e: float = t * t * (3.0 - 2.0 * t)
			fz = lerpf(stride * 0.5, -stride * 0.5, e)
			fy = sin(t * PI) * (0.055 + stride * 0.14)
			if t > 0.5 and _foot_planted[side]:
				_foot_planted[side] = false
			# Report the plant one step later, when it lands.
		if ph < STANCE_FRAC and not _foot_planted[side]:
			_foot_planted[side] = true
			footstep.emit(side, to_global(Vector3(fx, 0, fz)), speed)

		if not on_floor:
			# Tuck in the air, trailing leg lower.
			fz = lerpf(fz, -0.10 + sx * 0.02, air_tuck)
			fy = lerpf(fy, 0.16 + air_tuck * 0.10, air_tuck)
		if dodge > 0.01:
			var d: float = sin(dodge * PI)
			fy = lerpf(fy, 0.30, d)
			fz = lerpf(fz, -0.05, d * 0.6)

		# Conform to the ground under the foot.
		if ground_fn.is_valid() and on_floor and is_inside_tree():
			var wp := to_global(Vector3(fx, 0.0, fz))
			var gy: float = ground_fn.call(wp.x, wp.z)
			fy += clampf(gy - global_position.y, -0.55, 0.55)

		var foot_local := Vector3(fx, fy + 0.055, fz)
		var target_h := hips_inv * foot_local
		var root_h: Vector3 = thigh[side].position
		# Knee points forward (-Z in rig space) and slightly outward.
		var pole := (hips_inv.basis * Vector3(sx * 0.35, 0.0, -1.0)).normalized()
		var knee_p := solve_two_bone(root_h, target_h, cfg.thigh, cfg.shin, pole)

		var fwd_ref: Vector3 = hips_inv.basis * Vector3.FORWARD
		var th_basis := basis_down(knee_p - root_h, fwd_ref)
		thigh[side].basis = th_basis
		var kn_world_basis := basis_down(target_h - knee_p, fwd_ref)
		knee[side].basis = th_basis.inverse() * kn_world_basis
		# Keep the sole roughly level with the ground.
		var ank_basis := basis_down(Vector3.DOWN, fwd_ref)
		ankle[side].basis = kn_world_basis.inverse() * ank_basis
		ankle[side].rotate_object_local(
			Vector3.RIGHT, -0.12 + sin(fposmod(stride_phase + (0.0 if side == "L" else 0.5), 1.0) * TAU) * 0.16 * moving
		)


func _animate_arms(delta: float, phase: float, moving: float, on_floor: bool, air_tuck: float, dodge: float) -> void:
	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		# Arms swing opposite the leg on the same side.
		var ph: float = fposmod(phase + (0.5 if side == "L" else 0.0), 1.0)
		var swing: float = sin(ph * TAU) * (0.28 + moving * 0.52) * moving
		var idle_drift: float = sin(_t * 0.7 + _idle_seed + sx) * 0.035 * (1.0 - moving)

		var sh_rot := Vector3(swing, 0.0, sx * (0.14 + moving * 0.07) + idle_drift)
		var el_rot := Vector3(-0.22 - moving * 0.55 - maxf(0.0, -swing) * 0.6, 0.0, 0.0)
		if not on_floor:
			sh_rot = sh_rot.lerp(Vector3(-0.55, 0.0, sx * 0.55), air_tuck)
			el_rot = el_rot.lerp(Vector3(-1.0, 0.0, 0.0), air_tuck)
		if dodge > 0.01:
			var d: float = sin(dodge * PI)
			sh_rot = sh_rot.lerp(Vector3(-1.5, 0.0, sx * 0.35), d)
			el_rot = el_rot.lerp(Vector3(-2.0, 0.0, 0.0), d)

		# Aiming a bow: left arm extends along the aim, right hand draws to the cheek.
		if aim_weight > 0.001:
			var local_aim: Vector3 = (global_transform.basis.inverse() * aim_dir).normalized()
			var pitch: float = asin(clampf(local_aim.y, -1.0, 1.0))
			if side == "L":
				sh_rot = sh_rot.lerp(Vector3(-PI * 0.5 - pitch, 0.0, 0.30), aim_weight)
				el_rot = el_rot.lerp(Vector3(-0.10, 0.0, 0.0), aim_weight)
			else:
				sh_rot = sh_rot.lerp(Vector3(-PI * 0.42 - pitch * 0.8, 0.0, -1.02), aim_weight)
				el_rot = el_rot.lerp(Vector3(-2.28, 0.0, 0.0), aim_weight)

		# Melee: a diagonal overhead cut with the right arm, left arm counterbalancing.
		if attack_swing > 0.001:
			var a: float = attack_swing
			var wind: float = clampf(a / 0.30, 0.0, 1.0)
			var strike: float = clampf((a - 0.30) / 0.40, 0.0, 1.0)
			var recover: float = clampf((a - 0.70) / 0.30, 0.0, 1.0)
			var arc: float = lerpf(-2.5, 0.75, strike * strike * (3.0 - 2.0 * strike))
			if side == "R":
				sh_rot = sh_rot.lerp(Vector3(arc, -0.35, -0.5), (1.0 - recover) * (0.35 + wind * 0.65))
				el_rot = el_rot.lerp(Vector3(-0.55 - (1.0 - strike) * 1.1, 0.0, 0.0), 1.0 - recover)
			else:
				sh_rot = sh_rot.lerp(Vector3(0.5, 0.0, 0.9), (1.0 - recover) * 0.6)

		var target_sh := Basis.from_euler(sh_rot)
		var target_el := Basis.from_euler(el_rot)
		var k: float = 1.0 - pow(0.00002, delta)
		shoulder[side].basis = shoulder[side].basis.slerp(target_sh, k)
		elbow[side].basis = elbow[side].basis.slerp(target_el, k)


func _animate_head(delta: float) -> void:
	var target := Vector3(sin(_t * 0.53 + _idle_seed) * 0.05, sin(_t * 0.31 + _idle_seed) * 0.10, 0.0)
	if look_weight > 0.001:
		var local := (global_transform.basis.inverse() * (look_target - head.global_position)).normalized()
		var yaw: float = atan2(-local.x, -local.z)
		var pitch: float = asin(clampf(local.y, -1.0, 1.0))
		target = target.lerp(Vector3(-clampf(pitch, -0.6, 0.6), clampf(yaw, -1.1, 1.1), 0.0), look_weight)
	if aim_weight > 0.001:
		var la: Vector3 = (global_transform.basis.inverse() * aim_dir).normalized()
		target = target.lerp(Vector3(-asin(clampf(la.y, -1.0, 1.0)) * 0.8, atan2(-la.x, -la.z) * 0.7, 0.0), aim_weight)
	neck.rotation = neck.rotation.lerp(target * 0.35, 1.0 - pow(0.0001, delta))
	head.rotation = head.rotation.lerp(target * 0.65, 1.0 - pow(0.0001, delta))


func _pose_dead(a: float) -> void:
	var e: float = clampf(a, 0.0, 1.0)
	hips.position.y = lerpf(hips.position.y, 0.22, e)
	hips.rotation = hips.rotation.lerp(Vector3(-1.35, 0.35, 0.25), e)
	spine.rotation = spine.rotation.lerp(Vector3(0.5, 0.0, 0.2), e)
	chest.rotation = chest.rotation.lerp(Vector3(0.35, 0.2, 0.0), e)
	head.rotation = head.rotation.lerp(Vector3(0.5, 0.4, 0.0), e)
	for side in ["L", "R"]:
		var sx: float = 1.0 if side == "L" else -1.0
		thigh[side].basis = thigh[side].basis.slerp(Basis.from_euler(Vector3(-0.7, 0.0, sx * 0.3)), e)
		knee[side].basis = knee[side].basis.slerp(Basis.from_euler(Vector3(1.1, 0.0, 0.0)), e)
		shoulder[side].basis = shoulder[side].basis.slerp(Basis.from_euler(Vector3(0.4, 0.0, sx * 1.1)), e)
		elbow[side].basis = elbow[side].basis.slerp(Basis.from_euler(Vector3(-0.35, 0.0, 0.0)), e)
