class_name Arch
extends RefCounted
## Man-made geometry for the Vale of Panchavati: huts, granaries, the shrine, ruins,
## gates, bridges, fences and the small props that make a place look lived in.
##
## Everything is real geometry built through Kit, a small multi-surface mesh builder.
## Two rules that cost debugging time elsewhere in this project and are obeyed here:
##   * Godot front faces are CLOCKWISE. Kit.trin() emits (a, c, b) so callers can pass
##     vertices counter-clockwise-as-seen-from-outside, which is what everyone expects.
##   * Every material here uses a normal map, so ARRAY_TANGENT is mandatory. Kit.commit()
##     calls generate_tangents() on every surface; without it each lit pixel is black.
##
## Loops in the XZ plane are ordered CLOCKWISE in (x, z) — the ordering produced by
## p(theta) = (r*cos t, y, -r*sin t). With that handedness the side bands face outward
## and the top caps face +Y with no special-casing. _ensure_cw() enforces it.

# --- materials -------------------------------------------------------------
static var _mats: Dictionary = {}


static func mat(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var m: Material = null
	match key:
		"clay":
			m = Mats.pbr("clay_wall", 0.40)
		"clay_dark":
			var c := (Mats.pbr("clay_wall", 0.40) as StandardMaterial3D).duplicate()
			c.albedo_color = Color(0.34, 0.30, 0.26)
			m = c
		"thatch":
			m = Mats.pbr("thatch", 0.55)
		"thatch_fine":
			m = Mats.pbr("thatch", 1.6)
		"wood":
			m = Mats.pbr("wood_beam", 0.85)
		"stone":
			m = Mats.pbr("temple_stone", 0.32)
		"stone_fine":
			m = Mats.pbr("temple_stone", 0.70)
		"carved":
			m = Mats.pbr("carved_stone", 0.36)
		"carved_fine":
			m = Mats.pbr("carved_stone", 0.85)
		"terracotta":
			m = Mats.pbr("terracotta", 0.65)
		"pot":
			# terracotta_albedo is a bright orange roof-tile sheet. At uv_scale 1.5 a
			# 40 cm water pot spans less than one texture repeat, so it came out flat
			# saturated orange: from ten metres the pots by the well read as pumpkins
			# lying on the grass, and at dusk they looked emissive. Tighter UVs so the
			# mottling actually shows at pot scale, and a tint that drops it to the
			# value of unglazed fired clay.
			var pt := (Mats.pbr("terracotta", 3.4) as StandardMaterial3D).duplicate()
			pt.albedo_color = Color(0.56, 0.50, 0.48)
			# terracotta_rough is a glossy sheet meant for fired roof tiles. On a lathed
			# pot it put a highlight all down one side, which is what made the pots read
			# as balloons rather than as clay. Unglazed water pots are dead matte.
			pt.roughness_texture = null
			pt.roughness = 0.96
			pt.metallic_specular = 0.25
			m = pt
		"cane":
			# baskets borrowed the thatch sheet untinted and read as blocks of butter
			var cn := (Mats.pbr("thatch", 3.2) as StandardMaterial3D).duplicate()
			cn.albedo_color = Color(0.70, 0.58, 0.40)
			m = cn
		"brick":
			m = Mats.pbr("brick_ruin", 0.48)
		"carved_ruin":
			var cr := (Mats.pbr("carved_stone", 0.34) as StandardMaterial3D).duplicate()
			cr.albedo_color = Color(0.72, 0.73, 0.65)
			m = cr
		"stone_ruin":
			# The ruin floor and its rubble were sharing the temple's dressed stone, so
			# a hall abandoned for centuries was brighter and cleaner than the shrine
			# that is still in use. Weather it: darker, greyer, no gloss.
			var sr := (Mats.pbr("temple_stone", 0.30) as StandardMaterial3D).duplicate()
			sr.albedo_color = Color(0.70, 0.71, 0.63)
			m = sr
		"brass":
			m = Mats.brass()
		"dirt":
			m = Mats.pbr("dirt", 0.30)
		"bed":
			# Exposed rubble bedding under a ruined pavement.
			#
			# It started as `dirt`, whose sheet averages sRGB (91, 50, 30) - a strong red
			# laterite. Spread over a 21 x 13 m platform in sunlight that read as a sheet
			# of red plastic laid on the grass, and no albedo tint fixes it: a tint can
			# only scale the channels, and this needs the red pulled DOWN relative to the
			# other two. `rock` averages (115, 105, 85), which is the neutral grey-tan of
			# stone dust and broken mortar, so the bed uses that instead and is only
			# darkened enough to sit under the surviving slabs.
			var bd := (Mats.pbr("rock", 0.42) as StandardMaterial3D).duplicate()
			bd.albedo_color = Color(0.82, 0.80, 0.76)
			m = bd
		"mud":
			m = Mats.pbr("mud_river", 0.35)
		"hide":
			# The raw demon hide reads cold grey in sunlight, which looked like sheet
			# metal on a lean-to. Warm it toward tanned leather.
			var h := (Mats.pbr("demon_hide", 0.45, "demon_hide") as StandardMaterial3D).duplicate()
			h.cull_mode = BaseMaterial3D.CULL_DISABLED
			h.albedo_color = Color(0.86, 0.66, 0.50)
			m = h
		"cloth_s":
			m = _cloth("cloth_saffron")
		"cloth_i":
			m = _cloth("cloth_indigo")
		"cloth_w":
			m = _cloth("cloth_white")
		"rope":
			m = Mats.flat(Color(0.70, 0.60, 0.42), 0.95)
		"bone":
			m = Mats.flat(Color(0.80, 0.77, 0.68), 0.65)
		"ash":
			m = Mats.flat(Color(0.56, 0.53, 0.49), 1.0)
		"char":
			m = Mats.flat(Color(0.31, 0.25, 0.21), 0.92)
		"dark":
			m = Mats.flat(Color(0.035, 0.030, 0.026), 1.0)
		"flame":
			var f := StandardMaterial3D.new()
			f.albedo_color = Color(1.0, 0.72, 0.30)
			f.emission_enabled = true
			f.emission = Color(1.0, 0.66, 0.24)
			f.emission_energy_multiplier = 6.0
			f.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m = f
		_:
			m = Mats.flat(Color(0.6, 0.6, 0.6))
	_mats[key] = m
	return m


static func _cloth(base: String) -> Material:
	var c := (Mats.pbr(base, 0.9, base) as StandardMaterial3D).duplicate()
	c.cull_mode = BaseMaterial3D.CULL_DISABLED
	return c


static func rng(seed_i: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash(seed_i * 2654435761 + 1013904223)
	return r


# ===========================================================================
# Kit — multi-surface mesh builder
# ===========================================================================
class Kit:
	extends RefCounted
	var _t: Dictionary = {}
	var _order: Array = []

	func s(key: String) -> SurfaceTool:
		if _t.has(key):
			return _t[key]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_t[key] = st
		_order.append(key)
		return st

	## a, b, c counter-clockwise as seen from OUTSIDE. Emitted reversed because Godot
	## front faces are clockwise.
	func trin(
		key: String, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, ua: Vector2, ub: Vector2, uc: Vector2
	) -> void:
		var st := s(key)
		st.set_normal(na)
		st.set_uv(ua)
		st.add_vertex(a)
		st.set_normal(nc)
		st.set_uv(uc)
		st.add_vertex(c)
		st.set_normal(nb)
		st.set_uv(ub)
		st.add_vertex(b)

	func tri(key: String, a: Vector3, b: Vector3, c: Vector3, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
		var n: Vector3 = (b - a).cross(c - a)
		if n.length_squared() < 1e-14:
			return
		n = n.normalized()
		trin(key, a, b, c, n, n, n, ua, ub, uc)

	func quad(key: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
		tri(key, a, b, c, ua, ub, uc)
		tri(key, a, c, d, ua, uc, ud)

	func quadn(
		key: String,
		a: Vector3,
		b: Vector3,
		c: Vector3,
		d: Vector3,
		na: Vector3,
		nb: Vector3,
		nc: Vector3,
		nd: Vector3,
		ua: Vector2,
		ub: Vector2,
		uc: Vector2,
		ud: Vector2
	) -> void:
		trin(key, a, b, c, na, nb, nc, ua, ub, uc)
		trin(key, a, c, d, na, nc, nd, ua, uc, ud)

	## Auto-UV planar quad: u runs a->b, v runs a->d, both in metres.
	func quadp(key: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, uo := Vector2.ZERO) -> void:
		var w: float = a.distance_to(b)
		var h: float = a.distance_to(d)
		var w2: float = d.distance_to(c)
		quad(key, a, b, c, d, uo, uo + Vector2(w, 0.0), uo + Vector2(w2, h), uo + Vector2(0.0, h))

	func box(key: String, xf: Transform3D, size: Vector3, uv_off := Vector2.ZERO) -> void:
		var hx: float = size.x * 0.5
		var hy: float = size.y * 0.5
		var hz: float = size.z * 0.5
		var p := func(x: float, y: float, z: float) -> Vector3: return xf * Vector3(x, y, z)
		var faces := [
			# each: 4 corners CCW from outside, plus uv axis pair
			[[Vector3(hx, -hy, hz), Vector3(hx, -hy, -hz), Vector3(hx, hy, -hz), Vector3(hx, hy, hz)], 2, 1],
			[[Vector3(-hx, -hy, -hz), Vector3(-hx, -hy, hz), Vector3(-hx, hy, hz), Vector3(-hx, hy, -hz)], 2, 1],
			[[Vector3(-hx, hy, hz), Vector3(hx, hy, hz), Vector3(hx, hy, -hz), Vector3(-hx, hy, -hz)], 0, 2],
			[[Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz)], 0, 2],
			[[Vector3(-hx, -hy, hz), Vector3(hx, -hy, hz), Vector3(hx, hy, hz), Vector3(-hx, hy, hz)], 0, 1],
			[[Vector3(hx, -hy, -hz), Vector3(-hx, -hy, -hz), Vector3(-hx, hy, -hz), Vector3(hx, hy, -hz)], 0, 1],
		]
		for f in faces:
			var cs: Array = f[0]
			var ai: int = f[1]
			var bi: int = f[2]
			var uv: Array = []
			for cv in cs:
				var v: Vector3 = cv
				uv.append(Vector2(v[ai], v[bi]) + uv_off)
			quad(
				key,
				p.call(cs[0].x, cs[0].y, cs[0].z),
				p.call(cs[1].x, cs[1].y, cs[1].z),
				p.call(cs[2].x, cs[2].y, cs[2].z),
				p.call(cs[3].x, cs[3].y, cs[3].z),
				uv[0],
				uv[1],
				uv[2],
				uv[3]
			)

	## Side band between two matching closed loops (lo below, hi above). Flat shaded.
	func band(key: String, lo: Array, hi: Array, uo: float = 0.0) -> void:
		var n: int = lo.size()
		var u: float = uo
		for i in range(n):
			var j: int = (i + 1) % n
			var a: Vector3 = lo[i]
			var b: Vector3 = lo[j]
			var c: Vector3 = hi[j]
			var d: Vector3 = hi[i]
			var w: float = Vector2(b.x - a.x, b.z - a.z).length()
			var h0: float = d.y - a.y
			var h1: float = c.y - b.y
			quad(key, a, b, c, d, Vector2(u, 0.0), Vector2(u + w, 0.0), Vector2(u + w, h1), Vector2(u, h0))
			u += w

	## Smooth-shaded band; normals supplied per loop vertex.
	func band_n(key: String, lo: Array, hi: Array, nl: Array, nh: Array, v0: float, v1: float, uscale: float) -> void:
		var n: int = lo.size()
		var u: float = 0.0
		for i in range(n):
			var j: int = (i + 1) % n
			var w: float = lo[i].distance_to(lo[j])
			quadn(
				key,
				lo[i],
				lo[j],
				hi[j],
				hi[i],
				nl[i],
				nl[j],
				nh[j],
				nh[i],
				Vector2(u * uscale, v0),
				Vector2((u + w) * uscale, v0),
				Vector2((u + w) * uscale, v1),
				Vector2(u * uscale, v1)
			)
			u += w

	## Horizontal annulus between an outer and inner loop. up=true faces +Y.
	func annulus(key: String, outer: Array, inner: Array, up: bool) -> void:
		var n: int = outer.size()
		for i in range(n):
			var j: int = (i + 1) % n
			var a: Vector3 = outer[i]
			var b: Vector3 = outer[j]
			var c: Vector3 = inner[j]
			var d: Vector3 = inner[i]
			if up:
				quad(key, a, b, c, d, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z), Vector2(d.x, d.z))
			else:
				quad(key, d, c, b, a, Vector2(d.x, d.z), Vector2(c.x, c.z), Vector2(b.x, b.z), Vector2(a.x, a.z))

	## Fan cap over a loop. up=true faces +Y, otherwise -Y.
	func cap(key: String, loop: Array, up: bool) -> void:
		var n: int = loop.size()
		if n < 3:
			return
		var ctr := Vector3.ZERO
		for v in loop:
			ctr += v
		ctr /= float(n)
		for i in range(n):
			var j: int = (i + 1) % n
			var a: Vector3 = loop[i]
			var b: Vector3 = loop[j]
			if up:
				tri(key, ctr, a, b, Vector2(ctr.x, ctr.z), Vector2(a.x, a.z), Vector2(b.x, b.z))
			else:
				tri(key, ctr, b, a, Vector2(ctr.x, ctr.z), Vector2(b.x, b.z), Vector2(a.x, a.z))

	## Surface of revolution. profile is (radius, y) bottom to top.
	func lathe(
		key: String,
		profile: PackedVector2Array,
		sides: int,
		xf: Transform3D,
		smooth: bool = true,
		cap_bottom: bool = false,
		cap_top: bool = false
	) -> void:
		var m: int = profile.size()
		if m < 2:
			return
		var rmax: float = 0.0
		for p in profile:
			rmax = maxf(rmax, p.x)
		var rings: Array = []
		var norms: Array = []
		for li in range(m):
			var ring: Array = []
			var nr: Array = []
			var dr: float
			var dy: float
			if li == 0:
				dr = profile[1].x - profile[0].x
				dy = profile[1].y - profile[0].y
			elif li == m - 1:
				dr = profile[m - 1].x - profile[m - 2].x
				dy = profile[m - 1].y - profile[m - 2].y
			else:
				dr = profile[li + 1].x - profile[li - 1].x
				dy = profile[li + 1].y - profile[li - 1].y
			var n2 := Vector2(dy, -dr)
			if n2.length_squared() < 1e-12:
				n2 = Vector2(1.0, 0.0)
			n2 = n2.normalized()
			for i in range(sides):
				var th: float = TAU * float(i) / float(sides)
				var cs: float = cos(th)
				var sn: float = sin(th)
				ring.append(xf * Vector3(profile[li].x * cs, profile[li].y, -profile[li].x * sn))
				nr.append((xf.basis * Vector3(n2.x * cs, n2.y, -n2.x * sn)).normalized())
			rings.append(ring)
			norms.append(nr)
		var v: float = 0.0
		for li in range(m - 1):
			var seglen: float = Vector2(profile[li + 1].x - profile[li].x, profile[li + 1].y - profile[li].y).length()
			if smooth:
				band_n(key, rings[li], rings[li + 1], norms[li], norms[li + 1], v, v + seglen, 1.0)
			else:
				band(key, rings[li], rings[li + 1], v)
			v += seglen
		if cap_bottom:
			cap(key, rings[0], false)
		if cap_top:
			cap(key, rings[m - 1], true)

	func cyl(
		key: String,
		xf: Transform3D,
		r0: float,
		r1: float,
		h: float,
		sides: int,
		cap_bottom: bool = true,
		cap_top: bool = true,
		smooth: bool = true
	) -> void:
		var prof := PackedVector2Array([Vector2(r0, 0.0), Vector2(r1, h)])
		lathe(key, prof, sides, xf, smooth, cap_bottom, cap_top)

	## Poly-tube swept along a path. Good for ropes, withies and rough poles.
	func tube(key: String, path: Array, r: float, sides: int) -> void:
		if path.size() < 2:
			return
		var up := Vector3.UP
		var rings: Array = []
		var norms: Array = []
		for i in range(path.size()):
			var fwd: Vector3
			if i == 0:
				fwd = (path[1] - path[0])
			elif i == path.size() - 1:
				fwd = (path[i] - path[i - 1])
			else:
				fwd = (path[i + 1] - path[i - 1])
			if fwd.length_squared() < 1e-12:
				fwd = Vector3.FORWARD
			fwd = fwd.normalized()
			var ref: Vector3 = up if absf(fwd.dot(up)) < 0.94 else Vector3.RIGHT
			var sx: Vector3 = fwd.cross(ref).normalized()
			var sy: Vector3 = sx.cross(fwd).normalized()
			var ring: Array = []
			var nr: Array = []
			for j in range(sides):
				var th: float = TAU * float(j) / float(sides)
				var d: Vector3 = sx * cos(th) + sy * sin(th)
				ring.append(path[i] + d * r)
				nr.append(d)
			rings.append(ring)
			norms.append(nr)
		var v: float = 0.0
		for i in range(path.size() - 1):
			var l: float = path[i].distance_to(path[i + 1])
			band_n(key, rings[i], rings[i + 1], norms[i], norms[i + 1], v, v + l, 1.0)
			v += l
		cap(key, rings[0], false)
		cap(key, rings[rings.size() - 1], true)

	func commit() -> ArrayMesh:
		var mesh := ArrayMesh.new()
		for key in _order:
			var st: SurfaceTool = _t[key]
			st.generate_tangents()
			st.index()
			st.set_material(Arch.mat(key))
			st.commit(mesh)
		return mesh

	func node(nm: String) -> MeshInstance3D:
		var mi := MeshInstance3D.new()
		mi.name = nm
		mi.mesh = commit()
		return mi


# ===========================================================================
# 2-D plan helpers. All loops CLOCKWISE in (x, z).
# ===========================================================================
static func signed_area(poly: Array) -> float:
	var a: float = 0.0
	var n: int = poly.size()
	for i in range(n):
		var p: Vector2 = poly[i]
		var q: Vector2 = poly[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


static func ensure_cw(poly: Array) -> Array:
	if signed_area(poly) > 0.0:
		poly.reverse()
	return poly


static func circle_poly(r: float, n: int, jitter: float = 0.0, rg: RandomNumberGenerator = null) -> Array:
	var out: Array = []
	for i in range(n):
		var th: float = TAU * float(i) / float(n)
		var rr: float = r
		if jitter > 0.0 and rg != null:
			rr += rg.randf_range(-jitter, jitter)
		out.append(Vector2(rr * cos(th), -rr * sin(th)))
	return out


static func rect_poly(hx: float, hz: float, per_side: int) -> Array:
	var corners := [Vector2(hx, -hz), Vector2(-hx, -hz), Vector2(-hx, hz), Vector2(hx, hz)]
	var out: Array = []
	for i in range(4):
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		for k in range(per_side):
			out.append(a.lerp(b, float(k) / float(per_side)))
	return ensure_cw(out)


static func inset_poly(poly: Array, t: float) -> Array:
	var n: int = poly.size()
	var out: Array = []
	for i in range(n):
		var p: Vector2 = poly[i]
		var pm: Vector2 = poly[(i - 1 + n) % n]
		var pn: Vector2 = poly[(i + 1) % n]
		var d0: Vector2 = (p - pm).normalized()
		var d1: Vector2 = (pn - p).normalized()
		var n0 := Vector2(d0.y, -d0.x)
		var n1 := Vector2(d1.y, -d1.x)
		var bis: Vector2 = n0 + n1
		if bis.length_squared() < 1e-9:
			bis = n1
		bis = bis.normalized()
		var k: float = maxf(0.35, bis.dot(n1))
		out.append(p + bis * (t / k))
	return out


static func scale_poly(poly: Array, s: float) -> Array:
	var out: Array = []
	for p in poly:
		out.append(p * s)
	return out


static func rot_poly(poly: Array, ang: float) -> Array:
	var out: Array = []
	var c: float = cos(ang)
	var s: float = sin(ang)
	for p in poly:
		out.append(Vector2(p.x * c - p.y * s, p.x * s + p.y * c))
	return out


static func loop3(poly: Array, y: float, xf: Transform3D = Transform3D.IDENTITY) -> Array:
	var out: Array = []
	for p in poly:
		out.append(xf * Vector3(p.x, y, p.y))
	return out


# ===========================================================================
# Walls with real openings
# ===========================================================================
## A hollow wall between an outer and an inner loop, split into horizontal bands.
## `holes` maps "band_segment" -> true; a hole gets proper jambs, a sill where the band
## below is solid, and a soffit where the band above is solid. That is what makes a
## doorway read as a hole punched through 30 cm of clay rather than a painted rectangle.
static func wall_ring(
	k: Kit,
	key: String,
	outer: Array,
	inner: Array,
	levels: Array,
	holes: Dictionary,
	batter: float = 0.0,
	cap_top: bool = true,
	xf: Transform3D = Transform3D.IDENTITY
) -> void:
	var n: int = outer.size()
	var bands: int = levels.size() - 1
	var y0: float = levels[0]
	var y1: float = levels[levels.size() - 1]
	var ol: Array = []  # outer loops per level, tapered
	var il: Array = []
	for li in range(levels.size()):
		var t: float = (levels[li] - y0) / maxf(0.001, y1 - y0)
		ol.append(loop3(scale_poly(outer, 1.0 - batter * t), levels[li], xf))
		il.append(loop3(inner, levels[li], xf))
	for b in range(bands):
		for i in range(n):
			var j: int = (i + 1) % n
			var hkey := "%d_%d" % [b, i]
			if holes.has(hkey):
				# jamb on the i side, if the neighbour segment is solid
				var prev: int = (i - 1 + n) % n
				if not holes.has("%d_%d" % [b, prev]):
					k.quad(
						key,
						ol[b][i],
						il[b][i],
						il[b + 1][i],
						ol[b + 1][i],
						Vector2(0, 0),
						Vector2(0.4, 0),
						Vector2(0.4, levels[b + 1] - levels[b]),
						Vector2(0, levels[b + 1] - levels[b])
					)
				var nxt: int = (i + 1) % n
				if not holes.has("%d_%d" % [b, nxt]):
					k.quad(
						key,
						il[b][j],
						ol[b][j],
						ol[b + 1][j],
						il[b + 1][j],
						Vector2(0, 0),
						Vector2(0.4, 0),
						Vector2(0.4, levels[b + 1] - levels[b]),
						Vector2(0, levels[b + 1] - levels[b])
					)
				# soffit (top of the hole)
				if b + 1 < bands and not holes.has("%d_%d" % [b + 1, i]):
					k.quad(
						key,
						ol[b + 1][i],
						il[b + 1][i],
						il[b + 1][j],
						ol[b + 1][j],
						Vector2(ol[b + 1][i].x, ol[b + 1][i].z),
						Vector2(il[b + 1][i].x, il[b + 1][i].z),
						Vector2(il[b + 1][j].x, il[b + 1][j].z),
						Vector2(ol[b + 1][j].x, ol[b + 1][j].z)
					)
				# sill (bottom of the hole)
				if b > 0 and not holes.has("%d_%d" % [b - 1, i]):
					k.quad(
						key,
						ol[b][j],
						il[b][j],
						il[b][i],
						ol[b][i],
						Vector2(ol[b][j].x, ol[b][j].z),
						Vector2(il[b][j].x, il[b][j].z),
						Vector2(il[b][i].x, il[b][i].z),
						Vector2(ol[b][i].x, ol[b][i].z)
					)
				continue
			# outer face
			k.quad(
				key,
				ol[b][i],
				ol[b][j],
				ol[b + 1][j],
				ol[b + 1][i],
				Vector2(0, levels[b]),
				Vector2(ol[b][i].distance_to(ol[b][j]), levels[b]),
				Vector2(ol[b][i].distance_to(ol[b][j]), levels[b + 1]),
				Vector2(0, levels[b + 1])
			)
			# inner face
			k.quad(
				key,
				il[b][j],
				il[b][i],
				il[b + 1][i],
				il[b + 1][j],
				Vector2(0, levels[b]),
				Vector2(il[b][i].distance_to(il[b][j]), levels[b]),
				Vector2(il[b][i].distance_to(il[b][j]), levels[b + 1]),
				Vector2(0, levels[b + 1])
			)
	if cap_top:
		k.annulus(key, ol[bands], il[bands], true)


## Which segments of a loop fall inside an angular window centred on `dir`.
static func segs_facing(poly: Array, dir: float, half_angle: float) -> Array:
	var out: Array = []
	var n: int = poly.size()
	for i in range(n):
		var m: Vector2 = (poly[i] + poly[(i + 1) % n]) * 0.5
		var a: float = atan2(-m.y, m.x)
		var d: float = wrapf(a - dir, -PI, PI)
		if absf(d) <= half_angle:
			out.append(i)
	return out


# ===========================================================================
# Roofs
# ===========================================================================
## Conical thatch with a belled profile, a thick ragged eave and binding ropes.
static func thatch_cone(
	k: Kit, r_eave: float, eave_y: float, h: float, sides: int, rg: RandomNumberGenerator, xf: Transform3D = Transform3D.IDENTITY
) -> void:
	var steps := 5
	var rings: Array = []
	var jr: Array = []
	var jy: Array = []
	for i in range(sides):
		jr.append(rg.randf_range(-0.07, 0.07))
		jy.append(rg.randf_range(-0.06, 0.05))
	for si in range(steps + 1):
		var t: float = float(si) / float(steps)
		var rr: float = r_eave * pow(1.0 - t, 1.02)
		var yy: float = eave_y + h * t
		var ring: Array = []
		for i in range(sides):
			var th: float = TAU * float(i) / float(sides)
			var rj: float = rr + (jr[i] * (1.0 - t))
			var yj: float = yy + (jy[i] * (1.0 - t) if si == 0 else 0.0)
			ring.append(xf * Vector3(rj * cos(th), yj, -rj * sin(th)))
		rings.append(ring)
	# thick eave: a short skirt hanging below the eave line
	var skirt: Array = []
	for i in range(sides):
		var p: Vector3 = rings[0][i]
		var o: Vector3 = xf * Vector3.ZERO
		var rad: Vector3 = p - o
		rad.y = 0.0
		rad = rad.normalized()
		skirt.append(p + rad * 0.07 + Vector3(0, -0.30 - rg.randf_range(0.0, 0.10), 0))
	k.band("thatch", skirt, rings[0], 0.0)
	k.annulus("thatch", skirt, loop3(circle_poly(r_eave * 0.86, sides), eave_y - 0.34, xf), false)
	for si in range(steps):
		k.band("thatch", rings[si], rings[si + 1], 0.0)
	# apex bundle
	var apex_y: float = eave_y + h
	k.lathe(
		"thatch_fine",
		PackedVector2Array(
			[
				Vector2(r_eave * pow(1.0 / float(steps), 1.02) * 0.9, apex_y - 0.05),
				Vector2(0.20, apex_y + 0.10),
				Vector2(0.17, apex_y + 0.42),
				Vector2(0.26, apex_y + 0.50),
				Vector2(0.02, apex_y + 0.72)
			]
		),
		8,
		xf,
		false,
		false,
		true
	)
	# binding ropes
	for t in [0.24, 0.55]:
		var rr2: float = r_eave * pow(1.0 - t, 1.02)
		var yy2: float = eave_y + h * t
		var path: Array = []
		for i in range(sides + 1):
			var th2: float = TAU * float(i % sides) / float(sides)
			path.append(xf * Vector3(rr2 * cos(th2) * 1.02, yy2, -rr2 * sin(th2) * 1.02))
		k.tube("rope", path, 0.035, 4)


## Hipped thatch roof with a real ridge and a rolled ridge cap.
static func thatch_hip(
	k: Kit, hx: float, hz: float, eave_y: float, h: float, rg: RandomNumberGenerator, xf: Transform3D = Transform3D.IDENTITY
) -> void:
	var rz: float = hz * 0.44
	var top: float = eave_y + h
	var per := 5
	var base: Array = rect_poly(hx, hz, per)
	var n: int = base.size()
	# eave loop with a ragged edge, and the ridge point each eave point lofts to
	var eave: Array = []
	var ridge: Array = []
	for i in range(n):
		var p: Vector2 = base[i]
		eave.append(xf * Vector3(p.x, eave_y + rg.randf_range(-0.045, 0.035), p.y))
		ridge.append(xf * Vector3(0.0, top, clampf(p.y, -rz, rz)))
	var steps := 4
	var prev: Array = eave
	for si in range(steps):
		var u: float = float(si + 1) / float(steps)
		var cur: Array = []
		for i in range(n):
			cur.append(eave[i].lerp(ridge[i], u))
		k.band("thatch", prev, cur, 0.0)
		prev = cur
	# thick ragged eave
	var ctr: Vector3 = xf * Vector3(0, eave_y, 0)
	var skirt: Array = []
	for i in range(n):
		var rad: Vector3 = eave[i] - ctr
		rad.y = 0.0
		skirt.append(eave[i] + rad.normalized() * 0.06 + Vector3(0, -0.30 - rg.randf_range(0.0, 0.09), 0))
	k.band("thatch", skirt, eave, 0.0)
	var soffit: Array = []
	for i in range(n):
		soffit.append(xf * Vector3(base[i].x * 0.78, eave_y - 0.34, base[i].y * 0.78))
	k.annulus("clay_dark", skirt, soffit, false)
	k.cap("clay_dark", soffit, false)
	# ridge roll, clearly visible along the top
	var ra: Vector3 = xf * Vector3(0, top, -rz)
	var rb: Vector3 = xf * Vector3(0, top, rz)
	var rp: Array = []
	var ax: Vector3 = (rb - ra).normalized()
	for i in range(6):
		rp.append(ra.lerp(rb, float(i) / 5.0) + Vector3(0, 0.07, 0))
	rp[0] -= ax * 0.24
	rp[5] += ax * 0.24
	k.tube("thatch_fine", rp, 0.20, 7)
	for i in range(4):
		var t2: float = 0.14 + float(i) * 0.24
		var pp: Vector3 = ra.lerp(rb, t2) + Vector3(0, 0.07, 0)
		var side: Vector3 = ax.cross(Vector3.UP).normalized()
		k.tube("rope", [pp + side * 0.30 - Vector3(0, 0.18, 0), pp + Vector3(0, 0.26, 0), pp - side * 0.30 - Vector3(0, 0.18, 0)], 0.032, 4)


# ===========================================================================
# Village buildings
# ===========================================================================
## Village dwelling. Clay plinth, battered clay wall with a doorway, a window and a
## wooden lintel, and a thatch roof (conical on round huts, hipped with a ridge on
## square ones). The doorway always faces local +X so the caller can aim it.
static func hut(seed_i: int) -> Node3D:
	var rg := rng(seed_i)
	var k := Kit.new()
	var round_hut: bool = rg.randf() < 0.58
	var wall_h: float = rg.randf_range(2.35, 2.85)
	var thick: float = 0.32
	var door_h: float = 1.82
	var w0: float = 1.15
	var w1: float = 1.62
	var levels := [0.22, w0, w1, door_h, wall_h]
	var outer: Array
	var sides: int
	var r_ref: float
	if round_hut:
		var R: float = rg.randf_range(2.35, 3.05)
		sides = 20
		outer = circle_poly(R, sides, 0.035, rg)
		r_ref = R
	else:
		var hx: float = rg.randf_range(2.35, 3.05)
		var hz: float = hx * rg.randf_range(0.78, 1.0)
		sides = 20
		outer = rect_poly(hx, hz, 5)
		r_ref = maxf(hx, hz)
	outer = ensure_cw(outer)
	var inner: Array = inset_poly(outer, thick)
	# doorway on +X, window roughly opposite-ish
	var door_segs: Array = segs_facing(outer, 0.0, 0.10)
	if door_segs.is_empty():
		door_segs = [0]
	var win_dir: float = rg.randf_range(1.9, 2.6) * (1.0 if rg.randf() < 0.5 else -1.0)
	var win_segs: Array = segs_facing(outer, win_dir, 0.10)
	var holes: Dictionary = {}
	for s in door_segs:
		for b in range(3):
			holes["%d_%d" % [b, s]] = true
	for s in win_segs:
		holes["1_%d" % s] = true
	# plinth apron
	var apron: Array = inset_poly(outer, -0.34)
	k.band("clay", loop3(apron, -0.55), loop3(apron, 0.22), 0.0)
	k.annulus("clay", loop3(apron, 0.22), loop3(outer, 0.22), true)
	wall_ring(k, "clay", outer, inner, levels, holes, 0.035)
	# floor
	k.cap("clay_dark", loop3(inner, 0.22), true)
	# wooden lintel over the door, projecting past the jambs
	var dmid := Vector2.ZERO
	for s in door_segs:
		dmid += (outer[s] + outer[(s + 1) % sides]) * 0.5
	dmid /= float(door_segs.size())
	var dyaw: float = atan2(-dmid.y, dmid.x)
	var dw: float = 0.0
	for s in door_segs:
		dw += outer[s].distance_to(outer[(s + 1) % sides])
	var lin_xf := Transform3D(Basis(Vector3.UP, dyaw), Vector3(dmid.x * 0.99, door_h - 0.10, dmid.y * 0.99))
	k.box("wood", lin_xf, Vector3(thick + 0.20, 0.20, dw + 0.42))
	# threshold and step
	var dn := Vector3(cos(dyaw), 0.0, -sin(dyaw))
	var dxf := Transform3D(Basis(Vector3.UP, dyaw), Vector3(dmid.x, 0.0, dmid.y) + dn * 0.42)
	k.box("stone", Transform3D(dxf.basis, dxf.origin + Vector3(0, 0.11, 0)), Vector3(0.80, 0.44, dw + 0.30))
	k.box("stone", Transform3D(dxf.basis, dxf.origin + dn * 0.62 + Vector3(0, -0.06, 0)), Vector3(0.55, 0.30, dw + 0.60))
	# window frame
	if not win_segs.is_empty():
		var wmid: Vector2 = (outer[win_segs[0]] + outer[(win_segs[0] + 1) % sides]) * 0.5
		var wyaw: float = atan2(-wmid.y, wmid.x)
		var wxf := Transform3D(Basis(Vector3.UP, wyaw), Vector3(wmid.x, (w0 + w1) * 0.5, wmid.y))
		var ww: float = outer[win_segs[0]].distance_to(outer[(win_segs[0] + 1) % sides])
		k.box("wood", Transform3D(wxf.basis, wxf.origin + Vector3(0, (w1 - w0) * 0.5, 0)), Vector3(0.30, 0.10, ww + 0.16))
		k.box("wood", Transform3D(wxf.basis, wxf.origin - Vector3(0, (w1 - w0) * 0.5, 0)), Vector3(0.30, 0.10, ww + 0.16))
		var bxf := Transform3D(wxf.basis, wxf.origin - Vector3(0, 0.0, 0))
		for bi in range(2):
			var off: float = -0.16 + 0.32 * float(bi)
			k.box("wood", Transform3D(bxf.basis, bxf.origin + bxf.basis * Vector3(0, 0, off)), Vector3(0.22, w1 - w0, 0.06))
	# roof
	var eave_y: float = wall_h - 0.14
	var overhang: float = rg.randf_range(0.42, 0.62)
	var roof_h: float = rg.randf_range(2.30, 3.10)
	if round_hut:
		thatch_cone(k, r_ref + overhang, eave_y, roof_h, sides, rg)
	else:
		var hx2: float = 0.0
		var hz2: float = 0.0
		for p in outer:
			hx2 = maxf(hx2, absf(p.x))
			hz2 = maxf(hz2, absf(p.y))
		thatch_hip(k, hx2 + overhang, hz2 + overhang, eave_y, roof_h, rg)
	var mi := k.node("Hut")
	mi.rotate_y(rg.randf_range(-0.14, 0.14))
	return mi


## Raised grain store on stilts with a tiled terracotta cone and a leaning ladder.
static func granary(seed_i: int) -> Node3D:
	var rg := rng(seed_i)
	var k := Kit.new()
	var R: float = rg.randf_range(1.35, 1.8)
	var stilt: float = rg.randf_range(0.75, 1.05)
	var body: float = rg.randf_range(1.7, 2.1)
	var sides := 16
	# stone pad + stilts
	for i in range(5):
		var th: float = TAU * float(i) / 5.0 + 0.3
		var px: float = cos(th) * R * 0.68
		var pz: float = -sin(th) * R * 0.68
		k.box("stone", Transform3D(Basis.IDENTITY, Vector3(px, -0.35 + stilt * 0.14, pz)), Vector3(0.42, 0.9, 0.42))
		k.cyl("wood", Transform3D(Basis.IDENTITY, Vector3(px, stilt * 0.14, pz)), 0.11, 0.10, stilt * 0.86, 7)
	# floor slab
	var flo: Array = circle_poly(R + 0.16, sides)
	k.band("wood", loop3(flo, stilt), loop3(flo, stilt + 0.18), 0.0)
	k.cap("wood", loop3(flo, stilt + 0.18), true)
	k.cap("wood", loop3(flo, stilt), false)
	# clay body with a hatch
	var outer: Array = ensure_cw(circle_poly(R, sides, 0.02, rg))
	var inner: Array = inset_poly(outer, 0.22)
	var y0: float = stilt + 0.18
	var levels := [y0, y0 + body * 0.52, y0 + body * 0.86, y0 + body]
	var hatch: Array = segs_facing(outer, 0.0, 0.12)
	var holes: Dictionary = {}
	for s in hatch:
		holes["1_%d" % s] = true
	wall_ring(k, "clay", outer, inner, levels, holes, 0.05)
	k.cap("clay_dark", loop3(inner, y0 + 0.02), true)
	# terracotta tiled cone: stepped courses read as tile rows
	var eave: float = y0 + body - 0.10
	var rh: float = R * 1.15
	var courses := 6
	var prev: Array = circle_poly(R + 0.5, sides)
	var py: float = eave
	k.band("terracotta", loop3(prev, py - 0.16), loop3(prev, py), 0.0)
	k.annulus("terracotta", loop3(prev, py - 0.16), loop3(circle_poly(R * 0.8, sides), py - 0.18), false)
	for ci in range(courses):
		var t0: float = float(ci) / float(courses)
		var t1: float = float(ci + 1) / float(courses)
		var r0: float = (R + 0.5) * pow(1.0 - t0, 1.1)
		var r1: float = (R + 0.5) * pow(1.0 - t1, 1.1)
		var yA: float = eave + rh * t0
		var yB: float = eave + rh * t1
		var lo: Array = loop3(circle_poly(r0, sides), yA)
		var hi: Array = loop3(circle_poly(r1 * 1.10, sides), yB - 0.02)
		k.band("terracotta", lo, hi, 0.0)
		k.band("terracotta", hi, loop3(circle_poly(r1, sides), yB), 0.0)
	k.lathe(
		"terracotta",
		PackedVector2Array(
			[
				Vector2(0.16, eave + rh - 0.02),
				Vector2(0.20, eave + rh + 0.16),
				Vector2(0.10, eave + rh + 0.24),
				Vector2(0.02, eave + rh + 0.34)
			]
		),
		8,
		Transform3D.IDENTITY,
		false,
		false,
		true
	)
	# ladder
	var lx: float = R + 0.55
	var top := Vector3(R * 0.86, y0 + body * 0.60, 0.0)
	var bot := Vector3(lx + 0.55, 0.0, 0.0)
	for sgn in [-1.0, 1.0]:
		k.tube("wood", [bot + Vector3(0, 0, 0.20 * sgn), top + Vector3(0, 0, 0.18 * sgn)], 0.055, 6)
	for ri in range(5):
		var t: float = 0.12 + float(ri) * 0.20
		var p: Vector3 = bot.lerp(top, t)
		k.tube("wood", [p + Vector3(0, 0, -0.20), p + Vector3(0, 0, 0.20)], 0.038, 5)
	return k.node("Granary")


## Village well: a kerb of individually laid blocks, a windlass frame, rope and bucket.
static func well() -> Node3D:
	var k := Kit.new()
	var rg := rng(7717)
	var n := 16
	var r_out: float = 1.55
	var r_in: float = 1.02
	# apron
	k.annulus("stone", loop3(circle_poly(2.35, n), 0.06), loop3(circle_poly(r_out, n), 0.06), true)
	k.band("stone", loop3(circle_poly(2.35, n), -0.40), loop3(circle_poly(2.35, n), 0.06), 0.0)
	# kerb: separate blocks with visible joints
	for i in range(n):
		var a0: float = TAU * (float(i) + 0.06) / float(n)
		var a1: float = TAU * (float(i) + 0.94) / float(n)
		var h: float = 0.80 + rg.randf_range(-0.05, 0.05)
		var ro: float = r_out + rg.randf_range(-0.03, 0.03)
		var lo: Array = []
		var hi: Array = []
		var loi: Array = []
		var hii: Array = []
		for t in [a0, a1]:
			lo.append(Vector3(ro * cos(t), 0.06, -ro * sin(t)))
			hi.append(Vector3(ro * cos(t), h, -ro * sin(t)))
			loi.append(Vector3(r_in * cos(t), 0.06, -r_in * sin(t)))
			hii.append(Vector3(r_in * cos(t), h, -r_in * sin(t)))
		k.quadp("stone", lo[0], lo[1], hi[1], hi[0])
		k.quadp("stone", hii[0], hii[1], loi[1], loi[0])
		k.quadp("stone", hi[0], hi[1], hii[1], hii[0])
		k.quadp("stone", lo[1], lo[0], loi[0], loi[1])
		k.quadp("stone", hi[1], lo[1], loi[1], hii[1])
		k.quadp("stone", loi[0], lo[0], hi[0], hii[0])
	# shaft
	k.band("dark", loop3(circle_poly(r_in, n), -3.4), loop3(circle_poly(r_in, n), 0.06), 0.0)
	k.cap("dark", loop3(circle_poly(r_in, n), -3.4), true)
	# frame
	for sgn in [-1.0, 1.0]:
		k.box("wood", Transform3D(Basis.IDENTITY, Vector3(0.0, 1.15, sgn * 1.32)), Vector3(0.20, 2.30, 0.20))
		k.tube("wood", [Vector3(0.0, 2.06, sgn * 1.32), Vector3(sgn * 0.0, 1.0, sgn * 2.05)], 0.07, 6)
	k.box("wood", Transform3D(Basis.IDENTITY, Vector3(0.0, 2.34, 0.0)), Vector3(0.24, 0.20, 3.15))
	k.cyl("wood", Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, 2.10, -0.55)), 0.16, 0.16, 1.1, 12)
	k.cyl("wood", Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, 2.10, -0.62)), 0.24, 0.24, 0.06, 12)
	k.tube("wood", [Vector3(0.0, 2.10, 0.60), Vector3(0.30, 2.10, 0.60), Vector3(0.30, 1.80, 0.60)], 0.05, 6)
	# rope + bucket
	k.tube("rope", [Vector3(0.20, 2.06, -0.10), Vector3(0.20, 1.05, -0.10)], 0.026, 4)
	k.lathe(
		"wood",
		PackedVector2Array(
			[Vector2(0.0, 0.60), Vector2(0.19, 0.62), Vector2(0.21, 0.75), Vector2(0.25, 1.02), Vector2(0.245, 1.05), Vector2(0.20, 1.05)]
		),
		12,
		Transform3D(Basis.IDENTITY, Vector3(0.20, 0.0, -0.10)),
		false,
		false,
		false
	)
	k.tube("rope", [Vector3(0.02, 1.06, -0.10), Vector3(0.20, 1.22, -0.10), Vector3(0.38, 1.06, -0.10)], 0.022, 4)
	# a spare pot beside the kerb
	return k.node("Well")


