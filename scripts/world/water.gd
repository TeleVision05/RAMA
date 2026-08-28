class_name RiverWater
extends Node3D
## The river Godavari: its surface ribbon, the falls in the northern gorge, the plunge
## pool and the standing water elsewhere in the vale.
##
## THERE IS NO GLOBAL WATER LEVEL. The river's surface descends ~44 m from the source
## in the north to the south-west exit, and drops ~21 m of that in one gorge. Every
## height in here comes from `WorldMap.water_y_at()`, which is the same field the
## terrain's own river carve used, so the ribbon and the bed it sits in cannot drift
## apart.
##
## The surface is a ribbon swept along `WorldMap.river_points()`:
##   * stations are placed along the centreline at an ADAPTIVE spacing - 2.2 m in the
##     flats, down to 0.55 m through the falls where the surface turns over hard,
##   * each station's left and right edges are found by MARCHING outward until the
##     terrain rises through the local water surface, so the water fills the channel
##     exactly and tucks under the bank instead of leaving a dry shelf or a floating rim,
##   * UV.x is metres across, UV.y is metres downstream, which is what lets the shader
##     scroll ripples with the current round every bend instead of along world X/Z,
##   * COLOR carries flow speed / churn / mid-channel / alpha mask (see water.gdshader).
##
## Budget: ~5.7 k triangles for the whole river, in ONE draw call (see _build_river_meshes
## for why it must be one).

const COLS: int = 7  # vertex columns across the ribbon
const STEP: float = 2.2  # station spacing in the flats, metres
const STEP_MIN: float = 0.55  # ... and through the falls
const SUB: float = 0.25  # centreline walk resolution, metres
const EDGE: float = WorldMap.HALF - 0.05  # the ribbon is CLIPPED to this, not truncated at it
const SHORE_STEP: float = 0.5  # shoreline search resolution, metres
const WIDEN: float = 0.75  # tuck this far past the shoreline, metres
const EDGE_DIP: float = 0.07  # and drop the outer column this far
const FALL_BULGE: float = 0.95  # how far the falling sheet arcs off the rock
const END_FADE: float = 4.0  # metres over which the ribbon's open ends fade out
const NO_WATER: float = -1.0e9  # `water_height_at` on dry land

## Where the fall lands. The map widens the channel into a basin around (34, -178).
const PLUNGE: Vector2 = Vector2(33.0, -181.5)
## The two bodies of standing water.
const GROVE_POND: Vector2 = WorldMap.P_HIDDEN_GROVE
## Fallback only. The washing pool belongs BESIDE the village well, and the village well
## belongs to Settlement, so at build time the pool asks Settlement where it put it (see
## `_find_well`) and only falls back to this. Measured 2026-08-28: Settlement puts it at
## SQUARE + (-4.6, -3.4) = (-127.6, 51.6). The previous value here was (-113, 51) - 14.6 m
## away, in open square with no well anywhere near it, which is how a water tank ended up
## standing on its own in the middle of the village.
const WELL_POOL: Vector2 = Vector2(-127.6, 51.6)

var map: WorldMap
var sky: Node = null  # SkySystem, if the caller has one

var _st: Array = []  # stations, see _build_stations()
var _fall_a: int = -1  # first station of the falls
var _fall_b: int = -1  # last station of the falls
var _pools: Array = []  # [{c: Vector2, level: float, r: float}]
var _river_mat: ShaderMaterial
var _falls_mat: ShaderMaterial
var _tris: int = 0
var _sky_t: float = -1.0  # hour the reflection tints were last built for


# ---------------------------------------------------------------------------
## `sky_system` is optional (Game passes it by arity; the render harnesses may not).
## Without it the water keeps the shader's own midday tints.
func setup(world_map: WorldMap, sky_system: Node = null) -> void:
	map = world_map
	sky = sky_system
	var t0 := Time.get_ticks_msec()
	_river_mat = _make_river_material()
	_falls_mat = _make_falls_material()
	_build_stations()
	_find_falls()
	_score_flow()
	_build_river_meshes()
	_build_falls_mesh()
	_build_mist()
	_build_pools()
	refresh_sky()
	print("[water] %d stations, %d tris, %d ms" % [_st.size(), _tris, Time.get_ticks_msec() - t0])


## Take the reflection's two sky tints from the sky that is actually being rendered,
## rather than re-deriving the time-of-day gradient here - two copies of that curve would
## drift apart the first time either is touched. The horizon tone is the environment's own
## fog colour (which SkySystem already blends day -> golden -> night); the zenith tone is
## that colour pulled towards blue by how high the sun is.
func refresh_sky() -> void:
	if _river_mat == null:
		return
	var horizon := Color(0.74, 0.78, 0.82)
	var zenith := Color(0.42, 0.56, 0.80)
	if sky and sky.has_method("light_level") and sky.env and sky.env.environment:
		var e: Environment = sky.env.environment
		var lvl: float = sky.light_level()
		# Not the fog colour as-is: what a grazing ray brings back near the horizon is the
		# far BANK - trees, rock, shadowed ground - as much as the sky, and taking the fog
		# colour neat left the river brighter than the wooded valley it runs through
		# (water_ingame_ford.png). 0.68 is that near-horizon band measured against the
		# terrain either side of it.
		horizon = e.fog_light_color * 0.68
		zenith = horizon.lerp(Color(0.30, 0.48, 0.86), 0.62 * lvl)
		zenith = zenith.lerp(Color(0.020, 0.030, 0.075), (1.0 - lvl) * 0.85)
		horizon = horizon.lerp(Color(0.035, 0.050, 0.095), (1.0 - lvl) * 0.70)
		_sky_t = sky.time_of_day
	_river_mat.set_shader_parameter("sky_horizon", horizon)
	_river_mat.set_shader_parameter("sky_tint", zenith)


