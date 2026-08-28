class_name MeshKit
extends RefCounted
## Procedural mesh primitives.
##
## WINDING: Godot treats CLOCKWISE as front-facing. Concretely, for a triangle
## (P0, P1, P2) to be visible from direction N, `cross(P1-P0, P2-P0)` must point
## AWAY from the viewer, i.e. equal -N. Every helper here follows that, and
## tests/meshkit_test.gd renders them to prove it rather than trusting the derivation.

## Generated meshes are pure functions of their arguments, so they are memoised.
## Building one ProcRig means generating ~40 meshes; with 26 enemies and 12 villagers
## that was ~1500 mesh generations, and two rig builds landing in the same frame
## produced 150 ms spikes. With the cache the second rakshasa of a given type is free.
static var _cache: Dictionary = {}
static var cache_hits: int = 0
static var cache_misses: int = 0
static var debug_misses: bool = false


static func _memo(key: String, gen: Callable) -> ArrayMesh:
	var hit: Variant = _cache.get(key)
	if hit != null:
		cache_hits += 1
		return hit
	cache_misses += 1
	if debug_misses:
		print("[meshkit] MISS %s" % key.substr(0, 90))
	var m: ArrayMesh = gen.call()
	_cache[key] = m
	return m


static func cache_stats() -> Dictionary:
	return {"entries": _cache.size(), "hits": cache_hits, "misses": cache_misses}


static func clear_cache() -> void:
	_cache.clear()


