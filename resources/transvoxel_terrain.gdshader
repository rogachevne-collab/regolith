shader_type spatial;

#include "res://addons/zylann.voxel/shaders/transvoxel.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/virtual_texturing.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/triplanar.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/lod_fade.gdshaderinc"
#include "res://resources/triplanar_normal.gdshaderinc"
#include "res://resources/hex_tile.gdshaderinc"

// Three frequency bands, one mechanism each — no stacked hacks:
//   micro (0.1–5 m):  hex-tiled triplanar photo PBR, untouched histogram
//   meso  (5–100 m):  same textures at far scale, distance cross-fade
//   macro (100 m–km): baked equirect brightness map + one value fbm
// Color grading happens exactly once, at the end (grade_lunar).

// Layer semantics (texture slots kept for .tres/bootstrap compatibility):
//   u_rock_* — lunar base regolith (flats, highlands)
//   u_dust_* — dark rough rock (steep walls, cave interiors)
//   u_mare_* — cratered rock (crater floors, basins)

const float PLANAR_THRESH = 0.92;
const float LAYER_CULL = 0.02;
const float BLEND_SHARPNESS = 6.0;

uniform sampler2D u_rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D u_rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D u_rock_ao : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D u_rock_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D u_dust_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D u_dust_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D u_dust_ao : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D u_dust_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D u_mare_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D u_mare_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D u_mare_ao : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D u_mare_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

// Micro band: texture cycles per metre (0.15 → ~6.7 m period).
uniform float u_detail_scale : hint_range(0.02, 2.0, 0.01) = 0.15;
// Meso band: far scale = detail/ratio (12 → ~80 m period).
uniform float u_far_ratio : hint_range(4.0, 32.0, 0.5) = 12.0;
uniform float u_far_start : hint_range(20.0, 400.0, 5.0) = 60.0;
uniform float u_far_end : hint_range(100.0, 1200.0, 10.0) = 280.0;
uniform float u_mip_bias : hint_range(-1.5, 0.0, 0.05) = -0.5;
uniform float u_normal_strength : hint_range(0.0, 1.5, 0.01) = 0.9;
// Regolith is uniform matte powder: at mid range albedo variance stays LOW
// (a busy photo reads as steel wool), but up close the photo contrast IS the
// detail — flattening it everywhere is what made the ground look soapy.
uniform float u_albedo_variance : hint_range(0.0, 1.0, 0.01) = 0.42;
uniform float u_albedo_variance_near : hint_range(0.0, 1.0, 0.01) = 0.55;
uniform float u_variance_near_end : hint_range(5.0, 120.0, 1.0) = 45.0;
// Micro band. The base band is ~0.65 cm/texel, so within a few metres the
// photo is magnified past its own resolution — pure bilinear mush. This adds
// a much finer sample of the base texture as grain modulation (not base
// color), so it cannot reintroduce visible repetition.
uniform float u_micro_ratio : hint_range(2.0, 16.0, 0.5) = 7.0;
uniform float u_micro_start : hint_range(2.0, 40.0, 0.5) = 14.0;
uniform float u_micro_strength : hint_range(0.0, 1.0, 0.01) = 0.28;
uniform float u_micro_normal : hint_range(0.0, 1.5, 0.01) = 0.55;
// Extra flatten + normal damping for the meso band — a busy photo at 80 m
// period reads as crumpled foil on distant slopes.
uniform float u_far_variance : hint_range(0.0, 1.0, 0.01) = 0.45;
uniform float u_far_normal : hint_range(0.0, 1.0, 0.01) = 0.35;
// Hex-tile rotation jitter (fraction of a full turn). Small: the photos are
// striated, full random rotation reads as a surreal swirl patchwork.
uniform float u_hex_rotation : hint_range(0.0, 1.0, 0.01) = 0.12;
// Pull dust/mare mean brightness toward the base layer: regolith is uniform,
// layers should differ in texture, not value (macro value = brightness map).
uniform float u_layer_equalize : hint_range(0.0, 1.0, 0.01) = 0.75;
uniform float u_ao_strength : hint_range(0.0, 1.0, 0.01) = 0.35;
// Height-proxy blend sharpening: rocks poke through dust at layer borders.
uniform float u_height_blend : hint_range(0.0, 1.0, 0.01) = 0.4;
// One breakup noise for layer borders, one value fbm for macro patchiness.
uniform float u_biome_scale : hint_range(0.001, 0.2, 0.001) = 0.008;
uniform float u_large_scale : hint_range(0.002, 0.5, 0.001) = 0.018;
uniform float u_macro_strength : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float u_mare_amount : hint_range(0.0, 1.0, 0.01) = 0.55;
// Layer mix ceilings: lunar is THE base, the other two only blend into it.
uniform float u_wall_mix : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float u_mare_mix : hint_range(0.0, 1.0, 0.01) = 0.7;
// Wall subtlety: breakup frays the steep mask; albedo/detail split lets a
// second pack (e.g. Ground103) add grit without replacing base albedo.
// Defaults 0 / 1 / 1 / 0 / 0 keep legacy "full dust layer on steep" behaviour.
// When albedo_start/end > 0, dust albedo only on near-vertical scarps.
uniform float u_wall_breakup : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float u_wall_albedo_mix : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float u_wall_detail : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float u_wall_albedo_start : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float u_wall_albedo_end : hint_range(0.0, 1.0, 0.01) = 0.0;
// Final grade — the only place albedo value/chroma is touched.
uniform float u_exposure : hint_range(0.3, 1.5, 0.01) = 0.58;
uniform float u_contrast : hint_range(0.5, 2.0, 0.01) = 1.0;
uniform float u_chroma : hint_range(0.0, 1.0, 0.01) = 0.02;
uniform float u_specular : hint_range(0.0, 0.5, 0.01) = 0.15;
uniform float u_radial_up : hint_range(0.0, 1.0, 1.0) = 0.0;
uniform float u_planet_radius : hint_range(0.0, 20000.0, 1.0) = 0.0;
// Baked equirect albedo brightness (dark maria + fresh-crater ray systems),
// value = texel * 1.5 (neutral 1/1.5). Set by bootstrap on the native path.
uniform sampler2D u_moon_brightness : hint_default_white, filter_linear, repeat_enable;
uniform float u_moon_brightness_on : hint_range(0.0, 1.0, 1.0) = 0.0;
uniform float u_moon_brightness_strength : hint_range(0.0, 1.0, 0.01) = 0.85;

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

