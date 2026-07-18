// Moon map globe — cubemap only (DEM + deposits). Zero equirect UV in shader.
// Text-only per R3.
shader_type spatial;
render_mode unshaded, cull_back;

uniform samplerCube dem_cube : source_color, filter_linear;
uniform samplerCube deposit_cube : source_color, filter_linear;
uniform float deposit_strength : hint_range(0.0, 1.0) = 1.0;
uniform vec4 limb_tint : source_color = vec4(0.55, 0.62, 0.78, 1.0);
uniform float limb_strength : hint_range(0.0, 1.0) = 0.12;

varying vec3 v_model_pos;
varying vec3 v_ao;

void vertex() {
	v_model_pos = VERTEX;
	v_ao = COLOR.rgb;
}

void fragment() {
	vec3 dir = normalize(v_model_pos);
	vec3 albedo = texture(dem_cube, dir).rgb * v_ao;

	vec4 deposit = texture(deposit_cube, dir);
	float dep_w = deposit.a * deposit_strength;
	albedo = mix(albedo, mix(albedo, deposit.rgb, 0.78), dep_w);

	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.2);
	albedo = mix(albedo, limb_tint.rgb, fres * limb_strength);

	ALBEDO = albedo;
	ALPHA = 1.0;
}
