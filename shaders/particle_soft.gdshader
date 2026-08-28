shader_type spatial;

// Soft billboard for every atmospheric particle in the world: pollen, fireflies,
// leaves, dust, mist, smoke, embers, rain.
//
// Blending is PREMULTIPLIED, which is the whole trick: with dst = src.rgb + dst*(1-src.a)
// a single shader covers both ends of the range. Write ALPHA = 0 and the particle is
// purely additive (a firefly, an ember); write ALPHA = coverage and it is a normal
// alpha blend (smoke, mist). The `additive` uniform slides between the two, so one
// shader file serves every emitter instead of one file per blend mode.
//
// Every particle also fades against the depth buffer, so nothing cuts a hard line into
// the terrain when it intersects it - that hard edge is the single biggest tell that a
// scene is made of camera-facing quads.

render_mode blend_premul_alpha, depth_draw_never, cull_disabled, unshaded,
	shadows_disabled, fog_disabled;

// --- look -------------------------------------------------------------------
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float brightness : hint_range(0.0, 12.0) = 1.0;
uniform float additive : hint_range(0.0, 1.0) = 1.0;
// 0 = tight dot with a hard core, 1 = wide diffuse haze.
uniform float softness : hint_range(0.0, 1.0) = 0.45;
// Extra hot centre, for things that are meant to bloom (fireflies, embers, flame).
uniform float core : hint_range(0.0, 8.0) = 0.0;

// --- optional sprite --------------------------------------------------------
uniform sampler2D sprite : source_color, filter_linear_mipmap, hint_default_white;
uniform bool use_sprite = false;
// Cells in an RGBA sprite atlas; each particle deterministically picks one.
uniform vec2 atlas_cells = vec2(1.0, 1.0);
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.0;

// --- motion -----------------------------------------------------------------
// 0 = use the instance transform untouched (lets GPUParticles3D transform_align do
//     the work, and enables `tumble`), 1 = full camera billboard, 2 = Y-axis billboard.
uniform int billboard_mode : hint_range(0, 2) = 1;
// How much of the per-particle angle becomes a screen-space spin, 0..1. This has to be
// separable from the angle itself, because the angle is ALSO the per-particle random
// seed (see `vertex`). A round puff does not care - a circle spun is a circle - but a
// deliberately non-square quad does: spinning a 27 m x 7 m mist ribbon to a random
// screen angle turns a bank of mist into a pile of crossed white spikes. That was the
// single worst artifact in the first pass. Set spin 0 for any non-square quad.
uniform float spin_amount : hint_range(0.0, 1.0) = 1.0;
// Free 3D tumble about a per-particle axis. Only meaningful with billboard_mode 0.
uniform float tumble = 0.0;
uniform float pulse_rate = 0.0;
uniform float pulse_depth : hint_range(0.0, 1.0) = 0.0;

// --- fades ------------------------------------------------------------------
uniform float soft_depth = 1.4;   // metres of depth-buffer softening
// 0 = the depth fade may erase the particle entirely, 1 = ignore the depth buffer.
uniform float soft_keep : hint_range(0.0, 1.0) = 0.0;
uniform float near_fade = 0.9;    // metres; stops particles slapping the lens
uniform float fade_start = 45.0;
uniform float fade_end = 80.0;

// Godot 4.7 removed the DEPTH_TEXTURE built-in; it has to be bound by hint now.
uniform sampler2D scene_depth : hint_depth_texture, filter_linear;

varying float v_rand;