## Called every frame by Game. The reflection tints are rebuilt only when the clock has
## actually moved a couple of minutes, so this is free on all but a handful of frames.
func update_focus(_pos: Vector3) -> void:
	if sky and absf(float(sky.time_of_day) - _sky_t) > 0.03:
		refresh_sky()


# --- materials -------------------------------------------------------------
## Defined here rather than in Mats: the water shader's parameter set is private to
## this system and nothing else in the world needs it.
func _make_river_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/water.gdshader")
	m.set_shader_parameter("normal_tex", _tex("water_normal"))
	m.set_shader_parameter("foam_tex", _tex("water_foam"))
	# Warm-country river: jade over the sand shallows, dark teal where it is deep. The
	# deep end is NOT near-black: what the eye gets back from deep water is light
	# scattered out of the column, and at (0.020, 0.086, 0.105) the middle of the river
	# measured luminance 0.06 from the bank at noon and read as wet asphalt.
	# The Godavari is a warm, silty, green river, not a Caribbean lagoon.
	m.set_shader_parameter("shallow_color", Color(0.286, 0.430, 0.330))
	m.set_shader_parameter("deep_color", Color(0.052, 0.118, 0.098))
	return m


## Screen-space refraction costs a full-resolution copy of the frame; the low quality
## tier gives it up and keeps the rest of the surface. Wired to the shader's
## `use_refraction`, which was declared but never read by anything.
func set_refraction(on: bool) -> void:
	if _river_mat:
		_river_mat.set_shader_parameter("use_refraction", on)


func _make_falls_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/waterfall.gdshader")
	m.set_shader_parameter("foam_tex", _tex("water_foam"))
	m.set_shader_parameter("normal_tex", _tex("water_normal"))
	return m


func _tex(n: String) -> Texture2D:
	var p := "res://assets/textures/%s.png" % n
	if not ResourceLoader.exists(p):
		push_warning("[water] missing texture " + n)
		return null
	return load(p)


# --- the centreline --------------------------------------------------------
## Half-channel width at a point. This mirrors `WorldMap._river_half_width`, which is
## private; it is only used as a SEARCH BOUND and for the containment test, because the
## real water edge is found by marching the terrain, so a small drift here is harmless.
static func half_width(p: Vector2) -> float:
	var t: float = clampf(inverse_lerp(-390.0, 340.0, p.y), 0.0, 1.0)
	var w: float = lerpf(4.0, 13.5, t)
	var d: float = p.distance_to(Vector2(34.0, -178.0))
	if d < 46.0:
		var s: float = 1.0 - d / 46.0
		w += s * s * (3.0 - 2.0 * s) * 16.0
	return w


