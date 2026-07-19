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
#define TERRAIN_FEAT_ALBEDO_VAR  0 // OFF: procedural mush over photo detail
#define TERRAIN_FEAT_ALBEDO_LIFT 0 // OFF: портит базовые albedo
#define TERRAIN_FEAT_UNDERSIDE   0 // OFF: затемняет низ/overhang, визуально неочевидно
#define TERRAIN_FEAT_SPECULAR    1 // ← сейчас: specular от rock weight

// Full triplanar PBR with adaptive planar fast-path (same look on flats/walls).

// High thresh forced single-plane wallpaper on gentle Ø19 km slopes — keep low.
const float PLANAR_THRESH = 0.995;
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

// Detail period ~1/scale metres — sharper grain, light dual-scale for tiling.
uniform float u_detail_scale : hint_range(0.02, 2.0, 0.01) = 0.13;
uniform float u_large_scale : hint_range(0.002, 0.5, 0.001) = 0.018;
uniform float u_biome_scale : hint_range(0.001, 0.2, 0.001) = 0.008;
uniform float u_macro_strength : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float u_rock_normal_strength : hint_range(0.0, 1.0, 0.01) = 0.68;
uniform float u_dust_normal_strength : hint_range(0.0, 1.5, 0.01) = 0.95;
uniform float u_layer_normal_strength : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float u_dust_light_mix : hint_range(0.0, 1.0, 0.01) = 0.50;
// Cycles per metre on wpos (not dir*R). 0.40 ≈ 2.5 m patches.
uniform float u_dust_variant_scale : hint_range(0.05, 0.80, 0.01) = 0.40;
uniform float u_ao_strength : hint_range(0.0, 1.0, 0.01) = 0.22;
uniform float u_mare_amount : hint_range(0.0, 1.0, 0.01) = 0.48;
uniform float u_detail_fade_start : hint_range(10.0, 120.0, 0.5) = 40.0;
uniform float u_detail_fade_end : hint_range(20.0, 220.0, 0.5) = 95.0;
uniform float u_specular : hint_range(0.0, 0.5, 0.01) = 0.17;
uniform float u_radial_up : hint_range(0.0, 1.0, 1.0) = 0.0;
uniform float u_planet_radius : hint_range(0.0, 20000.0, 1.0) = 0.0;

varying vec3 v_world_pos;
varying vec3 v_vertex_pos_model;

