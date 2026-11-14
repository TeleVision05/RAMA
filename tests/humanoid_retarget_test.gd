extends SceneTree
## Every humanoid character model, in every retargeted clip, stays the size of a person.
##
## Guards the animation retarget (scripts/player/humanoid_retarget.gd). The clips come from
## a metre-scale skeleton and the characters have a centimetre-scale one; copied across
## unchanged, the walk lifted the hips 38 m and the skinned meshes were drawn there, which
## showed as a huge dark spiky shape above the village (the skirted `woman` model, on every
## woman villager). A skinned mesh's own bounding box does NOT move with the pose, so the
## check skins the vertices itself: for each model, clip and a few moments of the clip, it
## poses the skeleton, moves every sampled vertex by its bone weights, and asserts the
## result stays inside a person-sized box around the character's feet.
##
## Also: the three characters that share a skeleton layout but not a rest pose must each get
## their own retargeted clips (the woman's differ from the king's).
##
## Run:  Godot --headless --path . --script tests/humanoid_retarget_test.gd
## Pass `-- --probe` to print the measured extents instead of only failures.

## Box a person fits in, metres, around the model origin (feet at y = 0, facing away).
const MAX_HEIGHT := 2.4
const MIN_Y := -0.35
const MAX_REACH := 1.6
## Per-bone distance from the origin: a bone further than this is not on a person.
const MAX_BONE_DIST := 3.0
const SAMPLES := [0.0, 0.25, 0.5, 0.75, 0.99]
const VERTEX_STRIDE := 5

var failures: Array[String] = []
var probe: bool = false


func _initialize() -> void:
	probe = OS.get_cmdline_user_args().has("--probe")
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var holder := Node3D.new()
	root.add_child(holder)
	var files := {}
	for key in HumanoidModel.MODEL_PATHS:
		files[HumanoidModel.MODEL_PATHS[key]] = key
	var checked := 0
	for path in files:
		var h := HumanoidModel.build(files[path])
		holder.add_child(h)
		checked += _check_model(String(files[path]), h)
		holder.remove_child(h)
		h.free()
	_check_libraries_differ()
	if checked == 0:
		failures.append("no clips were checked: the models or clips did not load")
	print("humanoid retarget: %d model/clip/time samples checked" % checked)
	if failures.is_empty():
		print("RESULT: PASS")
	else:
		for f in failures:
			print("FAIL: ", f)
		print("RESULT: FAIL (%d)" % failures.size())
	quit(0 if failures.is_empty() else 1)


func _check_model(key: String, h: HumanoidModel) -> int:
	var n := 0
	var skel := h.skeleton
	var meshes: Array[MeshInstance3D] = []
	for m in skel.get_children():
		if m is MeshInstance3D and (m as MeshInstance3D).skin != null:
			meshes.append(m)
	if h.anim_player == null or meshes.is_empty():
		failures.append("%s: no skeleton, animation player or skinned mesh" % key)
		return 0
	for clip in h.anim_player.get_animation_list():
		var len := h.anim_player.get_animation(clip).length
		for f in SAMPLES:
			h.play(clip, 0.0)
			h.anim_player.seek(len * f, true)
			h.anim_player.advance(0.0)
			_check_pose("%s/%s@%.2f" % [key, clip, f], skel, meshes)
			n += 1
	_check_idle_stance(key, h)
	return n


func _bone_y(skel: Skeleton3D, bone: String) -> float:
	var i := skel.find_bone(bone)
	return (skel.global_transform * skel.get_bone_global_pose(i).origin).y if i >= 0 else NAN


## Standing at ease: head at a person's height, feet on the ground, arms hanging below the
## chest. Catches a clip that is merely small enough to pass the box test but bent wrong
## (arms out in a T, legs folded the wrong way).
func _check_idle_stance(key: String, h: HumanoidModel) -> void:
	h.play("idle", 0.0)
	h.anim_player.seek(0.0, true)
	h.anim_player.advance(0.0)
	var sk := h.skeleton
	var head := _bone_y(sk, "Head")
	var chest := _bone_y(sk, "Chest")
	if not (head > 1.2 and head < 2.1):
		failures.append("%s idle: head at %.2f m, expected 1.2 to 2.1" % [key, head])
	for side in ["L", "R"]:
		if not (_bone_y(sk, "Hand." + side) < chest - 0.1):
			failures.append("%s idle: %s hand is not hanging below the chest" % [key, side])
		if not (_bone_y(sk, "Foot." + side) < 0.25):
			failures.append("%s idle: %s foot is off the ground" % [key, side])


func _check_pose(label: String, skel: Skeleton3D, meshes: Array[MeshInstance3D]) -> void:
	var far := 0.0
	for i in skel.get_bone_count():
		far = maxf(far, (skel.global_transform * skel.get_bone_global_pose(i).origin).length())
	if far > MAX_BONE_DIST:
		failures.append("%s: a bone is %.1f m from the character (limit %.1f)" % [label, far, MAX_BONE_DIST])
	for mi in meshes:
		var box := _skinned_aabb(skel, mi)
		var ok: bool = (
			box.size.y <= MAX_HEIGHT
			and box.position.y >= MIN_Y
			and absf(box.position.x) <= MAX_REACH
			and absf(box.end.x) <= MAX_REACH
			and absf(box.position.z) <= MAX_REACH
			and absf(box.end.z) <= MAX_REACH
		)
		if probe:
			print("  %s %s box pos %s size %s" % [label, mi.name, box.position, box.size])
		if not ok:
			failures.append("%s: mesh %s spans %s (size %s), not a person-sized box" % [label, mi.name, box.position, box.size])


## The mesh's bounding box in the character's space with the current pose applied,
## from every VERTEX_STRIDE-th vertex of every surface.
func _skinned_aabb(skel: Skeleton3D, mi: MeshInstance3D) -> AABB:
	var skin := mi.skin
	var palette: Array[Transform3D] = []
	for b in skin.get_bind_count():
		var bone := skin.get_bind_bone(b)
		if bone < 0:
			bone = skel.find_bone(skin.get_bind_name(b))
		palette.append(skel.get_bone_global_pose(bone) * skin.get_bind_pose(b))
	var to_skel: Transform3D = skel.global_transform.affine_inverse() * mi.global_transform
	var box := AABB()
	var first := true
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var per := 4 if verts.size() == 0 else bones.size() / verts.size()
		for v in range(0, verts.size(), VERTEX_STRIDE):
			var p := to_skel * verts[v]
			var acc := Vector3.ZERO
			for k in per:
				var w := weights[v * per + k]
				if w > 0.0:
					acc += (palette[bones[v * per + k]] * p) * w
			var world := skel.global_transform * acc
			if first:
				box = AABB(world, Vector3.ZERO)
				first = false
			else:
				box = box.expand(world)
	return box


## Retargeting depends on each skeleton's rest pose, so two model files must not share clips.
func _check_libraries_differ() -> void:
	var a := HumanoidModel.build("king")
	var b := HumanoidModel.build("woman")
	root.add_child(a)
	root.add_child(b)
	var wa := a.anim_player.get_animation("walk")
	var wb := b.anim_player.get_animation("walk")
	if wa == null or wb == null or wa == wb:
		failures.append("the king and the woman share one retargeted walk clip")
	a.queue_free()
	b.queue_free()
