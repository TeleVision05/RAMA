extends SceneTree


func _init() -> void:
	var m := WorldMap.load_or_bake(false)
	var names := ["RIVERBED", "SAND", "MEADOW", "FOREST", "ROCK", "MOUNTAIN", "FIELD", "VILLAGE", "PATH"]
	print("%-16s %-9s dirt forest rock sand | grass" % ["pos", "biome"])
	for p in [
		Vector2(-114, 66),
		Vector2(-120, 44),
		Vector2(-70, 27),
		Vector2(-180, -10),
		Vector2(150, -60),
		Vector2(96, -150),
		Vector2(-168, -140),
		Vector2(-90, 60),
		Vector2(200, 100),
		Vector2(-300, 120)
	]:
		var i := m._idx(int((p.x + WorldMap.HALF) / WorldMap.CELL), int((p.y + WorldMap.HALF) / WorldMap.CELL))
		var j := i * 4
		var d := m.layer[j] / 255.0
		var f := m.layer[j + 1] / 255.0
		var r := m.layer[j + 2] / 255.0
		var s := m.layer[j + 3] / 255.0
		print("%-16s %-9s %.2f %.2f  %.2f %.2f | %.2f" % [p, names[m.biomes[i]], d, f, r, s, clampf(1.0 - (d + f + r + s), 0, 1)])
	# Average over the whole map
	var tot := [0.0, 0.0, 0.0, 0.0]
	var n := WorldMap.GRID * WorldMap.GRID
	for k in range(0, n, 7):
		for c in range(4):
			tot[c] += m.layer[k * 4 + c] / 255.0
	var cnt := float(int(n / 7.0) + 1)
	print(
		(
			"world average: dirt=%.3f forest=%.3f rock=%.3f sand=%.3f grass=%.3f"
			% [tot[0] / cnt, tot[1] / cnt, tot[2] / cnt, tot[3] / cnt, 1.0 - (tot[0] + tot[1] + tot[2] + tot[3]) / cnt]
		)
	)
	quit()
