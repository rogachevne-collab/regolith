shader_type spatial;

#include "res://addons/zylann.voxel/shaders/transvoxel.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/virtual_texturing.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/triplanar.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/lod_fade.gdshaderinc"
#include "res://resources/triplanar_normal.gdshaderinc"

uniform sampler2D u_texture_top : source_color;
uniform sampler2D u_texture_sides : source_color;
uniform sampler2D u_normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float u_macro_scale : hint_range(0.01, 0.5, 0.001) = 0.035;
uniform float u_detail_scale : hint_range(0.05, 2.0, 0.01) = 0.16;
uniform float u_macro_strength : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float u_normal_strength : hint_range(0.0, 2.0, 0.01) = 0.8;

varying vec3 v_world_pos;
varying vec3 v_vertex_pos_model;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * value_noise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}


void vertex() {
	VERTEX = get_transvoxel_position(VERTEX, CUSTOM0);
	v_vertex_pos_model = VERTEX;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 geometry_normal_view = get_voxel_normal_view(
		v_vertex_pos_model,
		NORMAL,
		VIEW_MATRIX * MODEL_MATRIX
	);
	vec3 normal = normalize(
		(INV_VIEW_MATRIX * vec4(geometry_normal_view, 0.0)).xyz
	);
	vec3 wpos = v_world_pos;

	float topness = smoothstep(0.46, 0.54, normal.y);
	vec3 blending = get_triplanar_blend(normal, 5.0);

	vec3 detail_pos = wpos * u_detail_scale;
	vec3 top_col = texture_triplanar(u_texture_top, detail_pos, blending).rgb;
	vec3 side_col = texture_triplanar(u_texture_sides, detail_pos, blending).rgb;
	vec3 tex_col = mix(side_col, top_col, topness);
	tex_col = pow(tex_col, vec3(1.05));

	vec3 macro_pos = wpos * u_macro_scale;
	float macro_n = fbm(macro_pos.xz) * blending.y
		+ fbm(macro_pos.yz) * blending.x
		+ fbm(macro_pos.xy) * blending.z;
	macro_n = smoothstep(0.18, 0.82, macro_n);

	vec3 regolith_dark = vec3(0.28, 0.27, 0.26);
	vec3 regolith_bright = vec3(0.52, 0.51, 0.49);
	vec3 macro_col = mix(regolith_dark, regolith_bright, macro_n);
	vec3 macro_tint = mix(vec3(1.0), macro_col, u_macro_strength);

	ALBEDO = macro_tint * tex_col;
	ALBEDO = clamp(ALBEDO, vec3(0.03), vec3(0.85));
	ALBEDO = mix(ALBEDO, ALBEDO * 0.72, max(0.0, -normal.y) * 0.5);
	vec3 detail_normal = triplanar_normal_whiteout(
		u_normal_map,
		detail_pos,
		normal,
		blending
	);
	vec3 final_normal = normalize(
		mix(normal, detail_normal, clamp(u_normal_strength, 0.0, 1.0))
	);
	NORMAL = normalize((VIEW_MATRIX * vec4(final_normal, 0.0)).xyz);
	ROUGHNESS = 0.86;
	SPECULAR = 0.12;

	if (get_lod_fade_discard(SCREEN_UV)) {
		discard;
	}
}