# ===========================================================================
# Temple architecture
# ===========================================================================
## Latina (single-spire) nagara plan: a square with a central bhadra offset, a
## pratiratha step and a karna corner. Unit half-width 1.0, 48 points. The same
## outline runs from the sanctum wall all the way up the shikhara, which is what
## makes the tower read as a temple and not as a stepped pyramid.
static func plan_latina() -> Array:
	var q := [
		Vector2(1.00, 0.00),
		Vector2(1.00, 0.18),
		Vector2(1.00, 0.40),
		Vector2(0.90, 0.40),
		Vector2(0.90, 0.58),
		Vector2(0.74, 0.58),
		Vector2(0.74, 0.74),
		Vector2(0.58, 0.74),
		Vector2(0.58, 0.90),
		Vector2(0.40, 0.90),
		Vector2(0.40, 1.00),
		Vector2(0.18, 1.00),
	]
	var out: Array = []
	for rot in range(4):
		for p in q:
			var v: Vector2 = p
			for _r in range(rot):
				v = Vector2(-v.y, v.x)
			out.append(v)
	return ensure_cw(out)


## Ribbed amalaka cushion — the fluted disc that crowns a nagara spire.
static func amalaka(k: Kit, key: String, xf: Transform3D, r: float, h: float, lobes: int) -> void:
	var sides: int = lobes * 3
	var steps := 6
	var rings: Array = []
	for si in range(steps + 1):
		var u: float = float(si) / float(steps)
		var rr: float = r * (0.52 + 0.48 * sin(PI * clampf(u, 0.02, 0.98)))
		var ring: Array = []
		for i in range(sides):
			var th: float = TAU * float(i) / float(sides)
			var rm: float = rr * (1.0 + 0.14 * cos(float(lobes) * th))
			ring.append(xf * Vector3(rm * cos(th), h * u, -rm * sin(th)))
		rings.append(ring)
	for si in range(steps):
		k.band(key, rings[si], rings[si + 1], 0.0)
	k.cap(key, rings[0], false)
	k.cap(key, rings[steps], true)