func _build_stations() -> void:
	var raw: Array[Vector2] = map.river_points()
	# The centreline runs off both ends of the world; there is no terrain out there to
	# hold water, so the ribbon stops at the edge of the heightfield. It is CLIPPED to the
	# edge, not truncated at the last whole point inside it: truncating ended the sheet up
	# to 2 m short of the boundary and cut it square across 4.2 m of still-open channel at
	# the south-west exit, which is a rim hanging in mid air.
	var pts: Array[Vector2] = []
	for i in range(raw.size()):
		var p: Vector2 = raw[i]
		if _in_box(p):
			if pts.is_empty() and i > 0:
				pts.append(_clip_to_box(p, raw[i - 1]))
			pts.append(p)
		elif not pts.is_empty():
			pts.append(_clip_to_box(pts[pts.size() - 1], p))
			break
	if pts.size() < 4:
		push_error("[water] river centreline is empty inside the world bounds")
		return

	# Pass 1 - walk the polyline at a fixed fine resolution, recording the local water
	# surface as we go.
	var sp: Array[Vector2] = []
	var swy := PackedFloat32Array()
	var sdist := PackedFloat32Array()
	var run := 0.0
	sp.append(pts[0])
	swy.append(map.water_y_at(pts[0].x, pts[0].y))
	sdist.append(0.0)
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var seg: float = a.distance_to(b)
		var n: int = maxi(1, int(ceil(seg / SUB)))
		for s in range(1, n + 1):
			var q: Vector2 = a.lerp(b, float(s) / float(n))
			run += sp[sp.size() - 1].distance_to(q)
			sp.append(q)
			swy.append(map.water_y_at(q.x, q.y))
			sdist.append(run)

	# Pass 2 - gradient of the water surface, smoothed over +/-1.5 m so a single noisy
	# cell cannot pretend to be a waterfall.
	var n_sub := sp.size()
	var grad := PackedFloat32Array()
	grad.resize(n_sub)
	for i in range(n_sub):
		var lo: int = i
		var hi: int = i
		while lo > 0 and sdist[i] - sdist[lo] < 1.5:
			lo -= 1
		while hi < n_sub - 1 and sdist[hi] - sdist[i] < 1.5:
			hi += 1
		var ds: float = maxf(sdist[hi] - sdist[lo], 0.05)
		grad[i] = absf(swy[hi] - swy[lo]) / ds

	# Pass 3 - emit stations, packing them tighter where the surface tips over.
	_st.clear()
	var acc := 0.0
	var d3 := 0.0
	var last := 0
	_push_station(sp, swy, grad, 0, 0.0)
	for i in range(1, n_sub):
		var d2: float = sdist[i] - sdist[i - 1]
		var dy: float = swy[i] - swy[i - 1]
		d3 += sqrt(d2 * d2 + dy * dy)
		acc += d2
		var want: float = clampf(STEP / (1.0 + grad[i] * 4.0), STEP_MIN, STEP)
		if acc >= want or i == n_sub - 1:
			_push_station(sp, swy, grad, i, d3)
			acc = 0.0
			last = i
	if last != n_sub - 1:
		_push_station(sp, swy, grad, n_sub - 1, d3)

	# Edges. Marching outward from the centreline until the ground rises through the
	# water surface is what makes the river fill its channel exactly.
	for i in range(_st.size()):
		var st: Dictionary = _st[i]
		var t3 := _dir_along(i)
		var nn := Vector2(t3.z, -t3.x).normalized()  # cross-flow, +ve = column order
		st.n = nn
		var hw: float = half_width(st.p)
		st.hw = hw
		st.rl = _shore(st.p, -nn, st.wy, hw)
		st.rr = _shore(st.p, nn, st.wy, hw)
		_st[i] = st

	# Second pass on the surface height. `water_y_at` is a nearest-seed field, so it is
	# not constant across a wide section: over the plunge basin it varies 0.8 m between
	# the centreline and the rim, and a cross-section held flat at the CENTRELINE value
	# ends up standing above the line the terrain was carved to at the edges. Water finds
	# its lowest level, so each station takes the minimum over its own width - which keeps
	# the section flat (as a water surface must be) while guaranteeing it never sits above
	# the map's own water line anywhere along it.
	for i in range(_st.size()):
		var st: Dictionary = _st[i]
		var nn: Vector2 = st.n
		var lo: float = st.wy
		for k in range(-3, 4):
			var f: float = float(k) / 3.0
			var off: float = (float(st.rl) * -f) if f < 0.0 else (float(st.rr) * f)
			var q: Vector2 = st.p + nn * off
			if map.in_bounds(q.x, q.y):
				lo = minf(lo, map.water_y_at(q.x, q.y))
		# Bounded: through the falls the field is genuinely steep and a large correction
		# there would tip the sheet, not level it.
		var was: float = st.wy
		st.wy = maxf(lo, was - 1.0)
		# Re-march only where the level actually moved. Most stations are in reaches where
		# the field is flat across the channel and the shoreline cannot have changed.
		if absf(float(st.wy) - was) > 0.02:
			st.rl = _shore(st.p, -nn, st.wy, float(st.hw))
			st.rr = _shore(st.p, nn, st.wy, float(st.hw))
		_st[i] = st


static func _in_box(p: Vector2) -> bool:
	return absf(p.x) <= EDGE and absf(p.y) <= EDGE


## Where the segment from `inside` to `outside` crosses the world boundary. Bisection
## rather than an analytic clip because the box test is the one that has to agree.
static func _clip_to_box(inside: Vector2, outside: Vector2) -> Vector2:
	var lo := 0.0
	var hi := 1.0
	for _i in range(28):
		var m: float = (lo + hi) * 0.5
		if _in_box(inside.lerp(outside, m)):
			lo = m
		else:
			hi = m
	return inside.lerp(outside, lo)


func _push_station(sp: Array[Vector2], swy: PackedFloat32Array, grad: PackedFloat32Array, i: int, d3: float) -> void:
	(
		_st
		. append(
			{
				"p": sp[i],
				"wy": swy[i],
				"g": grad[i],
				"d3": d3,
				"n": Vector2.RIGHT,
				"hw": 6.0,
				"rl": 6.0,
				"rr": 6.0,
				"flow": 0.4,
				"churn": 0.0,
			}
		)
	)


## Direction of travel at a station, in 3-D, from its neighbours.
func _dir_along(i: int) -> Vector3:
	var a: int = maxi(i - 1, 0)
	var b: int = mini(i + 1, _st.size() - 1)
	var pa: Dictionary = _st[a]
	var pb: Dictionary = _st[b]
	var v := Vector3(pb.p.x - pa.p.x, pb.wy - pa.wy, pb.p.y - pa.p.y)
	if v.length_squared() < 1e-8:
		return Vector3(0, 0, 1)
	return v.normalized()


