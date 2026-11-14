extends SceneTree


func _init() -> void:
	var n := Arch.shrine(2.6)
	for c in n.get_children():
		if not (c is MeshInstance3D):
			continue
		var m: ArrayMesh = c.mesh
		for si in range(m.get_surface_count()):
			var arr: Array = m.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var lo := Vector3(1e9, 1e9, 1e9)
			var hi := Vector3(-1e9, -1e9, -1e9)
			for p in v:
				lo = Vector3(minf(lo.x, p.x), minf(lo.y, p.y), minf(lo.z, p.z))
				hi = Vector3(maxf(hi.x, p.x), maxf(hi.y, p.y), maxf(hi.z, p.z))
			print(
				(
					"surf %d  mat=%s  y %.2f..%.2f  x %.2f..%.2f  z %.2f..%.2f  verts=%d"
					% [
						si,
						m.surface_get_material(si).resource_name if m.surface_get_material(si) else "?",
						lo.y,
						hi.y,
						lo.x,
						hi.x,
						lo.z,
						hi.z,
						v.size()
					]
				)
			)
			# anything unexpectedly high
			var cluster: Dictionary = {}
			for p in v:
				if p.y > 16.5:
					var key := "%.1f,%.1f,%.1f" % [round(p.x), round(p.y), round(p.z)]
					cluster[key] = true
			if cluster.size() > 0:
				print("    HIGH verts (>16.5): ", cluster.keys().slice(0, 20))
	quit()