## Carved pillar: square footing, octagonal then sixteen-sided shaft, lotus capital,
## abacus and corbel brackets.
## `suffix` selects the weathered pair ("_ruin") for pillars standing in the ruins, so a
## fragment abandoned for centuries is not brighter than the shrine still in use.
static func pillar(k: Kit, xf: Transform3D, h: float, cut: float = 1.0e9, suffix: String = "") -> void:
	var k_st: String = "stone" + suffix
	var k_cv: String = "carved" + suffix
	var o: Vector3 = xf.origin
	var b: Basis = xf.basis
	var at := func(y: float) -> Transform3D: return Transform3D(b, o + b * Vector3(0, y, 0))
	if 0.0 < cut:
		k.box(k_cv, at.call(0.11), Vector3(0.56, 0.22, 0.56))
	if 0.22 < cut:
		k.box(k_st, at.call(0.36), Vector3(0.48, 0.28, 0.48))
	var s0: float = 0.50
	var s1: float = s0 + (h - s0 - 0.86) * 0.46
	var s2: float = h - 0.86
	if s0 < cut:
		k.lathe(k_st, PackedVector2Array([Vector2(0.205, s0), Vector2(0.195, minf(s1, cut))]), 8, xf, false, false, false)
	if s1 < cut:
		k.lathe(
			k_cv,
			PackedVector2Array(
				[
					Vector2(0.20, s1),
					Vector2(0.225, minf(s1 + 0.07, cut)),
					Vector2(0.225, minf(s1 + 0.20, cut)),
					Vector2(0.19, minf(s1 + 0.27, cut))
				]
			),
			16,
			xf,
			false,
			false,
			false
		)
	if s1 + 0.27 < cut:
		k.lathe(k_st, PackedVector2Array([Vector2(0.185, s1 + 0.27), Vector2(0.168, minf(s2, cut))]), 16, xf, true, false, false)
	if s2 < cut:
		k.lathe(
			k_cv,
			PackedVector2Array(
				[
					Vector2(0.168, s2),
					Vector2(0.24, s2 + 0.10),
					Vector2(0.34, s2 + 0.26),
					Vector2(0.30, s2 + 0.36),
					Vector2(0.235, s2 + 0.46)
				]
			),
			16,
			xf,
			true,
			false,
			false
		)
	if h - 0.42 < cut:
		k.box(k_st, at.call(h - 0.32), Vector3(0.62, 0.20, 0.62))
		k.box(k_cv, at.call(h - 0.10), Vector3(0.52, 0.24, 0.52))
		for sgn in [-1.0, 1.0]:
			k.box(k_cv, Transform3D(b, o + b * Vector3(0, h - 0.14, sgn * 0.44)), Vector3(0.36, 0.30, 0.42))


