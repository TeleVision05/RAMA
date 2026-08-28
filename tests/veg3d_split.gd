extends SceneTree


func _init() -> void:
	print("%-8s %4s %8s %8s %8s" % ["species", "lod", "bark", "leaf", "total"])
	for sp in range(TreeBuilder.SPECIES_COUNT):
		for lod in range(2):
			var m := TreeBuilder.mesh(sp, 1, lod)
			var t := [0, 0]
			for i in range(m.get_surface_count()):
				t[i] = m.surface_get_array_index_len(i) / 3
			print("%-8s %4d %8d %8d %8d" % [TreeBuilder.SPECIES_NAMES[sp], lod, t[0], t[1], t[0] + t[1]])
	quit()
