class_name WorldVFX
extends Node3D
## Atmosphere. Everything here is air and light rather than geometry: pollen in the
## sun, fireflies under the trees, leaves coming down, dust sheeting across open
## ground, mist lying on the river at dawn, cookfire smoke, firelight, rain.
##
## Two rules keep it cheap enough to leave running forever:
##
##   1. Nothing emits away from the player. `update_focus()` walks a handful of
##      emitters to wherever the camera is and switches each one on only when the
##      ground under the focus actually justifies it (forest for fireflies, river for
##      mist, daylight for pollen). At any instant there are ~8 live emitters, not
##      one per tree.
##   2. Every emitter shares one shader (`shaders/particle_soft.gdshader`) and one
##      pass of quads. Worst case (a downpour, which switches pollen off) is about
##      3.7k quads live at once; a normal day is well under 2k.
##
## The state evaluation runs at ~3.5 Hz, not per frame; particles do not care.
##
## Two things here were paid for once and are worth knowing:
##   * `forest_density` reads 0.000 at P_FOREST_CAMP and every other named place,
##     because they all sit on a carved path corridor. Anything gated on "am I in the
##     forest" must sample a neighbourhood - see `_forest_near`.
##   * Smoke and mist are `unshaded`, so their tint IS their lighting and has to be
##     re-driven from the time of day. They also must SHARE one material across every
##     hearth, or that update reaches only the last fire built.

const SHADER_PATH := "res://shaders/particle_soft.gdshader"

const EVAL_PERIOD := 0.28
const FIRE_ACTIVE_DIST := 72.0  # beyond this a firelight stops flickering
const SMOKE_ACTIVE_DIST := 150.0  # smoke reads from much further off than light

var map: WorldMap
var sky: SkySystem

var _shader: Shader
var _leaf_tex: Texture2D
var _rng := RandomNumberGenerator.new()

var _focus := Vector3.ZERO
var _ground := 0.0
var _eval_t := 0.0

var _pollen: GPUParticles3D
var _fireflies: GPUParticles3D
var _leaves: GPUParticles3D
var _gust: GPUParticles3D
var _mist: GPUParticles3D
var _rain: GPUParticles3D
var _splash: GPUParticles3D

var _pollen_mat: ShaderMaterial
var _mist_mat: ShaderMaterial
var _smoke_mat: ShaderMaterial
var _leaf_mat: ShaderMaterial

## World-space XZ footprints of every building standing in the valley, gathered once
## at setup. `_settle` uses them so a hearth is never lit inside somebody's hut.
var _solids: Array[Rect2] = []

var _firelights: Array[Node3D] = []
var _smokes: Array[GPUParticles3D] = []

var _shared: Dictionary = {}
var _river: Array[Vector2] = []
var _gust_timer := 7.0

var _rain_amount := 0.0
var _overcast_target := 0.0
var _drives_overcast := false


# =============================================================================
#  Firelight — an OmniLight3D whose flicker comes off a noise field rather than
#  randf() per frame. Naive per-frame randomness strobes; real fire wanders.
# =============================================================================
class Firelight:
	extends Node3D

	var light: OmniLight3D
	var flame: GPUParticles3D
	var embers: GPUParticles3D
	var base_energy := 3.2
	var intensity := 1.0
	var jitter := 0.09

	var _noise := FastNoiseLite.new()
	var _t := 0.0
	var _off := 0.0
	var _base_pos := Vector3(0.0, 0.62, 0.0)

	func configure(seed_value: int, energy: float) -> void:
		base_energy = energy
		_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
		_noise.seed = seed_value
		_noise.frequency = 1.0
		_noise.fractal_octaves = 3
		_noise.fractal_lacunarity = 2.4
		_off = float(seed_value % 977) * 0.31

	func _process(delta: float) -> void:
		_t += delta
		# Two rates layered: a fast one for the lick of the flame, a slow one for the
		# fire breathing up and down as the fuel shifts.
		var fast := _noise.get_noise_2d(_t * 5.6, _off)
		var slow := _noise.get_noise_2d(_t * 1.15, _off + 61.0)
		var f: float = clampf(0.80 + 0.36 * fast + 0.20 * slow, 0.30, 1.65)
		light.light_energy = base_energy * f
		light.position = _base_pos + Vector3(slow * jitter, fast * jitter * 0.5, fast * jitter)
		if flame:
			flame.speed_scale = 0.85 + 0.35 * f


# =============================================================================
#  Setup
# =============================================================================
func setup(world_map: WorldMap, sky_system: SkySystem) -> void:
	map = world_map
	sky = sky_system
	_rng.seed = 0x5646_5831  # "VFX1" - scatter must be identical every run
	_shader = load(SHADER_PATH)
	if _shader == null:
		push_error("[vfx] missing " + SHADER_PATH)
		return
	_leaf_tex = _leaf_atlas()
	_river = map.river_points()
	# Settlement is built and set up before this system in Game._spawn_content, so its
	# huts already exist and can be avoided.
	_gather_solids()

	_build_pollen()
	_build_fireflies()
	_build_leaves()
	_build_gust()
	_build_mist()
	_build_rain()
	_place_fires()

	_focus = map.ground(WorldMap.P_VILLAGE.x, WorldMap.P_VILLAGE.y)
	_ground = _focus.y
	_evaluate()


## Walk every follow-emitter to the player. Cheap: this only stores the position,
## the actual re-evaluation is throttled in `_process`.
func update_focus(pos: Vector3) -> void:
	_focus = pos
	_ground = map.height_at(pos.x, pos.z)


