class_name Wildlife
extends Node3D
## Ambient, non-hostile life: chital herds, bird flocks, monkeys, butterflies, bats
## and fish. None of it fights, none of it talks; it exists so the valley is not empty
## between the set pieces.
##
## Cost discipline, in order of how much it saves:
##   * Anything that appears more than ~30 times is ONE MultiMeshInstance3D with a
##     vertex-shader wing flap, so a flock of birds is one draw call, not twelve.
##   * Animals past `VISIBLE_DIST` are hidden and skipped entirely.
##   * Animals past `NEAR_ANIM` still think, but only on the 2.5 Hz slow tick, and
##     their limbs do not move.
##   * Measured 2026-08-28 by `tests/vfx_wildlife_headless.gd`: 156 animals,
##     10,336 triangles, 153 draw calls with EVERY group awake at once. In play only
##     a herd or two and a flock or two are inside VISIBLE_DIST, so the real figure is
##     a third of that. `stats()` re-measures it; do not trust this line, re-run it.
##
## Everything walks on `map.height_at` every single step, so nothing ever floats or
## sinks - that is the one rule of this world and it applies to animals too.

# --- tuning ------------------------------------------------------------------
const NEAR_ANIM := 90.0  # limbs only move inside this radius
const VISIBLE_DIST := 170.0  # beyond this, hidden and not simulated
const SLOW_PERIOD := 0.4

const DEER_WALK := 1.35
const DEER_RUN := 6.4
const DEER_FLEE_DIST := 21.0
# WorldMap.slope_at is 1 - normal.y, so 0.55 is acos(0.45) = 63 degrees - a cliff. The
# first pass let deer walk onto that, and a chital standing on a 63-degree riverbank has
# its downhill legs hanging in mid-air no matter how the body is aligned. 0.22 is
# acos(0.78) = 39 degrees, which is about what a deer will actually cross.
const DEER_MAX_SLOPE := 0.22
# Ground this steep is never chosen as a destination or a spawn point at all.
const STAND_MAX_SLOPE := 0.30

# Leg sockets, front pair first. Kept as constants so the walk cycle and the rig
# can never drift apart.
const LEG_X := [-0.115, 0.115, -0.115, 0.115]
const LEG_Y := [0.62, 0.62, 0.60, 0.60]
const LEG_Z := [-0.34, -0.34, 0.33, 0.33]
const HEAD_PIVOT := Vector3(0.0, 0.80, -0.42)
const MONKEY_FLEE_DIST := 9.0

enum { GRAZE, ALERT, WALK, FLEE }
enum { CIRCLE, DESCEND, PERCH, TAKEOFF }
enum { K_BIRD, K_BUTTERFLY, K_BAT }

var map: WorldMap
var sky: SkySystem

var _rng := RandomNumberGenerator.new()
var _focus := Vector3(-120.0, 0.0, 44.0)
var _t := 0.0
var _slow := 0.0

var _herds: Array = []
var _monkeys: Array = []
var _flocks: Array = []
var _fish: FishShoal

var _m_body: ArrayMesh
var _m_head: ArrayMesh
var _m_head_antler: ArrayMesh
var _m_leg: ArrayMesh
var _m_monkey: ArrayMesh
var _m_monkey_head: ArrayMesh


