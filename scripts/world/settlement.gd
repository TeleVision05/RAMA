class_name Settlement
extends Node3D
## Every man-made place in the Vale: Panchavati village, the shrine on its knoll, the
## ruins, the rakshasa camp, the paddy fields, and the wayside furniture that makes the
## roads feel travelled.
##
## Placement rules, without exception:
##   * Ground height comes from WorldMap.height_at. Nothing here invents a height.
##   * Buildings are LEVELLED (they never tilt) and are sunk to the LOWEST ground under
##     their footprint, so a building can be neither afloat nor half-buried. Small
##     buildings with a deep buried plinth take a `bias` that lifts them back toward the
##     high side of the footprint - see _place_level.
##   * Loose props are aligned to the local ground normal, partially, the way a dropped
##     pot settles rather than sticking out perpendicular to a slope.
##   * Every scatter is driven by one seeded RNG, so the village is the same village on
##     every run.

const VILLAGE_SEED: int = 0x50414E43  # "PANC"

# Composed places. These are hand-chosen against the baked heightfield: the village
# square sits on the flat river terrace, the temple on the level lobe of the knoll
# plateau clear of the road cut that climbs to it.
const SQUARE := Vector2(-123.0, 55.0)  # open ground: banyan and well
const SQUARE_CLEAR: float = 11.0
const TEMPLE := Vector2(154.0, -78.5)  # temple plinth centre, faces east
const TEMPLE_HX: float = 8.4
const TEMPLE_HZ: float = 6.9
const KNOLL_STAIR_A := Vector2(159.6, -66.2)  # foot, in the road cut
const KNOLL_STAIR_B := Vector2(166.0, -66.2)  # head, on the plateau

var map: WorldMap
var _rng: RandomNumberGenerator
var _poi: Array = []
var _hut_spots: Array = []  # {p: Vector2, yaw: float, r: float}


# ---------------------------------------------------------------------------
func setup(world_map: WorldMap) -> void:
	map = world_map
	_rng = RandomNumberGenerator.new()
	_rng.seed = VILLAGE_SEED
	var t0 := Time.get_ticks_msec()
	_build_village()
	_build_shrine()
	_build_ruins()
	_build_camp()
	_build_fields()
	_build_wayside()
	_build_ford()
	print("[settlement] built %d nodes in %d ms, %d POI" % [get_child_count(), Time.get_ticks_msec() - t0, _poi.size()])


func points_of_interest() -> Array:
	return _poi


## Collision descriptors for anything the player should not walk through, derived from
## the baked meshes themselves so it cannot drift from what is drawn. Small props and
## anything low enough to step over are skipped, as are the shrine steps, which have to
## stay walkable.
const NO_COLLIDE := [
	"pot",
	"basket",
	"lamp",
	"rack",
	"fence",
	"line",
	"step",
	"stair",
	"cart",
	"firepit",
	"bone",
	"stake",
	"marker",
	"milestone",
	"bund",
	"sheaf",
	"mat"
]


func solid_colliders() -> Array:
	var out: Array = []
	_collect_solids(self, out)
	return out


func _collect_solids(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			var mi := c as MeshInstance3D
			if mi.mesh == null:
				continue
			var nm := (mi.name + " " + String(n.name)).to_lower()
			var skip := false
			for bad in NO_COLLIDE:
				if nm.contains(bad):
					skip = true
					break
			if skip:
				continue
			var ab := mi.get_aabb()
			var size: Vector3 = ab.size * mi.global_transform.basis.get_scale()
			# Only things that are actually an obstacle: a real footprint AND tall
			# enough that walking through them would read as a bug.
			if size.y < 1.3 or minf(size.x, size.z) < 0.9:
				continue
			var centre: Vector3 = mi.global_transform * (ab.position + ab.size * 0.5)
			# Shrink slightly: an axis-aligned box around a rotated building otherwise
			# blocks the ground beside it.
			out.append({"pos": centre, "box": Vector3(size.x * 0.82, size.y, size.z * 0.82)})
		if c.get_child_count() > 0:
			_collect_solids(c, out)


# ---------------------------------------------------------------------------
# Ground queries
# ---------------------------------------------------------------------------
func _g(x: float, z: float) -> Vector3:
	return Vector3(x, map.height_at(x, z), z)


func _gv(p: Vector2) -> Vector3:
	return Vector3(p.x, map.height_at(p.x, p.y), p.y)


## Lowest / highest ground under a rectangular footprint, sampled on a grid.
func _extent(c: Vector2, hx: float, hz: float, yaw: float = 0.0) -> Vector2:
	var lo: float = 1.0e9
	var hi: float = -1.0e9
	var cs: float = cos(yaw)
	var sn: float = sin(yaw)
	for j in range(5):
		for i in range(5):
			var lx: float = lerpf(-hx, hx, float(i) / 4.0)
			var lz: float = lerpf(-hz, hz, float(j) / 4.0)
			var wx: float = c.x + lx * cs - lz * sn
			var wz: float = c.y + lx * sn + lz * cs
			var h: float = map.height_at(wx, wz)
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return Vector2(lo, hi)


## Level a building: upright, sunk to the lowest ground it stands on.
##
## `bias` lifts it back toward the HIGHEST ground under the footprint, and `skirt` is how
## far the building's own buried apron reaches below its origin, which caps the lift so
## no daylight can ever appear on the downhill side. Sitting on the lowest ground is the
## safe default for anything with a tall wall, but for a small object on a slope it
## buries the uphill half: a wayside shrine 2.6 m across on a 0.4 m grade had the lamp on
## its own plinth 6 cm under the dirt. bias 0.0 is exactly the old behaviour.
func _place_level(
	n: Node3D, p: Vector2, yaw: float, hx: float, hz: float, sink: float = 0.10, bias: float = 0.0, skirt: float = 0.0
) -> Node3D:
	var e := _extent(p, hx, hz, yaw)
	var lift: float = clampf((e.y - e.x) * bias, 0.0, maxf(skirt - 0.15, 0.0))
	n.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, e.x + lift - sink, p.y))
	add_child(n)
	return n


