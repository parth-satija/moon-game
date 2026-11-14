shader_type sky;
// Realistic airless lunar sky.
//
//  - Pure black vacuum sky: no atmosphere, no horizon glow, no scattering halo around the sun.
//  - Sun at its true angular size (~0.53 deg) with limb darkening.
//  - Earth as a lit sphere at its true angular size (~1.9 deg): correct phase for the current sun
//    direction, continents + clouds + polar ice, ocean sun-glint, blue atmospheric limb, and a red
//    refraction ring when the Earth passes in front of the sun (an eclipse seen from the Moon).
//  - Star field with a heavy-tailed brightness distribution, star colours, and a Milky Way band
//    with dust lanes.
//
// All directions are WORLD space and point TOWARD the object. lunar_environment.gd drives them.

// ---- sun ----
uniform vec3 sun_dir = vec3(0.8, 0.25, 0.45);
uniform vec3 sun_color : source_color = vec3(1.0, 0.97, 0.92);
uniform float sun_angular_radius_deg : hint_range(0.05, 10.0) = 0.265;
uniform float sun_intensity : hint_range(1.0, 500.0) = 80.0;
uniform float sun_limb_darkening : hint_range(0.0, 1.0) = 0.6;

// ---- earth ----
uniform float earth_enabled : hint_range(0.0, 1.0) = 1.0;
uniform vec3 earth_dir = vec3(0.0, 0.0, 1.0);
uniform vec3 earth_axis = vec3(0.397, 0.918, 0.0);      // rotation axis (23.4 deg tilt)
uniform float earth_angular_radius_deg : hint_range(0.1, 20.0) = 0.95;
uniform float earth_rotation = 0.0;                      // radians, driven by the script
uniform float earth_brightness : hint_range(0.0, 8.0) = 1.6;

// ---- stars ----
uniform float star_brightness : hint_range(0.0, 8.0) = 1.5;
uniform float star_visibility : hint_range(0.0, 1.0) = 1.0;     // lowered in daylight by the script
uniform float milky_way_intensity : hint_range(0.0, 8.0) = 1.0;
uniform vec3 milky_way_normal = vec3(0.30, 0.80, 0.52);         // pole of the galactic plane
uniform vec3 milky_way_core = vec3(0.74, -0.22, -0.63);         // toward the galactic centre

// ------------------------------------------------------------------ noise
float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash13(i);
	float b = hash13(i + vec3(1.0, 0.0, 0.0));
	float c = hash13(i + vec3(0.0, 1.0, 0.0));
	float d = hash13(i + vec3(1.0, 1.0, 0.0));
	float e = hash13(i + vec3(0.0, 0.0, 1.0));
	float g = hash13(i + vec3(1.0, 0.0, 1.0));
	float h = hash13(i + vec3(0.0, 1.0, 1.0));
	float k = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(a, b, f.x), mix(c, d, f.x), f.y),
			mix(mix(e, g, f.x), mix(h, k, f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec3(11.7, 5.3, 8.1);
		a *= 0.5;
	}
	return s;
}

vec3 rot_axis(vec3 v, vec3 a, float t) {
	float c = cos(t);
	float sn = sin(t);
	return v * c + cross(a, v) * sn + a * dot(a, v) * (1.0 - c);
}

// ------------------------------------------------------------------ stars
// One layer of point stars on a 3D cell grid. Most stars are faint, a few are bright.
vec3 star_layer(vec3 d, float scale, float density, float seed, float radius, float boost) {
	vec3 p = d * scale;
	vec3 id = floor(p);
	vec3 f = p - id;
	if (hash13(id + seed) > density * boost) {
		return vec3(0.0);
	}
	vec3 c = vec3(hash13(id + seed + 1.7), hash13(id + seed + 5.3), hash13(id + seed + 9.1)) * 0.4 + 0.3;
	float flux = pow(hash13(id + seed + 13.3), 10.0);               // heavy-tailed magnitudes
	float bright = 0.12 + 3.2 * flux;
	float rad = radius * (0.65 + 0.35 * min(bright, 1.0));
	float x = clamp(length(f - c) / rad, 0.0, 1.0);
	float falloff = (1.0 - x) * (1.0 - x);
	float temp = hash13(id + seed + 21.1);
	vec3 tint = temp < 0.2 ? vec3(1.0, 0.74, 0.55) : (temp < 0.75 ? vec3(1.0, 0.97, 0.92) : vec3(0.72, 0.82, 1.0));
	return tint * falloff * bright;
}

