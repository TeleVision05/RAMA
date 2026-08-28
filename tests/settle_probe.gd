extends SceneTree


func _init() -> void:
	var m := WorldMap.load_or_bake(false)
	var c := WorldMap.P_SHRINE
	var step := 3.0
	var n := 9
	var hdr := "        "
	for dx in range(-n, n + 1):
		hdr += "%7.0f" % (c.x + dx * step)
	print(hdr)
	for dz in range(-n, n + 1):
		var line := "z%7.0f" % (c.y + dz * step)
		for dx in range(-n, n + 1):
			var p := c + Vector2(dx * step, dz * step)
			line += "%7.2f" % m.height_at(p.x, p.y)
		print(line)
	print("--- path mask ---")
	for dz in range(-n, n + 1):
		var line := "z%7.0f" % (c.y + dz * step)
		for dx in range(-n, n + 1):
			var p := c + Vector2(dx * step, dz * step)
			line += "%7.2f" % m.path_at(p.x, p.y)
		print(line)
	# find flattest 20x20 patch near shrine
	var best := 1e9
	var bestp := c
	for dz in range(-14, 15):
		for dx in range(-14, 15):
			var q := c + Vector2(dx * 2.0, dz * 2.0)
			var lo := 1e9
			var hi := -1e9
			for j in range(-5, 6):
				for i in range(-5, 6):
					var h := m.height_at(q.x + i * 2.0, q.y + j * 2.0)
					lo = minf(lo, h)
					hi = maxf(hi, h)
			var span := hi - lo
			# prefer high ground too
			var sc := span - (m.height_at(q.x, q.y) - 45.0) * 0.15
			if sc < best:
				best = sc
				bestp = q
	print("flattest 20m patch near shrine: %s span-score %.2f h=%.2f" % [bestp, best, m.height_at(bestp.x, bestp.y)])
	quit()