# =============================================================================
#  Mesh helpers.  Godot's front faces are CLOCKWISE - every quad here is listed
#  counter-clockwise as seen from OUTSIDE and emitted reversed. Get this backwards
#  and the animal renders as a hole in the world.
# =============================================================================
static func _quad_cw(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(a)
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(c)
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(b)
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(a)
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(d)
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(c)


## v[0..3] = the -Z face, v[4..7] = the +Z face, each as (-x,-y) (+x,-y) (+x,+y) (-x,+y).
static func _box8(st: SurfaceTool, v: Array) -> void:
	_quad_cw(st, v[4], v[5], v[6], v[7])  # +Z
	_quad_cw(st, v[0], v[3], v[2], v[1])  # -Z
	_quad_cw(st, v[1], v[2], v[6], v[5])  # +X
	_quad_cw(st, v[0], v[4], v[7], v[3])  # -X
	_quad_cw(st, v[3], v[7], v[6], v[2])  # +Y
	_quad_cw(st, v[0], v[1], v[5], v[4])  # -Y


## A tapered box running from `a` to `b`. Every limb, neck, torso and antler tine in
## this file is one of these.
static func _limb(st: SurfaceTool, a: Vector3, b: Vector3, ra: Vector2, rb: Vector2) -> void:
	var f := b - a
	var l := f.length()
	if l < 1e-5:
		return
	f /= l
	var up := Vector3.UP
	if absf(f.dot(up)) > 0.985:
		up = Vector3.FORWARD
	# Right-handed frame (r, u, f): r = up x f, u = f x r.
	var r := up.cross(f).normalized()
	var u := f.cross(r).normalized()
	_box8(
		st,
		[
			a - r * ra.x - u * ra.y,
			a + r * ra.x - u * ra.y,
			a + r * ra.x + u * ra.y,
			a - r * ra.x + u * ra.y,
			b - r * rb.x - u * rb.y,
			b + r * rb.x - u * rb.y,
			b + r * rb.x + u * rb.y,
			b - r * rb.x + u * rb.y,
		]
	)


## Flat double-sided card in the XZ plane, outward normal +Y. Wings are these.
static func _card(st: SurfaceTool, x0: float, x1: float, z0: float, z1: float, y: float) -> void:
	_quad_cw(st, Vector3(x0, y, z1), Vector3(x1, y, z1), Vector3(x1, y, z0), Vector3(x0, y, z0))


## A card whose chord narrows and slides from root to tip: a wing outline rather than
## a rectangle. `c` is the chord centre and `r` the chord half-width at each end.
## Rendered at 15 cm a rectangular wing card reads as a slab of orange cardboard, which
## is exactly what the butterflies looked like before this existed.
static func _taper_card(
	st: SurfaceTool, x0: float, x1: float, c0: float, r0: float, c1: float, r1: float, y: float
) -> void:
	_quad_cw(st, Vector3(x0, y, c0 + r0), Vector3(x1, y, c1 + r1), Vector3(x1, y, c1 - r1), Vector3(x0, y, c0 - r0))


static func _finish(st: SurfaceTool, mat: Material) -> ArrayMesh:
	st.generate_normals()
	st.generate_tangents()
	var m := st.commit()
	m.surface_set_material(0, mat)
	return m


## Engine-side LOD cut. Small parts drop out well before the silhouette does, which
## is free and invisible: nobody resolves a chital's shin at 120 metres.
static func _ranged(mi: GeometryInstance3D, end_m: float) -> void:
	mi.visibility_range_end = end_m
	mi.visibility_range_end_margin = end_m * 0.12
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED


func _new_st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


# =============================================================================
#  Setup
# =============================================================================
func setup(world_map: WorldMap, sky_system: SkySystem = null) -> void:
	map = world_map
	sky = sky_system
	_rng.seed = 0x574C_4946  # "WLIF" - deterministic scatter, identical every run

	_build_deer_meshes()
	_build_monkey_meshes()

	_spawn_deer()
	_spawn_monkeys()
	_spawn_flocks()
	_spawn_fish()

	_focus = map.ground(WorldMap.P_VILLAGE.x, WorldMap.P_VILLAGE.y)


func update_focus(pos: Vector3) -> void:
	_focus = pos


func _process(delta: float) -> void:
	if map == null:
		return
	var dt: float = minf(delta, 0.1)
	_t += dt
	_slow -= dt
	var slow := _slow <= 0.0
	var sdt := SLOW_PERIOD
	if slow:
		_slow = SLOW_PERIOD

	var night: bool = sky.is_night() if sky else false
	var lit: float = sky.light_level() if sky else 1.0

	for h in _herds:
		_update_herd(h, dt, sdt, slow)
	for m in _monkeys:
		_update_monkey(m, dt, sdt, slow, lit)
	for f in _flocks:
		_update_flock(f, dt, slow, night, lit)
	if _fish:
		_update_fish(dt, slow)


# =============================================================================
#  CHITAL - low-poly spotted deer, six nodes each: body, head, four legs.
# =============================================================================
func _hide_texture() -> ImageTexture:
	var w := 96
	var img := Image.create(w, w, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x43_4849  # deterministic coat
	var base := Color(0.545, 0.315, 0.165)
	for y in range(w):
		for x in range(w):
			var n: float = sin(float(x) * 0.63) * 0.035 + cos(float(y) * 0.81) * 0.035
			n += sin(float(x + y) * 0.21) * 0.03
			img.set_pixel(
				x,
				y,
				Color(
					clampf(base.r * (1.0 + n), 0.0, 1.0),
					clampf(base.g * (1.0 + n), 0.0, 1.0),
					clampf(base.b * (1.0 + n), 0.0, 1.0)
				)
			)
	# Chital spots: rows of pale flecks, jittered so they do not read as a grid.
	var spot := Color(0.93, 0.89, 0.79)
	for row in range(9):
		for col in range(9):
			var cx: float = (float(col) + 0.5) * (float(w) / 7.0) + rng.randf_range(-3.5, 3.5)
			var cy: float = (float(row) + 0.5) * (float(w) / 7.0) + rng.randf_range(-3.5, 3.5)
			var rad: float = rng.randf_range(2.4, 3.8)
			for dy in range(-4, 5):
				for dx in range(-4, 5):
					var px := int(fposmod(cx + float(dx), float(w)))
					var py := int(fposmod(cy + float(dy), float(w)))
					var d := Vector2(float(dx), float(dy)).length()
					var k: float = clampf(1.0 - d / rad, 0.0, 1.0)
					if k <= 0.0:
						continue
					img.set_pixel(px, py, img.get_pixel(px, py).lerp(spot, k * 0.85))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _build_deer_meshes() -> void:
	var hide := StandardMaterial3D.new()
	hide.albedo_texture = _hide_texture()
	hide.roughness = 0.92
	hide.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	var plain := StandardMaterial3D.new()
	plain.albedo_color = Color(0.46, 0.27, 0.145)
	plain.roughness = 0.94

	# --- torso (faces -Z, Godot forward) ------------------------------------
	var st := _new_st()
	_limb(st, Vector3(0.0, 0.74, -0.46), Vector3(0.0, 0.70, 0.44), Vector2(0.155, 0.185), Vector2(0.145, 0.170))
	# shoulder / withers hump
	_limb(st, Vector3(0.0, 0.86, -0.34), Vector3(0.0, 0.83, -0.02), Vector2(0.105, 0.055), Vector2(0.085, 0.040))
	# tail
	_limb(st, Vector3(0.0, 0.80, 0.44), Vector3(0.0, 0.62, 0.56), Vector2(0.035, 0.045), Vector2(0.018, 0.022))
	_m_body = _finish(st, hide)

	# --- neck + head, pivoting at the base of the neck ----------------------
	# Authored around the base of the neck; the node carrying it sits at HEAD_PIVOT.
	_m_head = _deer_head(false, plain)
	_m_head_antler = _deer_head(true, plain)

	# --- one leg, hip at the origin, hoof at -Y ------------------------------
	var lst := _new_st()
	_limb(lst, Vector3.ZERO, Vector3(0.0, -0.30, 0.015), Vector2(0.048, 0.052), Vector2(0.032, 0.036))
	_limb(lst, Vector3(0.0, -0.30, 0.015), Vector3(0.0, -0.545, 0.0), Vector2(0.030, 0.034), Vector2(0.020, 0.024))
	_limb(lst, Vector3(0.0, -0.545, 0.0), Vector3(0.0, -0.585, -0.012), Vector2(0.026, 0.030), Vector2(0.024, 0.028))
	_m_leg = _finish(lst, plain)


func _deer_head(antlers: bool, mat: Material) -> ArrayMesh:
	var st := _new_st()
	# neck: base at the pivot, rising and reaching forward (-Z)
	_limb(st, Vector3.ZERO, Vector3(0.0, 0.30, -0.30), Vector2(0.105, 0.125), Vector2(0.072, 0.082))
	# skull
	_limb(st, Vector3(0.0, 0.30, -0.30), Vector3(0.0, 0.275, -0.44), Vector2(0.070, 0.078), Vector2(0.055, 0.062))
	# muzzle
	_limb(st, Vector3(0.0, 0.275, -0.44), Vector3(0.0, 0.245, -0.565), Vector2(0.050, 0.055), Vector2(0.036, 0.040))
	# ears
	for s in [-1.0, 1.0]:
		_limb(
			st,
			Vector3(0.062 * s, 0.345, -0.31),
			Vector3(0.145 * s, 0.435, -0.29),
			Vector2(0.012, 0.030),
			Vector2(0.008, 0.048)
		)
	if antlers:
		for s in [-1.0, 1.0]:
			var base := Vector3(0.048 * s, 0.355, -0.325)
			var mid := base + Vector3(0.075 * s, 0.24, 0.02)
			var top := mid + Vector3(0.055 * s, 0.22, -0.06)
			_limb(st, base, mid, Vector2(0.017, 0.017), Vector2(0.012, 0.012))
			_limb(st, mid, top, Vector2(0.012, 0.012), Vector2(0.007, 0.007))
			_limb(st, mid, mid + Vector3(0.02 * s, 0.10, -0.20), Vector2(0.011, 0.011), Vector2(0.006, 0.006))
			_limb(
				st,
				base + Vector3(0.02 * s, 0.09, 0.0),
				base + Vector3(0.03 * s, 0.16, -0.15),
				Vector2(0.010, 0.010),
				Vector2(0.006, 0.006)
			)
	return _finish(st, mat)


class Deer:
	extends RefCounted
	var root: Node3D
	var head: Node3D
	var legs: Array = []
	var pos := Vector2.ZERO
	var yaw := 0.0
	var target := Vector2.ZERO
	var state := 0
	var timer := 0.0
	var speed := 0.0
	var gait := 0.0
	var pitch := 0.0
	var size := 1.0
	var vis := true


class Herd:
	extends RefCounted
	var deer: Array = []
	var home := Vector2.ZERO
	var spot := Vector2.ZERO
	var spot_timer := 0.0


func _spawn_deer() -> void:
	var anchors := [
		WorldMap.P_FIELDS + Vector2(38.0, -26.0),
		WorldMap.P_FOREST_CAMP + Vector2(46.0, 34.0),
		WorldMap.P_HIDDEN_GROVE + Vector2(28.0, -30.0),
		Vector2(-56.0, 118.0),
	]
	for a in anchors:
		var home: Vector2 = _good_ground(a, 40.0, false)
		var h := Herd.new()
		h.home = home
		h.spot = home
		h.spot_timer = _rng.randf_range(8.0, 18.0)
		var count := _rng.randi_range(4, 6)
		for i in range(count):
			var d := Deer.new()
			d.size = _rng.randf_range(0.88, 1.10)
			d.pos = _good_ground(home + Vector2(_rng.randf_range(-9.0, 9.0), _rng.randf_range(-9.0, 9.0)), 6.0, false)
			d.target = d.pos
			d.yaw = _rng.randf_range(-PI, PI)
			d.state = GRAZE
			d.timer = _rng.randf_range(1.0, 7.0)
			d.gait = _rng.randf_range(0.0, TAU)

			var root := Node3D.new()
			root.name = "Chital"
			root.top_level = true  # transforms authored directly in world space
			root.scale = Vector3.ONE * d.size
			add_child(root)
			var body := MeshInstance3D.new()
			body.mesh = _m_body
			_ranged(body, 160.0)
			root.add_child(body)
			var head := MeshInstance3D.new()
			# Roughly one stag per herd carries antlers.
			head.mesh = _m_head_antler if i == 0 else _m_head
			head.position = HEAD_PIVOT
			_ranged(head, 140.0)
			root.add_child(head)
			for li in range(4):
				var leg := MeshInstance3D.new()
				leg.mesh = _m_leg
				leg.position = Vector3(LEG_X[li], LEG_Y[li], LEG_Z[li])
				_ranged(leg, 110.0)  # legs are invisible long before the body is
				root.add_child(leg)
				d.legs.append(leg)
			d.root = root
			d.head = head
			# Pose it NOW. `_update_herd` skips animals beyond VISIBLE_DIST, so an
			# unposed deer would sit at the world origin - floating or buried - until
			# the player first came near it.
			_place_deer(d)
			h.deer.append(d)
		_herds.append(h)


## Put the rig where the state says it is. Shared by spawn and by the walk update so
## there is exactly one place that decides how a deer meets the ground.
func _place_deer(d: Deer, bob: float = 0.0) -> void:
	var g := map.height_at(d.pos.x, d.pos.y)
	# Half-align to the ground: a real animal keeps its spine closer to level than the
	# hillside it stands on, and full alignment glues it flat to any slope it crosses.
	var n := map.normal_at(d.pos.x, d.pos.y).lerp(Vector3.UP, 0.5).normalized()
	var f := Vector3(-sin(d.yaw), 0.0, -cos(d.yaw))
	f = (f - n * f.dot(n)).normalized()
	d.root.position = Vector3(d.pos.x, g + bob, d.pos.y)
	d.root.basis = Basis.looking_at(f, n).scaled(Vector3.ONE * d.size)


func _update_herd(h: Herd, dt: float, sdt: float, slow: bool) -> void:
	h.spot_timer -= dt
	if h.spot_timer <= 0.0:
		h.spot_timer = _rng.randf_range(14.0, 30.0)
		h.spot = _good_ground(
			h.home + Vector2(_rng.randf_range(-26.0, 26.0), _rng.randf_range(-26.0, 26.0)), 12.0, false
		)
		for d in h.deer:
			if d.state != FLEE:
				d.state = WALK
				d.timer = _rng.randf_range(6.0, 12.0)
				d.target = h.spot + Vector2(_rng.randf_range(-6.5, 6.5), _rng.randf_range(-6.5, 6.5))

	for d in h.deer:
		var dist := Vector2(_focus.x - d.pos.x, _focus.z - d.pos.y).length()
		if dist > VISIBLE_DIST:
			if d.vis:
				d.vis = false
				d.root.visible = false
			continue
		if not d.vis:
			d.vis = true
			d.root.visible = true
		var near := dist < NEAR_ANIM
		if not near and not slow:
			continue
		_deer_step(d, sdt if not near else dt, dist, near)


func _deer_step(d: Deer, dt: float, dist: float, near: bool) -> void:
	d.timer -= dt

	# Flight response. A chital does not wait to be sure.
	if dist < DEER_FLEE_DIST and d.state != FLEE:
		d.state = FLEE
		d.timer = _rng.randf_range(3.0, 6.0)
		var away := (d.pos - Vector2(_focus.x, _focus.z)).normalized()
		if away.length() < 0.01:
			away = Vector2(1.0, 0.0)
		d.target = _good_ground(
			d.pos + away * 34.0 + Vector2(_rng.randf_range(-8.0, 8.0), _rng.randf_range(-8.0, 8.0)), 10.0, false
		)

	var want_speed := 0.0
	var want_pitch := 0.0
	match d.state:
		GRAZE:
			want_pitch = -1.02
			if d.timer <= 0.0:
				if _rng.randf() < 0.45:
					d.state = ALERT
					d.timer = _rng.randf_range(1.4, 3.4)
				else:
					d.state = WALK
					d.timer = _rng.randf_range(3.0, 7.0)
					d.target = _good_ground(
						d.pos + Vector2(_rng.randf_range(-11.0, 11.0), _rng.randf_range(-11.0, 11.0)), 6.0, false
					)
		ALERT:
			want_pitch = 0.06
			if d.timer <= 0.0:
				d.state = GRAZE
				d.timer = _rng.randf_range(4.0, 9.0)
		WALK:
			want_pitch = -0.12
			want_speed = DEER_WALK
			if d.pos.distance_to(d.target) < 0.6 or d.timer <= 0.0:
				d.state = GRAZE
				d.timer = _rng.randf_range(4.0, 10.0)
		FLEE:
			want_pitch = 0.22
			want_speed = DEER_RUN
			if d.timer <= 0.0:
				d.state = ALERT
				d.timer = _rng.randf_range(1.5, 3.0)
			elif d.pos.distance_to(d.target) < 1.0:
				var away := (d.pos - Vector2(_focus.x, _focus.z)).normalized()
				d.target = d.pos + away * 20.0

	d.speed = move_toward(d.speed, want_speed, dt * 7.0)
	d.pitch = lerpf(d.pitch, want_pitch, clampf(dt * 3.4, 0.0, 1.0))

	if d.speed > 0.02:
		var to := d.target - d.pos
		var l := to.length()
		if l > 0.001:
			var dir := to / l
			var want_yaw := atan2(-dir.x, -dir.y)
			d.yaw = _approach_angle(d.yaw, want_yaw, dt * (2.2 + d.speed * 0.7))
		var fwd := Vector2(-sin(d.yaw), -cos(d.yaw))
		var step := fwd * d.speed * dt
		var np := d.pos + step
		# Never wade into the river and never climb a cliff.
		if (
			map.in_bounds(np.x, np.y)
			and map.water_depth_at(np.x, np.y) < 0.45
			and map.slope_at(np.x, np.y) < DEER_MAX_SLOPE
		):
			d.pos = np
		else:
			d.yaw += 1.1 * dt * 3.0
		d.gait += dt * d.speed * 2.55

	# --- pose ----------------------------------------------------------------
	var bob: float = 0.0
	if near:
		var amp: float = clampf(d.speed * 0.135, 0.0, 0.62)
		bob = sin(d.gait * 2.0) * amp * 0.055
		for i in range(4):
			var ph: float = d.gait + (0.0 if (i == 0 or i == 3) else PI)
			var swing: float = sin(ph) * amp
			var lift: float = maxf(0.0, cos(ph)) * amp * 0.20
			var leg: Node3D = d.legs[i]
			leg.rotation = Vector3(swing, 0.0, 0.0)
			leg.position.y = LEG_Y[i] + lift
		d.head.rotation.x = d.pitch + sin(d.gait * 2.0 + 0.8) * 0.035
	else:
		d.head.rotation.x = d.pitch

	_place_deer(d, bob)


static func _approach_angle(cur: float, want: float, amount: float) -> float:
	var diff := wrapf(want - cur, -PI, PI)
	return cur + clampf(diff, -amount, amount)


# =============================================================================
#  MONKEYS - sitting and hopping near the village and the big trees.
# =============================================================================
func _build_monkey_meshes() -> void:
	var fur := StandardMaterial3D.new()
	# A 0.58 grey is a brighter surface than moonlit grass (~0.15), so under night
	# ambient the troop lit up as pale blobs on black ground - they read as grubs, not
	# as langurs. A grey langur in daylight is closer to 0.33.
	fur.albedo_color = Color(0.335, 0.315, 0.280)
	fur.roughness = 0.96

	var face := StandardMaterial3D.new()
	face.albedo_color = Color(0.115, 0.105, 0.100)
	face.roughness = 0.9

	var st := _new_st()
	# haunches -> chest, sitting up
	_limb(st, Vector3(0.0, 0.10, 0.10), Vector3(0.0, 0.30, -0.02), Vector2(0.105, 0.095), Vector2(0.088, 0.082))
	# thighs folded forward
	for s in [-1.0, 1.0]:
		_limb(
			st,
			Vector3(0.070 * s, 0.11, 0.055),
			Vector3(0.078 * s, 0.075, -0.10),
			Vector2(0.035, 0.040),
			Vector2(0.026, 0.028)
		)
		_limb(
			st,
			Vector3(0.078 * s, 0.075, -0.10),
			Vector3(0.070 * s, 0.030, -0.145),
			Vector2(0.024, 0.026),
			Vector2(0.020, 0.018)
		)
		# arms hanging to the ground
		_limb(
			st,
			Vector3(0.082 * s, 0.275, -0.03),
			Vector3(0.092 * s, 0.13, -0.075),
			Vector2(0.028, 0.030),
			Vector2(0.021, 0.022)
		)
		_limb(
			st,
			Vector3(0.092 * s, 0.13, -0.075),
			Vector3(0.085 * s, 0.028, -0.095),
			Vector2(0.020, 0.021),
			Vector2(0.017, 0.018)
		)
	# tail, three segments arcing up behind
	_limb(st, Vector3(0.0, 0.10, 0.12), Vector3(0.0, 0.075, 0.30), Vector2(0.028, 0.028), Vector2(0.021, 0.021))
	_limb(st, Vector3(0.0, 0.075, 0.30), Vector3(0.0, 0.17, 0.42), Vector2(0.021, 0.021), Vector2(0.016, 0.016))
	_limb(st, Vector3(0.0, 0.17, 0.42), Vector3(0.0, 0.32, 0.40), Vector2(0.016, 0.016), Vector2(0.010, 0.010))
	_m_monkey = _finish(st, fur)

	var hst := _new_st()
	_limb(hst, Vector3(0.0, 0.0, 0.02), Vector3(0.0, 0.075, -0.055), Vector2(0.068, 0.070), Vector2(0.055, 0.052))
	for s in [-1.0, 1.0]:
		_limb(
			hst,
			Vector3(0.058 * s, 0.030, -0.01),
			Vector3(0.092 * s, 0.045, -0.005),
			Vector2(0.010, 0.030),
			Vector2(0.007, 0.034)
		)
	_m_monkey_head = _finish(hst, fur)
	# Second surface: the black face. That grey-body / black-face contrast is the whole
	# read on a langur, and a single dark head mesh just looked like a lump.
	var fst := _new_st()
	_limb(fst, Vector3(0.0, 0.066, -0.050), Vector3(0.0, 0.040, -0.128), Vector2(0.044, 0.042), Vector2(0.030, 0.028))
	fst.generate_normals()
	fst.generate_tangents()
	fst.commit(_m_monkey_head)
	_m_monkey_head.surface_set_material(1, face)


class Monkey:
	extends RefCounted
	var root: Node3D
	var head: Node3D
	var pos := Vector2.ZERO
	var home := Vector2.ZERO
	var yaw := 0.0
	var timer := 0.0
	var hop_from := Vector2.ZERO
	var hop_to := Vector2.ZERO
	var hop_t := -1.0
	var hop_len := 0.0
	var vis := true
	var size := 1.0


func _spawn_monkeys() -> void:
	var spots := [
		WorldMap.P_VILLAGE + Vector2(16.0, -13.0),
		WorldMap.P_VILLAGE + Vector2(-19.0, 9.0),
		WorldMap.P_VILLAGE + Vector2(4.0, 21.0),
		WorldMap.P_HIDDEN_GROVE + Vector2(6.0, 5.0),
		WorldMap.P_FOREST_CAMP + Vector2(-12.0, 14.0),
		WorldMap.P_SHRINE + Vector2(-11.0, 8.0),
	]
	for s in spots:
		var count := _rng.randi_range(1, 3)
		for i in range(count):
			var m := Monkey.new()
			m.size = _rng.randf_range(1.05, 1.35)
			m.home = _good_ground(s + Vector2(_rng.randf_range(-5.0, 5.0), _rng.randf_range(-5.0, 5.0)), 5.0, false)
			m.pos = m.home
			m.yaw = _rng.randf_range(-PI, PI)
			m.timer = _rng.randf_range(1.0, 5.0)
			var root := Node3D.new()
			root.name = "Monkey"
			root.top_level = true
			add_child(root)
			var body := MeshInstance3D.new()
			body.mesh = _m_monkey
			_ranged(body, 110.0)
			root.add_child(body)
			var head := MeshInstance3D.new()
			head.mesh = _m_monkey_head
			head.position = Vector3(0.0, 0.315, -0.03)
			_ranged(head, 90.0)
			root.add_child(head)
			m.root = root
			m.head = head
			_place_monkey(m)
			_monkeys.append(m)


func _place_monkey(m: Monkey, lift: float = 0.0, squash: float = 1.0) -> void:
	var g := map.height_at(m.pos.x, m.pos.y)
	m.root.position = Vector3(m.pos.x, g + lift, m.pos.y)
	m.root.basis = Basis(Vector3.UP, m.yaw).scaled(Vector3(m.size / squash, m.size * squash, m.size / squash))


func _update_monkey(m: Monkey, dt: float, sdt: float, slow: bool, _lit: float) -> void:
	var dist := Vector2(_focus.x - m.pos.x, _focus.z - m.pos.y).length()
	if dist > VISIBLE_DIST:
		if m.vis:
			m.vis = false
			m.root.visible = false
		return
	if not m.vis:
		m.vis = true
		m.root.visible = true
	var near := dist < NEAR_ANIM
	if not near and not slow:
		return
	var d := dt if near else sdt

	if m.hop_t >= 0.0:
		m.hop_t += d * (2.4 if dist > MONKEY_FLEE_DIST else 3.6)
		if m.hop_t >= 1.0:
			m.hop_t = -1.0
			m.pos = m.hop_to
		else:
			m.pos = m.hop_from.lerp(m.hop_to, m.hop_t)
	else:
		m.timer -= d
		var startled := dist < MONKEY_FLEE_DIST
		if m.timer <= 0.0 or startled:
			m.timer = _rng.randf_range(2.5, 7.0)
			var dir: Vector2
			if startled:
				dir = (m.pos - Vector2(_focus.x, _focus.z)).normalized() * _rng.randf_range(2.0, 3.4)
			else:
				dir = (
					Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
					* _rng.randf_range(0.8, 2.2)
				)
			var to := m.pos + dir
			if to.distance_to(m.home) > 11.0:
				to = m.home + (to - m.home).normalized() * 11.0
			if map.in_bounds(to.x, to.y) and map.water_depth_at(to.x, to.y) < 0.25:
				m.hop_from = m.pos
				m.hop_to = to
				m.hop_len = m.pos.distance_to(to)
				m.hop_t = 0.0
				m.yaw = atan2(-dir.x, -dir.y)

	var lift := 0.0
	var squash := 1.0
	if m.hop_t >= 0.0:
		lift = sin(m.hop_t * PI) * (0.16 + m.hop_len * 0.16)
		squash = 1.0 + sin(m.hop_t * PI) * 0.10
	_place_monkey(m, lift, squash)
	if near:
		# idle: head cocking, plus a look toward the player when close
		var look: float = 0.0
		if dist < 26.0:
			var to_p := Vector2(_focus.x - m.pos.x, _focus.z - m.pos.y)
			look = clampf(wrapf(atan2(-to_p.x, -to_p.y) - m.yaw, -PI, PI), -0.9, 0.9)
		m.head.rotation.y = lerpf(m.head.rotation.y, look, clampf(dt * 4.0, 0.0, 1.0))
		m.head.rotation.x = sin(_t * 1.7 + m.home.x) * 0.11
		m.head.position.y = 0.315 + sin(_t * 2.3 + m.home.y) * 0.012


# =============================================================================
#  FLOCKS - birds, butterflies, bats. One MultiMesh each, wings flapped in the
#  vertex shader off per-instance custom data, so a flock is one draw call.
# =============================================================================
const FLAP_SHADER := """
shader_type spatial;
render_mode cull_disabled, specular_disabled, diffuse_lambert, shadows_disabled;

uniform vec4 body_color : source_color = vec4(0.09, 0.09, 0.11, 1.0);
uniform vec4 wing_color : source_color = vec4(0.15, 0.15, 0.18, 1.0);
uniform float flap_amp = 1.15;
uniform float wing_start = 0.03;
uniform float wing_full = 0.11;
uniform float rough = 0.9;
uniform float emissive = 0.0;
uniform vec4 tip_color : source_color = vec4(0.09, 0.06, 0.04, 1.0);
uniform float tip_amount : hint_range(0.0, 1.0) = 0.0;
uniform float tip_start = 0.20;
uniform float tip_end = 0.32;

varying float v_wing;
varying float v_tip;

void vertex() {
	float ph = INSTANCE_CUSTOM.x * 6.2831853;
	float amp = flap_amp * (0.72 + 0.55 * INSTANCE_CUSTOM.y);
	float w = abs(VERTEX.x);
	float k = smoothstep(wing_start, wing_full, w);
	v_wing = k;
	v_tip = smoothstep(tip_start, tip_end, w);
	float a = sin(ph) * amp * k;
	float ca = cos(a);
	float sa = sin(a);
	float sx = VERTEX.x < 0.0 ? -1.0 : 1.0;
	vec2 p = vec2(w, VERTEX.y);
	vec2 nn = vec2(NORMAL.x * sx, NORMAL.y);
	VERTEX.x = (p.x * ca - p.y * sa) * sx;
	VERTEX.y = p.x * sa + p.y * ca;
	NORMAL.x = (nn.x * ca - nn.y * sa) * sx;
	NORMAL.y = nn.x * sa + nn.y * ca;
}

void fragment() {
	vec3 c = mix(body_color.rgb, wing_color.rgb, v_wing);
	c = mix(c, tip_color.rgb, v_tip * tip_amount);
	ALBEDO = c;
	EMISSION = c * emissive;
	ROUGHNESS = rough;
	SPECULAR = 0.15;
}
"""


class Flock:
	extends RefCounted
	var mmi: MultiMeshInstance3D
	var mm: MultiMesh
	var n := 0
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	var spot := PackedVector3Array()
	var phase := PackedFloat32Array()
	var rnd := PackedFloat32Array()
	var down := PackedByteArray()
	var home := Vector2.ZERO
	var centre := Vector3.ZERO
	var orbit := 0.0
	var radius := 20.0
	var alt := 24.0
	var cruise := 8.0
	var flap := 7.0
	var state := 0
	var timer := 0.0
	var kind := 0
	var size := 1.0
	var offset := Vector2.ZERO
	var follows := false
	var awake := true
	var acc := PackedVector3Array()


func _flap_material(
	body: Color,
	wing: Color,
	amp: float,
	w0: float,
	w1: float,
	emissive: float = 0.0,
	tip: float = 0.0,
	tip_span: Vector2 = Vector2(0.2, 0.32),
	tip_col: Color = Color(0.09, 0.06, 0.04)
) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = FLAP_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("body_color", body)
	m.set_shader_parameter("wing_color", wing)
	m.set_shader_parameter("flap_amp", amp)
	m.set_shader_parameter("wing_start", w0)
	m.set_shader_parameter("wing_full", w1)
	m.set_shader_parameter("emissive", emissive)
	m.set_shader_parameter("tip_amount", tip)
	m.set_shader_parameter("tip_start", tip_span.x)
	m.set_shader_parameter("tip_end", tip_span.y)
	m.set_shader_parameter("tip_color", tip_col)
	return m


func _bird_mesh(mat: Material) -> ArrayMesh:
	var st := _new_st()
	# body along -Z (Godot forward)
	_limb(st, Vector3(0.0, 0.0, 0.11), Vector3(0.0, 0.005, -0.10), Vector2(0.022, 0.024), Vector2(0.020, 0.022))
	_limb(st, Vector3(0.0, 0.005, -0.10), Vector3(0.0, 0.012, -0.165), Vector2(0.016, 0.017), Vector2(0.007, 0.008))
	# tail fan
	_card(st, -0.035, 0.035, 0.11, 0.20, 0.0)
	# wings: flat cards spreading along +-X so the vertex shader can hinge them
	for s in [-1.0, 1.0]:
		var a: float = minf(0.024 * s, 0.30 * s)
		var b: float = maxf(0.024 * s, 0.30 * s)
		_card(st, a, b, -0.055, 0.055, 0.004)
		var a2: float = minf(0.10 * s, 0.31 * s)
		var b2: float = maxf(0.10 * s, 0.31 * s)
		_card(st, a2, b2, 0.02, 0.075, 0.004)
	return _finish(st, mat)


## Plain tiger: a long swept forewing with a rounded apex, a shorter rounded hindwing.
## Three chord segments per wing, so the outline actually curves.
func _butterfly_mesh(mat: Material) -> ArrayMesh:
	var st := _new_st()
	_limb(st, Vector3(0.0, 0.0, 0.026), Vector3(0.0, 0.0, -0.028), Vector2(0.0045, 0.0045), Vector2(0.0028, 0.0028))
	for s in [-1.0, 1.0]:
		# forewing: root -> mid -> swept apex
		_taper_card(st, 0.005 * s, 0.020 * s, -0.010, 0.019, -0.010, 0.021, 0.0)
		_taper_card(st, 0.020 * s, 0.032 * s, -0.010, 0.021, -0.007, 0.017, 0.0)
		_taper_card(st, 0.032 * s, 0.041 * s, -0.007, 0.017, -0.002, 0.008, 0.0)
		# hindwing: shorter, rounder, trailing
		_taper_card(st, 0.005 * s, 0.017 * s, 0.019, 0.013, 0.021, 0.014, 0.0)
		_taper_card(st, 0.017 * s, 0.027 * s, 0.021, 0.014, 0.020, 0.009, 0.0)
	return _finish(st, mat)


func _bat_mesh(mat: Material) -> ArrayMesh:
	var st := _new_st()
	_limb(st, Vector3(0.0, 0.0, 0.06), Vector3(0.0, 0.0, -0.055), Vector2(0.017, 0.019), Vector2(0.013, 0.014))
	for s in [-1.0, 1.0]:
		var a: float = minf(0.016 * s, 0.115 * s)
		var b: float = maxf(0.016 * s, 0.115 * s)
		_card(st, a, b, -0.045, 0.030, 0.0)
		var a2: float = minf(0.115 * s, 0.185 * s)
		var b2: float = maxf(0.115 * s, 0.185 * s)
		_card(st, a2, b2, -0.020, 0.048, 0.0)
	return _finish(st, mat)


func _make_flock(nm: String, count: int, mesh: ArrayMesh, kind: int) -> Flock:
	var f := Flock.new()
	f.kind = kind
	f.n = count
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	f.mm = mm
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	mmi.multimesh = mm
	mmi.top_level = true  # instance transforms are authored in world space
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 80, 80))
	add_child(mmi)
	f.mmi = mmi
	f.pos.resize(count)
	f.vel.resize(count)
	f.spot.resize(count)
	f.acc.resize(count)
	f.phase.resize(count)
	f.rnd.resize(count)
	f.down.resize(count)
	_flocks.append(f)
	return f


