extends SceneTree
## Characterisation test for MeshKit: every public builder is called with fixed arguments
## and its geometry compared with tests/golden/mesh_kit.txt, so the file can be split or
## refactored without changing a single vertex.
##
## Each line of the golden file: name, vertex count, index count, bounding box and mean
## vertex position (rounded to 0.01), and a hash of the exact vertices.
##   default   compares counts, box and mean (stable across platforms; this is what CI runs)
##   --exact   also compares the hash of the exact vertices (same machine and engine only)
##   --update  rewrites the golden file from the current code
## Run:  Godot --headless --path . --script tests/mesh_kit_golden_test.gd -- --exact

const GOLDEN := "res://tests/golden/mesh_kit.txt"


func _cases() -> Array:
	var prof: Array = [[0.0, 0.05], [0.5, 0.09], [1.0, 0.03]]
	var prof3: Array = [[0.0, 0.05, 0.04], [0.5, 0.09, 0.07], [1.0, 0.03, 0.03]]
	var stations_anat: Array = [[0.0, 0.05, 0.04, 0.0, 0.0], [0.5, 0.07, 0.06, 0.01, -0.01], [1.0, 0.04, 0.04]]
	var path := PackedVector3Array([Vector3(0, 0, 0), Vector3(0.1, 0.2, 0.0), Vector3(0.15, 0.35, 0.1), Vector3(0.1, 0.5, 0.2)])
	var radii := PackedFloat32Array([0.03, 0.025, 0.02, 0.01])
	var cases: Array = [
		["loft", func(): return MeshKit.loft(_two_rings(), PackedFloat32Array([0.0, 1.0]))],
		["profile_loft", func(): return MeshKit.profile_loft(1.2, prof3, 12)],
		["tube", func(): return MeshKit.tube(0.8, prof, 10, 0.8, Vector3(0.1, 0, 0.05))],
		["limb", func(): return MeshKit.limb(0.5, 0.06, 0.04)],
		["sphere", func(): return MeshKit.sphere(0.3, 12, 8, 0.9)],
		["ovoid", func(): return MeshKit.ovoid(0.3, 0.7, 0.5, 12, 10)],
		["box", func(): return MeshKit.box(Vector3(0.4, 0.6, 0.2), 2.0)],
		["quad", func(): return MeshKit.quad(0.5, 0.8, true)],
		["boulder", func(): return MeshKit.boulder(1.0, 7)],
		["surface", func(): return MeshKit.surface([{"rows": MeshKit.sweep_rows(path, radii, 6, 0.8)}])],
		["sweep", func(): return MeshKit.sweep(path, radii, 6, 0.8)],
		["bake", func(): return _bake()],
		["limb_anat", func(): return MeshKit.limb_anat(0.5, stations_anat, 9)],
		["skirt", func(): return MeshKit.skirt(0.9, [[0.0, 0.05], [0.4, 0.08], [1.0, 0.12]], 7, 0.3, 0.03, 4, 18)],
		["cloth_strip", func(): return MeshKit.cloth_strip(path, 0.15, 0.01, 0.3, 5, 8)],
		["blade", func(): return MeshKit.blade(0.9, [[0.0, 0.02, 0.004], [0.5, 0.025, 0.005], [1.0, 0.0, 0.001]], 0.3, 5)],
		["wrap", func(): return MeshKit.wrap(0.128, 0.0246, 11.0, 0.0028, 4)],
		["fletch", func(): return MeshKit.fletch(0.105, 0.019, 0.0016, 0.30)],
		["spherical_cap", func(): return MeshKit.spherical_cap(0.1, 0.6, 12, 3)],
		["face_cavities", func(): return MeshKit.face_cavities(1.0, 1)],
	]
	for preset in range(6):
		for lod in range(2):
			cases.append(["head_shell p%d lod%d" % [preset, lod], func(): return MeshKit.head_shell(1.0, preset, lod)])
	for lod in range(2):
		cases.append(["eyelid up lod%d" % lod, func(): return MeshKit.eyelid(0.108, true, lod)])
		cases.append(["eyelid down lod%d" % lod, func(): return MeshKit.eyelid(0.108, false, lod)])
		cases.append(["brows lod%d" % lod, func(): return MeshKit.brows(1.0, 2, lod)])
		cases.append(["beard lod%d" % lod, func(): return MeshKit.beard(1.0, 4, 0.6, lod)])
	for style in range(6):
		for lod in range(2):
			cases.append(["hair s%d lod%d" % [style, lod], func(): return MeshKit.hair(1.0, style, style, style + 3, lod)])
	for grip in range(3):
		cases.append(["hand g%d" % grip, func(): return MeshKit.hand(0.18, 1.0, grip, 1.0, 0)])
		cases.append(["hand g%d left lod1" % grip, func(): return MeshKit.hand(0.18, 0.9, grip, -1.0, 1)])
		cases.append(["hand_lod g%d" % grip, func(): return MeshKit.hand_lod(0.18, 1.0, grip, 1.0)])
	for lod in range(2):
		cases.append(["foot lod%d" % lod, func(): return MeshKit.foot(0.26, 1.0, 1.0, lod)])
	return cases