// Hex-tiled triplanar albedo. Per-plane seeds decorrelate the projections;
// they must match hex_triplanar_normal's so albedo and normal stay aligned.
vec3 hex_triplanar_rgb(
	sampler2D tex, vec3 pos, vec3 ddx, vec3 ddy,
	vec3 blending, int pmode, vec3 mean
) {
	if (pmode == 1) {
		return hextile_rgb(tex, pos.xz, ddx.xz, ddy.xz, mean, 11u, u_hex_rotation);
	}
	if (pmode == 2) {
		return hextile_rgb(tex, pos.yz, ddx.yz, ddy.yz, mean, 5u, u_hex_rotation);
	}
	if (pmode == 3) {
		return hextile_rgb(tex, pos.xy, ddx.xy, ddy.xy, mean, 23u, u_hex_rotation);
	}
	return hextile_rgb(tex, pos.yz, ddx.yz, ddy.yz, mean, 5u, u_hex_rotation) * blending.x
		+ hextile_rgb(tex, pos.xz, ddx.xz, ddy.xz, mean, 11u, u_hex_rotation) * blending.y
		+ hextile_rgb(tex, pos.xy, ddx.xy, ddy.xy, mean, 23u, u_hex_rotation) * blending.z;
}

// Hex-tiled triplanar normal, whiteout blend (conventions from
// triplanar_normal.gdshaderinc: mode 1 = Y plane, 2 = X, 3 = Z).
vec3 hex_triplanar_normal(
	sampler2D tex, vec3 pos, vec3 ddx, vec3 ddy,
	vec3 wn, vec3 blending, int pmode
) {
	if (pmode == 1) {
		vec3 tn = hextile_normal(tex, pos.xz, ddx.xz, ddy.xz, 11u, u_hex_rotation);
		tn = vec3(tn.xy + wn.xz, abs(tn.z) * wn.y);
		return normalize(tn.xzy);
	}
	if (pmode == 2) {
		vec3 tn = hextile_normal(tex, pos.yz, ddx.yz, ddy.yz, 5u, u_hex_rotation);
		tn = vec3(tn.xy + wn.zy, abs(tn.z) * wn.x);
		return normalize(tn.zyx);
	}
	if (pmode == 3) {
		vec3 tn = hextile_normal(tex, pos.xy, ddx.xy, ddy.xy, 23u, u_hex_rotation);
		tn = vec3(tn.xy + wn.xy, abs(tn.z) * wn.z);
		return normalize(tn.xyz);
	}
	vec3 nx = hextile_normal(tex, pos.yz, ddx.yz, ddy.yz, 5u, u_hex_rotation);
	vec3 ny = hextile_normal(tex, pos.xz, ddx.xz, ddy.xz, 11u, u_hex_rotation);
	vec3 nz = hextile_normal(tex, pos.xy, ddx.xy, ddy.xy, 23u, u_hex_rotation);
	nx = vec3(nx.xy + wn.zy, abs(nx.z) * wn.x);
	ny = vec3(ny.xy + wn.xz, abs(ny.z) * wn.y);
	nz = vec3(nz.xy + wn.xy, abs(nz.z) * wn.z);
	return normalize(
		nx.zyx * blending.x + ny.xzy * blending.y + nz.xyz * blending.z
	);
}

