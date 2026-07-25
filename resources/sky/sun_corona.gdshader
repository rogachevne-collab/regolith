shader_type spatial;
// Camera halo around the disc: three smooth exponential lobes (tight rim,
// mid falloff, wide veil). Purely radial — angular rays read as a fireball.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 inner_color : source_color = vec3(1.0, 0.88, 0.66);
uniform vec3 outer_color : source_color = vec3(1.0, 0.72, 0.42);
uniform float photo_radius : hint_range(0.15, 0.9, 0.01) = 0.4;
uniform float energy : hint_range(0.0, 8.0, 0.01) = 1.6;
uniform float tight_falloff : hint_range(4.0, 60.0, 0.5) = 26.0;
uniform float mid_falloff : hint_range(1.0, 20.0, 0.1) = 6.5;
uniform float wide_falloff : hint_range(0.2, 6.0, 0.05) = 1.6;

void fragment() {
	vec2 p = (UV * 2.0 - 1.0) / max(photo_radius, 0.001);
	float r = length(p);
	if (r < 0.99) {
		discard;
	}

	float d = r - 1.0;
	float tight = exp(-d * tight_falloff);
	float mid = exp(-d * mid_falloff) * 0.4;
	float wide = exp(-d * wide_falloff) * 0.12;
	float halo = tight + mid + wide;

	// Fade to nothing before the quad border so no seam is visible.
	halo *= smoothstep(2.4, 1.6, r);
	if (halo < 0.004) {
		discard;
	}

	vec3 col = mix(inner_color, outer_color, smoothstep(1.0, 1.8, r));
	col *= halo * energy;

	ALBEDO = col;
	EMISSION = col;
	ALPHA = clamp(halo, 0.0, 1.0);
}
