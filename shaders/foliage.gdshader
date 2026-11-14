shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// Foliage. Every leaf, sprig, frond and fern in the Vale draws with this.
//
// IT IS NO LONGER A CARD SHADER. FULL and MID foliage is real geometry — a leaf is a
// cambered, drooping, twisting lamina of 2 to 14 triangles (scripts/world/veg3d_leaf.gd)
// — and only the FAR billboard is still a quad. Two consequences run through the whole
// file: the normals are now MEANINGFUL rather than a fan baked to fake a curve, and
// anything computed per-VERTEX that ought to be per-leaf will visibly tear a leaf in
// half. See the flutter note below; that one was a real bug waiting to happen.
//
// VERTEX COLOUR CONTRACT (written by veg3d_leaf.gd and tree_builder.gd):
//   r  flex   0 where the geometry is anchored, 1 at a leaf tip. Wind amplitude.
//   g  ao     baked occlusion.
//   b  hue    per-LEAF colour jitter, 0.5 neutral. Constant over one leaf.
//   a  phase  per-SPRIG flutter phase. Constant over one sprig.
//
// Four things it has to do and why:
//
//  1. WIND. A layered gust: a slow world-space swell, a per-tree sway, and a fast
//     per-sprig flutter. The amplitude is masked by COLOR.r ("flex"), which the mesh
//     builder bakes as 0 at the trunk base rising to 1 at a leaf tip, so trunks stay
//     planted while the canopy moves. Without that mask whole trees skate sideways.
//     Because flex ramps ALONG a sprig — low where its twig joins the branch, high at
//     the blade tips — the sprig bends from its base instead of sliding sideways.
//  2. TRANSLUCENCY. Godot's BACKLIGHT term. A canopy with no backlight reads as black
//     cardboard whenever the sun is behind it; with it, the leaf edges glow.
//  3. PER-INSTANCE VARIATION through INSTANCE_CUSTOM, so a forest of one baked mesh
//     is not a forest of one colour.
//  4. LOD CROSS-FADE. Screen-space dither against a distance ramp. Both partners in a
//     hand-over evaluate the SAME ramp `s` (how far the coarser LOD has faded in) and
//     take opposite sides of the dither: the coarse one keeps pixels where s > dither,
//     the fine one keeps the rest. Exactly one of the two owns every pixel, so the
//     band can never show a hole or a double image. Testing both against `s < dither`
//     — the obvious way — leaves half the pixels empty at s = 0.5.
//
//     Two things make that actually work, and both were wrong at first:
//
//     `s` is evaluated from the INSTANCE ORIGIN, never from the vertex. A MID canopy
//     mesh and its FAR billboard are completely different geometry, so a per-vertex
//     distance gives the two partners DIFFERENT `s` at the same screen pixel — and the
//     moment they disagree the dither stops being complementary and the hand-over shows
//     as doubled and holed pixels. Rendered at 60-90 m that read as chicken wire laid
//     over the whole treeline.
//
//     And the ramp carries a per-tree offset (`lod_jitter`, hashed from the instance
//     origin so both partners agree). Without it every tree in a 14 m shell dithers at
//     once and the stipple is a screen-wide texture; with it the band is 3 m wide and
//     scattered over a 14 m spread, so a handful of trees are mid-swap at any moment
//     and each is mid-swap for about a third of a second at running pace.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool two_sided = true;          // kept for Mats.foliage() compatibility
uniform bool use_normal_map = true;

uniform float alpha_cut : hint_range(0.0, 1.0) = 0.40;
// Measured 2026-08-28: the project grades with AGX, which desaturates highlights hard
// — sampled canopy pixels fall from sat 0.46 in the shadows to 0.10 in the brightest
// band. A sunlit leaf therefore reads as cream, not as bright green, and no amount of
// tinting fixes it because the tint is applied before the curve. The fix is to keep
// lit leaves off the top of the curve, so the gain sits near 1.0 rather than the 1.3
// that looked right in isolation.
uniform float albedo_gain : hint_range(0.2, 3.0) = 1.72;
// Tints are MULTIPLIERS around 1.0, not colours: the leaf atlas is already the right
// hue and multiplying it by a dark green would crush it to black.
uniform vec3 tint_a = vec3(1.10, 1.06, 0.80);
uniform vec3 tint_b = vec3(0.74, 0.92, 0.66);
uniform float ao_strength : hint_range(0.0, 1.0) = 0.55;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.72;
uniform float normal_depth : hint_range(0.0, 2.0) = 0.30;
// Per-leaf colour spread. The cluster atlas used to supply this for free — every card
// carried a dozen leaves painted in slightly different greens. One lamina per leaf does
// not, so the variation moves into the mesh (COLOR.b) and is applied here. 0 on the FAR
// billboard, which is still an atlas.
uniform float leaf_var : hint_range(0.0, 1.0) = 0.0;

