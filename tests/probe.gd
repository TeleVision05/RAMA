extends SceneTree


func _init() -> void:
	var m := WorldMap.load_or_bake(true)
	print("pt              height   path_mask  slope")
	for i in range(16):
		var p := Vector2(-184.0, -14.0).lerp(Vector2(-196.0, -34.0), float(i) / 15.0)
		print("%-16s %6.2f  %6.3f  %5.3f" % [p, m.height_at(p.x, p.y), m.path_at(p.x, p.y), m.slope_at(p.x, p.y)])
	print("raw at camp: %.2f   flattened: %.2f" % [m._raw_height(-196, -34), m.height_at(-196, -34)])
	print("raw at -184,-14: %.2f  final: %.2f" % [m._raw_height(-184, -14), m.height_at(-184, -14)])
	quit()
