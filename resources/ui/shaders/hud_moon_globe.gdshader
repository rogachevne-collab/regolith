// Map globe — orbital matte grey (no ground-scale regolith jpeg → no sand).
shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_back;

uniform samplerCube deposit_cube : source_color, filter_linear;
uniform vec3 albedo_tint : source_color = vec3(0.58, 0.59, 0.61);
uniform float deposit_strength : hint_range(0.0, 1.0) = 1.0;
// Macro mottling only (basins), not meter-scale grit.
uniform float macro_amp : hint_range(0.0, 0.2) = 0.045;
uniform float macro_freq : hint_range(0.5, 12.0) = 2.4;

varying vec3 v_obj_pos;

void vertex() {
	v_obj_pos = VERTEX;
}

float _hash31(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float _macro_mottle(vec3 dir) {
	vec3 p = normalize(dir) * macro_freq;
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = _hash31(i);
	float n100 = _hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = _hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = _hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = _hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = _hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = _hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = _hash31(i + vec3(1.0, 1.0, 1.0));
	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);
	float nxy0 = mix(nx00, nx10, f.y);
	float nxy1 = mix(nx01, nx11, f.y);
	return mix(nxy0, nxy1, f.z);
}

void fragment() {
	vec3 dir = normalize(v_obj_pos);
	float mottle = (_macro_mottle(dir) - 0.5) * 2.0 * macro_amp;
	vec3 alb = albedo_tint * COLOR.rgb;
	alb *= 1.0 + mottle;
	alb = clamp(alb, vec3(0.0), vec3(1.0));

	vec4 dep = texture(deposit_cube, dir);
	alb = mix(alb, dep.rgb, clamp(dep.a * deposit_strength, 0.0, 1.0));

	ALBEDO = alb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
