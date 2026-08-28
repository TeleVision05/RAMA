class_name SkySystem
extends Node3D
## Day/night cycle: sun, moon, sky, ambient, fog and colour grading all driven from a
## single time-of-day so they can never disagree with each other.
##
## Night is deliberately NOT "blue daytime": the key light swaps to a dim, cool moon
## with much softer shadows, ambient collapses, fog thickens and cools, exposure lifts,
## and saturation drops the way night vision actually behaves.

signal phase_changed(phase: String)

const DAY_LENGTH_SECONDS: float = 900.0  # 15 real minutes per in-game day

@export var time_of_day: float = 7.4  # hours, 0..24
@export var paused: bool = false
@export var time_scale: float = 1.0

var sun: DirectionalLight3D
var moon: DirectionalLight3D
var env: WorldEnvironment
var _sky_mat: ShaderMaterial
var _phase: String = ""

# Weather, kept lightweight: one 0..1 dial that thickens cloud and fog together.
var overcast: float = 0.0
var wind_strength: float = 0.45
var wind_dir: Vector2 = Vector2(0.82, 0.57)


func _ready() -> void:
	add_to_group("sky")
	_build()
	_apply(true)


func _build() -> void:
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 175.0
	sun.directional_shadow_split_1 = 0.045
	sun.directional_shadow_split_2 = 0.14
	sun.directional_shadow_split_3 = 0.38
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.035
	sun.shadow_normal_bias = 1.4
	sun.light_angular_distance = 0.55
	add_child(sun)

	moon = DirectionalLight3D.new()
	moon.name = "Moon"
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 130.0
	moon.shadow_bias = 0.05
	moon.light_angular_distance = 1.6
	add_child(moon)

	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = load("res://shaders/sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	sky.radiance_size = Sky.RADIANCE_SIZE_256

	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_white = 8.0
	e.ssao_enabled = true
	e.ssao_radius = 1.6
	e.ssao_intensity = 2.6
	e.ssao_detail = 0.4
	e.ssao_power = 1.7
	# SSIL measured at roughly 8 ms/frame on an M2 Max for an effect that is nearly
	# invisible in daylight. Off by default; the ULTRA quality tier turns it back on.
	e.ssil_enabled = false
	e.ssil_radius = 4.0
	e.ssil_intensity = 0.45
	e.ssil_normal_rejection = 0.9
	e.glow_enabled = true
	e.glow_intensity = 0.42
	e.glow_strength = 1.0
	e.glow_bloom = 0.06
	e.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	e.glow_hdr_threshold = 1.05
	e.glow_hdr_scale = 2.2
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_DEPTH
	e.fog_depth_begin = 120.0
	e.fog_depth_end = 2100.0
	e.fog_depth_curve = 3.2
	e.fog_sky_affect = 0.06
	e.fog_aerial_perspective = 0.12
	e.volumetric_fog_enabled = true
	e.volumetric_fog_density = 0.004
	e.volumetric_fog_length = 120.0
	e.volumetric_fog_gi_inject = 0.6
	e.volumetric_fog_anisotropy = 0.45
	e.adjustment_enabled = true
	e.adjustment_brightness = 1.0
	e.adjustment_contrast = 1.06
	e.adjustment_saturation = 1.07

	env = WorldEnvironment.new()
	env.name = "WorldEnvironment"
	env.environment = e
	add_child(env)

	var ca := CameraAttributesPractical.new()
	ca.auto_exposure_enabled = false
	ca.dof_blur_far_enabled = false
	env.camera_attributes = ca


func _process(delta: float) -> void:
	if paused:
		return
	time_of_day = fposmod(time_of_day + delta * (24.0 / DAY_LENGTH_SECONDS) * time_scale, 24.0)
	_apply(false)


func set_time(h: float) -> void:
	time_of_day = fposmod(h, 24.0)
	_apply(true)


## Sun direction for a given hour. Rises in the east (+X), sets in the west.
static func sun_direction(hour: float) -> Vector3:
	var a: float = (hour - 6.0) / 12.0 * PI
	return Vector3(cos(a), sin(a), -0.30).normalized()


func _apply(_force: bool) -> void:
	var sd := sun_direction(time_of_day)
	var md := sun_direction(fposmod(time_of_day + 12.6, 24.0))
	md = Vector3(md.x, md.y, 0.34).normalized()

	# Lights point ALONG -Z, so the node looks from the sun toward the ground.
	if sd.y > -0.999:
		sun.look_at_from_position(Vector3.ZERO, -sd, Vector3.UP)
	if md.y > -0.999:
		moon.look_at_from_position(Vector3.ZERO, -md, Vector3.UP)

	var elev := sd.y
	var night: float = 1.0 - smoothstep(-0.16, 0.06, elev)
	var golden: float = smoothstep(-0.06, 0.12, elev) * (1.0 - smoothstep(0.14, 0.34, elev))

	# --- key light --------------------------------------------------------
	var sun_col := Color(1.0, 0.36, 0.14).lerp(Color(1.0, 0.72, 0.44), smoothstep(-0.05, 0.10, elev))
	sun_col = sun_col.lerp(Color(1.0, 0.955, 0.90), smoothstep(0.10, 0.42, elev))
	sun.light_color = sun_col
	sun.light_energy = smoothstep(-0.09, 0.16, elev) * lerpf(2.3, 1.35, overcast)
	sun.visible = sun.light_energy > 0.005
	sun.light_angular_distance = lerpf(2.2, 0.5, smoothstep(0.0, 0.3, elev)) + overcast * 3.0

	moon.light_color = Color(0.60, 0.70, 1.0)
	moon.light_energy = night * 0.42 * (1.0 - overcast * 0.6)
	moon.visible = moon.light_energy > 0.004 and md.y > -0.05

	# --- environment ------------------------------------------------------
	var e := env.environment
	e.ambient_light_energy = lerpf(0.62, 0.22, night) * lerpf(1.0, 0.8, overcast)
	e.ambient_light_sky_contribution = 1.0
	e.background_energy_multiplier = lerpf(1.0, 1.05, night)

	# Night must not read as dim blue day: drop saturation, lift contrast, cool it.
	e.adjustment_saturation = lerpf(1.10, 0.62, night)
	e.adjustment_contrast = lerpf(1.06, 1.16, night)
	e.adjustment_brightness = lerpf(1.0, 1.06, night)
	e.tonemap_exposure = lerpf(1.0, 2.0, night)

	var fog_day := Color(0.72, 0.76, 0.80)
	var fog_gold := Color(0.96, 0.66, 0.40)
	var fog_night := Color(0.055, 0.075, 0.135)
	var fc := fog_day.lerp(fog_gold, golden * 0.85)
	fc = fc.lerp(fog_night, night)
	e.fog_light_color = fc
	e.fog_light_energy = lerpf(1.0, 0.5, night)
	e.fog_density = lerpf(0.0006, 0.0022, night) + overcast * 0.0018
	e.fog_sun_scatter = lerpf(0.30, 0.02, night)
	e.volumetric_fog_albedo = fc.lerp(Color(1, 1, 1), 0.35)
	e.volumetric_fog_emission = fc * lerpf(0.010, 0.0016, 1.0 - night)
	e.volumetric_fog_density = lerpf(0.0022, 0.0075, night) + overcast * 0.004
	e.glow_intensity = lerpf(0.40, 0.72, night)

	# --- sky --------------------------------------------------------------
	_sky_mat.set_shader_parameter("sun_dir", sd)
	_sky_mat.set_shader_parameter("moon_dir", md)
	_sky_mat.set_shader_parameter("sun_elev", elev)
	_sky_mat.set_shader_parameter("night", night)
	_sky_mat.set_shader_parameter("star_intensity", 1.35)
	_sky_mat.set_shader_parameter("cloud_cover", clampf(0.34 + overcast * 0.55, 0.0, 1.0))
	_sky_mat.set_shader_parameter("haze", lerpf(0.38, 0.16, night) + overcast * 0.2)
	_sky_mat.set_shader_parameter("haze_color", Color(0.86, 0.80, 0.68).lerp(Color(1.0, 0.60, 0.34), golden))

	var ph := phase()
	if ph != _phase:
		_phase = ph
		phase_changed.emit(ph)


func phase() -> String:
	if time_of_day < 5.0 or time_of_day >= 20.4:
		return "night"
	if time_of_day < 7.2:
		return "dawn"
	if time_of_day < 17.0:
		return "day"
	if time_of_day < 19.0:
		return "dusk"
	return "twilight"


func is_night() -> bool:
	var p := phase()
	return p == "night" or p == "twilight"


func light_level() -> float:
	return clampf(smoothstep(-0.16, 0.10, sun_direction(time_of_day).y), 0.0, 1.0)