## Distance from `p` along `dir` to the first place the ground rises to the water
## surface, plus a tuck-under margin.
func _shore(p: Vector2, dir: Vector2, wy: float, hw: float) -> float:
	# The budget has to cover the widest submerged section, not the nominal channel. At
	# +9 m the march ran out in the south-west estuary, where the ground stays 4 m under
	# the water line for ~25 m: the ribbon stopped short and its rim hung over 4.2 m of
	# open channel. Measured with tests/water_ground_test.gd, which counts exactly that.
	# In a gorge the march still stops at the first rise, so the extra budget is only
	# spent where it is needed.
	var limit: float = hw + 26.0
	# Coarse sweep, then bisect the crossing. The exhaustive SHORE_STEP walk out to the
	# limit was 78 height_at queries per side per station and ran twice; that was 135 k
	# queries and about 120 ms of setup(). This is the same answer to within 6 cm - finer
	# than SHORE_STEP - for a third of the work. The coarse step stays BELOW the narrowest
	# feature that must stop the march (a 1.5 m sand bar), because stepping over one would
	# put water on top of it.
	var coarse := 1.4
	var under := 0.0  # last radius known to be under water
	var over := -1.0  # first radius known to be dry, or off the heightfield
	var r: float = coarse
	while r <= limit:
		if _dry(p + dir * r, wy):
			over = r
			break
		under = r
		r += coarse
	if over < 0.0:
		return clampf(limit, 1.0, limit)
	for _i in range(5):
		var mid: float = (under + over) * 0.5
		if _dry(p + dir * mid, wy):
			over = mid
		else:
			under = mid
	return clampf(under + WIDEN, 1.0, limit)


## True where the ground has risen through the water surface, or where the heightfield
## has run out. The heightfield runs to +/-HALF; `in_bounds` stops 2 m short of that, and
## using it here cut the ribbon at x = -382 in the south-west estuary while the channel
## ran on to the world edge, leaving the rim hanging over 4.2 m of open water.
func _dry(q: Vector2, wy: float) -> bool:
	if absf(q.x) >= WorldMap.HALF - 0.25 or absf(q.y) >= WorldMap.HALF - 0.25:
		return true
	return map.height_at(q.x, q.y) >= wy - 0.02


# --- the falls -------------------------------------------------------------
## The falls are wherever the surface actually tips over, not a hard-coded z range: the
## gorge is between z -206 and -182 and the water drops ~21 m through it.
func _find_falls() -> void:
	var a := -1
	var b := -1
	for i in range(_st.size()):
		var st: Dictionary = _st[i]
		if st.p.y < -215.0 or st.p.y > -172.0:
			continue
		if st.g > 0.25:
			if a < 0:
				a = i
			b = i
	if a < 0 or b <= a:
		push_warning("[water] no steep section found; the falls will not be built")
		return
	_fall_a = maxi(a - 2, 0)
	_fall_b = mini(b + 2, _st.size() - 1)
	var sa: Dictionary = _st[_fall_a]
	var sb: Dictionary = _st[_fall_b]
	print(
		(
			"[water] falls z %.1f -> %.1f, drop %.1f m over %d stations"
			% [sa.p.y, sb.p.y, sa.wy - sb.wy, _fall_b - _fall_a]
		)
	)


## Flow speed and froth per station. Speed comes from the gradient of the water surface
## and from how tight the channel is; froth from the gradient, from the plunge basin
## ring, and from the tail of white water below the fall.
func _score_flow() -> void:
	var base_d3: float = 0.0
	if _fall_b >= 0:
		var sb: Dictionary = _st[_fall_b]
		base_d3 = sb.d3
	for i in range(_st.size()):
		var st: Dictionary = _st[i]
		var narrow: float = clampf(inverse_lerp(13.0, 4.5, st.hw), 0.0, 1.0)
		st.flow = clampf(0.22 + st.g * 1.7 + narrow * 0.30, 0.0, 1.0)
		var churn: float = clampf(st.g * 2.4, 0.0, 1.0)
		# A ring of froth thrown out around where the fall lands.
		var d: float = st.p.distance_to(PLUNGE)
		churn = maxf(churn, (1.0 - smoothstep(0.0, 14.0, absf(d - 7.5))) * 0.80)
		# ... and white water carried on downstream from it.
		if _fall_b >= 0 and st.d3 > base_d3:
			churn = maxf(churn, clampf(1.0 - (st.d3 - base_d3) / 60.0, 0.0, 1.0) * 0.50)
		st.churn = clampf(churn, 0.0, 1.0)
		_st[i] = st


