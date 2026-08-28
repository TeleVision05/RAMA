extends SceneTree


func _init() -> void:
	var m := WorldMap.load_or_bake()
	var ox := -100.0
	var oz := 20.0
	var t0 := Time.get_ticks_usec()
	for i in range(49):
		var p := Vector2(ox + float(i % 7) * 3.33, oz + float(i / 7) * 3.33)
		m.slope_at(p.x, p.y)
	var t1 := Time.get_ticks_usec()
	for i in range(49):
		var p := Vector2(ox + float(i % 7) * 3.33, oz + float(i / 7) * 3.33)
		m.normal_at(p.x, p.y)
	var t2 := Time.get_ticks_usec()
	for i in range(49):
		var p := Vector2(ox + float(i % 7) * 3.33, oz + float(i / 7) * 3.33)
		m.forest_density(p)
	var t3 := Time.get_ticks_usec()
	for i in range(49):
		var p := Vector2(ox + float(i % 7) * 3.33, oz + float(i / 7) * 3.33)
		m.water_depth_at(p.x, p.y)
		m.river_dist(p)
	var t4 := Time.get_ticks_usec()
	for i in range(49):
		var p := Vector2(ox + float(i % 7) * 3.33, oz + float(i / 7) * 3.33)
		m.path_at(p.x, p.y)
		m.biome_at(p.x, p.y)
	var t5 := Time.get_ticks_usec()
	var acc := 0.0
	for i in range(640):
		acc += m.height_at(ox + float(i % 20), oz + float(i / 20))
	var t6 := Time.get_ticks_usec()
	var b := Basis.IDENTITY
	for i in range(640):
		b = Basis(Vector3.UP, float(i) * 0.01).scaled(Vector3(1.0, 1.1, 1.0))
	var t7 := Time.get_ticks_usec()
	print("49x slope_at        %6.2f ms" % ((t1 - t0) / 1000.0))
	print("49x normal_at       %6.2f ms" % ((t2 - t1) / 1000.0))
	print("49x forest_density  %6.2f ms" % ((t3 - t2) / 1000.0))
	print("49x waterdepth+riv  %6.2f ms" % ((t4 - t3) / 1000.0))
	print("49x path+biome      %6.2f ms" % ((t5 - t4) / 1000.0))
	print("640x height_at      %6.2f ms  (%f)" % [(t6 - t5) / 1000.0, acc])
	print("640x Basis          %6.2f ms  (%s)" % [(t7 - t6) / 1000.0, str(b.x.x)])
	quit()
