class_name MeshKit
extends MeshKitBody
## Procedural mesh primitives, and the one name callers use for all of them.
##
## The 1,500 lines that used to live here are split by responsibility into a chain of
## classes, each extending the one before, so `MeshKit.hand(...)`, `MeshKit.Grip` and
## `MeshKit.EYE_R` all keep working:
##
##   MeshKitBase  memo cache, loft, tube, sphere, box, boulder, bake, surface, sweep
##   MeshKitHead  skull, face presets, eyelids, eye cavities, spherical caps
##   MeshKitHair  hair styles, brows, beards
##   MeshKitBody  hands, feet, anatomical limbs
##   MeshKit      cloth (skirt, strip) and blades, bindings, fletching
##
## WINDING and MEMOISATION are documented in MeshKitBase. tests/mesh_kit_golden_test.gd
## pins every builder's output.

# ---------------------------------------------------------------------------
#  CLOTH
# ---------------------------------------------------------------------------
## A wrapped lower garment. Rows are emitted HEM FIRST so the winding matches every
## other primitive here; the pleats deepen toward the hem, and the hem itself is not a
## circle — a length of cotton wound round a waist never hangs level.
static func skirt(
	length: float, stations: Array, pleats: int, pleat_depth: float, hem_wave: float, seed_i: int, segments: int = 22
) -> ArrayMesh:
	var key := "skirt|%.4f|%s|%d|%.3f|%.3f|%d|%d" % [length, str(stations), pleats, pleat_depth, hem_wave, seed_i, segments]
	return _memo(key, func(): return _skirt_gen(length, stations, pleats, pleat_depth, hem_wave, seed_i, segments))


static func _skirt_gen(
	length: float, stations: Array, pleats: int, pleat_depth: float, hem_wave: float, seed_i: int, segments: int
) -> ArrayMesh:
	var ph: float = float(seed_i) * 0.919
	var rows: Array = []
	# A short return lip inside the hem, so the garment has an edge rather than
	# showing the viewer the inside of a cone.
	var seq: Array = [[1.0, 0.90, -0.030], [1.0, 1.0, 0.0]]
	for st in stations:
		seq.append([float(st[0]), 1.0, 0.0])
	seq.reverse()
	for e in seq:
		var t: float = float(e[0])
		var shrink: float = float(e[1])
		var rise: float = float(e[2])
		var rad: float = _skirt_radius(stations, t)
		var ring_pts := PackedVector3Array()
		for i in range(segments):
			var a: float = TAU * float(i) / float(segments)
			var fold: float = 1.0 + pleat_depth * t * t * cos(float(pleats) * a + ph)
			var wave: float = hem_wave * t * t * t * sin(3.0 * a + ph * 1.7)
			ring_pts.append(
				Vector3(cos(a) * rad * fold * shrink, -t * length + wave * length + rise * length, sin(a) * rad * fold * shrink)
			)
		rows.append(ring_pts)
	return surface([{"rows": rows, "wrap": true}])


static func _skirt_radius(stations: Array, t: float) -> float:
	var prev: Array = stations[0]
	for st in stations:
		if float(st[0]) >= t:
			var t0: float = float(prev[0])
			var t1: float = float(st[0])
			var f: float = 0.0 if t1 <= t0 else (t - t0) / (t1 - t0)
			return lerpf(float(prev[1]), float(st[1]), f)
		prev = st
	return float(stations[stations.size() - 1][1])


## A length of cloth with thickness and folds in it, swept along a path — the uttariya
## over the shoulder, a sari's pallu, a waist sash. Closed in cross-section, so it is
## cloth and not a card that vanishes edge-on.
static func cloth_strip(path: PackedVector3Array, width: float, thick: float, folds: float, seed_i: int, seg: int = 10) -> ArrayMesh:
	var key := "cstrip|%s|%.4f|%.4f|%.2f|%d|%d" % [str(path), width, thick, folds, seed_i, seg]
	return _memo(key, func(): return _cloth_strip_gen(path, width, thick, folds, seed_i, seg))


static func _cloth_strip_gen(path: PackedVector3Array, width: float, thick: float, folds: float, seed_i: int, seg: int) -> ArrayMesh:
	var n: int = path.size()
	var radii := PackedFloat32Array()
	for i in range(n):
		radii.append(width * 0.5)
	var rows: Array = sweep_rows(path, radii, seg, thick / maxf(width, 1e-5), Vector3.RIGHT)
	# Ripple the flat faces so the cloth has folds running down it.
	var out: Array = []
	for r in range(rows.size()):
		var src: PackedVector3Array = rows[r]
		var dst := PackedVector3Array()
		var f: float = float(r) / float(maxi(rows.size() - 1, 1))
		for i in range(src.size()):
			var a: float = TAU * float(i) / float(src.size())
			var amp: float = folds * width * 0.5 * sin(float(seed_i) * 1.3 + f * 9.0 + a) * absf(sin(a))
			var c: Vector3 = _row_centre(src)
			dst.append(src[i] + (src[i] - c).normalized() * amp * clampf(f * 2.4, 0.0, 1.0))
		out.append(dst)
	return surface([{"rows": out, "wrap": true}])


