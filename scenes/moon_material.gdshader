shader_type spatial;
render_mode specular_disabled;

// Physically-motivated lunar regolith with real 3D micro-relief.
//
// LIGHTING (light() at the bottom): the Moon does not behave like a Lambertian surface. Its soil is
// a porous, very dark powder, so brightness barely falls off toward the terminator and distant
// ground is not darker than near ground. This uses the lunar-Lambert / Lommel-Seeliger model
// (McEwen) plus an opposition surge: the bright "hot spot" around your own shadow when the sun is
// directly behind you. No specular, no toon bands, no outlines. On top of that the sun is
// ray-marched through the micro height field, so boulders, pebbles and crater rims cast shadows.
//
// SURFACE: scalar albedo (real values, ~0.06 dark mare ... ~0.3 fresh ejecta) from the photo map or
// the LRO/LOLA topography model, then
//   - 3D relief: a procedural height field (craters, angular boulders, pebbles, soil) between
//     6 cm and 2 m that is parallax-ray-marched per pixel, plus analytic normals above 2 m and
//     powder grain down to ~4 mm. No geometry is added, so collision is unaffected,
//   - albedo variation: maturity patches, fresh bright ejecta, fine grain, bright steep slopes
//     (mass wasting exposes fresh soil), darker boulder contact zones.
// Terrain displacement (vertex()) is unchanged and must stay in sync with moon.gd.

// ---- albedo (visible-light, physical range) ----
uniform float use_vertex_color = 1.0;                 // set by moon.gd
uniform vec3 fallback_color : source_color = vec3(0.55, 0.55, 0.53);
uniform float albedo_gain : hint_range(0.2, 3.0) = 1.0;
uniform float albedo_dark : hint_range(0.0, 0.5) = 0.06;       // darkest mare
uniform float albedo_bright : hint_range(0.05, 0.8) = 0.28;    // brightest highlands / fresh ejecta
uniform float lum_min : hint_range(0.0, 1.0) = 0.05;           // vertex-color luminance mapped to albedo_dark
uniform float lum_max : hint_range(0.0, 1.0) = 0.6;            // ... and albedo_bright

// ---- far-range photo map (equirectangular, same layout as the heightmap) ----
uniform sampler2D moon_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float tex_amount : hint_range(0.0, 1.0) = 1.0;      // 0 = topography/vertex-color albedo, 1 = photo map
uniform float tex_gain : hint_range(0.2, 4.0) = 1.0;
uniform float tex_contrast : hint_range(0.5, 2.0) = 1.1;
uniform float tex_lod_bias : hint_range(0.0, 3.0) = 0.75;   // >0 = blurrier map from afar (stops shimmer)
uniform float color_strength : hint_range(0.0, 4.0) = 2.0;  // how strongly the map's colour is applied (0 = grey, >1 exaggerates)
uniform float far_exposure : hint_range(0.1, 1.0) = 0.5;   // exposure multiplier when viewed from far away (stops the whole globe blowing out to white)

// ---- reflectance model ----
uniform float exposure_gain : hint_range(0.5, 6.0) = 2.4;          // camera exposure for sunlit ground (soil albedo is ~0.1)
uniform float ls_weight : hint_range(0.0, 1.0) = 0.85;             // 1 = pure Lommel-Seeliger (flat-looking Moon), 0 = Lambert
uniform float opposition_strength : hint_range(0.0, 2.0) = 0.7;    // brightness boost at zero phase angle
uniform float opposition_width : hint_range(0.01, 0.5) = 0.05;     // ~tan(half the surge angle)

// ---- topography -> albedo model (LRO / LOLA trends, see the notes at topo_km) ----
uniform sampler2D height_tex : filter_linear_mipmap, repeat_enable;
uniform float use_topo_albedo = 0.0;               // set by moon.gd once the height texture exists
uniform float h_mean = 1.0;                        // heightmap mean radius (model units)
uniform float km_per_unit = 1.0;                   // model units -> REAL km (exaggeration removed)
uniform vec2 tex_size = vec2(8192.0, 4096.0);
uniform float texel_m = 1330.0;                    // metres per heightmap texel (game world)
uniform vec3 off_full = vec3(0.0);                 // true position of the engine origin

uniform float albedo_highland : hint_range(0.02, 0.6) = 0.19;
uniform float albedo_mare : hint_range(0.02, 0.6) = 0.085;
uniform float mare_elev_full_km : hint_range(-8.0, 4.0) = -1.5;
uniform float mare_elev_none_km : hint_range(-8.0, 6.0) = 0.5;
uniform float smooth_full_deg : hint_range(0.0, 10.0) = 1.0;
uniform float smooth_none_deg : hint_range(0.5, 20.0) = 4.0;
uniform float rough_lod : hint_range(0.0, 6.0) = 2.0;
uniform float lowland_rough_floor : hint_range(0.0, 1.0) = 0.25;
uniform float slope_bright_start_deg : hint_range(0.0, 40.0) = 12.0;
uniform float slope_bright_full_deg : hint_range(1.0, 60.0) = 32.0;
uniform float slope_bright_gain : hint_range(0.0, 1.5) = 0.3;

// ---- surface detail ----
uniform float detail_albedo : hint_range(0.0, 1.0) = 0.6;         // strength of maturity patches and grain
uniform float detail_normal : hint_range(0.0, 3.0) = 1.0;         // strength of all normal relief
uniform float regolith_amount : hint_range(0.0, 3.0) = 1.0;       // fine soil bumps
uniform float crater_amount : hint_range(0.0, 3.0) = 1.0;
uniform float crater_density : hint_range(0.0, 1.0) = 0.55;
uniform float rock_amount : hint_range(0.0, 3.0) = 1.0;
uniform float rock_density : hint_range(0.0, 1.0) = 0.28;
uniform float fresh_ejecta : hint_range(0.0, 3.0) = 1.0;          // brightness of young craters

// ---- 3D micro-relief (parallax ray-march + self-shadowing) ----
uniform float relief_height : hint_range(0.25, 2.0) = 1.0;         // scales the height of all marched relief
uniform float parallax_distance : hint_range(2.0, 120.0) = 45.0;   // ray-march fades out by this distance (m)
uniform float parallax_steps : hint_range(4.0, 32.0) = 12.0;       // max march steps per pixel (cost!)
uniform float shadow_distance : hint_range(2.0, 120.0) = 60.0;     // micro-shadows fade out by this distance (m)
uniform float shadow_steps : hint_range(2.0, 16.0) = 8.0;          // steps toward the sun per pixel (cost!)
uniform float shadow_softness : hint_range(0.005, 0.2) = 0.03;     // penumbra width (real sun is ~0.01)
uniform float micro_shadow_strength : hint_range(0.0, 1.0) = 1.0;
uniform float micro_shadow_fill : hint_range(0.0, 0.5) = 0.1;      // brightness kept inside micro-shadows
uniform float grain_normal : hint_range(0.0, 3.0) = 1.0;           // powder grain, 4 mm .. 6 cm

