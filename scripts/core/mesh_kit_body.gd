class_name MeshKitBody
extends MeshKitHair
## Part 4 of 5 of MeshKit (see mesh_kit.gd): hands, feet and anatomical limbs.

# ---------------------------------------------------------------------------
#  HANDS AND FEET
# ---------------------------------------------------------------------------
## Grip poses. The hand does not articulate per finger — it is generated closed to the
## degree the thing it is holding needs, which is all a bow, a staff or a water pot ask
## for, and costs nothing at runtime.
enum Grip { OPEN, RELAXED, CLOSED }

const GRIP_CURL: Array = [
	[0.06, 0.10, 0.08],  # OPEN
	[0.42, 0.58, 0.46],  # RELAXED — the hand a walking person actually has
	[0.86, 0.96, 0.56],  # CLOSED — round a shaft. Past about 2.4 rad total the
	# fingertips come back up out of the palm and the fist reads as an open hand again.
]


## A hand, built at the wrist and hanging down -Y. `sx` is +1 for the limb on +X; the
## palm faces the body, so the whole hand mirrors. ~300 triangles, or a mitten at LOD 1.
static func hand(l: float, build: float, grip: int, sx: float, lod: int = 0) -> ArrayMesh:
	return _memo("hand|%.4f|%.3f|%d|%.0f|%d" % [l, build, grip, sx, lod], func(): return _hand_gen(l, build, grip, sx, lod))


static func _digit_rows(base: Vector3, dir0: Vector3, segs: Array, curls: Array, rad0: float, rad1: float, sx: float, seg: int) -> Array:
	var path := PackedVector3Array()
	var radii := PackedFloat32Array()
	var pos := base
	var dir := dir0.normalized()
	var axis := Vector3(0, 0, -sx)
	var total := 0.0
	for sl in segs:
		total += float(sl)
	var walked := 0.0
	path.append(pos)
	radii.append(rad0)
	for k in range(segs.size()):
		dir = dir.rotated(axis, float(curls[k])).normalized()
		var half := float(segs[k]) * 0.5
		for _h in range(2):
			pos += dir * half
			walked += half
			path.append(pos)
			radii.append(lerpf(rad0, rad1, walked / total))
	radii[radii.size() - 1] = rad1 * 0.45
	return sweep_rows(path, radii, seg, 0.86, Vector3(sx, 0.0, 0.0))


static func _hand_gen(l: float, build: float, grip: int, sx: float, lod: int) -> ArrayMesh:
	var b: float = 0.85 + 0.15 * build
	var seg: int = 5 if lod == 0 else 4
	var curls: Array = GRIP_CURL[clampi(grip, 0, 2)]
	var grids: Array = []

	# --- palm: an ellipse swept down, thickened on the thumb side (the thenar pad)
	# and hollowed across the middle, so it CUPS.
	var stations: Array = [
		[0.00, 0.080, 0.148, 0.00],
		[0.16, 0.094, 0.190, 0.02],
		[0.36, 0.098, 0.218, 0.03],
		[0.50, 0.090, 0.226, 0.01],
		[0.60, 0.068, 0.205, -0.02],
	]
	var cols: int = 10 if lod == 0 else 7
	var rows: Array = []
	for st in stations:
		var t: float = st[0]
		var rx: float = st[1] * l * b
		var rz: float = st[2] * l * b
		var ring_pts := PackedVector3Array()
		for i in range(cols):
			var a: float = TAU * float(i) / float(cols)
			var cx: float = cos(a)
			var cz: float = sin(a)
			# Cup: the palm side (-X for sx=+1) is pulled in across the middle.
			var cup: float = clampf(-cx * sx, 0.0, 1.0) * (1.0 - cz * cz) * 0.22 * smoothstep(0.0, 0.4, t)
			var thenar: float = clampf(-cz, 0.0, 1.0) * clampf(1.0 - absf(t - 0.22) / 0.34, 0.0, 1.0) * 0.30
			(
				ring_pts
				. append(
					Vector3(
						cx * rx * (1.0 - cup + thenar * 0.5) * sx,
						-t * l,
						cz * rz * (1.0 + float(st[3])),
					)
				)
			)
		rows.append(ring_pts)
	grids.append({"rows": rows, "wrap": true})

	# --- four fingers off the knuckle arc
	var fz: Array = [-0.132, -0.045, 0.045, 0.129]
	var fy: Array = [0.560, 0.590, 0.568, 0.510]
	var flen: Array = [0.430, 0.470, 0.440, 0.345]
	var splay: Array = [-0.16, -0.05, 0.05, 0.18]
	for i in range(4):
		var base := Vector3(0.0, -float(fy[i]) * l, float(fz[i]) * l * b)
		var dir0 := Vector3(sx * 0.06, -1.0, float(splay[i])).normalized()
		var fl: float = float(flen[i]) * l
		grids.append({"rows": _digit_rows(base, dir0, [fl * 0.44, fl * 0.32, fl * 0.24], curls, 0.052 * l * b, 0.038 * l * b, sx, seg)})

	# --- the thumb, set opposed: it comes off the radial side and swings across the
	# palm as the grip closes, which is the whole reason a hand reads as holding
	# something rather than resting against it.
	var op: float = [0.10, 0.45, 0.80][clampi(grip, 0, 2)]
	var tb := Vector3(sx * 0.055 * l, -0.185 * l, -0.150 * l * b)
	var tdir := Vector3(-sx * (0.34 + op * 0.30), -0.86, -0.42 + op * 0.30).normalized()
	var tl: float = 0.320 * l
	grids.append(
		{"rows": _digit_rows(tb, tdir, [tl * 0.52, tl * 0.48], [0.30 + op * 0.55, 0.25 + op * 0.75], 0.066 * l * b, 0.048 * l * b, sx, seg)}
	)
	return surface(grids)


