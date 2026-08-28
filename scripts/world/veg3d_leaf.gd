class_name Veg3D
extends RefCounted
## TRUE 3D vegetation primitives. Everything in here is a SURFACE, never a plane.
##
## The review note that produced this file was "a lot of them are just 2D, make sure
## they're all 3D", and the failure it names is specific: a quad has no thickness, so
## edge-on it is a one-pixel sliver, from below it is a hard-lit rectangle, and in
## silhouette it is a rectangle. The fix is not more quads. It is geometry that still
## reads as a plant when you look along it.
##
## THE LEAF. One lamina, 6-16 triangles, built as a swept ribbon of THREE columns —
## left margin, midrib, right margin. Three columns is the cheapest cross-section that
## is not a line: the midrib sits proud of the two margins, so a section across the
## blade is a shallow tent and the leaf catches a different amount of light on each
## half. Along its length the blade droops on a curve and twists, so no two of its
## triangles are coplanar and the silhouette changes as you walk around it.
##
## THE UV SPACE. UV.x runs across the blade (0.004 left margin, 0.375 midrib, 0.746
## right margin) and UV.y from the petiole at the bottom to the tip at the top. That is
## the LEAF'S OWN parameter space, not a rectangle in an atlas, so the painted veins
## taper exactly as the geometry tapers. tools/gen_tex_leaf3d.py draws into that space.
## The stem strip at UV.x 0.893..0.977 is the twig of a sprig and the rachis of a frond,
## which is why a whole sprig is ONE surface with ONE material.
##
## ALPHA IS NOT THE SILHOUETTE ANY MORE. The old cards cut their leaf shape out of an
## atlas with an alpha scissor; here the outline IS the mesh, the lamina textures are
## opaque, and the scissor never fires on near foliage. That also means no overdraw
## from cut-away pixels.
##
## VERTEX COLOUR CONTRACT, shared with foliage.gdshader:
##   r  flex     0 at the point the sprig is anchored, 1 at a leaf tip. Wind amplitude.
##   g  ao       baked occlusion; low inside a canopy, high on the sunlit shell.
##   b  hue      per-LEAF variation, 0.5 neutral. Constant over one leaf, so a leaf
##               never tears.
##   a  phase    per-SPRIG flutter phase. Constant over a whole sprig, which is what
##               makes the wind bend a sprig from its base instead of shearing the
##               individual leaves off it. This is not cosmetic: hashing the vertex
##               position, which is what the card shader did, gives every vertex of a
##               real leaf a different beat and the leaf visibly comes apart.
##
## Nothing here references TreeBuilder, deliberately: TreeBuilder references this, and
## a `class_name` cycle is a parse error, not a warning. `s` is a TreeBuilder.Surf, but
## it is taken untyped and only ever used through .vert()/.tri()/.quad().

# --- Atlas layout. Must match tools/gen_tex_leaf3d.py. ---------------------
const BLADE_MID := 0.375
const BLADE_HALF := 0.371
const STEM_U0 := 0.893
const STEM_U1 := 0.977
const V_BASE := 0.996  # petiole, bottom of the image
const V_TIP := 0.006  # tip, top of the image

const PHI := 2.399963  # golden angle: alternate leaves round a twig


# --- Winding ---------------------------------------------------------------
## Godot's front faces are CLOCKWISE: the visible side of (a, b, c) is the side that
## (b-a) x (c-a) points AWAY from. Same convention as TreeBuilder.Surf.quad, so the two
## can share a surface without one of them coming out inside-out.
static func face(s, a: int, b: int, c: int, want: Vector3) -> void:
	var cr: Vector3 = (s.v[b] - s.v[a]).cross(s.v[c] - s.v[a])
	if cr.dot(want) > 0.0:
		s.tri(a, c, b)
	else:
		s.tri(a, b, c)


