shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque, specular_schlick_ggx;

// Five ground layers blended from per-vertex weights baked by the mesher, plus a
// triplanar projection on steep ground so rock does not smear vertically.

uniform sampler2D grass_a : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_r : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D forest_a : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D forest_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D forest_r : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_a : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_r : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_a : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_r : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_a : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_r : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform float grass_scale = 0.13;
uniform float forest_scale = 0.10;
uniform float dirt_scale = 0.16;
uniform float rock_scale  = 0.055;
uniform float sand_scale  = 0.20;
uniform float macro_scale = 0.0022;
uniform float macro_strength : hint_range(0.0, 1.0) = 0.70;
uniform float normal_strength : hint_range(0.0, 3.0) = 1.25;
uniform vec3 wet_tint : source_color = vec3(0.42, 0.40, 0.34);
// Per-layer grade. The generated albedos are physically sensible but dark, and the
// leaf litter is strongly red; without this the whole valley reads as rust.
uniform vec3 grass_grade = vec3(1.42, 1.52, 1.22);
uniform vec3 forest_grade = vec3(1.02, 1.22, 1.10);
uniform vec3 dirt_grade = vec3(1.02, 1.06, 1.04);
uniform vec3 rock_grade = vec3(1.05, 1.06, 1.08);
uniform vec3 sand_grade = vec3(1.04, 1.04, 1.02);
uniform float far_fade_start = 120.0;
uniform float far_fade_end = 320.0;

varying vec3 v_world;
varying vec3 v_wnorm;
varying vec4 v_w;        // dirt, forest, rock, sand
varying vec2 v_extra;    // wetness, baked AO

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_w = COLOR;
	v_extra = UV2;
}

// Triplanar sample, used where the ground is too steep for a planar XZ projection.
// Sample the same texture at two very different scales and cross-fade between them
// with low-frequency noise. A single scale repeats visibly every few metres.
vec3 dual(sampler2D t, vec2 uv, float k, float m) {
	vec3 a = texture(t, uv).rgb;
	vec3 b = texture(t, uv * 0.2571 + vec2(0.37, 0.61)).rgb;
	return mix(a, b, k * 0.55) * (1.0 + (m - 0.5) * 0.18);
}

float dual1(sampler2D t, vec2 uv, float k) {
	return mix(texture(t, uv).r, texture(t, uv * 0.2571 + vec2(0.37, 0.61)).r, k * 0.55);
}

vec4 tri(sampler2D t, vec3 p, vec3 n, float s) {
	vec3 b = pow(abs(n), vec3(4.0));
	b /= max(b.x + b.y + b.z, 0.0001);
	return texture(t, p.zy * s) * b.x + texture(t, p.xz * s) * b.y + texture(t, p.xy * s) * b.z;
}

void fragment() {
	vec3 P = v_world;
	vec3 N = normalize(v_wnorm);

	float w_dirt = v_w.r;
	float w_for  = v_w.g;
	float w_rock = v_w.b;
	float w_sand = v_w.a;
	float w_grass = clamp(1.0 - (w_dirt + w_for + w_rock + w_sand), 0.0, 1.0);

	// Break up obvious tiling with a very low-frequency noise that biases which layer
	// wins locally. Without this a 6 m tile reads as a grid from any distance.
	vec3 macro = texture(detail_noise, P.xz * macro_scale).rgb;
	w_for  = clamp(w_for  + (macro.g - 0.5) * 0.35 * step(0.02, w_for), 0.0, 1.0);
	w_grass = clamp(w_grass + (macro.r - 0.5) * 0.20, 0.0, 1.0);

	float total = max(w_grass + w_dirt + w_for + w_rock + w_sand, 0.0001);
	w_grass /= total; w_dirt /= total; w_for /= total; w_rock /= total; w_sand /= total;

	vec2 uv_g = P.xz * grass_scale;
	vec2 uv_f = P.xz * forest_scale;
	vec2 uv_d = P.xz * dirt_scale;
	vec2 uv_s = P.xz * sand_scale;

	float k = texture(detail_noise, P.xz * macro_scale * 3.1).b;
	vec3 alb = dual(grass_a, uv_g, k, macro.r) * grass_grade * w_grass
		+ dual(forest_a, uv_f, k, macro.g) * forest_grade * w_for
		+ dual(dirt_a, uv_d, k, macro.r) * dirt_grade * w_dirt
		+ dual(sand_a, uv_s, k, macro.b) * sand_grade * w_sand;
	vec3 nrm = texture(grass_n, uv_g).rgb * w_grass
		+ texture(forest_n, uv_f).rgb * w_for
		+ texture(dirt_n, uv_d).rgb * w_dirt
		+ texture(sand_n, uv_s).rgb * w_sand;
	float rgh = dual1(grass_r, uv_g, k) * w_grass
		+ dual1(forest_r, uv_f, k) * w_for
		+ dual1(dirt_r, uv_d, k) * w_dirt
		+ dual1(sand_r, uv_s, k) * w_sand;

	if (w_rock > 0.001) {
		alb += tri(rock_a, P, N, rock_scale).rgb * rock_grade * w_rock;
		nrm += tri(rock_n, P, N, rock_scale).rgb * w_rock;
		rgh += tri(rock_r, P, N, rock_scale).r * w_rock;
	}

	// Large-scale colour drift so the ground is never one flat hue.
	vec3 drift = vec3(macro.r * 0.10 - 0.05, macro.g * 0.09 - 0.045, macro.b * 0.07 - 0.035);
	alb *= 1.0 + drift * macro_strength * 2.0;

	// Damp ground near the river reads darker and glossier.
	float wet = clamp(v_extra.x, 0.0, 1.0);
	alb = mix(alb, alb * wet_tint * 1.7, wet * 0.55);
	rgh = mix(rgh, 0.16, wet * 0.7);

	ALBEDO = alb;
	ROUGHNESS = clamp(rgh, 0.05, 1.0);
	SPECULAR = 0.42;

	// Flatten the detail normal with distance: at range it is aliasing, not detail.
	float d = length(P - CAMERA_POSITION_WORLD);
	float fade = 1.0 - smoothstep(far_fade_start, far_fade_end, d);
	vec3 tn = normalize(nrm * 2.0 - 1.0);
	tn.xy *= normal_strength * fade;
	NORMAL_MAP = normalize(tn) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;

	AO = clamp(v_extra.y, 0.0, 1.0);
	AO_LIGHT_AFFECT = 0.55;
}
