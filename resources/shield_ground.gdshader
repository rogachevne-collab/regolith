shader_type spatial;
render_mode cull_back;

// The ground of the shield drive: three photographed grounds mixed by the data
// the drive already keeps, plus the whole of the depth cut.
//
// It replaces three flat colours and a rust tint. What the tint said is still
// said, by material rather than by hue:
//
//   * soil  — the untouched sandy layer nobody has been near;
//   * rock  — the hill the drive has to go through or under;
//   * spoil — gravel: everything inside the envelope the machine has taken out,
//     which is the bore walls, the muck heap and every cell that has fallen
//     back into its own tunnel.
//
// Triplanar in world space, because the surface is marching cubes and has no
// UVs at all, and because a tunnel wall is vertical — a single planar
// projection would smear the whole of the bore.
//
// World position without `MODEL_MATRIX` and without anything derived from the
// camera: the chunk instances carry a pure scale by the cell size and no
// translation at all (see `_mesh_chunk`), so a vertex's own coordinates — the
// mesher emits vertices in cell units — are the world position over the cell
// size. This build's camera-relative world transforms make
// `CAMERA_POSITION_WORLD` and everything like it unreliable; nothing here is
// allowed to depend on it, and the cut map is read in world XZ for the same
// reason. `length(VERTEX)` is the camera distance if one is ever needed.
//
// The bilinear over the cut map is written out by hand over `texelFetch` rather
// than left to the sampler, and that is not fussiness. Two reasons. The lid is
// built out of the same map on the CPU and the two have to agree to the
// centimetre — a lid drawn a hair off the height fragments are thrown away at is
// a hairline gap running the length of the trench — and writing the filter out is
// the only way to be sure both are computing the same thing. And a 32-bit float
// texture is not guaranteed to be filterable at all: `filter_linear` on it is a
// driver-dependent black screen waiting to happen.
//
// The cut *has* to be interpolated and not stepped. Quantised to the cell it
// already quantises to, the flare came out as a field of loose tiles — the slope
// is shallow, so half the trace straddled a cell boundary and dithered between
// two levels. That reads as breakage, not as a slope.

#include "res://resources/triplanar_normal.gdshaderinc"

// Above this the surface is flat enough for one planar sample instead of three.
// The mesher's normals wander, so most fragments still take the three; the ones
// that do not are the flat trench floor and the flat top of the sand, which is
// most of the screen in the section view.
const float SHIELD_PLANAR_THRESH = 0.90;
// Below this share a ground is not sampled at all. Three sets of five maps is
// forty-five taps if nothing is culled and about twelve if the culling works,
// and it works because two of the three weights are zero almost everywhere.
const float SHIELD_LAYER_CULL = 0.015;

// --- the depth cut ------------------------------------------------------------

uniform float cell_size = 0.5;
uniform bool cut_on = false;
uniform bool dug_on = true;
uniform float map_cell = 1.0;
uniform vec2 map_dim = vec2(120.0, 48.0);
// r: the height of the cut. g, b: the bottom and the top of the volume the
// machine has taken out of this column. a: the top of the rock in it.
uniform sampler2D cut_map : filter_nearest, repeat_disable, hint_default_black;

// --- the three grounds --------------------------------------------------------
//
// Albedo carries `source_color` and nothing else does, and that is the whole of
// the sRGB question in a custom shader: `source_color` binds the texture's sRGB
// view and every other hint binds the linear one. Roughness, AO and height read
// through a colour transform are a surface that is far too smooth in the mids
// and far too rough at the ends — wet plastic, for no visible reason.

uniform sampler2D soil_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_rough : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_ao : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_height : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_rough : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_ao : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_height : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D spoil_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D spoil_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D spoil_rough : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D spoil_ao : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D spoil_height : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

// How many metres of ground one tile of each photograph covers.
uniform float soil_scale_m = 3.0;
uniform float rock_scale_m = 4.0;
uniform float spoil_scale_m = 1.6;

