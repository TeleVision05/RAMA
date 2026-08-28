extends SceneTree


func _init() -> void:
	var m := WorldMap.load_or_bake(true)
	var t := Terrain.new()
	get_root().add_child(t)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/terrain.gdshader")
	var t0 := Time.get_ticks_msec()
	t.setup(m, mat)
	print("chunk nodes + collider: %d ms" % (Time.get_ticks_msec() - t0))

	var fails: Array[String] = []
	# Build one chunk at every LOD and check the geometry.
	for lod in range(4):
		var t1 := Time.get_ticks_msec()
		var mesh := t._build_mesh(Vector2(-128.0, 0.0), lod)
		var ms := Time.get_ticks_msec() - t1
		var arrs := mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrs[Mesh.ARRAY_INDEX]
		var aabb := mesh.get_aabb()
		print("LOD%d: %d verts, %d tris, %d ms, aabb=%s" % [lod, v.size(), idx.size() / 3, ms, aabb])
		if v.size() == 0 or idx.size() == 0:
			fails.append("LOD%d produced empty mesh" % lod)
		if aabb.size.x < 60.0 or aabb.size.z < 60.0:
			fails.append("LOD%d aabb does not span the chunk: %s" % [lod, aabb.size])
		# Every vertex of the top grid must sit exactly on the heightfield.
		var side: int = int(Terrain.CHUNK / float(Terrain.LOD_STEP[lod])) + 1
		var worst := 0.0
		for k in range(side * side):
			var p: Vector3 = v[k]
			worst = maxf(worst, absf(p.y - m.height_at(p.x, p.z)))
		print("     max deviation from heightfield: %.4f m" % worst)
		if worst > 0.001:
			fails.append("LOD%d vertices do not match the heightfield (%.3f m)" % [lod, worst])

	# Full-world build timing at the LOD the player would actually see.
	var t2 := Time.get_ticks_msec()
	t.update_focus(Vector3(-120, 12, 44), true)
	print("full world resolve: %d ms" % (Time.get_ticks_msec() - t2))
	var lods := {}
	var tris := 0
	for c in t._chunks:
		lods[c.lod] = lods.get(c.lod, 0) + 1
		if c.node.mesh:
			tris += c.node.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() / 3
	print("chunks by LOD: %s   total tris: %d" % [lods, tris])
	if tris > 900000:
		fails.append("triangle budget blown: %d" % tris)
	if lods.has(-1):
		fails.append("%d chunks never got a mesh" % lods[-1])

	print("\nRESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	quit(0 if fails.is_empty() else 1)