func _process(delta: float) -> void:
	_eval_t -= delta
	if _eval_t <= 0.0:
		_eval_t = EVAL_PERIOD
		_evaluate()

	_gust_timer -= delta
	if _gust_timer <= 0.0:
		_fire_gust()

	if _drives_overcast and sky:
		var prev := sky.overcast
		sky.overcast = move_toward(sky.overcast, _overcast_target, delta * 0.55)
		# `overcast` is only READ by SkySystem._apply, and _apply only runs from
		# SkySystem._process, which returns immediately while the sky is paused. Every
		# harness and every cutscene that freezes time therefore got rain out of a clear
		# blue sky. Push the value through ourselves when nobody else will.
		if sky.paused and absf(sky.overcast - prev) > 0.0004:
			sky.set_time(sky.time_of_day)
		if _overcast_target <= 0.0 and sky.overcast <= 0.0005:
			sky.overcast = 0.0
			if sky.paused:
				sky.set_time(sky.time_of_day)
			_drives_overcast = false


# =============================================================================
#  Shared builders
# =============================================================================
func _mat(cfg: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader
	for k in cfg:
		m.set_shader_parameter(k, cfg[k])
	return m


## Materials that every instance of a thing shares. Firelights and smoke columns are
## created one per hearth; without this the runtime tint update (which holds a single
## reference) reached only the last one built, and every other fire kept its daylight
## colour after dark.
func _shared_mat(key: String, cfg: Dictionary) -> ShaderMaterial:
	if _shared.has(key):
		return _shared[key]
	var m := _mat(cfg)
	_shared[key] = m
	return m


## A 2x2 atlas of four single leaves - ovate blade, midrib, petiole, four autumn
## tints. assets/textures/leaf_banyan.png is a canopy CLUSTER sheet: correct for a
## tree card, wrong for one leaf coming down, where it reads as a floating bush.
func _leaf_atlas() -> ImageTexture:
	var cell := 64
	var w := cell * 2
	var img := Image.create(w, w, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var tints := [
		Color(0.40, 0.50, 0.19),
		Color(0.74, 0.56, 0.17),
		Color(0.60, 0.33, 0.11),
		Color(0.31, 0.42, 0.17),
	]
	for ci in range(4):
		var ox: int = (ci % 2) * cell
		var oy: int = (ci >> 1) * cell
		var tint: Color = tints[ci]
		for py in range(cell):
			for px in range(cell):
				var u: float = (float(px) + 0.5) / float(cell) - 0.5
				var v: float = (float(py) + 0.5) / float(cell)
				var a := 0.0
				var col := tint
				var t: float = (v - 0.06) / 0.80
				if t >= 0.0 and t <= 1.0:
					# Half-width peaks below the middle: an ovate ficus blade.
					var hw: float = 0.335 * pow(sin(PI * pow(t, 0.72)), 0.85)
					var d: float = absf(u) / maxf(hw, 1e-4)
					a = clampf((1.0 - d) * 7.0, 0.0, 1.0)
					if a > 0.0:
						var rib: float = 1.0 - smoothstep(0.0, 0.085, absf(u))
						var vein: float = 0.5 + 0.5 * sin(t * 26.0 + absf(u) * 16.0)
						col = tint.lerp(tint.lightened(0.22), vein * 0.16)
						col = col.lerp(tint.darkened(0.40), rib * 0.55)
						col = col.lerp(tint.darkened(0.30), smoothstep(0.70, 1.0, d) * 0.7)
				elif v > 0.86 and absf(u) < 0.020:
					a = 1.0
					col = Color(0.44, 0.33, 0.19)
				if a > 0.0:
					img.set_pixel(ox + px, oy + py, Color(col.r, col.g, col.b, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _quad(w: float, h: float) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(w, h)
	return q


func _ramp(offsets: Array, colors: Array) -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	var t := GradientTexture1D.new()
	t.gradient = g
	t.width = 64
	return t


func _curve(points: Array, maxv: float = 1.0) -> CurveTexture:
	var c := Curve.new()
	c.min_value = 0.0
	c.max_value = maxv
	for p in points:
		c.add_point(Vector2(p[0], p[1]))
	var t := CurveTexture.new()
	t.curve = c
	t.width = 64
	return t


## Global particle budget. Measured 2026-08-28 on an M2 Max: the atmosphere layer cost
## ~10 ms/frame at full counts, which is a third of the frame for effects that read the
## same at half the density. Scaled by the quality tier via `density`.
static var density: float = 0.55


func _emitter(
	nm: String, amount: int, life: float, mesh: Mesh, mat: ShaderMaterial, proc: ParticleProcessMaterial, half: Vector3
) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = nm
	p.amount = maxi(4, int(round(float(amount) * density)))
	p.lifetime = life
	p.local_coords = false
	p.fixed_fps = 30
	p.interpolate = true
	p.draw_pass_1 = mesh
	p.material_override = mat
	p.process_material = proc
	# A real custom AABB. Without one Godot guesses from the mesh and the whole system
	# vanishes the moment the emitter node leaves the frustum.
	p.visibility_aabb = AABB(-half, half * 2.0)
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.emitting = false
	add_child(p)
	return p


func _proc() -> ParticleProcessMaterial:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.direction = Vector3(0.0, 1.0, 0.0)
	m.spread = 180.0
	m.gravity = Vector3.ZERO
	# A randomised spawn angle is what gives the shader its stable per-particle seed.
	m.angle_min = -180.0
	m.angle_max = 180.0
	return m


func _wind() -> Vector2:
	if sky == null:
		return Vector2(0.82, 0.57)
	return sky.wind_dir.normalized() * clampf(sky.wind_strength, 0.05, 2.0)


# =============================================================================
#  Pollen / dust motes — the warm daylight one
# =============================================================================
func _build_pollen() -> void:
	var w := _wind()
	var pm := _proc()
	# A 28 m box spreads 540 motes so thin that each one is individually resolvable,
	# which is what makes them read as dirt on the lens rather than as air. The same
	# count in a 18 m box is 3.7x the density for nothing.
	pm.emission_box_extents = Vector3(9.0, 4.5, 9.0)
	pm.initial_velocity_min = 0.06
	pm.initial_velocity_max = 0.30
	pm.gravity = Vector3(w.x * 0.22, 0.015, w.y * 0.22)
	pm.damping_min = 0.02
	pm.damping_max = 0.10
	pm.scale_min = 0.018
	pm.scale_max = 0.050
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.32
	pm.turbulence_noise_scale = 2.6
	pm.turbulence_noise_speed = Vector3(0.16, 0.06, 0.12)
	pm.turbulence_influence_min = 0.05
	pm.turbulence_influence_max = 0.30
	pm.lifetime_randomness = 0.45
	pm.color_ramp = _ramp([0.0, 0.16, 0.72, 1.0], [Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.85), Color(1, 1, 1, 0)])

	_pollen_mat = _mat(
		{
			"tint": Color(1.0, 0.90, 0.70, 0.46),
			# core 5.0 gave every mote a blown-out white centre - a star, not a speck of
			# drifting seed. softness up and core down turn it back into a soft mote.
			"brightness": 2.2,
			"additive": 1.0,
			"softness": 0.62,
			"core": 1.2,
			"soft_depth": 0.35,
			"near_fade": 3.0,
			"fade_start": 15.0,
			"fade_end": 27.0,
			"billboard_mode": 1,
		}
	)
	_pollen = _emitter("Pollen", 1500, 15.0, _quad(1.0, 1.0), _pollen_mat, pm, Vector3(20.0, 11.0, 20.0))
	_pollen.preprocess = 11.0


# =============================================================================
#  Fireflies — night, forest only
# =============================================================================
func _build_fireflies() -> void:
	var pm := _proc()
	# Tight to the player: a firefly 15 m away in a night forest is one pixel.
	pm.emission_box_extents = Vector3(9.5, 2.2, 9.5)
	pm.initial_velocity_min = 0.10
	pm.initial_velocity_max = 0.45
	pm.gravity = Vector3(0.0, 0.01, 0.0)
	pm.damping_min = 0.4
	pm.damping_max = 1.0
	pm.scale_min = 0.035
	pm.scale_max = 0.080
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.5
	pm.turbulence_noise_scale = 5.0
	pm.turbulence_noise_speed = Vector3(0.55, 0.30, 0.55)
	pm.turbulence_influence_min = 0.25
	pm.turbulence_influence_max = 0.85
	pm.lifetime_randomness = 0.50
	pm.color_ramp = _ramp([0.0, 0.10, 0.85, 1.0], [Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])

	var ffm := _mat(
		{
			"tint": Color(0.80, 1.0, 0.30, 1.0),
			"brightness": 5.2,
			"additive": 1.0,
			"softness": 0.72,
			"core": 5.0,
			# Fireflies drift through undergrowth, so the depth fade has the terrain right
			# behind them nearly all the time and was erasing most of the swarm.
			"soft_depth": 0.18,
			"soft_keep": 0.45,
			"near_fade": 1.3,
			"pulse_rate": 3.1,
			"pulse_depth": 0.78,
			"fade_start": 20.0,
			"fade_end": 36.0,
			"billboard_mode": 1,
		}
	)
	_fireflies = _emitter("Fireflies", 300, 11.0, _quad(1.0, 1.0), ffm, pm, Vector3(20.0, 9.0, 20.0))
	_fireflies.preprocess = 7.0


# =============================================================================
#  Falling leaves — tumbling, under canopy
# =============================================================================
func _build_leaves() -> void:
	var w := _wind()
	var pm := _proc()
	pm.emission_box_extents = Vector3(11.0, 2.2, 11.0)
	pm.direction = Vector3(0.0, -1.0, 0.0)
	pm.spread = 40.0
	pm.initial_velocity_min = 0.15
	pm.initial_velocity_max = 0.7
	pm.gravity = Vector3(w.x * 0.85, -0.75, w.y * 0.85)
	pm.damping_min = 0.35
	pm.damping_max = 0.9
	pm.scale_min = 0.60
	pm.scale_max = 1.15
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.1
	pm.turbulence_noise_scale = 3.2
	pm.turbulence_noise_speed = Vector3(0.35, 0.10, 0.35)
	pm.turbulence_influence_min = 0.2
	pm.turbulence_influence_max = 0.7
	pm.lifetime_randomness = 0.40
	pm.color_ramp = _ramp([0.0, 0.08, 0.86, 1.0], [Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])

	_leaf_mat = _mat(
		{
			"tint": Color(1.0, 0.97, 0.90, 1.0),
			"brightness": 1.0,
			"additive": 0.0,
			"alpha_cut": 0.34,
			"soft_depth": 0.20,
			"soft_keep": 0.25,
			"near_fade": 3.0,
			"fade_start": 26.0,
			"fade_end": 42.0,
			"billboard_mode": 0,
			"tumble": 2.1,
		}
	)
	if _leaf_tex:
		_leaf_mat.set_shader_parameter("sprite", _leaf_tex)
		_leaf_mat.set_shader_parameter("use_sprite", true)
		_leaf_mat.set_shader_parameter("atlas_cells", Vector2(2, 2))
	_leaves = _emitter("FallingLeaves", 150, 11.0, _quad(0.17, 0.17), _leaf_mat, pm, Vector3(24.0, 16.0, 24.0))
	_leaves.preprocess = 6.0


# =============================================================================
#  Wind gusts — an occasional sheet of dust and litter crossing open ground
# =============================================================================
func _build_gust() -> void:
	var pm := _proc()
	pm.emission_box_extents = Vector3(16.0, 0.9, 0.8)
	pm.direction = Vector3(0.0, 0.05, -1.0)
	pm.spread = 14.0
	pm.initial_velocity_min = 9.0
	pm.initial_velocity_max = 17.0
	pm.gravity = Vector3(0.0, -0.35, 0.0)
	pm.damping_min = 0.6
	pm.damping_max = 1.6
	pm.scale_min = 0.30
	pm.scale_max = 1.05
	pm.scale_curve = _curve([[0.0, 0.30], [0.35, 1.0], [1.0, 2.1]], 2.4)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 2.4
	pm.turbulence_noise_scale = 2.0
	pm.turbulence_noise_speed = Vector3(1.0, 0.4, 1.0)
	pm.turbulence_influence_min = 0.2
	pm.turbulence_influence_max = 0.8
	pm.color_ramp = _ramp([0.0, 0.13, 0.55, 1.0], [Color(1, 1, 1, 0), Color(1, 1, 1, 0.85), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])

	var gm := _mat(
		{
			"tint": Color(0.82, 0.70, 0.53, 0.13),
			"brightness": 1.0,
			"additive": 0.22,
			"softness": 1.0,
			"soft_depth": 1.4,
			"near_fade": 2.8,
			"fade_start": 55.0,
			"fade_end": 90.0,
			"billboard_mode": 1,
		}
	)
	# 1.5 m quads at a quarter opacity read as bokeh on the lens, not as grit in the
	# air. Half the size and half again the count: the eye reads DENSITY as wind.
	_gust = _emitter("WindGust", 760, 4.6, _quad(0.60, 0.60), gm, pm, Vector3(60.0, 20.0, 60.0))
	_gust.one_shot = true
	_gust.explosiveness = 0.72
	_gust.randomness = 0.5


func _fire_gust() -> void:
	_gust_timer = _rng.randf_range(9.0, 17.0)
	trigger_gust()


## Send a sheet of dust and litter across the ground on the wind, right now. Called on
## a timer by default; also the hook for a story beat that wants a gust on cue.
## Returns false when the spot cannot support one (canopy, downpour, pitch dark).
func trigger_gust() -> bool:
	if _rain_amount > 0.35 or sky == null or _gust == null:
		return false
	var p2 := Vector2(_focus.x, _focus.z)
	# Gusts belong on open ground; under a closed canopy you would never see one.
	if _forest_near(p2) > 0.60:
		return false
	if sky.light_level() < 0.06:
		return false
	var w := sky.wind_dir.normalized()
	var wv := Vector3(w.x, 0.0, w.y)
	var origin := _focus - wv * 26.0
	var gy := map.height_at(origin.x, origin.z)
	_gust.global_position = Vector3(origin.x, gy + 0.95, origin.z)
	_gust.global_basis = Basis.looking_at(wv, Vector3.UP)
	_gust.restart()
	_gust.emitting = true
	return true


# =============================================================================
#  River mist — low ribbons lying on the water at dawn and at night
# =============================================================================
func _build_mist() -> void:
	var pm := _proc()
	pm.emission_box_extents = Vector3(19.0, 0.22, 19.0)
	pm.initial_velocity_min = 0.05
	pm.initial_velocity_max = 0.35
	pm.gravity = Vector3(0.10, 0.012, 0.07)
	pm.damping_min = 0.05
	pm.damping_max = 0.2
	# 17 x 1.6 = a 27 m wide, 7 m tall quad. Sixty of those centred on the water line is
	# a wall, and it saturated to solid white. A bank of mist is many small ribbons.
	pm.scale_min = 3.6
	pm.scale_max = 8.5
	pm.scale_curve = _curve([[0.0, 0.45], [0.5, 1.0], [1.0, 1.35]], 1.5)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.28
	pm.turbulence_noise_scale = 1.1
	pm.turbulence_noise_speed = Vector3(0.05, 0.01, 0.05)
	pm.turbulence_influence_min = 0.05
	pm.turbulence_influence_max = 0.2
	pm.lifetime_randomness = 0.35
	pm.color_ramp = _ramp([0.0, 0.22, 0.72, 1.0], [Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.9), Color(1, 1, 1, 0)])

	_mist_mat = _mat(
		{
			"tint": Color(0.90, 0.92, 0.95, 0.115),
			"brightness": 1.0,
			"additive": 0.0,
			"softness": 1.0,
			"soft_depth": 1.2,
			"near_fade": 3.5,
			# billboard_mode 2 (cylindrical) instead of 1: the ribbon stays horizontal and
			# upright instead of being spun to a random screen angle. See `spin_amount` in
			# the shader - a spun 27 m x 7 m quad is what produced the white starbursts.
			"fade_start": 110.0,
			"fade_end": 175.0,
			"billboard_mode": 2,
			"spin_amount": 0.0,
		}
	)
	# Wide and shallow: a ribbon lying on the water, not a ball of cotton.
	_mist = _emitter("RiverMist", 280, 34.0, _quad(1.0, 0.30), _mist_mat, pm, Vector3(46.0, 12.0, 46.0))
	_mist.preprocess = 22.0
	_mist.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH


# =============================================================================
#  Rain
# =============================================================================
func _build_rain() -> void:
	var pm := _proc()
	# 26 m square spread ~1200 drops over 13,000 cubic metres, which is one drop per
	# eleven cubic metres - individually countable. The material fades out at 27 m
	# anyway, so a 15 m box wastes nothing and is 3x denser where it is looked at.
	pm.emission_box_extents = Vector3(7.5, 1.0, 7.5)
	pm.direction = Vector3(0.0, -1.0, 0.0)
	pm.spread = 3.0
	pm.initial_velocity_min = 14.0
	pm.initial_velocity_max = 19.0
	pm.gravity = Vector3(4.2, -22.0, 2.9)
	pm.scale_min = 0.70
	pm.scale_max = 1.75
	pm.color_ramp = _ramp([0.0, 0.1, 1.0], [Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1)])

	var rm := _mat(
		{
			"tint": Color(0.82, 0.88, 0.96, 0.26),
			"brightness": 1.05,
			"additive": 0.72,
			"softness": 1.0,
			# soft_depth 0.6 with no floor is why the first pass had rain that visibly
			# dissolved a metre above the grass and never touched anything.
			"soft_depth": 0.10,
			"soft_keep": 0.80,
			"near_fade": 2.6,
			"fade_start": 26.0,
			"fade_end": 46.0,
			"billboard_mode": 0,
		}
	)
	_rain = _emitter("Rain", 3400, 0.80, _quad(0.011, 0.50), rm, pm, Vector3(30.0, 26.0, 30.0))
	_rain.preprocess = 1.0
	# Streaks must lie along the fall direction and still face the camera.
	_rain.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY

	var sp := _proc()
	sp.emission_box_extents = Vector3(7.0, 0.22, 7.0)
	sp.direction = Vector3(0.0, 1.0, 0.0)
	sp.spread = 22.0
	sp.initial_velocity_min = 1.0
	sp.initial_velocity_max = 2.3
	sp.gravity = Vector3(0.0, -12.0, 0.0)
	sp.scale_min = 0.75
	sp.scale_max = 1.9
	sp.scale_curve = _curve([[0.0, 1.0], [0.45, 0.8], [1.0, 0.1]], 1.0)
	sp.color_ramp = _ramp([0.0, 0.2, 1.0], [Color(1, 1, 1, 0.9), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0)])

	var sm := _mat(
		{
			"tint": Color(0.90, 0.94, 0.99, 0.8),
			"brightness": 2.1,
			"additive": 0.6,
			"softness": 0.8,
			# A splash lives 8 cm above the ground it is splashing off, so the depth fade
			# had it at zero alpha from every angle. This is why no splash was ever visible.
			"soft_depth": 0.05,
			"soft_keep": 0.92,
			"near_fade": 1.1,
			"fade_start": 16.0,
			"fade_end": 28.0,
			"billboard_mode": 2,
		}
	)
	# A narrow upright quad: the round falloff becomes a droplet tick, not a bubble.
	_splash = _emitter("RainSplash", 640, 0.34, _quad(0.030, 0.20), sm, sp, Vector3(24.0, 6.0, 24.0))