uniform vec4 soil_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 rock_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 spoil_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform float soil_rough_gain = 1.0;
uniform float rock_rough_gain = 1.0;
uniform float spoil_rough_gain = 1.0;

// The volume's old rust tint over worked ground. Zero by default: the gravel is
// the reading now. The lid and the plan keep the rust, and are untouched.
uniform vec4 dug_tint : source_color = vec4(0.86, 0.42, 0.18, 1.0);
uniform float dug_mix : hint_range(0.0, 1.0) = 0.0;

// This material draws the rock field's own mesh, which is rock everywhere.
uniform bool all_rock = false;
// Blend down into the rock set under the top of the rock. The sand field draws
// the rock's own solid cells wherever they touch loose material, so without this
// the two meshes stand in the same place wearing two different grounds.
uniform bool rock_line_on = true;
// How wide every one of these boundaries is, metres.
uniform float blend_m : hint_range(0.05, 4.0) = 0.7;
// How far the boundary is allowed to wander off the map's own metre grid. This
// is what stops the transition being a staircase along the lattice.
uniform float blend_warp_m : hint_range(0.0, 4.0) = 1.1;
uniform float triplanar_sharpness : hint_range(1.0, 16.0) = 4.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 0.7;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
// Height-driven blending: let the coarser ground poke through the finer one at
// the boundary instead of cross-fading it. Off by default — it costs three more
// taps and the boundary is legible without it.
uniform bool height_blend = false;
uniform float height_blend_sharp : hint_range(0.02, 1.0) = 0.25;

varying vec3 world_pos;
varying vec3 world_normal;

