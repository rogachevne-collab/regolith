shader_type spatial;

#include "res://addons/zylann.voxel/shaders/transvoxel.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/virtual_texturing.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/triplanar.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/lod_fade.gdshaderinc"
#include "res://resources/triplanar_normal.gdshaderinc"

// Full triplanar PBR: rock flats, cratered slopes, dark mare basins.

uniform sampler2D u_rock_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D u_rock_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D u_rock_ao : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D u_rock_roughness : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform sampler2D u_dust_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D u_dust_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D u_dust_ao : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D u_dust_roughness : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform sampler2D u_mare_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D u_mare_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D u_mare_ao : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D u_mare_roughness : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform float u_detail_scale : hint_range(0.05, 2.0, 0.01) = 0.11;
uniform float u_large_scale : hint_range(0.01, 0.5, 0.001) = 0.045;
uniform float u_biome_scale : hint_range(0.005, 0.2, 0.001) = 0.018;
uniform float u_macro_strength : hint_range(0.0, 1.0, 0.01) = 0.42;
uniform float u_normal_strength : hint_range(0.0, 2.0, 0.01) = 1.3;
uniform float u_ao_strength : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float u_mare_amount : hint_range(0.0, 1.0, 0.01) = 0.32;
uniform float u_detail_fade_start : hint_range(10.0, 80.0, 0.5) = 30.0;
uniform float u_detail_fade_end : hint_range(20.0, 160.0, 0.5) = 75.0;
uniform float u_specular : hint_range(0.0, 0.5, 0.01) = 0.17;

varying vec3 v_world_pos;
varying vec3 v_vertex_pos_model;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

