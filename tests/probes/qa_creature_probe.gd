extends SceneTree
## QA probe: measure what the creature renders actually contain.
##
## Renders nothing. For each archetype it reports, in the rig's own head-local frame:
## the eye spheres ProcRig published, every mesh hung on the head with its AABB, and
## which of those meshes sit BETWEEN the camera and an eye (i.e. occlude the face).
## Also totals instances and triangles per LOD tier and times the build.
##
## A face that photographs as a blank plank is not a lighting problem, and squinting at
## a PNG cannot tell you which of eleven meshes is the plank. This can.
##   ~/tools/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/probes/qa_creature_probe.gd

const KINDS := [EnemyTypes.Kind.WARRIOR, EnemyTypes.Kind.ARCHER, EnemyTypes.Kind.ELITE]


func _init() -> void:
	var host := Node3D.new()
	get_root().add_child(host)
	await process_frame
	_rig_bench(host)
	for k in KINDS:
		_probe_rakshasa(host, k)
	_probe_beast(host)
	print("done")
	quit()


## Build each archetype repeatedly. CreatureKit claims "everything is memoised ... the
## second rakshasa of a given size generates no meshes at all", and that claim is the
## whole reason a 1.3 ms rig build is possible. If the mesh cache keeps GROWING build
## after build, the claim is false and every spawn pays full generation cost.
func _rig_bench(host: Node3D) -> void:
	for k in KINDS:
		_bench_kind(host, k, EnemyTypes.display_name(k))
	_bench_kind(host, EnemyTypes.Kind.BEAST, "Vyaghra")
	var plain := Node3D.new()
	host.add_child(plain)
	var times: Array[float] = []
	for i in range(6):
		var t0 := Time.get_ticks_usec()
		var pr := ProcRig.new()
		pr.configure({"seed": 4, "topknot": true, "jewellery": true})
		plain.add_child(pr)
		pr.build()
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	print("[bench] %-18s builds ms: %s" % ["ProcRig (ref)", _fmt(times)])
	plain.queue_free()


func _bench_kind(host: Node3D, kind: int, nm: String) -> void:
	var times: Array[float] = []
	var caches: Array[int] = []
	for i in range(6):
		var h := Node3D.new()
		host.add_child(h)
		var t0 := Time.get_ticks_usec()
		EnemyTypes.build_body(kind, h, 5)
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		caches.append(CreatureKit.cache_size())
		h.queue_free()
	print("[bench] %-18s builds ms: %s   CreatureKit cache: %s   MeshKit: %s" % [nm, _fmt(times), str(caches), MeshKit.cache_stats()])


func _fmt(times: Array) -> String:
	var out := ""
	for t in times:
		out += "%.1f " % float(t)
	return out


func _probe_rakshasa(host: Node3D, kind: int) -> void:
	var holder := Node3D.new()
	host.add_child(holder)
	var parts := EnemyTypes.build_body(kind, holder, 3)
	var rig: ProcRig = parts["rig"]
	print("\n===== %s =====" % EnemyTypes.display_name(kind))
	_count(holder, kind)
	if rig == null or rig.head == null:
		print("  no rig/head")
		holder.queue_free()
		return
	var r: float = rig.cfg.head
	print("  cfg.head r = %.3f m" % r)
	# Eye centres in head-local space.
	var eyes := {}
	for side in ["L", "R"]:
		if rig.eye.has(side) and rig.eye[side] != null:
			var e: Node3D = rig.eye[side]
			eyes[side] = rig.head.to_local(e.global_position)
	for side in eyes:
		var p: Vector3 = eyes[side]
		print("  eye %s local (%.3f, %.3f, %.3f) = (%.2f, %.2f, %.2f) r" % [side, p.x, p.y, p.z, p.x / r, p.y / r, p.z / r])
	print("  %-16s %-34s %s" % ["mesh", "aabb pos -> end (head-local, in r)", "occludes eye"])
	for c in rig.head.get_children():
		if not (c is MeshInstance3D):
			continue
		var mi := c as MeshInstance3D
		if mi.mesh == null:
			continue
		var bb: AABB = mi.transform * mi.get_aabb()
		var occ := ""
		for side in eyes:
			var p: Vector3 = eyes[side]
			# An AABB test cannot answer this: a mesh split into a brow band and two
			# cheek streaks has a union box that swallows the eye while leaving it in
			# clear air. So fire the actual viewing ray — straight down -Z at the eye
			# centre, the way the portrait camera looks — and intersect the triangles.
			if _blocks(mi, p):
				occ += side
		print(
			(
				"  %-16s (%5.2f,%5.2f,%5.2f)->(%5.2f,%5.2f,%5.2f)  %s"
				% [
					mi.name,
					bb.position.x / r,
					bb.position.y / r,
					bb.position.z / r,
					(bb.position.x + bb.size.x) / r,
					(bb.position.y + bb.size.y) / r,
					(bb.position.z + bb.size.z) / r,
					occ
				]
			)
		)
	holder.queue_free()


