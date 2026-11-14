extends SceneTree
## Audit: nothing may float or sink. Walks every mesh in the Settlement, takes the
## world-space AABB of its geometry, and compares its bottom against the ground under
## the same XZ. Reports offenders with their node path so they can be traced.
##
## RUN WINDOWED. Under --headless the dummy RenderingServer stores nothing for a
## MultiMesh: set_instance_transform() is discarded, get_instance_transform() returns
## IDENTITY for every instance and multimesh.buffer is empty. Every scattered prop then
## audits as if it stood at the world origin, which is under a hill, so the float test
## passes on all of them and this file prints "0 issues" while checking nothing. That is
## exactly what it did for its first two hundred and forty-four instances. _mm_usable()
## below refuses to report a MultiMesh result it cannot trust.
##
## tests/qa_settle_ground.gd is the stricter successor: it also checks BURIAL, exempts
## nothing by name, and resolves what is holding each object up.


func _walk(n: Node, out: Array, map: WorldMap) -> void:
	if n is MeshInstance3D and n.mesh:
		var ab: AABB = n.mesh.get_aabb()
		_check(n.name, n.get_path(), n.global_transform * ab, out, map)
	elif n is MultiMeshInstance3D and n.multimesh and n.multimesh.mesh:
		if not _mm_usable(n.multimesh):
			out.append("%-42s MULTIMESH NOT CHECKED - transforms read back identity; run windowed" % n.name)
			for c0 in n.get_children():
				_walk(c0, out, map)
			return
		var mb: AABB = n.multimesh.mesh.get_aabb()
		var worst := 0.0
		var worst_i := -1
		for i in range(n.multimesh.instance_count):
			var t: Transform3D = n.global_transform * n.multimesh.get_instance_transform(i)
			var a: AABB = t * mb
			var c: Vector3 = a.get_center()
			var gh: float = map.height_at(c.x, c.z)
			var gap: float = a.position.y - gh
			if gap > worst:
				worst = gap
				worst_i = i
		if worst > 0.6:
			out.append("%-42s MULTIMESH inst %d floats %.2f m" % [n.name, worst_i, worst])
	for c in n.get_children():
		_walk(c, out, map)


## True only if the renderer actually kept this MultiMesh's instance data.
static func _mm_usable(mm: MultiMesh) -> bool:
	if mm.instance_count == 0:
		return false
	for i in [0, mm.instance_count / 2, mm.instance_count - 1]:
		if mm.get_instance_transform(i) != Transform3D.IDENTITY:
			return true
	return false


func _check(nm: String, path: NodePath, a: AABB, out: Array, map: WorldMap) -> void:
	var c: Vector3 = a.get_center()
	if not map.in_bounds(c.x, c.z):
		out.append("%-42s OUT OF BOUNDS at %s" % [nm, c])
		return
	# sample the ground under the footprint, take the lowest
	var lo: float = 1e9
	for j in range(3):
		for i in range(3):
			var x: float = lerpf(a.position.x, a.position.x + a.size.x, float(i) / 2.0)
			var z: float = lerpf(a.position.z, a.position.z + a.size.z, float(j) / 2.0)
			lo = minf(lo, map.height_at(x, z))
	var gap: float = a.position.y - lo
	# Anything standing ON the temple plinth is legitimately above grade.
	if String(path).contains("/Shrine/"):
		return
	if gap > 1.2:
		out.append("%-42s FLOATS %.2f m  bottom=%.1f ground=%.1f at (%.0f,%.0f) %s" % [nm, gap, a.position.y, lo, c.x, c.z, path])


func _init() -> void:
	var root := get_root()
	await process_frame
	var map := WorldMap.load_or_bake(false)
	var s := Settlement.new()
	root.add_child(s)
	s.setup(map)
	var out: Array = []
	_walk(s, out, map)
	print("--- float audit: %d issues ---" % out.size())
	for o in out:
		print("  " + o)
	# triangle census by system
	var tot := 0
	for c in s.get_children():
		var t := _tris(c)
		tot += t
		if t > 1500:
			print("  tris %-32s %d" % [c.name, t])
	print("TOTAL TRIANGLES: %d over %d children" % [tot, s.get_child_count()])
	quit()


func _tris(n: Node) -> int:
	var t := 0
	if n is MeshInstance3D and n.mesh:
		for i in range(n.mesh.get_surface_count()):
			t += n.mesh.surface_get_array_index_len(i) / 3
	elif n is MultiMeshInstance3D and n.multimesh and n.multimesh.mesh:
		var per := 0
		for i in range(n.multimesh.mesh.get_surface_count()):
			per += n.multimesh.mesh.surface_get_array_index_len(i) / 3
		t += per * n.multimesh.instance_count
	for c in n.get_children():
		t += _tris(c)
	return t
