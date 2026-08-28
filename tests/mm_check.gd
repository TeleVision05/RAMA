extends SceneTree


func _init() -> void:
	var root := get_root()
	await process_frame
	var map := WorldMap.load_or_bake(false)
	var s := Settlement.new()
	root.add_child(s)
	s.setup(map)
	print("--- MultiMesh census (custom_aabb + visibility range) ---")
	var mm_tris := 0
	for c in s.get_children():
		if c is MultiMeshInstance3D:
			var per := 0
			for i in range(c.multimesh.mesh.get_surface_count()):
				per += c.multimesh.mesh.surface_get_array_index_len(i) / 3
			mm_tris += per * c.multimesh.instance_count
			print(
				(
					"  %-18s n=%-4d tris=%-6d aabb=%s vis_end=%.0f"
					% [
						c.name,
						c.multimesh.instance_count,
						per * c.multimesh.instance_count,
						str(c.custom_aabb.size).pad_decimals(0),
						c.visibility_range_end
					]
				)
			)
	var lights := 0
	var nodes := 0
	for c in s.get_children():
		nodes += 1
		for d in c.get_children():
			if d is OmniLight3D:
				lights += 1
			for e in d.get_children():
				if e is OmniLight3D:
					lights += 1
	print("multimesh triangles: %d ; omni lights: %d ; top-level nodes: %d" % [mm_tris, lights, nodes])
	quit()
