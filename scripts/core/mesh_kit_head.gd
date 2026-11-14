class_name MeshKitHead
extends MeshKitBase
## Part 2 of 5 of MeshKit (see mesh_kit.gd): the sculpted head, eyelids, eye cavities and caps.

# ---------------------------------------------------------------------------
#  THE HEAD
# ---------------------------------------------------------------------------
## The skull is a displaced ellipsoid, sculpted by ~20 overlapping blobs: brow ridge,
## glabella, eye sockets, cheekbones and the hollow under them, temples, the angle of
## the jaw, a nose with a bridge / dorsum / tip / alae, upper and lower lips with a
## mouth line, a philtrum, nasolabial folds, a chin with a mentolabial groove, and the
## occiput. Ears are swept rims committed into the SAME mesh, so a whole head — bone
## structure and all — is one draw call.
##
## THE FACE POINTS AT -Z. Everything else in this project treats -Z as forward (the
## player sets `facing_yaw = atan2(-x, -z)`, the leg cycle swings the feet along -Z),
## and the old head was built the other way round, which is why two other files each
## carried a routine to turn it back to front.
##
## All the numbers below are in units of `r` (the rig's `head` half-width), so the same
## field builds a child's head and a rakshasa's.
const FACE_PRESETS: Array = [
	# 0 hero: balanced, strong brow and jaw
	{"jaw": 1.00, "chin": 1.05, "cheek": 1.05, "brow": 1.10, "nose": 1.00, "nw": 0.94, "lips": 0.95, "fh": 1.00, "w": 1.00},
	# 1 broad
	{"jaw": 1.10, "chin": 1.12, "cheek": 0.92, "brow": 1.22, "nose": 0.92, "nw": 1.14, "lips": 0.90, "fh": 0.96, "w": 1.06},
	# 2 fine-boned
	{"jaw": 0.86, "chin": 0.84, "cheek": 1.18, "brow": 0.74, "nose": 1.06, "nw": 0.86, "lips": 1.18, "fh": 1.05, "w": 0.93},
	# 3 round
	{"jaw": 0.94, "chin": 0.94, "cheek": 0.78, "brow": 0.88, "nose": 0.94, "nw": 1.02, "lips": 1.06, "fh": 0.96, "w": 1.03},
	# 4 gaunt — the elders
	{"jaw": 1.04, "chin": 1.00, "cheek": 1.30, "brow": 1.06, "nose": 1.14, "nw": 1.04, "lips": 0.84, "fh": 1.05, "w": 0.95},
	# 5 child: short face, soft everything
	{"jaw": 0.84, "chin": 0.80, "cheek": 0.86, "brow": 0.62, "nose": 0.80, "nw": 0.96, "lips": 1.12, "fh": 0.92, "w": 1.07},
]

## Where the eye sits, in units of `r`: half the interpupillary distance, the height of
## the pupil above the head's centre, and how far forward the eyeball's centre is.
## ProcRig needs these to hang the eyeballs and the lids in the sockets this field cuts.
const EYE_X: float = 0.290
const EYE_Y: float = 0.010
const EYE_Z: float = -0.640
const EYE_R: float = 0.108


static func face_preset(i: int) -> Dictionary:
	return FACE_PRESETS[posmod(i, FACE_PRESETS.size())]