// Plain (non-hex) planar samplers taking explicit gradients. Implicit
// derivatives are unusable here for the same precision reason as above.
vec3 planar_rgb_grad(sampler2D tex, vec3 pos, vec3 gx, vec3 gy, vec3 blend, int mode) {
	if (mode == 1) {
		return textureGrad(tex, pos.xz, gx.xz, gy.xz).rgb;
	}
	if (mode == 2) {
		return textureGrad(tex, pos.yz, gx.yz, gy.yz).rgb;
	}
	if (mode == 3) {
		return textureGrad(tex, pos.xy, gx.xy, gy.xy).rgb;
	}
	return textureGrad(tex, pos.yz, gx.yz, gy.yz).rgb * blend.x
		+ textureGrad(tex, pos.xz, gx.xz, gy.xz).rgb * blend.y
		+ textureGrad(tex, pos.xy, gx.xy, gy.xy).rgb * blend.z;
}

float planar_r_grad(sampler2D tex, vec3 pos, vec3 gx, vec3 gy, vec3 blend, int mode) {
	if (mode == 1) {
		return textureGrad(tex, pos.xz, gx.xz, gy.xz).r;
	}
	if (mode == 2) {
		return textureGrad(tex, pos.yz, gx.yz, gy.yz).r;
	}
	if (mode == 3) {
		return textureGrad(tex, pos.xy, gx.xy, gy.xy).r;
	}
	return textureGrad(tex, pos.yz, gx.yz, gy.yz).r * blend.x
		+ textureGrad(tex, pos.xz, gx.xz, gy.xz).r * blend.y
		+ textureGrad(tex, pos.xy, gx.xy, gy.xy).r * blend.z;
}

// Whiteout-blended planar normal with explicit gradients (plane conventions
// match triplanar_normal.gdshaderinc: mode 1 = Y, 2 = X, 3 = Z).
vec3 planar_normal_grad(
	sampler2D tex, vec3 pos, vec3 gx, vec3 gy, vec3 wn, vec3 blend, int mode
) {
	if (mode == 1) {
		vec3 tn = textureGrad(tex, pos.xz, gx.xz, gy.xz).xyz * 2.0 - 1.0;
		tn = vec3(tn.xy + wn.xz, abs(tn.z) * wn.y);
		return normalize(tn.xzy);
	}
	if (mode == 2) {
		vec3 tn = textureGrad(tex, pos.yz, gx.yz, gy.yz).xyz * 2.0 - 1.0;
		tn = vec3(tn.xy + wn.zy, abs(tn.z) * wn.x);
		return normalize(tn.zyx);
	}
	if (mode == 3) {
		vec3 tn = textureGrad(tex, pos.xy, gx.xy, gy.xy).xyz * 2.0 - 1.0;
		tn = vec3(tn.xy + wn.xy, abs(tn.z) * wn.z);
		return normalize(tn.xyz);
	}
	vec3 nx = textureGrad(tex, pos.yz, gx.yz, gy.yz).xyz * 2.0 - 1.0;
	vec3 ny = textureGrad(tex, pos.xz, gx.xz, gy.xz).xyz * 2.0 - 1.0;
	vec3 nz = textureGrad(tex, pos.xy, gx.xy, gy.xy).xyz * 2.0 - 1.0;
	nx = vec3(nx.xy + wn.zy, abs(nx.z) * wn.x);
	ny = vec3(ny.xy + wn.xz, abs(ny.z) * wn.y);
	nz = vec3(nz.xy + wn.xy, abs(nz.z) * wn.z);
	return normalize(nx.zyx * blend.x + ny.xzy * blend.y + nz.xyz * blend.z);
}

