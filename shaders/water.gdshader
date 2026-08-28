shader_type spatial;
// The Godavari's surface: river ribbon, plunge pool and the standing pools.
//
// What makes it read as water rather than a blue plane:
//   * two scrolling samples of water_normal at different scales AND different speeds,
//     scrolled along the mesh's own flow UV (v runs downstream), so the ripples travel
//     with the current instead of along world X/Z,
//   * the THICKNESS of the water, reconstructed from DEPTH_TEXTURE, which drives colour
//     (pale jade over the sand shallows -> dark teal in the deep pools), absorption of
//     the refracted image, and the shoreline wash,
//   * Fresnel: transparent looking straight down, near-mirror at grazing angles,
//   * a sharp sun glitter written in the light() function.
//
// Vertex COLOR is authored by scripts/world/water.gd:
//   r = flow speed 0..1   g = churn (rapids / plunge froth)
//   b = 1 mid-channel .. 0 at the bank    a = authored alpha mask (pool rims)
//
// The mesh MUST carry ARRAY_TANGENT: this shader writes NORMAL_MAP, and without a
// tangent basis Godot's TBN is degenerate and every lit pixel comes out black.
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_tex : filter_linear_mipmap, repeat_enable;
uniform bool use_refraction = true;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

group_uniforms waves;
uniform float wave_scale_a = 0.105;      // texture repeats per metre, ripple layer
uniform float wave_scale_b = 0.026;      // ... and the broad swell layer
uniform float wave_stretch = 0.62;       // <1 stretches the ripples ALONG the flow
uniform float wave_speed_a = 0.155;
uniform float wave_speed_b = 0.068;
// The ripples have to be strong enough to BREAK the grazing reflection - that is what
// they are for. At 0.38 the far half of the river reflected one flat colour.
uniform float wave_strength : hint_range(0.0, 3.0) = 0.72;
uniform float flow_gain : hint_range(0.0, 4.0) = 1.5;
uniform float bob_amp : hint_range(0.0, 0.3) = 0.035;

group_uniforms body;
uniform vec3 shallow_color : source_color = vec3(0.286, 0.430, 0.330);
// Measured, not guessed: with deep_color at (0.020, 0.086, 0.105) the middle of the
// river rendered at luminance 0.06 from the bank at noon - a slab of wet asphalt. The
// body colour reaches the eye as IN-SCATTERED light (see scatter_gain), not as a
// lambertian bounce, so it has to be bright enough to survive on its own.
uniform vec3 deep_color : source_color = vec3(0.052, 0.118, 0.098);
uniform vec3 extinction = vec3(0.42, 0.16, 0.22);   // per metre; silt eats blue too
uniform float depth_fade = 3.2;          // metres to reach the deep colour
uniform float absorb_rate = 0.55;        // how fast the bed stops showing through
uniform float refraction : hint_range(0.0, 0.2) = 0.045;
// How much of the body colour is in-scattered rather than lit off the surface. Water is
// almost all of the former.
uniform float scatter_gain : hint_range(0.0, 2.0) = 0.62;

group_uniforms surface;
uniform vec3 foam_color : source_color = vec3(0.900, 0.925, 0.910);
uniform float foam_depth = 0.24;         // mean depth of the shore wash, metres
// The foam texture was sampled at 0.075 and 0.145 repeats per metre - a 13 m and a 7 m
// tile - so its blobs came out metres across and the plunge pool read as cotton wool
// laid on the water. Froth is a decimetre feature; these are 3.6 m and 1.4 m tiles.
uniform float foam_scale_a : hint_range(0.02, 2.0) = 0.28;
uniform float foam_scale_b : hint_range(0.02, 2.0) = 0.70;
uniform float foam_scale_wash : hint_range(0.005, 0.5) = 0.055;  // the slow lapping band
// Measured, not guessed: with roughness 0.14 and specular 0.5 the mid-river pixel from
// straight overhead at noon averaged 0.77 - the sky's own sun disc, mirrored off the
// surface, not the glitter in light() (which was worth 0.03 of that). Water's real
// normal-incidence reflectance is ~0.02, i.e. Godot SPECULAR 0.25, and a river is never
// a polished mirror, so it is roughened too.
uniform float rough_calm : hint_range(0.0, 1.0) = 0.220;
uniform float rough_churn : hint_range(0.0, 1.0) = 0.40;
uniform float specular_f0 : hint_range(0.0, 1.0) = 0.25;
// The reflection is a TWO-TONE sky, not a flat tint, and that is the whole difference
// between a river and a sheet of pale plastic. A flat stretch at a grazing angle
// reflects the horizon; every ripple that tips towards the eye reflects the zenith. The
// alternation between the two along the ripple crests is what reads as a water surface
// at 100 m, where the ripples themselves are below a pixel.
// Both are driven from SkySystem by RiverWater._refresh_sky(), so they follow the hour.
uniform vec3 sky_tint : source_color = vec3(0.42, 0.56, 0.80);      // zenith
uniform vec3 sky_horizon : source_color = vec3(0.50, 0.53, 0.56);   // near the horizon
// Fresnel-weighted, so this is worth ~2% of itself looking straight down and ~100% of
// itself at a grazing angle. At 0.05 the far half of every river went black, because
// nothing else lifts a grazing pixel: that is the ONE place real water is brightest. At
// 0.62 with a flat tint it went the other way and every river turned to milk.
uniform float sky_gain : hint_range(0.0, 2.0) = 0.34;
// A 620-power lobe at gain 14 turned the whole river white at noon: with the sun and
// the eye both near the vertical, most of the surface sits inside a 2 deg lobe. Tighter
// and much weaker reads as sparkle instead of as a blowout.
uniform float glitter_power : hint_range(8.0, 4096.0) = 1000.0;
uniform float glitter_gain : hint_range(0.0, 40.0) = 0.85;

