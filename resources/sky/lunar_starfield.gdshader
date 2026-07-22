shader_type sky;

// No TIME. LIGHT0_* forces sky refresh when DirectionalLight3D moves
// (same +Z vector Godot uses for scene lighting — see light_storage.cpp).

uniform vec3 space_color : source_color = vec3(0.002, 0.003, 0.008);
uniform float star_density : hint_range(0.5, 8.0, 0.1) = 2.4;
uniform float star_brightness : hint_range(0.2, 3.0, 0.05) = 1.25;
uniform vec3 galactic_normal = vec3(0.22, 0.48, 0.85);
uniform float plane_star_boost : hint_range(0.0, 12.0, 0.1) = 5.0;
uniform float plane_width : hint_range(0.02, 0.35, 0.005) = 0.1;
uniform float dust_strength : hint_range(0.0, 1.0, 0.01) = 0.72;
uniform float bulge_strength : hint_range(0.0, 2.0, 0.01) = 0.55;
uniform vec3 bulge_warm : source_color = vec3(1.0, 0.86, 0.72);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.88);
uniform float sun_angular_diameter_deg : hint_range(0.2, 6.0, 0.05) = 2.0;
uniform float sun_core_energy : hint_range(0.0, 20.0, 0.1) = 10.0;
uniform float sun_corona_energy : hint_range(0.0, 8.0, 0.05) = 1.8;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i);
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	float nxy0 = mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y);
	float nxy1 = mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y);
	return mix(nxy0, nxy1, f.z);
}

float fbm3(vec3 p) {
	float s = 0.5 * value_noise(p);
	s += 0.25 * value_noise(p * 2.07 + vec3(17.1, 9.3, 3.7));
	s += 0.125 * value_noise(p * 4.28 + vec3(3.1, 7.9, 11.2));
	return s;
}

// 3x3x3 neighbor search is expensive; 2x2x2 keeps the look, much cheaper.
float star_layer(vec3 dir, float scale, float threshold, float sharpness) {
	vec3 p = dir * scale;
	vec3 cell = floor(p);
	vec3 f = fract(p);
	float best = 0.0;
	for (int z = 0; z < 2; z++) {
		for (int y = 0; y < 2; y++) {
			for (int x = 0; x < 2; x++) {
				vec3 o = vec3(float(x), float(y), float(z));
				vec3 g = cell + o;
				float h = hash13(g);
				if (h > threshold) {
					continue;
				}
				vec3 r = o + vec3(hash13(g + 1.7), hash13(g + 3.1), hash13(g + 5.9)) - f;
				float d = length(r);
				float mag = 1.0 - h / max(threshold, 0.001);
				best = max(best, exp(-d * d * sharpness) * mag);
			}
		}
	}
	return best;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	vec3 col = space_color;

	vec3 g_n = normalize(galactic_normal);
	vec3 g_x = normalize(cross(g_n, vec3(0.0, 1.0, 0.0)));
	if (length(g_x) < 0.1) {
		g_x = normalize(cross(g_n, vec3(1.0, 0.0, 0.0)));
	}
	vec3 g_y = cross(g_n, g_x);
	float g_lat = asin(clamp(dot(dir, g_n), -1.0, 1.0));
	float g_lon = atan(dot(dir, g_y), dot(dir, g_x));

	float lat_n = abs(g_lat) / max(plane_width, 0.001);
	float plane = exp(-lat_n * lat_n * 2.8);

	vec3 gp = vec3(g_lon * 2.2, g_lat * 10.0, 0.7);
	float clumps = fbm3(gp * 1.4 + vec3(2.1, 0.0, 5.5));
	float lanes = fbm3(gp * 3.3 + vec3(8.0, 1.7, 0.0));
	float dust = mix(1.0, 1.0 - dust_strength, smoothstep(0.35, 0.82, lanes) * plane);

	float unresolved = star_layer(dir, 240.0 * star_density, mix(0.9975, 0.968, plane * clumps * dust), 1000.0);
	unresolved += star_layer(dir, 340.0 * star_density, mix(0.999, 0.98, plane * dust), 1500.0) * 0.6;

	float dense = 1.0 + plane_star_boost * plane * dust * mix(0.55, 1.0, clumps);
	float thresh_a = mix(0.988, 0.974, clamp((dense - 1.0) * 0.12, 0.0, 1.0));
	float stars = star_layer(dir, 110.0 * star_density, thresh_a, 360.0);
	stars += star_layer(dir, 48.0 * star_density, 0.995, 200.0) * 2.0;

	vec3 bulge_dir = normalize(-g_x * 0.15 + g_y * 0.95);
	float toward_center = pow(max(dot(dir, bulge_dir), 0.0), 14.0) * plane;
	float bulge_stars = star_layer(dir, 280.0 * star_density, mix(0.999, 0.972, toward_center), 1200.0);

	vec3 star_rgb = vec3(stars + unresolved * (0.55 + 1.8 * plane * dust));
	star_rgb += bulge_warm * bulge_stars * bulge_strength * toward_center * 1.4;
	col += star_rgb * star_brightness;

	float integrated = plane * dust * clumps * 0.04 * bulge_strength;
	col += bulge_warm * integrated * 0.3 + vec3(0.75, 0.82, 1.0) * integrated * 0.2;

	// Sun disc locked to LIGHT0 (first DirectionalLight3D = scene sun).
	if (LIGHT0_ENABLED) {
		vec3 sun_dir = normalize(LIGHT0_DIRECTION);
		float cos_ang = clamp(dot(dir, sun_dir), -1.0, 1.0);
		float half_rad = radians(max(sun_angular_diameter_deg, 0.05) * 0.5);
		float cos_core = cos(half_rad);
		float cos_corona = cos(half_rad * 2.8);
		float core = smoothstep(cos_core, mix(cos_core, 1.0, 0.2), cos_ang);
		float corona = smoothstep(cos_corona, cos_core, cos_ang);
		corona *= corona;
		float sun = (core * sun_core_energy + corona * sun_corona_energy) * max(LIGHT0_ENERGY, 0.0);
		col += sun_color * sun;
	}

	COLOR = col;
}
