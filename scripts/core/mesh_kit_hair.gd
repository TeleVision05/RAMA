class_name MeshKitHair
extends MeshKitHead
## Part 3 of 5 of MeshKit (see mesh_kit.gd): hair, brows and beards.

# ---------------------------------------------------------------------------
#  HAIR
# ---------------------------------------------------------------------------
## Hair is built ON the sculpted skull rather than as a separate ovoid guessed to be
## the right size. A cap whose lower edge follows a real HAIRLINE — high across the
## forehead, dipping at the temples, low at the nape — plus locks with enough
## protrusion to break the silhouette, plus whatever the style ties it into.
##
## The offsets are all "this far proud of the skull at this point", which is the only
## formulation that cannot repeat the bug that left twelve villagers bald: a hair cap
## sized by hand, and therefore entirely inside the head.
enum Hair { JATA, BUN, BRAID, LOOSE, SHORT, TOP_KNOT }


## Where the hairline sits, as a `t` on the skull lathe, for azimuth `a`.
static func hairline_t(a: float, style: int) -> float:
	var fw: float = clampf(-sin(a), 0.0, 1.0)
	var bw: float = clampf(sin(a), 0.0, 1.0)
	var t: float = 0.575 + 0.105 * fw * fw - 0.200 * bw
	# A widow's peak, and the two temple recessions either side of it.
	var d: float = absf(wrapf(a + PI * 0.5, -PI, PI))
	# Wide on purpose. At 0.01 the peak was narrower than the gap between two rings and
	# the hairline came out as a zigzag.
	t -= 0.028 * exp(-(d * d) / 0.055)
	t += 0.030 * exp(-((d - 0.62) * (d - 0.62)) / 0.150)
	if style == Hair.SHORT:
		t -= 0.03
	return t


## Smallest distance the hair cap keeps outside the scalp, in metres, recorded as the
## cap is generated. An AABB comparison cannot answer this — the skull's box includes
## the EARS, which stick out further than any hairstyle, so measuring that way reports
## every villager as bald while they are all wearing hair.
static var _hair_clear: Dictionary = {}


static func hair_clearance(r: float, preset: int, style: int, seed_i: int) -> float:
	hair(r, preset, style, seed_i, 0)
	return float(_hair_clear.get("%d|%d|%d" % [preset, style, seed_i], 0.0))


static func hair(r: float, preset: int, style: int, seed_i: int, lod: int = 0) -> ArrayMesh:
	return _memo("hair|%.4f|%d|%d|%d|%d" % [r, preset, style, seed_i, lod], func(): return _hair_gen(r, preset, style, seed_i, lod))


static func _hair_gen(r: float, preset: int, style: int, seed_i: int, lod: int) -> ArrayMesh:
	var p: Dictionary = face_preset(preset)
	var az: int = 30 if lod == 0 else 16
	var nrow: int = 8 if lod == 0 else 5
	var ph: float = float(seed_i) * 1.37
	var thick: float = 0.070 if style != Hair.SHORT else 0.032
	var worst := 1.0e9
	var rows: Array = []
	for j in range(nrow + 1):
		var f: float = float(j) / float(nrow)
		var ring_pts := PackedVector3Array()
		for i in range(az):
			var a: float = TAU * float(i) / float(az) + PI * 0.5
			var t0: float = hairline_t(a, style)
			var t: float = lerpf(t0, 1.0, f)
			var q := head_point(t, a, r, p)
			var nrm: Vector3 = q.normalized()
			# The edge is thin so the hairline is a line, not a ledge; the mass builds
			# toward the crown and toward the back of the head.
			var up: float = smoothstep(0.0, 0.35, f)
			var bulk: float = thick * (0.20 + 0.80 * up) * (1.0 + 0.30 * clampf(sin(a), 0.0, 1.0))
			bulk += 0.016 * sin(a * 5.0 + ph) * up
			if style == Hair.JATA or style == Hair.TOP_KNOT:
				bulk *= lerpf(1.0, 0.62, up)  # swept up and back, tight to the skull
			var off: float = bulk * 0.9 + 0.004
			worst = minf(worst, off)
			ring_pts.append(q + nrm * (off * r))
		rows.append(ring_pts)
	_hair_clear["%d|%d|%d" % [preset, style, seed_i]] = worst * r
	var grids: Array = [{"rows": rows, "wrap": true}]
	grids.append_array(_hair_locks(r, p, style, seed_i, lod))
	return surface(grids)