## Loose prop: sits on the ground and leans partway toward the surface normal.
func _prop_xform(p: Vector2, yaw: float, tilt: float = 0.55, y_off: float = 0.0) -> Transform3D:
	var nrm: Vector3 = map.normal_at(p.x, p.y)
	var up: Vector3 = Vector3.UP.lerp(nrm, tilt).normalized()
	var fwd := Vector3(cos(yaw), 0.0, -sin(yaw))
	var right: Vector3 = up.cross(fwd)
	if right.length_squared() < 1e-6:
		right = Vector3.RIGHT
	right = right.normalized()
	var f2: Vector3 = right.cross(up).normalized()
	return Transform3D(Basis(right, up, -f2), Vector3(p.x, map.height_at(p.x, p.y) + y_off, p.y))


## A scattered instance. Same grounding as _prop_xform, plus a per-instance size.
##
## Every MultiMesh here draws ONE source mesh, so without this the fifty-two rubble
## blocks in the ruins are literally the same stone stamped fifty-two times and read as
## sugar cubes laid out on the grass. Every source mesh is modelled with its base at or
## below y = 0 and its buried part below that, so scaling it cannot lift it off the
## ground. The scale is slightly anisotropic: uniform scaling still reads as one object
## at different distances.
func _scatter_xform(p: Vector2, yaw: float, tilt: float, y_off: float, lo: float, hi: float) -> Transform3D:
	var t := _prop_xform(p, yaw, tilt, y_off)
	var sc: float = _rng.randf_range(lo, hi)
	t.basis = (
		t.basis
		* Basis.from_scale(Vector3(sc * _rng.randf_range(0.90, 1.12), sc * _rng.randf_range(0.86, 1.15), sc * _rng.randf_range(0.90, 1.12)))
	)
	return t


## Tip a grounded transform away from vertical, `ang` radians in the compass direction
## `towards`. Used to drive palisade stakes in leaning outward from the fire; a ring of
## dead-vertical poles reads as a garden trellis.
static func _lean(t: Transform3D, towards: Vector2, ang: float) -> Transform3D:
	var out := Vector3(towards.x, 0.0, towards.y)
	if out.length_squared() < 1e-8:
		return t
	var axis: Vector3 = Vector3.UP.cross(out.normalized())
	if axis.length_squared() < 1e-8:
		return t
	t.basis = Basis(axis.normalized(), ang) * t.basis
	return t


func _place_prop(n: Node3D, p: Vector2, yaw: float, tilt: float = 0.55, y_off: float = 0.0) -> Node3D:
	n.transform = _prop_xform(p, yaw, tilt, y_off)
	add_child(n)
	return n


static func _yaw_to(from: Vector2, to: Vector2) -> float:
	var d: Vector2 = to - from
	if d.length_squared() < 1e-8:
		return 0.0
	d = d.normalized()
	return atan2(-d.y, d.x)


## MultiMesh with a real custom AABB and a visibility range, as the budget demands.
func _mm(nm: String, mesh: Mesh, xforms: Array, vis_end: float = 0.0, shadows: bool = true) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	var mesh_aabb: AABB = mesh.get_aabb()
	var total := AABB()
	for i in range(xforms.size()):
		var t: Transform3D = xforms[i]
		mm.set_instance_transform(i, t)
		var a: AABB = t * mesh_aabb
		total = a if i == 0 else total.merge(a)
	mmi.multimesh = mm
	mmi.custom_aabb = total.grow(0.5)
	if vis_end > 0.0:
		mmi.visibility_range_end = vis_end
		mmi.visibility_range_end_margin = vis_end * 0.15
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if not shadows:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi


func _vis(n: Node3D, end_dist: float) -> void:
	for c in n.get_children():
		if c is GeometryInstance3D:
			c.visibility_range_end = end_dist
			c.visibility_range_end_margin = end_dist * 0.15
			c.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if n is GeometryInstance3D:
		n.visibility_range_end = end_dist
		n.visibility_range_end_margin = end_dist * 0.15
		n.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


## Dense samples along every road, with the direction of travel.
func _road_samples(spacing: float) -> Array:
	var out: Array = []
	for poly in map.paths():
		var pts: Array = poly
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var d: float = a.distance_to(b)
			var n: int = maxi(1, int(d / spacing))
			for s in range(n):
				var t: float = float(s) / float(n)
				out.append({"p": a.lerp(b, t), "dir": (b - a).normalized()})
	return out


# ---------------------------------------------------------------------------
# The village of Panchavati
# ---------------------------------------------------------------------------
func _village_ok(p: Vector2, min_gap: float, taken: Array) -> bool:
	if not map.in_bounds(p.x, p.y):
		return false
	if p.distance_to(WorldMap.P_VILLAGE) > 52.0:
		return false
	if p.distance_to(SQUARE) < SQUARE_CLEAR + 1.5:
		return false
	if map.slope_at(p.x, p.y) > 0.13:
		return false
	if map.river_dist(p) < 21.0:
		return false
	if map.path_dist(p) < 6.2:
		return false
	var e := _extent(p, 3.8, 3.8)
	if e.y - e.x > 1.05:
		return false
	for q in taken:
		if p.distance_to(q) < min_gap:
			return false
	return true


