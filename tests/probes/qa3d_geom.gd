extends SceneTree
## QA: is the ground cover ACTUALLY 3D, or a plane wearing a normal map?
##
## Independent of the implementer's own harnesses. Reads the SHIPPED ArrayMeshes that
## Ground3D hands the scatter, splits each one into connected components (one component
## = one blade / petal / frond / stem, because the builder never shares a vertex between
## parts), and measures how far each component departs from being flat.
##
## A plane has a minimum width of EXACTLY zero, whatever its orientation, so the number
## that matters is the slab thickness along the direction that minimises it, found by a
## direction search rather than from an axis-aligned box (a card lying at 45 degrees has
## no zero AABB axis and would pass an AABB test while still being a card).
##
## Reported per component:
##   thick   min slab width in metres — exactly 0 for a flat card, at any orientation
##   t/w     thickness against the part's WIDTH, which is the cross-section aspect
##
## Thickness is compared to WIDTH, not to length. A blade is a cross-section swept along
## a curve: a 350 mm blade with a 3 mm midrib is a real blade, and dividing 3 by 350
## measures nothing but the aspect ratio of grass. Dividing it by the 20 mm width asks
## the actual question — is the cross-section a V, or a line?

const T_ABS := 0.0015  ## 1.5 mm of relief. Below this a part is a card at arm's length.
const T_WID := 0.12  ## and the cross-section must be at least 12% as deep as it is wide.

var fails: Array = []
var rows: Array = []


func _init() -> void:
	_probe_ground_cover()
	_probe_single_parts()
	_probe_tree_leaves()
	print("")
	for r in rows:
		print(r)
	print("")
	if fails.is_empty():
		print("RESULT: PASS  (every component non-degenerate)")
	else:
		for f in fails:
			print("  ! %s" % f)
		print("RESULT: FAIL  (%d degenerate components)" % fails.size())
	quit()


# --- Measurement -----------------------------------------------------------
## Minimum slab width over all directions, and the two extents perpendicular to it.
##
## No PCA and no Basis element assignment (which silently no-ops in GDScript, because
## `basis[i]` hands back a Vector3 by value — the first cut of this probe reported a
## 0.17 m leaf as 0.047 m long because of exactly that). A Fibonacci sphere seeds the
## search and a shrinking random descent refines it: a plane reads 0.000 mm from any
## starting direction.
static func _extent(pts: PackedVector3Array, d: Vector3) -> float:
	var lo := INF
	var hi := -INF
	for p in pts:
		var x := p.dot(d)
		lo = minf(lo, x)
		hi = maxf(hi, x)
	return hi - lo


static func _min_width(pts: PackedVector3Array) -> Dictionary:
	var best := Vector3.UP
	var bw := INF
	var n := 256
	for i in range(n):
		var z := 1.0 - 2.0 * (float(i) + 0.5) / float(n)
		var r := sqrt(maxf(0.0, 1.0 - z * z))
		var a := PI * (1.0 + sqrt(5.0)) * float(i)
		var d := Vector3(cos(a) * r, z, sin(a) * r)
		var w := _extent(pts, d)
		if w < bw:
			bw = w
			best = d
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var step := 0.20
	for it in range(900):
		var cand := best + Vector3(rng.randfn(0.0, step), rng.randfn(0.0, step), rng.randfn(0.0, step))
		if cand.length_squared() < 1e-9:
			continue
		cand = cand.normalized()
		var w := _extent(pts, cand)
		if w < bw:
			bw = w
			best = cand
		if it % 90 == 89:
			step *= 0.66
	# In the plane perpendicular to the thin axis: the longest extent is the part's
	# length, the shortest its width. Flatness is thickness against WIDTH — a blade is
	# a cross-section extruded along a curve, so comparing a 3 mm midrib to a 350 mm
	# length says nothing about whether the cross-section is a V or a line.
	var u := best.cross(Vector3.UP)
	if u.length_squared() < 1e-9:
		u = best.cross(Vector3.RIGHT)
	u = u.normalized()
	var v2 := best.cross(u).normalized()
	var lo := INF
	var hi := -INF
	for k in range(180):
		var th := PI * float(k) / 180.0
		var d2 := u * cos(th) + v2 * sin(th)
		var e := _extent(pts, d2)
		lo = minf(lo, e)
		hi = maxf(hi, e)
	return {"thick": bw, "width": maxf(lo, 1e-9), "length": maxf(hi, 1e-9), "axis": best}


## Split an indexed mesh into connected components of vertices.
static func _components(verts: PackedVector3Array, idx: PackedInt32Array) -> Array:
	var n := verts.size()
	var parent := PackedInt32Array()
	parent.resize(n)
	for i in range(n):
		parent[i] = i
	var find := func(a: int) -> int:
		var r := a
		while parent[r] != r:
			r = parent[r]
		var w := a
		while parent[w] != w:
			var nx := parent[w]
			parent[w] = r
			w = nx
		return r
	for k in range(0, idx.size(), 3):
		var a: int = find.call(idx[k])
		var b: int = find.call(idx[k + 1])
		var c: int = find.call(idx[k + 2])
		if a != b:
			parent[b] = a
		if a != c:
			parent[c] = a
	var groups: Dictionary = {}
	for i in range(n):
		var r: int = find.call(i)
		if not groups.has(r):
			groups[r] = PackedVector3Array()
		groups[r].push_back(verts[i])
	var out: Array = []
	for k in groups:
		var g: PackedVector3Array = groups[k]
		if g.size() >= 3:
			out.append(g)
	return out