// True position of the engine origin, reduced in doubles on the CPU (moon.gd).
uniform vec3 off_a = vec3(0.0);   // mod 4096 m
uniform vec3 off_b = vec3(0.0);   // mod 262144 m

varying vec3 v_col;

// ============================================================================
// VERTEX DISPLACEMENT -- DO NOT CHANGE without changing moon.gd (it mirrors this on the CPU for
// collision). Everything from here down to vertex() is identical to the previous shader.
// ============================================================================
uniform float vtx_amount = 0.0;
uniform float vtx_slope = 0.06;
uniform float vtx_bumps = 1.0;
uniform float vtx_bump_density = 0.4;
uniform float vtx_crater_depth = 1.0;
uniform float vtx_crater_density = 0.45;
uniform float vtx_first_ring = 3.0;
uniform float vtx_near = 8.0;        // within this distance of the player the displacement fade is constant
uniform vec3 vtx_player = vec3(0.0); // player position in mesh-local space (updated every frame by moon.gd)
uniform float vtx_spread = 0.049;
uniform vec3 vmo_a = vec3(0.0);      // mesh origin true position, mod 4096 m
uniform vec3 vmo_b = vec3(0.0);      // ... mod 262144 m
uniform vec3 vmo_full = vec3(0.0);   // ... unreduced (only used for the radial direction)

uniform float vtx_far_amount : hint_range(0.0, 3.0) = 1.0;
uniform float vtx_far_crater_density : hint_range(0.0, 1.0) = 0.35;
uniform float vtx_far_crater_depth : hint_range(0.0, 2.0) = 1.0;

uint pcg(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float h01(uint h) {
	return float(h >> 8u) * (1.0 / 16777216.0);
}

// Hash of lattice cell c, wrapped every (mask + 1) cells.
uint ihash(ivec3 c, int mask, uint seed) {
	ivec3 w = c & ivec3(mask);
	return pcg(uint(w.x) + pcg(uint(w.y) + pcg(uint(w.z) + seed)));
}

// 3D value noise with analytic derivative: (value 0..1, d/dp in cell units).
vec4 vn(vec3 p, int mask, uint seed) {
	vec3 fl = floor(p);
	ivec3 i = ivec3(fl);
	vec3 f = p - fl;
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec3 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);

	float a = h01(ihash(i, mask, seed));
	float b = h01(ihash(i + ivec3(1, 0, 0), mask, seed));
	float c = h01(ihash(i + ivec3(0, 1, 0), mask, seed));
	float d = h01(ihash(i + ivec3(1, 1, 0), mask, seed));
	float e = h01(ihash(i + ivec3(0, 0, 1), mask, seed));
	float f1 = h01(ihash(i + ivec3(1, 0, 1), mask, seed));
	float g = h01(ihash(i + ivec3(0, 1, 1), mask, seed));
	float h = h01(ihash(i + ivec3(1, 1, 1), mask, seed));

	float k1 = b - a;
	float k2 = c - a;
	float k3 = e - a;
	float k4 = a - b - c + d;
	float k5 = a - c - e + g;
	float k6 = a - b - e + f1;
	float k7 = -a + b + c - d + e - f1 - g + h;

	float v = a + k1 * u.x + k2 * u.y + k3 * u.z
			+ k4 * u.x * u.y + k5 * u.y * u.z + k6 * u.z * u.x
			+ k7 * u.x * u.y * u.z;
	vec3 dv = du * vec3(
			k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
			k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
			k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y);
	return vec4(v, dv);
}

// Rolling relief octave: wavelength ~ cell, steepness set by vtx_slope. -> (height, gradient)
vec4 und_octave(vec3 p, float cell, int mask, uint seed, float s) {
	float fade = smoothstep(2.0 * s, 6.0 * s, cell);
	if (fade <= 0.0) {
		return vec4(0.0);
	}
	float amp = vtx_slope * cell * 0.35 * fade;
	vec4 n = vn(p / cell, mask, seed);
	return vec4(amp * (n.x - 0.5), amp * n.yzw / cell);
}

// Random small mounds (70%) and shallow hollows (30%), smooth compact bumps.
vec4 bump_layer(vec3 p, float cell, int mask, uint seed, float s) {
	float fade = smoothstep(2.0 * s, 6.0 * s, cell * 0.4);
	if (fade <= 0.0 || vtx_bumps <= 0.0) {
		return vec4(0.0);
	}
	vec3 q = p / cell;
	vec3 fl = floor(q);
	ivec3 i0 = ivec3(fl);
	ivec3 st = ivec3(step(vec3(0.5), q - fl) * 2.0 - 1.0);
	vec4 acc = vec4(0.0);

	for (int a = 0; a < 2; a++) {
		for (int b = 0; b < 2; b++) {
			for (int c = 0; c < 2; c++) {
				ivec3 cc = i0 + ivec3(a, b, c) * st;
				uint h0 = ihash(cc, mask, seed);
				if (h01(h0) > vtx_bump_density) {
					continue;
				}
				uint r1 = pcg(h0);
				uint r2 = pcg(r1);
				uint r3 = pcg(r2);
				uint r4 = pcg(r3);
				uint r5 = pcg(r4);
				uint r6 = pcg(r5);
				vec3 center = vec3(cc) + 0.2 + 0.6 * vec3(h01(r1), h01(r2), h01(r3));
				vec3 dv = (q - center) * cell;
				float R = cell * (0.08 + 0.2 * h01(r4));
				float x2 = dot(dv, dv) / (R * R);
				if (x2 >= 1.0) {
					continue;
				}
				float H = R * (0.05 + 0.15 * h01(r6)) * (h01(r5) < 0.7 ? 1.0 : -0.6);
				float w = 1.0 - x2;
				acc.x += fade * H * w * w;
				acc.yzw += fade * H * (-4.0 * w) * dv / (R * R);
			}
		}
	}
	return acc * vtx_bumps;
}