// ------------------------------------------------------------------ earth
// Draws the Earth over whatever is behind it (stars, the sun), plus its limb glow.
vec3 earth_over(vec3 d, vec3 s, vec3 under) {
	vec3 e = normalize(earth_dir);
	float R = radians(earth_angular_radius_deg);
	float sR = sin(R);
	if (dot(d, e) <= 0.0 || length(cross(d, e)) > sR * 1.2) {
		return under;
	}
	vec3 aux = abs(e.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 u = normalize(cross(aux, e));
	vec3 v = cross(e, u);
	vec2 p = vec2(dot(d, u), dot(d, v)) / sR;
	float r = length(p);
	float disc = 1.0 - smoothstep(0.97, 1.0, r);

	vec3 result = under;

	// Glow just outside the limb: blue scattered light on the sunlit side, plus the red ring of
	// sunlight refracted through the atmosphere when the sun is hidden behind the Earth.
	if (r > 0.97) {
		vec3 limb_w = normalize(p.x * u + p.y * v + u * 1e-5);
		float outside = exp(-max(r - 1.0, 0.0) * 38.0) * smoothstep(0.97, 1.0, r);
		float lit_side = smoothstep(-0.3, 0.7, dot(limb_w, s));
		result += vec3(0.25, 0.48, 1.0) * earth_brightness * 0.5 * outside * lit_side * (1.0 - disc);

		float sep = acos(clamp(dot(e, s), -1.0, 1.0));
		float ecl = 1.0 - smoothstep(0.0, R * 1.15, sep);
		float ring = exp(-max(r - 1.0, 0.0) * 70.0) * smoothstep(0.97, 1.0, r);
		result += vec3(1.0, 0.30, 0.07) * 3.0 * ecl * ring * (1.0 - disc);
	}

	if (disc > 0.0) {
		float z = sqrt(max(1.0 - r * r, 0.0));
		vec3 n = normalize(p.x * u + p.y * v - z * e);     // surface normal, facing the Moon
		vec3 a = normalize(earth_axis);
		vec3 bp = rot_axis(n, a, -earth_rotation);         // body-fixed coordinates
		float lat = abs(dot(bp, a));

		float cont = fbm(bp * 1.7 + vec3(3.1, 7.7, 1.3));
		float land = smoothstep(0.50, 0.55, cont);
		float veg = fbm(bp * 4.5 + vec3(9.0, 2.0, 5.0));
		vec3 ground = mix(vec3(0.34, 0.27, 0.14), vec3(0.07, 0.17, 0.05), smoothstep(0.38, 0.60, veg));
		vec3 ocean = mix(vec3(0.012, 0.045, 0.17), vec3(0.03, 0.12, 0.28), smoothstep(0.40, 0.50, cont));
		vec3 surf = mix(ocean, ground, land);

		float ice = smoothstep(0.86, 0.93, lat + 0.07 * (fbm(bp * 6.0) - 0.5));
		surf = mix(surf, vec3(0.86, 0.89, 0.93), ice);

		vec3 cp = rot_axis(n, a, -earth_rotation * 1.05);   // clouds drift slightly relative to the ground
		float cl = fbm(cp * 3.4 + vec3(4.0, 1.0, 9.0)) + 0.12 * sin(dot(bp, a) * 14.0);
		float cov = smoothstep(0.50, 0.70, cl) * 0.92;
		surf = mix(surf, vec3(0.90, 0.92, 0.95), cov);

		float ndl = dot(n, s);
		float diff = max(ndl, 0.0);
		vec3 radiance = surf * diff;

		// sun glint on open ocean
		vec3 hv = normalize(s - e + vec3(1e-5));
		float glint = pow(max(dot(n, hv), 0.0), 240.0) * (1.0 - land) * (1.0 - cov) * step(0.0, ndl);
		radiance += vec3(1.0, 0.97, 0.90) * glint * 3.0;

		// atmosphere: blue limb on the lit side, a thin warm band along the terminator
		float rim = pow(1.0 - z, 2.2);
		float atm_lit = smoothstep(-0.25, 0.45, ndl);
		radiance += vec3(0.22, 0.45, 1.0) * rim * atm_lit * 1.2;
		radiance += vec3(1.0, 0.42, 0.18) * rim * exp(-ndl * ndl * 40.0) * 0.45;

		result = mix(result, radiance * earth_brightness, disc);
	}
	return result;
}

// ------------------------------------------------------------------ sky
void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 s = normalize(sun_dir);
	vec3 col = vec3(0.0);

	// Milky Way: a soft band with a brighter, warmer bulge and dark dust lanes.
	vec3 mn = normalize(milky_way_normal);
	vec3 mc = normalize(milky_way_core - mn * dot(milky_way_core, mn));
	float gl = dot(d, mn);
	float band = exp(-(gl * gl) / 0.0288);
	if (band > 0.02) {
		float gc = max(dot(d, mc), 0.0);
		float bulge = gc * gc * gc;
		float dust = fbm(d * 5.0 + vec3(2.0));
		float lanes = smoothstep(0.46, 0.66, fbm(d * 10.0 + vec3(7.7, 1.1, 3.3)));
		float glow = band * (0.35 + 1.1 * bulge) * (0.45 + 1.1 * dust);
		glow *= 1.0 - 0.7 * lanes;
		vec3 mw_col = mix(vec3(0.72, 0.82, 1.0), vec3(1.0, 0.86, 0.68), clamp(bulge * 1.5, 0.0, 1.0));
		col += mw_col * glow * 0.055 * milky_way_intensity;
	}

	// Stars, denser along the galactic plane.
	float boost = 1.0 + 2.5 * band;
	vec3 stars = star_layer(d, 60.0, 0.035, 0.0, 0.14, boost)
			+ star_layer(d, 130.0, 0.04, 40.0, 0.26, boost)
			+ 0.5 * star_layer(d, 280.0, 0.03, 90.0, 0.30, boost);
	col += stars * star_brightness;
	col *= star_visibility;

	// Sun: true angular size, limb darkened, no atmospheric glare (glow comes from the camera bloom).
	if (dot(d, s) > 0.0) {
		float sr = sin(radians(sun_angular_radius_deg));
		float rr = length(cross(d, s)) / sr;
		if (rr < 1.2) {
			float edge = 1.0 - smoothstep(0.88, 1.0, rr);
			float mu = sqrt(max(1.0 - rr * rr, 0.0));
			float limb = 1.0 - sun_limb_darkening * (1.0 - mu);
			col += sun_color * sun_intensity * limb * edge;
		}
	}

	// Earth sits in front of the stars and the sun, so it occludes both.
	if (earth_enabled > 0.5) {
		col = earth_over(d, s, col);
	}

	COLOR = max(col, vec3(0.0));
}