func _build_village() -> void:
	var rg := _rng
	var taken: Array = []
	var anchors: Array = []

	# Frontage along the roads that leave the village: houses face the road they stand on.
	for s in _road_samples(7.0):
		var p: Vector2 = s.p
		if p.distance_to(WorldMap.P_VILLAGE) > 44.0:
			continue
		var side: Vector2 = Vector2(-s.dir.y, s.dir.x)
		for sgn in [-1.0, 1.0]:
			var off: float = rg.randf_range(7.8, 11.6)
			anchors.append({"p": p + side * sgn * off, "face": p})
	# A loose ring facing the open square.
	for i in range(16):
		var a: float = TAU * float(i) / 16.0 + rg.randf_range(-0.14, 0.14)
		var r: float = rg.randf_range(13.8, 21.0)
		var q: Vector2 = SQUARE + Vector2(cos(a), sin(a)) * r
		anchors.append({"p": q, "face": SQUARE})
	# Shuffle deterministically so the two families interleave.
	for i in range(anchors.size() - 1, 0, -1):
		var j: int = rg.randi_range(0, i)
		var tmp = anchors[i]
		anchors[i] = anchors[j]
		anchors[j] = tmp

	var huts: Array = []
	for a in anchors:
		if huts.size() >= 12:
			break
		var p: Vector2 = a.p
		if not _village_ok(p, 10.2, taken):
			continue
		taken.append(p)
		huts.append(a)

	var seed_i := 0
	for a in huts:
		seed_i += 1
		var p: Vector2 = a.p
		var yaw: float = _yaw_to(p, a.face) + rg.randf_range(-0.18, 0.18)
		var n := Arch.hut(seed_i * 7 + 3)
		_place_level(n, p, yaw, 3.6, 3.6, 0.12)
		_vis(n, 420.0)
		_hut_spots.append({"p": p, "yaw": yaw})

	# Granaries tucked behind houses.
	var gsp: Array = []
	for i in range(_hut_spots.size()):
		if gsp.size() >= 4:
			break
		var h: Dictionary = _hut_spots[i]
		var back: float = h.yaw + PI + rg.randf_range(-0.6, 0.6)
		var q: Vector2 = h.p + Vector2(cos(back), -sin(back)) * rg.randf_range(6.0, 8.5)
		if not _village_ok(q, 5.5, taken):
			continue
		taken.append(q)
		gsp.append(q)
		var g := Arch.granary(i * 13 + 5)
		_place_level(g, q, rg.randf_range(0.0, TAU), 2.2, 2.2, 0.05)
		_vis(g, 300.0)

	# The well, just off the centre of the square so the banyan keeps the middle.
	var wp: Vector2 = SQUARE + Vector2(-4.6, -3.4)
	var w := Arch.well()
	_place_level(w, wp, rg.randf_range(0.0, TAU), 2.4, 2.4, 0.05)
	_vis(w, 320.0)
	_poi.append({"name": "The Village Well", "position": _gv(wp), "radius": 6.0, "kind": "landmark"})

	# Working ground: racks, carts, washing, hearths.
	var work: Array = []
	for h in _hut_spots:
		var yaw: float = h.yaw
		for s in range(3):
			var a: float = yaw + rg.randf_range(-1.25, 1.25)
			var d: float = rg.randf_range(4.6, 8.0)
			work.append(h.p + Vector2(cos(a), -sin(a)) * d)

	var racks := 0
	for q in work:
		if racks >= 6:
			break
		if map.slope_at(q.x, q.y) > 0.14 or map.path_dist(q) < 4.0:
			continue
		if rg.randf() > 0.45:
			continue
		racks += 1
		var r := Arch.drying_rack(racks * 3)
		_place_prop(r, q, rg.randf_range(0.0, TAU), 0.35)
		_vis(r, 190.0)
	var lines := 0
	for q in work:
		if lines >= 3:
			break
		if map.slope_at(q.x, q.y) > 0.10 or map.path_dist(q) < 5.0:
			continue
		if rg.randf() > 0.30:
			continue
		lines += 1
		var wl := Arch.washing_line(lines * 5, rg.randf_range(4.0, 6.0))
		_place_prop(wl, q, rg.randf_range(0.0, TAU), 0.25)
		_vis(wl, 190.0)
	var fires := 0
	for q in work:
		if fires >= 4:
			break
		if map.slope_at(q.x, q.y) > 0.12 or map.path_dist(q) < 4.5:
			continue
		if rg.randf() > 0.35:
			continue
		fires += 1
		var f := Arch.firepit(fires * 11, fires % 2 == 0)
		_place_prop(f, q, rg.randf_range(0.0, TAU), 0.75)
		_vis(f, 180.0)

	# Two carts standing at the road edge.
	var carts := 0
	for s in _road_samples(11.0):
		if carts >= 2:
			break
		var p2: Vector2 = s.p
		if p2.distance_to(WorldMap.P_VILLAGE) > 40.0:
			continue
		var side2: Vector2 = Vector2(-s.dir.y, s.dir.x)
		var q2: Vector2 = p2 + side2 * (5.2 if carts == 0 else -5.4)
		if map.slope_at(q2.x, q2.y) > 0.12:
			continue
		carts += 1
		var c := Arch.cart(carts * 17)
		_place_prop(c, q2, atan2(-s.dir.y, s.dir.x) + PI * 0.5, 0.45)
		_vis(c, 220.0)

	# A goat pen on the edge of the settled ground.
	var pen_c: Vector2 = SQUARE + Vector2(19.0, 15.0)
	var pen: Array = []
	for i in range(11):
		var a3: float = TAU * float(i) / 11.0
		var rr: float = 6.4 + sin(a3 * 3.0) * 1.5
		var q3: Vector2 = pen_c + Vector2(cos(a3) * rr * 1.25, sin(a3) * rr)
		pen.append(_gv(q3))
	pen.append(pen[0])
	var fn := Arch.fence(pen, 1.15, 21)
	add_child(fn)
	_vis(fn, 240.0)

	# A lit diya at four doorways. Four shadowless omni lights is a negligible cost and
	# it is the difference between a village and a model village once the sun goes down.
	var lamps := 0
	for h in _hut_spots:
		if lamps >= 4 or (lamps + 1) * 3 > _hut_spots.size():
			break
		if rg.randf() > 0.55:
			continue
		lamps += 1
		var lq: Vector2 = (
			h.p + Vector2(cos(h.yaw), -sin(h.yaw)) * 4.1 + Vector2(cos(h.yaw + 1.5), -sin(h.yaw + 1.5)) * rg.randf_range(-0.7, 0.7)
		)
		var dl := Arch.oil_lamp(true)
		_place_prop(dl, lq, 0.0, 0.9)
		_vis(dl, 150.0)

	# Pots and baskets by the doorways and around the well.
	var pot_x: Array = []
	var bas_x: Array = []
	for h in _hut_spots:
		var yaw2: float = h.yaw
		for s in range(3):
			var a4: float = yaw2 + rg.randf_range(-0.9, 0.9)
			var d2: float = rg.randf_range(3.9, 5.4)
			var q4: Vector2 = h.p + Vector2(cos(a4), -sin(a4)) * d2
			if rg.randf() < 0.62:
				pot_x.append(_scatter_xform(q4, rg.randf_range(0.0, TAU), 0.8, 0.0, 0.78, 1.30))
			else:
				bas_x.append(_scatter_xform(q4, rg.randf_range(0.0, TAU), 0.8, 0.0, 0.80, 1.24))
	for i in range(6):
		var a5: float = TAU * float(i) / 6.0 + rg.randf_range(-0.35, 0.35)
		var q5: Vector2 = wp + Vector2(cos(a5), sin(a5)) * rg.randf_range(2.4, 4.2)
		pot_x.append(_scatter_xform(q5, rg.randf_range(0.0, TAU), 0.8, 0.0, 0.78, 1.30))
	for i in range(8):
		var q6: Vector2 = SQUARE + Vector2(rg.randf_range(-14, 14), rg.randf_range(-14, 14))
		if q6.distance_to(SQUARE) < 7.0:
			continue
		bas_x.append(_scatter_xform(q6, rg.randf_range(0.0, TAU), 0.8, 0.0, 0.80, 1.24))
	_mm("VillagePots", Arch.water_pot_mesh(4), pot_x, 165.0)
	_mm("VillageBaskets", Arch.basket_mesh(6), bas_x, 150.0)

	_poi.append({"name": "Panchavati", "position": _gv(SQUARE), "radius": 62.0, "kind": "village"})