# --- Leaf ------------------------------------------------------------------
## A real leaf outline: narrow where it meets the petiole, widest around `broad`, then
## tapering. `tip` 0 draws it to an acuminate point, 1 leaves it obtuse and rounded.
static func width_at(t: float, broad: float, tip: float, base_w: float) -> float:
	if t <= 0.0:
		return base_w
	if t < broad:
		return base_w + (1.0 - base_w) * pow(sin(t / broad * PI * 0.5), 0.75)
	var a: float = (t - broad) / maxf(1.0 - broad, 1e-3)
	return pow(cos(clampf(a, 0.0, 1.0) * PI * 0.5), lerpf(1.20, 0.34, clampf(tip, 0.0, 1.0)))


## Triangles one leaf costs. LOD maths, and the budget assertions in the tests, read it.
##
## rows = 1 is the MID leaf and the cheapest thing in this file that is still not a
## plane: three verts at the petiole and one at the tip, so it is a TAPERED FOLDED DART
## — two triangles meeting along a raised midrib. It loses the droop along its length,
## which at 30 m and beyond is worth less than one pixel, and keeps the cross-section,
## which is the whole difference between a leaf and a sliver seen edge-on.
static func leaf_tris(rows: int, blunt: bool = false) -> int:
	var r: int = maxi(1, rows)
	return 4 * (r - 1) + (4 if blunt else 2)


## Shape defaults. Copy, override what matters, pass to `leaf`.
static func leaf_cfg() -> Dictionary:
	return {
		"length": 0.26,
		"width": 0.13,
		"rows": 3,  # 1 -> 2 tris, 2 -> 6, 3 -> 10, 4 -> 14
		"camber": 0.46,  # midrib rise as a fraction of the local HALF-width
		"rib": 0.26,  # extra rise right along the midrib, x half-width
		"droop": 0.60,  # radians the blade bends downward over its length
		"twist": 0.30,  # radians the blade rolls over its length
		"broad": 0.34,  # where the leaf is widest
		"tip": 0.0,  # 0 pointed, 1 rounded
		# The blade is 42% of full width where it meets the petiole. Not botany, budget:
		# at three or four stations along the length a narrow base puts the whole widening
		# into one segment and the outline comes out as a blocky shield instead of a leaf.
		"base_w": 0.42,
		"flex": 0.9,
		"ao": 0.9,
		"hue": 0.5,
		"phase": 0.0,
	}