## 0 = clear, 1 = downpour. Also asks the sky to thicken its cloud and fog to match,
## because rain with a clear blue sky above it reads as a bug.
func set_rain(amount: float) -> void:
	var a := clampf(amount, 0.0, 1.0)
	var was_on := _rain_amount > 0.02
	_rain_amount = a
	var on := a > 0.02
	if _rain and _splash:
		_rain.amount_ratio = maxf(a, 0.02)
		_splash.amount_ratio = maxf(a * 0.9, 0.02)
		if on and not was_on:
			_rain.restart()
			_rain.emitting = true
			_splash.restart()
			_splash.emitting = true
		elif not on:
			_rain.emitting = false
			_splash.emitting = false
	_drives_overcast = true
	_overcast_target = (0.18 + a * 0.72) if on else 0.0


func rain_amount() -> float:
	return _rain_amount


# =============================================================================
#  Firelight — reusable. Hand it to a firepit, a torch or an oil lamp.
# =============================================================================
## Returns a self-contained flickering fire: light, flame, embers. Reparent it
## anywhere; it registers itself so distant fires stop costing anything.
## `intensity` scales light, flame size and ember count together (0.18 for a diya,
## 1.0 for a cooking fire, 1.6 for a bonfire).
func make_firelight(intensity: float = 1.0, light_range: float = 9.0) -> Node3D:
	var fl := Firelight.new()
	fl.name = "Firelight"
	var s: float = maxf(intensity, 0.05)

	var lamp := OmniLight3D.new()
	lamp.name = "Light"
	lamp.light_color = Color(1.0, 0.55, 0.21)
	lamp.omni_range = light_range * (0.85 + 0.55 * s)
	lamp.omni_attenuation = 0.95
	lamp.light_energy = 3.2 * s
	lamp.light_specular = 0.35
	lamp.shadow_enabled = false
	lamp.position = Vector3(0.0, 0.62 * sqrt(s), 0.0)
	fl.add_child(lamp)
	fl.light = lamp
	fl._base_pos = lamp.position
	fl.jitter = 0.09 * s

	# --- flame ---------------------------------------------------------------
	var fm := _proc()
	fm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	fm.emission_sphere_radius = 0.14 * s
	fm.direction = Vector3(0.0, 1.0, 0.0)
	fm.spread = 14.0
	fm.initial_velocity_min = 0.55 * s
	fm.initial_velocity_max = 1.5 * s
	fm.gravity = Vector3(0.0, 1.15 * s, 0.0)
	fm.damping_min = 0.5
	fm.damping_max = 1.4
	fm.scale_min = 0.55 * s
	fm.scale_max = 1.15 * s
	fm.scale_curve = _curve([[0.0, 0.45], [0.28, 1.0], [1.0, 0.12]], 1.0)
	fm.lifetime_randomness = 0.40
	fm.color_ramp = _ramp(
		[0.0, 0.16, 0.55, 1.0],
		[Color(1.00, 0.92, 0.55, 0.0), Color(1.00, 0.80, 0.34, 1.0), Color(1.00, 0.42, 0.11, 0.85), Color(0.55, 0.13, 0.03, 0.0)]
	)

	var flame_mat := _shared_mat(
		"flame",
		{
			"tint": Color(1.0, 0.72, 0.36, 1.0),
			"brightness": 2.1,
			"additive": 1.0,
			"softness": 0.85,
			"core": 0.8,
			"soft_depth": 0.28,
			"near_fade": 0.5,
			"fade_start": 60.0,
			"fade_end": 95.0,
			"billboard_mode": 1,
		}
	)
	var flame := GPUParticles3D.new()
	flame.name = "Flame"
	flame.amount = maxi(8, int(44.0 * clampf(s, 0.35, 2.0) * density))
	flame.lifetime = 0.9
	flame.local_coords = false
	flame.fixed_fps = 30
	flame.interpolate = true
	flame.preprocess = 1.0
	flame.draw_pass_1 = _quad(0.34 * s, 0.44 * s)
	flame.material_override = flame_mat
	flame.process_material = fm
	flame.visibility_aabb = AABB(Vector3(-2, -0.5, -2) * s, Vector3(4, 6, 4) * s)
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flame.position = Vector3(0.0, 0.12 * s, 0.0)
	fl.add_child(flame)
	fl.flame = flame

	# --- embers --------------------------------------------------------------
	var em := _proc()
	em.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	em.emission_sphere_radius = 0.20 * s
	em.direction = Vector3(0.0, 1.0, 0.0)
	em.spread = 26.0
	em.initial_velocity_min = 1.1 * s
	em.initial_velocity_max = 2.6 * s
	var w := _wind()
	em.gravity = Vector3(w.x * 0.55, 1.35 * s, w.y * 0.55)
	em.damping_min = 0.25
	em.damping_max = 0.8
	em.scale_min = 0.4 * s
	em.scale_max = 0.95 * s
	em.turbulence_enabled = true
	em.turbulence_noise_strength = 1.6
	em.turbulence_noise_scale = 3.0
	em.turbulence_noise_speed = Vector3(0.5, 0.25, 0.5)
	em.turbulence_influence_min = 0.2
	em.turbulence_influence_max = 0.75
	em.lifetime_randomness = 0.55
	em.color_ramp = _ramp(
		[0.0, 0.12, 0.6, 1.0],
		[Color(1.0, 0.85, 0.45, 0.0), Color(1.0, 0.62, 0.22, 1.0), Color(1.0, 0.32, 0.07, 0.7), Color(0.6, 0.12, 0.02, 0.0)]
	)

	var ember_mat := _shared_mat(
		"ember",
		{
			"tint": Color(1.0, 0.72, 0.34, 1.0),
			"brightness": 5.0,
			"additive": 1.0,
			"softness": 0.25,
			"core": 3.5,
			"soft_depth": 0.25,
			"near_fade": 0.5,
			"pulse_rate": 6.5,
			"pulse_depth": 0.55,
			"fade_start": 55.0,
			"fade_end": 90.0,
			"billboard_mode": 1,
		}
	)
	var embers := GPUParticles3D.new()
	embers.name = "Embers"
	embers.amount = maxi(6, int(37.0 * clampf(s, 0.35, 2.0) * density))
	embers.lifetime = 2.8
	embers.local_coords = false
	embers.fixed_fps = 30
	embers.interpolate = true
	embers.preprocess = 2.0
	embers.draw_pass_1 = _quad(0.055, 0.055)
	embers.material_override = ember_mat
	embers.process_material = em
	embers.visibility_aabb = AABB(Vector3(-8, -1, -8), Vector3(16, 16, 16))
	embers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	embers.position = Vector3(0.0, 0.2 * s, 0.0)
	fl.add_child(embers)
	fl.embers = embers

	flame.emitting = true
	embers.emitting = true
	fl.intensity = s
	fl.configure(_rng.randi(), 3.2 * s)
	_firelights.append(fl)
	return fl