## A point on the sculpted skull. `t` 0 (under the chin) .. 1 (crown); `a` is the
## azimuth, -PI/2 dead ahead. Returns metres, head centre at the origin.
##
## The base is NOT an ellipsoid. A lathe of `sin(phi)` tapers to a point at both ends,
## which put a cone where the jaw should be and made the first render read as an alien
## rather than a person. Raising the ring radius to a power below one squares the form
## off, and the exponent is animated up the skull: boxy at the mandible, full at the
## cheekbones, flattened again over the parietals.
static func head_point(t: float, a: float, r: float, p: Dictionary) -> Vector3:
	var hx: float = 0.720 * float(p["w"])
	var hy: float = 0.960 * float(p["fh"])
	var hz: float = 0.900
	var phi: float = t * PI
	var ny: float = -cos(phi)
	var w0: float = maxf(sin(phi), 0.004)
	# Squareness. Below 1 the ring holds its width further up and down the skull, which
	# is what gives a head straight temples and a jaw instead of an egg's curve; back
	# above 1 at the crown so the dome still closes to a rounded pole.
	var box: float = lerpf(0.50, 1.0, smoothstep(-1.00, -0.24, ny)) * lerpf(1.0, 0.82, smoothstep(0.30, 1.0, ny))
	var w: float = pow(w0, box)
	var jaw_t: float = smoothstep(-1.00, -0.46, ny)
	var crown: float = smoothstep(0.35, 1.0, ny)
	var wx: float = lerpf(0.84 * float(p["jaw"]), 1.0, jaw_t) * lerpf(1.0, 0.86, crown)
	var wz: float = lerpf(0.88, 1.0, jaw_t) * lerpf(1.0, 0.90, crown)
	var px: float = cos(a) * w * hx * wx
	var pz: float = sin(a) * w * hz * wz
	var py: float = ny * hy
	var fw: float = clampf(-sin(a), 0.0, 1.0)
	var bw: float = clampf(sin(a), 0.0, 1.0)
	# A face is a plane, not the front of a ball; the occiput bulges; and under the
	# jaw at the back is where the neck goes, so that quarter pulls in hard.
	pz *= lerpf(1.0, 0.90, fw * smoothstep(-0.95, -0.30, ny))
	pz *= lerpf(1.0, 1.06, bw * smoothstep(-0.25, 0.50, ny))
	pz *= lerpf(1.0, 0.52, bw * (1.0 - smoothstep(-0.95, -0.42, ny)))

	var ax: float = absf(px)
	var out := Vector3(px / (hx * hx), py / (hy * hy), pz / (hz * hz)).normalized()
	var dr := 0.0  # along the outward normal
	var dz := 0.0  # straight forward, for everything on the face plane
	var nose: float = float(p["nose"])
	var nw: float = 0.150 * float(p["nw"])
	var lips: float = float(p["lips"])

	# --- bone: brow, cheek, temple, jaw, occiput ---------------------------
	dz -= 0.115 * float(p["brow"]) * _blob(ax - 0.30, py - 0.150, pz + 0.80, 0.34, 0.130, 0.46)
	dz -= 0.055 * float(p["brow"]) * _blob(px, py - 0.115, pz + 0.84, 0.16, 0.120, 0.44)
	dz += 0.105 * _blob(ax - 0.290, py - 0.010, pz + 0.76, 0.250, 0.185, 0.42)
	dr += 0.090 * float(p["cheek"]) * _blob(ax - 0.470, py + 0.150, pz + 0.60, 0.300, 0.260, 0.60)
	dr -= 0.048 * _blob(ax - 0.400, py + 0.430, pz + 0.62, 0.240, 0.240, 0.54)
	dr -= 0.034 * _blob(ax - 0.640, py - 0.250, pz + 0.28, 0.220, 0.330, 0.56)
	dr += 0.070 * float(p["jaw"]) * _blob(ax - 0.520, py + 0.560, pz - 0.16, 0.270, 0.300, 0.64)
	# The jawline itself: a crease under the mandible, so the face has an edge.
	dr -= 0.034 * _blob(ax - 0.340, py + 0.800, pz + 0.16, 0.440, 0.140, 0.74)
	dr += 0.038 * _blob(px, py - 0.150, pz - 0.84, 0.60, 0.50, 0.48)

	# --- the nose ----------------------------------------------------------
	dz -= 0.075 * nose * _blob(px, py + 0.080, pz + 0.84, 0.135, 0.340, 0.54)
	dz -= 0.130 * nose * _blob(px, py + 0.300, pz + 0.84, 0.140, 0.240, 0.54)
	dz -= 0.125 * _blob(px, py + 0.400, pz + 0.88, nw, 0.125, 0.48)
	dz -= 0.090 * _blob(ax - nw, py + 0.460, pz + 0.84, 0.115, 0.100, 0.48)
	dz += 0.055 * _blob(px, py + 0.520, pz + 0.80, 0.210, 0.062, 0.42)

	# --- mouth and chin ----------------------------------------------------
	dz -= 0.050 * _blob(px, py + 0.615, pz + 0.66, 0.400, 0.250, 0.50)
	dz -= 0.072 * lips * _blob(px, py + 0.590, pz + 0.72, 0.330, 0.072, 0.44)
	dz -= 0.080 * lips * _blob(px, py + 0.710, pz + 0.72, 0.300, 0.080, 0.44)
	dz += 0.070 * _blob(px, py + 0.645, pz + 0.74, 0.320, 0.034, 0.44)
	dz += 0.038 * _blob(px, py + 0.515, pz + 0.78, 0.052, 0.086, 0.42)
	dz += 0.042 * _blob(ax - 0.255, py + 0.570, pz + 0.68, 0.085, 0.150, 0.44)
	dz -= 0.110 * float(p["chin"]) * _blob(px, py + 0.845, pz + 0.42, 0.280, 0.200, 0.44)
	dz += 0.050 * _blob(px, py + 0.740, pz + 0.50, 0.240, 0.085, 0.40)

	return (Vector3(px, py, pz) + out * dr + Vector3(0, 0, dz)) * r