func _measure(tag: String, verts: PackedVector3Array, idx: PackedInt32Array) -> void:
	var comps := _components(verts, idx)
	if comps.is_empty():
		fails.append("%s: no geometry at all" % tag)
		return
	var worst_abs := INF
	var worst_rel := INF
	var worst_tag := ""
	var worst_aabb := INF
	var thicks: Array = []
	var bad := 0
	for g in comps:
		var r := _min_width(g)
		var th: float = r.thick
		var rel: float = th / r.width
		thicks.append(th)
		worst_abs = minf(worst_abs, th)
		worst_aabb = minf(worst_aabb, _aabb_thinnest(g))
		if rel < worst_rel:
			worst_rel = rel
			worst_tag = "%.0fx%.0f mm cross-section, %.0f mm long" % [th * 1000.0, r.width * 1000.0, r.length * 1000.0]
		if th < T_ABS or rel < T_WID:
			bad += 1
	thicks.sort()
	var med: float = thicks[thicks.size() / 2]
	rows.append(
		(
			"%-28s parts %4d  thin %6.2f mm  median %6.2f mm  aabb %6.2f mm  min t/w %5.1f%%  (%s)%s"
			% [
				tag,
				comps.size(),
				worst_abs * 1000.0,
				med * 1000.0,
				worst_aabb * 1000.0,
				worst_rel * 100.0,
				worst_tag,
				("   <-- %d DEGENERATE" % bad) if bad > 0 else ""
			]
		)
	)
	if bad > 0:
		fails.append(
			"%s: %d/%d components flat (thinnest %.3f mm, min t/w %.1f%%)" % [tag, bad, comps.size(), worst_abs * 1000.0, worst_rel * 100.0]
		)


## The literal check the brief asked for: axis-aligned bounding box, thinnest axis.
## Weaker than the direction search — a tilted card has no zero AABB axis — so it is
## reported alongside rather than gated on.
static func _aabb_thinnest(pts: PackedVector3Array) -> float:
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = lo.min(p)
		hi = hi.max(p)
	var d := hi - lo
	return minf(d.x, minf(d.y, d.z))


func _mesh_arrays(m: ArrayMesh, tag: String) -> void:
	for si in range(m.get_surface_count()):
		var a := m.surface_get_arrays(si)
		var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var idx = a[Mesh.ARRAY_INDEX]
		if idx == null:
			var seq := PackedInt32Array()
			for i in range(verts.size()):
				seq.push_back(i)
			idx = seq
		_measure(tag, verts, idx)


# --- What to probe ---------------------------------------------------------
func _probe_ground_cover() -> void:
	print("== SHIPPED GROUND-COVER MESHES (per connected part) ==")
	var names := ["grass", "flower", "fern"]
	var sub := [["mat", "mid", "upright"], ["marigold", "jasmine", "hibiscus"], ["fern_a", "fern_b", "broadleaf"]]
	for l in range(3):
		for v in range(3):
			for d in range(3):
				var m := Ground3D.mesh(l, v, d)
				_mesh_arrays(m, "%s/%s/LOD%d" % [names[l], sub[l][v], d])


## The primitive on its own, at the exact settings a grass blade and a petal use, so the
## number is not diluted by a tuft's worth of parts.
func _probe_single_parts() -> void:
	print("== SINGLE PARTS, isolated ==")
	var cases := {
		"one grass blade":
		{
			"origin": Vector3.ZERO,
			"dir": Vector3.UP,
			"bend": Vector3.RIGHT,
			"length": 0.21,
			"width": 0.011,
			"segs": 3,
			"ribs": 3,
			"droop": 1.55,
			"keel": 0.85,
			"twist": 0.6,
			"taper": 0.52,
			"bulge": 0.24,
			"dpow": 1.95,
		},
		"one grass blade LOD2":
		{
			"origin": Vector3.ZERO,
			"dir": Vector3.UP,
			"bend": Vector3.RIGHT,
			"length": 0.21,
			"width": 0.011,
			"segs": 1,
			"ribs": 3,
			"droop": 1.55,
			"keel": 0.85,
			"twist": 0.0,
			"taper": 0.52,
			"bulge": 0.24,
			"dpow": 1.95,
		},
		"one basal leaf (cupped)":
		{
			"origin": Vector3.ZERO,
			"dir": Vector3(0.5, 0.5, 0.0).normalized(),
			"bend": Vector3.RIGHT,
			"length": 0.17,
			"width": 0.026,
			"segs": 2,
			"ribs": 5,
			"droop": 0.7,
			"keel": -0.45,
			"twist": 0.2,
			"taper": 0.42,
			"bulge": 0.4,
		},
	}
	for k in cases:
		var s := TreeBuilder.Surf.new()
		Ground3D._lamina(s, cases[k])
		_measure(k, s.v, s.idx)


## Not my file, but the brief covers leaves and canopy too, so the numbers go in the
## report as an observation rather than as a gate on this change.
func _probe_tree_leaves() -> void:
	print("== TREE FOLIAGE (observation only, not owned by this change) ==")
	var keep := fails.size()
	for sp in range(TreeBuilder.SPECIES_COUNT):
		var m := TreeBuilder.mesh(sp, 0, 0)
		_mesh_arrays(m, "tree sp%d LOD0" % sp)
	while fails.size() > keep:
		var f: String = fails[fails.size() - 1]
		fails.remove_at(fails.size() - 1)
		rows.append("   (not gated) %s" % f)