func _spawn_flocks() -> void:
	var bird_mat := _flap_material(
		Color(0.085, 0.075, 0.075),
		Color(0.16, 0.14, 0.13),
		1.25,
		0.03,
		0.12,
		0.0,
		0.6,
		Vector2(0.16, 0.30),
		Color(0.05, 0.045, 0.045)
	)
	var bird := _bird_mesh(bird_mat)
	var homes := [
		WorldMap.P_FIELDS + Vector2(26.0, 30.0),
		WorldMap.P_FORD + Vector2(-18.0, -26.0),
		WorldMap.P_VILLAGE + Vector2(30.0, -34.0),
		WorldMap.P_LOOKOUT + Vector2(-30.0, 26.0),
		WorldMap.P_HIDDEN_GROVE + Vector2(40.0, -18.0),
	]
	for hi in range(homes.size()):
		var f := _make_flock("BirdFlock%d" % hi, _rng.randi_range(9, 13), bird, K_BIRD)
		f.home = homes[hi]
		f.radius = _rng.randf_range(14.0, 26.0)
		f.alt = _rng.randf_range(17.0, 32.0)
		f.cruise = _rng.randf_range(7.0, 10.5)
		f.flap = _rng.randf_range(5.5, 8.5)
		f.size = _rng.randf_range(0.85, 1.35)
		f.state = CIRCLE
		f.timer = _rng.randf_range(6.0, 22.0)
		f.centre = map.ground(f.home.x, f.home.y) + Vector3(0.0, f.alt, 0.0)
		_seed_flock(f, 6.0)

	# Butterflies live wherever the player is, in daylight, over open ground.
	# Plain tiger: burnt orange panel, dark body, black wingtip.
	var bfly_mat := _flap_material(
		Color(0.13, 0.08, 0.04),
		Color(0.88, 0.45, 0.11),
		1.55,
		0.005,
		0.018,
		0.08,
		0.80,
		Vector2(0.026, 0.040),
		Color(0.09, 0.055, 0.03)
	)
	var bfly := _butterfly_mesh(bfly_mat)
	for i in range(2):
		var f := _make_flock("Butterflies%d" % i, 14, bfly, K_BUTTERFLY)
		# Held out at arm's length from the player, not swarming the lens. 15 m was too
		# far: a plain tiger is 8 cm across, which at 15 m is two pixels, so the
		# butterflies were simulating perfectly and reading as nothing at all.
		var a: float = TAU * float(i) / 2.0 + 0.9
		f.offset = Vector2(cos(a), sin(a)) * 7.5
		f.home = Vector2(_focus.x, _focus.z) + f.offset
		f.radius = 4.5
		f.alt = 0.9
		f.cruise = 1.4
		f.flap = 11.0
		# 1.9 makes a 15 cm butterfly. A plain tiger is 7-8 cm; at close range the
		# oversized version reads as a floating orange slab, not as an insect.
		f.size = 1.2
		f.follows = true
		f.state = CIRCLE
		# `centre` MUST be set before seeding. Birds and bats do it; the butterflies did
		# not, so both flocks were born around Vector3.ZERO - the world origin, hundreds
		# of metres from anywhere - and then crawled toward the player at their 1.4 m/s
		# cruise, which is slower than walking. They were never once on screen.
		f.centre = map.ground(f.home.x, f.home.y) + Vector3(0.0, f.alt, 0.0)
		_seed_flock(f, 5.0)

	# Bats at the ruins.
	# Bats are only ever seen at night, so a 0.045 albedo with no emission is literally
	# black on black - the flock was on screen and invisible. A little self-lift plus a
	# lighter wing membrane makes them read as silhouettes without making them glow.
	var bat_mat := _flap_material(Color(0.115, 0.105, 0.120), Color(0.185, 0.165, 0.190), 1.05, 0.016, 0.08, 0.22)
	var bat := _bat_mesh(bat_mat)
	var bf := _make_flock("Bats", 30, bat, K_BAT)
	bf.home = WorldMap.P_RUINS
	bf.radius = 19.0
	# Higher, so they cross the sky rather than a black hillside.
	bf.alt = 18.0
	bf.cruise = 9.0
	bf.flap = 9.5
	bf.size = 1.75
	bf.state = CIRCLE
	bf.centre = map.ground(bf.home.x, bf.home.y) + Vector3(0.0, bf.alt, 0.0)
	_seed_flock(bf, 10.0)