## Ring heights for the skull: packed into the face band (chin to brow), because that
## is where every feature is and the cranium is a smooth dome that needs almost none.
static func head_ts(lod: int) -> PackedFloat32Array:
	var lo: int = 4 if lod == 0 else 3
	var mid: int = 18 if lod == 0 else 10
	var hi: int = 8 if lod == 0 else 5
	var ts := PackedFloat32Array()
	for i in range(lo + 1):
		ts.append(lerpf(0.0, 0.17, float(i) / float(lo)))
	for i in range(1, mid + 1):
		ts.append(lerpf(0.17, 0.62, float(i) / float(mid)))
	for i in range(1, hi + 1):
		ts.append(lerpf(0.62, 1.0, float(i) / float(hi)))
	return ts


## Azimuths for the skull. Warped so the segments bunch up at the FRONT: the face needs
## six-millimetre spacing to hold a philtrum, the back of the head does not, and a
## uniform ring wastes two thirds of its vertices on the occiput. The seam lands at the
## back where nothing can see it.
static func head_azimuths(seg: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in range(seg):
		var d: float = -PI + TAU * float(i) / float(seg)
		out.append(-PI * 0.5 + d - 0.50 * sin(d))
	return out


static func head_shell(r: float, preset: int, lod: int = 0) -> ArrayMesh:
	return _memo("head|%.4f|%d|%d" % [r, preset, lod], func(): return _head_shell_gen(r, preset, lod))


static func _head_shell_gen(r: float, preset: int, lod: int) -> ArrayMesh:
	var p: Dictionary = face_preset(preset)
	var ts := head_ts(lod)
	var azs := head_azimuths(36 if lod == 0 else 20)
	var rows: Array = []
	for t in ts:
		var ring_pts := PackedVector3Array()
		for a in azs:
			ring_pts.append(head_point(t, a, r, p))
		rows.append(ring_pts)
	var grids: Array = [{"rows": rows, "wrap": true, "u": 1.0, "v": 1.0}]
	for sx in [-1.0, 1.0]:
		grids.append_array(_ear_grids(r, p, sx, lod))
	return surface(grids)


## An ear.
##
## The first version was a torus: an even ring with a hole in it, stuck flat on the
## skull, which read as a handle rather than an ear. A real auricle is a rolled helix
## that is THICK at the top and back and thins to nothing where it meets the temple, an
## antihelix ridge inside it, a concha dish between the two, and a lobe hanging below —
## and it lies at an angle, top tilted back. All four are here; it is worth the ~200
## triangles because the ear is most of what says "person" in profile, which is exactly
## the angle a conversation puts you at.
static func _ear_grids(r: float, p: Dictionary, sx: float, lod: int) -> Array:
	var e := {
		"ex": head_surface(-0.170, 0.0, r, p).x * 0.955 * sx,
		"ey": -0.170 * r,
		"ez": 0.145 * r,
		"ry": 0.250 * r,
		"rz": 0.140 * r,
		"tilt": 0.20,  # radians, top of the ear rakes backwards
	}
	return [_ear_rim(r, sx, lod, e), _ear_antihelix(r, sx, lod, e), _ear_plate(r, sx, lod, e), _ear_lobe(r, sx, lod, e)]


## The helix: a rolled rim, thick at the top and back, thinning to nothing at the root.
static func _ear_rim(r: float, sx: float, lod: int, e: Dictionary) -> Dictionary:
	var ex: float = e.ex
	var ey: float = e.ey
	var ez: float = e.ez
	var ry: float = e.ry
	var rz: float = e.rz
	var tilt: float = e.tilt
	var n: int = 15 if lod == 0 else 9
	var seg: int = 5 if lod == 0 else 4
	var path := PackedVector3Array()
	var radii := PackedFloat32Array()
	for i in range(n + 1):
		var a: float = TAU * float(i) / float(n) - PI * 0.5
		var cy: float = cos(a)
		var sz2: float = sin(a)
		# 1 at the back-top of the helix, 0 at the root in front of the tragus.
		var roll: float = clampf(0.5 + 0.5 * cos(a - 1.05), 0.0, 1.0)
		var yy: float = ey + cy * ry
		var zz: float = ez + sz2 * rz
		path.append(Vector3(ex + sx * (0.012 + 0.044 * roll) * r, yy + sz2 * ry * tilt, zz))
		radii.append(r * lerpf(0.022, 0.052, roll))
	return {"rows": sweep_rows(path, radii, seg, 0.75, Vector3(sx, 0, 0))}


## The Y-shaped ridge inside the rim. Without it the ear is a loop.
static func _ear_antihelix(r: float, sx: float, lod: int, e: Dictionary) -> Dictionary:
	var ex: float = e.ex
	var ey: float = e.ey
	var ez: float = e.ez
	var ry: float = e.ry
	var rz: float = e.rz
	var tilt: float = e.tilt
	var ah := PackedVector3Array()
	var ahr := PackedFloat32Array()
	var m: int = 8 if lod == 0 else 5
	for i in range(m):
		var a: float = lerpf(-2.5, 0.9, float(i) / float(m - 1))
		var yy: float = ey + cos(a) * ry * 0.58
		var zz: float = ez + sin(a) * rz * 0.52
		ah.append(Vector3(ex + sx * 0.024 * r, yy + sin(a) * ry * tilt * 0.6, zz))
		ahr.append(r * lerpf(0.020, 0.036, sin(float(i) / float(m - 1) * PI)))
	return {"rows": sweep_rows(ah, ahr, 4, 1.0, Vector3(sx, 0, 0))}


## The plate behind them, dished into a concha in front of the antihelix so the ear
## has a hollow rather than a flat disc.
static func _ear_plate(r: float, sx: float, lod: int, e: Dictionary) -> Dictionary:
	var ex: float = e.ex
	var ey: float = e.ey
	var ez: float = e.ez
	var ry: float = e.ry
	var rz: float = e.rz
	var tilt: float = e.tilt
	var plate: Array = []
	var pn: int = 12 if lod == 0 else 8
	for j in range(5):
		var f: float = float(j) / 4.0
		var ring_pts := PackedVector3Array()
		for i in range(pn):
			var a: float = TAU * float(i) / float(pn)
			var cy: float = cos(a)
			var sz2: float = sin(a)
			var dish: float = 0.044 * r * (1.0 - f * f) * clampf(0.35 - sz2 * 0.85, 0.0, 1.4)
			(
				ring_pts
				. append(
					Vector3(
						ex + sx * (0.010 * r - dish),
						ey + cy * ry * 0.80 * f + sz2 * ry * tilt * f,
						ez + sz2 * rz * 0.78 * f,
					)
				)
			)
		plate.append(ring_pts)
	return {"rows": plate if sx > 0.0 else _flip_rows(plate)}


## The lobe.
static func _ear_lobe(r: float, sx: float, _lod: int, e: Dictionary) -> Dictionary:
	var ex: float = e.ex
	var ey: float = e.ey
	var ez: float = e.ez
	var ry: float = e.ry
	var tilt: float = e.tilt
	var lobe: Array = []
	for j in range(4):
		var t: float = float(j) / 3.0
		var ring_pts := PackedVector3Array()
		for i in range(8):
			var a: float = TAU * float(i) / 8.0
			var rr: float = sin(maxf(t, 0.06) * PI) * 0.085 * r
			(
				ring_pts
				. append(
					Vector3(
						ex + sx * (0.024 * r + cos(a) * rr * 0.55),
						ey - ry * 0.92 - r * 0.055 + (t - 0.5) * 0.14 * r,
						ez + sin(a) * rr - ry * tilt * 0.9,
					)
				)
			)
		lobe.append(ring_pts)
	return {"rows": lobe if sx > 0.0 else _flip_rows(lobe)}


## Reverse a grid's ring order so a mirrored copy keeps its front faces outward.
static func _flip_rows(rows: Array) -> Array:
	var out: Array = []
	for row in rows:
		var src: PackedVector3Array = row
		var dst := PackedVector3Array()
		for i in range(src.size()):
			dst.append(src[src.size() - 1 - i])
		out.append(dst)
	return out


## The front-most point of the sculpted skull at height `y_units` on azimuth `a`.
##
## Features are placed AGAINST THIS rather than against a constant. The same class of
## bug has already been paid for twice in this project — a hair cap tuned by hand that
## ended up entirely inside the skull, and eyes whose front face never drew — and it
## comes back every time a number is guessed instead of measured.
static func head_surface(y_units: float, a: float, r: float, p: Dictionary) -> Vector3:
	var best := Vector3.ZERO
	var best_d := 1.0e9
	for i in range(72):
		var t: float = 0.02 + 0.96 * float(i) / 71.0
		var q := head_point(t, a, r, p)
		var d: float = absf(q.y / r - y_units)
		if d < best_d:
			best_d = d
			best = q
	return best


## One eyelid: a thin spherical shell that rides on the eyeball and blinks by rotating
## about its own X axis. The lid edge is an ALMOND — the aperture is tall at the pupil
## and closes to nothing at the two corners — which is the difference between an eye and
## a ping-pong ball with a band round it.
static func eyelid(rb: float, upper: bool, lod: int = 0) -> ArrayMesh:
	return _memo("lid|%.4f|%s|%d" % [rb, upper, lod], func(): return _eyelid_gen(rb, upper, lod))


static func _eyelid_gen(rb: float, upper: bool, lod: int) -> ArrayMesh:
	var ro: float = rb * 1.155
	var ri: float = rb * 1.062
	var hw: float = rb * 0.99
	var root: float = -0.30 if upper else PI + 0.30
	var mid: float = 1.05 if upper else 2.13
	var corner: float = 1.70 if upper else 1.79
	var cols: int = 15 if lod == 0 else 8
	var na: int = 5 if lod == 0 else 3
	var rows: Array = []
	var stages: Array = [[ro, 0], [lerpf(ro, ri, 0.5), 1], [ri, 2]]
	for stage in stages:
		var rad: float = stage[0]
		var kind: int = stage[1]
		var steps: int = na if kind != 1 else 1
		for j in range(steps):
			var f: float = float(j) / float(maxi(steps - 1, 1))
			if kind == 2:
				f = 1.0 - f
			var ring_pts := PackedVector3Array()
			for i in range(cols):
				# Columns run +x to -x so the shell's front faces point outward.
				var x: float = lerpf(hw, -hw, float(i) / float(cols - 1))
				var k: float = absf(x) / hw
				var edge: float = lerpf(mid, corner, pow(k, 1.7))
				var psi: float = lerpf(root, edge, 1.0 if kind == 1 else f)
				if kind == 1:
					psi += 0.07 if upper else -0.07
				var rr: float = sqrt(maxf(rad * rad - x * x, rad * rad * 0.004))
				ring_pts.append(Vector3(x * rad / ro, cos(psi) * rr, -sin(psi) * rr))
			rows.append(ring_pts)
	return surface([{"rows": rows, "wrap": false}])


## Nostrils and the line of the mouth, as separate dark geometry sunk into the face.
## Seven-millimetre holes cannot be modelled by displacing a shell whose vertices are
## six millimetres apart; two small dark forms poking through the skin read as both at
## any distance a conversation happens at, for sixty triangles.
static func face_cavities(r: float, preset: int) -> ArrayMesh:
	return _memo("cav|%.4f|%d" % [r, preset], func(): return _face_cavities_gen(r, preset))


static func _face_cavities_gen(r: float, preset: int) -> ArrayMesh:
	var p: Dictionary = face_preset(preset)
	var parts: Array = []
	var nw: float = 0.150 * float(p["nw"])
	# Both features are parameterised in (t, a) and read straight off `head_point`, so
	# they are ON the sculpted surface however the skull is retuned. Placed by hand
	# instead, the mouth vanished inside the face the first time the head got shorter.
	var t_nose: float = acos(clampf(0.500 / (0.960 * float(p["fh"])), -1.0, 1.0)) / PI
	for sx in [-1.0, 1.0]:
		var q := head_point(t_nose, -PI * 0.5 + sx * 0.24, r, p)
		var b := Basis.from_euler(Vector3(PI * 0.5 - 0.42, sx * 0.30, 0.0))
		parts.append(
			{
				"mesh": ovoid(r * 0.038, r * 0.125, 0.5, 7, 5),
				"xform": Transform3D(b, q + Vector3(sx * nw * 0.06 * r, -r * 0.028, r * 0.070))
			}
		)
	var t_lip: float = acos(clampf(0.650 / (0.960 * float(p["fh"])), -1.0, 1.0)) / PI
	var n := 11
	var path := PackedVector3Array()
	var radii := PackedFloat32Array()
	for i in range(n):
		var u: float = lerpf(-1.0, 1.0, float(i) / float(n - 1))
		var q := head_point(t_lip, -PI * 0.5 + u * 0.62, r, p)
		# Corners of a mouth sit lower than its middle; and the slit is sunk a little
		# way back into the groove the lips already make, never proud of it.
		path.append(q + Vector3(0, -u * u * 0.030 * r, 0.010 * r))
		radii.append(lerpf(0.030, 0.007, u * u) * r)
	# `up_hint` FORWARD puts the ring's full radius along Z and its squashed axis along
	# Y: a slit that is thin top-to-bottom and deep enough to break the surface. With
	# the default UP hint the two are swapped and the mouth sinks into the face.
	parts.append({"mesh": sweep(path, radii, 5, 0.38, Vector3.FORWARD), "xform": Transform3D()})
	return bake(parts)


## A cap of a sphere, facing -Z, its rim exactly on the sphere. The iris uses this:
## a scaled sphere floated in front of an eyeball pokes through the faceted ball at
## every ring and produces the white shards the first face render was covered in.
static func spherical_cap(radius: float, half_angle: float, seg: int = 14, rings_n: int = 4) -> ArrayMesh:
	return _memo(
		"cap|%.4f|%.3f|%d|%d" % [radius, half_angle, seg, rings_n], func(): return _spherical_cap_gen(radius, half_angle, seg, rings_n)
	)


static func _spherical_cap_gen(radius: float, half_angle: float, seg: int, rings_n: int) -> ArrayMesh:
	var rows: Array = []
	for i in range(rings_n + 1):
		var th: float = half_angle * float(rings_n - i) / float(rings_n)
		var rr: float = sin(th) * radius
		var zz: float = -cos(th) * radius
		var ring_pts := PackedVector3Array()
		for s in range(seg):
			var a: float = TAU * float(s) / float(seg)
			ring_pts.append(Vector3(cos(a) * rr, sin(a) * rr, zz))
		rows.append(ring_pts)
	return surface([{"rows": rows, "wrap": true}])