## ONE LEAF, as a curved surface.
##
## `xf`: origin is the petiole attachment, basis.z the direction the blade leaves it in,
## basis.x the direction across the blade. basis.y is ignored and recomputed, so a
## caller can hand over a rough frame.
static func leaf(s, xf: Transform3D, cfg: Dictionary) -> void:
	var rows: int = maxi(1, int(cfg.get("rows", 3)))
	var length: float = cfg.get("length", 0.26)
	var half: float = float(cfg.get("width", 0.13)) * 0.5
	var camber: float = cfg.get("camber", 0.46)
	var rib: float = cfg.get("rib", 0.26)
	var droop: float = cfg.get("droop", 0.60)
	var twist: float = cfg.get("twist", 0.30)
	var broad: float = clampf(cfg.get("broad", 0.34), 0.12, 0.88)
	var tipr: float = clampf(cfg.get("tip", 0.0), 0.0, 1.0)
	var base_w: float = cfg.get("base_w", 0.42)
	var flex0: float = cfg.get("flex", 0.9)
	var col := Color(flex0, cfg.get("ao", 0.9), cfg.get("hue", 0.5), cfg.get("phase", 0.0))
	var blunt: bool = tipr > 0.55

	var fwd: Vector3 = xf.basis.z
	if fwd.length_squared() < 1e-10:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var side: Vector3 = xf.basis.x - fwd * xf.basis.x.dot(fwd)
	if side.length_squared() < 1e-10:
		side = fwd.cross(Vector3.UP)
		if side.length_squared() < 1e-10:
			side = Vector3.RIGHT
	side = side.normalized()

	var pos: Vector3 = xf.origin
	var step: float = length / float(rows)
	var lft := PackedInt32Array()
	var mid := PackedInt32Array()
	var rgt := PackedInt32Array()
	var ups := PackedVector3Array()

	for i in range(rows + 1):
		var t := float(i) / float(rows)
		# fwd x side = up: with fwd = +Z and side = +X that is +Y, which is the leaf's
		# upper surface. The frame tilts with the droop because fwd does.
		var up := fwd.cross(side).normalized()
		var hw: float = half * width_at(t, broad, tipr, base_w)
		# The midrib stands proud of the margins. Held to a floor near the tip so the
		# blade keeps a section where it is too narrow for `camber` to give it one.
		var rise: float = camber * hw + rib * half * (1.0 - t) * 0.5
		var v: float = lerpf(V_BASE, V_TIP, t)
		# Geometric normal of each half-panel: the panel runs from the raised midrib out
		# and down to the margin, so its normal leans outward by exactly that slope.
		var nw: float = maxf(hw, half * 0.22)
		var nl := (up * nw - side * rise).normalized()
		var nr := (up * nw + side * rise).normalized()
		var cl := col
		cl.r = lerpf(flex0 * 0.55, minf(flex0 * 1.15, 1.0), t)
		ups.push_back(up)
		if i == rows and not blunt:
			var ip: int = s.vert(pos, up, side, cl, Vector2(BLADE_MID, v))
			lft.push_back(ip)
			mid.push_back(ip)
			rgt.push_back(ip)
		else:
			lft.push_back(s.vert(pos - side * hw, nl, side, cl, Vector2(BLADE_MID - BLADE_HALF, v)))
			mid.push_back(s.vert(pos + up * rise, up, side, cl, Vector2(BLADE_MID, v)))
			rgt.push_back(s.vert(pos + side * hw, nr, side, cl, Vector2(BLADE_MID + BLADE_HALF, v)))
		if i < rows:
			var t1 := float(i + 1) / float(rows)
			# Droop accelerates toward the tip; the twist is linear, and it is applied
			# to the axis the droop then bends about, so the blade curls as it falls.
			var dth: float = droop * (pow(t1, 1.4) - pow(t, 1.4))
			side = side.rotated(fwd, twist * (t1 - t)).normalized()
			fwd = fwd.rotated(side, dth).normalized()
			pos += fwd * step

	for i in range(rows):
		var want: Vector3 = (ups[i] + ups[i + 1]) * 0.5
		if i == rows - 1 and not blunt:
			face(s, lft[i], mid[i], lft[i + 1], want)
			face(s, mid[i], rgt[i], rgt[i + 1], want)
		else:
			s.quad(lft[i], lft[i + 1], mid[i + 1], mid[i], want)
			s.quad(mid[i], mid[i + 1], rgt[i + 1], rgt[i], want)


# --- Stem ------------------------------------------------------------------
## A tapered prism through `pts`, UV'd into the stem strip of the lamina atlas. Three
## sides is a real volume for 1.5 cm of twig and costs 2 triangles a segment per side;
## anything rounder is spent on something the eye resolves as a line anyway.
static func stem(s, pts: PackedVector3Array, radii: PackedFloat32Array, cols: Array, sides: int = 3) -> void:
	var n := pts.size()
	if n < 2:
		return
	var rings: Array[PackedInt32Array] = []
	var u_ax := Vector3.RIGHT
	var run := 0.0
	for i in range(n):
		var fwd: Vector3
		if i == 0:
			fwd = pts[1] - pts[0]
		elif i == n - 1:
			fwd = pts[i] - pts[i - 1]
		else:
			fwd = pts[i + 1] - pts[i - 1]
		if fwd.length_squared() < 1e-10:
			fwd = Vector3.UP
		fwd = fwd.normalized()
		if i > 0:
			run += pts[i].distance_to(pts[i - 1])
		var u := u_ax - fwd * u_ax.dot(fwd)
		if u.length_squared() < 1e-8:
			u = Vector3.RIGHT - fwd * fwd.x
			if u.length_squared() < 1e-8:
				u = Vector3.FORWARD
		u = u.normalized()
		u_ax = u
		var w := fwd.cross(u).normalized()
		var ring := PackedInt32Array()
		var col: Color = cols[mini(i, cols.size() - 1)]
		for k in range(sides + 1):
			var th := TAU * float(k) / float(sides)
			var rad := (cos(th) * u + sin(th) * w).normalized()
			var tan := -sin(th) * u + cos(th) * w
			var uu: float = lerpf(STEM_U0, STEM_U1, float(k) / float(sides))
			ring.push_back(s.vert(pts[i] + rad * radii[i], rad, tan, col, Vector2(uu, V_BASE - run * 1.6)))
		rings.append(ring)
	for i in range(n - 1):
		var lo := rings[i]
		var hi := rings[i + 1]
		for k in range(sides):
			var mid: Vector3 = (s.v[lo[k]] + s.v[lo[k + 1]] + s.v[hi[k]] + s.v[hi[k + 1]]) * 0.25
			var want: Vector3 = mid - (pts[i] + pts[i + 1]) * 0.5
			if want.length_squared() < 1e-10:
				want = Vector3.UP
			s.quad(lo[k], hi[k], hi[k + 1], lo[k + 1], want)