func _seed_flock(f: Flock, spread: float) -> void:
	for i in range(f.n):
		f.pos[i] = (
			f.centre
			+ Vector3(
				_rng.randf_range(-spread, spread),
				_rng.randf_range(-spread * 0.35, spread * 0.35),
				_rng.randf_range(-spread, spread)
			)
		)
		f.vel[i] = Vector3(_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.0, 1.0)).normalized() * f.cruise
		f.phase[i] = _rng.randf()
		f.rnd[i] = _rng.randf()
		f.down[i] = 0


func _update_flock(f: Flock, dt: float, slow: bool, night: bool, lit: float) -> void:
	# Who is allowed to be out right now.
	var allowed := true
	match f.kind:
		K_BUTTERFLY:
			# Butterflies want sun and open flowery ground: not deep canopy, not rain.
			var wet: bool = sky != null and sky.overcast > 0.45
			var b: int = map.biome_at(_focus.x, _focus.z)
			var flowery: bool = (
				b == WorldMap.Biome.MEADOW
				or b == WorldMap.Biome.FIELD
				or b == WorldMap.Biome.VILLAGE
				or b == WorldMap.Biome.PATH
			)
			allowed = lit > 0.35 and not wet and flowery and map.forest_density(Vector2(_focus.x, _focus.z)) < 0.55
		K_BAT:
			allowed = night
	var d_home := Vector2(_focus.x, _focus.z).distance_to(f.home)
	if f.follows:
		d_home = 0.0
	if not allowed or d_home > VISIBLE_DIST + 40.0:
		if f.awake:
			f.awake = false
			f.mmi.visible = false
		return
	if not f.awake:
		f.awake = true
		f.mmi.visible = true
		if f.follows:
			f.home = Vector2(_focus.x, _focus.z)
			f.centre = map.ground(f.home.x, f.home.y) + Vector3(0.0, f.alt, 0.0)
			_seed_flock(f, 10.0)

	# Far flocks think on the slow tick only; they are silhouettes at that range.
	var near := d_home < NEAR_ANIM + 40.0
	if not near and not slow:
		return
	var step := dt if near else SLOW_PERIOD

	if f.follows:
		# Butterflies stay with the player, and only over open sunny ground.
		var fp := Vector2(_focus.x, _focus.z) + f.offset
		var jumped := false
		if fp.distance_to(f.home) > 18.0:
			jumped = fp.distance_to(f.home) > 50.0
			f.home = _good_ground(fp + Vector2(_rng.randf_range(-7.0, 7.0), _rng.randf_range(-7.0, 7.0)), 8.0, false)
		f.centre = map.ground(f.home.x, f.home.y) + Vector3(0.0, f.alt, 0.0)
		# Also reseed whenever the swarm ITSELF has been left behind, not only when the
		# home teleports. A butterfly cruises at 1.4 m/s and the player walks faster
		# than that, so once the gap opens it can never close on its own.
		if not jumped and f.n > 0:
			var mid := Vector3.ZERO
			for i in range(f.n):
				mid += f.pos[i]
			mid /= float(f.n)
			jumped = Vector2(mid.x - f.centre.x, mid.z - f.centre.z).length() > 22.0
		if jumped:
			# The player outran them; a butterfly will not chase across a valley.
			_seed_flock(f, 7.0)

	_flock_state(f, step, night)
	_flock_steer(f, step)
	_flock_write(f, step, near)


