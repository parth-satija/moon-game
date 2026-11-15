shader_type canvas_item;
// Orthographic view of the Moon's NEAR (front) side, centred on lon 0 / lat 0, drawn from the
// equirectangular colour map. Same lon/lat convention as moon.gd: lon = atan2(x, z), lat = asin(y).

uniform sampler2D moon_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float grid_alpha = 0.15;
uniform float grid_step_deg = 15.0;

void fragment() {
	vec2 p = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);     // disc coords: x east, y north
	float rr = length(p);
	float edge = 1.0 - smoothstep(1.0 - fwidth(rr) * 1.5, 1.0, rr);
	if (rr >= 1.0) {
		COLOR = vec4(0.0);
	} else {
		float z = sqrt(1.0 - rr * rr);                       // toward the viewer, so lon stays in -90..90
		float lon = atan(p.x, z);
		float lat = asin(clamp(p.y, -1.0, 1.0));
		vec3 c = texture(moon_tex, vec2(lon / TAU + 0.5, 0.5 - lat / PI)).rgb;

		vec2 g = vec2(lon, lat) / radians(grid_step_deg);
		vec2 d = abs(fract(g - 0.5) - 0.5) / max(fwidth(g), vec2(0.0001));
		float line = 1.0 - min(min(d.x, d.y), 1.0);
		c = mix(c, vec3(1.0), line * grid_alpha);

		c *= 0.55 + 0.45 * z;                                // gentle limb darkening so it reads as a sphere
		COLOR = vec4(c, edge);
	}
}