static func stem_tris(stations: int, sides: int = 3) -> int:
	return maxi(0, stations - 1) * sides * 2


# --- Sprig -----------------------------------------------------------------
## Defaults for a leaf sprig: a twig with several leaves on it.
static func sprig_cfg() -> Dictionary:
	var c := leaf_cfg()
	c["stem_len"] = 0.52
	c["stem_r"] = 0.016
	c["stem_segs"] = 2
	c["leaves"] = 5
	c["first"] = 0.24  # where along the twig the lowest leaf sits
	c["spread"] = 1.05  # radians the leaf leaves the twig at
	c["opposite"] = false
	c["sag"] = 0.34  # how far each blade is pulled toward straight down
	c["stem_droop"] = 0.45  # radians the twig itself bends over its length
	c["tip_leaf"] = true
	return c


## A twig carrying `leaves` real leaves, alternating (golden angle) or in opposite
## pairs, each angled out of the twig and sagging under its own weight.
##
## `xf`: origin is where the twig joins the branch, basis.z the direction it grows in.
static func sprig(s, xf: Transform3D, rng: RandomNumberGenerator, cfg: Dictionary) -> void:
	var slen: float = cfg.get("stem_len", 0.52)
	# stem_segs 0 means NO TWIG: the leaves are still placed along the same virtual
	# spine, but the tube is not emitted. At 30 m and beyond a 3 cm twig is under a
	# pixel wide, and it was costing 6 of the 16 triangles in a MID sprig — 37% of the
	# whole MID canopy budget spent on something that cannot be resolved.
	var segs: int = maxi(1, int(cfg.get("stem_segs", 2)))
	var draw_stem: bool = int(cfg.get("stem_segs", 2)) > 0
	var sr: float = cfg.get("stem_r", 0.016)
	var nleaf: int = maxi(1, int(cfg.get("leaves", 5)))
	var first: float = cfg.get("first", 0.24)
	var spread: float = cfg.get("spread", 1.05)
	var opposite: bool = cfg.get("opposite", false)
	var sag: float = cfg.get("sag", 0.34)
	var sdroop: float = cfg.get("stem_droop", 0.45)
	var flex: float = cfg.get("flex", 0.9)
	var ao: float = cfg.get("ao", 0.9)
	var phase: float = cfg.get("phase", rng.randf())

	var fwd: Vector3 = xf.basis.z.normalized() if xf.basis.z.length_squared() > 1e-10 else Vector3.FORWARD
	var side: Vector3 = fwd.cross(Vector3.UP)
	if side.length_squared() < 1e-8:
		side = fwd.cross(Vector3.RIGHT)
	side = side.normalized()

	# --- the twig itself, drooping on a curve
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var cols: Array = []
	var p: Vector3 = xf.origin
	var d: Vector3 = fwd
	var tans := PackedVector3Array()
	for i in range(segs + 1):
		var t := float(i) / float(segs)
		pts.push_back(p)
		tans.push_back(d)
		radii.push_back(sr * lerpf(1.0, 0.42, t))
		# The twig is the ANCHOR: flex 0 at its base is what stops the whole sprig
		# skating sideways in a gust instead of bending.
		# 0.42 at the base, not 0: the sprig is notionally attached to a branch tip that
		# is itself swaying at about that amount, and pinning the twig to zero left the
		# sprig bases standing still inside a moving canopy.
		cols.push_back(Color(flex * lerpf(0.42, 0.78, t), ao * lerpf(0.72, 1.0, t), 0.5, phase))
		if i < segs:
			var t1 := float(i + 1) / float(segs)
			d = d.rotated(side, sdroop * (t1 - t)).normalized()
			p += d * (slen / float(segs))
	if draw_stem:
		stem(s, pts, radii, cols, 3)

	# --- the leaves
	var lcfg: Dictionary = cfg.duplicate()
	lcfg["phase"] = phase
	var count: int = nleaf if not cfg.get("tip_leaf", true) else maxi(1, nleaf - 1)
	for i in range(count):
		var t: float = lerpf(first, 0.94, 0.0 if count == 1 else float(i) / float(count - 1))
		_leaf_on_stem(s, rng, pts, tans, t, i, spread, opposite, sag, lcfg, flex, ao)
	if cfg.get("tip_leaf", true):
		var td: Vector3 = tans[tans.size() - 1]
		var lf := _sag_frame(pts[pts.size() - 1], td, sag * 0.6, rng)
		var tc: Dictionary = lcfg.duplicate()
		tc["length"] = float(lcfg.get("length", 0.26)) * rng.randf_range(0.86, 1.04)
		tc["flex"] = flex
		tc["ao"] = minf(ao * 1.06, 1.0)
		tc["hue"] = clampf(0.5 + rng.randf_range(-0.34, 0.34), 0.0, 1.0)
		leaf(s, lf, tc)