// Craters: parabolic bowl with a raised rim.
vec4 vcrater_layer(vec3 p, float cell, int mask, uint seed, float s) {
	float fade = smoothstep(2.0 * s, 6.0 * s, cell * 0.2);
	if (fade <= 0.0 || vtx_crater_depth <= 0.0) {
		return vec4(0.0);
	}
	vec3 q = p / cell;
	vec3 fl = floor(q);
	ivec3 i0 = ivec3(fl);
	ivec3 st = ivec3(step(vec3(0.5), q - fl) * 2.0 - 1.0);
	vec4 acc = vec4(0.0);

	for (int a = 0; a < 2; a++) {
		for (int b = 0; b < 2; b++) {
			for (int c = 0; c < 2; c++) {
				ivec3 cc = i0 + ivec3(a, b, c) * st;
				uint h0 = ihash(cc, mask, seed);
				if (h01(h0) > vtx_crater_density) {
					continue;
				}
				uint r1 = pcg(h0);
				uint r2 = pcg(r1);
				uint r3 = pcg(r2);
				uint r4 = pcg(r3);
				uint r5 = pcg(r4);
				vec3 center = vec3(cc) + 0.15 + 0.7 * vec3(h01(r1), h01(r2), h01(r3));
				vec3 dv = (q - center) * cell;
				float dl = max(length(dv), 1e-4);
				float R = cell * (0.07 + 0.2 * h01(r4));
				float x = dl / R;
				if (x > 1.9) {
					continue;
				}
				float dr = mix(0.05, 0.14, h01(r5)) * vtx_crater_depth;
				float inside = x < 1.0 ? 1.0 : 0.0;
				float t = (x - 1.0) / 0.3;
				float rim = 0.35 * dr * exp(-t * t);
				float f = inside * dr * (x * x - 1.0) + rim;
				float df = inside * dr * 2.0 * x + rim * (-2.0 * t / 0.3);
				acc.x += fade * R * f;
				acc.yzw += fade * df * (dv / dl);
			}
		}
	}
	return acc;
}

// Realistic large craters: bowl, raised rim, power-law ejecta blanket falling off with distance,
// and a central peak on about a third of them. Heights/gradients are analytic like the layers above.
vec4 vcrater_real(vec3 p, float cell, int mask, uint seed, float s, float density, float depth_scale) {
	float fade = smoothstep(2.0 * s, 6.0 * s, cell * 0.2);
	if (fade <= 0.0 || vtx_far_crater_depth <= 0.0) {
		return vec4(0.0);
	}
	vec3 q = p / cell;
	vec3 fl = floor(q);
	ivec3 i0 = ivec3(fl);
	ivec3 st = ivec3(step(vec3(0.5), q - fl) * 2.0 - 1.0);
	vec4 acc = vec4(0.0);

	for (int a = 0; a < 2; a++) {
		for (int b = 0; b < 2; b++) {
			for (int c = 0; c < 2; c++) {
				ivec3 cc = i0 + ivec3(a, b, c) * st;
				uint h0 = ihash(cc, mask, seed);
				if (h01(h0) > density) {
					continue;
				}
				uint r1 = pcg(h0);
				uint r2 = pcg(r1);
				uint r3 = pcg(r2);
				uint r4 = pcg(r3);
				uint r5 = pcg(r4);
				uint r6 = pcg(r5);
				vec3 center = vec3(cc) + 0.15 + 0.7 * vec3(h01(r1), h01(r2), h01(r3));
				vec3 dv = (q - center) * cell;
				float dl = max(length(dv), 1e-4);
				float R = cell * (0.07 + 0.2 * h01(r4));
				float x = dl / R;
				if (x > 1.9) {
					continue;
				}
				float dr = mix(0.05, 0.14, h01(r5)) * depth_scale * vtx_far_crater_depth;

				// raised rim (both sides of x = 1)
				float t = (x - 1.0) / 0.3;
				float rim = 0.35 * dr * exp(-t * t);
				float f = rim;
				float df = rim * (-2.0 * t / 0.3);

				if (x < 1.0) {
					// parabolic bowl
					f += dr * (x * x - 1.0);
					df += dr * 2.0 * x;
					// central peak
					if (h01(r6) < 0.35) {
						float pk = 0.45 * dr * exp(-(x * x) / 0.02);
						f += pk;
						df += pk * (-2.0 * x / 0.02);
					}
				} else {
					// ejecta blanket: ~1/x^3 falloff, faded out by the lookup cutoff
					float u = clamp((x - 1.2) / 0.7, 0.0, 1.0);
					float sm = u * u * (3.0 - 2.0 * u);
					float dsm = x > 1.2 ? 6.0 * u * (1.0 - u) / 0.7 : 0.0;
					float e0 = 0.10 * dr * pow(x, -3.0);
					f += e0 * (1.0 - sm);
					df += (-3.0 * e0 / x) * (1.0 - sm) - e0 * dsm;
				}
				acc.x += fade * R * f;
				acc.yzw += fade * df * (dv / dl);
			}
		}
	}
	return acc;
}

void vertex() {
	v_col = COLOR.rgb;

	// ---- terrain displacement (see vertex displacement above) ----
	float vd = length(VERTEX);                       // distance from the mesh centre
	if (vtx_amount > 0.0 && vd < 40000.0) {
		float dp = length(VERTEX - vtx_player);          // distance from the PLAYER, so re-centring the mesh changes nothing
		float s = max(dp, vtx_near) * vtx_spread;       // local vertex spacing (constant near the player)
		vec3 pA = VERTEX + vmo_a;
		vec3 pB = VERTEX + vmo_b;
		vec4 hg = vec4(0.0);
		hg += vcrater_layer(pB, 1024.0, 255, 11u, s);
		hg += vcrater_layer(pB, 128.0, 2047, 23u, s);
		hg += bump_layer(pA, 16.0, 255, 31u, s);
		hg += bump_layer(pA, 4.0, 1023, 47u, s);
		hg += und_octave(pB, 128.0, 2047, 59u, s);
		hg += und_octave(pB, 32.0, 8191, 71u, s);
		hg += und_octave(pA, 8.0, 511, 83u, s);
		hg += und_octave(pA, 2.0, 2047, 97u, s);

		// Large-scale relief: big craters with rims, ejecta and central peaks, plus broad rolling
		// terrain. Always on and fixed in world space (no distance ramp from the player), so these
		// shapes never follow you; only the resolution fade (s) drops them far away. moon.gd mirrors
		// this exactly (_far_height) for collision.
		float wf = vtx_far_amount;
		if (wf > 0.0) {
			vec4 hf = vec4(0.0);
			hf += vcrater_real(pB, 16384.0, 15, 101u, s, vtx_far_crater_density * 0.6, 0.55);
			hf += vcrater_real(pB, 8192.0, 31, 107u, s, vtx_far_crater_density * 0.8, 0.7);
			hf += vcrater_real(pB, 4096.0, 63, 113u, s, vtx_far_crater_density, 0.85);
			hf += vcrater_real(pB, 2048.0, 127, 127u, s, vtx_far_crater_density, 1.0);
			hf += und_octave(pB, 4096.0, 63, 131u, s);
			hf += und_octave(pB, 1024.0, 255, 137u, s);
			hf += und_octave(pB, 512.0, 511, 139u, s);
			hf += und_octave(pB, 256.0, 1023, 149u, s);
			hg += hf * (wf / max(vtx_amount, 1e-4));   // cancels the vtx_amount scaling below
		}
		hg *= vtx_amount;

		vec3 up = normalize(VERTEX + vmo_full);
		VERTEX += up * hg.x;

		// smooth shading: tilt the normal by the displacement's analytic slope
		vec3 g = hg.yzw;
		g -= NORMAL * dot(g, NORMAL);
		NORMAL = normalize(NORMAL - g);
	}
}