## Build a surface from rings of vertices. `rings` is an Array of PackedVector3Array,
## each the same length, ordered bottom to top, each ring's points going anticlockwise
## when seen from +Y. `vs` are the V texture coordinates per ring.
static func loft(rings: Array, vs: PackedFloat32Array, closed: bool = true, u_scale: float = 1.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n_seg: int = (rings[0] as PackedVector3Array).size()
	for r in range(rings.size() - 1):
		var lo: PackedVector3Array = rings[r]
		var hi: PackedVector3Array = rings[r + 1]
		var lim: int = n_seg if closed else n_seg - 1
		for s in range(lim):
			var s2: int = (s + 1) % n_seg
			var u0 := float(s) / float(n_seg) * u_scale
			var u1 := float(s + 1) / float(n_seg) * u_scale
			var v0: float = vs[r]
			var v1: float = vs[r + 1]
			_tri(st, lo[s], Vector2(u0, v0), lo[s2], Vector2(u1, v0), hi[s2], Vector2(u1, v1))
			_tri(st, lo[s], Vector2(u0, v0), hi[s2], Vector2(u1, v1), hi[s], Vector2(u0, v1))
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


static func _tri(st: SurfaceTool, a: Vector3, ua: Vector2, b: Vector3, ub: Vector2, c: Vector3, uc: Vector2) -> void:
	st.set_uv(ua)
	st.add_vertex(a)
	st.set_uv(ub)
	st.add_vertex(b)
	st.set_uv(uc)
	st.add_vertex(c)


static func ring(centre: Vector3, radius: float, segments: int, squash: float = 1.0, rot: float = 0.0) -> PackedVector3Array:
	var p := PackedVector3Array()
	for i in range(segments):
		var a: float = TAU * float(i) / float(segments) + rot
		p.append(centre + Vector3(cos(a) * radius, 0.0, sin(a) * radius * squash))
	return p


## Loft an elliptical profile along +Y. `profile` entries are [t, radius_x, radius_z].
## This is what torsos and pots need: a single ovoid reads as a barrel.
static func profile_loft(length: float, profile: Array, segments: int = 16) -> ArrayMesh:
	return _memo("pl|%.4f|%s|%d" % [length, str(profile), segments], func(): return _profile_loft_gen(length, profile, segments))


static func _profile_loft_gen(length: float, profile: Array, segments: int) -> ArrayMesh:
	var rings: Array = []
	var vs := PackedFloat32Array()
	for p in profile:
		var t: float = p[0]
		var rx: float = maxf(p[1], 0.002)
		var rz: float = maxf(p[2], 0.002)
		rings.append(ring(Vector3(0, t * length, 0), rx, segments, rz / rx))
		vs.append(t)
	return loft(rings, vs)


## Tapered tube along +Y. `profile` is an Array of [height_fraction, radius].
static func tube(length: float, profile: Array, segments: int = 12, squash: float = 1.0, bend: Vector3 = Vector3.ZERO) -> ArrayMesh:
	return _memo(
		"tube|%.4f|%s|%d|%.3f|%s" % [length, str(profile), segments, squash, bend],
		func(): return _tube_gen(length, profile, segments, squash, bend)
	)


static func _tube_gen(length: float, profile: Array, segments: int, squash: float, bend: Vector3) -> ArrayMesh:
	var rings: Array = []
	var vs := PackedFloat32Array()
	for p in profile:
		var t: float = p[0]
		var r: float = p[1]
		var c := Vector3(bend.x * t * t, t * length, bend.z * t * t)
		rings.append(ring(c, r, segments, squash))
		vs.append(t)
	return loft(rings, vs)


## Capsule-ish limb segment: fat in the middle, rounded ends, so joints read as flesh
## rather than as pipe sections.
static func limb(length: float, r_top: float, r_bot: float, bulge: float = 1.12, segments: int = 10) -> ArrayMesh:
	return _memo(
		"limb|%.4f|%.4f|%.4f|%.3f|%d" % [length, r_top, r_bot, bulge, segments],
		func(): return _limb_gen(length, r_top, r_bot, bulge, segments)
	)


static func _limb_gen(length: float, r_top: float, r_bot: float, bulge: float, segments: int) -> ArrayMesh:
	var prof := []
	var steps := 9
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var base: float = lerpf(r_bot, r_top, t)
		# Round the very ends off.
		var cap: float = sin(clampf(t, 0.0, 1.0) * PI)
		var r: float = base * (1.0 - 0.34 * pow(absf(t * 2.0 - 1.0), 3.2)) * lerpf(1.0, bulge, cap * 0.5)
		prof.append([t, maxf(r, 0.004)])
	return tube(length, prof, segments)


static func sphere(radius: float, segments: int = 14, rings_n: int = 10, scale_y: float = 1.0) -> ArrayMesh:
	return _memo(
		"sph|%.4f|%d|%d|%.3f" % [radius, segments, rings_n, scale_y], func(): return _sphere_gen(radius, segments, rings_n, scale_y)
	)


static func _sphere_gen(radius: float, segments: int, rings_n: int, scale_y: float) -> ArrayMesh:
	var rings: Array = []
	var vs := PackedFloat32Array()
	for i in range(rings_n + 1):
		var t: float = float(i) / float(rings_n)
		var phi: float = t * PI
		var r: float = sin(phi) * radius
		var y: float = -cos(phi) * radius * scale_y
		rings.append(ring(Vector3(0, y, 0), maxf(r, 0.0008), segments))
		vs.append(t)
	return loft(rings, vs)


## An egg / ovoid, good for heads, pots and fruit.
static func ovoid(radius: float, height: float, top_bias: float = 0.55, segments: int = 14, rings_n: int = 12) -> ArrayMesh:
	return _memo(
		"ovo|%.4f|%.4f|%.3f|%d|%d" % [radius, height, top_bias, segments, rings_n],
		func(): return _ovoid_gen(radius, height, top_bias, segments, rings_n)
	)


static func _ovoid_gen(radius: float, height: float, top_bias: float, segments: int, rings_n: int) -> ArrayMesh:
	var rings: Array = []
	var vs := PackedFloat32Array()
	for i in range(rings_n + 1):
		var t: float = float(i) / float(rings_n)
		var phi: float = t * PI
		var w: float = sin(phi)
		# Push the widest point above or below centre.
		var shape: float = pow(w, lerpf(1.35, 0.75, t * top_bias + (1.0 - top_bias) * 0.5))
		rings.append(ring(Vector3(0, (t - 0.5) * height, 0), maxf(shape * radius, 0.0008), segments))
		vs.append(t)
	return loft(rings, vs)


static func box(size: Vector3, uv_scale: float = 1.0) -> ArrayMesh:
	return _memo("box|%s|%.3f" % [size, uv_scale], func(): return _box_gen(size, uv_scale))


static func _box_gen(size: Vector3, uv_scale: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := size * 0.5
	var faces := [
		[
			Vector3(0, 0, 1),
			Vector3(-h.x, -h.y, h.z),
			Vector3(h.x, -h.y, h.z),
			Vector3(h.x, h.y, h.z),
			Vector3(-h.x, h.y, h.z),
			Vector2(size.x, size.y)
		],
		[
			Vector3(0, 0, -1),
			Vector3(h.x, -h.y, -h.z),
			Vector3(-h.x, -h.y, -h.z),
			Vector3(-h.x, h.y, -h.z),
			Vector3(h.x, h.y, -h.z),
			Vector2(size.x, size.y)
		],
		[
			Vector3(1, 0, 0),
			Vector3(h.x, -h.y, h.z),
			Vector3(h.x, -h.y, -h.z),
			Vector3(h.x, h.y, -h.z),
			Vector3(h.x, h.y, h.z),
			Vector2(size.z, size.y)
		],
		[
			Vector3(-1, 0, 0),
			Vector3(-h.x, -h.y, -h.z),
			Vector3(-h.x, -h.y, h.z),
			Vector3(-h.x, h.y, h.z),
			Vector3(-h.x, h.y, -h.z),
			Vector2(size.z, size.y)
		],
		[
			Vector3(0, 1, 0),
			Vector3(-h.x, h.y, h.z),
			Vector3(h.x, h.y, h.z),
			Vector3(h.x, h.y, -h.z),
			Vector3(-h.x, h.y, -h.z),
			Vector2(size.x, size.z)
		],
		[
			Vector3(0, -1, 0),
			Vector3(-h.x, -h.y, -h.z),
			Vector3(h.x, -h.y, -h.z),
			Vector3(h.x, -h.y, h.z),
			Vector3(-h.x, -h.y, h.z),
			Vector2(size.x, size.z)
		],
	]
	for f in faces:
		var uvs: Vector2 = f[5] * uv_scale
		st.set_uv(Vector2(0, uvs.y))
		st.add_vertex(f[1])
		st.set_uv(Vector2(uvs.x, uvs.y))
		st.add_vertex(f[2])
		st.set_uv(Vector2(uvs.x, 0))
		st.add_vertex(f[3])
		st.set_uv(Vector2(0, uvs.y))
		st.add_vertex(f[1])
		st.set_uv(Vector2(uvs.x, 0))
		st.add_vertex(f[3])
		st.set_uv(Vector2(0, 0))
		st.add_vertex(f[4])
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


## Flat quad in the XY plane, facing +Z. Used for cloth, leaves and banners.
static func quad(w: float, h: float, pivot_top: bool = false) -> ArrayMesh:
	return _memo("quad|%.4f|%.4f|%s" % [w, h, pivot_top], func(): return _quad_gen(w, h, pivot_top))


static func _quad_gen(w: float, h: float, pivot_top: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y0 := -h if pivot_top else -h * 0.5
	var y1 := 0.0 if pivot_top else h * 0.5
	var a := Vector3(-w * 0.5, y0, 0)
	var b := Vector3(w * 0.5, y0, 0)
	var c := Vector3(w * 0.5, y1, 0)
	var d := Vector3(-w * 0.5, y1, 0)
	# Wound so the card faces +Z, which is what every caller expects of a quad.
	_tri(st, a, Vector2(0, 1), c, Vector2(1, 0), b, Vector2(1, 1))
	_tri(st, a, Vector2(0, 1), d, Vector2(0, 0), c, Vector2(1, 0))
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


## An irregular boulder: a sphere pushed around by noise, then flattened slightly.
static func boulder(radius: float, seed_v: int, segments: int = 12, rings_n: int = 9) -> ArrayMesh:
	return _memo("bld|%.4f|%d|%d|%d" % [radius, seed_v, segments, rings_n], func(): return _boulder_gen(radius, seed_v, segments, rings_n))


static func _boulder_gen(radius: float, seed_v: int, segments: int, rings_n: int) -> ArrayMesh:
	var n := FastNoiseLite.new()
	n.seed = seed_v
	n.frequency = 0.9
	n.fractal_octaves = 3
	var rings: Array = []
	var vs := PackedFloat32Array()
	for i in range(rings_n + 1):
		var t: float = float(i) / float(rings_n)
		var phi: float = t * PI
		var pts := PackedVector3Array()
		for s in range(segments):
			var a: float = TAU * float(s) / float(segments)
			var dir := Vector3(sin(phi) * cos(a), -cos(phi), sin(phi) * sin(a))
			var d: float = 1.0 + n.get_noise_3d(dir.x * 2.2, dir.y * 2.2, dir.z * 2.2) * 0.34
			var p := dir * radius * d
			p.y *= 0.78
			pts.append(p)
		rings.append(pts)
		vs.append(t)
	return loft(rings, vs)


## Merge several meshes, each with its own transform, into one surface. Memoised on the
## exact set of (mesh, transform) pairs, so every character sharing a joint's geometry
## merges it once.
static func bake_cached(parts: Array) -> ArrayMesh:
	var key := "bake"
	for p in parts:
		var m: ArrayMesh = p.mesh
		var x: Transform3D = p.xform
		key += (
			"|%d@%.3f,%.3f,%.3f/%.3f,%.3f,%.3f"
			% [m.get_instance_id(), x.origin.x, x.origin.y, x.origin.z, x.basis.get_scale().x, x.basis.get_scale().y, x.basis.get_scale().z]
		)
		key += "/%.3f,%.3f,%.3f" % [x.basis.get_euler().x, x.basis.get_euler().y, x.basis.get_euler().z]
	return _memo(key, func(): return bake(parts))


## Merge several meshes, each with its own transform, into one surface per material.
static func bake(parts: Array) -> ArrayMesh:
	# parts: [{mesh: ArrayMesh, xform: Transform3D}]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in parts:
		var m: ArrayMesh = p.mesh
		var x: Transform3D = p.xform
		for si in range(m.get_surface_count()):
			var arrays := m.surface_get_arrays(si)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			var idx := PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] != null:
				idx = arrays[Mesh.ARRAY_INDEX]
			var has_uv := uvs.size() == verts.size()
			if idx.is_empty():
				for i in range(verts.size()):
					if has_uv:
						st.set_uv(uvs[i])
					st.add_vertex(x * verts[i])
			else:
				for i in idx:
					if has_uv:
						st.set_uv(uvs[i])
					st.add_vertex(x * verts[i])
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


# ===========================================================================
#  SCULPTED SURFACES
# ===========================================================================
## Everything above builds a shape by lathing a radius profile, which is why the first
## pass of the characters read as tubes and eggs: a lathe cannot put a cheekbone on a
## skull or a knuckle on a finger. The builders below work on an explicit GRID of
## points instead, so an analytic field can push individual vertices around, and several
## grids can be committed as ONE indexed mesh — one draw call for a whole head.


## Commit a set of quad grids as one indexed mesh with smooth normals.
##
## `grids` entries: {"rows": Array[PackedVector3Array], "wrap": bool, "u": float,
## "v": float}. Rows run bottom to top; inside a row the points go anticlockwise seen
## from +Y, which is the winding the rest of this file uses (front faces are CLOCKWISE).
##
## Normals are computed from grid neighbours rather than by `generate_normals()`, for
## two reasons that both showed up as visible defects: `generate_normals()` averages by
## (position, uv) so it CREASES the wrap column of any closed surface, and it would
## flatten the analytic normals of a sculpted patch the moment a second grid is added.
static func surface(grids: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var base := 0
	for g in grids:
		var rows: Array = g["rows"]
		var wrap: bool = g.get("wrap", true)
		var us: float = g.get("u", 1.0)
		var vs: float = g.get("v", 1.0)
		var nr: int = rows.size()
		var nc: int = (rows[0] as PackedVector3Array).size()
		for r in range(nr):
			var row: PackedVector3Array = rows[r]
			var rm: PackedVector3Array = rows[maxi(r - 1, 0)]
			var rp: PackedVector3Array = rows[mini(r + 1, nr - 1)]
			for s in range(nc):
				var sm: int = (s - 1 + nc) % nc if wrap else maxi(s - 1, 0)
				var sp: int = (s + 1) % nc if wrap else mini(s + 1, nc - 1)
				var du: Vector3 = row[sp] - row[sm]
				var dv: Vector3 = rp[s] - rm[s]
				# A pole row collapses to a point, so its own tangents are zero; borrow
				# the ring next to it or the normal comes out as garbage.
				if du.length_squared() < 1.0e-12:
					du = (rp[sp] - rp[sm]) if r < nr - 1 else (rm[sp] - rm[sm])
				if dv.length_squared() < 1.0e-12:
					dv = Vector3.UP
				var n: Vector3 = dv.cross(du)
				st.set_normal(n.normalized() if n.length_squared() > 1.0e-14 else Vector3.UP)
				st.set_uv(Vector2(float(s) / float(nc) * us, float(r) / float(maxi(nr - 1, 1)) * vs))
				st.add_vertex(row[s])
		var lim: int = nc if wrap else nc - 1
		for r in range(nr - 1):
			var a: int = base + r * nc
			var b: int = base + (r + 1) * nc
			for s in range(lim):
				var s2: int = (s + 1) % nc
				st.add_index(a + s)
				st.add_index(a + s2)
				st.add_index(b + s2)
				st.add_index(a + s)
				st.add_index(b + s2)
				st.add_index(b + s)
		base += nr * nc
	st.generate_tangents()
	return st.commit()


## Rings of a tube swept along an arbitrary path, by parallel transport, so a finger,
## a hair lock, a braid and the rim of an ear are all the same call. Returns the grid
## for `surface()`; `sweep()` wraps it into a mesh on its own.
static func sweep_rows(
	path: PackedVector3Array, radii: PackedFloat32Array, seg: int = 6, squash: float = 1.0, up_hint: Vector3 = Vector3.UP
) -> Array:
	var n: int = path.size()
	var tans := PackedVector3Array()
	for i in range(n):
		var a: Vector3 = path[maxi(i - 1, 0)]
		var b: Vector3 = path[mini(i + 1, n - 1)]
		var t: Vector3 = b - a
		tans.append(t.normalized() if t.length_squared() > 1.0e-12 else Vector3.UP)
	# Seed the frame from the hint, then rotate it along with the tangent so the tube
	# does not spin about its own axis where the path bends.
	var nrm: Vector3 = up_hint - tans[0] * up_hint.dot(tans[0])
	if nrm.length_squared() < 1.0e-8:
		nrm = Vector3.RIGHT - tans[0] * Vector3.RIGHT.dot(tans[0])
	if nrm.length_squared() < 1.0e-8:
		nrm = Vector3.FORWARD - tans[0] * Vector3.FORWARD.dot(tans[0])
	nrm = nrm.normalized()
	var rows: Array = []
	for i in range(n):
		if i > 0:
			var axis: Vector3 = tans[i - 1].cross(tans[i])
			if axis.length_squared() > 1.0e-12:
				var ang: float = acos(clampf(tans[i - 1].dot(tans[i]), -1.0, 1.0))
				nrm = nrm.rotated(axis.normalized(), ang)
			nrm = (nrm - tans[i] * nrm.dot(tans[i])).normalized()
		var bin: Vector3 = nrm.cross(tans[i])
		var ring_pts := PackedVector3Array()
		for s in range(seg):
			var th: float = TAU * float(s) / float(seg)
			ring_pts.append(path[i] + nrm * (cos(th) * radii[i]) + bin * (sin(th) * radii[i] * squash))
		rows.append(ring_pts)
	return rows


## MEMOISED, and it has to be. `_merge_draws` keys its baked joints on the instance ids
## of the meshes going into them, so a generator that hands back a fresh mesh every call
## makes every merge a cache miss: two unmemoised collarbones re-baked the whole chest
## on every rig and took a warm build from 2.5 ms to 15 ms.
static func sweep(
	path: PackedVector3Array, radii: PackedFloat32Array, seg: int = 6, squash: float = 1.0, up_hint: Vector3 = Vector3.UP
) -> ArrayMesh:
	return _memo(
		"swp|%s|%s|%d|%.3f|%s" % [str(path), str(radii), seg, squash, str(up_hint)],
		func(): return surface([{"rows": sweep_rows(path, radii, seg, squash, up_hint)}])
	)


## Squared-falloff blob, 1 at the centre and 0 outside the ellipsoid (sx, sy, sz).
## Every facial feature is one of these; the shape reads because they OVERLAP, the way
## a brow ridge runs into a temple.
static func _blob(dx: float, dy: float, dz: float, sx: float, sy: float, sz: float) -> float:
	var qx: float = dx / sx
	var qy: float = dy / sy
	var qz: float = dz / sz
	var q: float = qx * qx + qy * qy + qz * qz
	if q >= 1.0:
		return 0.0
	q = 1.0 - q
	return q * q


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
	var ex: float = head_surface(-0.170, 0.0, r, p).x * 0.955 * sx
	var ey: float = -0.170 * r
	var ez: float = 0.145 * r
	var ry: float = 0.250 * r
	var rz: float = 0.140 * r
	var tilt: float = 0.20  # radians, top of the ear rakes backwards
	var n: int = 15 if lod == 0 else 9
	var seg: int = 5 if lod == 0 else 4
	var grids: Array = []

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
	grids.append({"rows": sweep_rows(path, radii, seg, 0.75, Vector3(sx, 0, 0))})

	# Antihelix: the Y-shaped ridge inside the rim. Without it the ear is a loop.
	var ah := PackedVector3Array()
	var ahr := PackedFloat32Array()
	var m: int = 8 if lod == 0 else 5
	for i in range(m):
		var a: float = lerpf(-2.5, 0.9, float(i) / float(m - 1))
		var yy: float = ey + cos(a) * ry * 0.58
		var zz: float = ez + sin(a) * rz * 0.52
		ah.append(Vector3(ex + sx * 0.024 * r, yy + sin(a) * ry * tilt * 0.6, zz))
		ahr.append(r * lerpf(0.020, 0.036, sin(float(i) / float(m - 1) * PI)))
	grids.append({"rows": sweep_rows(ah, ahr, 4, 1.0, Vector3(sx, 0, 0))})

	# The plate behind them, dished into a concha in front of the antihelix so the ear
	# has a hollow rather than a flat disc.
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
	grids.append({"rows": plate if sx > 0.0 else _flip_rows(plate)})

	# The lobe.
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
	grids.append({"rows": lobe if sx > 0.0 else _flip_rows(lobe)})
	return grids


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
