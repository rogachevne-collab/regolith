shader_type spatial;
// fog_disabled: at sky distance env fog would erase the disc; haze is baked in.
render_mode diffuse_burley, specular_schlick_ggx, cull_back, shadows_disabled, fog_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 ocean_tint : source_color = vec4(0.08, 0.22, 0.55, 1.0);
uniform float ocean_boost : hint_range(0.0, 1.0, 0.05) = 0.12;
uniform float night_glow : hint_range(0.0, 0.5, 0.01) = 0.03;
uniform vec4 night_color : source_color = vec4(0.04, 0.06, 0.14, 1.0);
uniform vec3 haze_color : source_color = vec3(0.55, 0.62, 0.78);
uniform float haze_amount : hint_range(0.0, 1.0, 0.01) = 0.38;
uniform float soft_focus : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float saturation : hint_range(0.0, 1.5, 0.01) = 0.78;

void fragment() {
	vec3 tex = textureLod(albedo_tex, UV, soft_focus * 3.5).rgb;
	float luma = dot(tex, vec3(0.299, 0.587, 0.114));
	vec3 albedo = mix(tex, ocean_tint.rgb, ocean_boost * (1.0 - smoothstep(0.15, 0.45, luma)));
	albedo = mix(vec3(luma), albedo, saturation);

	// Aerial haze: distant sky body, not vacuum-crisp.
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	float rim = pow(clamp(1.0 - abs(dot(n, v)), 0.0, 1.0), 1.4);
	float haze = clamp(haze_amount * (0.55 + 0.45 * rim), 0.0, 1.0);
	albedo = mix(albedo, haze_color, haze);

	ALBEDO = albedo;
	ROUGHNESS = 0.85;
	METALLIC = 0.0;
	EMISSION = night_color.rgb * night_glow * (1.0 - haze);
}