static func _hair_locks(r: float, p: Dictionary, style: int, seed_i: int, lod: int) -> Array:
	var grids: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i * 7919 + style
	var seg: int = 5 if lod == 0 else 4
	var steps: int = 7 if lod == 0 else 4
	match style:
		Hair.JATA, Hair.TOP_KNOT:
			# The jata: hair gathered and wound into a coil above the crown. Wound, so
			# it reads as rope rather than as a bun sitting on the head.
			var top := head_point(0.985, -PI * 0.5, r, p)
			var turns: float = 2.6 if style == Hair.JATA else 1.8
			var hgt: float = (0.30 if style == Hair.JATA else 0.22) * r
			var rad: float = (0.225 if style == Hair.JATA else 0.20) * r
			var path := PackedVector3Array()
			var radii := PackedFloat32Array()
			var n: int = 22 if lod == 0 else 12
			for i in range(n):
				var f: float = float(i) / float(n - 1)
				var a: float = f * TAU * turns
				var rr: float = rad * (1.0 - 0.45 * f)
				path.append(Vector3(cos(a) * rr, top.y + f * hgt - 0.06 * r, top.z + sin(a) * rr * 0.9 - 0.12 * r))
				radii.append(r * lerpf(0.062, 0.040, f))
			grids.append({"rows": sweep_rows(path, radii, seg, 1.0, Vector3.UP)})
		Hair.BUN:
			var back := head_point(0.72, PI * 0.5, r, p)
			var path2 := PackedVector3Array()
			var radii2 := PackedFloat32Array()
			var n2: int = 16 if lod == 0 else 9
			for i in range(n2):
				var f: float = float(i) / float(n2 - 1)
				var a: float = f * TAU * 1.9
				var rr: float = 0.30 * r * sin(clampf(f, 0.03, 0.97) * PI) + 0.06 * r
				path2.append(back + Vector3(cos(a) * rr, sin(a) * rr, (f - 0.5) * 0.18 * r))
				radii2.append(r * 0.075)
			grids.append({"rows": sweep_rows(path2, radii2, seg, 1.0, Vector3.FORWARD)})
		Hair.BRAID:
			var nape := head_point(0.34, PI * 0.5, r, p)
			var path3 := PackedVector3Array()
			var radii3 := PackedFloat32Array()
			var n3: int = 18 if lod == 0 else 10
			for i in range(n3):
				var f: float = float(i) / float(n3 - 1)
				# A braid is a rope with a beat in it; the bulge is what says "plait".
				path3.append(nape + Vector3(sin(f * 9.0) * 0.05 * r, -f * 1.55 * r, 0.10 * r + f * 0.10 * r))
				radii3.append(r * (0.115 - 0.055 * f) * (1.0 + 0.28 * sin(f * 14.0)))
			grids.append({"rows": sweep_rows(path3, radii3, seg, 0.85, Vector3.UP)})
		Hair.LOOSE:
			var m: int = 13 if lod == 0 else 6
			for k in range(m):
				var a: float = lerpf(0.05, PI - 0.05, float(k) / float(m - 1))
				var start := head_point(hairline_t(a, style) + 0.10, a, r, p)
				var path4 := PackedVector3Array()
				var radii4 := PackedFloat32Array()
				var drop: float = (0.85 + rng.randf() * 0.55) * r
				for i in range(steps):
					var f: float = float(i) / float(steps - 1)
					var flare: float = 1.0 + f * 0.30
					(
						path4
						. append(
							Vector3(
								start.x * flare + sin(f * 4.0 + float(k)) * 0.04 * r,
								start.y - f * drop,
								start.z * flare + f * 0.12 * r,
							)
						)
					)
					radii4.append(r * lerpf(0.155, 0.060, f))
				grids.append({"rows": sweep_rows(path4, radii4, seg, 0.70, Vector3.FORWARD)})
		_:
			pass
	return grids


## Eyebrows: two tapered ridges following the brow. Nothing else so cheap does as much
## for a face — an eye with no brow over it reads as a doll's.
static func brows(r: float, preset: int, lod: int = 0) -> ArrayMesh:
	return _memo("brow|%.4f|%d|%d" % [r, preset, lod], func(): return _brows_gen(r, preset, lod))