## Stepped moulded course used all over the temple: a slab with a chamfered top edge.
static func course(k: Kit, key: String, y0: float, y1: float, hx: float, hz: float, ctr := Vector3.ZERO) -> void:
	k.box(key, Transform3D(Basis.IDENTITY, ctr + Vector3(0, (y0 + y1) * 0.5, 0)), Vector3(hx * 2.0, y1 - y0, hz * 2.0))


## THE hero building: a small north-Indian temple. Stepped moulded plinth, a pillared
## mandapa, a garbhagriha with a carved doorway, and a curvilinear latina shikhara of
## stacked inward-stepping courses rising to an amalaka and a brass kalasa.
## `foundation` is how far the plinth is extended downward into the knoll.
static func shrine(foundation: float = 2.6) -> Node3D:
	var k := Kit.new()
	var rg := rng(31337)
	var root := Node3D.new()
	root.name = "Shrine"

	# ---- plinth -----------------------------------------------------------
	var PX: float = 8.0
	var PZ: float = 6.5
	course(k, "stone", -1.85 - foundation, -1.85, PX + 0.10, PZ + 0.10)
	course(k, "stone", -1.85, -1.44, PX, PZ)
	course(k, "stone", -1.44, -1.10, PX - 0.42, PZ - 0.42)
	course(k, "carved", -1.10, -0.70, PX - 0.78, PZ - 0.78)
	course(k, "stone", -0.70, -0.50, PX - 0.58, PZ - 0.58)
	course(k, "carved", -0.50, -0.14, PX - 1.02, PZ - 1.02)
	course(k, "stone", -0.14, 0.0, PX - 0.60, PZ - 0.60)

	# ---- garbhagriha ------------------------------------------------------
	var plan := plan_latina()
	var w0: float = 2.95
	var cell := Vector3(-2.7, 0.0, 0.0)
	var cxf := Transform3D(Basis.IDENTITY, cell)
	var outer: Array = scale_poly(plan, w0)
	var inner: Array = scale_poly(plan, w0 * 0.60)
	var wall_top: float = 4.35
	var door_top: float = 2.70
	var levels := [0.0, door_top, wall_top]
	var door_segs: Array = segs_facing(outer, 0.0, 0.13)
	var holes: Dictionary = {}
	for s in door_segs:
		holes["0_%d" % s] = true
	wall_ring(k, "stone", outer, inner, levels, holes, 0.0, false, cxf)
	# base moulding and cornice on the cell
	k.band("carved", loop3(scale_poly(plan, w0 * 1.035), 0.0, cxf), loop3(scale_poly(plan, w0 * 1.035), 0.55, cxf), 0.0)
	k.annulus("carved", loop3(scale_poly(plan, w0 * 1.035), 0.55, cxf), loop3(outer, 0.55, cxf), true)
	k.band(
		"carved", loop3(scale_poly(plan, w0 * 1.045), wall_top - 0.52, cxf), loop3(scale_poly(plan, w0 * 1.045), wall_top - 0.14, cxf), 0.0
	)
	k.annulus("carved", loop3(scale_poly(plan, w0 * 1.045), wall_top - 0.14, cxf), loop3(outer, wall_top - 0.14, cxf), true)
	k.annulus("carved", loop3(scale_poly(plan, w0 * 1.045), wall_top - 0.52, cxf), loop3(outer, wall_top - 0.52, cxf), false)
	# sanctum floor, ceiling and the idol pedestal
	k.cap("dark", loop3(inner, 0.04, cxf), true)
	k.cap("dark", loop3(inner, wall_top, cxf), false)
	k.box("stone", Transform3D(Basis.IDENTITY, cell + Vector3(-0.5, 0.30, 0.0)), Vector3(1.5, 0.60, 1.5))
	k.lathe(
		"stone_fine",
		PackedVector2Array([Vector2(0.42, 0.60), Vector2(0.40, 1.05), Vector2(0.34, 1.25), Vector2(0.20, 1.38), Vector2(0.0, 1.42)]),
		12,
		Transform3D(Basis.IDENTITY, cell + Vector3(-0.5, 0.0, 0.0)),
		true,
		false,
		false
	)
	# carved door frame
	var dx: float = cell.x + w0 + 0.06
	for sgn in [-1.0, 1.0]:
		k.box("carved", Transform3D(Basis.IDENTITY, Vector3(dx, door_top * 0.5, sgn * 0.80)), Vector3(0.42, door_top + 0.10, 0.36))
		k.box("carved", Transform3D(Basis.IDENTITY, Vector3(dx + 0.12, door_top * 0.5, sgn * 1.04)), Vector3(0.22, door_top - 0.20, 0.22))
	k.box("carved", Transform3D(Basis.IDENTITY, Vector3(dx, door_top + 0.20, 0.0)), Vector3(0.46, 0.40, 2.30))
	k.box("carved", Transform3D(Basis.IDENTITY, Vector3(dx + 0.10, door_top + 0.62, 0.0)), Vector3(0.30, 0.44, 1.90))
	k.box("stone", Transform3D(Basis.IDENTITY, Vector3(dx + 0.10, 0.06, 0.0)), Vector3(0.70, 0.16, 1.60))

	# ---- shikhara ---------------------------------------------------------
	var s_base: float = wall_top - 0.14
	var s_h: float = 8.55
	var courses := 22
	var prev_loop: Array = loop3(scale_poly(plan, w0 * 1.02), s_base, cxf)
	for ci in range(courses):
		var t0: float = float(ci) / float(courses)
		var t1: float = float(ci + 1) / float(courses)
		var sc0: float = lerpf(1.02, 0.30, pow(t0, 1.95))
		var sc1: float = lerpf(1.02, 0.30, pow(t1, 1.95))
		var y0: float = s_base + s_h * t0
		var y1: float = s_base + s_h * t1
		var jit: float = rg.randf_range(-0.010, 0.010)
		var p0: Array = rot_poly(scale_poly(plan, w0 * sc0), jit)
		var p1: Array = rot_poly(scale_poly(plan, w0 * sc1), jit)
		var lo: Array = loop3(p0, y0, cxf)
		var hi: Array = loop3(p0, y1, cxf)
		k.band("stone" if ci % 3 else "carved", lo, hi, 0.0)
		k.annulus("stone", hi, loop3(p1, y1, cxf), true)
		prev_loop = loop3(p1, y1, cxf)
	# bhumi amalakas on the karna corners
	for lvl in [0.34, 0.63]:
		var sc: float = lerpf(1.02, 0.30, pow(lvl, 1.95)) * w0
		var yy: float = s_base + s_h * lvl
		var rr: float = 0.58 * (1.0 - lvl * 0.42)
		for qi in range(4):
			var ang: float = PI * 0.25 + PI * 0.5 * float(qi)
			var px: float = cos(ang) * sc * 0.86
			var pz: float = -sin(ang) * sc * 0.86
			amalaka(k, "stone", Transform3D(Basis.IDENTITY, cell + Vector3(px, yy, pz)), rr, rr * 0.78, 12)
	# griva, amalaka, kalasa
	var gy: float = s_base + s_h
	k.band("carved", loop3(scale_poly(plan, w0 * 0.30), gy, cxf), loop3(scale_poly(plan, w0 * 0.30), gy + 0.46, cxf), 0.0)
	k.annulus("carved", loop3(scale_poly(plan, w0 * 0.30), gy + 0.46, cxf), loop3(scale_poly(plan, w0 * 0.10), gy + 0.46, cxf), true)
	amalaka(k, "stone", Transform3D(Basis.IDENTITY, cell + Vector3(0, gy + 0.42, 0)), 1.30, 0.92, 16)
	k.box("stone", Transform3D(Basis.IDENTITY, cell + Vector3(0, gy + 1.44, 0)), Vector3(1.05, 0.22, 1.05))
	k.lathe(
		"brass",
		PackedVector2Array(
			[
				Vector2(0.34, gy + 1.55),
				Vector2(0.42, gy + 1.80),
				Vector2(0.30, gy + 2.05),
				Vector2(0.16, gy + 2.18),
				Vector2(0.20, gy + 2.32),
				Vector2(0.10, gy + 2.44),
				Vector2(0.06, gy + 2.85),
				Vector2(0.0, gy + 3.05)
			]
		),
		12,
		cxf,
		true,
		true,
		false
	)

	# ---- mandapa ----------------------------------------------------------
	var mp_h: float = 3.55
	var px_rows := [1.75, 5.05]
	var pz_rows := [-2.55, -0.85, 0.85, 2.55]
	for pxv in px_rows:
		for pzv in pz_rows:
			pillar(k, Transform3D(Basis.IDENTITY, Vector3(pxv, 0.0, pzv)), mp_h)
	# architraves
	for pxv in px_rows:
		k.box("stone", Transform3D(Basis.IDENTITY, Vector3(pxv, mp_h + 0.22, 0.0)), Vector3(0.50, 0.44, 5.95))
	for pzv in [-2.55, 2.55]:
		k.box("stone", Transform3D(Basis.IDENTITY, Vector3(3.40, mp_h + 0.22, pzv)), Vector3(3.90, 0.44, 0.50))
	# ceiling slab with a projecting cornice
	k.box("carved", Transform3D(Basis.IDENTITY, Vector3(3.40, mp_h + 0.56, 0.0)), Vector3(4.90, 0.28, 6.90))
	k.box("stone", Transform3D(Basis.IDENTITY, Vector3(3.40, mp_h + 0.80, 0.0)), Vector3(4.40, 0.24, 6.40))
	# samvarana: receding slabs to a small amalaka
	var sy: float = mp_h + 0.92
	for i in range(4):
		var f: float = 1.0 - float(i) * 0.19
		k.box(
			"stone" if i % 2 else "carved",
			Transform3D(Basis.IDENTITY, Vector3(3.40, sy + 0.28 * float(i), 0.0)),
			Vector3(4.10 * f, 0.32, 6.10 * f)
		)
	amalaka(k, "stone", Transform3D(Basis.IDENTITY, Vector3(3.40, sy + 1.16, 0.0)), 0.82, 0.60, 12)
	k.lathe(
		"brass",
		PackedVector2Array([Vector2(0.20, sy + 1.74), Vector2(0.26, sy + 1.92), Vector2(0.16, sy + 2.08), Vector2(0.05, sy + 2.24)]),
		10,
		Transform3D.IDENTITY,
		true,
		true,
		false
	)

	# ---- east steps with carved balustrades ------------------------------
	var st_top := Vector3(PX - 0.05, 0.0, 0.0)
	var st_foot := Vector3(PX + 3.4, -1.45, 0.0)
	steps_geom(k, st_top, st_foot, 4.0, 1.4, true)
	root.add_child(k.node("ShrineMesh"))

	# ---- lamps on the plinth ---------------------------------------------
	for lp in [Vector3(PX - 1.4, 0.0, -4.6), Vector3(PX - 1.4, 0.0, 4.6), Vector3(0.6, 0.0, -5.2), Vector3(0.6, 0.0, 5.2)]:
		var l := oil_lamp(true)
		l.position = lp
		root.add_child(l)
	return root


