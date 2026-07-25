shader_type spatial;
// Vacuum sun: blown-out white photosphere with a hard limb.
// No noise, no TIME — surface detail only reads through a solar filter, and
// animated granulation turned the disc into a shivering fireball.
render_mode unshaded, depth_draw_opaque, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 core_color : source_color = vec3(1.0, 0.99, 0.96);
uniform vec3 rim_color : source_color = vec3(1.0, 0.86, 0.62);
uniform float photo_radius : hint_range(0.15, 0.9, 0.01) = 0.4;
uniform float energy : hint_range(0.0, 40.0, 0.05) = 9.0;
uniform float limb_darkening : hint_range(0.0, 1.0, 0.01) = 0.14;
uniform float rim_warmth : hint_range(0.0, 1.0, 0.01) = 0.45;

void fragment() {
	vec2 p = (UV * 2.0 - 1.0) / max(photo_radius, 0.001);
	float r = length(p);
	float aa = max(fwidth(r) * 0.6, 0.002);
	if (r > 1.0 + aa) {
		discard;
	}

	float disc = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);
	float mu = sqrt(max(1.0 - min(r * r, 1.0), 0.0));
	float limb = mix(1.0 - limb_darkening, 1.0, pow(mu, 0.45));

	// Warm tint only in the last few percent of the radius.
	float rim = smoothstep(0.86, 1.0, r) * rim_warmth;
	vec3 col = mix(core_color, rim_color, rim) * limb * energy;

	ALBEDO = col * disc;
	EMISSION = col * disc;
}