## LOD 1: a mitten. Past about twelve metres a knuckle is a third of a pixel, and the
## silhouette — a mass with a thumb off it — is the only part that still reads.
static func hand_lod(l: float, build: float, grip: int, sx: float) -> ArrayMesh:
	return _memo("handlo|%.4f|%.3f|%d|%.0f" % [l, build, grip, sx], func(): return _hand_lod_gen(l, build, grip, sx))


static func _hand_lod_gen(l: float, build: float, grip: int, sx: float) -> ArrayMesh:
	var b: float = 0.85 + 0.15 * build
	var curl: float = [0.10, 0.55, 1.10][clampi(grip, 0, 2)]
	var grids: Array = []
	var rows: Array = []
	for st in [[0.00, 0.082, 0.150], [0.30, 0.102, 0.225], [0.62, 0.090, 0.230], [0.95, 0.062, 0.180]]:
		var ring_pts := PackedVector3Array()
		for i in range(7):
			var a: float = TAU * float(i) / 7.0
			(
				ring_pts
				. append(
					Vector3(
						cos(a) * float(st[1]) * l * b * sx,
						-float(st[0]) * l - sin(clampf(float(st[0]) - 0.5, 0.0, 1.0)) * curl * l * 0.2,
						sin(a) * float(st[2]) * l * b,
					)
				)
			)
		rows.append(ring_pts)
	grids.append({"rows": rows, "wrap": true})
	var tb := Vector3(sx * 0.055 * l, -0.185 * l, -0.150 * l * b)
	var tdir := Vector3(-sx * 0.5, -0.82, -0.28).normalized()
	grids.append({"rows": _digit_rows(tb, tdir, [0.19 * l, 0.17 * l], [0.35, 0.45], 0.062 * l * b, 0.040 * l * b, sx, 4)})
	return surface(grids)


## A bare foot: heel, arch, ball and five toes. The ankle joint is at the origin and
## the sole is flat at -0.235 of the foot's length below it, which is where the leg IK
## puts the ground.
static func foot(fl: float, build: float, sx: float, lod: int = 0) -> ArrayMesh:
	return _memo("foot|%.4f|%.3f|%.0f|%d" % [fl, build, sx, lod], func(): return _foot_gen(fl, build, sx, lod))


