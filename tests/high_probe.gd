extends SceneTree


func _init() -> void:
	var root := get_root()
	await process_frame
	var map := WorldMap.load_or_bake(false)
	var s := Settlement.new()
	root.add_child(s)
	s.setup(map)
	var rows: Array = []
	_walk(s, rows, map)
	rows.sort_custom(func(a, b): return a.top > b.top)
	print("--- highest geometry in the settlement ---")
	for i in range(mini(14, rows.size())):
		var r: Dictionary = rows[i]
		print(
			(
				"  top=%8.2f ground=%7.2f  above=%7.2f  %-22s at (%.0f, %.0f)  %s"
				% [r.top, r.g, r.top - r.g, r.name, r.c.x, r.c.z, r.path]
			)
		)
	quit()


func _walk(n: Node, rows: Array, map: WorldMap) -> void:
	if n is MeshInstance3D and n.mesh:
		var a: AABB = n.global_transform * n.mesh.get_aabb()
		var c: Vector3 = a.get_center()
		rows.append(
			{
				"top": a.position.y + a.size.y,
				"g": map.height_at(c.x, c.z),
				"name": n.name,
				"c": c,
				"path": String(n.get_path())
			}
		)
	elif n is MultiMeshInstance3D and n.multimesh and n.multimesh.mesh:
		var mb: AABB = n.multimesh.mesh.get_aabb()
		for i in range(n.multimesh.instance_count):
			var a2: AABB = (n.global_transform * n.multimesh.get_instance_transform(i)) * mb
			var c2: Vector3 = a2.get_center()
			rows.append(
				{
					"top": a2.position.y + a2.size.y,
					"g": map.height_at(c2.x, c2.z),
					"name": n.name + "#" + str(i),
					"c": c2,
					"path": String(n.get_path())
				}
			)
	for c3 in n.get_children():
		_walk(c3, rows, map)