// 0 off, 1 reconstructed depth, 2 vertex colour, 3 perturbed normal.
uniform int debug_mode : hint_range(0, 3) = 0;

void vertex() {
	// A breathing surface, deliberately tiny (<= 6 cm): the ribbon is tucked UNDER the
	// banks and a big swell would lift its edge out of the ground and show a seam.
	float ph = UV.y * 0.33 + UV.x * 0.19;
	float s = sin(ph + TIME * (0.55 + COLOR.r)) * 0.62 + sin(ph * 2.9 - TIME * 1.35) * 0.38;
	VERTEX.y += s * bob_amp * COLOR.b;
}

void fragment() {
	float flow = COLOR.r;
	float churn = COLOR.g;
	float mid = COLOR.b;
	float mask = COLOR.a;
	float t = TIME;
	float sp = 0.25 + flow * flow_gain;

	// --- ripples ----------------------------------------------------------
	// UV.x is metres ACROSS the channel, UV.y is metres DOWNSTREAM, so subtracting
	// time from .y walks the crests downstream no matter which way the river bends.
	// Fast water is stretched as well as accelerated: the crests draw out into streaks
	// down the current instead of staying round.
	float stretch = wave_stretch * (1.0 - 0.35 * flow);
	vec2 uv_a = vec2(UV.x * wave_scale_a, UV.y * wave_scale_a * stretch - t * wave_speed_a * sp);
	// The second layer samples the SAME texture transposed. water_normal is strongly
	// directional (it was synthesised from Gerstner wave families), and two copies of it
	// in the same orientation stack into a corduroy pattern with obvious repeats.
	vec2 uv_b = vec2(UV.y * wave_scale_b * (0.7 + 0.3 * stretch) - t * wave_speed_b * sp,
			UV.x * wave_scale_b + 0.37);
	vec3 na = texture(normal_tex, uv_a).xyz * 2.0 - 1.0;
	vec3 nb = texture(normal_tex, uv_b).xyz * 2.0 - 1.0;
	vec3 nt = normalize(vec3(na.xy + nb.yx * 0.55, na.z * nb.z + 0.25));
	nt = normalize(vec3(nt.xy * wave_strength * (0.65 + 0.55 * flow), nt.z));
	NORMAL_MAP = nt * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
	// Same perturbation, in view space, for the refraction offset and the Fresnel term.
	vec3 vn = normalize(TANGENT * nt.x + BINORMAL * nt.y + NORMAL * nt.z);

	// --- how thick is the water -------------------------------------------
	float raw = texture(depth_tex, SCREEN_UV).x;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(vec3(SCREEN_UV * 2.0 - 1.0, raw), 1.0);
	vp.xyz /= vp.w;
	float surf_z = -VERTEX.z;
	vec3 bed_world = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;
	vec3 surf_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float vdepth = clamp(surf_world.y - bed_world.y, 0.0, 40.0);
	// Where the water's silhouette is against the SKY there is nothing in the depth
	// buffer behind it, and the reconstruction then reports the far plane: the surface
	// comes out at maximum depth, which is to say black. That is what put a slab of ink
	// along the lip of the falls and a wall of it across the world edge
	// (water_exit_sw.png). Reverse-Z clears the depth buffer to 0, so a raw sample of 0
	// means "no geometry behind this pixel", not "infinitely far away".
	if (raw <= 1e-6 || -vp.z > 3000.0) {
		vdepth = 1.6;
	}
	// Seen from BELOW (wading, swimming) the thing behind the surface is the sky, so the
	// vertical gap is meaningless and comes out negative: the surface vanished entirely.
	// Under water it is treated as a shallow translucent ceiling instead.
	if (!FRONT_FACING) {
		vdepth = 4.0;
	}

	// The optical path is set by how THICK the water is, not by how far away the bed
	// happens to be along the view ray. Those differ by two orders of magnitude at a
	// grazing angle - the depth buffer puts the bed 40 m behind a pond that is 30 cm
	// deep - and driving absorption off the latter is what turned the middle of every
	// river into a black slab and the grove pond into a sheet of opaque plastic.
	//
	// Snell caps the refracted ray at 48.6 deg from the vertical (asin(1/1.333)), so the
	// path through the water can never exceed 1/cos(48.6) = 1.51x the thickness. That
	// bound is the whole correction.
	vec3 vdir = normalize(-VERTEX);
	float cos_i = clamp(dot(vn, vdir), 0.02, 1.0);
	float sin_r = sqrt(max(1.0 - cos_i * cos_i, 0.0)) / 1.333;
	float cos_r = sqrt(max(1.0 - sin_r * sin_r, 0.4374));
	float optical = vdepth / cos_r;

	// --- refraction -------------------------------------------------------
	float near_fade = clamp(9.0 / max(surf_z, 0.6), 0.0, 1.0);
	vec2 ruv = clamp(SCREEN_UV + vn.xy * refraction * near_fade * min(optical, 2.5),
			vec2(0.002), vec2(0.998));
	// Reject anything that is actually IN FRONT of the water: without this the rocks on
	// the bank smear across the river wherever they overlap it on screen.
	float raw2 = texture(depth_tex, ruv).x;
	vec4 vp2 = INV_PROJECTION_MATRIX * vec4(vec3(ruv * 2.0 - 1.0, raw2), 1.0);
	vp2.xyz /= vp2.w;
	if (-vp2.z < surf_z || raw2 <= 1e-6) {
		ruv = SCREEN_UV;
	}
	// `optical` deliberately keeps the UNOFFSET thickness. Re-reading it from the
	// refracted sample made the colour jump wherever that branch flipped, which showed up
	// as hard angular patches of pale and deep water across the ford.
	if (!FRONT_FACING) {
		optical = min(optical, 2.2);
	}
	// The screen read is the only texture fetch here that costs a full-resolution copy of
	// the frame; on the low tier the water gives it up and keeps everything else.
	vec3 refr = shallow_color * 1.4;
	if (use_refraction) {
		refr = textureLod(screen_tex, ruv, 0.0).rgb;
	}

	// --- body colour ------------------------------------------------------
	float deep_t = 1.0 - exp(-optical / depth_fade);
	vec3 body = mix(shallow_color, deep_color, deep_t);
	float absorb = 1.0 - exp(-optical * absorb_rate);
	vec3 through = refr * exp(-extinction * optical);

	float fres = pow(1.0 - cos_i, 5.0);
	fres = clamp(0.02 + 0.98 * fres, 0.0, 1.0);
	// Where the reflected ray points decides which part of the sky it brings back.
	vec3 refl_w = (INV_VIEW_MATRIX * vec4(reflect(-vdir, vn), 0.0)).xyz;
	vec3 sky = mix(sky_horizon, sky_tint, sqrt(clamp(refl_w.y, 0.0, 1.0)));

	// --- foam -------------------------------------------------------------
	float f1 = texture(foam_tex, vec2(UV.x * foam_scale_a,
			UV.y * foam_scale_a - t * 0.20 * sp)).r;
	float f2 = texture(foam_tex, vec2(UV.x * foam_scale_b + 0.5,
			UV.y * foam_scale_b * 0.8 - t * 0.42 * sp)).r;
	float fn = clamp(f1 * 0.70 + f2 * 0.55, 0.0, 1.0);
	// A slow, long-wavelength sample used to move the WATERLINE in and out rather than to
	// fade the foam's opacity. Modulating the opacity leaves the band tracing the mesh
	// edge in white pen - the continuous piping that ran the length of both banks; moving
	// the depth at which it starts is what makes it lap.
	float wash = texture(foam_tex, vec2(UV.x * foam_scale_wash * 2.0,
			UV.y * foam_scale_wash - t * 0.045 * sp)).r;
	float band = foam_depth * (0.16 + 1.55 * wash * wash);
	float shore = 1.0 - smoothstep(0.0, max(band, 0.02), vdepth);
	// Foam is made by water MOVING against something. A still pond gets a damp edge, not
	// a white rim, so the shore band is scaled by how fast this stretch is running.
	float moving = clamp(flow * 1.8 + churn, 0.0, 1.0);
	float shore_foam = smoothstep(0.26, 0.78, shore * (0.30 + 0.95 * fn)) * (0.06 + 0.94 * moving);
	// Churn foam is COVERAGE, not a thresholded texture. Thresholding turned the plunge
	// pool into evenly scattered white dots - confetti - because an isolated texture
	// threshold produces islands wherever it is applied uniformly. Coverage goes almost
	// solid where the fall lands (churn 1) and breaks into lace as the churn falls off,
	// which is what white water below a fall actually does.
	float churn_foam = smoothstep(0.30, 0.86, churn * (0.34 + 1.05 * f1) * (0.42 + 0.95 * wash));
	// Foam is a fine detail; kept at full strength it aliases into crawling static at
	// 200 m, where one texel of froth is a fraction of a pixel. Both bands fade out over
	// the same range the roughness already ramps across.
	float foam_far = 1.0 - 0.80 * clamp((surf_z - 60.0) / 160.0, 0.0, 1.0);
	float foam = clamp(max(shore_foam, churn_foam) * foam_far, 0.0, 1.0);

	// --- compose ----------------------------------------------------------
	ALBEDO = mix(body * absorb, foam_color, foam);
	// Three things reach the eye from a water surface, and only the last of them is a
	// lambertian bounce off ALBEDO:
	//   through   the bed, refracted and absorbed,
	//   body      light scattered back out of the water column itself,
	//   sky       the surface's own reflection, which is nearly all of it at grazing.
	EMISSION = (through * (1.0 - absorb) * (1.0 - fres * 0.85)
			+ body * scatter_gain * absorb * (1.0 - fres * 0.6)
			+ sky * sky_gain * fres) * (1.0 - foam * 0.9);
	// Mip-flattened normals plus a tight specular lobe alias into a crawling moire at
	// distance, so the surface is deliberately roughened as it recedes.
	float far = clamp((surf_z - 45.0) / 220.0, 0.0, 1.0);
	ROUGHNESS = mix(mix(rough_calm, rough_churn, clamp(churn + flow * 0.4, 0.0, 1.0)), 0.72, foam);
	ROUGHNESS = max(ROUGHNESS, far * 0.30);
	METALLIC = 0.0;
	SPECULAR = specular_f0;
	// Fade out where there is no water left to see, which is what hides the ribbon's
	// edge where it is tucked under the bank.
	ALPHA = clamp(smoothstep(0.0, 0.07, vdepth) * mask, 0.0, 1.0);
	ALPHA = max(ALPHA, foam * mask * 0.85 * step(0.015, vdepth));

	if (debug_mode == 1) {
		ALBEDO = vec3(clamp(optical / 8.0, 0.0, 1.0));
		EMISSION = vec3(0.0);
		ALPHA = 1.0;
	} else if (debug_mode == 2) {
		ALBEDO = vec3(flow, churn, mid);
		EMISSION = vec3(0.0);
		ALPHA = 1.0;
	} else if (debug_mode == 3) {
		ALBEDO = vec3(0.0);
		EMISSION = vn * 0.5 + 0.5;
		ALPHA = 1.0;
	}
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	// Godot multiplies DIFFUSE_LIGHT by ALBEDO after this function runs (verified with
	// a black-albedo probe quad: it rendered pure black), so ALBEDO is NOT multiplied
	// in here. Water has almost no lambertian term - what reads as colour is
	// in-scattered light - so the term is wrapped and weak.
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (max(ndl, 0.0) * 0.55 + 0.45) * 0.42;

	// Sun glitter: a very tight lobe on the perturbed normal, plus a broad sheen. The
	// tight lobe is what breaks up into moving sparks on the ripples, and it is bright
	// enough (> 1.0) to catch the environment's glow threshold at dusk.
	vec3 h = normalize(LIGHT + VIEW);
	float ndh = max(dot(NORMAL, h), 0.0);
	// Measured: with the sun and the eye both near the vertical, ndh is ~1 over most of
	// the surface, so a BROAD lobe here is what turned the whole river white from above -
	// a sheen of 0.22 alone took the mid-river pixel from 0.34 to 0.70. The lobe stays
	// tight even on rough water, and the broad term is only a hint.
	float p = mix(glitter_power, 110.0, clamp(ROUGHNESS * 2.2, 0.0, 1.0));
	float glit = pow(ndh, p) * glitter_gain;
	float sheen = pow(ndh, 34.0) * 0.035;
	// Foam is a diffuse crust: it must not carry the mirror highlight as well.
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * (glit + sheen) * step(0.0, ndl)
			* (1.0 - clamp(ROUGHNESS * 1.4, 0.0, 1.0));
}
