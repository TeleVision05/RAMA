class_name HumanoidRetarget
extends RefCounted
## Moves an animation clip from one humanoid skeleton onto another whose bones are named
## alike but built differently.
##
## The clips (KayKit) and the characters (Quaternius) do not share a skeleton: the clips'
## bones are a metre long where the characters' are a centimetre, and the same bone has a
## different rest orientation in each (an upper leg is turned a half turn in one and a
## quarter turn in the other). Copying the clips' keys across unchanged, as this once did,
## put the hips 38 m up and bent every limb the wrong way; the skinned meshes were drawn
## there, so a skirted villager showed as a huge dark spiky shape above the village.
##
## The retarget works in model space, per bone:
##   * rotation: how far the bone has turned from its own rest orientation (as a model-space
##     rotation) is applied to the target bone's rest orientation, then expressed relative
##     to the target bone's parent. Rest-pose differences cancel out.
##   * position: only the hips move; bone lengths belong to the character. The hips' travel
##     from rest is scaled by the ratio of the two hip heights.
## A skeleton is described by rig_data(); a clip is moved by retarget().

const HIPS := "hips"


## A skeleton's bones as plain data: lower-case names, parents, rest transforms, rest in
## model space (including the nodes above the skeleton up to `root`) and parents-first order.
static func rig_data(skel: Skeleton3D, root: Node) -> Dictionary:
	var frame := Transform3D.IDENTITY
	var n: Node = skel
	while n != null and n != root:
		if n is Node3D:
			frame = (n as Node3D).transform * frame
		n = n.get_parent()
	var count := skel.get_bone_count()
	var names := PackedStringArray()
	var real_names := PackedStringArray()
	var parent := PackedInt32Array()
	var rest: Array[Transform3D] = []
	var index := {}
	for i in count:
		real_names.append(skel.get_bone_name(i))
		names.append(skel.get_bone_name(i).to_lower())
		parent.append(skel.get_bone_parent(i))
		rest.append(skel.get_bone_rest(i))
		index[names[i]] = i
	var order := _parents_first(parent)
	var grest: Array[Transform3D] = []
	grest.resize(count)
	for i in order:
		var up: Transform3D = frame if parent[i] < 0 else grest[parent[i]]
		grest[i] = up * rest[i]
	return {
		"names": names,
		"real_names": real_names,
		"parent": parent,
		"rest": rest,
		"grest": grest,
		"order": order,
		"frame": frame,
		"index": index,
	}


static func _parents_first(parent: PackedInt32Array) -> PackedInt32Array:
	var order := PackedInt32Array()
	var done := {}
	while order.size() < parent.size():
		var progressed := false
		for i in parent.size():
			if done.has(i):
				continue
			if parent[i] < 0 or done.has(parent[i]):
				order.append(i)
				done[i] = true
				progressed = true
		if not progressed:
			break
	return order


static func _rot(t: Transform3D) -> Quaternion:
	return t.basis.orthonormalized().get_rotation_quaternion()


## Tracks of `anim` by lower-case bone name: {name: {"rot": track, "pos": track}}.
static func _bone_tracks(anim: Animation) -> Dictionary:
	var out := {}
	for t in anim.get_track_count():
		var parts := String(anim.track_get_path(t)).split(":")
		if parts.size() != 2:
			continue
		var kind := ""
		match anim.track_get_type(t):
			Animation.TYPE_ROTATION_3D:
				kind = "rot"
			Animation.TYPE_POSITION_3D:
				kind = "pos"
			_:
				continue
		var key := parts[1].to_lower()
		if not out.has(key):
			out[key] = {}
		out[key][kind] = t
	return out


## Every time at which any bone of the clip has a key, in order, in whole milliseconds.
static func _key_times(anim: Animation, tracks: Dictionary) -> Array:
	var seen := {}
	for bone in tracks:
		for kind in tracks[bone]:
			var t: int = tracks[bone][kind]
			for k in anim.track_get_key_count(t):
				seen[roundi(anim.track_get_key_time(t, k) * 1000.0)] = true
	if seen.is_empty():
		seen[0] = true
	var times := seen.keys()
	times.sort()
	return times