## Does `mi` put geometry between the viewer and the point `p` (both head-local)?
## The ray starts well in front of the face and travels +Z toward the eye.
func _blocks(mi: MeshInstance3D, p: Vector3) -> bool:
	var from := Vector3(p.x, p.y, p.z - 4.0)
	var dir := Vector3(0, 0, 1)
	for s in range(mi.mesh.get_surface_count()):
		var a := mi.mesh.surface_get_arrays(s)
		var vt: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var idx: Variant = a[Mesh.ARRAY_INDEX]
		var n: int = (idx as PackedInt32Array).size() if idx != null else vt.size()
		var i := 0
		while i + 2 < n:
			var t0: Vector3
			var t1: Vector3
			var t2: Vector3
			if idx != null:
				t0 = vt[(idx as PackedInt32Array)[i]]
				t1 = vt[(idx as PackedInt32Array)[i + 1]]
				t2 = vt[(idx as PackedInt32Array)[i + 2]]
			else:
				t0 = vt[i]
				t1 = vt[i + 1]
				t2 = vt[i + 2]
			var hit: Variant = Geometry3D.ray_intersects_triangle(from, dir, mi.transform * t0, mi.transform * t1, mi.transform * t2)
			# A hit counts only if it lands in FRONT of the eye, not behind it.
			if hit != null and (hit as Vector3).z < p.z - 0.0005:
				return true
			i += 3
	return false


func _probe_beast(host: Node3D) -> void:
	var holder := Node3D.new()
	host.add_child(holder)
	var parts := EnemyTypes.build_body(EnemyTypes.Kind.BEAST, holder, 3)
	var beast: BeastRig = parts["beast"]
	print("\n===== Vyaghra =====")
	_count(holder, EnemyTypes.Kind.BEAST)
	if beast == null or beast.head == null:
		holder.queue_free()
		return
	print("  %-16s %s" % ["mesh (head)", "aabb pos -> end, head-local metres"])
	for c in beast.head.get_children():
		if not (c is MeshInstance3D) or (c as MeshInstance3D).mesh == null:
			continue
		var mi := c as MeshInstance3D
		var bb: AABB = mi.transform * mi.get_aabb()
		print(
			(
				"  %-16s (%6.3f,%6.3f,%6.3f)->(%6.3f,%6.3f,%6.3f)"
				% [
					mi.name,
					bb.position.x,
					bb.position.y,
					bb.position.z,
					bb.position.x + bb.size.x,
					bb.position.y + bb.size.y,
					bb.position.z + bb.size.z
				]
			)
		)
	holder.queue_free()


## Instances and triangles, split by whether the mesh fades at DETAIL_DIST.
func _count(n: Node, _kind: int) -> void:
	var acc := {"n": 0, "hi": 0, "mid": 0, "open": []}
	_walk(n, acc)
	var drop: float = 100.0 * (1.0 - float(acc.mid) / maxf(1.0, float(acc.hi)))
	print("  instances=%d  tris HIGH=%d  tris MID=%d  (drop %.0f%%)" % [acc.n, acc.hi, acc.mid, drop])


func _walk(n: Node, acc: Dictionary) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			var mi := c as MeshInstance3D
			if mi.mesh != null and mi.is_visible_in_tree():
				var t := _tris(mi.mesh)
				acc.n += 1
				acc.hi += t
				if mi.visibility_range_end <= 0.0:
					acc.mid += t
		if c.get_child_count() > 0:
			_walk(c, acc)


func _tris(m: Mesh) -> int:
	var t := 0
	for s in range(m.get_surface_count()):
		var a := m.surface_get_arrays(s)
		var idx: Variant = a[Mesh.ARRAY_INDEX]
		if idx != null and (idx as PackedInt32Array).size() > 0:
			t += (idx as PackedInt32Array).size() / 3
		else:
			t += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t
