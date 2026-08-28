class_name Quality
extends RefCounted
## Graphics quality tiers, applied to the viewport, the environment and the sun.
##
## Measured on an M2 Max at 1600x900 (2026-08-28): the default settings cost about
## 21 ms/frame in post alone — SSIL, 4x MSAA and a 140 m volumetric fog volume — for
## effects that are barely visible in an outdoor daylight scene. LOW/MEDIUM turn the
## expensive ones off; HIGH keeps them for screenshots and cinematics.

enum Tier { LOW, MEDIUM, HIGH, ULTRA }

const NAMES := ["Low", "Medium", "High", "Ultra"]


static func apply(tier: int, vp: Viewport, sky: SkySystem) -> void:
	tier = clampi(tier, 0, 3)
	var e: Environment = sky.env.environment
	var sun: DirectionalLight3D = sky.sun

	match tier:
		Tier.LOW:
			vp.msaa_3d = Viewport.MSAA_DISABLED
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			vp.scaling_3d_scale = 0.80
			e.ssao_enabled = false
			e.ssil_enabled = false
			e.volumetric_fog_enabled = false
			e.glow_enabled = true
			sun.directional_shadow_max_distance = 90.0
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		Tier.MEDIUM:
			vp.msaa_3d = Viewport.MSAA_2X
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			vp.scaling_3d_scale = 1.0
			e.ssao_enabled = true
			e.ssao_detail = 0.2
			e.ssao_power = 1.4
			e.ssil_enabled = false
			e.volumetric_fog_enabled = true
			e.volumetric_fog_length = 84.0
			e.glow_enabled = true
			sun.directional_shadow_max_distance = 150.0
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		Tier.HIGH:
			vp.msaa_3d = Viewport.MSAA_2X
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			vp.scaling_3d_scale = 1.0
			e.ssao_enabled = true
			e.ssao_detail = 0.5
			e.ssao_power = 1.7
			e.ssil_enabled = false
			e.volumetric_fog_enabled = true
			e.volumetric_fog_length = 130.0
			e.glow_enabled = true
			sun.directional_shadow_max_distance = 200.0
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		Tier.ULTRA:
			vp.msaa_3d = Viewport.MSAA_4X
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			vp.scaling_3d_scale = 1.0
			e.ssao_enabled = true
			e.ssao_detail = 0.6
			e.ssao_power = 1.8
			e.ssil_enabled = true
			e.ssil_intensity = 0.45
			e.volumetric_fog_enabled = true
			e.volumetric_fog_length = 190.0
			e.glow_enabled = true
			sun.directional_shadow_max_distance = 260.0
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS

	# Shadow map resolution is a project setting, not per-light.
	var shadow_size: int = [1024, 2048, 4096, 8192][tier]
	RenderingServer.directional_shadow_atlas_set_size(shadow_size, tier >= Tier.MEDIUM)


## Foliage density multiplier for the vegetation streamer.
static func foliage_scale(tier: int) -> float:
	var v: Array = [0.45, 0.75, 1.0, 1.25]
	return v[clampi(tier, 0, 3)]


## Atmosphere particle density. Applied before WorldVFX builds its emitters.
static func particle_density(tier: int) -> float:
	var v: Array = [0.20, 0.40, 0.60, 1.0]
	return v[clampi(tier, 0, 3)]