uniform vec2 wind_dir = vec2(0.82, 0.57);
uniform float wind_strength : hint_range(0.0, 3.0) = 0.5;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.0;
uniform float bend_scale = 0.55;        // metres of travel at the very tip
uniform float flutter_scale = 0.14;

uniform vec3 translucency_color : source_color = vec3(0.72, 0.86, 0.34);
uniform float translucency : hint_range(0.0, 3.0) = 1.05;

// SUN TRANSMITTED THROUGH THE BLADE — and the reason it is not BACKLIGHT.
//
// Godot adds BACKLIGHT inside the light loop, multiplied by that light's ATTENUATION,
// and for a DirectionalLight that attenuation IS the shadow term. Every leaf inside a
// canopy stands in the canopy's own shadow, so BACKLIGHT is multiplied to zero exactly
// where it is the only light the leaf has. The result is a canopy that renders BLACK
// from underneath — which is the single commonest way the player sees foliage.
//
// Measured 2026-08-28 at the forest canopy_under framing (tests/probes/qa_dark_ab.gd), median
// luminance over the non-sky pixels:
//
//   as shipped                    26.9   (36.7% of canopy pixels below luminance 10)
//   translucency x4               26.9   (33.5%)  <- the knob does NOTHING
//   SSAO off                      22.1   (36.6%)  <- not SSAO either
//   sun shadow off                86.2   ( 0.8%)  <- the shadow is the whole cause
//   sun shadow off + transl x4   157.7   ( 0.8%)  <- backlight only works unshadowed
//
// So the term has to live OUTSIDE the light loop or it does nothing at all. This one
// does: it is emission, it is never shadowed, and it fires only when the viewer is
// looking along the sunbeam THROUGH the leaf, which is precisely the case the light
// loop cannot serve. Front-lit leaves get none of it and are unchanged.
uniform vec3 sun_dir = vec3(0.36, -0.86, 0.36);  // direction the sunlight TRAVELS
uniform float sun_transmit : hint_range(0.0, 2.0) = 1.0;  // 0 at night; SkySystem drives it
uniform float transmit_strength : hint_range(0.0, 3.0) = 0.0;
uniform float transmit_sharp : hint_range(0.5, 8.0) = 1.6;

// x,y = fade IN band (near edge), z,w = fade OUT band (far edge). Keep x < y < z < w:
// smoothstep with a zero-width edge is undefined in GLSL.
uniform vec4 lod_fade = vec4(-2.0, -1.0, 4000.0, 4200.0);
uniform float lod_jitter = 0.0;   // metres of per-tree spread on the hand-over distance
// The point the LOD ramp is measured FROM. Must not be the camera: a spatial shader
// cannot tell it is in a shadow pass, and in that pass CAMERA_POSITION_WORLD is the
// light's virtual camera. Every LOD then evaluated its ramp against the wrong distance,
// so a tree twenty metres away — drawn as a full mesh, its billboard discarding every
// pixel on screen — still cast the BILLBOARD's shadow as well as the mesh's. Measured:
// the deep-forest floor sat at luminance 28/255 at 15:20 with the double shadow and
// 35 with the billboards silenced. Feeding the streaming focus in explicitly makes the
// shadow pass agree with the camera pass, which is both correct and cheaper.
// 1e9 means "nobody set it" - fall back to the camera, which is what the species
// gallery wants.
uniform vec3 lod_focus = vec3(1.0e9);
uniform bool dither_fade = false;
// false: this is the COARSER partner (or a lone fade-out) - keep where the ramp wins.
// true:  this is the FINER partner - keep exactly the pixels the coarse one gave up.
uniform bool dither_invert = false;

