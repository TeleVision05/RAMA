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


static func _memo(key: String, gen: Callable) -> ArrayMesh:
	var hit: Variant = _cache.get(key)
	if hit != null:
		cache_hits += 1
		return hit
	cache_misses += 1
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


static func ring(
	centre: Vector3, radius: float, segments: int, squash: float = 1.0, rot: float = 0.0
) -> PackedVector3Array:
	var p := PackedVector3Array()
	for i in range(segments):
		var a: float = TAU * float(i) / float(segments) + rot
		p.append(centre + Vector3(cos(a) * radius, 0.0, sin(a) * radius * squash))
	return p


## Loft an elliptical profile along +Y. `profile` entries are [t, radius_x, radius_z].
## This is what torsos and pots need: a single ovoid reads as a barrel.
static func profile_loft(length: float, profile: Array, segments: int = 16) -> ArrayMesh:
	return _memo(
		"pl|%.4f|%s|%d" % [length, str(profile), segments], func(): return _profile_loft_gen(length, profile, segments)
	)


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
static func tube(
	length: float, profile: Array, segments: int = 12, squash: float = 1.0, bend: Vector3 = Vector3.ZERO
) -> ArrayMesh:
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
		"sph|%.4f|%d|%d|%.3f" % [radius, segments, rings_n, scale_y],
		func(): return _sphere_gen(radius, segments, rings_n, scale_y)
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
static func ovoid(
	radius: float, height: float, top_bias: float = 0.55, segments: int = 14, rings_n: int = 12
) -> ArrayMesh:
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
	return _memo(
		"bld|%.4f|%d|%d|%d" % [radius, seed_v, segments, rings_n],
		func(): return _boulder_gen(radius, seed_v, segments, rings_n)
	)


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
			% [
				m.get_instance_id(),
				x.origin.x,
				x.origin.y,
				x.origin.z,
				x.basis.get_scale().x,
				x.basis.get_scale().y,
				x.basis.get_scale().z
			]
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
