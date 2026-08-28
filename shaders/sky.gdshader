shader_type sky;
render_mode use_half_res_pass;

// Procedural sky for the Vale. Drives dawn / day / dusk / night from one elevation
// parameter so the whole cycle stays consistent: sky, sun disc, moon, stars, clouds
// and the horizon haze all move together.

uniform vec3 zenith_day   : source_color = vec3(0.16, 0.36, 0.72);
uniform vec3 horizon_day  : source_color = vec3(0.72, 0.80, 0.88);
uniform vec3 zenith_night : source_color = vec3(0.020, 0.038, 0.086);
uniform vec3 horizon_night: source_color = vec3(0.060, 0.082, 0.140);
uniform vec3 dusk_glow    : source_color = vec3(1.00, 0.42, 0.16);
uniform vec3 ground_color : source_color = vec3(0.12, 0.10, 0.08);

uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 moon_dir = vec3(0.0, -1.0, 0.0);
uniform float sun_elev = 1.0;            // -1 .. 1
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float star_intensity : hint_range(0.0, 4.0) = 1.0;
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.45;
uniform float cloud_speed = 0.004;
uniform float haze : hint_range(0.0, 1.0) = 0.35;
uniform vec3 haze_color : source_color = vec3(0.80, 0.76, 0.66);

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i);
	float n100 = hash13(i + vec3(1, 0, 0));
	float n010 = hash13(i + vec3(0, 1, 0));
	float n110 = hash13(i + vec3(1, 1, 0));
	float n001 = hash13(i + vec3(0, 0, 1));
	float n101 = hash13(i + vec3(1, 0, 1));
	float n011 = hash13(i + vec3(0, 1, 1));
	float n111 = hash13(i + vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
	           mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float up = d.y;
	float t = clamp(up * 1.15 + 0.06, 0.0, 1.0);

	// --- base gradient ---------------------------------------------------
	vec3 zen = mix(zenith_night, zenith_day, 1.0 - night);
	vec3 hor = mix(horizon_night, horizon_day, 1.0 - night);
	vec3 col = mix(hor, zen, pow(t, 0.62));

	// --- warm band near the sun's azimuth at low elevation ---------------
	float sun_cos = dot(d, sun_dir);
	float dusk = smoothstep(0.42, -0.05, abs(sun_elev)) ;
	float band = pow(clamp(1.0 - abs(up) * 3.0, 0.0, 1.0), 1.6);
	float toward = pow(clamp(sun_cos * 0.5 + 0.5, 0.0, 1.0), 3.5);
	col += dusk_glow * dusk * band * toward * 1.5;
	col += dusk_glow * dusk * pow(clamp(1.0 - abs(up) * 1.7, 0.0, 1.0), 3.0) * 0.30;

	// --- sun disc + bloom ------------------------------------------------
	float above = smoothstep(-0.12, 0.02, sun_elev);
	float disc = smoothstep(0.99955, 0.99985, sun_cos);
	float glow = pow(clamp(sun_cos, 0.0, 1.0), 220.0) * 0.9 + pow(clamp(sun_cos, 0.0, 1.0), 14.0) * 0.16;
	vec3 sun_col = mix(vec3(1.0, 0.52, 0.22), vec3(1.0, 0.96, 0.88), smoothstep(0.02, 0.35, sun_elev));
	col += sun_col * (disc * 22.0 + glow * 2.4) * above;

	// --- moon ------------------------------------------------------------
	float moon_cos = dot(d, moon_dir);
	float m_above = smoothstep(-0.10, 0.04, moon_dir.y);
	float m_disc = smoothstep(0.9993, 0.99965, moon_cos);
	// A shallow crater mottle so the disc is not a flat white dot.
	float craters = fbm(d * 900.0) * 0.35 + 0.75;
	col += vec3(0.88, 0.90, 1.0) * m_disc * craters * 5.0 * m_above * night;
	col += vec3(0.55, 0.62, 0.85) * pow(clamp(moon_cos, 0.0, 1.0), 90.0) * 0.55 * m_above * night;

	// --- stars -----------------------------------------------------------
	if (night > 0.01 && up > -0.05) {
		vec3 sd = d * 260.0;
		vec3 cell = floor(sd);
		float r = hash13(cell);
		if (r > 0.9885) {
			vec3 jit = vec3(hash13(cell + 11.0), hash13(cell + 23.0), hash13(cell + 37.0));
			float dd = length(fract(sd) - jit);
			float mag = hash13(cell + 5.0);
			float tw = 0.72 + 0.28 * sin(TIME * (1.4 + mag * 3.0) + mag * 30.0);
			float s = smoothstep(0.30, 0.0, dd) * (0.25 + mag * mag * 1.1) * tw;
			// Faint colour variation between hot and cool stars.
			vec3 sc = mix(vec3(1.0, 0.86, 0.72), vec3(0.78, 0.86, 1.0), hash13(cell + 71.0));
			col += sc * s * star_intensity * night * smoothstep(-0.05, 0.25, up);
		}
		// The Milky Way as a broad noisy band.
		float mw = pow(clamp(1.0 - abs(dot(d, normalize(vec3(0.55, 0.42, -0.72)))), 0.0, 1.0), 7.0);
		col += vec3(0.42, 0.46, 0.62) * mw * fbm(d * 9.0) * 0.16 * night;
	}

	// --- clouds ----------------------------------------------------------
	if (up > 0.005) {
		vec3 cp = vec3(d.xz / (up + 0.14) * 0.75, 0.0);
		cp.xy += vec2(TIME * cloud_speed, TIME * cloud_speed * 0.42);
		float n = fbm(vec3(cp.xy, TIME * cloud_speed * 0.5) * 1.6);
		float cov = smoothstep(0.62 - cloud_cover * 0.42, 0.86 - cloud_cover * 0.28, n);
		cov *= smoothstep(0.005, 0.16, up);
		// Light the cloud from the sun side, keep the base in shadow.
		float lit = clamp(dot(normalize(vec3(d.x, 0.35, d.z)), sun_dir) * 0.5 + 0.5, 0.0, 1.0);
		vec3 bright = mix(vec3(0.55, 0.56, 0.60), vec3(1.02, 0.98, 0.94), lit);
		bright = mix(bright * 0.28, bright, 1.0 - night);
		bright += dusk_glow * dusk * lit * 0.85;
		col = mix(col, bright, cov * 0.88);
	}

	// --- horizon haze ----------------------------------------------------
	float hz = pow(clamp(1.0 - abs(up) * 2.6, 0.0, 1.0), 2.4);
	col = mix(col, mix(haze_color * 0.22, haze_color, 1.0 - night), hz * haze);

	// --- ground hemisphere ------------------------------------------------
	col = mix(col, ground_color * mix(0.25, 1.0, 1.0 - night), smoothstep(0.0, -0.10, up));

	COLOR = col;
}