static func _foot_gen(fl: float, build: float, sx: float, lod: int) -> ArrayMesh:
	var b: float = 0.88 + 0.12 * build
	var ah: float = 0.235 * fl
	var cols: int = 11 if lod == 0 else 7
	# t 0 at the back of the heel, 1 at the ball of the foot.
	# Half-widths and heights as fractions of the foot's LENGTH. A foot is 0.39 of its
	# own length across the ball and 0.32 tall at the instep; the first pass used these
	# as full widths and produced a pair of paddles.
	var stations: Array = [
		[0.00, 0.140, 0.500, 0.300],
		[0.12, 0.161, 0.230, 0.332],
		[0.30, 0.166, 0.055, 0.340],
		[0.52, 0.156, 0.000, 0.302],
		[0.72, 0.172, 0.000, 0.252],
		[0.88, 0.193, 0.000, 0.216],
		[1.00, 0.195, 0.000, 0.190],
	]
	var rows: Array = []
	for st in stations:
		var t: float = st[0]
		var hw: float = float(st[1]) * fl * b
		var lift: float = float(st[2]) * fl
		var ht: float = float(st[3]) * fl
		var zz: float = lerpf(0.255, -0.500, t) * fl
		var ring_pts := PackedVector3Array()
		for i in range(cols):
			var a: float = TAU * float(i) / float(cols)
			var cx: float = cos(a)
			var cy: float = sin(a)
			var xx: float = signf(cx) * pow(absf(cx), 0.62) * hw
			# The arch is on the MEDIAL side only; a foot lifted evenly is a clog.
			var med: float = clampf(-xx * sx / maxf(hw, 1e-5), 0.0, 1.0)
			var sole: float = -ah + lift * med
			var yy: float = 0.0
			if cy >= 0.0:
				yy = sole + (ht + ah) * pow(cy, 0.75)
			else:
				yy = sole + (ah * 0.12) * pow(-cy, 2.4)
			ring_pts.append(Vector3(xx * sx, yy, zz))
		rows.append(ring_pts)
	var grids: Array = [{"rows": rows, "wrap": true}]

	# --- toes
	var tx: Array = [-0.128, -0.048, 0.021, 0.082, 0.137]
	var tlen: Array = [0.165, 0.155, 0.140, 0.116, 0.086]
	var trad: Array = [0.053, 0.045, 0.041, 0.036, 0.030]
	var tseg: int = 5 if lod == 0 else 4
	for i in range(5):
		var x0: float = float(tx[i]) * fl * b * sx
		var path := PackedVector3Array()
		var radii := PackedFloat32Array()
		var n: int = 4
		for k in range(n):
			var f: float = float(k) / float(n - 1)
			var ln: float = float(tlen[i]) * fl
			(
				path
				. append(
					Vector3(
						x0 + f * 0.016 * fl * signf(x0),
						-ah + float(trad[i]) * fl * (0.92 - 0.28 * f * f),
						-0.470 * fl - f * ln,
					)
				)
			)
			radii.append(float(trad[i]) * fl * (1.0 - 0.42 * f * f))
		radii[n - 1] *= 0.80
		grids.append({"rows": sweep_rows(path, radii, tseg, 0.90, Vector3.UP)})
	return surface(grids)


## A limb segment with a muscle in it. Stations are [t, radius_x, radius_z, dx, dz]:
## the two offsets are what let a bicep sit forward of the bone and a calf sit behind
## it, which a lathe of one radius cannot express and which is why the first pass read
## as plumbing.
static func limb_anat(length: float, stations: Array, segments: int = 10) -> ArrayMesh:
	return _memo("lan|%.4f|%s|%d" % [length, str(stations), segments], func(): return _limb_anat_gen(length, stations, segments))


static func _limb_anat_gen(length: float, stations: Array, segments: int) -> ArrayMesh:
	var rows: Array = []
	for st in stations:
		var t: float = st[0]
		var rx: float = maxf(float(st[1]), 0.002)
		var rz: float = maxf(float(st[2]), 0.002)
		var dx: float = float(st[3]) if st.size() > 3 else 0.0
		var dz: float = float(st[4]) if st.size() > 4 else 0.0
		var ring_pts := PackedVector3Array()
		for i in range(segments):
			var a: float = TAU * float(i) / float(segments)
			ring_pts.append(Vector3(cos(a) * rx + dx, t * length, sin(a) * rz + dz))
		rows.append(ring_pts)
	return surface([{"rows": rows, "wrap": true}])