# ---------------------------------------------------------------------------
# The shrine on the knoll
# ---------------------------------------------------------------------------
func _build_shrine() -> void:
	var rg := _rng
	var e := _extent(TEMPLE, TEMPLE_HX, TEMPLE_HZ)
	var plinth_top: float = e.y + 1.45
	var foundation: float = plinth_top - (e.x - 1.1)
	var sh := Arch.shrine(foundation)
	sh.transform = Transform3D(Basis.IDENTITY, Vector3(TEMPLE.x, plinth_top, TEMPLE.y))
	add_child(sh)

	# The stair that lifts the road out of its cut onto the plateau.
	var a: Vector3 = _gv(KNOLL_STAIR_A)
	var b: Vector3 = _gv(KNOLL_STAIR_B)
	var st := Arch.stone_steps(a, b + Vector3(0, 0.05, 0), 3.6)
	add_child(st)

	# Torana at the head of the stair, straddling the processional path.
	var gp := Vector2(166.4, -72.4)
	var gt := Arch.gate(3)
	_place_level(gt, gp, PI * 0.5, 0.9, 2.4, 0.05)

	# Flagstone processional: north-south along the plateau lip, then west to the steps.
	var route: Array = []
	for i in range(15):
		route.append(Vector2(166.4, lerpf(-67.0, -79.0, float(i) / 14.0)))
	for i in range(1, 6):
		route.append(Vector2(lerpf(166.4, 163.6, float(i) / 5.0), -79.0))
	var flags: Array = []
	for i in range(route.size()):
		var c: Vector2 = route[i]
		for s in range(3):
			var q: Vector2 = c + Vector2(rg.randf_range(-1.5, 1.5), rg.randf_range(-0.55, 0.55))
			flags.append(_scatter_xform(q, rg.randf_range(0.0, TAU), 1.0, 0.04, 0.82, 1.26))
	_mm("ShrineFlagstones", Arch.flagstone_mesh(2), flags, 220.0, false)

	# Lamps line the way up.
	for i in range(6):
		var t: float = float(i) / 5.0
		var c2: Vector2 = Vector2(167.9, lerpf(-68.5, -79.5, t))
		var lp := Arch.oil_lamp(true)
		_place_prop(lp, c2, 0.0, 1.0)
	# A wayside shrine at the foot of the knoll stair, where pilgrims arrive.
	var ws := Arch.shrine_small(4)
	# shrine_small carries a 0.90 m buried plinth course, so it can be lifted most of the
	# way to the high side of its footprint without ever showing daylight underneath.
	_place_level(ws, Vector2(157.5, -62.0), _yaw_to(Vector2(157.5, -62.0), KNOLL_STAIR_A), 1.3, 1.2, 0.05, 0.9, 0.90)

	_poi.append(
		{"name": "The Shrine of the Rising Sun", "position": Vector3(TEMPLE.x, plinth_top, TEMPLE.y), "radius": 30.0, "kind": "shrine"}
	)
	_poi.append({"name": "The Knoll Stair", "position": a, "radius": 10.0, "kind": "landmark"})