## Column of cookfire smoke, wind-drifted. Returned unparented so a village can put
## it exactly on its own hearth; `setup` uses it for the fires it places itself.
func make_smoke(scale_v: float = 1.0) -> GPUParticles3D:
	var w := _wind()
	var pm := _proc()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.22 * scale_v
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 10.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.2
	pm.gravity = Vector3(w.x * 1.5, 0.85, w.y * 1.5)
	pm.damping_min = 0.05
	pm.damping_max = 0.25
	pm.scale_min = 0.35 * scale_v
	pm.scale_max = 0.80 * scale_v
	pm.scale_curve = _curve([[0.0, 0.35], [0.4, 1.2], [1.0, 2.4]], 3.0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.65
	pm.turbulence_noise_scale = 1.6
	pm.turbulence_noise_speed = Vector3(0.22, 0.08, 0.22)
	pm.turbulence_influence_min = 0.1
	pm.turbulence_influence_max = 0.45
	pm.lifetime_randomness = 0.35
	pm.color_ramp = _ramp(
		[0.0, 0.12, 0.45, 1.0],
		[Color(0.60, 0.48, 0.38, 0.0), Color(0.78, 0.72, 0.66, 1.0), Color(0.92, 0.90, 0.88, 0.55), Color(1.0, 1.0, 1.0, 0.0)]
	)

	# The tint is re-driven from the sky every evaluation - unshaded smoke that keeps
	# its daylight colour after dark is the loudest possible "these are sprites" tell.
	_smoke_mat = _shared_mat(
		"smoke",
		{
			"tint": Color(0.80, 0.78, 0.74, 0.20),
			"brightness": 1.0,
			"additive": 0.0,
			"softness": 1.0,
			"soft_depth": 1.3,
			"near_fade": 1.6,
			"fade_start": 150.0,
			"fade_end": 230.0,
			"billboard_mode": 1,
		}
	)
	var sm := GPUParticles3D.new()
	sm.name = "Smoke"
	sm.amount = maxi(14, int(92.0 * density))
	sm.lifetime = 9.5
	sm.local_coords = false
	sm.fixed_fps = 24
	sm.interpolate = true
	sm.preprocess = 8.0
	sm.draw_pass_1 = _quad(0.62 * scale_v, 0.62 * scale_v)
	sm.material_override = _smoke_mat
	sm.process_material = pm
	sm.visibility_aabb = AABB(Vector3(-24, -2, -24), Vector3(48, 40, 48))
	sm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sm.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	sm.emitting = true
	_smokes.append(sm)
	return sm


# =============================================================================
#  Fixed fires: village hearths, the forest camp, shrine lamps
# =============================================================================
func _place_fires() -> void:
	# Village cookfires, ringed round the settlement centre on flat, dry ground.
	for i in range(4):
		var ang: float = TAU * (float(i) / 4.0) + 0.62
		var r: float = 11.0 + float(i % 2) * 5.5
		var p := WorldMap.P_VILLAGE + Vector2(cos(ang), sin(ang)) * r
		p = _settle(p, 10.0)
		_add_fire(p, 1.0 if i == 0 else 0.72, 10.0)

	_add_fire(_settle(WorldMap.P_FOREST_CAMP + Vector2(2.5, -1.5), 6.0), 1.25, 12.0)
	_add_fire(_settle(WorldMap.P_FORD + Vector2(9.0, 11.0), 6.0), 0.55, 7.0)

	# Oil lamps at the shrine: no smoke, tiny pools of light.
	for i in range(4):
		var a: float = TAU * (float(i) / 4.0) + 0.4
		# The 3.4 m ring put one lamp inside the shrine itself; settle them out.
		var p := _settle(WorldMap.P_SHRINE + Vector2(cos(a), sin(a)) * 5.2, 4.0)
		var fl := make_firelight(0.16, 4.0)
		var g := map.height_at(p.x, p.y)
		fl.position = Vector3(p.x, g + 0.85, p.y)
		add_child(fl)


func _add_fire(p: Vector2, intensity: float, light_range: float) -> void:
	var g := map.height_at(p.x, p.y)
	var fl := make_firelight(intensity, light_range)
	fl.position = Vector3(p.x, g + 0.10, p.y)
	add_child(fl)
	var sm := make_smoke(clampf(intensity, 0.6, 1.4))
	sm.position = Vector3(p.x, g + 0.75, p.y)
	add_child(sm)


## Nudge a point to the flattest dry spot within `r` metres that is NOT inside a
## building. Fires on a 30-degree slope, or in the river, look like a placement bug
## even when they are not - and a hearth inside a hut is invisible from outside AND
## puts an omni light inside somebody's walls. Measured 2026-08-28: on the fixed ring
## this used to place, two of the ten fires (one village cookfire, one shrine lamp)
## landed inside settlement geometry.
func _settle(p: Vector2, r: float) -> Vector2:
	var best := p
	var best_score := -1e9
	for i in range(18):
		var a: float = TAU * float(i) / 18.0
		for k in [0.0, 0.34, 0.62, 0.85, 1.0]:
			var q: float = float(k)
			var c := p + Vector2(cos(a), sin(a)) * r * q
			if not map.in_bounds(c.x, c.y):
				continue
			var score := -map.slope_at(c.x, c.y) * 6.0 - map.wet_at(c.x, c.y) * 3.0
			score -= q * 0.35
			if map.water_depth_at(c.x, c.y) > 0.02:
				score -= 20.0
			score -= _solid_penalty(c)
			if score > best_score:
				best_score = score
				best = c
	return best


## How badly `c` collides with a building: heavy inside, tapering to nothing at 1.6 m.
func _solid_penalty(c: Vector2) -> float:
	var worst := 0.0
	for rect in _solids:
		if rect.has_point(c):
			return 60.0
		if rect.grow(1.6).has_point(c):
			worst = maxf(worst, 22.0)
	return worst


## XZ footprints of everything building-shaped that a sibling system has put in the
## world. Deliberately duck-typed on geometry rather than on `Settlement`, because
## Game builds content systems optionally and this one must not require any of them.
func _gather_solids() -> void:
	_solids.clear()
	var parent := get_parent()
	if parent == null:
		return
	for sib in parent.get_children():
		if sib == self:
			continue
		_scan_solids(sib, 0)


func _scan_solids(n: Node, depth: int) -> void:
	if depth > 7:
		return
	var mi := n as MeshInstance3D
	# MultiMeshInstance3D is skipped on purpose: one AABB round a whole scattered
	# forest would exclude every clearing in the valley.
	if mi and mi.mesh and mi.is_inside_tree():
		var a: AABB = mi.global_transform * mi.mesh.get_aabb()
		# Hut-shaped: big enough to stand in, small enough not to be terrain or a
		# canopy, tall enough not to be a doorstep.
		if a.size.x > 2.0 and a.size.z > 2.0 and a.size.x < 34.0 and a.size.z < 34.0 and a.size.y > 1.4 and a.size.y < 17.0:
			_solids.append(Rect2(a.position.x, a.position.z, a.size.x, a.size.z))
	for c in n.get_children():
		_scan_solids(c, depth + 1)


# =============================================================================
#  The throttled state evaluation
# =============================================================================
func _evaluate() -> void:
	if map == null or not is_inside_tree():
		# setup() legitimately runs before the tree is live (a --script harness builds
		# the world inside SceneTree._init); global_position is meaningless until then.
		return
	var p2 := Vector2(_focus.x, _focus.z)
	var lit: float = sky.light_level() if sky else 1.0
	var night: bool = sky.is_night() if sky else false
	var phase: String = sky.phase() if sky else "day"
	# Sample a NEIGHBOURHOOD, not the point. Every named place in this world sits on a
	# path or in a clearing, where forest_density reads 0.000 even with trees fifteen
	# metres away - and fireflies drift out of the trees onto the path, they do not
	# stop at the treeline. Measured 2026-08-28: forest_density(P_FOREST_CAMP) = 0.000.
	var fd: float = _forest_near(p2)
	var rain_off: bool = _rain_amount < 0.35

	# Smoke and mist are unshaded, so their tint IS their lighting. Re-derive it from
	# the time of day, plus a warm underlight at night from the fire below.
	if _smoke_mat:
		# Driving the night value all the way down to 0.12 made the column DARKER than
		# the night sky behind it, so four village hearths produced no smoke at all
		# after dusk. Real cookfire smoke is underlit by the fire it comes off.
		var sc := Color(0.30, 0.26, 0.25).lerp(Color(0.84, 0.82, 0.78), lit)
		sc = sc.lerp(Color(0.72, 0.44, 0.24), (1.0 - lit) * 0.42)
		sc.a = lerpf(0.20, 0.22, lit)
		_smoke_mat.set_shader_parameter("tint", sc)

	# --- pollen: warm daylight, no rain, over ground that grows something ----
	# Motes drifting over midstream water or bare rock read as dirt on the lens, which
	# is exactly the failure this whole layer is trying to avoid.
	var bio: int = map.biome_at(_focus.x, _focus.z)
	var barren: bool = bio == WorldMap.Biome.ROCK or bio == WorldMap.Biome.MOUNTAIN or bio == WorldMap.Biome.RIVERBED
	# lit > 0.22 put pollen in the frame at six in the morning over open water, where
	# a handful of bright specks is indistinguishable from dirt on the lens. Pollen is
	# a thing that happens in a sunbeam.
	# Also: not standing on a riverbank. The emitter box reaches 9 m, so motes over the
	# channel are the ones that read as dirt on the lens no matter how they are tuned.
	var pollen_on: bool = (
		lit > 0.55 and rain_off and not barren and map.water_depth_at(_focus.x, _focus.z) < 0.25 and map.wet_at(_focus.x, _focus.z) < 0.55
	)
	if _pollen_mat:
		_pollen_mat.set_shader_parameter("brightness", 0.8 + 1.55 * lit)
	_toggle(_pollen, pollen_on, Vector3(_focus.x, _ground + 2.6, _focus.z))

	# --- fireflies: night, under trees --------------------------------------
	var ff_on: bool = night and fd > 0.12 and _rain_amount < 0.30
	if _fireflies:
		_fireflies.amount_ratio = clampf(0.35 + fd, 0.1, 1.0)
	_toggle(_fireflies, ff_on, Vector3(_focus.x, _ground + 1.05, _focus.z))

	# --- leaves: wherever there is canopy overhead --------------------------
	# Unshaded, like the smoke and the mist, so the tint has to be re-driven from the
	# time of day or a night forest fills with leaves lit for a summer noon. This was
	# missed on the first pass and the ruins-at-night shot was full of glowing foliage.
	if _leaf_mat:
		var lc := Color(0.13, 0.15, 0.13).lerp(Color(1.0, 0.97, 0.90), clampf(0.06 + lit * 1.05, 0.0, 1.0))
		_leaf_mat.set_shader_parameter("tint", lc)
	var leaf_on: bool = fd > 0.38
	if _leaves:
		_leaves.amount_ratio = clampf((fd - 0.30) * 1.6, 0.12, 1.0)
	_toggle(_leaves, leaf_on, Vector3(_focus.x, _ground + 8.0, _focus.z))

	# --- river mist: dawn and night, close to water -------------------------
	var mist_on: bool = (night or phase == "dawn" or phase == "twilight") and _river.size() > 0
	if mist_on:
		var rp := _nearest_river(p2)
		if p2.distance_to(rp) > 85.0:
			mist_on = false
		else:
			var wy := map.water_y_at(rp.x, rp.y)
			if _mist_mat:
				# Dawn mist is lit warm off the low sun; night mist is cold and thinner.
				var warm: float = clampf(lit * 2.5, 0.0, 1.0)
				var mc := Color(0.20, 0.24, 0.34).lerp(Color(1.0, 0.92, 0.80), warm)
				mc.a = lerpf(0.040, 0.068, warm)
				_mist_mat.set_shader_parameter("tint", mc)
			_toggle(_mist, true, Vector3(rp.x, wy + 0.45, rp.y))
	if not mist_on:
		_toggle(_mist, false, Vector3.ZERO)

	# --- rain rig follows the focus -----------------------------------------
	if _rain and _rain_amount > 0.02:
		_rain.global_position = Vector3(_focus.x, _ground + 13.0, _focus.z)
		_splash.global_position = Vector3(_focus.x, _ground + 0.08, _focus.z)

	# --- distance-cull the fixed fires --------------------------------------
	for i in range(_firelights.size() - 1, -1, -1):
		var fl := _firelights[i]
		if not is_instance_valid(fl):
			_firelights.remove_at(i)
			continue
		var d := fl.global_position.distance_to(_focus)
		var near := d < FIRE_ACTIVE_DIST
		fl.set_process(near)
		fl.visible = d < FIRE_ACTIVE_DIST * 1.6
		var f := fl as Firelight
		if f and f.flame:
			f.flame.emitting = near
			f.embers.emitting = near
			# Fires read hot at night and washed out at noon.
			f.base_energy = 3.2 * f.intensity * lerpf(1.0, 0.32, lit)

	for i in range(_smokes.size() - 1, -1, -1):
		var sm := _smokes[i]
		if not is_instance_valid(sm):
			_smokes.remove_at(i)
			continue
		sm.emitting = sm.global_position.distance_to(_focus) < SMOKE_ACTIVE_DIST


func _toggle(e: GPUParticles3D, on: bool, at: Vector3) -> void:
	if e == null:
		return
	if on:
		if not e.emitting:
			e.global_position = at
			e.restart()
			e.emitting = true
			return
		var d := e.global_position.distance_to(at)
		if d > 25.0:
			# Teleport (fast travel, a cut, a big camera move): refill in place, or the
			# emitter trails a comet of stale particles across the valley behind it.
			e.global_position = at
			e.restart()
		elif d > 7.0:
			e.global_position = at
	else:
		e.emitting = false


## Strongest forest within ~16 m. See the note at the call site.
func _forest_near(p: Vector2) -> float:
	var best: float = map.forest_density(p)
	for i in range(6):
		var a: float = TAU * float(i) / 6.0
		best = maxf(best, map.forest_density(p + Vector2(cos(a), sin(a)) * 16.0))
	return best


func _nearest_river(p: Vector2) -> Vector2:
	var best := p
	var bd := 1e18
	for q in _river:
		var d: float = p.distance_squared_to(q)
		if d < bd:
			bd = d
			best = q
	return best