## Wayside shrine: a niche on a plinth with a small spire and a lamp.
static func shrine_small(seed_i: int = 0) -> Node3D:
	var k := Kit.new()
	var rg := rng(seed_i + 991)
	var root := Node3D.new()
	root.name = "WaysideShrine"
	var hx: float = 0.95
	var hz: float = 0.80
	course(k, "stone", -0.9, -0.30, hx + 0.22, hz + 0.22)
	course(k, "stone", -0.30, 0.0, hx + 0.08, hz + 0.08)
	course(k, "carved", 0.0, 0.24, hx, hz)
	# the shrine body with a recessed niche facing +X
	var bw: float = 0.66
	var bh: float = 1.30
	var ny: float = 0.24
	k.box("stone", Transform3D(Basis.IDENTITY, Vector3(-0.30, ny + bh * 0.5, 0.0)), Vector3(0.60, bh, hz * 1.7))
	for sgn in [-1.0, 1.0]:
		k.box("stone", Transform3D(Basis.IDENTITY, Vector3(0.15, ny + bh * 0.5, sgn * 0.46)), Vector3(0.90, bh, 0.42))
	k.box("carved", Transform3D(Basis.IDENTITY, Vector3(0.18, ny + bh - 0.16, 0.0)), Vector3(1.02, 0.32, hz * 1.7))
	k.box("dark", Transform3D(Basis.IDENTITY, Vector3(-0.02, ny + bh * 0.5 - 0.10, 0.0)), Vector3(0.55, bh - 0.5, 0.52))
	k.box("stone_fine", Transform3D(Basis.IDENTITY, Vector3(-0.06, ny + 0.28, 0.0)), Vector3(0.30, 0.34, 0.26))
	# small spire
	var sy: float = ny + bh - 0.03
	var plan := plan_latina()
	for i in range(7):
		var t0: float = float(i) / 7.0
		var t1: float = float(i + 1) / 7.0
		var s0: float = lerpf(0.50, 0.17, pow(t0, 1.8))
		var s1: float = lerpf(0.50, 0.17, pow(t1, 1.8))
		var y0: float = sy + 1.35 * t0
		var y1: float = sy + 1.35 * t1
		k.band("carved" if i % 2 else "stone", loop3(scale_poly(plan, s0), y0), loop3(scale_poly(plan, s0), y1), 0.0)
		k.annulus("stone", loop3(scale_poly(plan, s0), y1), loop3(scale_poly(plan, s1), y1), true)
	amalaka(k, "stone", Transform3D(Basis.IDENTITY, Vector3(0, sy + 1.35, 0)), 0.30, 0.22, 10)
	k.lathe(
		"brass",
		PackedVector2Array([Vector2(0.09, sy + 1.57), Vector2(0.13, sy + 1.70), Vector2(0.05, sy + 1.86)]),
		8,
		Transform3D.IDENTITY,
		true,
		true,
		false
	)
	root.add_child(k.node("WaysideMesh"))
	var l := oil_lamp(rg.randf() < 0.6)
	l.position = Vector3(hx - 0.22, 0.24, rg.randf_range(-0.3, 0.3))
	root.add_child(l)
	return root


## Torana gateway over a path: two posts, two architraves, carved scroll ends.
static func gate(seed_i: int = 0) -> Node3D:
	var k := Kit.new()
	var rg := rng(seed_i + 4242)
	var half: float = rg.randf_range(1.85, 2.15)
	var h: float = rg.randf_range(3.15, 3.55)
	for sgn in [-1.0, 1.0]:
		var z: float = sgn * half
		k.box("stone", Transform3D(Basis.IDENTITY, Vector3(0, -0.55, z)), Vector3(1.05, 1.30, 1.05))
		k.box("carved", Transform3D(Basis.IDENTITY, Vector3(0, 0.12, z)), Vector3(0.90, 0.34, 0.90))
		k.box("stone", Transform3D(Basis.IDENTITY, Vector3(0, (h * 0.5) + 0.29, z)), Vector3(0.62, h - 0.5, 0.62))
		k.box("carved", Transform3D(Basis.IDENTITY, Vector3(0, h * 0.42, z)), Vector3(0.68, 0.42, 0.68))
		k.box("carved", Transform3D(Basis.IDENTITY, Vector3(0, h - 0.10, z)), Vector3(0.82, 0.36, 0.82))
	var span: float = half * 2.0 + 1.6
	k.box("carved", Transform3D(Basis.IDENTITY, Vector3(0, h + 0.28, 0)), Vector3(0.52, 0.40, span))
	k.box("stone", Transform3D(Basis.IDENTITY, Vector3(0, h + 0.60, 0)), Vector3(0.40, 0.26, span - 0.5))
	k.box("carved", Transform3D(Basis.IDENTITY, Vector3(0, h + 0.94, 0)), Vector3(0.50, 0.40, span - 0.9))
	for sgn2 in [-1.0, 1.0]:
		k.lathe(
			"carved",
			PackedVector2Array([Vector2(0.05, h + 0.10), Vector2(0.22, h + 0.16), Vector2(0.24, h + 0.40), Vector2(0.05, h + 0.46)]),
			10,
			Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(0, 0, sgn2 * (span * 0.5 - 0.02))),
			false,
			false,
			false
		)
	amalaka(k, "stone", Transform3D(Basis.IDENTITY, Vector3(0, h + 1.14, 0)), 0.42, 0.32, 10)
	k.lathe(
		"brass",
		PackedVector2Array([Vector2(0.11, h + 1.46), Vector2(0.16, h + 1.62), Vector2(0.06, h + 1.82)]),
		8,
		Transform3D.IDENTITY,
		true,
		true,
		false
	)
	return k.node("Gate")


# ===========================================================================
# Steps, bridges, fences
# ===========================================================================
## Solid masonry stair between two points. Built as overlapping courses so the flight
## is a single mass with a base well below both ends — a stair on a slope can then
## never float, whatever the ground does between its feet.
static func steps_geom(k: Kit, a: Vector3, b: Vector3, width: float, base_drop: float, balustrade: bool = true) -> void:
	var lo: Vector3 = a if a.y <= b.y else b
	var hi: Vector3 = b if a.y <= b.y else a
	var flat := Vector3(hi.x - lo.x, 0.0, hi.z - lo.z)
	var run: float = flat.length()
	if run < 0.2:
		return
	var fwd: Vector3 = flat / run
	var side: Vector3 = fwd.cross(Vector3.UP).normalized()
	var rise: float = hi.y - lo.y
	var n: int = clampi(int(ceil(rise / 0.195)), 2, 44)
	var riser: float = rise / float(n)
	var tread: float = run / float(n)
	var bottom: float = lo.y - base_drop
	var bs := Basis(side, Vector3.UP, -fwd)
	for i in range(n):
		var d0: float = float(i) * tread
		var seg: float = run - d0
		var top: float = lo.y + riser * float(i + 1)
		# The mid-height is ABSOLUTE. Adding it to `lo` (which already carries a world
		# height) launched the knoll stair fifty metres into the sky and buried the
		# temple's own steps by the same amount, since both call this with real world Y.
		var c: Vector3 = lo + fwd * (d0 + seg * 0.5)
		c.y = (bottom + top) * 0.5
		k.box("stone", Transform3D(bs, c), Vector3(width, top - bottom, seg))
	if not balustrade:
		return
	var thick: float = 0.38
	var rail: float = 0.62
	for sgn in [-1.0, 1.0]:
		var off: Vector3 = side * (sgn * (width * 0.5 + thick * 0.5 - 0.02))
		var a0: Vector3 = lo + off - fwd * 0.10
		var b0: Vector3 = hi + off + fwd * 0.10
		# top edge follows the ramp; bottom edge is the flight's own base
		var pts := [a0 + Vector3(0, rail, 0), b0 + Vector3(0, rail + riser, 0), Vector3(b0.x, bottom, b0.z), Vector3(a0.x, bottom, a0.z)]
		var half: Vector3 = side * (thick * 0.5)
		var inn: Array = []
		var outn: Array = []
		for q in pts:
			inn.append(q - half)
			outn.append(q + half)
		k.quadp("carved", inn[3], inn[2], inn[1], inn[0])
		k.quadp("carved", outn[0], outn[1], outn[2], outn[3])
		k.quadp("carved", inn[0], inn[1], outn[1], outn[0])
		k.quadp("carved", outn[3], outn[2], inn[2], inn[3])
		k.quadp("carved", outn[0], outn[3], inn[3], inn[0])
		k.quadp("carved", inn[1], inn[2], outn[2], outn[1])
		# newel at the foot, sunk to the flight's own base so it can never float
		var ntop: float = a0.y + rail + 0.30
		k.box("stone", Transform3D(Basis.IDENTITY, Vector3(a0.x, (bottom + ntop) * 0.5, a0.z)), Vector3(0.56, ntop - bottom, 0.56))
		k.box("carved", Transform3D(Basis.IDENTITY, Vector3(a0.x, ntop + 0.16, a0.z)), Vector3(0.46, 0.32, 0.46))


