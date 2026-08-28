shader_type spatial;
// The falls where the Godavari drops ~21 m out of the northern gorge.
//
// The sheet is the same ribbon as the river, just near-vertical, so it carries the
// same UV convention: UV.x is metres ACROSS, UV.y is metres ALONG the fall. Three
// layers of water_foam are sampled with a heavily anisotropic scale (wide across,
// long down) and scrolled downward at different rates - that is what makes streaks
// instead of a moving cloud.
//
// Vertex COLOR from scripts/world/water.gd:
//   r = flow speed   g = fall progress, 0 at the crest .. 1 at the plunge pool
//   b = 1 mid-sheet .. 0 at the rock walls   a = spare mask
//
// Writes NORMAL_MAP, so the mesh MUST carry ARRAY_TANGENT.
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D foam_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

uniform float fall_speed : hint_range(0.1, 6.0) = 1.0;
uniform float streak_across = 0.16;      // repeats per metre across the sheet
uniform float streak_along = 0.030;      // repeats per metre down it (long streaks)
uniform vec3 water_tint : source_color = vec3(0.560, 0.690, 0.720);
uniform vec3 white_tint : source_color = vec3(0.965, 0.980, 0.985);
uniform float emissive_gain : hint_range(0.0, 3.0) = 0.46;
uniform float body_alpha : hint_range(0.0, 1.0) = 0.46;
uniform float mid_thin : hint_range(0.0, 1.0) = 0.42;   // how much the middle thins out
uniform float edge_soft : hint_range(0.01, 1.0) = 0.34;
uniform float contact_fade = 0.9;        // metres of soft fade against the rock

void fragment() {
	float spd = (0.55 + COLOR.r) * fall_speed;
	float prog = COLOR.g;
	float mid = COLOR.b;
	float t = TIME;

	// A slow lateral wander so the curtain is not a set of perfectly parallel bars.
	float wander = sin(UV.y * 0.20 + t * 0.55) * 0.35 + sin(UV.y * 0.07 - t * 0.31) * 0.6;
	float u = UV.x + wander;

	float s1 = texture(foam_tex, vec2(u * streak_across, UV.y * streak_along - t * 0.62 * spd)).r;
	float s2 = texture(foam_tex, vec2(u * streak_across * 0.55 + 0.31,
			UV.y * streak_along * 0.58 - t * 0.98 * spd)).r;
	float s3 = texture(foam_tex, vec2(u * streak_across * 2.1 - 0.17,
			UV.y * streak_along * 1.9 - t * 1.55 * spd)).r;
	float streak = clamp(s1 * 0.9 + s2 * 0.8 + s3 * 0.55, 0.0, 1.7);
	float veil = smoothstep(0.16, 0.98, streak);

	// White water where it tips over the lip and where it detonates into the pool.
	float crest = 1.0 - smoothstep(0.0, 0.13, prog);
	float base = smoothstep(0.80, 1.0, prog);
	float bright = clamp(crest * 1.1 + base * 1.35, 0.0, 1.6);

	// Ripple relief across the sheet, scrolling down fast.
	vec3 nt = texture(normal_tex, vec2(u * 0.10, UV.y * 0.045 - t * 0.9 * spd)).xyz * 2.0 - 1.0;
	nt = normalize(vec3(nt.xy * 0.75, nt.z));
	NORMAL_MAP = nt * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;

	// Soft contact against the rock: the sheet is pushed a little off the chute so it
	// arcs, and without this fade its intersection with the terrain is a hard line.
	float raw = texture(depth_tex, SCREEN_UV).x;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(vec3(SCREEN_UV * 2.0 - 1.0, raw), 1.0);
	vp.xyz /= vp.w;
	float contact = clamp((-vp.z - (-VERTEX.z)) / contact_fade, 0.0, 1.0);

	float edge = smoothstep(0.0, edge_soft, mid);
	float thin = 1.0 - mid_thin * sin(clamp(prog, 0.0, 1.0) * PI);

	ALBEDO = mix(water_tint, white_tint, clamp(veil + bright * 0.6, 0.0, 1.0));
	EMISSION = white_tint * bright * emissive_gain * (0.35 + 0.65 * veil);
	ROUGHNESS = mix(0.62, 0.30, veil);
	METALLIC = 0.0;
	SPECULAR = 0.45;
	ALPHA = clamp((body_alpha + 0.62 * veil) * thin * edge
			+ bright * 0.30 * edge + crest * 0.40 * edge, 0.0, 1.0) * contact;
}