void vertex() {
	// CUSTOM.x is the particle's spawn angle in radians. With angular_velocity 0 and a
	// randomised angle range it is a stable per-particle random number - the only per
	// particle seed that does not change every frame (hashing the position would, since
	// these things drift).
	float ang = INSTANCE_CUSTOM.x;
	v_rand = fract(ang * 0.15915494 + 0.3713);

	vec3 sc = vec3(length(MODEL_MATRIX[0].xyz),
		length(MODEL_MATRIX[1].xyz),
		length(MODEL_MATRIX[2].xyz));

	if (billboard_mode == 1) {
		mat4 bb = mat4(
			vec4(normalize(INV_VIEW_MATRIX[0].xyz), 0.0),
			vec4(normalize(INV_VIEW_MATRIX[1].xyz), 0.0),
			vec4(normalize(INV_VIEW_MATRIX[2].xyz), 0.0),
			MODEL_MATRIX[3]);
		float sang = ang * spin_amount;
		float ca = cos(sang);
		float sa = sin(sang);
		mat4 spin = mat4(
			vec4(ca, -sa, 0.0, 0.0),
			vec4(sa, ca, 0.0, 0.0),
			vec4(0.0, 0.0, 1.0, 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
		MODELVIEW_MATRIX = VIEW_MATRIX * bb * spin;
		MODELVIEW_MATRIX[0] *= sc.x;
		MODELVIEW_MATRIX[1] *= sc.y;
		MODELVIEW_MATRIX[2] *= sc.z;
	} else if (billboard_mode == 2) {
		// Cylindrical: keeps world up, swings only about Y. Right for anything that
		// should stay vertical - rain, standing mist ribbons.
		vec3 to_cam = INV_VIEW_MATRIX[3].xyz - MODEL_MATRIX[3].xyz;
		to_cam.y = 0.0;
		to_cam = normalize(to_cam + vec3(1e-4, 0.0, 0.0));
		vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
		mat4 bb = mat4(
			vec4(right, 0.0),
			vec4(0.0, 1.0, 0.0, 0.0),
			vec4(to_cam, 0.0),
			MODEL_MATRIX[3]);
		MODELVIEW_MATRIX = VIEW_MATRIX * bb;
		MODELVIEW_MATRIX[0] *= sc.x;
		MODELVIEW_MATRIX[1] *= sc.y;
		MODELVIEW_MATRIX[2] *= sc.z;
	} else if (tumble > 0.0) {
		// Rodrigues rotation about a per-particle axis: a leaf turning over as it falls.
		float a = TIME * tumble * (0.55 + v_rand) + v_rand * 19.0;
		float ca = cos(a);
		float sa = sin(a);
		vec3 axis = normalize(vec3(sin(v_rand * 23.1), 0.55, cos(v_rand * 17.7)));
		vec3 p = VERTEX;
		VERTEX = p * ca + cross(axis, p) * sa + axis * dot(axis, p) * (1.0 - ca);
	}
}

void fragment() {
	vec4 src;
	if (use_sprite) {
		vec2 cell = floor(vec2(fract(v_rand * 7.13), fract(v_rand * 3.71)) * atlas_cells);
		cell = min(cell, atlas_cells - vec2(1.0));
		vec2 uv = (clamp(UV, vec2(0.004), vec2(0.996)) + cell) / atlas_cells;
		src = texture(sprite, uv);
	} else {
		// Procedural round puff - no texture fetch, no atlas bleed, and the falloff
		// exponent gives everything from a crisp mote to a broad bank of mist.
		float d = length(UV - vec2(0.5)) * 2.0;
		float f = clamp(1.0 - d, 0.0, 1.0);
		// Smoothstep FIRST. pow() alone still carries real opacity out to the rim, and
		// that is what turns a bank of mist into a heap of hard white bubbles.
		f = f * f * (3.0 - 2.0 * f);
		f = pow(f, mix(3.2, 0.9, softness));
		src = vec4(1.0, 1.0, 1.0, f + pow(f, 10.0) * core);
	}

	// Cut on the SPRITE's own alpha, never on the faded alpha - otherwise a leaf
	// fading in pops into existence whole instead of fading.
	if (src.a < alpha_cut) {
		discard;
	}
	float a = src.a * COLOR.a * tint.a;
	vec3 c = src.rgb * COLOR.rgb * tint.rgb * brightness;

	if (pulse_depth > 0.0) {
		float p = 0.5 + 0.5 * sin(TIME * pulse_rate + v_rand * 41.0);
		p = mix(1.0 - pulse_depth, 1.0, p * p);
		a *= p;
		c *= mix(0.65, 1.25, p);
	}

	// Soft depth fade. Godot 4 uses reverse-Z, so the sampled depth IS the NDC z.
	//
	// `soft_keep` is the floor this fade may not go below. Anything that is MEANT to
	// meet the ground needs one: rain and its splashes sit centimetres above the
	// terrain, so an unfloored fade drives them to zero alpha and the rain visibly
	// dissolves a metre short of the grass while no splash ever appears. That was the
	// reason the first pass had rain that never landed.
	float depth = texture(scene_depth, SCREEN_UV).x;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_z = -(view.z / view.w);
	float frag_z = -VERTEX.z;
	a *= mix(clamp((scene_z - frag_z) / max(soft_depth, 0.001), 0.0, 1.0), 1.0, soft_keep);

	// Distance fades: nothing pops at the far edge, nothing smears across the lens.
	a *= 1.0 - smoothstep(fade_start, fade_end, frag_z);
	a *= smoothstep(near_fade * 0.3, near_fade, frag_z);

	// Premultiplied output: ALPHA 0 -> pure add, ALPHA a -> normal alpha blend.
	ALBEDO = c * a;
	ALPHA = a * (1.0 - additive);
}