func _flock_state(f: Flock, dt: float, _night: bool) -> void:
	f.timer -= dt
	f.orbit += dt * f.cruise / maxf(f.radius, 2.0)
	var focus2 := Vector2(_focus.x, _focus.z)

	if f.kind == K_BIRD:
		match f.state:
			CIRCLE:
				f.centre = map.ground(f.home.x, f.home.y) + Vector3(0.0, f.alt, 0.0)
				if f.timer <= 0.0:
					# Pick a patch of ground and come down on it.
					var land := _good_ground(
						f.home + Vector2(_rng.randf_range(-16.0, 16.0), _rng.randf_range(-16.0, 16.0)), 12.0, false
					)
					for i in range(f.n):
						var p := land + Vector2(_rng.randf_range(-5.0, 5.0), _rng.randf_range(-5.0, 5.0))
						f.spot[i] = map.ground(p.x, p.y) + Vector3(0.0, 0.09, 0.0)
					f.state = DESCEND
					f.timer = 14.0
			DESCEND:
				var all_down := true
				for i in range(f.n):
					if f.down[i] == 0:
						all_down = false
						break
				if all_down or f.timer <= 0.0:
					f.state = PERCH
					f.timer = _rng.randf_range(9.0, 20.0)
				if focus2.distance_to(f.home) < 30.0:
					_startle(f)
			PERCH:
				if f.timer <= 0.0:
					_startle(f)
				else:
					var closest := 1e9
					for i in range(f.n):
						closest = minf(closest, focus2.distance_to(Vector2(f.pos[i].x, f.pos[i].z)))
					if closest < 17.0:
						_startle(f)
			TAKEOFF:
				if f.timer <= 0.0:
					f.state = CIRCLE
					f.timer = _rng.randf_range(16.0, 34.0)
	else:
		f.centre = map.ground(f.home.x, f.home.y) + Vector3(0.0, f.alt, 0.0)