# ---------------------------------------------------------------------------
# The ruins
# ---------------------------------------------------------------------------
## A collapsed hall: a broken plinth, two rows of toppled pillars, wall fragments half
## swallowed by the ground. No signage; the plan does the talking.
func _build_ruins() -> void:
	var rg := _rng
	var C := WorldMap.P_RUINS
	var ang: float = 0.42  # the hall's long axis
	var ax := Vector2(cos(ang), sin(ang))
	var az := Vector2(-sin(ang), cos(ang))
	var to_w := func(u: float, v: float) -> Vector2: return C + ax * u + az * v
	var HX: float = 11.0
	var HZ: float = 7.0

	# --- the plinth, its edges collapsed ---------------------------------
	var e := _extent(C, HX, HZ, -ang)
	var base: float = e.x - 0.9
	var top: float = e.y + 0.62
	var k := Arch.Kit.new()
	var bxf := Basis(Vector3.UP, ang)
	# The floor is laid as individual slabs. A single clean slab read as a modern deck;
	# gaps, tipped stones and missing corners are what makes it look abandoned.
	#
	# The first version laid them on an exact 11x7 lattice at one size, one height and a
	# +/-2.5 degree tip, in the temple's own bright dressed stone. From twenty metres
	# that read as a bathroom floor: a regular chessboard of clean pale tiles with dark
	# grout, brighter than the hall it was supposed to be the ruin of. What kills the
	# lattice is per-slab SIZE and OFFSET (so no two joints line up across a row) and a
	# height spread wide enough that some stones are visibly proud and others have sunk;
	# what kills the chessboard is the weathered "stone_ruin" pair.
	var sx: int = 11
	var sz: int = 7
	var cw: float = (2.0 * HX - 2.0) / float(sx)
	var cd: float = (2.0 * HZ - 2.0) / float(sz)
	for j in range(sz):
		for i in range(sx):
			var u: float = lerpf(-HX + 1.0, HX - 1.0, float(i) / float(sx - 1))
			var v: float = lerpf(-HZ + 1.0, HZ - 1.0, float(j) / float(sz - 1))
			var edge: float = maxf(absf(u) / HX, absf(v) / HZ)
			# survival falls off toward the edges, plus a patchy noise term. The middle
			# loses stones too, otherwise the ruin is a solid rectangle with a frayed hem.
			var live: float = 1.16 - edge * 1.05 + 0.34 * sin(u * 0.9 + 1.7) * cos(v * 1.3)
			if rg.randf() > clampf(live, 0.0, 1.0):
				continue
			var tip: float = rg.randf_range(-0.10, 0.10)
			var fw: float = rg.randf_range(0.70, 0.98)
			var fd: float = rg.randf_range(0.70, 0.98)
			# shove each stone off its cell centre by whatever the shrinkage frees up
			var ou: float = rg.randf_range(-0.5, 0.5) * cw * (1.0 - fw)
			var ov: float = rg.randf_range(-0.5, 0.5) * cd * (1.0 - fd)
			# most stones have settled; a few have been heaved up by roots
			var dy: float = rg.randf_range(-0.19, 0.07)
			if rg.randf() < 0.12:
				dy += rg.randf_range(0.06, 0.17)
			k.box(
				"stone_ruin",
				Transform3D(
					bxf.rotated(Vector3.UP, rg.randf_range(-0.16, 0.16)).rotated(bxf * Vector3.RIGHT, tip).rotated(
						bxf * Vector3.BACK, rg.randf_range(-0.07, 0.07)
					),
					Vector3(u + ou, top - base - 0.30 + dy, v + ov)
				),
				Vector3(cw * fw, 0.62, cd * fd),
				Vector2(u * 0.6 + ou, v * 0.6 + ov)
			)
	# the surviving kerb, in patches
	var n_edge := 30
	for i in range(n_edge):
		var t: float = float(i) / float(n_edge)
		var perim: float = t * 2.0 * (HX + HZ)
		var eu: float
		var ev: float
		if perim < 2.0 * HX:
			eu = -HX + perim
			ev = -HZ
		elif perim < 2.0 * HX + 2.0 * HZ:
			eu = HX
			ev = -HZ + (perim - 2.0 * HX)
		elif perim < 4.0 * HX + 2.0 * HZ:
			eu = HX - (perim - 2.0 * HX - 2.0 * HZ)
			ev = HZ
		else:
			eu = -HX
			ev = HZ - (perim - 4.0 * HX - 2.0 * HZ)
		if 0.5 + 0.5 * sin(t * 19.0 + 1.3) * cos(t * 8.0) < 0.34:
			continue
		var seg: float = 2.0 * (HX + HZ) / float(n_edge)
		k.box(
			"stone_ruin",
			Transform3D(
				bxf.rotated(Vector3.UP, rg.randf_range(-0.10, 0.10)).rotated(bxf * Vector3.RIGHT, rg.randf_range(-0.09, 0.09)),
				Vector3(eu, top - base - 0.30 + rg.randf_range(-0.22, 0.06), ev)
			),
			Vector3(seg * rg.randf_range(0.74, 0.96), 1.05, rg.randf_range(0.85, 1.05)),
			Vector2(eu * 0.6, ev * 0.6)
		)
	# The earth core the slabs are bedded in. It is EARTH, not masonry: when it was
	# dressed stone the gaps between the slabs read as clean grout lines and gave the
	# floor its tiled look. Its top sits 0.18 m under the slab tops, not 0.79 m: with
	# three quarters of every 0.62 m slab standing clear the floor was fifty separate
	# crates sitting on a lawn instead of a pavement with earth in its joints.
	k.box(
		"bed",
		Transform3D(bxf, Vector3(0.0, (top - base) * 0.5 - 0.22, 0.0)),
		Vector3(HX * 2.0 - 1.0, top - base, HZ * 2.0 - 1.0),
		Vector2(3.1, 1.7)
	)
	var plinth := k.node("RuinPlinth")
	plinth.transform = Transform3D(Basis(Vector3.UP, ang), Vector3(C.x, base, C.y))
	add_child(plinth)

	# --- two rows of pillars, most of them down --------------------------
	var pill := 0
	for row in range(2):
		var v0: float = -3.4 + 6.8 * float(row)
		for i in range(6):
			var u0: float = lerpf(-8.6, 8.6, float(i) / 5.0)
			var p: Vector2 = to_w.call(u0, v0)
			pill += 1
			if rg.randf() < 0.42:
				# toppled: the drum lies where it rolled
				var fp: Vector2 = p + Vector2(rg.randf_range(-2.4, 2.4), rg.randf_range(-2.4, 2.4))
				var fl := Arch.fallen_lintel(pill * 9 + 2)
				_place_prop(fl, fp, rg.randf_range(0.0, TAU), 0.85, -0.10)
				_vis(fl, 260.0)
				continue
			var bp := Arch.broken_pillar(pill * 5 + 1)
			var y: float = map.height_at(p.x, p.y)
			bp.transform = Transform3D(
				Basis(Vector3.UP, rg.randf_range(0.0, TAU)) * Basis(Vector3.BACK, rg.randf_range(-0.045, 0.045)),
				Vector3(p.x, maxf(y, top - 0.55), p.y)
			)
			add_child(bp)
			_vis(bp, 300.0)

	# --- broken enclosure walls ------------------------------------------
	var wall_slots := [
		[-12.5, -8.6, 0.0],
		[-4.0, -8.6, 0.0],
		[7.2, -8.6, 0.0],
		[-12.5, 8.6, 0.0],
		[3.0, 8.6, 0.0],
		[11.5, 8.6, 0.0],
		[-13.4, -3.0, PI * 0.5],
		[-13.4, 4.5, PI * 0.5],
		[13.4, 1.5, PI * 0.5],
	]
	for i in range(wall_slots.size()):
		var ws: Array = wall_slots[i]
		var p2: Vector2 = to_w.call(ws[0], ws[1])
		if map.slope_at(p2.x, p2.y) > 0.34:
			continue
		var rw := Arch.ruin_wall(i * 3 + 11)
		_place_level(rw, p2, ang + ws[2] + rg.randf_range(-0.08, 0.08), 3.6, 0.7, 0.55)
		_vis(rw, 320.0)

	# --- a threshold and fallen architraves at the east end --------------
	for i in range(4):
		var p3: Vector2 = to_w.call(rg.randf_range(-10.0, 10.0), rg.randf_range(-6.0, 6.0))
		var fl2 := Arch.fallen_lintel(i * 21 + 7)
		_place_prop(fl2, p3, rg.randf_range(0.0, TAU), 0.8, top - map.height_at(p3.x, p3.y) - 0.12)
		_vis(fl2, 260.0)

	# --- rubble ----------------------------------------------------------
	var rub: Array = []
	for i in range(52):
		var a2: float = rg.randf_range(0.0, TAU)
		var r2: float = sqrt(rg.randf()) * 22.0
		var q: Vector2 = C + Vector2(cos(a2), sin(a2) * 0.8) * r2
		if map.slope_at(q.x, q.y) > 0.4:
			continue
		rub.append(_scatter_xform(q, rg.randf_range(0.0, TAU), 0.9, -0.10, 0.50, 1.55))
	_mm("RuinRubble", Arch.stone_block_mesh(3), rub, 230.0)

	_poi.append({"name": "The Broken Hall", "position": _gv(C), "radius": 32.0, "kind": "ruin"})