# --- meshing ---------------------------------------------------------------
## The whole river is ONE MeshInstance3D, and it has to be.
##
## It was six chunks of 96 stations. That put a hard, dead-straight seam across every
## low-angle view of the river, and the seam was not geometry: `hint_screen_texture` is
## copied per transparent draw, so the nearer chunk refracted a frame that already had
## the farther chunk's water composited into it while the farther chunk refracted one
## that did not. Two different images, meeting along a chunk boundary. Proved by
## tests/probe_water_seam.gd - with `use_refraction` off the seam disappears and the
## surface is continuous; with only one chunk drawn, the seam IS that chunk's own edge.
##
## Merging costs nothing here: 5.6 k triangles and 3.3 k vertices for 700 m of river, and
## the shader is fragment-bound, so the off-screen half of the ribbon is free anyway.
func _build_river_meshes() -> void:
	var runs: Array = []
	if _fall_a > 0:
		runs.append([0, _fall_a])
	else:
		runs.append([0, _st.size() - 1])
	if _fall_b > 0 and _fall_b < _st.size() - 1:
		runs.append([_fall_b, _st.size() - 1])
	# Both runs go into one SURFACE, not one mesh with two surfaces - two surfaces are
	# two draws and would seam against each other exactly as the chunks did.
	var b := _RibbonArrays.new()
	for r in runs:
		_ribbon_into(b, int(r[0]), int(r[1]), false)
	var mi := _finish_ribbon(b, _river_mat, "River")
	add_child(mi)


func _build_falls_mesh() -> void:
	if _fall_a < 0:
		return
	var b := _RibbonArrays.new()
	_ribbon_into(b, _fall_a, _fall_b, true)
	add_child(_finish_ribbon(b, _falls_mat, "Waterfall"))


## Growable vertex arrays, so several station runs can be appended into one surface.
class _RibbonArrays:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var tans := PackedFloat32Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()


## Append the ribbon over stations [i0, i1] inclusive to `b`.
##
## Winding: Godot's front faces are CLOCKWISE. With rows running downstream and columns
## running along `n` = (tangent.z, -tangent.x), the pair below faces UP, exactly as the
## terrain mesher's does; reversing it renders the whole river invisible from above.
func _ribbon_into(b: _RibbonArrays, i0: int, i1: int, falls: bool) -> void:
	var nst: int = i1 - i0 + 1
	if nst < 2:
		return
	# The ribbon's two OPEN ends - the source at the north edge of the heightfield and the
	# exit at the south-west corner - are square cuts across a channel that is still metres
	# deep. Seen from anywhere near them the cut shows as a wall of water standing in the
	# air (water_exit_sw.png). Fading the authored alpha out over the last few metres is
	# what makes the sheet end instead of being severed. The falls junctions are NOT open:
	# the falling sheet covers them.
	var fade_head: bool = not falls and i0 == 0
	var fade_tail: bool = not falls and i1 == _st.size() - 1
	var st_head: Dictionary = _st[i0]
	var st_tail: Dictionary = _st[i1]
	var d3_head: float = st_head.d3
	var d3_tail: float = st_tail.d3
	var base: int = b.verts.size()
	var count: int = nst * COLS
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var tans := PackedFloat32Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	verts.resize(count)
	norms.resize(count)
	cols.resize(count)
	uvs.resize(count)
	tans.resize(count * 4)

	var wy_a: float = 0.0
	var wy_b: float = 1.0
	if falls:
		var sa: Dictionary = _st[i0]
		var sb: Dictionary = _st[i1]
		wy_a = sa.wy
		wy_b = sb.wy

	for si in range(nst):
		var st: Dictionary = _st[i0 + si]
		var p: Vector2 = st.p
		var nn: Vector2 = st.n
		var t3 := _dir_along(i0 + si)
		var c3 := Vector3(nn.x, 0.0, nn.y)
		var nrm: Vector3 = t3.cross(c3).normalized()
		if nrm.y < 0.0:
			nrm = -nrm
		var prog: float = 0.0
		if falls:
			prog = clampf((wy_a - st.wy) / maxf(wy_a - wy_b, 0.001), 0.0, 1.0)
		var bulge: float = sin(prog * PI) * FALL_BULGE if falls else 0.0
		for cj in range(COLS):
			var u: float = float(cj) / float(COLS - 1)
			var off: float = lerpf(-float(st.rl), float(st.rr), u)
			var mid: float = 1.0 - absf(u * 2.0 - 1.0)
			var dip: float = (1.0 - smoothstep(0.0, 0.34, mid)) * EDGE_DIP
			var pos := Vector3(p.x + nn.x * off, float(st.wy) - dip, p.y + nn.y * off)
			pos += nrm * bulge
			var vi: int = si * COLS + cj
			verts[vi] = pos
			norms[vi] = nrm
			# UV.x across in metres, UV.y downstream in metres. Metres (not 0..1) so the
			# ripple texture keeps its scale where the channel widens.
			uvs[vi] = Vector2(off, float(st.d3))
			# Tangent follows +U, i.e. straight across the flow. w = -1 puts the binormal
			# on +V (downstream), which is the direction the normal map is scrolled in.
			tans[vi * 4] = c3.x
			tans[vi * 4 + 1] = c3.y
			tans[vi * 4 + 2] = c3.z
			tans[vi * 4 + 3] = -1.0
			var g: float = prog if falls else float(st.churn)
			var a: float = 1.0
			if fade_head:
				a = minf(a, smoothstep(0.0, END_FADE, float(st.d3) - d3_head))
			if fade_tail:
				a = minf(a, smoothstep(0.0, END_FADE, d3_tail - float(st.d3)))
			cols[vi] = Color(float(st.flow), g, mid, a)

	for si in range(nst - 1):
		for cj in range(COLS - 1):
			var a: int = base + si * COLS + cj
			var q: int = a + 1
			var c: int = a + COLS
			var d: int = c + 1
			b.idx.append(a)
			b.idx.append(q)
			b.idx.append(c)
			b.idx.append(q)
			b.idx.append(d)
			b.idx.append(c)
	b.verts.append_array(verts)
	b.norms.append_array(norms)
	b.tans.append_array(tans)
	b.cols.append_array(cols)
	b.uvs.append_array(uvs)


