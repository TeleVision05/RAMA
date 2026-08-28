shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_lambert_wrap, specular_disabled;

// Ground cover: grass clumps, ferns and flowers, drawn as crossed alpha-cut cards from
// a MultiMesh that streams in a grid of cells around the player.
//
// Grass is lit with wrapped lambert and no specular on purpose. Thousands of thin
// vertical cards with a hard specular lobe turn into a field of sparkling white dots
// the moment the sun gets low, and every blade is a shadow-caster's worst case.
//
// COLOR.r is the flex mask baked by the mesh builder: 0 at the root, 1 at the tip. It
// drives the wind bend AND the root darkening, because a blade is in shadow exactly
// where it is stiff.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

uniform float alpha_cut : hint_range(0.0, 1.0) = 0.34;
uniform float albedo_gain : hint_range(0.2, 3.0) = 1.15;
uniform vec3 tint_a = vec3(1.12, 1.08, 0.68);   // sun-bleached straw
uniform vec3 tint_b = vec3(0.72, 1.00, 0.60);   // fresh monsoon green
uniform vec3 ground_tint : source_color = vec3(0.30, 0.26, 0.17);
uniform float ground_blend : hint_range(0.0, 1.0) = 0.75;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.92;

uniform vec2 wind_dir = vec2(0.82, 0.57);
uniform float wind_strength : hint_range(0.0, 3.0) = 0.5;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.0;
uniform float bend_scale = 0.30;

uniform vec3 translucency_color : source_color = vec3(0.66, 0.82, 0.30);
uniform float translucency : hint_range(0.0, 3.0) = 0.85;

uniform float fade_begin = 42.0;
uniform float fade_end = 58.0;
// Cards that stand straight up vanish when the camera looks along them. Leaning the
// baked normal toward +Y keeps a field evenly lit instead of stripey.
uniform float normal_up : hint_range(0.0, 1.0) = 0.72;

varying vec3 v_var;
varying float v_flex;
varying float v_fade;
varying float v_thresh;

void vertex() {
	vec3 iorg = MODEL_MATRIX[3].xyz;
	v_var = vec3(INSTANCE_CUSTOM.x, INSTANCE_CUSTOM.y, INSTANCE_CUSTOM.w);
	v_flex = COLOR.r;

	float phase = INSTANCE_CUSTOM.z * 6.2831853 + iorg.x * 0.53 + iorg.z * 0.41;
	float t = TIME * wind_speed;

	// Two travelling waves crossing the meadow at different speeds and headings. A
	// single wave makes the whole field pulse in lockstep, which reads as a rubber
	// sheet rather than as wind.
	float w1 = sin(t * 1.55 + iorg.x * 0.21 + iorg.z * 0.13 + phase);
	float w2 = sin(t * 2.7 + iorg.x * 0.07 - iorg.z * 0.31 + phase * 0.7);
	float gust = 0.5 + 0.5 * sin(t * 0.27 + iorg.x * 0.012 + iorg.z * 0.015);
	float amp = wind_strength * (0.45 + 0.9 * gust);

	float flex2 = v_flex * v_flex;
	vec3 wd = normalize(vec3(wind_dir.x, 0.0, wind_dir.y) + vec3(1e-5, 0.0, 1e-5));
	float s2 = max(dot(MODEL_MATRIX[0].xyz, MODEL_MATRIX[0].xyz), 1e-4);
	vec3 lwd = vec3(dot(MODEL_MATRIX[0].xyz, wd), 0.0, dot(MODEL_MATRIX[2].xyz, wd)) / s2;
	vec3 lside = vec3(lwd.z, 0.0, -lwd.x);

	float bend = (w1 * 0.7 + w2 * 0.3) * amp * bend_scale;
	VERTEX += lwd * (bend * flex2);
	VERTEX += lside * (w2 * 0.25 * amp * bend_scale * flex2);
	VERTEX.y -= abs(bend) * flex2 * 0.30;   // a bent blade is a shorter blade

	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), normal_up));

	// Measured from the instance origin, not the vertex: a clump has to fade as one
	// object or its own blades disagree about whether it still exists.
	v_fade = 1.0 - smoothstep(fade_begin, fade_end, distance(iorg, CAMERA_POSITION_WORLD));
	v_thresh = fract(INSTANCE_CUSTOM.z * 1.618 + 0.31);
}

void fragment() {
	// Distance fade, PER CLUMP rather than per pixel. INSTANCE_CUSTOM.z is already a
	// per-instance random, so each clump simply vanishes whole somewhere in the fade
	// band instead of dissolving into a stipple. A screen-space dither here put a
	// visible cross-hatch over the far half of every meadow: the cards are far smaller
	// than a tree, so there is nothing for the eye to reconstruct the shape from and it
	// only ever reads as noise. Whole clumps thinning out reads as distance.
	if (v_fade < v_thresh) {
		discard;
	}

	vec4 tex = texture(albedo_tex, UV);
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;

	vec3 tint = mix(tint_a, tint_b, clamp(v_var.x, 0.0, 1.0));
	vec3 alb = tex.rgb * tint * albedo_gain * clamp(v_var.y, 0.4, 2.0);
	// Sink the root of every blade into the colour of the dirt it grows out of. This
	// single line is what stops a grass field from looking like a decal laid on top of
	// the terrain: the two surfaces share a colour where they meet.
	alb = mix(ground_tint, alb, mix(1.0 - ground_blend, 1.0, clamp(v_flex * 1.6, 0.0, 1.0)));

	ALBEDO = alb;
	ROUGHNESS = roughness_value;
	// The AO floor used to be 0.55. Under a closed canopy there is no direct light at
	// all, so AO is the only thing scaling the ambient, and 0.55 stacked on top of the
	// ground tint crushed every clump on the forest floor to a black fleck — measured
	// mean luminance 17/255 in the deep-forest shot. A blade of grass is not that
	// occluded; 0.78 keeps it readable as a plant in shade and is invisible in the sun.
	AO = mix(0.78, 1.0, clamp(v_flex, 0.0, 1.0));
	AO_LIGHT_AFFECT = 0.45;
	BACKLIGHT = translucency_color * translucency * clamp(v_flex, 0.0, 1.0);
}
