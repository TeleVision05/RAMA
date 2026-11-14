extends SceneTree
## H2 check: what baked AO (COLOR.g) do canopy leaves actually carry?


func _init() -> void:
	print("%-14s %8s %8s %8s %8s %8s" % ["mesh", "ao_min", "ao_p10", "ao_med", "ao_max", "flexmed"])
	for sp in range(TreeBuilder.SPECIES_COUNT):
		var nm: String = TreeBuilder.SPECIES_NAMES[sp]
		if nm == "rock" or nm == "dead":
			continue
		var m := TreeBuilder.mesh(sp, 0, TreeBuilder.Lod.FULL)
		if m.get_surface_count() < 2:
			continue
		var arr := m.surface_get_arrays(m.get_surface_count() - 1)
		var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
		var ao: Array[float] = []
		var fx: Array[float] = []
		for c in cols:
			ao.append(c.g)
			fx.append(c.r)
		ao.sort()
		fx.sort()
		print(
			(
				"%-14s %8.3f %8.3f %8.3f %8.3f %8.3f"
				% [nm, ao[0], ao[int(ao.size() * 0.1)], ao[ao.size() / 2], ao[ao.size() - 1], fx[fx.size() / 2]]
			)
		)
	quit()