// One material layer: micro/meso cross-fade for albedo+normal, near-scale
// triplanar for AO/roughness (their tiling is invisible; saves fetches).
void sample_layer(
	sampler2D t_alb, sampler2D t_nrm, sampler2D t_ao, sampler2D t_rough,
	vec3 uv_off, vec3 wpos, vec3 dpx, vec3 dpy,
	float far_w, float near_variance, vec3 blending, int pmode, vec3 wn,
	out vec3 albedo, out vec3 nrm, out float ao, out float rough
) {
	// Top mip = texture mean, pivot for hex contrast restore.
	vec3 mean = textureLod(t_alb, vec2(0.5), 12.0).rgb;
	vec3 p = wpos + uv_off;
	float far_scale = u_detail_scale / max(u_far_ratio, 1.0);

	vec3 a_near = vec3(0.0);
	vec3 a_far = vec3(0.0);
	vec3 n_near = wn;
	vec3 n_far = wn;
	if (far_w < 1.0) {
		vec3 pn = p * u_detail_scale;
		vec3 gx = dpx * u_detail_scale;
		vec3 gy = dpy * u_detail_scale;
		a_near = hex_triplanar_rgb(t_alb, pn, gx, gy, blending, pmode, mean);
		a_near = mix(mean, a_near, near_variance);
		n_near = hex_triplanar_normal(t_nrm, pn, gx, gy, wn, blending, pmode);
	}
	if (far_w > 0.0) {
		vec3 pf = p * far_scale;
		vec3 gx = dpx * far_scale;
		vec3 gy = dpy * far_scale;
		a_far = hex_triplanar_rgb(t_alb, pf, gx, gy, blending, pmode, mean);
		a_far = mix(mean, a_far, u_albedo_variance * u_far_variance);
		n_far = hex_triplanar_normal(t_nrm, pf, gx, gy, wn, blending, pmode);
		n_far = normalize(mix(wn, n_far, u_far_normal));
	}
	albedo = mix(a_near, a_far, far_w);
	nrm = normalize(mix(n_near, n_far, far_w));

	if (far_w < 1.0) {
		vec3 pn = p * u_detail_scale;
		vec3 gx = dpx * u_detail_scale;
		vec3 gy = dpy * u_detail_scale;
		ao = planar_r_grad(t_ao, pn, gx, gy, blending, pmode);
		rough = planar_r_grad(t_rough, pn, gx, gy, blending, pmode);
	} else {
		ao = 1.0;
		rough = 0.85;
	}
}