varying vec3 v_var;     // tint mix, brightness, dryness
varying float v_fade;
varying float v_flex;
varying float v_ao;
varying float v_hue;    // COLOR.b, per-leaf

void vertex() {
	vec3 iorg = MODEL_MATRIX[3].xyz;
	v_var = vec3(INSTANCE_CUSTOM.x, INSTANCE_CUSTOM.y, INSTANCE_CUSTOM.w);
	v_flex = COLOR.r;
	v_ao = COLOR.g;
	v_hue = COLOR.b;

	float phase = INSTANCE_CUSTOM.z * 6.2831853 + iorg.x * 0.071 + iorg.z * 0.113;
	float t = TIME * wind_speed;

	// A gust front rolling across the valley: low frequency in both space and time, so
	// neighbouring trees lull and surge together instead of each doing its own thing.
	float gust = 0.55 + 0.45 * sin(t * 0.21 + iorg.x * 0.013 + iorg.z * 0.017)
		* cos(t * 0.097 + iorg.z * 0.0071);
	float amp = wind_strength * gust;

	// The wind direction is world space but VERTEX is model space. Instances are a
	// yaw + near-uniform scale, so transposing the basis and dividing by scale^2 is an
	// exact inverse-rotate and far cheaper than inverse(MODEL_MATRIX) per vertex.
	vec3 wd = normalize(vec3(wind_dir.x, 0.0, wind_dir.y) + vec3(1e-5, 0.0, 1e-5));
	float s2 = max(dot(MODEL_MATRIX[0].xyz, MODEL_MATRIX[0].xyz), 1e-4);
	vec3 lwd = vec3(dot(MODEL_MATRIX[0].xyz, wd), 0.0, dot(MODEL_MATRIX[2].xyz, wd)) / s2;
	vec3 lside = vec3(lwd.z, 0.0, -lwd.x);

	float flex2 = v_flex * v_flex;
	float sway = sin(t * 0.83 + phase) * 0.62 + sin(t * 1.67 + phase * 1.61) * 0.38;
	vec3 off = lwd * (sway * amp * bend_scale * flex2);

	// Per-SPRIG flutter, so a canopy does not breathe like one solid object.
	//
	// The phase is baked into COLOR.a by the mesh builder, one value per sprig. It used
	// to be hashed from the model-space VERTEX, and that is fine for a card — four
	// corners with four beats only skews a quad — but a real leaf has up to fifteen
	// vertices, and giving each of them its own beat pulls the blade apart along its
	// own triangles. Same reason the leaf's hue lives in COLOR.b rather than a hash.
	float h = COLOR.a;
	float fl = sin(t * 3.05 + h * 6.2831853 + phase) * flutter_scale * amp * v_flex;
	off += lside * fl;
	off.y += sin(t * 2.37 + h * 12.91 + phase) * flutter_scale * 0.55 * amp * v_flex;
	// Leaning costs height: without this the canopy visibly stretches as it bends.
	off.y -= abs(sway) * amp * bend_scale * flex2 * 0.14;

	VERTEX += off;

	// Quantising the origin to 0.25 m before hashing keeps bark and leaves — two
	// separate shaders — from landing on different sides of a float rounding.
	float lodh = fract(sin(dot(floor(iorg.xz * 4.0), vec2(12.9898, 78.233))) * 43758.5453);
	vec3 fpt = lod_focus.x > 1.0e8 ? CAMERA_POSITION_WORLD : lod_focus;
	float dref = distance(iorg, fpt) + (lodh - 0.5) * lod_jitter;
	v_fade = smoothstep(lod_fade.x, lod_fade.y, dref)
		* (1.0 - smoothstep(lod_fade.z, lod_fade.w, dref));
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);

	if (dither_fade) {
		// Deterministic screen-space dither. Interleaved-gradient noise rather than a
		// sine hash: it is far less clumpy, so the hand-over reads as a soft stipple
		// instead of a visible speckle field.
		vec2 p = floor(FRAGCOORD.xy);
		float dq = fract(52.9829189 * fract(0.06711056 * p.x + 0.00583715 * p.y));
		if (dither_invert) {
			if (v_fade > dq) { discard; }
		} else {
			if (v_fade <= dq) { discard; }
		}
	}

	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;

	vec3 tint = mix(tint_a, tint_b, clamp(v_var.x, 0.0, 1.0));
	// Per-leaf jitter: brightness both ways, and a push toward straw on the light side,
	// because within one crown the older outer leaves yellow and the shaded ones do not.
	float lv = clamp(v_hue, 0.0, 1.0) * 2.0 - 1.0;
	tint *= 1.0 + lv * leaf_var * 0.55;
	tint = mix(tint, tint * vec3(1.14, 1.02, 0.70), max(lv, 0.0) * leaf_var);
	// Dryness pulls a leaf toward straw: the outer, sun-struck part of a canopy and
	// anything on the badlands side of the valley.
	tint = mix(tint, vec3(1.16, 1.0, 0.62), clamp(v_var.z, 0.0, 1.0) * 0.55);
	ALBEDO = tex.rgb * tint * albedo_gain * clamp(v_var.y, 0.4, 2.0);

	ROUGHNESS = roughness_value;
	// 0.32 was the single cause of the bleached canopy, and it took an A/B to find it.
	// A leaf card takes specular from the SKY as well as from the sun, and the sky
	// around a low sun is a blown-out white; a broad rough lobe pointed at it returns
	// white light, the normal map turns that into a fine woven pattern, and the card
	// reads as a flake of grey paper. Zeroing specular and the normal map together took
	// the hero banyan's crown from leaf saturation 0.12 to 0.22 and the deep-forest
	// canopy from 0.53 to 0.84 — but also removed roughly 60% of the canopy's light
	// (backlit mean luminance 36.5 -> 14.1), because that white sheen was doing most of
	// the lighting. So the energy is not removed, it is MOVED: specular down to a real
	// leaf sheen and the loss made up in albedo_gain, which is green. Same brightness,
	// far more colour.
	SPECULAR = 0.10;
	AO = mix(1.0, clamp(v_ao, 0.0, 1.0), ao_strength);
	AO_LIGHT_AFFECT = 0.5;

	// Sunlight bleeding through the leaf. Interior cards (low baked AO) get less of it,
	// which is what gives a canopy depth rather than a uniform glow.
	//
	// The amounts were nearly halved after a measurement. BACKLIGHT is added per light
	// with that light's full energy, so with a 2.3-energy sun straight behind a crown
	// the term alone came out around (1.1, 1.6, 0.5) in linear HDR — well past 1.0, and
	// AGX desaturates hard above that. Photographed looking up at the hero banyan at
	// 09:00 the crown measured mean saturation 0.11 and 35% of its pixels above
	// luminance 190: cream-coloured paper flakes, not leaves. The same canopy at 17:00,
	// where the sun is weaker, measured 0.61 and was correct — which is exactly why
	// tuning this on one backlit shot got it wrong.
	BACKLIGHT = translucency_color * translucency * mix(0.25, 1.0, clamp(v_ao, 0.0, 1.0));

	// The unshadowed half of the same effect. `through` is 1 when the camera is looking
	// straight down the sunbeam (the leaf is between the viewer and the sun, so light
	// that made it through the blade travels at the eye) and 0 when the sun is behind
	// the viewer, so a front-lit leaf receives nothing and keeps the look it already
	// has. Scaled by baked AO so the deep interior of a crown stays darker than the
	// shell and the canopy keeps its depth instead of becoming a uniform glow.
	if (transmit_strength > 0.0) {
		vec3 ldir = normalize((VIEW_MATRIX * vec4(sun_dir, 0.0)).xyz);
		float through = clamp(dot(normalize(VIEW), ldir), 0.0, 1.0);
		through = pow(through, transmit_sharp);
		EMISSION += ALBEDO * translucency_color * (transmit_strength * sun_transmit
			* through * mix(0.35, 1.0, clamp(v_ao, 0.0, 1.0)));
	}

	if (use_normal_map) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = normal_depth;
	}
	// Back faces MUST have their normal flipped, and it matters MORE now than it did.
	// A leaf is a real two-sided surface with a genuine outward normal, so half of every
	// crown is seen from underneath; leaving those unflipped renders a lit front surface
	// on a face that should be in shade, and a backlit canopy came out bleached cream
	// instead of dark and glowing. The sun-through-leaf effect is BACKLIGHT's job, not
	// the geometric normal's — that term is added independently of N dot L, which is
	// exactly why it works here.
	if (two_sided && !FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