// The cut surface, in metres, at a point on the trace. Texel centres sit half a
// map cell in from the corner of the box, which is what the lid assumes too.
float cut_at(vec2 p) {
	vec2 t = p / map_cell - vec2(0.5);
	vec2 f = fract(t);
	ivec2 last = ivec2(map_dim) - ivec2(1);
	ivec2 lo = clamp(ivec2(floor(t)), ivec2(0), last);
	ivec2 hi = clamp(ivec2(floor(t)) + ivec2(1), ivec2(0), last);
	float h00 = texelFetch(cut_map, ivec2(lo.x, lo.y), 0).r;
	float h10 = texelFetch(cut_map, ivec2(hi.x, lo.y), 0).r;
	float h01 = texelFetch(cut_map, ivec2(lo.x, hi.y), 0).r;
	float h11 = texelFetch(cut_map, ivec2(hi.x, hi.y), 0).r;
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

// Integer-stable hash. A sin-hash goes to mush a few hundred metres out, and the
// trace is a hundred and twenty of them.
float shield_hash(vec2 p) {
	uvec2 u = uvec2(ivec2(floor(p)));
	uint n = u.x * 1597334677u + u.y * 3812015801u;
	n ^= n >> 13u;
	n *= 1274126177u;
	return float(n & 0x7fffffffu) / 2147483647.0;
}

float shield_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(shield_hash(i), shield_hash(i + vec2(1.0, 0.0)), f.x),
		mix(shield_hash(i + vec2(0.0, 1.0)), shield_hash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

// Where a boundary is *asked* about, rather than where it is. Both the worked
// envelope and the rock top are per-column facts on a one-metre lattice; read
// straight, every boundary they draw is an axis-aligned staircase. Two octaves
// of value noise move the question a metre or so off the lattice, and the
// staircase becomes the ragged edge a dug face actually has.
vec3 warp_point(vec3 p) {
	if (blend_warp_m <= 0.001) {
		return p;
	}
	float n0 = shield_noise(p.xz * 0.85 + vec2(p.y * 0.35)) - 0.5;
	float n1 = shield_noise(p.zy * 0.85 + vec2(p.x * 0.35 + 19.7)) - 0.5;
	return p + vec3(n0, n1 * 0.6, n1) * 2.0 * blend_warp_m;
}

// How much of one map column is worked ground at a height. An empty span — the
// machine never came here — is zero at every height.
float worked_at(ivec2 c, float y, float feather) {
	vec2 span = texelFetch(cut_map, c, 0).gb;
	if (span.y < span.x) {
		return 0.0;
	}
	return smoothstep(span.x - feather, span.x + feather, y)
		* (1.0 - smoothstep(span.y - feather, span.y + feather, y));
}

// The same, bilinear across the four columns around a point. The envelope is a
// fact about one column and the lid reads it flat for exactly that reason; here
// it is smeared over the map's own metre on purpose, because what this decides
// is not *whether* a cell was dug but *what the ground looks like*, and a
// material boundary that snaps at a metre grid is the one thing this whole
// change exists to avoid.
float worked_share(vec3 p) {
	float feather = max(blend_m, 0.01);
	vec2 t = p.xz / map_cell - vec2(0.5);
	vec2 f = fract(t);
	ivec2 last = ivec2(map_dim) - ivec2(1);
	ivec2 lo = clamp(ivec2(floor(t)), ivec2(0), last);
	ivec2 hi = clamp(ivec2(floor(t)) + ivec2(1), ivec2(0), last);
	float w00 = worked_at(ivec2(lo.x, lo.y), p.y, feather);
	float w10 = worked_at(ivec2(hi.x, lo.y), p.y, feather);
	float w01 = worked_at(ivec2(lo.x, hi.y), p.y, feather);
	float w11 = worked_at(ivec2(hi.x, hi.y), p.y, feather);
	return mix(mix(w00, w10, f.x), mix(w01, w11, f.x), f.y);
}

// The top of the rock, in metres, bilinear over the same four columns. Zero
// where the machine has eaten the whole column, which is below the floor of the
// trace and so never wins.
float rock_top_at(vec2 p) {
	vec2 t = p / map_cell - vec2(0.5);
	vec2 f = fract(t);
	ivec2 last = ivec2(map_dim) - ivec2(1);
	ivec2 lo = clamp(ivec2(floor(t)), ivec2(0), last);
	ivec2 hi = clamp(ivec2(floor(t)) + ivec2(1), ivec2(0), last);
	float h00 = texelFetch(cut_map, ivec2(lo.x, lo.y), 0).a;
	float h10 = texelFetch(cut_map, ivec2(hi.x, lo.y), 0).a;
	float h01 = texelFetch(cut_map, ivec2(lo.x, hi.y), 0).a;
	float h11 = texelFetch(cut_map, ivec2(hi.x, hi.y), 0).a;
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

void sample_ground(
	sampler2D albedo_tex,
	sampler2D normal_tex,
	sampler2D rough_tex,
	sampler2D ao_tex,
	vec3 p,
	float scale_m,
	vec3 geometry_normal,
	vec3 blending,
	int mode,
	out vec3 out_albedo,
	out vec3 out_normal,
	out float out_rough,
	out float out_ao
) {
	vec3 uvw = p / max(scale_m, 0.01);
	out_albedo = sample_planar_rgb(albedo_tex, uvw, blending, mode);
	out_normal = sample_planar_normal(
		normal_tex, uvw, geometry_normal, blending, mode
	);
	out_rough = sample_planar_r(rough_tex, uvw, blending, mode);
	out_ao = sample_planar_r(ao_tex, uvw, blending, mode);
}

// Exponential height blend: at a given mix the taller of the two grounds takes
// the fragment outright, so gravel sits *in* the sand rather than dissolving
// into it.
float height_weighted(float t, float below, float above) {
	float d = max(height_blend_sharp, 0.001);
	float a = (1.0 - t) * exp(below / d);
	float b = t * exp(above / d);
	return clamp(b / max(a + b, 1e-6), 0.0, 1.0);
}

void vertex() {
	world_pos = VERTEX * cell_size;
	// The instance transform is a pure uniform scale, so the model normal is the
	// world normal. Nothing here goes through MODEL_NORMAL_MATRIX or the camera.
	world_normal = normalize(NORMAL);
}

void fragment() {
	vec3 p = world_pos;
	if (cut_on && p.y > cut_at(p.xz)) {
		discard;
	}

	vec3 geometry_normal = normalize(world_normal);
	vec3 blending = pow(abs(geometry_normal), vec3(triplanar_sharpness));
	blending /= max(blending.x + blending.y + blending.z, 0.0001);
	int mode = planar_mode(blending, SHIELD_PLANAR_THRESH);

	float w_rock = 1.0;
	float w_spoil = 0.0;
	if (!all_rock) {
		vec3 q = warp_point(p);
		w_rock = rock_line_on
			? 1.0 - smoothstep(
				rock_top_at(q.xz) - max(blend_m, 0.01),
				rock_top_at(q.xz) + max(blend_m, 0.01),
				q.y
			)
			: 0.0;
		w_spoil = dug_on ? worked_share(q) : 0.0;
	}

	if (height_blend) {
		float h_soil = sample_planar_r(soil_height, p / max(soil_scale_m, 0.01), blending, mode);
		float h_rock = sample_planar_r(rock_height, p / max(rock_scale_m, 0.01), blending, mode);
		float h_spoil = sample_planar_r(spoil_height, p / max(spoil_scale_m, 0.01), blending, mode);
		w_rock = height_weighted(w_rock, h_soil, h_rock);
		w_spoil = height_weighted(w_spoil, mix(h_soil, h_rock, w_rock), h_spoil);
	}

	float k_spoil = clamp(w_spoil, 0.0, 1.0);
	float k_rock = clamp(w_rock, 0.0, 1.0) * (1.0 - k_spoil);
	float k_soil = 1.0 - k_spoil - k_rock;

	vec3 albedo = vec3(0.0);
	vec3 normal_sum = vec3(0.0);
	float rough = 0.0;
	float ao = 0.0;
	float total = 0.0;

	vec3 s_albedo;
	vec3 s_normal;
	float s_rough;
	float s_ao;

	if (k_soil > SHIELD_LAYER_CULL) {
		sample_ground(
			soil_albedo, soil_normal, soil_rough, soil_ao,
			p, soil_scale_m, geometry_normal, blending, mode,
			s_albedo, s_normal, s_rough, s_ao
		);
		albedo += s_albedo * soil_tint.rgb * k_soil;
		normal_sum += s_normal * k_soil;
		rough += s_rough * soil_rough_gain * k_soil;
		ao += s_ao * k_soil;
		total += k_soil;
	}
	if (k_rock > SHIELD_LAYER_CULL) {
		sample_ground(
			rock_albedo, rock_normal, rock_rough, rock_ao,
			p, rock_scale_m, geometry_normal, blending, mode,
			s_albedo, s_normal, s_rough, s_ao
		);
		albedo += s_albedo * rock_tint.rgb * k_rock;
		normal_sum += s_normal * k_rock;
		rough += s_rough * rock_rough_gain * k_rock;
		ao += s_ao * k_rock;
		total += k_rock;
	}
	if (k_spoil > SHIELD_LAYER_CULL) {
		sample_ground(
			spoil_albedo, spoil_normal, spoil_rough, spoil_ao,
			p, spoil_scale_m, geometry_normal, blending, mode,
			s_albedo, s_normal, s_rough, s_ao
		);
		albedo += s_albedo * spoil_tint.rgb * k_spoil;
		normal_sum += s_normal * k_spoil;
		rough += s_rough * spoil_rough_gain * k_spoil;
		ao += s_ao * k_spoil;
		total += k_spoil;
	}
	float inv = 1.0 / max(total, 1e-4);
	albedo *= inv;
	rough *= inv;
	ao *= inv;

	vec3 shaded = normalize(
		mix(geometry_normal, normalize(normal_sum + geometry_normal * 1e-4), normal_strength)
	);

	ALBEDO = mix(albedo, dug_tint.rgb, dug_mix * k_spoil);
	NORMAL = normalize((VIEW_MATRIX * vec4(shaded, 0.0)).xyz);
	ROUGHNESS = clamp(rough, 0.05, 1.0);
	METALLIC = 0.0;
	AO = mix(1.0, clamp(ao, 0.0, 1.0), ao_strength);
	AO_LIGHT_AFFECT = 1.0;
}