static func _leaf_on_stem(
	s,
	rng: RandomNumberGenerator,
	pts: PackedVector3Array,
	tans: PackedVector3Array,
	t: float,
	i: int,
	spread: float,
	opposite: bool,
	sag: float,
	lcfg: Dictionary,
	flex: float,
	ao: float
) -> void:
	var fi: float = t * float(pts.size() - 1)
	var k: int = clampi(int(fi), 0, pts.size() - 2)
	var f: float = fi - float(k)
	var att: Vector3 = pts[k].lerp(pts[k + 1], f)
	var axis: Vector3 = tans[k].lerp(tans[k + 1], f).normalized()
	var roll: float = (PI if (i % 2 == 1) else 0.0) if opposite else (PHI * float(i))
	roll += rng.randf_range(-0.22, 0.22)
	var rad: Vector3 = axis.cross(Vector3.UP)
	if rad.length_squared() < 1e-8:
		rad = axis.cross(Vector3.RIGHT)
	rad = rad.normalized().rotated(axis, roll)
	var sp: float = spread + rng.randf_range(-0.18, 0.18)
	var dir: Vector3 = (axis * cos(sp) + rad * sin(sp)).normalized()
	var lf := _sag_frame(att, dir, sag, rng)
	var c: Dictionary = lcfg.duplicate()
	c["length"] = float(lcfg.get("length", 0.26)) * rng.randf_range(0.82, 1.14)
	c["width"] = float(lcfg.get("width", 0.13)) * rng.randf_range(0.88, 1.12)
	c["twist"] = float(lcfg.get("twist", 0.30)) * rng.randf_range(-1.0, 1.4)
	c["flex"] = clampf(flex * lerpf(0.72, 1.0, t), 0.0, 1.0)
	c["ao"] = clampf(ao * lerpf(0.86, 1.0, t), 0.0, 1.0)
	c["hue"] = clampf(0.5 + rng.randf_range(-0.34, 0.34), 0.0, 1.0)
	leaf(s, lf, c)