static func _row_centre(row: PackedVector3Array) -> Vector3:
	var c := Vector3.ZERO
	for v in row:
		c += v
	return c / float(maxi(row.size(), 1))


# ---------------------------------------------------------------------------
#  BLADES AND BINDINGS
# ---------------------------------------------------------------------------
## A blade with a real cross-section: a fuller groove down each face and a bevel that
## runs out to an actual edge. `stations` are [t, half_width, half_thickness]. An
## elliptical loft cannot do this — it gives a rounded bar, which is what the first
## sword was, and no amount of metal shader makes a bar look sharp.
static func blade(length: float, stations: Array, fuller: float = 0.30, face_steps: int = 6) -> ArrayMesh:
	return _memo(
		"blade|%.4f|%s|%.2f|%d" % [length, str(stations), fuller, face_steps],
		func(): return _blade_gen(length, stations, fuller, face_steps)
	)


static func _blade_gen(length: float, stations: Array, fuller: float, face_steps: int) -> ArrayMesh:
	var rows: Array = []
	for st in stations:
		var t: float = st[0]
		var hw: float = maxf(float(st[1]), 0.0004)
		var ht: float = maxf(float(st[2]), 0.0002)
		var ring_pts := PackedVector3Array()
		for i in range(face_steps + 1):
			var sv: float = lerpf(-1.0, 1.0, float(i) / float(face_steps))
			ring_pts.append(Vector3(sv * hw, t * length, ht * _blade_prof(sv, fuller)))
		for i in range(face_steps - 1, 0, -1):
			var sv: float = lerpf(-1.0, 1.0, float(i) / float(face_steps))
			ring_pts.append(Vector3(sv * hw, t * length, -ht * _blade_prof(sv, fuller)))
		rows.append(ring_pts)
	return surface([{"rows": rows, "wrap": true}])


static func _blade_prof(sv: float, fuller: float) -> float:
	var a: float = absf(sv)
	# Flat through the middle, then a long bevel that reaches zero at the edge.
	var body: float = 1.0 - pow(a, 5.0)
	# The fuller: a groove down the centre of the face.
	var groove: float = fuller * exp(-(sv * sv) / 0.075)
	return maxf(body - groove, 0.0)


## A leather binding: a cord wound round a shaft, so a grip is something a hand closes
## on rather than a smooth dowel.
static func wrap(length: float, radius: float, turns: float, cord: float, seg: int = 5) -> ArrayMesh:
	return _memo(
		"wrap|%.4f|%.4f|%.2f|%.4f|%d" % [length, radius, turns, cord, seg], func(): return _wrap_gen(length, radius, turns, cord, seg)
	)


static func _wrap_gen(length: float, radius: float, turns: float, cord: float, seg: int) -> ArrayMesh:
	var n: int = int(maxf(turns * 4.5, 8.0))
	var path := PackedVector3Array()
	var radii := PackedFloat32Array()
	for i in range(n + 1):
		var f: float = float(i) / float(n)
		var a: float = f * TAU * turns
		path.append(Vector3(cos(a) * radius, f * length, sin(a) * radius))
		radii.append(cord)
	return sweep(path, radii, seg, 0.75, Vector3.UP)


## An arrow's vane: a real feather with a curved leading edge, a spine and thickness,
## rather than a flat card that disappears when the arrow rolls.
static func fletch(length: float, height: float, thick: float, curl: float = 0.35) -> ArrayMesh:
	return _memo("fletch|%.4f|%.4f|%.4f|%.2f" % [length, height, thick, curl], func(): return _fletch_gen(length, height, thick, curl))


static func _fletch_gen(length: float, height: float, thick: float, curl: float) -> ArrayMesh:
	var n := 9
	var rows: Array = []
	for i in range(n):
		var f: float = float(i) / float(n - 1)
		# Leading edge sweeps up, trailing edge cut back: a fletched shape, not a box.
		var h: float = height * sin(clampf(f * 1.06, 0.0, 1.0) * PI * 0.92) * (0.35 + 0.65 * f)
		var tw: float = thick * (1.0 - 0.55 * f)
		var bend: float = curl * height * f * f
		var ring_pts := PackedVector3Array()
		for k in range(6):
			var a: float = TAU * float(k) / 6.0
			ring_pts.append(Vector3(sin(a) * tw + bend * absf(sin(a)), (0.5 + 0.5 * cos(a)) * h, f * length))
		rows.append(ring_pts)
	return surface([{"rows": rows, "wrap": true}])