func _startle(f: Flock) -> void:
	f.state = TAKEOFF
	f.timer = 3.2
	for i in range(f.n):
		f.down[i] = 0
		f.vel[i] = Vector3(_rng.randf_range(-2.5, 2.5), _rng.randf_range(4.5, 8.0), _rng.randf_range(-2.5, 2.5))


func _flock_steer(f: Flock, dt: float) -> void:
	var goal := f.centre
	if f.kind == K_BIRD and (f.state == CIRCLE or f.state == TAKEOFF):
		goal = f.centre + Vector3(cos(f.orbit), 0.0, sin(f.orbit)) * f.radius
		goal.y += sin(f.orbit * 1.7) * 3.0
	elif f.kind == K_BAT:
		goal = f.centre + Vector3(cos(f.orbit * 1.6), sin(f.orbit * 2.3) * 0.45, sin(f.orbit * 1.6)) * f.radius
	elif f.kind == K_BUTTERFLY:
		goal = f.centre

	var max_speed: float = f.cruise * (1.55 if f.state == TAKEOFF else 1.0)
	for i in range(f.n):
		if f.down[i] == 1:
			f.vel[i] = Vector3.ZERO
			continue
		var p := f.pos[i]
		var v := f.vel[i]
		var sep := Vector3.ZERO
		var ali := Vector3.ZERO
		var coh := Vector3.ZERO
		var cnt := 0
		for j in range(f.n):
			if j == i:
				continue
			var dv: Vector3 = f.pos[j] - p
			var dl := dv.length()
			if dl < 0.0001:
				continue
			if dl < 2.6:
				sep -= dv / (dl * dl)
			if dl < 10.0:
				ali += f.vel[j]
				coh += f.pos[j]
				cnt += 1
		var steer := Vector3.ZERO
		if cnt > 0:
			ali /= float(cnt)
			coh /= float(cnt)
			steer += (ali - v) * 0.55
			steer += (coh - p) * 0.35
		steer += sep * 5.0

		var g := goal
		if f.kind == K_BIRD and (f.state == DESCEND or f.state == PERCH):
			g = f.spot[i]
		elif f.kind == K_BUTTERFLY:
			# Butterflies do not fly straight; they bounce.
			var ph := _t * (1.1 + f.rnd[i]) + f.rnd[i] * 30.0
			g = f.centre + Vector3(cos(ph) * f.radius, 0.0, sin(ph * 1.4) * f.radius)
			# Height is measured from the ground UNDER THE BUTTERFLY, not under the
			# flock's home. On a slope the home-relative goal fell below the terrain,
			# the clamp below pinned every one of them to gy + 0.25, and a meadow full
			# of butterflies read as a meadow littered with orange scraps.
			g.y = map.height_at(g.x, g.z) + 0.85 + sin(ph * 2.3) * 0.45
		steer += (g - p).normalized() * (max_speed * 1.7)
		steer += (
			Vector3(
				sin(_t * 1.9 + f.rnd[i] * 21.0), sin(_t * 2.7 + f.rnd[i] * 13.0) * 0.4, cos(_t * 1.6 + f.rnd[i] * 17.0)
			)
			* (2.4 if f.kind == K_BAT else 0.9)
		)

		v += steer * dt
		var sp := v.length()
		if sp > max_speed:
			v = v / sp * max_speed
		elif sp < max_speed * 0.35:
			if sp > 0.001:
				v = v / sp * (max_speed * 0.35)
			else:
				v = Vector3(0.0, 0.0, max_speed * 0.35)
		p += v * dt

		# Ground contact: nothing may pass through the terrain.
		var gy := map.height_at(p.x, p.z)
		if f.kind == K_BIRD and (f.state == DESCEND or f.state == PERCH):
			if p.distance_to(f.spot[i]) < 0.7:
				p = f.spot[i]
				v = Vector3.ZERO
				f.down[i] = 1
			p.y = maxf(p.y, gy + 0.09)
		elif f.kind == K_BUTTERFLY:
			p.y = clampf(p.y, gy + 0.25, gy + 2.6)
		else:
			p.y = maxf(p.y, gy + 2.0)

		f.acc[i] = steer
		f.pos[i] = p
		f.vel[i] = v


