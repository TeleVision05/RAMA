extends SceneTree
## QA: is the vegetation ACTUALLY 3D?
##
## A flat card is a plane: every vertex lies in one plane, so the smallest principal
## extent of its vertex cloud is exactly 0. This measures that directly.
##
## Per PRIMITIVE (one leaf, one sprig, one frond) and per CONNECTED COMPONENT of every
## shipped canopy mesh, it runs a PCA on the vertices and reports the extent along the
## THINNEST principal axis, both absolute (metres) and as a fraction of the longest.
## It also reports the spread of triangle normals in the component: a plane has every
## normal identical, so max pairwise normal deviation is 0 degrees.


class Acc:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var t := PackedFloat32Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()

	func vert(p: Vector3, nrm: Vector3, tan: Vector3, col: Color, u: Vector2) -> int:
		var i := v.size()
		v.push_back(p)
		n.push_back(nrm.normalized() if nrm.length_squared() > 1e-12 else Vector3.UP)
		var tt := tan if tan.length_squared() > 1e-8 else Vector3.RIGHT
		tt = tt.normalized()
		t.append_array([tt.x, tt.y, tt.z, 1.0])
		c.push_back(col)
		uv.push_back(u)
		return i

	func tri(a: int, b: int, cc: int) -> void:
		idx.append_array([a, b, cc])

	func quad(i0: int, i1: int, i2: int, i3: int, want: Vector3) -> void:
		var cr := (v[i1] - v[i0]).cross(v[i3] - v[i0])
		if cr.dot(want) > 0.0:
			var tmp := i1
			i1 = i3
			i3 = tmp
		tri(i0, i1, i3)
		tri(i1, i2, i3)


# --- PCA -------------------------------------------------------------------
static func _matvec(pts: PackedVector3Array, ctr: Vector3, v: Vector3) -> Vector3:
	var r := Vector3.ZERO
	for p in pts:
		var d := p - ctr
		r += d * d.dot(v)
	return r


static func _power(pts: PackedVector3Array, ctr: Vector3, defl: Array) -> Vector3:
	var v := Vector3(0.577, 0.573, 0.582)
	for _i in range(80):
		var r := _matvec(pts, ctr, v)
		for d in defl:
			var ax: Vector3 = d[0]
			var lam: float = d[1]
			r -= ax * lam * ax.dot(v)
		if r.length_squared() < 1e-24:
			return v
		v = r.normalized()
	return v


## Extents of the vertex cloud along its three principal axes, sorted descending.
static func principal_extents(pts: PackedVector3Array) -> Vector3:
	if pts.size() < 3:
		return Vector3.ZERO
	var ctr := Vector3.ZERO
	for p in pts:
		ctr += p
	ctr /= float(pts.size())
	var a1 := _power(pts, ctr, [])
	var l1: float = a1.dot(_matvec(pts, ctr, a1))
	var a2 := _power(pts, ctr, [[a1, l1]])
	a2 = (a2 - a1 * a1.dot(a2))
	if a2.length_squared() < 1e-16:
		a2 = a1.cross(Vector3.UP)
		if a2.length_squared() < 1e-16:
			a2 = a1.cross(Vector3.RIGHT)
	a2 = a2.normalized()
	var a3 := a1.cross(a2).normalized()
	var ext := []
	for ax in [a1, a2, a3]:
		var lo := INF
		var hi := -INF
		for p in pts:
			var d: float = (p - ctr).dot(ax)
			lo = minf(lo, d)
			hi = maxf(hi, d)
		ext.append(hi - lo)
	ext.sort()
	ext.reverse()
	return Vector3(ext[0], ext[1], ext[2])


## Largest angle between any triangle normal and the component's mean normal, degrees.
static func normal_spread(pts: PackedVector3Array, idx: PackedInt32Array) -> float:
	var norms: Array[Vector3] = []
	var i := 0
	while i + 2 < idx.size():
		var a := pts[idx[i]]
		var b := pts[idx[i + 1]]
		var c := pts[idx[i + 2]]
		var nn := (b - a).cross(c - a)
		if nn.length_squared() > 1e-16:
			norms.append(nn.normalized())
		i += 3
	if norms.size() < 2:
		return 0.0
	var mean := Vector3.ZERO
	for n in norms:
		mean += n if n.dot(norms[0]) >= 0.0 else -n
	if mean.length_squared() < 1e-16:
		return 180.0
	mean = mean.normalized()
	var worst := 0.0
	for n in norms:
		var d: float = absf(n.dot(mean))
		worst = maxf(worst, rad_to_deg(acos(clampf(d, -1.0, 1.0))))
	return worst


# --- connected components over an indexed surface --------------------------
var _par := PackedInt32Array()
var _dump := false


func _find(a: int) -> int:
	while _par[a] != a:
		_par[a] = _par[_par[a]]
		a = _par[a]
	return a


func _union(a: int, b: int) -> void:
	var ra := _find(a)
	var rb := _find(b)
	if ra != rb:
		_par[ra] = rb