func _finish_ribbon(b: _RibbonArrays, mat: Material, nm: String) -> MeshInstance3D:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = b.verts
	arr[Mesh.ARRAY_NORMAL] = b.norms
	arr[Mesh.ARRAY_TANGENT] = b.tans
	arr[Mesh.ARRAY_COLOR] = b.cols
	arr[Mesh.ARRAY_TEX_UV] = b.uvs
	arr[Mesh.ARRAY_INDEX] = b.idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_tris += b.idx.size() / 3

	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# --- plunge-pool mist ------------------------------------------------------
func _build_mist() -> void:
	if _fall_b < 0:
		return
	var sb: Dictionary = _st[_fall_b]
	var origin := Vector3(sb.p.x, float(sb.wy) + 2.0, sb.p.y + 4.0)

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(15.0, 5.0, 9.0)
	pm.direction = Vector3(-0.25, 0.5, 0.82)
	pm.spread = 46.0
	pm.initial_velocity_min = 0.3
	pm.initial_velocity_max = 1.7
	pm.gravity = Vector3(0.0, 0.24, 0.0)
	pm.damping_min = 0.2
	pm.damping_max = 0.7
	pm.scale_min = 4.5
	pm.scale_max = 12.0
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -6.0
	pm.angular_velocity_max = 6.0
	# Fade in, hang, fade out - a hard-edged particle pop is what makes mist read as
	# sprites rather than as spray.
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.22, 0.65, 1.0])
	grad.colors = PackedColorArray(
		[Color(1, 1, 1, 0.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.75), Color(1, 1, 1, 0.0)]
	)
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	gt.width = 64
	pm.color_ramp = gt

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = _mist_material()

	var gp := GPUParticles3D.new()
	gp.name = "PlungeMist"
	gp.amount = 150
	gp.lifetime = 9.0
	gp.randomness = 1.0
	# Deterministic: the same drift every run, like every other scatter in this world.
	if "use_fixed_seed" in gp:
		gp.use_fixed_seed = true
		gp.seed = 0x5241_4D41
	gp.preprocess = 8.0
	gp.fixed_fps = 24
	gp.interpolate = true
	gp.process_material = pm
	gp.draw_pass_1 = quad
	gp.position = origin
	gp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Wide and slow: without an explicit AABB the drifting sprites pop out of existence
	# as soon as the emitter box leaves the frustum.
	gp.visibility_aabb = AABB(Vector3(-34.0, -14.0, -26.0), Vector3(68.0, 44.0, 62.0))
	gp.visibility_range_end = 420.0
	gp.visibility_range_end_margin = 70.0
	add_child(gp)


func _mist_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	# Without this Godot rebuilds the billboard basis from the camera alone and THROWS
	# THE PARTICLE'S SCALE AWAY: 15 m mist puffs rendered as 1.5 m confetti.
	m.billboard_keep_scale = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = _mist_sprite()
	m.albedo_color = Color(0.88, 0.92, 0.96, 0.105)
	m.disable_receive_shadows = true
	# Soft-particle fade so the sprites do not slice against the gorge wall.
	m.proximity_fade_enabled = true
	m.proximity_fade_distance = 3.0
	return m


## A soft, slightly lumpy blob. Generated rather than loaded so the mist owns no asset.
func _mist_sprite() -> ImageTexture:
	var s := 64
	var img := Image.create(s, s, true, Image.FORMAT_RGBA8)
	var half := float(s) * 0.5
	for y in range(s):
		for x in range(s):
			var dx: float = (float(x) + 0.5 - half) / half
			var dy: float = (float(y) + 0.5 - half) / half
			var r: float = sqrt(dx * dx + dy * dy)
			# A long, low falloff: a tight core makes each sprite readable as a card.
			var a: float = pow(smoothstep(1.0, 0.0, r), 1.5)
			# Deterministic lumpiness, no RNG: the same sprite every run.
			var lump: float = 0.72 + 0.28 * (0.5 + 0.5 * sin(dx * 7.3 + 1.7) * sin(dy * 6.1 - 0.9))
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(a * lump, 0.0, 1.0)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# --- standing water --------------------------------------------------------
func _build_pools() -> void:
	# The grove is a wide, almost flat shelf, so the pond is a broad shallow lens that
	# follows the terrain's own contour rather than a disc cut into it.
	_add_pool("GrovePond", GROVE_POND, 20.0, 0.30, 11.0)
	# The village terrace is flat to within 10 cm - there is no hollow to fill - so the
	# well's washing pool gets a low stone kerb of its own and stands inside it.
	_add_well_pool()