# ---------------------------------------------------------------------------
# The rakshasa camp
# ---------------------------------------------------------------------------
## The camp sits on the floor of a steep ravine. Rather than guess where that floor is,
## scan for it: the flattest low cells within the hollow become the usable ground.
func _find_floor(c: Vector2, radius: float, max_slope: float, max_rise: float) -> Array:
	var base: float = map.height_at(c.x, c.y)
	var out: Array = []
	var step: float = 2.0
	var n: int = int(radius / step)
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var q := c + Vector2(float(i) * step, float(j) * step)
			if q.distance_to(c) > radius or not map.in_bounds(q.x, q.y):
				continue
			if map.slope_at(q.x, q.y) > max_slope:
				continue
			if map.height_at(q.x, q.y) - base > max_rise:
				continue
			out.append(q)
	return out


func _build_camp() -> void:
	var rg := _rng
	var C := WorldMap.P_FOREST_CAMP
	var floor_pts: Array = _find_floor(C, 26.0, 0.34, 5.0)
	if floor_pts.is_empty():
		floor_pts = [C]
	# hearth at the centre of the hollow
	var hearth: Vector2 = C
	var f := Arch.firepit(77, true)
	_place_prop(f, hearth, rg.randf_range(0.0, TAU), 0.6)
	_vis(f, 200.0)

	# lean-tos, pushed against the walls of the ravine and facing the fire
	var placed: Array = []
	var lean := 0
	for idx in range(floor_pts.size()):
		if lean >= 4:
			break
		var q: Vector2 = floor_pts[(idx * 37) % floor_pts.size()]
		var d: float = q.distance_to(hearth)
		if d < 4.5 or d > 10.0:
			continue
		var bad := false
		for t in placed:
			if q.distance_to(t) < 5.5:
				bad = true
		if bad:
			continue
		placed.append(q)
		lean += 1
		var lt := Arch.lean_to(lean * 9 + 4)
		_place_level(lt, q, _yaw_to(q, hearth), 1.8, 1.6, 0.15)
		_vis(lt, 220.0)

	# The palisade.
	#
	# Two wrong versions before this one. A ring by angle put half the stakes up a
	# 40-degree ravine wall. Scattering them over every flat cell between 6 m and 15 m
	# fixed the grounding but produced thirty sharpened poles standing a metre and a half
	# apart on open grass, which reads as dropped pencils, not as a defended camp: a
	# palisade is legible only when the stakes are a LINE and close enough to touch.
	#
	# So: sweep the perimeter by angle, and for each angle SNAP to the nearest scanned
	# floor cell within a couple of metres of the nominal radius. Angles where the floor
	# has run out simply get no stake, which is what leaves the gaps that make it read as
	# a half-finished rakshasa work rather than as fence panels.
	var stakes: Array = []
	var bones: Array = []
	var used: Array = []
	var ring_n := 64
	for ri in range(ring_n):
		var ang2: float = TAU * float(ri) / float(ring_n)
		var dir2 := Vector2(cos(ang2), sin(ang2))
		var want: float = 9.4 + 1.1 * sin(ang2 * 3.0 + 0.6)
		# March out along this bearing and take the buildable radius nearest `want`.
		# Snapping to _find_floor's 2 m scan lattice instead collapsed four neighbouring
		# angles onto one cell and left a ring of fourteen poles three metres apart.
		var base_h: float = map.height_at(hearth.x, hearth.y)
		var best: Vector2 = Vector2.INF
		var best_d: float = 3.0
		var r2: float = want - 3.0
		while r2 <= want + 3.0:
			var cand: Vector2 = hearth + dir2 * r2
			if map.in_bounds(cand.x, cand.y) and map.slope_at(cand.x, cand.y) <= 0.26 and map.height_at(cand.x, cand.y) - base_h <= 5.0:
				var dd: float = absf(r2 - want)
				if dd < best_d:
					best_d = dd
					best = cand
			r2 += 0.25
		if best == Vector2.INF:
			continue
		var jitter: Vector2 = Vector2(rg.randf_range(-0.30, 0.30), rg.randf_range(-0.30, 0.30))
		var q2: Vector2 = best + jitter
		var clash := false
		for t in used:
			if q2.distance_to(t) < 0.55:
				clash = true
		for t in placed:
			if q2.distance_to(t) < 2.4:
				clash = true
		if clash:
			continue
		used.append(q2)
		# driven in leaning OUTWARD from the fire, the way a stake is set against a charge
		stakes.append(
			_lean(_scatter_xform(q2, ang2 + rg.randf_range(-0.5, 0.5), 0.20, -0.14, 0.80, 1.34), dir2, rg.randf_range(0.13, 0.30))
		)
		if stakes.size() >= 46:
			break
	for idx in range(floor_pts.size()):
		var q3: Vector2 = floor_pts[(idx * 11 + 3) % floor_pts.size()]
		if q3.distance_to(hearth) > 9.0:
			continue
		if map.slope_at(q3.x, q3.y) > 0.3:
			continue
		bones.append(
			_scatter_xform(
				q3 + Vector2(rg.randf_range(-0.8, 0.8), rg.randf_range(-0.8, 0.8)), rg.randf_range(0.0, TAU), 1.0, 0.02, 0.68, 1.38
			)
		)
		if bones.size() >= 30:
			break
	if not stakes.is_empty():
		_mm("CampStakes", Arch.stake_mesh(3), stakes, 220.0)
	if not bones.is_empty():
		_mm("CampBones", Arch.bone_mesh(5), bones, 130.0, false)
	# a rack of drying hides and a second hearth, so the camp reads as occupied
	for idx in range(floor_pts.size()):
		var q4: Vector2 = floor_pts[(idx * 47 + 13) % floor_pts.size()]
		var d4: float = q4.distance_to(hearth)
		if d4 < 4.0 or d4 > 8.0 or map.slope_at(q4.x, q4.y) > 0.22:
			continue
		var r4 := Arch.drying_rack(919)
		_place_prop(r4, q4, _yaw_to(q4, hearth), 0.3)
		_vis(r4, 200.0)
		break

	_poi.append({"name": "The Rakshasa Camp", "position": _gv(C), "radius": 24.0, "kind": "camp"})