## Report the thinness statistics of every connected component of a surface.
func components(verts: PackedVector3Array, idx: PackedInt32Array) -> Dictionary:
	_par = PackedInt32Array()
	_par.resize(verts.size())
	for i in range(verts.size()):
		_par[i] = i
	var i := 0
	while i + 2 < idx.size():
		_union(idx[i], idx[i + 1])
		_union(idx[i + 1], idx[i + 2])
		i += 3
	var groups := {}
	i = 0
	while i + 2 < idx.size():
		var r := _find(idx[i])
		if not groups.has(r):
			groups[r] = PackedInt32Array()
		groups[r].append_array([idx[i], idx[i + 1], idx[i + 2]])
		i += 3

	var ratios: Array[float] = []
	var thins: Array[float] = []
	var spreads: Array[float] = []
	var flat := 0
	for k in groups:
		var tri_idx: PackedInt32Array = groups[k]
		var seen := {}
		var pts := PackedVector3Array()
		var local := PackedInt32Array()
		for vi in tri_idx:
			if not seen.has(vi):
				seen[vi] = pts.size()
				pts.push_back(verts[vi])
			local.push_back(seen[vi])
		if pts.size() < 3:
			continue
		var e := principal_extents(pts)
		var ratio: float = e.z / maxf(e.x, 1e-9)
		ratios.append(ratio)
		thins.append(e.z)
		spreads.append(normal_spread(pts, local))
		# A card is a PLANE: sub-millimetre thickness and every triangle normal the
		# same. A long thin prism (a frond rachis) also has a low thin/long ratio, so
		# the ratio alone is not the test — the normal spread separates them.
		if e.z < 0.001 or (ratio < 0.02 and normal_spread(pts, local) < 3.0):
			flat += 1
			if _dump:
				print(
					(
						"      flagged comp: tris=%d long=%.4f mid=%.4f thin=%.5f nspread=%.2fdeg"
						% [local.size() / 3, e.x, e.y, e.z, normal_spread(pts, local)]
					)
				)
	ratios.sort()
	thins.sort()
	spreads.sort()
	if ratios.is_empty():
		return {"n": 0}
	return {
		"n": ratios.size(),
		"ratio_min": ratios[0],
		"ratio_med": ratios[ratios.size() / 2],
		"thin_min": thins[0],
		"thin_med": thins[thins.size() / 2],
		"spread_min": spreads[0],
		"spread_med": spreads[spreads.size() / 2],
		"flat": flat,
	}


func _init() -> void:
	var fail := 0
	print("=== QA: primitive thinness (PCA, one primitive in isolation) ===")
	print("%-22s %6s %9s %9s %9s %7s" % ["primitive", "tris", "long(m)", "mid(m)", "THIN(m)", "thin/long"])
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var prims := []

	for rows in [1, 2, 3, 4]:
		var a := Acc.new()
		var cfg := Veg3D.leaf_cfg()
		cfg["rows"] = rows
		Veg3D.leaf(a, Transform3D.IDENTITY, cfg)
		prims.append(["leaf rows=%d" % rows, a])

	var ab := Acc.new()
	var cb := Veg3D.leaf_cfg()
	cb["rows"] = 1
	cb["tip"] = 1.0
	Veg3D.leaf(ab, Transform3D.IDENTITY, cb)
	prims.append(["leaf rows=1 blunt", ab])

	var asp := Acc.new()
	Veg3D.sprig(asp, Transform3D.IDENTITY, rng, Veg3D.sprig_cfg())
	prims.append(["sprig (default)", asp])

	var asm := Acc.new()
	var cm := Veg3D.sprig_cfg()
	cm["rows"] = 1
	cm["stem_segs"] = 0
	cm["leaves"] = 3
	Veg3D.sprig(asm, Transform3D.IDENTITY, rng, cm)
	prims.append(["sprig (MID tier)", asm])

	var af := Acc.new()
	Veg3D.frond(af, Transform3D.IDENTITY, rng, Veg3D.frond_cfg())
	prims.append(["palm frond", af])

	for p in prims:
		var name: String = p[0]
		var acc: Acc = p[1]
		var e := principal_extents(acc.v)
		var ratio: float = e.z / maxf(e.x, 1e-9)
		print("%-22s %6d %9.4f %9.4f %9.5f %7.4f" % [name, acc.idx.size() / 3, e.x, e.y, e.z, ratio])
		if e.z < 1e-5 or ratio < 0.01:
			print("   !! DEGENERATE: this primitive is a PLANE")
			fail += 1

	print("")
	print("=== QA: shipped canopy meshes, per connected component ===")
	print("(one component ~= one leaf. flat = components with thin/long < 0.02)")
	print("%-18s %5s %6s %9s %9s %8s %8s %5s" % ["mesh", "comp", "tris", "thin_med", "thin_min", "r_med", "r_min", "flat"])
	for sp in range(TreeBuilder.SPECIES_COUNT):
		var sname: String = TreeBuilder.SPECIES_NAMES[sp]
		if sname == "rock" or sname == "dead":
			continue
		for lod in [0, 1]:
			var m := TreeBuilder.mesh(sp, 0, lod)
			# leaf surface is the last one (bark is added first)
			if m.get_surface_count() < 2:
				print("%-18s  NO LEAF SURFACE" % ("%s lod%d" % [sname, lod]))
				continue
			var arr := m.surface_get_arrays(m.get_surface_count() - 1)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var r := components(verts, idx)
			var tag := "%s lod%d" % [sname, lod]
			if int(r.get("n", 0)) == 0:
				print("%-18s  EMPTY" % tag)
				continue
			print(
				(
					"%-18s %5d %6d %9.5f %9.5f %8.4f %8.4f %5d"
					% [
						tag,
						r["n"],
						idx.size() / 3,
						r["thin_med"],
						r["thin_min"],
						r["ratio_med"],
						r["ratio_min"],
						r["flat"],
					]
				)
			)
			if float(r["ratio_med"]) < 0.02:
				print("   !! MEDIAN COMPONENT IS FLAT — this canopy is still cards")
				fail += 1
	print("")
	print("RESULT: " + ("PASS" if fail == 0 else "FAIL"))
	quit()