func _flock_write(f: Flock, dt: float, near: bool) -> void:
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for i in range(f.n):
		var p := f.pos[i]
		lo = lo.min(p)
		hi = hi.max(p)
		var v := f.vel[i]
		var sp := v.length()
		var fwd: Vector3
		if sp > 0.05:
			fwd = v / sp
		else:
			fwd = Vector3(sin(f.rnd[i] * TAU), 0.0, cos(f.rnd[i] * TAU))
		var up := Vector3.UP
		if absf(fwd.y) > 0.965:
			# Climbing or diving vertically: UP is degenerate as a reference. The
			# obvious substitute is degenerate too when fwd is EXACTLY vertical
			# (Vector3(fwd.z, 0, -fwd.x) is then the zero vector), and a zero `up`
			# makes looking_at return garbage that rasterises as a needle across the
			# whole screen. Pick a fixed axis in that case.
			var side := Vector3(fwd.z, 0.0, -fwd.x)
			if side.length_squared() < 1e-8:
				side = Vector3(1.0, 0.0, 0.0)
			up = side.normalized().cross(fwd).normalized()
			if up.length_squared() < 1e-8:
				up = Vector3(0.0, 0.0, 1.0)
		elif f.down[i] == 0:
			# Bank into the turn.
			var bank: float = clampf(fwd.cross(f.acc[i]).y * -0.06, -0.85, 0.85)
			up = Vector3.UP.rotated(fwd, bank)
		var sc: float = f.size * (0.82 + 0.36 * f.rnd[i])
		var b := Basis.looking_at(fwd, up).scaled(Vector3.ONE * sc)
		f.mm.set_instance_transform(i, Transform3D(b, p))

		if f.down[i] == 1:
			# Perched: wings folded, an occasional hop and a bob.
			f.phase[i] = 0.0
			f.mm.set_instance_custom_data(i, Color(0.0, f.rnd[i], 0.0, 0.0))
		else:
			var rate: float = f.flap * (0.75 + 0.5 * f.rnd[i])
			if near:
				f.phase[i] = fposmod(f.phase[i] + dt * rate, 1.0)
			f.mm.set_instance_custom_data(i, Color(f.phase[i], f.rnd[i], 0.0, 0.0))
	# Real AABB, refreshed as the flock moves, so culling still works.
	f.mmi.custom_aabb = AABB(lo - Vector3(2, 2, 2), (hi - lo) + Vector3(4, 4, 4))


# =============================================================================
#  FISH - a few flickers of silver in the shallows
# =============================================================================
class FishShoal:
	extends RefCounted
	var mmi: MultiMeshInstance3D
	var mm: MultiMesh
	var n := 0
	var idx := PackedFloat32Array()  # arc position along the river centreline
	var lat := PackedFloat32Array()  # lateral offset in metres
	var spd := PackedFloat32Array()
	var rnd := PackedFloat32Array()
	var pts: Array = []
	# Live world positions, mirrored out of the MultiMesh. `--headless` runs the dummy
	# renderer, where MultiMesh.get_instance_transform() always reads back identity, so
	# a headless grounding audit cannot see where the shoal actually is without this.
	var wp := PackedVector3Array()