## A contour-following sheet of still water. `rise` is how far above the lowest ground
## in the search area the surface sits; each ray stops at the first ground above it, so
## the water can never spill out over a lip.
func _add_pool(nm: String, around: Vector2, search: float, rise: float, max_r: float) -> Node3D:
	var centre := around
	var low := map.height_at(around.x, around.y)
	var steps := int(search / 2.0)
	for gz in range(-steps, steps + 1):
		for gx in range(-steps, steps + 1):
			var q := around + Vector2(float(gx) * 2.0, float(gz) * 2.0)
			if q.distance_to(around) > search or not map.in_bounds(q.x, q.y):
				continue
			var h := map.height_at(q.x, q.y)
			if h < low:
				low = h
				centre = q
	var level: float = low + rise
	var radii := _contour(centre, level, max_r)
	return _pool_mesh(nm, centre, level, radii, 1.0)


## Where the village well actually is. Asked of whichever sibling system publishes points
## of interest, by POI NAME rather than by class, so this does not compile-depend on
## Settlement. Note the ordering: Game builds the water BEFORE the settlement, so in the
## real game this finds nothing and the constant is what is used - the lookup earns its
## keep only if that order ever changes. The constant is therefore the thing that has to
## be right, and it is checked by tests/water_ground_test.gd against the built well.
func _find_well() -> Vector2:
	var parent := get_parent()
	if parent == null:
		return WELL_POOL
	for sib in parent.get_children():
		if sib == self or not sib.has_method("points_of_interest"):
			continue
		for poi in sib.points_of_interest():
			if String(poi.get("name", "")).to_lower().contains("well"):
				var p: Vector3 = poi["position"]
				return Vector2(p.x, p.z)
	return WELL_POOL


func _add_well_pool() -> void:
	# Beside the well head, not on top of it: this is the washing tank the water is drawn
	# into, and the well itself is Settlement's object.
	var c := _find_well() + Vector2(2.9, 1.6)
	var ground := map.height_at(c.x, c.y)
	var hi := ground
	for a in range(16):
		var th := TAU * float(a) / 16.0
		var q := c + Vector2(cos(th), sin(th)) * 2.6
		hi = maxf(hi, map.height_at(q.x, q.y))
	var top: float = hi + 0.22
	# The skirt goes well below the terrace: a kerb whose foot only just reaches the
	# ground reads as a tub set down on the grass.
	_kerb("WellKerb", c, 2.10, 2.55, ground - 1.4, top)
	var radii := PackedFloat32Array()
	radii.resize(32)
	radii.fill(2.18)
	_pool_mesh("WellPool", c, top - 0.10, radii, 1.0)


## Shore radius per ray: march out until the ground rises through `level`.
func _contour(c: Vector2, level: float, max_r: float) -> PackedFloat32Array:
	var rays := 32
	var out := PackedFloat32Array()
	out.resize(rays)
	for a in range(rays):
		var th: float = TAU * float(a) / float(rays)
		var dir := Vector2(cos(th), -sin(th))
		var r: float = 0.5
		var ok: float = 0.9
		while r <= max_r:
			var q: Vector2 = c + dir * r
			if not map.in_bounds(q.x, q.y) or map.height_at(q.x, q.y) >= level:
				break
			ok = r
			r += 0.5
		out[a] = clampf(ok + 0.4, 1.0, max_r)
	# Smooth the outline: raw contours of a noisy heightfield come out as a starfish.
	for _pass in range(3):
		var cp := out.duplicate()
		for a in range(rays):
			out[a] = (cp[(a - 1 + rays) % rays] + cp[a] * 2.0 + cp[(a + 1) % rays]) * 0.25
	return out


## Rings of still water. Column order runs clockwise in XZ ((cos, -sin)) so the same
## index pattern as the ribbon leaves the surface facing UP.
func _pool_mesh(nm: String, c: Vector2, level: float, radii: PackedFloat32Array, flow: float) -> MeshInstance3D:
	var rays := radii.size()
	var rings := [0.0, 0.42, 0.76, 1.0]
	var count := rings.size() * rays
	var verts := PackedVector3Array()
	verts.resize(count)
	var norms := PackedVector3Array()
	norms.resize(count)
	var cols := PackedColorArray()
	cols.resize(count)
	var uvs := PackedVector2Array()
	uvs.resize(count)
	var tans := PackedFloat32Array()
	tans.resize(count * 4)
	for ri in range(rings.size()):
		var f: float = rings[ri]
		for a in range(rays):
			var th: float = TAU * float(a) / float(rays)
			var dir := Vector2(cos(th), -sin(th))
			var r: float = radii[a] * f
			var vi: int = ri * rays + a
			var dip: float = 0.06 if ri == rings.size() - 1 else 0.0
			verts[vi] = Vector3(c.x + dir.x * r, level - dip, c.y + dir.y * r)
			norms[vi] = Vector3.UP
			uvs[vi] = Vector2(dir.x * r, dir.y * r)
			tans[vi * 4] = 1.0
			tans[vi * 4 + 1] = 0.0
			tans[vi * 4 + 2] = 0.0
			tans[vi * 4 + 3] = -1.0
			var mid: float = 1.0 - f
			var mask: float = 1.0 if ri < rings.size() - 1 else 0.0
			cols[vi] = Color(flow * 0.06, 0.0, mid, mask)
	var idx := PackedInt32Array()
	for ri in range(rings.size() - 1):
		for a in range(rays):
			var a0: int = ri * rays + a
			var b0: int = ri * rays + (a + 1) % rays
			var a1: int = a0 + rays
			var b1: int = b0 + rays
			idx.append(a0)
			idx.append(b0)
			idx.append(a1)
			idx.append(b0)
			idx.append(b1)
			idx.append(a1)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TANGENT] = tans
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_tris += idx.size() / 3

	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.material_override = _river_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = 320.0
	mi.visibility_range_end_margin = 40.0
	add_child(mi)

	var rmax := 0.0
	for r in radii:
		rmax = maxf(rmax, r)
	_pools.append({"c": c, "level": level, "r": rmax})
	return mi


