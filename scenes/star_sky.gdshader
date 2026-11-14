shader_type sky;
// Black lunar sky: no atmosphere, a field of hard stars, and a small bright sun disc.

uniform vec3 sun_dir = vec3(0.8, 0.25, 0.45);   // set by moon_walk.gd (direction toward the sun)
uniform float star_brightness : hint_range(0.0, 4.0) = 1.3;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

vec3 star_layer(vec3 d, float scale, float density, float seed, float radius) {
	vec3 p = d * scale;
	vec3 id = floor(p);
	vec3 f = p - id;
	if (hash13(id + seed) > density) {
		return vec3(0.0);
	}
	vec3 c = vec3(hash13(id + seed + 1.7), hash13(id + seed + 5.3), hash13(id + seed + 9.1)) * 0.6 + 0.2;
	float s = 1.0 - smoothstep(0.0, radius, length(f - c));
	float mag = pow(hash13(id + seed + 13.3), 3.0);              // a few bright ones, many faint
	vec3 tint = mix(vec3(1.0, 0.86, 0.76), vec3(0.76, 0.86, 1.0), hash13(id + seed + 21.1));
	return tint * s * (0.25 + 1.6 * mag);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 col = star_layer(d, 110.0, 0.10, 0.0, 0.30) + star_layer(d, 55.0, 0.06, 40.0, 0.22);
	col *= star_brightness;

	float s = dot(d, normalize(sun_dir));
	float disc = smoothstep(0.99998, 0.999985, s);
	float glare = pow(clamp(s, 0.0, 1.0), 1500.0) * 0.8;
	col += vec3(1.0, 0.97, 0.9) * (disc * 40.0 + glare);

	COLOR = col;
}