## Turn a growth direction into a leaf frame: pull it toward straight down by `sag`
## (a leaf has weight) and roll it so the blade presents its upper surface upward.
static func _sag_frame(origin: Vector3, dir: Vector3, sag: float, rng: RandomNumberGenerator) -> Transform3D:
	var d: Vector3 = (dir + Vector3.DOWN * sag).normalized()
	if d.length_squared() < 1e-8:
		d = Vector3.FORWARD
	var side: Vector3 = d.cross(Vector3.UP)
	if side.length_squared() < 1e-8:
		# The blade is vertical: any horizontal axis will do, but Vector3.UP itself
		# gives a zero cross product and a garbage basis rather than an error.
		side = d.cross(Vector3.RIGHT)
		if side.length_squared() < 1e-8:
			side = Vector3.RIGHT
	side = side.normalized().rotated(d, rng.randf_range(-0.55, 0.55))
	var up: Vector3 = d.cross(side).normalized()
	return Transform3D(Basis(side, up, d), origin)


static func sprig_tris(cfg: Dictionary) -> int:
	var segs: int = int(cfg.get("stem_segs", 2))
	var rows: int = maxi(1, int(cfg.get("rows", 3)))
	var blunt: bool = float(cfg.get("tip", 0.0)) > 0.55
	var st: int = stem_tris(segs + 1, 3) if segs > 0 else 0
	return st + int(cfg.get("leaves", 5)) * leaf_tris(rows, blunt)


# --- Palm frond ------------------------------------------------------------
static func frond_cfg() -> Dictionary:
	return {
		"length": 4.2,
		"rise": 1.5,  # metres the rachis lifts before gravity wins
		"droop": 3.8,  # metres it has fallen by the tip
		"sweep": 0.18,  # radians of sideways curve
		"rachis_r": 0.055,
		# 16 pairs at 4.2 m is a leaflet every 26 cm, and the leaflets are 24 cm wide:
		# they just touch, which is what makes a frond read as one blade cut into
		# leaflets rather than a fishbone. 13 pairs looked like a fish skeleton.
		"pairs": 17,
		"pinna_len": 1.18,
		"pinna_w": 0.235,
		"rows": 2,
		"start": 0.10,
		"end": 0.97,
		"back": 0.70,  # radians each leaflet is swept back toward the tip
		# A coconut leaflet sits mostly IN the plane of the frond and only then droops.
		# At 0.55 rad they hung off the rachis like the teeth of a comb and the frond
		# read as a fish skeleton from any angle above it.
		"fall": 0.28,  # radians it hangs below the rachis plane
		"flex": 0.95,
		"ao": 0.92,
		"phase": 0.0,
	}