static func _brows_gen(r: float, preset: int, lod: int) -> ArrayMesh:
	var p: Dictionary = face_preset(preset)
	var grids: Array = []
	var t_b: float = acos(clampf(-0.118 / (0.960 * float(p["fh"])), -1.0, 1.0)) / PI
	var n: int = 7 if lod == 0 else 4
	for sx in [-1.0, 1.0]:
		var path := PackedVector3Array()
		var radii := PackedFloat32Array()
		for i in range(n):
			var f: float = float(i) / float(n - 1)
			var a: float = -PI * 0.5 + sx * lerpf(0.10, 0.60, f)
			var q := head_point(t_b - 0.030 * f * f, a, r, p)
			path.append(q + Vector3(0, 0.004 * r, -0.010 * r))
			radii.append(r * lerpf(0.038, 0.014, f * f))
		# UP hint puts the full radius along Y and the squashed axis along Z: a brow
		# that is 6 mm deep and 2 mm proud. The other way round it is a shelf.
		grids.append({"rows": sweep_rows(path, radii, 5, 0.32, Vector3.UP)})
	return surface(grids)


## A beard, hung off the jaw the skull actually has. Elders get length; everyone else
## gets a close crop. A moustache comes with it, because a beard without one reads as
## a chinstrap.
static func beard(r: float, preset: int, length: float, lod: int = 0) -> ArrayMesh:
	return _memo("beard|%.4f|%d|%.2f|%d" % [r, preset, length, lod], func(): return _beard_gen(r, preset, length, lod))


static func _beard_gen(r: float, preset: int, length: float, lod: int) -> ArrayMesh:
	var p: Dictionary = face_preset(preset)
	var az: int = 17 if lod == 0 else 9
	var nrow: int = 6 if lod == 0 else 4
	var rows: Array = []
	for j in range(nrow + 1):
		var f: float = float(j) / float(nrow)
		var ring_pts := PackedVector3Array()
		for i in range(az):
			# Only the front arc: a beard wraps the jaw, it does not go round the head.
			var u: float = lerpf(-1.0, 1.0, float(i) / float(az - 1))
			var a: float = -PI * 0.5 + u * 1.20
			# Below the lower lip at the front, up to the sideburns at the sides. Started
			# at 0.30 the shell covered the mouth and the elder had a plate for a face.
			var t_edge: float = 0.190 + 0.235 * u * u
			var t: float = lerpf(t_edge, 0.045, f)
			var q := head_point(t, a, r, p)
			var nrm: Vector3 = q.normalized()
			var bulk: float = (0.028 + 0.062 * sin(clampf(f, 0.0, 1.0) * PI)) * r
			ring_pts.append(q + nrm * bulk)
		rows.append(ring_pts)
	var grids: Array = [{"rows": rows, "wrap": false}]
	# The length is LOCKS, not a longer shell. Extending the shell downward built a
	# flat wall hanging off the chin; hair falls in strands and needs a strand's
	# silhouette to read as hair at all.
	if length > 0.05:
		var m: int = 9 if lod == 0 else 5
		for k in range(m):
			var u: float = lerpf(-1.0, 1.0, float(k) / float(m - 1))
			var root := head_point(0.055, -PI * 0.5 + u * 1.05, r, p)
			var drop: float = length * r * (1.55 - 0.55 * u * u) * (0.85 + 0.30 * absf(sin(float(k) * 2.7)))
			var path := PackedVector3Array()
			var radii := PackedFloat32Array()
			var steps: int = 6 if lod == 0 else 4
			for i in range(steps):
				var f2: float = float(i) / float(steps - 1)
				(
					path
					. append(
						(
							root
							+ Vector3(
								-root.x * f2 * 0.28 + sin(f2 * 3.0 + float(k)) * 0.02 * r,
								-f2 * drop,
								f2 * f2 * 0.10 * r,
							)
						)
					)
				)
				radii.append(r * lerpf(0.085, 0.030, f2))
			grids.append({"rows": sweep_rows(path, radii, 5, 0.80, Vector3.FORWARD)})
	# Moustache.
	var t_m: float = acos(clampf(0.585 / (0.960 * float(p["fh"])), -1.0, 1.0)) / PI
	var path := PackedVector3Array()
	var radii := PackedFloat32Array()
	for i in range(9):
		var u: float = lerpf(-1.0, 1.0, float(i) / 8.0)
		var q := head_point(t_m, -PI * 0.5 + u * 0.50, r, p)
		path.append(q + Vector3(0, -u * u * 0.030 * r, -0.006 * r))
		radii.append(r * lerpf(0.040, 0.015, u * u))
	grids.append({"rows": sweep_rows(path, radii, 5, 0.38, Vector3.UP)})
	return surface(grids)