// Integer-stable hash — sin-hash turns to mush at |p| ≳ 1e3 (Ø19 km crust).
float hash21(vec2 p) {
	uvec2 u = uvec2(ivec2(floor(p)));
	uint n = u.x * 1597334677u + u.y * 3812015801u;
	n ^= n >> 13u;
	n *= 1274126177u;
	return float(n) * (1.0 / 4294967296.0);
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

// Pole-safe surface noise: triplanar fbm on meter coords (dir * R).
float fbm_surface(vec3 meter_pos, vec3 dir, float scale) {
	vec3 b = abs(dir);
	b /= max(b.x + b.y + b.z, 1e-3);
	return fbm(meter_pos.yz * scale) * b.x
		+ fbm(meter_pos.xz * scale + vec2(19.1, -4.7)) * b.y
		+ fbm(meter_pos.xy * scale + vec2(-11.3, 8.2)) * b.z;
}

// Meter-domain position for biome/macro. Flat yard keeps world XYZ.
vec3 surface_meter_pos(vec3 wpos) {
	if (u_radial_up > 0.5 && u_planet_radius > 1.0) {
		return normalize(wpos) * u_planet_radius;
	}
	return wpos;
}

vec3 detail_pos(vec3 world_pos, float scale) {
	return world_pos * scale;
}

vec2 hash22(vec2 p) {
	return vec2(hash21(p), hash21(p + vec2(17.0, 41.0)));
}

vec3 texture_triplanar_off(sampler2D tex, vec3 pos, vec3 blending, vec2 off) {
	return texture(tex, pos.yz + off).rgb * blending.x
		+ texture(tex, pos.xz + off).rgb * blending.y
		+ texture(tex, pos.xy + off).rgb * blending.z;
}

// Sharp triplanar + light second scale (dust / mare).
vec3 sample_albedo_clean(sampler2D tex, vec3 pos, vec3 blending) {
	vec3 a = texture_triplanar(tex, pos, blending).rgb;
	vec3 b = texture_triplanar(tex, pos * 0.43 + vec3(2.3, -1.6, 0.8), blending).rgb;
	return mix(a, b, 0.18);
}

// Lunar plateaus: photo high-pass grit + procedural low-freq value.
// Large dark stains in the albedo are what tile — strip them, keep micro grain.
vec3 sample_albedo_lunar(sampler2D tex, vec3 pos, vec3 blending) {
	vec3 sharp = texture_triplanar(tex, pos, blending).rgb;
	vec3 low = texture_triplanar(tex, pos * 0.11, blending).rgb;
	vec3 grit = sharp - low + vec3(0.52);

	vec3 sharp2 = texture_triplanar(tex, pos * 1.63 + vec3(2.8, -1.9, 0.6), blending).rgb;
	vec3 low2 = texture_triplanar(tex, pos * 0.18 + vec3(1.1, 0.4, -0.7), blending).rgb;
	vec3 grit2 = sharp2 - low2 + vec3(0.52);
	float wg = value_noise(pos.xz * 0.48 + pos.y * 0.14);
	grit = mix(grit, grit2, 0.30 + 0.15 * wg);

	// Soft UV phase on grit only (small offsets — stays sharp).
	float k = value_noise(pos.xy * 0.16 + 2.7);
	float ia = floor(k * 5.0);
	vec2 off = (hash22(vec2(ia, 11.3)) - 0.5) * 0.55;
	vec3 grit_off = texture_triplanar_off(tex, pos, blending, off)
		- texture_triplanar_off(tex, pos * 0.11, blending, off * 0.3)
		+ vec3(0.52);
	grit = mix(grit, grit_off, 0.18);

	// Irregular large value — no photo period, so no wallpaper.
	float macro = fbm(pos.xz * 0.07 + vec2(pos.y * 0.04, 3.7));
	float meso = fbm(pos.xz * 0.22 + vec2(-8.1, pos.y * 0.09));
	float base = mix(0.44, 0.62, macro);
	base *= mix(0.94, 1.06, meso);
	return clamp(grit * (base / 0.52), vec3(0.05), vec3(0.95));
}

// Source albedos (esp. dark_rough) carry rust/teal flecks — lunar crust is near-grey.
vec3 lunar_grey(vec3 c, float chroma) {
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	return mix(vec3(l), c, chroma);
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

	vec3 surface_up = u_radial_up > 0.5 ? normalize(wpos) : vec3(0.0, 1.0, 0.0);
	float upness = clamp(dot(normal, surface_up), -1.0, 1.0);
	float tilt = length(normal - surface_up * upness);

	// Height vs mean sphere — crater bowls sit below 0.
	float h_signal = u_planet_radius > 0.0
		? (length(wpos) - u_planet_radius)
		: wpos.y;
	float h_grad = length(vec2(dFdx(h_signal), dFdy(h_signal)));

	// dark_rough only on hard walls (~32°+). Mild/medium slopes stay lunar/cratered.
	float slope = clamp(1.0 - upness, 0.0, 1.0);
	float steep = smoothstep(0.14, 0.26, slope);
	float flatness = 1.0 - steep;

	vec3 blending = get_triplanar_blend(normal, 6.0);
	int pmode = planar_mode(blending, PLANAR_THRESH);
	bool fetch_pbr = detail_fade > 0.04;

	vec3 meter_pos = surface_meter_pos(wpos);
	vec3 surf_dir = u_radial_up > 0.5 ? surface_up : vec3(0.0, 1.0, 0.0);
	float mare_n = fbm_surface(meter_pos, surf_dir, u_biome_scale * 0.85);
	float ejecta_n = fbm_surface(meter_pos, surf_dir, u_biome_scale * 1.65);
	float highland_n = fbm_surface(meter_pos, surf_dir, u_biome_scale * 0.55);

	// Crater floors: flat + depressed. Soft-mix cratered with lunar (not a solid patch).
	float bowl = smoothstep(2.5, -14.0, h_signal);
	float floor_smooth = 1.0 - smoothstep(0.02, 0.14, h_grad);
	float crater_floor = flatness * bowl * mix(0.55, 1.0, floor_smooth);
	float basin_n = smoothstep(0.40, 0.74, mare_n) * u_mare_amount;
	float floor_mask = max(crater_floor, basin_n * flatness * 0.65);
	// cratered share inside the floor (rest stays lunar).
	float cratered_mix = floor_mask * 0.58;

	float ejecta = smoothstep(0.50, 0.82, ejecta_n) * (1.0 - floor_mask) * 0.55;
	float highland = smoothstep(0.38, 0.75, highland_n) * (1.0 - floor_mask);

	float w_dust = steep; // dark_rough_rock — steep walls only
	float w_mare = cratered_mix * (1.0 - steep); // cratered_rock on floors
	float w_rock = (1.0 - steep) * (1.0 - cratered_mix); // lunar base
	float w_sum = max(w_dust + w_rock + w_mare, 1e-3);
	w_dust /= w_sum;
	w_rock /= w_sum;
	w_mare /= w_sum;

	// Микрорельеф плато: выступ над сферой + наклон (SDF-бугорки), не normal map.
	float plateau = smoothstep(0.70, 0.98, upness);
	float protrusion = max(h_signal, 0.0);
	float crest = 0.0;
	float bump_side = 0.0;
	if (u_planet_radius > 0.0 || u_radial_up > 0.5) {
		crest = plateau * smoothstep(0.06, 1.6, protrusion)
			* (1.0 - smoothstep(0.015, 0.10, h_grad));
		bump_side = plateau * smoothstep(0.010, 0.11, tilt)
			* (1.0 - smoothstep(0.22, 0.40, tilt))
			* smoothstep(0.008, 0.22, h_grad + protrusion * 0.25);
	}

	// Per-layer UV. Dust is coarser — fine scale on big walls tiles hardest.
	vec3 tex_rock = detail_pos(wpos, u_detail_scale);
	vec3 tex_dust = detail_pos(wpos + vec3(17.0, -9.0, 5.0), u_detail_scale * 0.58);
	vec3 tex_mare = detail_pos(wpos + vec3(-11.0, 6.0, 13.0), u_detail_scale * 0.62);

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
		albedo_rock = sample_albedo_lunar(u_rock_albedo, tex_rock, blending);
#if TERRAIN_FEAT_NORMAL
		if (fetch_pbr) {
			n_rock = sample_planar_normal(u_rock_normal, tex_rock, normal, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_AO
		if (fetch_pbr) {
			ao_rock = sample_planar_r(u_rock_ao, tex_rock, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_ROUGHNESS
		if (fetch_pbr) {
			rough_rock = sample_planar_r(u_rock_roughness, tex_rock, blending, pmode);
		}
#endif
	}
	if (w_dust > LAYER_CULL || bump_side > 0.02) {
		vec3 dust_a = sample_albedo_clean(u_dust_albedo, tex_dust, blending);
		// Second phase of same rock — light variant will lift this toward regolith.
		vec3 dust_b = sample_albedo_clean(
			u_dust_albedo, tex_dust * 0.78 + vec3(5.3, -2.6, 1.9), blending
		);
		dust_a = lunar_grey(dust_a, 0.06);
		dust_b = lunar_grey(dust_b, 0.06);
		vec3 dust_dark = dust_a * 0.92;
		vec3 regolith_ref = w_rock > LAYER_CULL ? albedo_rock : vec3(0.56);
		vec3 dust_light = mix(dust_b * 1.05, regolith_ref, u_dust_light_mix);
		dust_light = clamp(dust_light, vec3(0.18), vec3(0.72));
		// World-metre domain — dir*R near poles makes xz almost constant → km-scale blobs.
		float dust_mask = fbm_surface(wpos, surf_dir, u_dust_variant_scale);
		dust_mask = smoothstep(0.38, 0.62, dust_mask);
		albedo_dust = mix(dust_dark, dust_light, dust_mask);
#if TERRAIN_FEAT_NORMAL
		if (fetch_pbr && w_dust > LAYER_CULL) {
			n_dust = sample_planar_normal(u_dust_normal, tex_dust, normal, blending, pmode);
			// Light patches: slightly softer normal read (dustier).
			vec3 n_dust_b = sample_planar_normal(
				u_dust_normal, tex_dust * 0.78 + vec3(5.3, -2.6, 1.9), normal, blending, pmode
			);
			n_dust = normalize(mix(n_dust, n_dust_b, dust_mask * 0.45));
		}
#endif
#if TERRAIN_FEAT_AO
		if (fetch_pbr && w_dust > LAYER_CULL) {
			ao_dust = sample_planar_r(u_dust_ao, tex_dust, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_ROUGHNESS
		if (fetch_pbr && w_dust > LAYER_CULL) {
			rough_dust = sample_planar_r(u_dust_roughness, tex_dust, blending, pmode);
			rough_dust = mix(rough_dust, 0.88, dust_mask * 0.35);
		}
#endif
	}
	if (w_mare > LAYER_CULL) {
		albedo_mare = sample_albedo_clean(u_mare_albedo, tex_mare, blending);
#if TERRAIN_FEAT_NORMAL
		if (fetch_pbr) {
			n_mare = sample_planar_normal(u_mare_normal, tex_mare, normal, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_AO
		if (fetch_pbr) {
			ao_mare = sample_planar_r(u_mare_ao, tex_mare, blending, pmode);
		}
#endif
#if TERRAIN_FEAT_ROUGHNESS
		if (fetch_pbr) {
			rough_mare = sample_planar_r(u_mare_roughness, tex_mare, blending, pmode);
		}
#endif
	}

#if TERRAIN_FEAT_ALBEDO_LIFT
	albedo_rock = min(albedo_rock * 1.10, vec3(0.92));
	albedo_dust = min(albedo_dust * 1.08, vec3(0.90));
	albedo_mare = min(albedo_mare * 1.22 + vec3(0.035), vec3(0.72));
#endif

	// Kill photo chroma — dust already grey'd in its dual-variant path.
	albedo_rock = lunar_grey(albedo_rock, 0.10) * 1.02;
	albedo_mare = lunar_grey(albedo_mare, 0.08) * 1.00;

	vec3 tex_col = albedo_dust * w_dust + albedo_rock * w_rock + albedo_mare * w_mare;
	tex_col *= mix(1.0, 1.08, crest * 0.90);
	// No extra dark from bump_side — that smeared black onto mild rims.
	tex_col = mix(tex_col, albedo_dust, bump_side * 0.08 * steep);

#if TERRAIN_FEAT_ALBEDO_VAR
	float var_n = fbm_surface(meter_pos, surf_dir, u_detail_scale * 0.28);
	tex_col *= mix(0.92, 1.08, var_n);
#endif

#if TERRAIN_FEAT_MACRO
	// Value-only macro — no warm/cool RGB tints.
	float large_n = fbm_surface(meter_pos, surf_dir, u_large_scale);
	large_n = smoothstep(0.24, 0.76, large_n);
	float large_v = mix(0.96, 1.04, large_n);
	tex_col *= mix(1.0, large_v, u_macro_strength * 0.28);

	float macro_v = 1.0;
	macro_v = mix(macro_v, 1.03, highland * 0.40);
	macro_v = mix(macro_v, 1.04, ejecta * 0.45);
	macro_v = mix(macro_v, 0.97, floor_mask * 0.35);
	tex_col *= mix(1.0, macro_v, u_macro_strength);
#endif

#if TERRAIN_FEAT_AO
	float ao_raw = w_dust * ao_dust + w_rock * ao_rock + w_mare * ao_mare;
	ao_raw = mix(0.90, 1.0, clamp(ao_raw, 0.0, 1.0));
	float ao = mix(1.0, ao_raw, u_ao_strength * mix(0.7, 1.0, detail_fade));
	tex_col *= ao;
#endif

	ALBEDO = clamp(tex_col, vec3(0.02), vec3(0.95));

#if TERRAIN_FEAT_UNDERSIDE
	ALBEDO = mix(ALBEDO, ALBEDO * 0.78, max(0.0, -normal.y) * 0.45);
#endif

#if TERRAIN_FEAT_NORMAL
	float rock_nw = clamp(u_rock_normal_strength * detail_fade, 0.0, 0.75);
	float dust_nw = clamp(u_dust_normal_strength * detail_fade, 0.0, 0.95);
	float layer_nw = clamp(u_layer_normal_strength * detail_fade, 0.0, 0.45);
	vec3 normal_perturb =
		(n_rock - normal) * w_rock * rock_nw
		+ (n_dust - normal) * w_dust * dust_nw
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