## Carved stairway used on the shrine knoll.
static func stone_steps(from: Vector3, to: Vector3, width: float = 3.0) -> Node3D:
	var k := Kit.new()
	steps_geom(k, from, to, width, 1.6, true)
	return k.node("Steps")


## Timber footbridge with trestle piers and sagging rope handrails. Built along local
## +X, centred on the origin; the deck arcs up by `camber` at mid-span.
static func bridge(length: float, camber: float = 1.25, pier_depth: float = 7.0) -> Node3D:
	var k := Kit.new()
	var rg := rng(int(length * 13.0) + 55)
	var half: float = length * 0.5
	var w: float = 2.05
	var deck := func(x: float) -> float:
		var u: float = clampf(x / half, -1.0, 1.0)
		return camber * (1.0 - u * u)
	# stringers
	var segs: int = maxi(6, int(length / 1.6))
	for sgn in [-1.0, 1.0]:
		var path: Array = []
		for i in range(segs + 1):
			var x: float = -half + length * float(i) / float(segs)
			path.append(Vector3(x, deck.call(x) - 0.20, sgn * (w * 0.5 - 0.16)))
		for i in range(segs):
			var p0: Vector3 = path[i]
			var p1: Vector3 = path[i + 1]
			var c: Vector3 = (p0 + p1) * 0.5
			var d: Vector3 = p1 - p0
			var bb := Basis(Vector3.UP.cross(d.normalized()).normalized(), Vector3.UP, -d.normalized())
			k.box(
				"wood",
				Transform3D(bb, c),
				Vector3(0.26, 0.34, d.length() + 0.02),
				Vector2(rg.randf_range(0.0, 3.0), rg.randf_range(0.0, 3.0))
			)
	# Planks. Each gets its own uv offset: Kit UVs are in metres, so a 27 cm deck plank
	# samples a 27 cm band of wood_beam, and at offset zero every plank on the bridge
	# samples the SAME band - from underneath the deck read as one sheet of repeated
	# grain rather than as ninety separate boards.
	var np: int = int(length / 0.315)
	for i in range(np + 1):
		var x2: float = -half + length * float(i) / float(np)
		var y2: float = deck.call(x2)
		var dy: float = (deck.call(x2 + 0.2) - deck.call(x2 - 0.2)) / 0.4
		var bb2 := Basis(Vector3.UP, rg.randf_range(-0.012, 0.012)) * Basis(Vector3.FORWARD, 0.0)
		bb2 = bb2.rotated(Vector3.BACK, atan(dy))
		k.box(
			"wood",
			Transform3D(bb2, Vector3(x2, y2 + rg.randf_range(-0.012, 0.012), 0.0)),
			Vector3(0.27, 0.085, w + rg.randf_range(-0.06, 0.06)),
			Vector2(rg.randf_range(0.0, 3.0), rg.randf_range(0.0, 3.0))
		)
	# trestle piers
	var npier: int = maxi(1, int(round(length / 7.5)) - 1)
	for i in range(npier):
		var x3: float = -half + length * float(i + 1) / float(npier + 1)
		var y3: float = deck.call(x3) - 0.36
		for sgn2 in [-1.0, 1.0]:
			var topp := Vector3(x3, y3, sgn2 * (w * 0.5 - 0.20))
			var botp := Vector3(x3 + sgn2 * 0.0, y3 - pier_depth, sgn2 * (w * 0.5 + 0.75))
			k.tube("wood", [topp, botp], 0.14, 6)
		k.box("wood", Transform3D(Basis.IDENTITY, Vector3(x3, y3, 0.0)), Vector3(0.24, 0.24, w + 1.0))
		k.tube("wood", [Vector3(x3, y3 - 0.5, -w * 0.5 - 0.2), Vector3(x3, y3 - 1.7, w * 0.5 + 0.2)], 0.09, 5)
	# handrail posts + ropes
	var nr: int = maxi(2, int(length / 2.3))
	for sgn3 in [-1.0, 1.0]:
		var tops: Array = []
		for i in range(nr + 1):
			var x4: float = -half + length * float(i) / float(nr)
			var y4: float = deck.call(x4)
			var pz: float = sgn3 * (w * 0.5 - 0.10)
			k.box(
				"wood", Transform3D(Basis(Vector3.UP, rg.randf_range(-0.05, 0.05)), Vector3(x4, y4 + 0.47, pz)), Vector3(0.13, 1.02, 0.13)
			)
			tops.append(Vector3(x4, y4 + 0.92, pz))
		for level in [0.0, -0.34]:
			var rope: Array = []
			for i in range(nr):
				for s in range(3):
					var t: float = float(s) / 3.0
					var p: Vector3 = tops[i].lerp(tops[i + 1], t) + Vector3(0, level, 0)
					p.y -= sin(t * PI) * 0.10
					rope.append(p)
			rope.append(tops[nr] + Vector3(0, level, 0))
			k.tube("rope", rope, 0.035, 4)
	# abutments
	for sgn4 in [-1.0, 1.0]:
		k.box("stone", Transform3D(Basis.IDENTITY, Vector3(sgn4 * (half + 0.45), -2.6, 0.0)), Vector3(1.4, 6.0, w + 0.9))
	return k.node("Bridge")


## Woven bamboo fencing following a polyline of ground-level points.
static func fence(points: Array, height: float = 1.15, seed_i: int = 0) -> Node3D:
	if points.size() < 2:
		return Node3D.new()
	var k := Kit.new()
	var rg := rng(seed_i + 313)
	# resample the polyline at even spacing so posts are evenly spread
	var dense: Array = []
	for i in range(points.size() - 1):
		var a: Vector3 = points[i]
		var b: Vector3 = points[i + 1]
		var d: float = a.distance_to(b)
		var n: int = maxi(1, int(round(d / 1.45)))
		for s in range(n):
			dense.append(a.lerp(b, float(s) / float(n)))
	dense.append(points[points.size() - 1])
	for p in dense:
		var lean := Vector3(rg.randf_range(-0.05, 0.05), 1.0, rg.randf_range(-0.05, 0.05)).normalized()
		var h: float = height * rg.randf_range(0.9, 1.08)
		k.tube("wood", [p - Vector3(0, 0.45, 0), p + lean * h], 0.055, 6)
	for lvl in [0.32, 0.62, 0.92]:
		var wob: Array = []
		for i in range(dense.size()):
			var p2: Vector3 = dense[i]
			var fwd: Vector3
			if i == 0:
				fwd = dense[1] - dense[0]
			elif i == dense.size() - 1:
				fwd = dense[i] - dense[i - 1]
			else:
				fwd = dense[i + 1] - dense[i - 1]
			fwd.y = 0.0
			var side: Vector3 = fwd.normalized().cross(Vector3.UP).normalized()
			var sgn: float = 1.0 if i % 2 == 0 else -1.0
			wob.append(p2 + Vector3(0, height * lvl, 0) + side * 0.055 * sgn)
			if i < dense.size() - 1:
				var mid: Vector3 = (dense[i] + dense[i + 1]) * 0.5
				wob.append(mid + Vector3(0, height * lvl + rg.randf_range(-0.02, 0.02), 0) - side * 0.055 * sgn)
		k.tube("wood", wob, 0.032, 5)
	return k.node("Fence")


## Earth bund: the low ridge that walls a paddy plot. Points are ground level.
static func bund(points: Array, base_w: float = 0.95, top_w: float = 0.45, height: float = 0.34) -> Node3D:
	if points.size() < 2:
		return Node3D.new()
	var k := Kit.new()
	var n: int = points.size()
	var lo_l: Array = []
	var lo_r: Array = []
	var hi_l: Array = []
	var hi_r: Array = []
	for i in range(n):
		var fwd: Vector3
		if i == 0:
			fwd = points[1] - points[0]
		elif i == n - 1:
			fwd = points[i] - points[i - 1]
		else:
			fwd = points[i + 1] - points[i - 1]
		fwd.y = 0.0
		var s: Vector3 = fwd.normalized().cross(Vector3.UP).normalized()
		lo_l.append(points[i] - s * base_w * 0.5 - Vector3(0, 0.14, 0))
		lo_r.append(points[i] + s * base_w * 0.5 - Vector3(0, 0.14, 0))
		hi_l.append(points[i] - s * top_w * 0.5 + Vector3(0, height, 0))
		hi_r.append(points[i] + s * top_w * 0.5 + Vector3(0, height, 0))
	# Winding runs ACROSS the ridge first: going along it first put every normal
	# under the ground and the whole paddy read as black lines from above.
	for i in range(n - 1):
		k.quadp("dirt", lo_l[i], hi_l[i], hi_l[i + 1], lo_l[i + 1])
		k.quadp("dirt", hi_l[i], hi_r[i], hi_r[i + 1], hi_l[i + 1])
		k.quadp("dirt", hi_r[i], lo_r[i], lo_r[i + 1], hi_r[i + 1])
	k.quadp("dirt", lo_r[0], hi_r[0], hi_l[0], lo_l[0])
	k.quadp("dirt", lo_l[n - 1], hi_l[n - 1], hi_r[n - 1], lo_r[n - 1])
	return k.node("Bund")


# ===========================================================================
# Ruins
# ===========================================================================
## An eroded section of wall: brick courses with a jagged broken crest, a stone base
## course, and enough height below zero that the caller can sink it into the ground.
static func ruin_wall(seed_i: int) -> Node3D:
	var k := Kit.new()
	var rg := rng(seed_i + 8081)
	var length: float = rg.randf_range(3.4, 7.5)
	var thick: float = rg.randf_range(0.70, 1.05)
	var hmax: float = rg.randf_range(1.6, 3.4)
	var bw: float = 0.78
	var cols: int = maxi(4, int(length / bw))
	var lean: float = rg.randf_range(-0.045, 0.045)
	var xf0 := Transform3D(Basis(Vector3.BACK, lean), Vector3.ZERO)
	# dressed stone footing, half swallowed by the ground
	k.box("stone", xf0 * Transform3D(Basis.IDENTITY, Vector3(0, -0.62, 0)), Vector3(length + 0.4, 1.7, thick + 0.30))
	var ph: float = rg.randf_range(0.0, 6.0)
	var fall: float = 1.0 if rg.randf() < 0.5 else -1.0
	for c in range(cols):
		var w: float = length / float(cols)
		var x: float = -length * 0.5 + w * (float(c) + 0.5)
		var t: float = float(c) / float(maxi(1, cols - 1))
		var tt: float = t if fall > 0.0 else 1.0 - t
		# crest: collapsed at one end, ragged everywhere
		var prof: float = 0.10 + 0.90 * pow(tt, 0.75)
		prof += 0.22 * sin(ph + tt * 5.3) + 0.13 * sin(ph * 1.7 + tt * 11.0)
		var h: float = hmax * clampf(prof, 0.06, 1.05)
		var courses: int = maxi(1, int(h / 0.31))
		for r in range(courses):
			if rg.randf() < 0.09 and r > 0:
				continue
			var y0: float = 0.14 + float(r) * 0.31
			var jx: float = rg.randf_range(-0.05, 0.05)
			var jz: float = rg.randf_range(-0.07, 0.07)
			var key: String = "stone" if (r == 0 or rg.randf() < 0.12) else "brick"
			k.box(
				key,
				xf0 * Transform3D(Basis(Vector3.UP, rg.randf_range(-0.045, 0.045)), Vector3(x + jx, y0 + 0.155, jz)),
				Vector3(w * 0.97, 0.30, thick + rg.randf_range(-0.10, 0.07)),
				Vector2(x * 0.8, y0 * 0.8)
			)
	# rubble spilled at the foot on the collapsed side
	for i in range(7):
		var bx: float = rg.randf_range(-length * 0.5, length * 0.5)
		var bz: float = (thick * 0.5 + rg.randf_range(0.20, 1.5)) * (1.0 if rg.randf() < 0.5 else -1.0)
		k.box(
			"brick",
			Transform3D(
				Basis(Vector3(rg.randf_range(-1, 1), rg.randf_range(-1, 1), rg.randf_range(-1, 1)).normalized(), rg.randf_range(0.0, 1.4)),
				Vector3(bx, rg.randf_range(-0.04, 0.09), bz)
			),
			Vector3(0.60, 0.28, 0.38),
			Vector2(rg.randf_range(0, 3), rg.randf_range(0, 3))
		)
	return k.node("RuinWall")