// ============================================================================
// FRAGMENT: 3D regolith
//
// Layers of relief, by scale:
//   >= 2 m   analytic normal perturbation (crater_layer / rock_layer / regolith_macro). These sit
//            on top of the real vertex-displaced terrain and only tilt the surface.
//   6 cm..2 m  a true procedural HEIGHT FIELD (relief()): craters, angular boulders, pebbles and
//            soil undulation. It is ray-marched per pixel (parallax occlusion with refinement), so
//            rocks hide what is behind them, crater walls slide against the floor as you move, and
//            everything casts real micro-shadows toward the sun (see light()).
//   < 6 cm   analytic grain: fine powder / pitting normals down to ~4 mm.
// All fine layers live in true planet space (like before), so they stay glued to the ground.
// ============================================================================
vec3 srgb_to_linear(vec3 c) {
	vec3 lo = c / 12.92;
	vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
	return mix(hi, lo, step(c, vec3(0.04045)));
}

// Height-field limits (metres, before relief_height). Rocks rise above the local plane, craters sink.
const float RELIEF_UP = 0.26;
const float RELIEF_DOWN = 0.12;

// ---- cheap integer hash for the fragment layers (the vertex code keeps pcg for CPU parity) ----
uint hq(ivec3 c, int mask, uint seed) {
	uvec3 w = uvec3(c & ivec3(mask));
	uint h = w.x * 374761393u + w.y * 668265263u + w.z * 2246822519u + seed * 3266489917u;
	h = (h ^ (h >> 15u)) * 2246822519u;
	h = (h ^ (h >> 13u)) * 3266489917u;
	return h ^ (h >> 16u);
}

float hb(uint h, uint s) {
	return float((h >> s) & 255u) * (1.0 / 255.0);
}

float h24(uint h) {
	return float(h >> 8u) * (1.0 / 16777216.0);
}

// 3D value noise, value only (0..1).
float vnv(vec3 p, int mask, uint seed) {
	vec3 fl = floor(p);
	ivec3 i = ivec3(fl);
	vec3 f = p - fl;
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = h24(hq(i, mask, seed));
	float b = h24(hq(i + ivec3(1, 0, 0), mask, seed));
	float c = h24(hq(i + ivec3(0, 1, 0), mask, seed));
	float d = h24(hq(i + ivec3(1, 1, 0), mask, seed));
	float e = h24(hq(i + ivec3(0, 0, 1), mask, seed));
	float f1 = h24(hq(i + ivec3(1, 0, 1), mask, seed));
	float g = h24(hq(i + ivec3(0, 1, 1), mask, seed));
	float h = h24(hq(i + ivec3(1, 1, 1), mask, seed));
	return mix(mix(mix(a, b, u.x), mix(c, d, u.x), u.y),
			mix(mix(e, f1, u.x), mix(g, h, u.x), u.y), u.z);
}

// 3D value noise with analytic derivative: (value, d/dp in cell units).
vec4 vng(vec3 p, int mask, uint seed) {
	vec3 fl = floor(p);
	ivec3 i = ivec3(fl);
	vec3 f = p - fl;
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec3 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	float a = h24(hq(i, mask, seed));
	float b = h24(hq(i + ivec3(1, 0, 0), mask, seed));
	float c = h24(hq(i + ivec3(0, 1, 0), mask, seed));
	float d = h24(hq(i + ivec3(1, 1, 0), mask, seed));
	float e = h24(hq(i + ivec3(0, 0, 1), mask, seed));
	float f1 = h24(hq(i + ivec3(1, 0, 1), mask, seed));
	float g = h24(hq(i + ivec3(0, 1, 1), mask, seed));
	float h = h24(hq(i + ivec3(1, 1, 1), mask, seed));
	float k1 = b - a;
	float k2 = c - a;
	float k3 = e - a;
	float k4 = a - b - c + d;
	float k5 = a - c - e + g;
	float k6 = a - b - e + f1;
	float k7 = -a + b + c - d + e - f1 - g + h;
	float v = a + k1 * u.x + k2 * u.y + k3 * u.z
			+ k4 * u.x * u.y + k5 * u.y * u.z + k6 * u.z * u.x
			+ k7 * u.x * u.y * u.z;
	vec3 dv = du * vec3(
			k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
			k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
			k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y);
	return vec4(v, dv);
}

// ---------------------------------------------------------------------------
// Macro layers: analytic gradients (normal-only). Same as the previous shader.
// All return (height_m, d/dx, d/dy, d/dz) in world units.
// ---------------------------------------------------------------------------

// Soil undulation from 4 m and 2 m. Finer octaves are part of the height field below.
vec4 regolith_macro(vec3 pA, float px) {
	vec4 acc = vec4(0.0);
	float cell = 4.0;
	int mask = 1023;
	for (int o = 0; o < 2; o++) {
		float fade = smoothstep(1.5 * px, 6.0 * px, cell);
		if (fade <= 0.0) {
			break;
		}
		float amp = 0.09 * cell * fade;
		vec4 n = vn(pA / cell, mask, 300u + uint(o) * 13u);
		acc.x += amp * (n.x - 0.5);
		acc.yzw += amp * n.yzw / cell;
		cell *= 0.5;
		mask = mask * 2 + 1;
	}
	return acc;
}

// One scale of impact craters (8 nearest cells of a jittered 3D grid), analytic gradient.
// bright = fresh-ejecta strength.
vec4 crater_layer(vec3 p, float cell, int mask, uint seed, float px, out float bright) {
	bright = 0.0;
	float fade = smoothstep(2.0 * px, 8.0 * px, cell * 0.27);
	if (fade <= 0.0 || crater_density <= 0.0) {
		return vec4(0.0);
	}
	vec3 q = p / cell;
	vec3 fl = floor(q);
	ivec3 i0 = ivec3(fl);
	ivec3 st = ivec3(step(vec3(0.5), q - fl) * 2.0 - 1.0);
	vec4 acc = vec4(0.0);

	for (int a = 0; a < 2; a++) {
		for (int b = 0; b < 2; b++) {
			for (int c = 0; c < 2; c++) {
				ivec3 cc = i0 + ivec3(a, b, c) * st;
				uint h0 = ihash(cc, mask, seed);
				if (h01(h0) > crater_density) {
					continue;
				}
				uint r1 = pcg(h0);
				uint r2 = pcg(r1);
				uint r3 = pcg(r2);
				uint r4 = pcg(r3);
				uint r5 = pcg(r4);
				uint r6 = pcg(r5);
				vec3 center = vec3(cc) + 0.15 + 0.7 * vec3(h01(r1), h01(r2), h01(r3));
				vec3 dv = (q - center) * cell;
				float dl = max(length(dv), 1e-4);
				float R = cell * (0.07 + 0.2 * h01(r4));
				float x = dl / R;
				if (x > 1.9) {
					continue;
				}
				float age = h01(r6);                                  // 0 fresh .. 1 old
				float dr = mix(0.07, 0.2, h01(r5)) * mix(1.0, 0.4, age);
				float rw = mix(0.2, 0.5, age);                        // rim width: crisp -> soft
				float inside = x < 1.0 ? 1.0 : 0.0;
				float t = (x - 1.0) / rw;
				float rim = 0.35 * dr * exp(-t * t);
				float f = inside * dr * (x * x - 1.0) + rim;
				float df = inside * dr * 2.0 * x + rim * (-2.0 * t / rw);
				acc.x += fade * R * f;
				acc.yzw += fade * df * (dv / dl);

				float fresh = pow(h01(r5), 2.0) * (1.0 - age) * (1.0 - age);
				bright = max(bright, fade * fresh * (1.0 - smoothstep(0.9, 1.9, x)));
			}
		}
	}
	return acc;
}