## The source bones' rotations in model space at time `t`, and the hips' local position.
static func _source_pose(anim: Animation, tracks: Dictionary, src: Dictionary, t: float) -> Dictionary:
	var count: int = src["names"].size()
	var glob: Array[Quaternion] = []
	glob.resize(count)
	var frame_q := _rot(src["frame"])
	var hips_pos := Vector3.ZERO
	for i in src["order"]:
		var name: String = src["names"][i]
		var local: Quaternion = _rot(src["rest"][i])
		var tr: Dictionary = tracks.get(name, {})
		if tr.has("rot"):
			local = anim.rotation_track_interpolate(tr["rot"], t)
		var p: int = src["parent"][i]
		glob[i] = (frame_q if p < 0 else glob[p]) * local
		if name == HIPS:
			hips_pos = src["rest"][i].origin
			if tr.has("pos"):
				hips_pos = anim.position_track_interpolate(tr["pos"], t)
	return {"glob": glob, "hips_pos": hips_pos}


## Retarget one clip. `src` and `dst` come from rig_data(); `skel_path` is the target
## skeleton's path from the AnimationPlayer's root node. Only bones present in both
## skeletons get tracks; the rest stay at their rest pose.
static func retarget(clip: Animation, src: Dictionary, dst: Dictionary, skel_path: String) -> Animation:
	var out := Animation.new()
	out.length = clip.length
	var tracks := _bone_tracks(clip)
	var times := _key_times(clip, tracks)
	var matched: Array[int] = []
	for j in dst["order"]:
		if src["index"].has(dst["names"][j]):
			matched.append(j)
	var rot_track := {}
	for j in matched:
		var ti := out.add_track(Animation.TYPE_ROTATION_3D)
		out.track_set_path(ti, NodePath("%s:%s" % [skel_path, dst["real_names"][j]]))
		rot_track[j] = ti
	var pos_track := -1
	var hips_dst: int = dst["index"].get(HIPS, -1)
	var hips_src: int = src["index"].get(HIPS, -1)
	if hips_dst >= 0 and hips_src >= 0 and tracks.has(HIPS) and tracks[HIPS].has("pos"):
		pos_track = out.add_track(Animation.TYPE_POSITION_3D)
		out.track_set_path(pos_track, NodePath("%s:%s" % [skel_path, dst["real_names"][hips_dst]]))
	var last := {}
	for ms in times:
		var t := float(ms) / 1000.0
		var pose := _source_pose(clip, tracks, src, t)
		var rots := _target_rotations(pose, src, dst)
		for j in matched:
			var q: Quaternion = rots[j]
			if last.has(j) and (last[j] as Quaternion).dot(q) < 0.0:
				q = -q
			last[j] = q
			out.rotation_track_insert_key(rot_track[j], t, q)
		if pos_track >= 0:
			out.position_track_insert_key(pos_track, t, _target_hips_position(pose, src, dst))
	return out


## The target bones' local rotations for a source pose (see the header).
static func _target_rotations(pose: Dictionary, src: Dictionary, dst: Dictionary) -> Array[Quaternion]:
	var count: int = dst["names"].size()
	var glob: Array[Quaternion] = []
	glob.resize(count)
	var local: Array[Quaternion] = []
	local.resize(count)
	var frame_q := _rot(dst["frame"])
	for j in dst["order"]:
		var p: int = dst["parent"][j]
		var up: Quaternion = frame_q if p < 0 else glob[p]
		var rest_local := _rot(dst["rest"][j])
		var i: int = src["index"].get(dst["names"][j], -1)
		if i < 0:
			glob[j] = up * rest_local
			local[j] = rest_local
			continue
		var delta: Quaternion = (pose["glob"][i] as Quaternion) * _rot(src["grest"][i]).inverse()
		glob[j] = delta * _rot(dst["grest"][j])
		local[j] = (up.inverse() * glob[j]).normalized()
	return local


## Where the target's hips go: its rest position plus the source hips' travel from rest,
## scaled by the ratio of the two hip heights, in the hips' parent's space.
static func _target_hips_position(pose: Dictionary, src: Dictionary, dst: Dictionary) -> Vector3:
	var si: int = src["index"][HIPS]
	var di: int = dst["index"][HIPS]
	var sp: int = src["parent"][si]
	var dp: int = dst["parent"][di]
	var s_up: Transform3D = src["frame"] if sp < 0 else src["grest"][sp]
	var d_up: Transform3D = dst["frame"] if dp < 0 else dst["grest"][dp]
	var s_rest: Vector3 = (src["grest"][si] as Transform3D).origin
	var d_rest: Vector3 = (dst["grest"][di] as Transform3D).origin
	var s_now: Vector3 = s_up * (pose["hips_pos"] as Vector3)
	var ratio := 1.0
	if absf(s_rest.y) > 0.0001:
		ratio = d_rest.y / s_rest.y
	var d_now := d_rest + (s_now - s_rest) * ratio
	return d_up.affine_inverse() * d_now