// The only color grade in the pipeline: kill photo chroma (lunar crust is
// near-grey), one contrast pivot, one exposure, done.
vec3 grade_lunar(vec3 c) {
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(l), c, u_chroma);
	c = vec3(0.32) + (c - vec3(0.32)) * u_contrast;
	return clamp(c * u_exposure, vec3(0.02), vec3(0.95));
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
	// In the fragment stage VERTEX is already the view-space position, so its
	// length IS the camera distance. Do NOT use CAMERA_POSITION_WORLD here:
	// measured in this build it does not agree with v_world_pos (equal radii,
	// ~19 km apart), which pinned view_dist at ~19000 m — every fragment,
	// including ground underfoot, was then drawn with the far band (80 m
	// texture period, flattened contrast, damped normals, AO/roughness
	// skipped). That was the "soapy up close" bug.
	float view_dist = length(VERTEX);

	vec3 surface_up = u_radial_up > 0.5 ? normalize(wpos) : vec3(0.0, 1.0, 0.0);
	float upness = clamp(dot(normal, surface_up), -1.0, 1.0);
	float slope = clamp(1.0 - upness, 0.0, 1.0);
	// How close the face is to vertical (floor/ceiling → 0, wall → 1).
	// Sphere-carve "walls" are rarely true vertical; this still reads them.
	float wallness = clamp(1.0 - abs(upness), 0.0, 1.0);

	// Height vs mean sphere — crater bowls sit below 0.
	float h_signal = u_planet_radius > 0.0
		? (length(wpos) - u_planet_radius)
		: wpos.y;

	vec3 blending = get_triplanar_blend(normal, BLEND_SHARPNESS);
	int pmode = planar_mode(blending, PLANAR_THRESH);

	vec3 meter_pos = surface_meter_pos(wpos);
	vec3 surf_dir = u_radial_up > 0.5 ? surface_up : vec3(0.0, 1.0, 0.0);

	// --- Layer masks: slope + height + ONE breakup noise -------------------
	float steep = smoothstep(0.16, 0.34, slope);
	float breakup = fbm_surface(meter_pos, surf_dir, u_biome_scale * 1.3);
	// Breakup jitters the height contours — a clean isoline reads as a
	// paint spill; the ragged edge reads as sediment.
	float depth_n = h_signal + (breakup - 0.5) * 10.0;
	// Crater floor core + slope run-outs easing into the floor.
	float bowl = smoothstep(6.0, -12.0, depth_n);
	float foot = smoothstep(0.30, 0.10, slope)
		* smoothstep(14.0, 0.0, depth_n) * 0.6;
	// Basin patches only in genuine depressions on near-flat ground —
	// mid-slope splats read as vitiligo.
	float basin = smoothstep(0.52, 0.72, breakup) * u_mare_amount
		* smoothstep(2.0, -6.0, h_signal)
		* (1.0 - smoothstep(0.06, 0.16, slope));
	// Lunar is the base everywhere; the other two only mix in, never take over.
	float w_mare = clamp(max(bowl, foot) + basin, 0.0, 1.0)
		* (1.0 - steep) * u_mare_mix;
	// Optional ragged edge so wall packs don't paint continuous iso-bands.
	float wall_m = steep;
	if (u_wall_breakup > 0.001) {
		float ragged = smoothstep(0.30, 0.62, breakup);
		wall_m *= mix(1.0, ragged, u_wall_breakup);
	}
	float w_dust = wall_m * u_wall_mix;
	float w_rock = max(1.0 - w_dust - w_mare, 0.0);
	float w_sum = max(w_rock + w_dust + w_mare, 1e-3);
	w_rock /= w_sum;
	w_dust /= w_sum;
	w_mare /= w_sum;

	// --- Micro/meso sampling ----------------------------------------------
	float far_w = smoothstep(u_far_start, u_far_end, view_dist);
	if (far_w <= 0.02) {
		far_w = 0.0;
	}
	if (far_w >= 0.98) {
		far_w = 1.0;
	}
	float grad_bias = exp2(u_mip_bias);
	// Derivatives MUST come from model space. v_world_pos carries the planet
	// radius (~9500 m), where float32 steps are ~1 mm; a screen pixel close
	// to the camera spans ~2.5 mm, so dFdx(v_world_pos) is ~40 % quantization
	// noise and textureGrad then picks mips far too coarse — that is what
	// made the ground look soapy underfoot. Chunk-local coords are small, so
	// their derivatives are exact; the basis maps them back to world scale.
	mat3 model_basis = mat3(MODEL_MATRIX);
	vec3 dpx = model_basis * dFdx(v_vertex_pos_model) * grad_bias;
	vec3 dpy = model_basis * dFdy(v_vertex_pos_model) * grad_bias;
	// Close up the photo's own contrast is the detail; mid-range it is noise.
	float near_w = 1.0 - smoothstep(0.0, u_variance_near_end, view_dist);
	float near_variance = mix(u_albedo_variance, u_albedo_variance_near, near_w);

	vec3 albedo_rock = vec3(0.0);
	vec3 albedo_dust = vec3(0.0);
	vec3 albedo_mare = vec3(0.0);
	vec3 n_rock = normal;
	vec3 n_dust = normal;
	vec3 n_mare = normal;
	float ao_rock = 1.0;
	float ao_dust = 1.0;
	float ao_mare = 1.0;
	float rough_rock = 0.80;
	float rough_dust = 0.90;
	float rough_mare = 0.85;

	if (w_rock > LAYER_CULL) {
		sample_layer(
			u_rock_albedo, u_rock_normal, u_rock_ao, u_rock_roughness,
			vec3(0.0), wpos, dpx, dpy, far_w, near_variance, blending, pmode, normal,
			albedo_rock, n_rock, ao_rock, rough_rock
		);
	}
	if (w_dust > LAYER_CULL) {
		sample_layer(
			u_dust_albedo, u_dust_normal, u_dust_ao, u_dust_roughness,
			vec3(17.0, -9.0, 5.0), wpos, dpx, dpy, far_w, near_variance,
			blending, pmode, normal,
			albedo_dust, n_dust, ao_dust, rough_dust
		);
	}
	if (w_mare > LAYER_CULL) {
		sample_layer(
			u_mare_albedo, u_mare_normal, u_mare_ao, u_mare_roughness,
			vec3(-11.0, 6.0, 13.0), wpos, dpx, dpy, far_w, near_variance,
			blending, pmode, normal,
			albedo_mare, n_mare, ao_mare, rough_mare
		);
	}

	// --- Layer tone equalization ------------------------------------------
	// Everything is the same powder; value differences between layers come
	// from the baked brightness map, not from the source photos' exposure.
	float l_ref = dot(textureLod(u_rock_albedo, vec2(0.5), 12.0).rgb, vec3(0.299, 0.587, 0.114));
	float l_dust = dot(textureLod(u_dust_albedo, vec2(0.5), 12.0).rgb, vec3(0.299, 0.587, 0.114));
	float l_mare = dot(textureLod(u_mare_albedo, vec2(0.5), 12.0).rgb, vec3(0.299, 0.587, 0.114));
	// Walls keep half their darkness (fresh rock under the dust reads well).
	albedo_dust *= mix(1.0, l_ref / max(l_dust, 1e-3), u_layer_equalize * 0.5);
	albedo_mare *= mix(1.0, l_ref / max(l_mare, 1e-3), u_layer_equalize);

	// --- Height-proxy blend sharpening ------------------------------------
	// Albedo luminance stands in for a heightmap: brighter chunks win the
	// border, so transitions read "rock pokes through dust", not a gradient.
	const float BLEND_DELTA = 0.22;
	float h_rock = dot(albedo_rock, vec3(0.333));
	float h_dust = dot(albedo_dust, vec3(0.333));
	float h_mare = dot(albedo_mare, vec3(0.333));
	float a_rock = w_rock > LAYER_CULL ? w_rock + h_rock * u_height_blend : -1.0;
	float a_dust = w_dust > LAYER_CULL ? w_dust + h_dust * u_height_blend : -1.0;
	float a_mare = w_mare > LAYER_CULL ? w_mare + h_mare * u_height_blend : -1.0;
	float a_max = max(a_rock, max(a_dust, a_mare));
	float b_rock = max(a_rock - a_max + BLEND_DELTA, 0.0);
	float b_dust = max(a_dust - a_max + BLEND_DELTA, 0.0);
	float b_mare = max(a_mare - a_max + BLEND_DELTA, 0.0);
	float b_sum = max(b_rock + b_dust + b_mare, 1e-3);
	b_rock /= b_sum;
	b_dust /= b_sum;
	b_mare /= b_sum;

	// Split wall albedo vs detail so a grit pack can ride normals without
	// painting a second photo tone over the refined base. Optional gate uses
	// wallness (not slope): slope treats ceilings as steep, wallness only
	// true side-walls — matches dig adits / scarps.
	float albedo_gate = 1.0;
	if (u_wall_albedo_end > 0.001) {
		albedo_gate = smoothstep(u_wall_albedo_start, u_wall_albedo_end, wallness);
	}
	float albedo_w = u_wall_albedo_mix * albedo_gate;
	float ab_dust = b_dust * albedo_w;
	float ab_rock = b_rock + b_dust * (1.0 - albedo_w);
	float ab_mare = b_mare;
	float ab_sum = max(ab_rock + ab_dust + ab_mare, 1e-3);
	ab_rock /= ab_sum;
	ab_dust /= ab_sum;
	ab_mare /= ab_sum;

	float db_dust = b_dust * u_wall_detail;
	float db_rock = b_rock + b_dust * (1.0 - u_wall_detail);
	float db_mare = b_mare;
	float db_sum = max(db_rock + db_dust + db_mare, 1e-3);
	db_rock /= db_sum;
	db_dust /= db_sum;
	db_mare /= db_sum;

	vec3 tex_col = albedo_rock * ab_rock + albedo_dust * ab_dust + albedo_mare * ab_mare;

	// --- Micro band: grain that survives magnification ---------------------
	// Base texels are ~0.65 cm, so a few metres out the photo is stretched
	// past its own resolution. Add the base texture again at u_micro_ratio
	// times the frequency, as a value modulation plus normal detail. It is
	// modulation (not base color) and dies by ~14 m, so plain repeat is safe
	// and the planar fast path keeps it at one or three fetches.
	float micro_w = 1.0 - smoothstep(0.0, u_micro_start, view_dist);
	vec3 micro_normal_add = vec3(0.0);
	if (micro_w > 0.01) {
		float ms = u_detail_scale * u_micro_ratio;
		vec3 pm = wpos * ms;
		vec3 gx = dpx * ms;
		vec3 gy = dpy * ms;
		vec3 d = planar_rgb_grad(u_rock_albedo, pm, gx, gy, blending, pmode);
		float d_l = dot(d, vec3(0.333));
		float d_mean = dot(textureLod(u_rock_albedo, vec2(0.5), 12.0).rgb, vec3(0.333));
		float grain = d_l / max(d_mean, 1e-3);
		tex_col *= mix(1.0, grain, micro_w * u_micro_strength);
		vec3 nm = planar_normal_grad(u_rock_normal, pm, gx, gy, normal, blending, pmode);
		micro_normal_add = (nm - normal) * micro_w * u_micro_normal;
	}

	// --- Macro band: one value fbm + baked brightness map -----------------
	float macro_n = fbm_surface(meter_pos, surf_dir, u_large_scale);
	tex_col *= mix(1.0, mix(0.93, 1.07, smoothstep(0.25, 0.75, macro_n)), u_macro_strength);

	float ao = ao_rock * db_rock + ao_dust * db_dust + ao_mare * db_mare;
	// AO fades with distance — at meso scale it would just shimmer.
	tex_col *= mix(1.0, ao, u_ao_strength * (1.0 - far_w * 0.7));

	if (u_moon_brightness_on > 0.5 && u_radial_up > 0.5) {
		// Equirect by radial dir; must mirror bake_brightness_panorama mapping.
		vec2 buv = vec2(
			0.5 - atan(surface_up.z, surface_up.x) / 6.28318530718,
			acos(clamp(surface_up.y, -1.0, 1.0)) / 3.14159265359
		);
		float bright = texture(u_moon_brightness, buv).r * 1.5;
		tex_col *= mix(1.0, bright, u_moon_brightness_strength);
	}

	ALBEDO = grade_lunar(tex_col);

	vec3 normal_perturb =
		(n_rock - normal) * db_rock
		+ (n_dust - normal) * db_dust
		+ (n_mare - normal) * db_mare;
	vec3 final_normal = normalize(
		normal + normal_perturb * u_normal_strength + micro_normal_add
	);
	NORMAL = normalize((VIEW_MATRIX * vec4(final_normal, 0.0)).xyz);

	float rough = rough_rock * db_rock + rough_dust * db_dust + rough_mare * db_mare;
	ROUGHNESS = clamp(rough, 0.70, 0.97);
	METALLIC = 0.0;
	SPECULAR = mix(u_specular * 0.7, u_specular * 1.05, db_rock);

	if (get_lod_fade_discard(SCREEN_UV)) {
		discard;
	}
}
