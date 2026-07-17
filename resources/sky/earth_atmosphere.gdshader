shader_type spatial;
render_mode unshaded, blend_add, depth_draw_opaque, cull_front, shadows_disabled, fog_disabled;

uniform vec4 atmosphere_color : source_color = vec4(0.45, 0.72, 1.0, 1.0);
uniform float rim_power : hint_range(0.5, 8.0, 0.1) = 1.9;
uniform float rim_intensity : hint_range(0.0, 4.0, 0.05) = 1.8;
uniform float face_glow : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float night_softness : hint_range(0.0, 1.0, 0.05) = 0.4;
uniform vec3 sun_direction = vec3(0.5, 0.7, 0.3);
uniform vec3 haze_color : source_color = vec3(0.55, 0.65, 0.85);
uniform float haze_mix : hint_range(0.0, 1.0, 0.01) = 0.35;

void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	float fresnel = pow(clamp(1.0 - abs(dot(n, v)), 0.0, 1.0), rim_power);

	vec3 sun_view = normalize((VIEW_MATRIX * vec4(normalize(sun_direction), 0.0)).xyz);
	float day = smoothstep(-night_softness, 0.55, dot(n, sun_view));

	float limb = fresnel * rim_intensity * mix(0.2, 1.0, day);
	float face = face_glow * (1.0 - fresnel) * day;
	float energy = limb + face;

	vec3 col = mix(atmosphere_color.rgb, haze_color, haze_mix);
	ALBEDO = col;
	EMISSION = col * energy;
	ALPHA = clamp(energy, 0.0, 1.0) * atmosphere_color.a;
}
