class_name ProcRigDetail
extends ProcRigDress
## Part 4 of 6 of ProcRig (see proc_rig.gd): the face (blink, saccades), cloth swing, level
## of detail and grip.
## The six parts form one inheritance chain, so every caller still writes `ProcRig.name`.

# ===========================================================================
#  FACE, CLOTH AND LEVEL OF DETAIL
# ===========================================================================
## Blink, and look at what the head is looking at.
##
## A face whose eyes never move is the single loudest "this is a puppet" cue at
## conversation distance, and both halves are nearly free: the lids are two nodes
## rotating about one axis, and the eyes are two nodes taking a clamped aim.
func _animate_face(delta: float) -> void:
	if _lid_up == null:
		return
	# --- blink. Irregular on purpose; a metronome reads as a machine.
	_blink_t -= delta
	if _blink_t <= 0.0 and _blink_a <= 0.0:
		_blink_a = 0.001
		if _blink_left <= 0:
			_blink_left = 2 if _rng.randf() < 0.22 else 1
	if _blink_a > 0.0:
		# 55 ms shut, 95 ms open: a real blink is not symmetric.
		_blink_a += delta * (1.0 / 0.055 if _blink_dir > 0.0 else -(1.0 / 0.095))
		if _blink_a >= 1.0:
			_blink_a = 1.0
			_blink_dir = -1.0
		elif _blink_a <= 0.0:
			_blink_a = 0.0
			_blink_dir = 1.0
			_blink_left -= 1
			_blink_t = 0.09 if _blink_left > 0 else _rng.randf_range(2.1, 6.4)

	# --- gaze. When nothing is being looked at the eyes still drift and flick, which
	# is what a person's do; a dead-ahead stare is the puppet again.
	var want := Vector2.ZERO
	_sac_t -= delta
	if _sac_t <= 0.0:
		_sac_t = _rng.randf_range(1.1, 3.4)
		_sac = Vector2(_rng.randf_range(-0.16, 0.16), _rng.randf_range(-0.09, 0.07))
	if look_weight > 0.001 and head != null:
		var d: Vector3 = (look_target - eye_centre()).normalized()
		var loc: Vector3 = head.global_transform.basis.inverse() * d
		want = Vector2(atan2(-loc.x, -loc.z), asin(clampf(loc.y, -1.0, 1.0))) * look_weight
	want += _sac * (1.0 - clampf(look_weight, 0.0, 1.0) * 0.55)
	want.x = clampf(want.x, -0.42, 0.42)
	want.y = clampf(want.y, -0.28, 0.24)
	_gaze = _gaze.lerp(want, 1.0 - pow(0.00004, delta))
	for side in ["L", "R"]:
		if eye.has(side):
			(eye[side] as Node3D).rotation = Vector3(_gaze.y, _gaze.x, 0.0)

	# Rotating the lid about X sweeps its edge round the eyeball: -0.74 rad takes the
	# upper lid from open to where the two lids meet, +0.34 brings the lower up to it.
	# The upper lid also FOLLOWS the eye down, or a downward glance shows white above.
	_lid_up.rotation.x = -0.74 * _blink_a + _gaze.y * 0.45
	_lid_lo.rotation.x = 0.34 * _blink_a + _gaze.y * 0.16


## World position between the eyes — where a gaze is measured from.
func eye_centre() -> Vector3:
	if eye.has("L") and eye.has("R"):
		return ((eye["L"] as Node3D).global_position + (eye["R"] as Node3D).global_position) * 0.5
	return head.global_position if head != null else global_position


