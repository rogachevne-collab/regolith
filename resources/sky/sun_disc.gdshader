shader_type spatial;
render_mode unshaded, blend_add, depth_draw_opaque, cull_back, shadows_disabled, fog_disabled;

uniform vec4 core_color : source_color = vec4(1.0, 0.97, 0.88, 1.0);
uniform vec4 corona_color : source_color = vec4(1.0, 0.85, 0.55, 1.0);
uniform float core_radius : hint_range(0.05, 0.95, 0.01) = 0.55;
uniform float corona_softness : hint_range(0.05, 1.5, 0.01) = 0.65;
uniform float core_energy : hint_range(0.0, 12.0, 0.05) = 5.0;
uniform float corona_energy : hint_range(0.0, 6.0, 0.05) = 1.6;

void fragment() {
	// View-space normal: center of facing disc ≈ (0,0,1), rim → xy grows.
	vec3 n = normalize(NORMAL);
	float facing = clamp(n.z, 0.0, 1.0);
	float r = length(n.xy);

	float core = 1.0 - smoothstep(core_radius * 0.7, core_radius, r);
	float corona = 1.0 - smoothstep(core_radius, core_radius + corona_softness, r);
	corona *= corona * facing;

	vec3 col = core_color.rgb * core * core_energy;
	col += corona_color.rgb * corona * corona_energy;

	ALBEDO = col;
	EMISSION = col;
	ALPHA = clamp(core + corona, 0.0, 1.0) * core_color.a;
}