func _spawn_fish() -> void:
	var pts := map.river_points()
	if pts.size() < 8:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.78, 0.82)
	mat.metallic = 0.55
	mat.metallic_specular = 0.85
	mat.roughness = 0.22
	mat.emission_enabled = true
	mat.emission = Color(0.35, 0.45, 0.5)
	mat.emission_energy_multiplier = 0.15

	var st := _new_st()
	_limb(st, Vector3(0.0, 0.0, -0.14), Vector3(0.0, 0.0, 0.04), Vector2(0.022, 0.036), Vector2(0.028, 0.046))
	_limb(st, Vector3(0.0, 0.0, 0.04), Vector3(0.0, 0.0, 0.18), Vector2(0.026, 0.042), Vector2(0.008, 0.014))
	_limb(st, Vector3(0.0, 0.0, 0.17), Vector3(0.0, 0.0, 0.26), Vector2(0.005, 0.013), Vector2(0.005, 0.075))
	var mesh := _finish(st, mat)

	var f := FishShoal.new()
	f.n = 20
	f.pts = pts
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = f.n
	f.mm = mm
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Fish"
	mmi.multimesh = mm
	mmi.top_level = true
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-30, -6, -30), Vector3(60, 12, 60))
	mmi.visible = false
	add_child(mmi)
	f.mmi = mmi
	f.idx.resize(f.n)
	f.lat.resize(f.n)
	f.spd.resize(f.n)
	f.rnd.resize(f.n)
	f.wp.resize(f.n)
	for i in range(f.n):
		f.idx[i] = 0.0
		f.lat[i] = _rng.randf_range(-1.6, 1.6)
		f.spd[i] = _rng.randf_range(0.35, 1.05)
		f.rnd[i] = _rng.randf()
	_fish = f


func _update_fish(dt: float, slow: bool) -> void:
	var f := _fish
	var focus2 := Vector2(_focus.x, _focus.z)
	if slow:
		# Anchor the shoal to whatever stretch of river the player is nearest.
		var best := -1
		var bd := 1e18
		for i in range(f.pts.size()):
			var d: float = focus2.distance_squared_to(f.pts[i])
			if d < bd:
				bd = d
				best = i
		if bd > 70.0 * 70.0 or best < 0:
			if f.mmi.visible:
				f.mmi.visible = false
			return
		if not f.mmi.visible:
			f.mmi.visible = true
			for i in range(f.n):
				f.idx[i] = float(best) + _rng.randf_range(-9.0, 9.0)
		# Keep them from drifting out of sight down the river.
		for i in range(f.n):
			if absf(f.idx[i] - float(best)) > 14.0:
				f.idx[i] = float(best) + _rng.randf_range(-8.0, 8.0)
	if not f.mmi.visible:
		return

	var last := f.pts.size() - 1
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for i in range(f.n):
		f.idx[i] = clampf(f.idx[i] + dt * f.spd[i] * 0.55, 1.0, float(last - 1))
		var i0 := int(f.idx[i])
		var t: float = f.idx[i] - float(i0)
		var a: Vector2 = f.pts[i0]
		var b: Vector2 = f.pts[i0 + 1]
		var c: Vector2 = a.lerp(b, t)
		var tang: Vector2 = (b - a).normalized()
		var nrm := Vector2(-tang.y, tang.x)
		var wob: float = sin(_t * (2.2 + f.rnd[i] * 2.0) + f.rnd[i] * 30.0)
		var p2: Vector2 = c + nrm * (f.lat[i] + wob * 0.35)
		var depth := map.water_depth_at(p2.x, p2.y)
		if depth < 0.25:
			# Too shallow: push back toward the centre of the channel.
			f.lat[i] *= 0.6
			p2 = c + nrm * f.lat[i]
			depth = map.water_depth_at(p2.x, p2.y)
		var wy := map.water_y_at(p2.x, p2.y)
		var bed := map.height_at(p2.x, p2.y)
		var y: float = clampf(wy - 0.22 - f.rnd[i] * 0.25, bed + 0.07, wy - 0.06)
		var p := Vector3(p2.x, y, p2.y)
		f.wp[i] = p
		lo = lo.min(p)
		hi = hi.max(p)
		var heading := tang + nrm * wob * 0.5
		var fwd := Vector3(heading.x, 0.0, heading.y).normalized()
		# Roll oscillation: this is what makes them read as flashes of silver.
		var roll: float = sin(_t * (5.0 + f.rnd[i] * 3.0) + f.rnd[i] * 12.0) * 0.55
		var up := Vector3.UP.rotated(fwd, roll)
		var b3 := Basis.looking_at(fwd, up).scaled(Vector3.ONE * (0.95 + f.rnd[i] * 0.6))
		f.mm.set_instance_transform(i, Transform3D(b3, p))
	f.mmi.custom_aabb = AABB(lo - Vector3(2, 2, 2), (hi - lo) + Vector3(4, 4, 4))


# =============================================================================
#  Introspection - used by the render harness to aim at things that exist
# =============================================================================
## Where each herd actually settled after the ground search.
func herd_homes() -> Array:
	var out := []
	for h in _herds:
		out.append(h.home)
	return out


## Live world position of the animal nearest `p`, or `p` itself if nothing is out.
## Used by the render harness to frame a real deer rather than a spawn anchor.
func nearest_deer(p: Vector3) -> Vector3:
	var best := p
	var bd := 1e18
	for h in _herds:
		for d in h.deer:
			var q: Vector3 = d.root.position
			var dist: float = q.distance_squared_to(p)
			if dist < bd:
				bd = dist
				best = q
	return best


## Live world position of the monkey nearest `p`, or `p` if the troop is all asleep.
## Same purpose as `nearest_deer`: a render harness must aim at an animal that is
## actually there, not at the spawn anchor it wandered away from.
func nearest_monkey(p: Vector3) -> Vector3:
	var best := p
	var bd := 1e18
	for m in _monkeys:
		var q: Vector3 = m.root.global_position
		var d: float = q.distance_squared_to(p)
		if d < bd:
			bd = d
			best = q
	return best


## Home XZ of each flock, in spawn order (birds, then butterflies, then bats).
func flock_homes() -> Array:
	var out := []
	for f in _flocks:
		out.append({"home": f.home, "alt": f.alt, "kind": f.kind})
	return out


func monkey_homes() -> Array:
	var out := []
	for m in _monkeys:
		out.append(m.home)
	return out


## Triangle and draw-call budget, so the cost claim can be checked rather than asserted.
func stats() -> Dictionary:
	var tris := 0
	var draws := 0
	var animals := 0
	for h in _herds:
		for d in h.deer:
			animals += 1
			draws += 6
			tris += _tris(_m_body) + _tris(_m_head) + _tris(_m_leg) * 4
	for m in _monkeys:
		animals += 1
		draws += 2
		tris += _tris(_m_monkey) + _tris(_m_monkey_head)
	for f in _flocks:
		animals += f.n
		draws += 1
		tris += _tris(f.mm.mesh) * f.n
	if _fish:
		animals += _fish.n
		draws += 1
		tris += _tris(_fish.mm.mesh) * _fish.n
	return {"animals": animals, "triangles": tris, "draw_calls": draws}


static func _tris(m: Mesh) -> int:
	if m == null:
		return 0
	var n := 0
	for s in range(m.get_surface_count()):
		var idx: int = m.surface_get_array_index_len(s)
		n += (idx if idx > 0 else m.surface_get_array_len(s)) / 3
	return n


# =============================================================================
#  Shared placement helper
# =============================================================================
## Nearest sensible piece of standing ground to `p`: not in the river, not on a
## cliff. Deterministic - it only reads the map, never the RNG.
func _good_ground(p: Vector2, r: float, want_forest: bool) -> Vector2:
	var best := p
	var best_score := -1e9
	for i in range(16):
		var a: float = TAU * float(i) / 16.0
		for k in [0.0, 0.35, 0.65, 1.0]:
			var q := float(k)
			var c: Vector2 = p + Vector2(cos(a), sin(a)) * r * q
			if not map.in_bounds(c.x, c.y):
				continue
			var sl: float = map.slope_at(c.x, c.y)
			var score: float = -sl * 8.0 - q * 0.6
			# A hard rejection, not just a penalty: with a penalty alone the least-bad
			# cliff still won whenever the whole search disc was steep, which is how a
			# deer ended up posed halfway down a riverbank.
			if sl > STAND_MAX_SLOPE:
				score -= 40.0
			if map.water_depth_at(c.x, c.y) > 0.15:
				score -= 25.0
			if want_forest:
				score += map.forest_density(c) * 3.0
			if score > best_score:
				best_score = score
				best = c
	return best