# ---------------------------------------------------------------------------
# The paddy fields
# ---------------------------------------------------------------------------
func _build_fields() -> void:
	var rg := _rng
	var C := WorldMap.P_FIELDS
	var ang: float = -0.28
	var ax := Vector2(cos(ang), sin(ang))
	var az := Vector2(-sin(ang), cos(ang))
	var plots := 0
	for gy in range(-2, 3):
		for gx in range(-2, 3):
			if plots >= 9:
				break
			var w: float = 13.0 + float((gx + gy) % 3) * 2.6
			var h: float = 11.0 + float((gx * 2 + gy) % 3) * 2.2
			var cu: float = float(gx) * 17.5 + rg.randf_range(-1.2, 1.2)
			var cv: float = float(gy) * 14.5 + rg.randf_range(-1.2, 1.2)
			var centre: Vector2 = C + ax * cu + az * cv
			# a plot only works on genuinely level, dry, road-free ground
			var e := _extent(centre, w * 0.5, h * 0.5, -ang)
			if e.y - e.x > 1.5:
				continue
			if map.river_dist(centre) < 16.0 or map.path_dist(centre) < 7.0:
				continue
			if centre.distance_to(WorldMap.P_FIELDS) > 46.0:
				continue
			plots += 1
			var ring: Array = []
			var corners := [Vector2(-w * 0.5, -h * 0.5), Vector2(w * 0.5, -h * 0.5), Vector2(w * 0.5, h * 0.5), Vector2(-w * 0.5, h * 0.5)]
			for ci in range(5):
				var a0: Vector2 = corners[ci % 4]
				var b0: Vector2 = corners[(ci + 1) % 4]
				var steps: int = maxi(2, int(a0.distance_to(b0) / 2.4))
				for s in range(steps):
					var lp: Vector2 = a0.lerp(b0, float(s) / float(steps))
					var wp: Vector2 = centre + ax * lp.x + az * lp.y
					ring.append(_gv(wp))
				if ci == 3:
					break
			ring.append(ring[0])
			var b := Arch.bund(ring, 0.82, 0.40, 0.24)
			add_child(b)
			_vis(b, 300.0)
	# two racks on the field edge
	for i in range(2):
		var q: Vector2 = C + ax * (float(i) * 22.0 - 11.0) + az * 24.0
		if map.slope_at(q.x, q.y) > 0.14:
			continue
		var r := Arch.drying_rack(i * 31 + 8)
		_place_prop(r, q, rg.randf_range(0.0, TAU), 0.3)
		_vis(r, 190.0)
	_poi.append({"name": "The Paddy Fields", "position": _gv(C), "radius": 46.0, "kind": "field"})


