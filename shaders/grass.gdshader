shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_lambert_wrap;

// Ground cover: grass tufts, flowers, ferns and undergrowth, drawn as REAL 3D geometry
// from a MultiMesh that streams in a grid of cells around the player.
//
// There is no albedo texture and no alpha scissor any more. The first pass built this
// layer as alpha-cut crossed cards, which is exactly what review called out: a card is
// invisible edge-on and lies flat against the ground texture it is standing on. Every
// blade is now a tapered, keeled, curved ribbon, so the silhouette comes from geometry
// and the shading comes from real vertex normals. Dropping the texture fetch also pays
// for the extra triangles: this shader is now two lerps and a ramp.
//
// VERTEX CHANNEL CONTRACT — the mesh builder (scripts/world/ground3d_flora.gd) writes:
//   COLOR.r  flex   0 at the root, 1 at the tip. Drives wind bend AND root darkening,
//                   because a blade is stiff exactly where it is in shadow.
//   COLOR.g  petal  0 leaf/stem, 1 petal. Selects the petal palette.
//   COLOR.b  core   1 on a receptacle, stamen or flower centre.
//   COLOR.a  ao     baked occlusion: low deep inside a tuft, 1 on an exposed edge.
//                   This is what stands in for the self-shadowing ground cover cannot
//                   afford to cast.
//   UV.x     hue    per-blade / per-petal 0..1 variation, so blades inside ONE tuft
//                   differ in colour rather than the whole tuft shifting together.
//   UV.y     t      distance along the part, 0 root .. 1 tip.

uniform vec3 leaf_a : source_color = vec3(0.52, 0.55, 0.24);   // sun-bleached straw
uniform vec3 leaf_b : source_color = vec3(0.24, 0.44, 0.15);   // fresh monsoon green
uniform vec3 petal_a : source_color = vec3(0.92, 0.36, 0.03);
uniform vec3 petal_b : source_color = vec3(0.98, 0.66, 0.06);
uniform vec3 core_col : source_color = vec3(0.52, 0.34, 0.03);
uniform vec3 ground_tint : source_color = vec3(0.30, 0.26, 0.17);
uniform float ground_blend : hint_range(0.0, 1.0) = 0.42;
uniform float albedo_gain : hint_range(0.2, 3.0) = 1.0;

uniform float roughness_value : hint_range(0.0, 1.0) = 0.74;
uniform float specular_amount : hint_range(0.0, 1.0) = 0.28;
// Baked AO is the only occlusion this layer has, so it is worth a knob. 1.0 uses it
// raw; lower values lift the interior of a tuft back toward flat.
uniform float ao_strength : hint_range(0.0, 1.0) = 0.85;

uniform vec2 wind_dir = vec2(0.82, 0.57);
uniform float wind_strength : hint_range(0.0, 3.0) = 0.5;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.0;
uniform float bend_scale = 0.30;

uniform vec3 translucency_color : source_color = vec3(0.66, 0.82, 0.30);
uniform float translucency : hint_range(0.0, 3.0) = 0.85;

uniform float fade_begin = 42.0;
uniform float fade_end = 56.0;
// Real blades have real normals, so this is now a whisper rather than the 0.72 the
// card version needed to stop a field going stripey. Anything above ~0.25 starts
// flattening the very curvature the geometry was rebuilt to have.
uniform float normal_up : hint_range(0.0, 1.0) = 0.12;

varying vec3 v_var;
varying float v_flex;
varying float v_petal;
varying float v_core;
varying float v_ao;
varying float v_hue;
varying float v_fade;
varying float v_thresh;

void vertex() {
	vec3 iorg = MODEL_MATRIX[3].xyz;
	v_var = vec3(INSTANCE_CUSTOM.x, INSTANCE_CUSTOM.y, INSTANCE_CUSTOM.w);
	v_flex = COLOR.r;
	v_petal = COLOR.g;
	v_core = COLOR.b;
	v_ao = COLOR.a;
	v_hue = UV.x;

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

	// Measured from the instance origin, not the vertex: a tuft has to fade as one
	// object or its own blades disagree about whether it still exists.
	v_fade = 1.0 - smoothstep(fade_begin, fade_end, distance(iorg, CAMERA_POSITION_WORLD));
	v_thresh = fract(INSTANCE_CUSTOM.z * 1.618 + 0.31);
}

void fragment() {
	// Distance fade, PER TUFT rather than per pixel. INSTANCE_CUSTOM.z is already a
	// per-instance random, so each tuft simply vanishes whole somewhere in the fade
	// band instead of dissolving into a stipple. A screen-space dither here put a
	// visible cross-hatch over the far half of every meadow: the tufts are far smaller
	// than a tree, so there is nothing for the eye to reconstruct the shape from and it
	// only ever reads as noise. Whole tufts thinning out reads as distance.
	if (v_fade < v_thresh) {
		discard;
	}

	// Two-sided geometry: the engine hands the fragment the front-face normal whichever
	// side is visible, so the back of a leaf must be flipped by hand or every blade
	// turned away from the sun renders as a black sliver — which is precisely how the
	// card version failed.
	vec3 nrm = FRONT_FACING ? NORMAL : -NORMAL;
	NORMAL = nrm;

	// Per-part hue crossed with the per-instance random. Two blades in one tuft differ,
	// and two tufts of the same mesh differ again, from one mesh and no texture.
	float dry = clamp(v_hue * 0.62 + clamp(v_var.x, 0.0, 1.0) * 0.55 - 0.08, 0.0, 1.0);
	vec3 col = mix(leaf_a, leaf_b, dry);
	col = mix(col, mix(petal_a, petal_b, dry), v_petal);
	col = mix(col, core_col, v_core);
	col *= albedo_gain * clamp(v_var.y, 0.4, 2.0);

	// Sink the root of every blade into the colour of the dirt it grows out of. This
	// single line is what stops a grass field from looking like a decal laid on top of
	// the terrain: the two surfaces share a colour where they meet. Petals are exempt —
	// a marigold does not fade into mud.
	float sink = ground_blend * (1.0 - max(v_petal, v_core));
	col = mix(col, ground_tint, sink * (1.0 - clamp(v_flex * 1.7, 0.0, 1.0)));

	ALBEDO = col;
	ROUGHNESS = mix(roughness_value, 0.42, v_petal * 0.5);
	SPECULAR = specular_amount;
	// The AO floor used to be 0.55. Under a closed canopy there is no direct light at
	// all, so AO is the only thing scaling the ambient, and 0.55 stacked on top of the
	// ground tint crushed every clump on the forest floor to a black fleck — measured
	// mean luminance 17/255 in the deep-forest shot. A blade of grass is not that
	// occluded; the baked value now bottoms out around 0.45 and is lifted by
	// ao_strength, which keeps it readable as a plant in shade.
	AO = mix(1.0, clamp(v_ao, 0.0, 1.0), ao_strength);
	AO_LIGHT_AFFECT = 0.45;
	BACKLIGHT = translucency_color * translucency * clamp(v_flex * 0.6 + 0.4, 0.0, 1.0);
}