## A temple pillar snapped off at a jagged height. Built as a real carved pillar so the
## fragment reads as part of the same order as the shrine.
static func broken_pillar(seed_i: int) -> Node3D:
	var k := Kit.new()
	var rg := rng(seed_i + 6161)
	var full: float = rg.randf_range(3.4, 4.6)
	# The surviving fragment. At 0.22 of a shaft these were knee-high stubs that read as
	# burnt fence posts from any distance; a ruined hall is legible because some of its
	# columns are still most of the way up.
	var h: float = full * rg.randf_range(0.34, 0.95)
	pillar(k, Transform3D(Basis.IDENTITY, Vector3(0, -0.30, 0)), full, h + 0.30, "_ruin")
	# fracture: a rough tilted cap where the shaft snapped
	var n := 7
	var bot: Array = []
	var top: Array = []
	var tilt := Vector3(rg.randf_range(-0.10, 0.10), 0.0, rg.randf_range(-0.10, 0.10))
	for i in range(n):
		var th: float = TAU * float(i) / float(n)
		var r: float = 0.175 + rg.randf_range(-0.03, 0.03)
		var px: float = r * cos(th)
		var pz: float = -r * sin(th)
		bot.append(Vector3(px, h - 0.14, pz))
		top.append(Vector3(px * 0.94, h + tilt.x * px + tilt.z * pz + rg.randf_range(-0.06, 0.09), pz * 0.94))
	k.band("stone_ruin", bot, top, 0.0)
	k.cap("stone_ruin", top, true)
	# the piece that fell, lying beside it
	if rg.randf() < 0.7:
		var seg: float = rg.randf_range(0.9, 2.0)
		var ang: float = rg.randf_range(0.0, TAU)
		var d: float = rg.randf_range(0.9, 2.2)
		k.lathe(
			"stone_ruin",
			PackedVector2Array([Vector2(0.20, -seg * 0.5), Vector2(0.185, seg * 0.5)]),
			8,
			Transform3D(Basis(Vector3.UP, ang) * Basis(Vector3.BACK, PI * 0.5), Vector3(cos(ang) * d, 0.20, -sin(ang) * d)),
			false,
			true,
			true
		)
	return k.node("BrokenPillar")


## A carved lintel or architrave lying where it fell, cracked into two pieces.
static func fallen_lintel(seed_i: int) -> Node3D:
	var k := Kit.new()
	var rg := rng(seed_i + 5151)
	var total: float = rg.randf_range(2.6, 4.4)
	var a: float = total * rg.randf_range(0.42, 0.6)
	var b: float = total - a - rg.randf_range(0.05, 0.30)
	var sec: float = rg.randf_range(0.56, 0.78)
	k.box(
		"carved_ruin",
		Transform3D(
			Basis(Vector3.UP, rg.randf_range(-0.06, 0.06)).rotated(Vector3.BACK, rg.randf_range(-0.10, 0.10)),
			Vector3(-total * 0.5 + a * 0.5, sec * 0.42, 0.0)
		),
		Vector3(a, sec, sec * 1.15)
	)
	k.box(
		"carved_ruin",
		Transform3D(
			Basis(Vector3.UP, rg.randf_range(0.05, 0.22)).rotated(Vector3.BACK, rg.randf_range(-0.14, 0.14)),
			Vector3(total * 0.5 - b * 0.5, sec * 0.40, rg.randf_range(-0.25, 0.25))
		),
		Vector3(b, sec, sec * 1.15)
	)
	k.box(
		"stone_ruin",
		Transform3D(Basis(Vector3.UP, rg.randf_range(0, TAU)), Vector3(rg.randf_range(-0.6, 0.6), sec * 0.2, rg.randf_range(0.5, 1.1))),
		Vector3(0.44, 0.22, 0.36)
	)
	return k.node("FallenLintel")


## An irregular cut stone block, for MultiMesh rubble scatter.
static func stone_block_mesh(seed_i: int) -> ArrayMesh:
	var k := Kit.new()
	var rg := rng(seed_i + 4004)
	var n := 6
	var lo: Array = []
	var hi: Array = []
	var h: float = rg.randf_range(0.22, 0.42)
	for i in range(n):
		var th: float = TAU * float(i) / float(n)
		var r: float = rg.randf_range(0.30, 0.55)
		lo.append(Vector3(r * cos(th), 0.0, -r * sin(th)))
		var r2: float = r * rg.randf_range(0.72, 0.95)
		hi.append(Vector3(r2 * cos(th), h + rg.randf_range(-0.05, 0.05), -r2 * sin(th)))
	k.band("stone_ruin", lo, hi, 0.0)
	k.cap("stone_ruin", hi, true)
	k.cap("stone_ruin", lo, false)
	return k.commit()


# ===========================================================================
# Props
# ===========================================================================
## Terracotta water pot (matka).
static func water_pot_mesh(seed_i: int) -> ArrayMesh:
	var k := Kit.new()
	var rg := rng(seed_i + 2020)
	var s: float = rg.randf_range(0.58, 0.88)
	var prof := PackedVector2Array(
		[
			Vector2(0.0, 0.0),
			Vector2(0.10, 0.0),
			Vector2(0.13, 0.04),
			Vector2(0.21, 0.14),
			Vector2(0.255, 0.28),
			Vector2(0.24, 0.40),
			Vector2(0.165, 0.49),
			Vector2(0.135, 0.54),
			Vector2(0.165, 0.585),
			Vector2(0.145, 0.60),
			Vector2(0.115, 0.55)
		]
	)
	var sp := PackedVector2Array()
	for p in prof:
		sp.append(p * s)
	k.lathe("pot", sp, 14, Transform3D.IDENTITY, true, false, false)
	return k.commit()


static func water_pot(seed_i: int = 0) -> Node3D:
	var mi := MeshInstance3D.new()
	mi.name = "Pot"
	mi.mesh = water_pot_mesh(seed_i)
	return mi


## Woven cane basket.
static func basket_mesh(seed_i: int) -> ArrayMesh:
	var k := Kit.new()
	var rg := rng(seed_i + 3030)
	var r0: float = rg.randf_range(0.17, 0.26)
	var r1: float = r0 * rg.randf_range(1.15, 1.4)
	var h: float = rg.randf_range(0.24, 0.38)
	k.lathe(
		"cane",
		PackedVector2Array(
			[
				Vector2(r0 * 0.5, 0.0),
				Vector2(r0, 0.03),
				Vector2(r1, h),
				Vector2(r1 * 1.05, h + 0.045),
				Vector2(r1 * 0.93, h + 0.05),
				Vector2(r1 * 0.90, h - 0.02)
			]
		),
		14,
		Transform3D.IDENTITY,
		true,
		true,
		false
	)
	k.cap("cane", loop3(circle_poly(r1 * 0.9, 14), h - 0.05), true)
	if rg.randf() < 0.45:
		k.lathe(
			"cloth_w",
			PackedVector2Array([Vector2(0.0, h - 0.02), Vector2(r1 * 0.86, h + 0.02)]),
			12,
			Transform3D.IDENTITY,
			false,
			false,
			false
		)
	return k.commit()


static func basket(seed_i: int = 0) -> Node3D:
	var mi := MeshInstance3D.new()
	mi.name = "Basket"
	mi.mesh = basket_mesh(seed_i)
	return mi


## Bullock cart: spoked wheels, a plank bed with side rails, shafts and a yoke.
static func cart(seed_i: int = 0) -> Node3D:
	var k := Kit.new()
	var rg := rng(seed_i + 1212)
	var wr: float = 0.62
	var track: float = 0.78
	var bed_y: float = 0.72
	for sgn in [-1.0, 1.0]:
		var wxf := Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, wr, sgn * track))
		# rim
		k.lathe(
			"wood",
			PackedVector2Array([Vector2(wr - 0.09, -0.055), Vector2(wr, -0.055), Vector2(wr, 0.055), Vector2(wr - 0.09, 0.055)]),
			16,
			wxf,
			false,
			false,
			false
		)
		k.lathe("wood", PackedVector2Array([Vector2(wr - 0.09, -0.055), Vector2(wr - 0.09, 0.055)]), 16, wxf, false, false, false)
		# hub
		k.lathe(
			"wood",
			PackedVector2Array([Vector2(0.0, -0.12), Vector2(0.12, -0.12), Vector2(0.14, 0.0), Vector2(0.12, 0.12), Vector2(0.0, 0.12)]),
			10,
			wxf,
			true,
			false,
			false
		)
		for i in range(8):
			var th: float = TAU * float(i) / 8.0 + 0.2
			var a: Vector3 = wxf * Vector3(0.11 * cos(th), 0.0, -0.11 * sin(th))
			var b: Vector3 = wxf * Vector3((wr - 0.08) * cos(th), 0.0, -(wr - 0.08) * sin(th))
			k.tube("wood", [a, b], 0.035, 5)
	k.cyl("wood", Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, wr, -track - 0.06)), 0.065, 0.065, track * 2.0 + 0.12, 8)
	# Bed. Every plank needs its OWN uv offset: Kit UVs are in metres, so a 2.5 x 0.165 m
	# plank samples a 16 cm band of wood_beam, and with all nine planks at offset zero
	# they sampled the SAME band - the cart bed rendered as one two-metre slab of a single
	# knot instead of as nine boards.
	for i in range(9):
		var z: float = -0.72 + 0.18 * float(i)
		k.box(
			"wood",
			Transform3D(Basis(Vector3.UP, rg.randf_range(-0.01, 0.01)), Vector3(0.05, bed_y, z)),
			Vector3(2.5, 0.07, 0.165),
			Vector2(rg.randf_range(0.0, 3.0), rg.randf_range(0.0, 3.0))
		)
	for sgn2 in [-1.0, 1.0]:
		k.box(
			"wood",
			Transform3D(Basis.IDENTITY, Vector3(0.05, bed_y - 0.09, sgn2 * 0.70)),
			Vector3(2.5, 0.14, 0.13),
			Vector2(rg.randf_range(0.0, 3.0), rg.randf_range(0.0, 3.0))
		)
		for i in range(5):
			var x: float = -1.0 + 0.55 * float(i)
			k.tube("wood", [Vector3(x, bed_y, sgn2 * 0.70), Vector3(x, bed_y + 0.46, sgn2 * 0.76)], 0.042, 5)
		k.tube("wood", [Vector3(-1.05, bed_y + 0.46, sgn2 * 0.76), Vector3(1.15, bed_y + 0.46, sgn2 * 0.76)], 0.05, 5)
	k.box("wood", Transform3D(Basis.IDENTITY, Vector3(-1.24, bed_y + 0.24, 0.0)), Vector3(0.10, 0.52, 1.5))
	# shafts down to the ground and a yoke
	for sgn3 in [-1.0, 1.0]:
		k.tube("wood", [Vector3(0.9, bed_y - 0.06, sgn3 * 0.42), Vector3(2.9, 0.30, sgn3 * 0.34)], 0.06, 6)
	k.tube("wood", [Vector3(2.85, 0.32, -0.62), Vector3(2.92, 0.36, 0.62)], 0.07, 6)
	return k.node("Cart")


## Pole rack for drying grain, chillies and cloth.
static func drying_rack(seed_i: int = 0) -> Node3D:
	var k := Kit.new()
	var rg := rng(seed_i + 7070)
	var L: float = rg.randf_range(2.2, 3.4)
	var h: float = rg.randf_range(1.35, 1.75)
	for sgn in [-1.0, 1.0]:
		var x: float = sgn * L * 0.5
		k.tube("wood", [Vector3(x, -0.25, -0.42), Vector3(x + rg.randf_range(-0.06, 0.06), h, 0.0)], 0.055, 6)
		k.tube("wood", [Vector3(x, -0.25, 0.42), Vector3(x + rg.randf_range(-0.06, 0.06), h, 0.0)], 0.055, 6)
	k.tube("wood", [Vector3(-L * 0.5 - 0.2, h - 0.03, 0.0), Vector3(L * 0.5 + 0.2, h - 0.03, 0.0)], 0.05, 6)
	k.tube("wood", [Vector3(-L * 0.5 - 0.1, h * 0.55, -0.2), Vector3(L * 0.5 + 0.1, h * 0.55, -0.2)], 0.04, 5)
	# hanging cloth panels
	var cols := ["cloth_s", "cloth_i", "cloth_w"]
	var np: int = rg.randi_range(2, 4)
	for i in range(np):
		var t: float = (float(i) + 0.5) / float(np)
		var cx: float = lerpf(-L * 0.42, L * 0.42, t)
		var cw: float = rg.randf_range(0.42, 0.72)
		var ch: float = rg.randf_range(0.55, 1.05)
		var key: String = cols[rg.randi() % 3]
		var segs := 4
		for s in range(segs):
			var u0: float = float(s) / float(segs)
			var u1: float = float(s + 1) / float(segs)
			var z0: float = -0.02 + sin(u0 * PI) * 0.045
			var z1: float = -0.02 + sin(u1 * PI) * 0.045
			k.quadp(
				key,
				Vector3(cx - cw * 0.5 + cw * u0, h - 0.05, z0),
				Vector3(cx - cw * 0.5 + cw * u1, h - 0.05, z1),
				Vector3(cx - cw * 0.5 + cw * u1, h - 0.05 - ch, z1 * 1.15),
				Vector3(cx - cw * 0.5 + cw * u0, h - 0.05 - ch, z0 * 1.15)
			)
	return k.node("DryingRack")


