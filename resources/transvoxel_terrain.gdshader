shader_type spatial;

#include "res://addons/zylann.voxel/shaders/transvoxel.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/virtual_texturing.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/triplanar.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/lod_fade.gdshaderinc"
#include "res://resources/triplanar_normal.gdshaderinc"

// Пошаговый debug PBR — включай по одному (1 = on):
#define TERRAIN_FEAT_NORMAL      1 // ← сейчас: normal maps (strength 0.35, cap 0.45)
#define TERRAIN_FEAT_ROUGHNESS   1
#define TERRAIN_FEAT_AO          1
#define TERRAIN_FEAT_MACRO       1
#define TERRAIN_FEAT_ALBEDO_VAR  1
#define TERRAIN_FEAT_ALBEDO_LIFT 0 // OFF: портит базовые albedo
#define TERRAIN_FEAT_UNDERSIDE   0 // OFF: затемняет низ/overhang, визуально неочевидно
#define TERRAIN_FEAT_SPECULAR    1 // ← сейчас: specular от rock weight

// Full triplanar PBR with adaptive planar fast-path (same look on flats/walls).

const float PLANAR_THRESH = 0.93;
const float LAYER_CULL = 0.012;

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
uniform float u_rock_normal_strength : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float u_layer_normal_strength : hint_range(0.0, 1.0, 0.01) = 0.2;
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
	int pmode = planar_mode(blending, PLANAR_THRESH);
	bool fetch_pbr = detail_fade > 0.04;

	vec2 biome_uv = wpos.xz * u_biome_scale;
	float mare_n = fbm(biome_uv * 0.85 + vec2(12.7, -4.2));
	float ejecta_n = fbm(biome_uv * 1.65 + vec2(-31.0, 9.5));
	float highland_n = fbm(biome_uv * 0.55 + vec2(3.3, 18.1));

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

	vec3 albedo_rock = vec3(0.0);
	vec3 albedo_dust = vec3(0.0);
	vec3 albedo_mare = vec3(0.0);
	vec3 n_rock = normal;
	vec3 n_dust = normal;
	vec3 n_mare = normal;
	float ao_rock = 1.0;
	float ao_dust = 1.0;
	float ao_mare = 1.0;
	float rough_rock = 0.76;
	float rough_dust = 0.90;
	float rough_mare = 0.85;

	if (w_rock > LAYER_CULL) {
		albedo_rock = sample_planar_rgb(u_rock_albedo, tex_pos, blending, pmode);
#if TERRAIN_FEAT_NORMAL
		if (fetch_pbr) {
			n_rock = sample_planar_normal(u_rock_normal, tex_pos, normal, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_AO
		if (fetch_pbr) {
			ao_rock = sample_planar_r(u_rock_ao, tex_pos, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_ROUGHNESS
		if (fetch_pbr) {
			rough_rock = sample_planar_r(u_rock_roughness, tex_pos, blending, pmode);
		}
#endif
	}
	if (w_dust > LAYER_CULL) {
		albedo_dust = sample_planar_rgb(u_dust_albedo, tex_pos, blending, pmode);
#if TERRAIN_FEAT_NORMAL
		if (fetch_pbr) {
			n_dust = sample_planar_normal(u_dust_normal, tex_pos, normal, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_AO
		if (fetch_pbr) {
			ao_dust = sample_planar_r(u_dust_ao, tex_pos, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_ROUGHNESS
		if (fetch_pbr) {
			rough_dust = sample_planar_r(u_dust_roughness, tex_pos, blending, pmode);
		}
#endif
	}
	if (w_mare > LAYER_CULL) {
		albedo_mare = sample_planar_rgb(u_mare_albedo, tex_pos, blending, pmode);
#if TERRAIN_FEAT_NORMAL
		if (fetch_pbr) {
			n_mare = sample_planar_normal(u_mare_normal, tex_pos, normal, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_AO
		if (fetch_pbr) {
			ao_mare = sample_planar_r(u_mare_ao, tex_pos, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_ROUGHNESS
		if (fetch_pbr) {
			rough_mare = sample_planar_r(u_mare_roughness, tex_pos, blending, pmode);
		}
#endif
	}

#if TERRAIN_FEAT_ALBEDO_LIFT
	albedo_rock = min(albedo_rock * 1.10, vec3(0.92));
	albedo_dust = min(albedo_dust * 1.08, vec3(0.90));
	albedo_mare = min(albedo_mare * 1.22 + vec3(0.035), vec3(0.72));
#endif

	vec3 tex_col = albedo_dust * w_dust + albedo_rock * w_rock + albedo_mare * w_mare;

#if TERRAIN_FEAT_ALBEDO_VAR
	float var_n = fbm(wpos.xz * u_detail_scale * 0.28 + vec2(11.0, 4.7));
	tex_col *= mix(0.94, 1.06, var_n);
#endif

#if TERRAIN_FEAT_MACRO
	float large_n = fbm(wpos.xz * u_large_scale);
	large_n = smoothstep(0.24, 0.76, large_n);
	vec3 large_tint = mix(vec3(0.94, 0.93, 0.91), vec3(1.06, 1.03, 0.99), large_n);
	tex_col *= mix(vec3(1.0), large_tint, u_macro_strength * 0.32);

	vec3 tint_highland = vec3(0.98, 0.99, 1.02);
	vec3 tint_ejecta = vec3(1.06, 1.02, 0.97);
	vec3 tint_mare = vec3(0.93, 0.94, 0.96);
	vec3 macro_tint = vec3(1.02, 1.01, 1.0);
	macro_tint = mix(macro_tint, tint_highland, highland * 0.55);
	macro_tint = mix(macro_tint, tint_ejecta, ejecta * 0.65);
	macro_tint = mix(macro_tint, tint_mare, mare_patch * flatness * 0.55);
	tex_col *= mix(vec3(1.0), macro_tint, u_macro_strength);
#endif

#if TERRAIN_FEAT_AO
	float ao_raw = w_dust * ao_dust + w_rock * ao_rock + w_mare * ao_mare;
	ao_raw = mix(0.90, 1.0, clamp(ao_raw, 0.0, 1.0));
	float ao = mix(1.0, ao_raw, u_ao_strength * mix(0.7, 1.0, detail_fade));
	tex_col *= ao;
#endif

	ALBEDO = tex_col;
#if TERRAIN_FEAT_ALBEDO_LIFT || TERRAIN_FEAT_AO || TERRAIN_FEAT_MACRO
	ALBEDO = clamp(ALBEDO, vec3(0.04), vec3(0.84));
#endif

#if TERRAIN_FEAT_UNDERSIDE
	ALBEDO = mix(ALBEDO, ALBEDO * 0.78, max(0.0, -normal.y) * 0.45);
#endif

#if TERRAIN_FEAT_NORMAL
	float rock_nw = clamp(u_rock_normal_strength * detail_fade, 0.0, 0.55);
	float layer_nw = clamp(u_layer_normal_strength * detail_fade, 0.0, 0.28);
	vec3 normal_perturb =
		(n_rock - normal) * w_rock * rock_nw
		+ (n_dust - normal) * w_dust * layer_nw
		+ (n_mare - normal) * w_mare * layer_nw;
	vec3 final_normal = normalize(normal + normal_perturb);
	NORMAL = normalize((VIEW_MATRIX * vec4(final_normal, 0.0)).xyz);
#endif

	float rough = w_dust * rough_dust + w_rock * rough_rock + w_mare * rough_mare;
	METALLIC = 0.0;
#if TERRAIN_FEAT_ROUGHNESS
	ROUGHNESS = clamp(rough, 0.68, 0.97);
#else
	ROUGHNESS = 0.88;
#endif
#if TERRAIN_FEAT_SPECULAR
	SPECULAR = mix(u_specular * 0.7, u_specular * 1.05, w_rock);
#else
	SPECULAR = 0.1;
#endif

	if (get_lod_fade_discard(SCREEN_UV)) {
		discard;
	}
}
