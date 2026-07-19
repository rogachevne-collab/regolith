shader_type spatial;

// Object-local triplanar for detached floating chunks.
// Terrain shader (Transvoxel + virtual texturing) is wrong on RigidBody meshes.

uniform sampler2D u_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D u_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float u_scale : hint_range(0.05, 2.0, 0.01) = 0.28;
uniform float u_normal_strength : hint_range(0.0, 2.0, 0.01) = 0.85;
uniform float u_roughness : hint_range(0.0, 1.0, 0.01) = 0.9;

varying vec3 v_model_pos;
varying vec3 v_model_normal;

void vertex() {
	v_model_pos = VERTEX;
	v_model_normal = NORMAL;
}

vec3 triplanar_blend(vec3 n) {
	vec3 b = pow(abs(n), vec3(4.0));
	return b / max(b.x + b.y + b.z, 1e-4);
}

vec3 sample_triplanar(sampler2D tex, vec3 pos, vec3 blend) {
	return texture(tex, pos.yz).rgb * blend.x
		+ texture(tex, pos.xz).rgb * blend.y
		+ texture(tex, pos.xy).rgb * blend.z;
}

void fragment() {
	vec3 n = normalize(v_model_normal);
	vec3 blend = triplanar_blend(n);
	vec3 pos = v_model_pos * u_scale;
	vec3 albedo = sample_triplanar(u_albedo, pos, blend);
	vec3 nmap = sample_triplanar(u_normal, pos, blend) * 2.0 - 1.0;
	// Cheap object-space normal bump (no full TBN) — enough for debris.
	vec3 bumped = normalize(n + nmap * u_normal_strength * 0.35);
	NORMAL = (VIEW_MATRIX * MODEL_MATRIX * vec4(bumped, 0.0)).xyz;
	ALBEDO = albedo;
	ROUGHNESS = u_roughness;
	METALLIC = 0.0;
	SPECULAR = 0.12;
}