func _two_rings() -> Array:
	return [MeshKit.ring(Vector3.ZERO, 1.0, 8), MeshKit.ring(Vector3(0, 1, 0), 0.5, 8)]


func _bake() -> ArrayMesh:
	var parts: Array = [
		{"mesh": MeshKit.box(Vector3(0.2, 0.2, 0.2)), "xform": Transform3D(Basis.IDENTITY, Vector3(0, 0.1, 0))},
		{"mesh": MeshKit.sphere(0.1, 8, 6), "xform": Transform3D(Basis(Vector3.UP, 0.5), Vector3(0.3, 0, 0))},
	]
	return MeshKit.bake(parts)


## Plain numbers about the functions that do not return a mesh.
func _scalars() -> Array:
	var rows: Array = []
	for i in range(6):
		rows.append(["face_preset %d" % i, str(MeshKit.face_preset(i))])
	var p := MeshKit.face_preset(0)
	for t in [0.1, 0.5, 0.9]:
		for a in [-1.2, -PI / 2.0, 0.4]:
			rows.append(["head_point %.1f %.2f" % [t, a], str(_q(MeshKit.head_point(t, a, 1.0, p)))])
	rows.append(["head_ts 0", str(MeshKit.head_ts(0).size())])
	rows.append(["head_ts 1", str(MeshKit.head_ts(1).size())])
	rows.append(["head_azimuths 12", str(MeshKit.head_azimuths(12).size())])
	for s in range(6):
		rows.append(["hairline_t %d" % s, "%.3f" % MeshKit.hairline_t(0.7, s)])
		rows.append(["hair_clearance %d" % s, "%.3f" % MeshKit.hair_clearance(1.0, 1, s, 3)])
	rows.append(["eye constants", "%.3f %.3f %.3f %.3f" % [MeshKit.EYE_X, MeshKit.EYE_Y, MeshKit.EYE_Z, MeshKit.EYE_R]])
	rows.append(["enums", "%d %d %d %d" % [MeshKit.Hair.TOP_KNOT, MeshKit.Grip.CLOSED, MeshKit.Hair.JATA, MeshKit.Grip.OPEN]])
	rows.append(["face presets", str(MeshKit.FACE_PRESETS.size())])
	return rows


func _q(v: Vector3) -> Vector3:
	return Vector3(snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01))


## "name|verts|indices|min|max|mean" (stable) and the exact hash, for one mesh.
func _describe(m: ArrayMesh) -> Array:
	if m == null or m.get_surface_count() == 0:
		return ["empty", ""]
	var verts := 0
	var idx := 0
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	var sum := Vector3.ZERO
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for s in range(m.get_surface_count()):
		var arrays := m.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		verts += v.size()
		var ia: Variant = arrays[Mesh.ARRAY_INDEX]
		idx += (ia as PackedInt32Array).size() if ia != null else 0
		for p in v:
			lo = lo.min(p)
			hi = hi.max(p)
			sum += p
		ctx.update(v.to_byte_array())
		if ia != null:
			ctx.update((ia as PackedInt32Array).to_byte_array())
	var mean := sum / float(maxi(verts, 1))
	var stable := "%d|%d|%s|%s|%s" % [verts, idx, _q(lo), _q(hi), _q(mean)]
	return [stable, ctx.finish().hex_encode().substr(0, 16)]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var lines: Array[String] = []
	for c in _cases():
		var d := _describe((c[1] as Callable).call())
		lines.append("%s = %s = %s" % [c[0], d[0], d[1]])
	for r in _scalars():
		lines.append("%s = %s = -" % [r[0], r[1]])
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
		var a: PackedStringArray = (want[i] as String).split(" = ")
		var b: PackedStringArray = (lines[i] as String).split(" = ")
		if a[0] != b[0] or a[1] != b[1]:
			fails.append("%s: golden '%s', now '%s'" % [b[0], a[1], b[1]])
		elif args.has("--exact") and a.size() > 2 and b.size() > 2 and a[2] != b[2]:
			fails.append("%s: exact vertices differ (%s vs %s)" % [b[0], a[2], b[2]])
	print("%d cases compared%s" % [lines.size(), " (exact)" if args.has("--exact") else ""])
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	quit(0 if fails.is_empty() else 1)
