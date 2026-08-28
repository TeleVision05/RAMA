extends SceneTree


func _init() -> void:
	var total_full := 0
	print("%-8s %3s %8s %8s %8s" % ["species", "var", "FULL", "MID", "FAR"])
	for sp in range(TreeBuilder.SPECIES_COUNT):
		for va in range(TreeBuilder.VARIANTS):
			var a := TreeBuilder.triangles(sp, va, TreeBuilder.Lod.FULL)
			var b := TreeBuilder.triangles(sp, va, TreeBuilder.Lod.MID)
			var c := TreeBuilder.triangles(sp, va, TreeBuilder.Lod.FAR)
			total_full += a
			print("%-8s %3d %8d %8d %8d" % [TreeBuilder.SPECIES_NAMES[sp], va, a, b, c])
	print("sum of FULL over all species/variants: %d" % total_full)
	quit()