## Two posts and a sagging line of washing.
static func washing_line(seed_i: int = 0, span: float = 4.5) -> Node3D:
	var k := Kit.new()
	var rg := rng(seed_i + 9090)
	var h: float = rg.randf_range(1.75, 2.05)
	for sgn in [-1.0, 1.0]:
		k.tube("wood", [Vector3(sgn * span * 0.5, -0.35, 0), Vector3(sgn * span * 0.5 + rg.randf_range(-0.08, 0.08), h, 0)], 0.065, 6)
		k.tube("wood", [Vector3(sgn * span * 0.5, h - 0.5, 0), Vector3(sgn * (span * 0.5 + 0.55), -0.25, 0)], 0.04, 5)
	var line: Array = []
	for i in range(13):
		var t: float = float(i) / 12.0
		line.append(Vector3(lerpf(-span * 0.5, span * 0.5, t), h - 0.06 - sin(t * PI) * 0.16, 0.0))
	k.tube("rope", line, 0.024, 4)
	var cols := ["cloth_s", "cloth_i", "cloth_w"]
	for i in range(rg.randi_range(3, 5)):
		var t2: float = rg.randf_range(0.14, 0.86)
		var idx: int = int(t2 * 12.0)
		var p: Vector3 = line[idx]
		var cw: float = rg.randf_range(0.5, 0.9)
		var ch: float = rg.randf_range(0.7, 1.3)
		var key: String = cols[rg.randi() % 3]
		var segs := 4
		for s in range(segs):
			var u0: float = float(s) / float(segs)
			var u1: float = float(s + 1) / float(segs)
			var w0: float = sin(u0 * PI) * 0.05
			var w1: float = sin(u1 * PI) * 0.05
			k.quadp(
				key,
				Vector3(p.x - cw * 0.5 + cw * u0, p.y, w0),
				Vector3(p.x - cw * 0.5 + cw * u1, p.y, w1),
				Vector3(p.x - cw * 0.5 + cw * u1, p.y - ch, w1 * 1.8),
				Vector3(p.x - cw * 0.5 + cw * u0, p.y - ch, w0 * 1.8)
			)
	return k.node("WashingLine")


## Stone-ringed firepit with ash, charred logs and a cooking tripod.
static func firepit(seed_i: int = 0, tripod: bool = true) -> Node3D:
	var k := Kit.new()
	var rg := rng(seed_i + 6060)
	var R: float = rg.randf_range(0.78, 1.02)
	var n: int = rg.randi_range(8, 11)
	# a ring of rounded field stones, each one a little dome, sunk into the ground
	for i in range(n):
		var th: float = TAU * float(i) / float(n) + rg.randf_range(-0.12, 0.12)
		var r: float = R + rg.randf_range(-0.05, 0.06)
		var cx: float = r * cos(th)
		var cz: float = -r * sin(th)
		var sh: float = rg.randf_range(0.20, 0.34)
		var m: int = 6
		var rings: Array = []
		var rr: Array = []
		for j in range(m):
			rr.append(rg.randf_range(0.17, 0.27))
		for li in range(3):
			var u: float = float(li) / 2.0
			var ring: Array = []
			for j in range(m):
				var t2: float = TAU * float(j) / float(m)
				var rad: float = rr[j] * (1.0 - u * u * 0.55)
				ring.append(Vector3(cx + rad * cos(t2), -0.16 + sh * (u * 1.12), cz - rad * sin(t2)))
			rings.append(ring)
		k.band("stone", rings[0], rings[1], 0.0)
		k.band("stone", rings[1], rings[2], 0.0)
		k.cap("stone", rings[2], true)
	# a dished bed of ash sitting proud of the ground, ringed with charcoal
	k.lathe(
		"ash",
		PackedVector2Array([Vector2(0.0, 0.015), Vector2(R * 0.45, 0.005), Vector2(R * 0.78, 0.045), Vector2(R * 0.90, 0.09)]),
		14,
		Transform3D.IDENTITY,
		true,
		false,
		false
	)
	# burnt logs lying across the bed, not radiating from the middle like a star
	for i in range(4):
		var th2: float = rg.randf_range(0.0, PI)
		var off: float = rg.randf_range(-0.30, 0.30) * R
		var l: float = rg.randf_range(0.30, 0.46) * R * 2.0
		var dir := Vector3(cos(th2), 0.0, -sin(th2))
		var per := Vector3(-dir.z, 0.0, dir.x)
		var y: float = 0.08 + float(i) * 0.045
		var a: Vector3 = per * off + dir * (-l * 0.5) + Vector3(0, y, 0)
		var b: Vector3 = per * off + dir * (l * 0.5) + Vector3(0, y + rg.randf_range(-0.03, 0.03), 0)
		k.tube("char", [a, b], rg.randf_range(0.048, 0.072), 5)
	if tripod:
		var apex := Vector3(0.0, R * 1.75, 0.0)
		for i in range(3):
			var th3: float = TAU * float(i) / 3.0 + 0.4
			k.tube("wood", [Vector3(cos(th3) * R * 1.15, -0.10, -sin(th3) * R * 1.15), apex], 0.055, 5)
		k.tube("rope", [apex, apex - Vector3(0, 0.34, 0)], 0.020, 4)
		var py: float = R * 1.75 - 0.66
		k.lathe(
			"pot",
			PackedVector2Array(
				[
					Vector2(0.03, py),
					Vector2(0.14, py + 0.03),
					Vector2(0.225, py + 0.15),
					Vector2(0.215, py + 0.28),
					Vector2(0.17, py + 0.33),
					Vector2(0.195, py + 0.36)
				]
			),
			12,
			Transform3D.IDENTITY,
			true,
			true,
			false
		)
		k.cap("char", loop3(circle_poly(0.16, 12), py + 0.31), true)
	return k.node("Firepit")


## Terracotta diya. `lit` adds a flame and a small warm light.
static func oil_lamp(lit: bool = false) -> Node3D:
	var root := Node3D.new()
	root.name = "Lamp"
	var k := Kit.new()
	k.lathe(
		"pot",
		PackedVector2Array(
			[Vector2(0.0, 0.0), Vector2(0.09, 0.0), Vector2(0.13, 0.035), Vector2(0.15, 0.10), Vector2(0.135, 0.115), Vector2(0.10, 0.05)]
		),
		12,
		Transform3D.IDENTITY,
		true,
		false,
		false
	)
	if lit:
		k.lathe(
			"flame",
			PackedVector2Array([Vector2(0.0, 0.10), Vector2(0.026, 0.13), Vector2(0.018, 0.19), Vector2(0.0, 0.235)]),
			7,
			Transform3D.IDENTITY,
			true,
			false,
			false
		)
	root.add_child(k.node("LampMesh"))
	if lit:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.68, 0.34)
		l.light_energy = 2.4
		l.omni_range = 6.5
		l.omni_attenuation = 1.6
		l.shadow_enabled = false
		l.position = Vector3(0, 0.18, 0)
		root.add_child(l)
	return root


## Crude hide lean-to for the rakshasa camp: three raked poles, a stretched hide, and a
## bone or two pushed into the earth beside it.
static func lean_to(seed_i: int) -> Node3D:
	var k := Kit.new()
	var rg := rng(seed_i + 4747)
	var w: float = rg.randf_range(2.0, 2.9)
	var d: float = rg.randf_range(1.6, 2.3)
	var h: float = rg.randf_range(1.5, 2.0)
	var back := Vector3(-d * 0.5, 0.0, 0.0)
	var ridge_a := Vector3(-d * 0.12, h, -w * 0.5)
	var ridge_b := Vector3(-d * 0.12, h, w * 0.5)
	k.tube("wood", [ridge_a - Vector3(0, 0, 0.15), ridge_b + Vector3(0, 0, 0.15)], 0.07, 6)
	for sgn in [-1.0, 1.0]:
		var top: Vector3 = ridge_a if sgn < 0 else ridge_b
		k.tube("wood", [Vector3(back.x - 0.25, -0.25, sgn * (w * 0.5 + 0.15)), top], 0.065, 6)
		k.tube("wood", [Vector3(d * 0.55, -0.25, sgn * (w * 0.5 - 0.10)), top], 0.06, 6)
	# hide sheet from the ridge down to the ground at the front
	var segs := 4
	for s in range(segs):
		var u0: float = float(s) / float(segs)
		var u1: float = float(s + 1) / float(segs)
		var z0: float = lerpf(-w * 0.5, w * 0.5, u0)
		var z1: float = lerpf(-w * 0.5, w * 0.5, u1)
		var sag0: float = sin(u0 * PI) * 0.14
		var sag1: float = sin(u1 * PI) * 0.14
		k.quadp(
			"hide",
			Vector3(-d * 0.12, h - sag0, z0),
			Vector3(-d * 0.12, h - sag1, z1),
			Vector3(d * 0.55, 0.02, z1 * 0.92),
			Vector3(d * 0.55, 0.02, z0 * 0.92)
		)
		k.quadp(
			"hide",
			Vector3(-d * 0.12, h - sag1, z1),
			Vector3(-d * 0.12, h - sag0, z0),
			Vector3(back.x - 0.2, 0.02, z0 * 0.9),
			Vector3(back.x - 0.2, 0.02, z1 * 0.9)
		)
	for i in range(rg.randi_range(1, 3)):
		k.tube(
			"bone",
			[
				Vector3(rg.randf_range(0.6, 1.6), -0.1, rg.randf_range(-1.4, 1.4)),
				Vector3(rg.randf_range(0.6, 1.6), rg.randf_range(0.3, 0.7), rg.randf_range(-1.4, 1.4))
			],
			0.045,
			5
		)
	return k.node("LeanTo")


## Sharpened stake driven into the ground, point up. MultiMesh source.
static func stake_mesh(seed_i: int) -> ArrayMesh:
	var k := Kit.new()
	var rg := rng(seed_i + 1717)
	var h: float = rg.randf_range(1.2, 2.0)
	var r: float = rg.randf_range(0.055, 0.085)
	k.lathe(
		"wood",
		PackedVector2Array([Vector2(r, -0.5), Vector2(r * 1.05, h * 0.6), Vector2(r * 0.8, h * 0.86), Vector2(0.008, h)]),
		7,
		Transform3D.IDENTITY,
		false,
		false,
		true
	)
	if rg.randf() < 0.30:
		k.tube("bone", [Vector3(-0.10, h - 0.28, 0.0), Vector3(0.12, h - 0.10, 0.05)], 0.05, 5)
	return k.commit()


## Weathered bone, for the camp floor.
static func bone_mesh(seed_i: int) -> ArrayMesh:
	var k := Kit.new()
	var rg := rng(seed_i + 2727)
	var L: float = rg.randf_range(0.35, 0.85)
	var r: float = rg.randf_range(0.030, 0.055)
	k.lathe(
		"bone",
		PackedVector2Array(
			[
				Vector2(r * 1.9, 0.0),
				Vector2(r * 2.1, r * 1.2),
				Vector2(r, r * 2.6),
				Vector2(r, L - r * 2.6),
				Vector2(r * 2.0, L - r * 1.2),
				Vector2(r * 1.8, L)
			]
		),
		7,
		Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3.ZERO),
		true,
		true,
		true
	)
	return k.commit()


## Roadside milestone: a rough dressed pillar with a chamfered cap.
static func milestone_mesh(seed_i: int) -> ArrayMesh:
	var k := Kit.new()
	var rg := rng(seed_i + 8383)
	var h: float = rg.randf_range(0.66, 0.98)
	var w: float = rg.randf_range(0.24, 0.32)
	var d: float = w * rg.randf_range(0.58, 0.78)
	var yaw: float = rg.randf_range(0.0, 0.7)
	var lo := ensure_cw([Vector2(w, d), Vector2(-w, d), Vector2(-w, -d), Vector2(w, -d)])
	var hi := ensure_cw(
		[Vector2(w * 0.86, d * 0.86), Vector2(-w * 0.86, d * 0.86), Vector2(-w * 0.86, -d * 0.86), Vector2(w * 0.86, -d * 0.86)]
	)
	var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3.ZERO)
	k.band("stone", loop3(lo, -0.45, xf), loop3(hi, h - 0.09, xf), 0.0)
	k.band("carved", loop3(hi, h - 0.09, xf), loop3(scale_poly(hi, 0.72), h, xf), 0.0)
	k.cap("carved", loop3(scale_poly(hi, 0.72), h, xf), true)
	return k.commit()


## Flat paving slab, for the shrine forecourt and processional path.
static func flagstone_mesh(seed_i: int) -> ArrayMesh:
	var k := Kit.new()
	var rg := rng(seed_i + 5252)
	var n := 5
	var lo: Array = []
	var hi: Array = []
	for i in range(n):
		var th: float = TAU * float(i) / float(n) + rg.randf_range(-0.15, 0.15)
		var r: float = rg.randf_range(0.42, 0.68)
		lo.append(Vector3(r * cos(th), -0.30, -r * sin(th)))
		hi.append(Vector3(r * 0.97 * cos(th), rg.randf_range(-0.01, 0.03), -r * 0.97 * sin(th)))
	k.band("stone", lo, hi, 0.0)
	k.cap("stone", hi, true)
	return k.commit()


## Rounded boulder used as a stepping stone in the shallows.
static func stepping_stone_mesh(seed_i: int) -> ArrayMesh:
	var k := Kit.new()
	var rg := rng(seed_i + 9393)
	var n := 7
	var rings: Array = []
	for si in range(4):
		var u: float = float(si) / 3.0
		var ring: Array = []
		for i in range(n):
			var th: float = TAU * float(i) / float(n)
			var r: float = rg.randf_range(0.55, 0.85) * (1.0 - u * u * 0.45)
			ring.append(Vector3(r * cos(th), -0.9 + u * 1.25, -r * sin(th)))
		rings.append(ring)
	for si in range(3):
		k.band("stone", rings[si], rings[si + 1], 0.0)
	k.cap("stone", rings[3], true)
	return k.commit()
