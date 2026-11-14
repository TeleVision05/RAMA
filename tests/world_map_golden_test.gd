extends SceneTree
## Characterisation test for WorldMap: bakes the map from scratch (no cache) and compares it
## with tests/golden/world_map.txt, so world_map.gd can be split or refactored without
## moving a single hill, road or biome.
##
## The golden file holds, for every baked array, its size, min, max and mean (rounded to
## 0.01) and, under --exact, a hash of the exact bytes; the biome histogram; and a grid of
## 49 query points (height, slope, biome, path, wetness, water height) rounded to 0.05.
##   default   compares the rounded figures; the biome histogram within 0.2 per cent per bin
##   --exact   also compares the byte hashes (same machine and engine only)
##   --update  rewrites the golden file from the current code
## Run:  Godot --headless --path . --script tests/world_map_golden_test.gd -- --exact

const GOLDEN := "res://tests/golden/world_map.txt"
const PLACES := [
	"P_VILLAGE", "P_SHRINE", "P_RUINS", "P_WATERFALL", "P_FORD", "P_FOREST_CAMP", "P_HIDDEN_GROVE", "P_BADLANDS", "P_FIELDS", "P_LOOKOUT"
]


func _initialize() -> void:
	_run.call_deferred()


func _bytes_hash(a: Variant) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(a.to_byte_array() if not (a is PackedByteArray) else a)
	return ctx.finish().hex_encode().substr(0, 16)


func _stats(a: Variant) -> String:
	var lo := 1.0e18
	var hi := -1.0e18
	var sum := 0.0
	for v in a:
		var f := float(v)
		lo = minf(lo, f)
		hi = maxf(hi, f)
		sum += f
	return "%d|%.2f|%.2f|%.2f" % [a.size(), lo, hi, sum / float(maxi(a.size(), 1))]


func _lines(m: WorldMap) -> Array[String]:
	var out: Array[String] = []
	for k in ["heights", "path_mask", "wet_mask", "biomes", "ao", "layer"]:
		var a: Variant = m.get(k)
		out.append("%s = %s = %s" % [k, _stats(a), _bytes_hash(a)])
	var hist := PackedInt32Array()
	hist.resize(9)
	for b in m.biomes:
		hist[b] += 1
	out.append("biome_hist = %s = -" % ",".join(Array(hist).map(func(n): return str(n))))
	out.append("river_points = %d = -" % m.river_points().size())
	out.append("paths = %d|%s = -" % [m.paths().size(), ",".join(m.paths().map(func(p): return str(p.size()))) ])
	for iz in range(-3, 4):
		for ix in range(-3, 4):
			var x := float(ix) * 110.0
			var z := float(iz) * 110.0
			var q := "%.2f|%.2f|%d|%.2f|%.2f|%.2f|%s" % [
				m.height_at(x, z), m.slope_at(x, z), m.biome_at(x, z), m.path_at(x, z), m.wet_at(x, z), m.water_y_at(x, z), str(m.is_underwater(x, z))
			]
			out.append("q %d,%d = %s = -" % [ix, iz, q])
	for name in PLACES:
		out.append("%s = %s = -" % [name, str(_place(name))])
	out.append("consts = %d|%s|%s|%s = -" % [WorldMap.GRID, str(WorldMap.CELL), str(WorldMap.WATER_LEVEL), str(WorldMap.Biome.PATH)])
	return out


func _place(name: String) -> Vector2:
	match name:
		"P_VILLAGE": return WorldMap.P_VILLAGE
		"P_SHRINE": return WorldMap.P_SHRINE
		"P_RUINS": return WorldMap.P_RUINS
		"P_WATERFALL": return WorldMap.P_WATERFALL
		"P_FORD": return WorldMap.P_FORD
		"P_FOREST_CAMP": return WorldMap.P_FOREST_CAMP
		"P_HIDDEN_GROVE": return WorldMap.P_HIDDEN_GROVE
		"P_BADLANDS": return WorldMap.P_BADLANDS
		"P_FIELDS": return WorldMap.P_FIELDS
	return WorldMap.P_LOOKOUT


func _compare(a: String, b: String, args: PackedStringArray) -> String:
	var pa := a.split(" = ")
	var pb := b.split(" = ")
	if pa[0] != pb[0]:
		return "line order changed: '%s' vs '%s'" % [pa[0], pb[0]]
	if pa[0] == "biome_hist":
		var ca := pa[1].split(",")
		var cb := pb[1].split(",")
		for i in range(ca.size()):
			var tol := maxf(5.0, 0.002 * float(WorldMap.GRID * WorldMap.GRID))
			if absf(float(ca[i]) - float(cb[i])) > tol:
				return "biome_hist bin %d: golden %s, now %s" % [i, ca[i], cb[i]]
		return ""
	if pa[1] != pb[1]:
		return "%s: golden '%s', now '%s'" % [pa[0], pa[1], pb[1]]
	if args.has("--exact") and pa[2] != pb[2]:
		return "%s: exact bytes differ (%s vs %s)" % [pa[0], pa[2], pb[2]]
	return ""


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var m := WorldMap.new()
	m._bake()
	var lines := _lines(m)
	if args.has("--update"):
		var f := FileAccess.open(GOLDEN, FileAccess.WRITE)
		f.store_string("\n".join(lines) + "\n")
		f.close()
		print("wrote %d lines to %s" % [lines.size(), GOLDEN])
		quit(0)
		return
	var want: Array = FileAccess.get_file_as_string(GOLDEN).strip_edges().split("\n")
	var fails: Array[String] = []
	if want.size() != lines.size():
		fails.append("golden has %d lines, the code produced %d" % [want.size(), lines.size()])
	for i in range(mini(want.size(), lines.size())):
		var why := _compare(want[i], lines[i], args)
		if why != "":
			fails.append(why)
	print("%d figures compared%s" % [lines.size(), " (exact)" if args.has("--exact") else ""])
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	quit(0 if fails.is_empty() else 1)