vec2 hash22(vec2 p) {
	return fract(sin(vec2(
		dot(p, vec2(127.1, 311.7)),
		dot(p, vec2(269.5, 183.3))
	)) * 43758.5453);
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
	for (int i = 0; i < 4; i++) {
		v += a * value_noise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}

float triplanar_fbm(vec3 pos, vec3 blending) {
	return fbm(pos.xz) * blending.y
		+ fbm(pos.yz) * blending.x
		+ fbm(pos.xy) * blending.z;
}

// Лёгкий anti-tile без rotation — rotation ломал triplanar в полосы на склонах.
vec3 detail_pos(vec3 world_pos, float scale) {
	vec3 p = world_pos * scale;
	p += vec3(
		hash21(floor(p.yz * 0.11)) - 0.5,
		hash21(floor(p.xz * 0.11)) - 0.5,
		hash21(floor(p.xy * 0.11)) - 0.5
	) * 0.65;
	return p;
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
	float view_dist = length(CAMERA_POSITION_WORLD - wpos);
	float detail_fade = 1.0 - smoothstep(u_detail_fade_start, u_detail_fade_end, view_dist);

	float flatness = smoothstep(0.20, 0.88, normal.y);
	float steep = 1.0 - flatness;

	vec3 blending = get_triplanar_blend(normal, 6.0);

	vec3 biome_pos = wpos * u_biome_scale;
	float mare_n = triplanar_fbm(biome_pos * 0.85 + vec3(12.7, -4.2, 0.0), blending);
	float ejecta_n = triplanar_fbm(biome_pos * 1.65 + vec3(-31.0, 9.5, 0.0), blending);
	float highland_n = triplanar_fbm(biome_pos * 0.55 + vec3(3.3, 18.1, 0.0), blending);

	// Mare — редкие бассейны на пологих участках; rock — база плато.
	float mare_patch = smoothstep(0.62, 0.90, mare_n) * u_mare_amount;
	float ejecta = smoothstep(0.52, 0.84, ejecta_n) * (1.0 - mare_patch) * 0.72;
	float highland = smoothstep(0.38, 0.78, highland_n) * (1.0 - mare_patch);

	float w_mare = mare_patch * flatness;
	float w_dust = steep;
	float w_rock = flatness * (1.0 - mare_patch);
	float w_sum = max(w_dust + w_rock + w_mare, 1e-3);
	w_dust /= w_sum;
	w_rock /= w_sum;
	w_mare /= w_sum;

	vec3 tex_pos = detail_pos(wpos, u_detail_scale);

	vec3 albedo_dust = texture_triplanar(u_dust_albedo, tex_pos, blending).rgb;
	vec3 albedo_rock = texture_triplanar(u_rock_albedo, tex_pos, blending).rgb;
	vec3 albedo_mare = texture_triplanar(u_mare_albedo, tex_pos, blending).rgb;
	albedo_rock = min(albedo_rock * 1.10, vec3(0.92));
	albedo_mare = min(albedo_mare * 1.22 + vec3(0.035), vec3(0.72));
	albedo_dust = min(albedo_dust * 1.08, vec3(0.90));
	vec3 tex_col = albedo_dust * w_dust + albedo_rock * w_rock + albedo_mare * w_mare;

	float var_n = triplanar_fbm(wpos * u_detail_scale * 0.28, blending);
	tex_col *= mix(0.94, 1.06, var_n);

	float large_n = triplanar_fbm(wpos * u_large_scale, blending);
	large_n = smoothstep(0.24, 0.76, large_n);
	vec3 large_tint = mix(vec3(0.94, 0.93, 0.91), vec3(1.06, 1.03, 0.99), large_n);
	tex_col *= mix(vec3(1.0), large_tint, u_macro_strength * 0.32);

	float ao_dust = texture_triplanar(u_dust_ao, tex_pos, blending).r;
	float ao_rock = texture_triplanar(u_rock_ao, tex_pos, blending).r;
	float ao_mare = texture_triplanar(u_mare_ao, tex_pos, blending).r;
	float ao_raw = w_dust * ao_dust + w_rock * ao_rock + w_mare * ao_mare;
	ao_raw = mix(0.90, 1.0, clamp(ao_raw, 0.0, 1.0));
	float ao = mix(1.0, ao_raw, u_ao_strength * mix(0.7, 1.0, detail_fade));

	vec3 n_dust = triplanar_normal_whiteout(u_dust_normal, tex_pos, normal, blending);
	vec3 n_rock = triplanar_normal_whiteout(u_rock_normal, tex_pos, normal, blending);
	vec3 n_mare = triplanar_normal_whiteout(u_mare_normal, tex_pos, normal, blending);
	vec3 detail_normal = normalize(n_dust * w_dust + n_rock * w_rock + n_mare * w_mare);

	vec3 tint_highland = vec3(0.98, 0.99, 1.02);
	vec3 tint_ejecta = vec3(1.06, 1.02, 0.97);
	vec3 tint_mare = vec3(0.93, 0.94, 0.96);
	vec3 macro_tint = vec3(1.02, 1.01, 1.0);
	macro_tint = mix(macro_tint, tint_highland, highland * 0.55);
	macro_tint = mix(macro_tint, tint_ejecta, ejecta * 0.65);
	macro_tint = mix(macro_tint, tint_mare, mare_patch * flatness * 0.55);
	macro_tint = mix(vec3(1.0), macro_tint, u_macro_strength);

	ALBEDO = clamp(macro_tint * tex_col * ao, vec3(0.04), vec3(0.84));
	ALBEDO = mix(ALBEDO, ALBEDO * 0.78, max(0.0, -normal.y) * 0.45);

	float n_w = clamp(u_normal_strength * mix(0.35, 1.0, detail_fade), 0.0, 1.0);
	vec3 final_normal = normalize(mix(normal, detail_normal, n_w));
	NORMAL = normalize((VIEW_MATRIX * vec4(final_normal, 0.0)).xyz);

	float rough_dust = texture_triplanar(u_dust_roughness, tex_pos, blending).r;
	float rough_rock = texture_triplanar(u_rock_roughness, tex_pos, blending).r;
	float rough_mare = texture_triplanar(u_mare_roughness, tex_pos, blending).r;
	float rough = w_dust * rough_dust + w_rock * rough_rock + w_mare * rough_mare;
	METALLIC = 0.0;
	ROUGHNESS = clamp(rough, 0.68, 0.97);
	SPECULAR = mix(u_specular * 0.7, u_specular * 1.05, w_rock);

	if (get_lod_fade_discard(SCREEN_UV)) {
		discard;
	}
}