// One scale of big boulders (analytic, blunt domes). Used for 8 m and 32 m cells only.
vec4 rock_layer(vec3 p, float cell, int mask, uint seed, float px, out float tone, out float ink) {
	tone = 0.0;
	ink = 0.0;
	float fade = smoothstep(2.0 * px, 6.0 * px, cell * 0.25);
	if (fade <= 0.0 || rock_density <= 0.0) {
		return vec4(0.0);
	}
	vec3 q = p / cell;
	vec3 fl = floor(q);
	ivec3 i0 = ivec3(fl);
	ivec3 st = ivec3(step(vec3(0.5), q - fl) * 2.0 - 1.0);
	vec4 acc = vec4(0.0);

	for (int a = 0; a < 2; a++) {
		for (int b = 0; b < 2; b++) {
			for (int c = 0; c < 2; c++) {
				ivec3 cc = i0 + ivec3(a, b, c) * st;
				uint h0 = ihash(cc, mask, seed);
				if (h01(h0) > rock_density) {
					continue;
				}
				uint r1 = pcg(h0);
				uint r2 = pcg(r1);
				uint r3 = pcg(r2);
				uint r4 = pcg(r3);
				vec3 center = vec3(cc) + 0.2 + 0.6 * vec3(h01(r1), h01(r2), h01(r3));
				vec3 dv = (q - center) * cell;
				float R = cell * (0.08 + 0.17 * h01(r4) * h01(r4));
				float x2 = dot(dv, dv) / (R * R);
				if (x2 >= 1.0) {
					continue;
				}
				float sw = sqrt(max(1.0 - x2, 1e-3));
				acc.x += fade * 0.7 * R * sw;
				acc.yzw += fade * (-0.7 * dv / (R * sw));
				tone += fade * (h01(pcg(r3)) * 2.0 - 1.0);
				ink = max(ink, fade * smoothstep(0.5, 0.98, x2));
			}
		}
	}
	return acc;
}

// ---------------------------------------------------------------------------
// Height field (metres) for 6 cm .. 2 m features. Height only, so it is cheap enough to ray-march.
// attrs = also accumulate albedo attributes (only requested once per pixel, at the hit point).
// ---------------------------------------------------------------------------

// Craters: parabolic bowl, raised rim, soft ejecta skirt. Young craters are deep and crisp,
// old ones shallow and rounded. bright = fresh-ejecta strength.
float crater_h(vec3 p, float cell, int mask, uint seed, float px, inout float bright, bool attrs) {
	float fade = smoothstep(2.0 * px, 8.0 * px, cell * 0.27);
	if (fade <= 0.0 || crater_density <= 0.0) {
		return 0.0;
	}
	vec3 q = p / cell;
	vec3 fl = floor(q);
	ivec3 i0 = ivec3(fl);
	ivec3 st = ivec3(step(vec3(0.5), q - fl) * 2.0 - 1.0);
	float acc = 0.0;
	for (int a = 0; a < 2; a++) {
		for (int b = 0; b < 2; b++) {
			for (int c = 0; c < 2; c++) {
				ivec3 cc = i0 + ivec3(a, b, c) * st;
				uint h0 = hq(cc, mask, seed);
				if (float(h0 >> 24u) * (1.0 / 256.0) > crater_density) {
					continue;
				}
				vec3 center = vec3(cc) + 0.15 + 0.7 * vec3(hb(h0, 0u), hb(h0, 8u), hb(h0, 16u));
				vec3 dv = (q - center) * cell;
				if (dot(dv, dv) > 0.27 * cell * cell) {
					continue;                                          // beyond 1.9 * the largest radius
				}
				uint h1 = (h0 ^ (h0 >> 15u)) * 2246822519u;
				h1 ^= h1 >> 13u;
				float R = cell * (0.07 + 0.2 * hb(h1, 0u));
				float x = length(dv) / R;
				if (x > 1.9) {
					continue;
				}
				float age = hb(h1, 16u);                               // 0 fresh .. 1 old
				float dr = mix(0.08, 0.3, hb(h1, 8u)) * mix(1.0, 0.3, age * age);
				float rw = mix(0.18, 0.5, age);                        // rim width: crisp -> soft
				float t = (x - 1.0) / rw;
				float rim = 0.35 * dr * exp(-t * t);
				float f = rim;
				if (x < 1.0) {
					f += dr * (x * x - 1.0);
				} else {
					f += 0.05 * dr * pow(x, -3.0) * (1.0 - smoothstep(1.3, 1.9, x));   // ejecta skirt
				}
				acc += fade * R * f;
				if (attrs) {
					float fresh = hb(h1, 8u) * hb(h1, 8u) * (1.0 - age) * (1.0 - age);
					bright = max(bright, fade * fresh * (1.0 - smoothstep(0.9, 1.9, x)));
				}
			}
		}
	}
	return acc;
}