## Cloth lags the body. A spring on the hem's offset, driven by how fast the character
## is travelling and turning, then read out as a rotation about the waist — so the hem
## swings wide on a turn and trails on a sprint, and settles when they stop.
func _animate_cloth(delta: float, moving: float) -> void:
	if delta <= 0.0 or not is_inside_tree():
		return
	var gp := global_position
	var yaw: float = global_transform.basis.get_euler().y
	var lv := Vector3.ZERO
	if _has_prev:
		lv = global_transform.basis.inverse() * ((gp - _prev_gpos) / delta)
		_turn = wrapf(yaw - _prev_yaw, -PI, PI) / delta
	_prev_gpos = gp
	_prev_yaw = yaw
	_has_prev = true

	# The hem wants to be where the body WAS: opposite the travel, and thrown outward
	# on a turn.
	var drive := Vector2(clampf(-lv.x * 0.070 - _turn * 0.055, -0.42, 0.42), clampf(-lv.z * 0.070, -0.42, 0.42))
	_sway_v += (drive - _sway) * (52.0 * delta)
	_sway_v *= pow(0.02, delta)
	_sway += _sway_v * delta

	if skirt_node != null:
		var flap: float = sin(stride_phase * TAU) * 0.055 * moving
		skirt_node.rotation = Vector3(clampf(-_sway.y * 0.85, -0.34, 0.34), 0.0, clampf(_sway.x * 0.85 + flap, -0.34, 0.34))
	if sash_node != null:
		# Lighter cloth: further and quicker, and it flutters with the stride.
		var f2: float = sin(stride_phase * TAU + 1.1) * 0.10 * moving
		sash_node.rotation = Vector3(clampf(-_sway.y * 1.35, -0.48, 0.48), 0.0, clampf(_sway.x * 1.35 + f2, -0.48, 0.48))


## Hands become mittens and the six eye meshes become one dark pair past `lod_near`.
## Characters are the largest single share of this game's draw calls, so the detail a
## conversation needs has to stop being drawn the moment the conversation is over.
func _update_lod() -> void:
	var want := 0
	if is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			want = 0 if global_position.distance_squared_to(cam.global_position) < lod_near * lod_near else 1
	if want != _lod:
		set_lod(want)


func set_lod(level: int) -> void:
	_lod = level
	var near: bool = level == 0
	for side in ["L", "R"]:
		var hd: Node3D = hand.get(side)
		if hd == null:
			continue
		var l0 := hd.get_node_or_null("Lod0")
		var l1 := hd.get_node_or_null("Lod1")
		if l0:
			(l0 as Node3D).visible = near
		if l1:
			(l1 as Node3D).visible = not near
	# The head's LOD pair is found by MATERIAL, not by node name: `_merge_draws` folds
	# the hair, the brows and the beard into one node with a generated name, and the
	# creature system replaces a rakshasa's head meshes outright. A material identity
	# survives both, and anything with a material this rig did not make is left alone.
	if head != null and not _near_mats.is_empty():
		for c in head.get_children():
			if not (c is MeshInstance3D):
				continue
			var m: Material = (c as MeshInstance3D).material_override
			if m == _skin_lod or m == _hair_lod:
				(c as MeshInstance3D).visible = not near
			elif _near_mats.has(m):
				(c as MeshInstance3D).visible = near
	for side in ["L", "R"]:
		if eye.has(side):
			(eye[side] as Node3D).visible = near
	if _lid_up != null:
		_lid_up.visible = near
	if _lid_lo != null:
		_lid_lo.visible = near
	if _eyes_lo != null and is_instance_valid(_eyes_lo):
		_eyes_lo.visible = not near


## Close the hand round whatever it is holding. `grip_l` / `grip_r` override; left at
## -1 the hand simply looks at its own attach point, so picking up a bow closes the
## fist that holds it without anyone having to remember to say so.
func _update_grip() -> void:
	for side in ["L", "R"]:
		var want: int = int(cfg.grip_l if side == "L" else cfg.grip_r)
		if want < 0:
			var at: Node3D = hand_attach.get(side)
			want = MeshKit.Grip.CLOSED if (at != null and at.get_child_count() > 0) else MeshKit.Grip.RELAXED
		if want == int(_grip[side]):
			continue
		_grip[side] = want
		var sx: float = 1.0 if side == "L" else -1.0
		var hl: float = cfg.hand * 1.35
		var hi: MeshInstance3D = _hand_hi.get(side)
		var lo: MeshInstance3D = _hand_lo.get(side)
		if hi != null and is_instance_valid(hi):
			hi.mesh = MeshKit.hand(hl, cfg.build, want, sx, 0)
		if lo != null and is_instance_valid(lo):
			lo.mesh = MeshKit.hand_lod(hl, cfg.build, want, sx)