## A palm frond: a rachis that arcs up and falls away, with a leaflet either side at
## every station. Not a card with a frond painted on it — the most recognisable plant
## in the valley gets ~26 individually curved blades.
##
## `xf`: origin at the crown, basis.z the direction the frond points, basis.x across.
static func frond(s, xf: Transform3D, rng: RandomNumberGenerator, cfg: Dictionary) -> void:
	var flen: float = cfg.get("length", 4.2)
	var rise: float = cfg.get("rise", 1.5)
	var drop: float = cfg.get("droop", 3.8)
	var sweep: float = cfg.get("sweep", 0.18)
	var rr: float = cfg.get("rachis_r", 0.055)
	var pairs: int = maxi(2, int(cfg.get("pairs", 17)))
	var plen: float = cfg.get("pinna_len", 1.18)
	var pw: float = cfg.get("pinna_w", 0.235)
	var rows: int = maxi(1, int(cfg.get("rows", 2)))
	var t0: float = cfg.get("start", 0.10)
	var t1: float = cfg.get("end", 0.97)
	var back: float = cfg.get("back", 0.70)
	var fall: float = cfg.get("fall", 0.28)
	var flex: float = cfg.get("flex", 0.95)
	var ao: float = cfg.get("ao", 0.92)
	var phase: float = cfg.get("phase", rng.randf())

	var out: Vector3 = xf.basis.z.normalized() if xf.basis.z.length_squared() > 1e-10 else Vector3.FORWARD
	var org: Vector3 = xf.origin

	# --- rachis. Rises then falls: y = rise*t - drop*t*t is the classic frond arc, and
	#     it is the same curve the old card strip used, so the crown silhouette is kept.
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var cols: Array = []
	for i in range(pairs + 1):
		var t := float(i) / float(pairs)
		var dir: Vector3 = out.rotated(Vector3.UP, sweep * t * t)
		var y: float = rise * t - drop * t * t
		pts.push_back(org + dir * (flen * t) + Vector3(0, y, 0))
		radii.push_back(rr * lerpf(1.0, 0.20, pow(t, 0.7)))
		cols.push_back(Color(flex * lerpf(0.06, 0.90, t * t), ao * lerpf(0.70, 1.0, t), 0.5, phase))
	stem(s, pts, radii, cols, 3)

	# --- leaflets, one pair a station
	for i in range(pairs + 1):
		var t := float(i) / float(pairs)
		if t < t0 or t > t1:
			continue
		var k: int = clampi(i, 0, pts.size() - 2)
		var axis: Vector3 = (pts[k + 1] - pts[k]).normalized()
		var cross: Vector3 = axis.cross(Vector3.UP)
		if cross.length_squared() < 1e-8:
			cross = axis.cross(Vector3.RIGHT)
		cross = cross.normalized()
		# Longest leaflets in the middle third, short at the base and the tip: that
		# profile is most of what makes a frond read as a frond in silhouette.
		var prof: float = pow(sin(clampf((t - t0) / maxf(t1 - t0, 1e-3), 0.0, 1.0) * PI), 0.42)
		var ln: float = plen * (0.46 + 0.54 * prof) * rng.randf_range(0.92, 1.08)
		for sgn in [-1.0, 1.0]:
			var d: Vector3 = cross * sgn
			# Out to the side, swept back toward the tip, then hung below the rachis.
			# Both angles matter: without the sweep a frond is a bottlebrush, without
			# the fall it is flat and reads as the card it replaced.
			var dir2: Vector3 = (d * cos(back) + axis * sin(back)).normalized()
			# Two ranks: neighbouring leaflets hang by different amounts, which is what
			# stops the blade from reading as one flat comb.
			var fa: float = fall * rng.randf_range(0.62, 1.42)
			dir2 = (dir2 * cos(fa) + Vector3.DOWN * sin(fa)).normalized()
			var sd: Vector3 = dir2.cross(Vector3.UP)
			if sd.length_squared() < 1e-8:
				sd = dir2.cross(axis)
			sd = sd.normalized().rotated(dir2, sgn * 0.35 + rng.randf_range(-0.2, 0.2))
			var up: Vector3 = dir2.cross(sd).normalized()
			var c := leaf_cfg()
			c["length"] = ln
			c["width"] = pw * rng.randf_range(0.9, 1.1)
			c["rows"] = rows
			c["camber"] = 1.15  # a leaflet is folded, not merely cambered
			c["rib"] = 0.20
			c["droop"] = 0.85 + rng.randf_range(0.0, 0.35)
			c["twist"] = rng.randf_range(-0.35, 0.35)
			c["broad"] = 0.26
			c["tip"] = 0.0
			c["base_w"] = 0.62
			c["flex"] = clampf(flex * lerpf(0.30, 1.0, t), 0.0, 1.0)
			c["ao"] = clampf(ao * lerpf(0.80, 1.0, t), 0.0, 1.0)
			c["hue"] = clampf(0.5 + rng.randf_range(-0.30, 0.42), 0.0, 1.0)
			c["phase"] = phase
			leaf(s, Transform3D(Basis(sd, up, dir2), pts[i]), c)


static func frond_tris(cfg: Dictionary) -> int:
	var pairs: int = maxi(2, int(cfg.get("pairs", 17)))
	var rows: int = maxi(1, int(cfg.get("rows", 2)))
	var t0: float = cfg.get("start", 0.10)
	var t1: float = cfg.get("end", 0.97)
	var n := 0
	for i in range(pairs + 1):
		var t := float(i) / float(pairs)
		if t >= t0 and t <= t1:
			n += 2
	return stem_tris(pairs + 1, 3) + n * leaf_tris(rows, false)