// Angular boulders: half-buried superellipsoids (exponent < 2 gives edges and facets), each with its
// own proportions. Returns the tallest rock above the point. tone = lighter/darker than soil,
// ink = dark contact zone at the base.
float rock_h(vec3 p, float cell, int mask, uint seed, float px, float dens, inout float tone, inout float ink, bool attrs) {
	float fade = smoothstep(2.0 * px, 6.0 * px, cell * 0.2);
	if (fade <= 0.0 || dens <= 0.0) {
		return 0.0;
	}
	vec3 q = p / cell;
	vec3 fl = floor(q);
	ivec3 i0 = ivec3(fl);
	ivec3 st = ivec3(step(vec3(0.5), q - fl) * 2.0 - 1.0);
	float top = 0.0;
	for (int a = 0; a < 2; a++) {
		for (int b = 0; b < 2; b++) {
			for (int c = 0; c < 2; c++) {
				ivec3 cc = i0 + ivec3(a, b, c) * st;
				uint h0 = hq(cc, mask, seed);
				if (float(h0 >> 24u) * (1.0 / 256.0) > dens) {
					continue;
				}
				vec3 center = vec3(cc) + 0.2 + 0.6 * vec3(hb(h0, 0u), hb(h0, 8u), hb(h0, 16u));
				vec3 dv = (q - center) * cell;
				uint h1 = (h0 ^ (h0 >> 15u)) * 2246822519u;
				h1 ^= h1 >> 13u;
				float rr = hb(h1, 0u);
				float R = cell * (0.06 + 0.1 * rr * rr);
				vec3 an = vec3(0.75 + 0.55 * hb(h1, 8u), 0.75 + 0.55 * hb(h1, 16u), 0.75 + 0.55 * hb(h1, 24u));
				vec3 ext = R * an;
				// exact early-out: the shape gauge is never below the largest normalised coordinate
				if (any(greaterThanEqual(abs(dv), ext))) {
					continue;
				}
				uint h2 = (h1 ^ (h1 >> 16u)) * 3266489917u;
				h2 ^= h2 >> 15u;
				float e = 1.3 + 0.9 * hb(h2, 0u);                      // 1.3 angular .. 2.2 rounded
				vec3 aq = abs(dv) / ext;
				float s = pow(pow(aq.x, e) + pow(aq.y, e) + pow(aq.z, e), 1.0 / e);
				if (s >= 1.0) {
					continue;
				}
				float rh = 0.78 * R * sqrt(1.0 - s * s);
				top = max(top, fade * rh);
				if (attrs) {
					tone += fade * (hb(h2, 8u) * 2.0 - 1.0);
					ink = max(ink, fade * smoothstep(0.55, 0.98, s));
				}
			}
		}
	}
	return top;
}

// Soil: value-noise undulation from 1 m down to 12 cm. Finer powder comes from grain_grad().
float soil_h(vec3 pA, float px) {
	float h = 0.0;
	float cell = 1.0;
	int mask = 4095;
	for (int o = 0; o < 4; o++) {
		float fade = smoothstep(1.5 * px, 6.0 * px, cell);
		if (fade <= 0.0) {
			break;
		}
		h += 0.08 * cell * fade * (vnv(pA / cell, mask, 500u + uint(o) * 7u) - 0.5);
		cell *= 0.5;
		mask = mask * 2 + 1;
	}
	return h;
}

// Total marched height above the local plane. Positions are true planet-space coordinates:
// pA wraps every 4096 m, pC every 64 m (kept small for millimetre precision).
float relief(vec3 pA, vec3 pC, float px, bool attrs, inout float bright, inout float tone, inout float ink) {
	float h = 0.0;
	if (crater_amount > 0.0) {
		float hc = crater_h(pA, 1.0, 4095, 229u, px, bright, attrs);
		hc += crater_h(pA, 0.25, 16383, 233u, px, bright, attrs);
		hc += crater_h(pC, 0.0625, 1023, 239u, px, bright, attrs);
		h += hc * crater_amount;
	}
	h += soil_h(pA, px) * regolith_amount;
	if (rock_amount > 0.0) {
		// Each 3D cell is sliced by the ground plane, so only a fraction of rocks show; the gate is
		// scaled up so rock_density reads as "rocks per square metre of ground".
		float rd = min(1.0, rock_density * 3.2);
		float hr = rock_h(pA, 2.0, 2047, 257u, px, rd, tone, ink, attrs);
		hr = max(hr, rock_h(pA, 0.5, 8191, 263u, px, rd, tone, ink, attrs));
		hr = max(hr, rock_h(pC, 0.125, 511, 269u, px, rd, tone, ink, attrs));
		h += hr * rock_amount;
	}
	return clamp(h * relief_height, -RELIEF_DOWN * relief_height, RELIEF_UP * relief_height);
}

// Fine powder / pitting: analytic gradient only (heights below 3 mm are invisible as parallax).
// Returns d(height)/d(world position).
vec3 grain_grad(vec3 pC, float px) {
	vec3 g = vec3(0.0);
	float cell = 0.0625;
	int mask = 1023;
	for (int o = 0; o < 4; o++) {
		float fade = smoothstep(1.5 * px, 6.0 * px, cell);
		if (fade <= 0.0) {
			break;
		}
		vec4 n = vng(pC / cell, mask, 600u + uint(o) * 11u);
		g += (o == 0 ? 0.06 : 0.1) * fade * n.yzw;
		cell *= 0.5;
		mask = mask * 2 + 1;
	}
	return g;
}

// Ray-march the height field. The ray enters the relief slab at its top and descends; sv is the
// horizontal shift of the sample point per unit of height. Returns the hit height (relative to
// the local plane). The final bracket is refined by false position.
float march_relief(vec3 pA0, vec3 pC0, vec3 sv, float px, int steps) {
	float U = RELIEF_UP * relief_height;
	float D = RELIEF_DOWN * relief_height;
	float d0 = 0.0;
	float d1 = 0.0;
	float d2 = 0.0;
	float dh = (U + D) / float(steps);
	float h_prev = U;
	float d_prev = U - relief(pA0 + sv * U, pC0 + sv * U, px, false, d0, d1, d2);
	float hit = -D;
	for (int i = 1; i <= 32; i++) {
		if (i > steps) {
			break;
		}
		float h = U - dh * float(i);
		float d = h - relief(pA0 + sv * h, pC0 + sv * h, px, false, d0, d1, d2);
		if (d <= 0.0) {
			float a = h_prev;
			float da = d_prev;
			float b = h;
			float db = d;
			float m = b;
			for (int k = 0; k < 2; k++) {
				m = a + (b - a) * da / (da - db);
				float dm = m - relief(pA0 + sv * m, pC0 + sv * m, px, false, d0, d1, d2);
				if (dm > 0.0) {
					a = m;
					da = dm;
				} else {
					b = m;
					db = dm;
				}
			}
			hit = m;
			break;
		}
		h_prev = h;
		d_prev = d;
	}
	return hit;
}

const float MOON_R_KM = 1737.4;

// Elevation in real km relative to the datum, from heightmap mip `lod`.
float topo_km(vec3 d, float lod) {
	float lon = atan(d.x, d.z);
	float lat = asin(clamp(d.y, -1.0, 1.0));
	vec2 uv = vec2(lon / TAU + 0.5, clamp(0.5 - lat / PI, 0.0005, 0.9995));
	return (textureLod(height_tex, uv, lod).r - h_mean) * km_per_unit;
}