## A low stone rim, so that standing water on flat ground reads as a built tank rather
## than as a puddle floating on the terrace. Normals are authored (not derived from the
## winding) and the material is double sided, so the kerb cannot come out black.
func _kerb(nm: String, c: Vector2, ri: float, ro: float, y0: float, y1: float) -> void:
	var segs := 20
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	var add_ring := func(radius: float, y: float, nrm: Vector3, uv_v: float) -> int:
		var base := verts.size()
		for a in range(segs + 1):
			var th: float = TAU * float(a) / float(segs)
			var d := Vector2(cos(th), -sin(th))
			verts.append(Vector3(c.x + d.x * radius, y, c.y + d.y * radius))
			var n: Vector3 = nrm if nrm != Vector3.ZERO else Vector3(d.x, 0.0, d.y)
			norms.append(n)
			uvs.append(Vector2(th * radius * 0.25, uv_v))
		return base

	var strip := func(a: int, b: int) -> void:
		for k in range(segs):
			idx.append(a + k)
			idx.append(a + k + 1)
			idx.append(b + k)
			idx.append(a + k + 1)
			idx.append(b + k + 1)
			idx.append(b + k)

	# outer wall (rows top -> bottom), top annulus (inner -> outer), inner wall (bottom -> top)
	var o_top: int = add_ring.call(ro, y1, Vector3.ZERO, 0.0)
	var o_bot: int = add_ring.call(ro, y0, Vector3.ZERO, 1.0)
	strip.call(o_top, o_bot)
	var t_in: int = add_ring.call(ri, y1, Vector3.UP, 0.0)
	var t_out: int = add_ring.call(ro, y1, Vector3.UP, 0.4)
	strip.call(t_in, t_out)
	var i_bot: int = add_ring.call(ri, y0, Vector3.ZERO, 1.0)
	var i_top: int = add_ring.call(ri, y1, Vector3.ZERO, 0.0)
	for k in range(i_bot, i_bot + segs + 1):
		norms[k] = -norms[k]
	for k in range(i_top, i_top + segs + 1):
		norms[k] = -norms[k]
	strip.call(i_bot, i_top)

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_tris += idx.size() / 3

	var mat := StandardMaterial3D.new()
	var alb := _tex("temple_stone_albedo")
	if alb:
		mat.albedo_texture = alb
	var nrm := _tex("temple_stone_normal")
	if nrm:
		mat.normal_enabled = true
		mat.normal_texture = nrm
	var rgh := _tex("temple_stone_rough")
	if rgh:
		mat.roughness_texture = rgh
	mat.roughness = 1.0
	mat.uv1_scale = Vector3(1.7, 1.7, 1.7)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.material_override = mat
	mi.visibility_range_end = 320.0
	mi.visibility_range_end_margin = 40.0
	add_child(mi)


# --- queries ---------------------------------------------------------------
## Height of the water surface over (x, z), or `NO_WATER` on dry land. Local to the
## body of water that covers the point: the river's surface is 44 m higher at the
## source than at the exit, so a single number for "the water level" is meaningless.
func water_height_at(x: float, z: float) -> float:
	var p := Vector2(x, z)
	for pool in _pools:
		var pc: Vector2 = pool.c
		var lvl: float = pool.level
		if p.distance_to(pc) <= float(pool.r) and map.height_at(x, z) < lvl:
			return lvl
	if map.river_dist(p) <= half_width(p) + 1.0:
		var wy := map.water_y_at(x, z)
		if map.height_at(x, z) < wy:
			return wy
	return NO_WATER


## True when `pos` is at or below the local water surface - the wade / swim test.
func is_in_water(pos: Vector3) -> bool:
	return pos.y <= water_height_at(pos.x, pos.z)


## Metres of water above the ground at (x, z); 0 on dry land.
func water_depth_at(x: float, z: float) -> float:
	var wy := water_height_at(x, z)
	if wy <= NO_WATER * 0.5:
		return 0.0
	return maxf(wy - map.height_at(x, z), 0.0)


## Centre, surface height and radius of each body of standing water, resolved from the
## terrain at build time (the grove pond hunts for the low point, so it is not exactly
## at GROVE_POND).
func pools() -> Array:
	return _pools.duplicate()


## Debug hook: 0 off, 1 reconstructed depth, 2 vertex colour, 3 perturbed normal.
func set_debug(mode: int) -> void:
	if _river_mat:
		_river_mat.set_shader_parameter("debug_mode", mode)