# ---------------------------------------------------------------------------
# Wayside: gates, milestones, small shrines
# ---------------------------------------------------------------------------
func _build_wayside() -> void:
	var rg := _rng
	var samples := _road_samples(4.0)

	# The gate where the eastern road enters Panchavati.
	var best_gate: Dictionary = {}
	var best_d: float = 1e9
	for s in samples:
		var d: float = s.p.distance_to(WorldMap.P_VILLAGE)
		if d < 20.0 or d > 34.0:
			continue
		if s.p.x < WorldMap.P_VILLAGE.x:
			continue
		var e := _extent(s.p, 3.0, 3.0)
		if e.y - e.x > 0.9:
			continue
		if absf(d - 26.0) < best_d:
			best_d = absf(d - 26.0)
			best_gate = s
	if not best_gate.is_empty():
		var gp: Vector2 = best_gate.p
		var gyaw: float = atan2(-best_gate.dir.y, best_gate.dir.x)
		var g := Arch.gate(9)
		_place_level(g, gp, gyaw, 1.0, 2.6, 0.05)
		_poi.append({"name": "The Village Gate", "position": _gv(gp), "radius": 8.0, "kind": "gate"})

	# Wayside shrines: where the roads fork, climb or leave a settlement.
	var shrine_at := [
		Vector2(-74.0, 27.0),
		Vector2(-10.0, -6.0),
		Vector2(96.0, -44.0),
		Vector2(-168.0, 6.0),
		Vector2(24.0, -140.0),
	]
	var si := 0
	for target in shrine_at:
		var near: Dictionary = {}
		var nd: float = 1e9
		for s in samples:
			var d2: float = s.p.distance_to(target)
			if d2 < nd:
				nd = d2
				near = s
		if near.is_empty() or nd > 12.0:
			continue
		var side: Vector2 = Vector2(-near.dir.y, near.dir.x)
		var q: Vector2 = near.p + side * 4.2
		if map.slope_at(q.x, q.y) > 0.30 or map.is_underwater(q.x, q.y):
			q = near.p - side * 4.2
		if map.slope_at(q.x, q.y) > 0.34 or map.is_underwater(q.x, q.y):
			continue
		si += 1
		var ws := Arch.shrine_small(si * 7)
		_place_level(ws, q, _yaw_to(q, near.p), 1.3, 1.2, 0.08, 0.9, 0.90)
		_vis(ws, 280.0)
		_poi.append({"name": "Wayside Shrine", "position": _gv(q), "radius": 5.0, "kind": "wayside"})

	# Milestones: a stone every fifty paces or so, on the shoulder of every road.
	var stones: Array = []
	var acc: float = 0.0
	var last: Vector2 = samples[0].p
	for s in samples:
		acc += s.p.distance_to(last)
		last = s.p
		if acc < 46.0:
			continue
		acc = 0.0
		var side2: Vector2 = Vector2(-s.dir.y, s.dir.x)
		var sgn: float = 1.0 if stones.size() % 2 == 0 else -1.0
		var q2: Vector2 = s.p + side2 * sgn * 3.0
		if not map.in_bounds(q2.x, q2.y) or map.is_underwater(q2.x, q2.y):
			continue
		if map.slope_at(q2.x, q2.y) > 0.45:
			continue
		stones.append(_scatter_xform(q2, atan2(-s.dir.y, s.dir.x), 0.7, -0.02, 0.88, 1.16))
	if not stones.is_empty():
		_mm("Milestones", Arch.milestone_mesh(4), stones, 260.0)


# ---------------------------------------------------------------------------
# The ford
# ---------------------------------------------------------------------------
## Span the Godavari where the east road crosses it. The banks are found by walking
## outward from the ford until the ground climbs clear of the local water surface, so
## the bridge is exactly as long as the river is wide at that point and both of its
## feet land on real ground.
func _build_ford() -> void:
	var rg := _rng
	var C := WorldMap.P_FORD
	var d: Vector2 = (Vector2(-10.0, -6.0) - Vector2(-52.0, 17.0)).normalized()
	var ends: Array = []
	for sgn in [-1.0, 1.0]:
		var found: Vector2 = C + d * sgn * 30.0
		var t: float = 2.0
		while t < 34.0:
			var q: Vector2 = C + d * sgn * t
			var wy: float = map.water_y_at(q.x, q.y)
			var h: float = map.height_at(q.x, q.y)
			# a real bank: above water here AND still above two metres further on
			var q2: Vector2 = C + d * sgn * (t + 2.0)
			if h > wy + 0.25 and map.height_at(q2.x, q2.y) > map.water_y_at(q2.x, q2.y) + 0.35:
				found = q + d * sgn * 1.6
				break
			t += 0.5
		ends.append(found)
	var a: Vector2 = ends[0]
	var b: Vector2 = ends[1]
	var ya: float = map.height_at(a.x, a.y) + 0.28
	var yb: float = map.height_at(b.x, b.y) + 0.28
	var length: float = a.distance_to(b)
	var wy_mid: float = map.water_y_at(C.x, C.y)
	var mid_y: float = (ya + yb) * 0.5
	# the deck must clear the water at mid-span whatever the banks are doing
	var camber: float = clampf(wy_mid + 1.55 - mid_y, 0.8, 2.6)
	var dir: Vector2 = (b - a).normalized()
	var yaw: float = atan2(-dir.y, dir.x)
	var pitch: float = atan2(yb - ya, length)
	var br := Arch.bridge(length, camber, 8.0)
	br.transform = Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, pitch), Vector3((a.x + b.x) * 0.5, mid_y, (a.y + b.y) * 0.5))
	add_child(br)

	# Boulders in the shallows on either bank, where people still wade across.
	var stones: Array = []
	for i in range(14):
		var t2: float = rg.randf_range(0.0, 1.0)
		var side: Vector2 = Vector2(-dir.y, dir.x)
		var q3: Vector2 = a.lerp(b, t2) + side * rg.randf_range(6.0, 13.0) * (1.0 if i % 2 == 0 else -1.0)
		if not map.in_bounds(q3.x, q3.y):
			continue
		var depth: float = map.water_depth_at(q3.x, q3.y)
		if depth > 1.3:
			continue
		stones.append(_scatter_xform(q3, rg.randf_range(0.0, TAU), 0.6, -0.25, 0.66, 1.45))
	if not stones.is_empty():
		_mm("FordStones", Arch.stepping_stone_mesh(7), stones, 200.0)

	_poi.append({"name": "The Ford of the Godavari", "position": _gv(C), "radius": 20.0, "kind": "crossing"})
	_poi.append(
		{
			"name": "The Timber Bridge",
			"position": Vector3((a.x + b.x) * 0.5, mid_y + camber, (a.y + b.y) * 0.5),
			"radius": 12.0,
			"kind": "landmark"
		}
	)