// Slope (rise/run, in real units) over a baseline of 2 texels at mip `lod`.
float topo_slope(vec3 d, float lod) {
	vec3 up = abs(d.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t1 = normalize(cross(up, d));
	vec3 t2 = cross(d, t1);
	float a = (PI / tex_size.y) * exp2(lod);
	float ca = cos(a);
	float sa = sin(a);
	float h1 = topo_km(d * ca + t1 * sa, lod);
	float h2 = topo_km(d * ca - t1 * sa, lod);
	float h3 = topo_km(d * ca + t2 * sa, lod);
	float h4 = topo_km(d * ca - t2 * sa, lod);
	return length(vec2(h1 - h2, h3 - h4)) / (2.0 * a * MOON_R_KM);
}

// Hand-off from fragment() to light(): where the pixel really is on the height field, and the
// frame needed to turn the (view-space) light direction back into planet space.
varying vec3 v_pA;
varying vec3 v_pC;
varying vec3 v_np;
varying vec3 v_bx;
varying vec3 v_by;
varying vec3 v_bz;
varying float v_h;
varying float v_px;
varying float v_sh;       // micro-shadow weight (fades to 0 with distance)
varying float v_far;      // 0 near .. 1 far (orbit views)

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 pA = wp + off_a;
	vec3 pB = wp + off_b;
	vec3 pC = wp + mod(off_a, vec3(64.0));
	float dist = length(VERTEX);
	float px = max(dist * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y), 1e-4);   // metres per pixel here

	// ---------------- macro relief (normal perturbation, >= 2 m) ----------------
	vec4 hg = vec4(0.0);
	float bright = 0.0;
	float tone = 0.0;
	float ink = 0.0;
	float b = 0.0;
	float r = 0.0;

	// Large normal-only craters (4..256 m) removed: they only tilted the shading, so their
	// shadows disagreed with the sun. Craters now come from the real height field + vertex terrain.

	hg += rock_layer(pA, 32.0, 127, 241u, px, b, r) * rock_amount;      tone += b; ink = max(ink, r);
	hg += rock_layer(pA, 8.0, 511, 251u, px, b, r) * rock_amount;       tone += b; ink = max(ink, r);

	hg += regolith_macro(pA, px) * regolith_amount;

	vec3 nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 gm = hg.yzw * detail_normal;
	gm -= nw * dot(gm, nw);
	gm *= min(1.0, 2.5 / max(length(gm), 1e-4));
	vec3 np = normalize(nw - gm);              // local ground plane for the height field

	// ---------------- 3D relief: ray-march the height field ----------------
	vec3 camw = INV_VIEW_MATRIX[3].xyz;
	vec3 rd = normalize(wp - camw);
	vec3 tt = normalize(cross(np, abs(np.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 bb = cross(np, tt);

	float w_par = 1.0 - smoothstep(0.75 * parallax_distance, parallax_distance, dist);
	float hh = 0.0;
	vec3 sv = vec3(0.0);
	if (w_par > 0.02 && parallax_steps >= 1.0) {
		float cosv = max(-dot(rd, np), 0.24);
		vec3 rh = rd - np * dot(rd, np);
		sv = -rh / cosv * w_par;
		int steps = int(parallax_steps);   // fixed count: a view-dependent count made the hit point (and lighting) shift as you turn
		hh = march_relief(pA, pC, sv, px, steps);
	}
	vec3 pAh = pA + sv * hh;
	vec3 pBh = pB + sv * hh;
	vec3 pCh = pC + sv * hh;

	// normal of the height field at the hit (forward differences one pixel wide)
	float eps = max(px * 0.6, 0.0006);
	float d0 = 0.0;
	float d1 = 0.0;
	float d2 = 0.0;
	float h0 = relief(pAh, pCh, px, true, bright, tone, ink);
	float hx = relief(pAh + tt * eps, pCh + tt * eps, px, false, d0, d1, d2);
	float hy = relief(pAh + bb * eps, pCh + bb * eps, px, false, d0, d1, d2);
	vec3 gh = (tt * (hx - h0) + bb * (hy - h0)) / eps;
	gh += grain_grad(pCh, px) * grain_normal;
	// Sub-metre relief is smaller than a pixel far away; left in, it aliases into black grains on
	// sun-facing slopes. Fade it out with distance (large forms come from the terrain mesh).
	float dfade = 1.0 - smoothstep(20.0, 80.0, dist);
	gh *= detail_normal * dfade;
	bright *= dfade;
	tone *= dfade;
	ink *= dfade;
	gh -= np * dot(gh, np);
	gh *= min(1.0, 2.5 / max(length(gh), 1e-4));
	nw = normalize(np - gh);
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);

	// ---------------- hand-off to light() ----------------
	v_pA = pAh;
	v_pC = pCh;
	v_np = np;
	v_bx = (INV_VIEW_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz;
	v_by = (INV_VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	v_bz = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz;
	v_h = h0;
	v_px = px;
	v_far = smoothstep(1500.0, 60000.0, dist);
	v_sh = (1.0 - smoothstep(0.75 * shadow_distance, shadow_distance, dist)) * micro_shadow_strength;

	// ---------------- far-field albedo (scalar) ----------------
	vec3 base = mix(fallback_color, srgb_to_linear(v_col), use_vertex_color);
	float lum = dot(base, vec3(0.2126, 0.7152, 0.0722));
	float A = mix(albedo_dark, albedo_bright, clamp((lum - lum_min) / max(lum_max - lum_min, 1e-4), 0.0, 1.0));

	vec3 dn = normalize(wp + off_full);       // local "up" on the sphere
	vec3 tint = vec3(1.0);
	if (use_topo_albedo > 0.5) {
		// Sampled at a mip matched to the pixel footprint (and never sharper than ~4 texels) so the
		// 1.3 km heightmap cannot show texel creases up close.
		float lod_px = max(log2(px / texel_m), 2.0);
		float z_km = topo_km(dn, lod_px);
		float s_rough = degrees(atan(topo_slope(dn, max(lod_px, rough_lod))));
		float p_low = 1.0 - smoothstep(mare_elev_full_km, mare_elev_none_km, z_km);
		float p_smooth = 1.0 - smoothstep(smooth_full_deg, smooth_none_deg, s_rough);
		float p_mare = p_low * mix(lowland_rough_floor, 1.0, p_smooth);   // mare = low AND smooth
		A = mix(albedo_highland, albedo_mare, p_mare);
	}

	// Photo map wrapped around the globe (blurred at a mip matched to the pixel footprint).
	if (tex_amount > 0.0) {
		vec2 tuv = vec2(atan(dn.x, dn.z) / TAU + 0.5, clamp(0.5 - asin(clamp(dn.y, -1.0, 1.0)) / PI, 0.0005, 0.9995));
		float graze = 1.0 / max(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.1);
		float tlod = max(log2(px / texel_m) + 0.5 * log2(graze) + tex_lod_bias, 1.0);
		vec3 tc = textureLod(moon_tex, tuv, tlod).rgb;           // linear colour from the map
		float tv = dot(tc, vec3(0.2126, 0.7152, 0.0722));        // its brightness drives albedo
		tv = clamp(clamp((tv - 0.18) * tex_contrast + 0.18, 0.0, 1.0) * tex_gain, 0.0, 1.0);
		A = mix(A, mix(albedo_dark, albedo_bright, tv), tex_amount);
		// chromaticity of the map (colour relative to its own brightness), applied on top of albedo
		vec3 ratio = clamp(tc / max(dot(tc, vec3(0.2126, 0.7152, 0.0722)), 0.02), vec3(0.4), vec3(2.5));
		tint = pow(ratio, vec3(tex_amount * color_strength));
	}

	// ---------------- albedo variation (evaluated where the ray really hit) ----------------
	// Maturity patches at several scales; each fades out once finer than a pixel (no shimmer).
	float pvar = 0.0;
	pvar += 0.45 * (vnv(pBh / 1024.0, 255, 401u) - 0.5) * smoothstep(2.0 * px, 8.0 * px, 1024.0);
	pvar += 0.50 * (vnv(pBh / 128.0, 2047, 409u) - 0.5) * smoothstep(2.0 * px, 8.0 * px, 128.0);
	float f8 = smoothstep(2.0 * px, 8.0 * px, 8.0);
	if (f8 > 0.0) {
		pvar += 0.45 * (vnv(pAh / 8.0, 511, 419u) - 0.5) * f8;
	}
	float f1 = smoothstep(2.0 * px, 8.0 * px, 1.0);
	if (f1 > 0.0) {
		pvar += 0.30 * (vnv(pAh / 1.0, 4095, 421u) - 0.5) * f1;
	}
	// Fine grain (down to 4 mm): the speckle of real regolith in close-ups.
	float grain = 0.0;
	float fg0 = smoothstep(2.0 * px, 8.0 * px, 0.25);
	if (fg0 > 0.0) {
		grain += (vnv(pAh / 0.25, 16383, 431u) - 0.5) * fg0;
		float fg1 = smoothstep(2.0 * px, 8.0 * px, 0.0625);
		if (fg1 > 0.0) {
			grain += (vnv(pCh / 0.0625, 1023, 433u) - 0.5) * fg1;
			float fg2 = smoothstep(2.0 * px, 8.0 * px, 0.0156);
			if (fg2 > 0.0) {
				grain += (vnv(pCh / 0.0156, 4095, 437u) - 0.5) * fg2;
			}
		}
	}

	// Steep slopes shed mature soil, exposing brighter material: crater walls and rims glow.
	float slope = degrees(acos(clamp(dot(nw, dn), -1.0, 1.0)));
	A *= 1.0 + slope_bright_gain * smoothstep(slope_bright_start_deg, slope_bright_full_deg, slope);

	float alb = A * albedo_gain * (1.0 + detail_albedo * pvar + 0.5 * detail_albedo * grain);
	alb *= 1.0 + 1.4 * fresh_ejecta * bright;                 // young craters: bright ejecta
	alb *= 1.0 + 0.35 * clamp(tone, -1.0, 1.0);               // boulders: lighter or darker than soil
	alb *= 1.0 - 0.3 * ink;                                   // dark contact zone around boulders

	// Subtle colour: dark mare a touch cool, bright highland/ejecta a touch warm, never saturated.
	vec3 chroma = mix(vec3(0.94, 0.955, 1.0), vec3(1.0, 0.965, 0.915), clamp((A - 0.06) / 0.22, 0.0, 1.0));

	ALBEDO = clamp(alb * chroma * tint, vec3(0.0), vec3(1.0));
	ROUGHNESS = 1.0;
	AO = clamp(1.0 - 0.6 * ink, 0.0, 1.0);
}

// ============================================================================
// LIGHTING: lunar-Lambert (Lommel-Seeliger blend) + opposition surge + micro self-shadowing.
// ============================================================================

// Soft shadow of the height field toward the light. Marches the plane-space sample point along
// the light ray with relaxed (clearance-based) steps; the penumbra widens with distance like the
// real sun's disc. Returns 1 lit .. 0 shadowed.
float micro_shadow(vec3 Lw, float steps_f) {
	float lz = dot(Lw, v_np);
	if (lz <= 0.02) {
		return 1.0;
	}
	vec3 lh = Lw - v_np * lz;
	float U = RELIEF_UP * relief_height;
	float s_end = min((U - v_h) / lz, 3.0);
	float s = 0.006;                      // fixed start: shadows must not depend on how far away the pixel is
	int n = int(steps_f);
	float vis = 1.0;
	float d0 = 0.0;
	float d1 = 0.0;
	float d2 = 0.0;
	for (int i = 0; i < 16; i++) {
		if (i >= n || s >= s_end) {
			break;
		}
		float hr = v_h + lz * s;
		float px_s = 0.004 + s * 0.02;          // fixed detail level (not the pixel size), so shadows do not change with distance/zoom
		float H = relief(v_pA + lh * s, v_pC + lh * s, px_s, false, d0, d1, d2);
		float clr = hr - H;                                   // clearance of the ray above the ground
		vis = min(vis, smoothstep(0.0, 1.0, (clr + 0.0015) / (s * shadow_softness + 0.003)));
		if (vis <= 0.01) {
			break;
		}
		// Relaxed stepping: a feature taller than the clearance is also wider than the step, so
		// jumping by the clearance cannot skip it. Close to the ground the steps stay small.
		s += max(clr * 0.9, s * 0.1 + 0.003);
	}
	return vis;
}

void light() {
	float mu0 = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);        // cos incidence
	float mu = clamp(dot(NORMAL, VIEW), 0.001, 1.0);        // cos emission

	// Lommel-Seeliger: 2*mu0/(mu0+mu), equal to 1 at normal incidence and view. Values above 1
	// (grazing views) are soft-capped at 1.6 so distant ground does not blow out.
	float ls = 2.0 * mu0 / (mu0 + mu);
	ls = ls > 1.0 ? 1.0 + 0.6 * (1.0 - exp(-(ls - 1.0))) : ls;
	float f = mix(mu0, ls, ls_weight);

	// Opposition surge: brightening when the phase angle -> 0 (sun behind the viewer).
	float cg = dot(LIGHT, VIEW);
	float tg = sqrt(max(1.0 - cg, 0.0) / max(1.0 + cg, 1e-4));    // tan(phase / 2)
	float surge = 1.0 + opposition_strength / (1.0 + tg / opposition_width);

	// Micro self-shadowing from the height field (only for the sun, not faint fill lights).
	float vis = 1.0;
	if (LIGHT_IS_DIRECTIONAL && v_sh > 0.001 && shadow_steps >= 2.0 && mu0 > 0.0
			&& max(LIGHT_COLOR.r, max(LIGHT_COLOR.g, LIGHT_COLOR.b)) > 0.5) {
		vec3 Lw = normalize(LIGHT.x * v_bx + LIGHT.y * v_by + LIGHT.z * v_bz);
		// micro_shadow_fill: light scattered into the shadow by neighbouring soil, so shadows are not pure black
		vis = mix(1.0, mix(micro_shadow_fill, 1.0, micro_shadow(Lw, shadow_steps)), v_sh);
	}

	DIFFUSE_LIGHT += LIGHT_COLOR / PI * ATTENUATION * f * surge * exposure_gain * mix(1.0, far_exposure, v_far) * vis;
}
