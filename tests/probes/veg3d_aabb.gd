extends SceneTree


func _init() -> void:
	var bad := 0
	for sp in range(TreeBuilder.SPECIES_COUNT):
		for va in range(TreeBuilder.VARIANTS):
			for lod in range(3):
				var m := TreeBuilder.mesh(sp, va, lod)
				var ab := m.get_aabb()
				var ok := true
				for c in [ab.position.x, ab.position.y, ab.position.z, ab.size.x, ab.size.y, ab.size.z]:
					if is_nan(c) or is_inf(c):
						ok = false
				# scan vertices too
				var nnan := 0
				for si in range(m.get_surface_count()):
					var arr := m.surface_get_arrays(si)
					for v in arr[Mesh.ARRAY_VERTEX] as PackedVector3Array:
						if is_nan(v.x) or is_nan(v.y) or is_nan(v.z):
							nnan += 1
					for n in arr[Mesh.ARRAY_NORMAL] as PackedVector3Array:
						if is_nan(n.x) or is_nan(n.y) or is_nan(n.z):
							nnan += 1
				if not ok or nnan > 0:
					bad += 1
					print("BAD %s v%d lod%d aabb=%s nan_verts=%d" % [TreeBuilder.SPECIES_NAMES[sp], va, lod, ab, nnan])
	print("bad meshes: %d" % bad)
	print("RESULT: " + ("PASS" if bad == 0 else "FAIL"))
	quit()
