// Stochastic hex-tiling ("tiling and blending", Heitz–Neyret 2018 / Burley 2019).
// Every triangle-grid tile samples the source photo at a random offset+rotation;
// the three nearest tiles blend with variance-preserving weights so blend zones
// keep the photo's contrast instead of averaging to grey. This is the single
// anti-tiling mechanism of the terrain material — no high-pass, no second
// scales, no offset variants needed on top.

const float HEXTILE_TAU = 6.28318530718;
// Triangle-grid density in UV space. 2*sqrt(3) → tile edge ≈ half a texture
// period, so repetition is broken well below the period of the photo.
const float HEXTILE_GRID = 3.46410162;

// Integer hash — sin-hash turns to mush at planet-scale coordinates.
float hextile_hash(ivec2 v, uint seed) {
	uvec2 u = uvec2(v);
	uint n = u.x * 1597334677u ^ u.y * 3812015801u ^ seed * 668265263u;
	n ^= n >> 13u;
	n *= 1274126177u;
	n ^= n >> 16u;
	return float(n) * (1.0 / 4294967296.0);
}

void hextile_grid(vec2 uv, out vec3 w, out ivec2 v1, out ivec2 v2, out ivec2 v3) {
	vec2 skewed = mat2(vec2(1.0, 0.0), vec2(-0.57735027, 1.15470054))
		* (uv * HEXTILE_GRID);
	ivec2 base = ivec2(floor(skewed));
	vec2 f = fract(skewed);
	float z = 1.0 - f.x - f.y;
	if (z > 0.0) {
		w = vec3(z, f.y, f.x);
		v1 = base;
		v2 = base + ivec2(0, 1);
		v3 = base + ivec2(1, 0);
	} else {
		w = vec3(-z, 1.0 - f.y, 1.0 - f.x);
		v1 = base + ivec2(1, 1);
		v2 = base + ivec2(1, 0);
		v3 = base + ivec2(0, 1);
	}
	// Narrow the blend zones, keep partition of unity.
	w = w * w * w;
	w /= (w.x + w.y + w.z);
}

// Random rotation + offset for one tile. Same (v, seed) always yields the same
// transform, so albedo and normal fetched with equal seeds stay aligned.
// rot_jitter is the fraction of a full turn: keep it small for anisotropic
// (striated) photos — full random rotation reads as a surreal swirl patchwork;
// the random offsets alone already break repetition.
vec2 hextile_uv(vec2 uv, ivec2 v, uint seed, float rot_jitter, out mat2 rot) {
	float a = (hextile_hash(v, seed) - 0.5) * HEXTILE_TAU * rot_jitter;
	float s = sin(a);
	float c = cos(a);
	rot = mat2(vec2(c, s), vec2(-s, c));
	vec2 off = vec2(
		hextile_hash(v, seed ^ 0x9E3779B9u),
		hextile_hash(v, seed ^ 0x85EBCA6Bu)
	);
	return rot * uv + off;
}

// `mean` is the texture average (top mip) — the pivot for contrast restore.
// Gradients must come from the continuous base uv (offsets are discontinuous).
vec3 hextile_rgb(
	sampler2D tex, vec2 uv, vec2 ddx, vec2 ddy,
	vec3 mean, uint seed, float rot_jitter
) {
	vec3 w;
	ivec2 v1;
	ivec2 v2;
	ivec2 v3;
	hextile_grid(uv, w, v1, v2, v3);
	mat2 r1;
	mat2 r2;
	mat2 r3;
	vec2 uv1 = hextile_uv(uv, v1, seed, rot_jitter, r1);
	vec2 uv2 = hextile_uv(uv, v2, seed, rot_jitter, r2);
	vec2 uv3 = hextile_uv(uv, v3, seed, rot_jitter, r3);
	vec3 c = textureGrad(tex, uv1, r1 * ddx, r1 * ddy).rgb * w.x
		+ textureGrad(tex, uv2, r2 * ddx, r2 * ddy).rgb * w.y
		+ textureGrad(tex, uv3, r3 * ddx, r3 * ddy).rgb * w.z;
	// Variance-preserving contrast restore (identity when one tile dominates).
	return clamp(mean + (c - mean) * inversesqrt(dot(w, w)), vec3(0.0), vec3(1.0));
}

// Tangent-space normal, decoded, with each tile's xy rotated back into the
// shared uv frame (covector transform = inverse rotation = transpose).
vec3 hextile_normal(
	sampler2D tex, vec2 uv, vec2 ddx, vec2 ddy, uint seed, float rot_jitter
) {
	vec3 w;
	ivec2 v1;
	ivec2 v2;
	ivec2 v3;
	hextile_grid(uv, w, v1, v2, v3);
	mat2 r1;
	mat2 r2;
	mat2 r3;
	vec2 uv1 = hextile_uv(uv, v1, seed, rot_jitter, r1);
	vec2 uv2 = hextile_uv(uv, v2, seed, rot_jitter, r2);
	vec2 uv3 = hextile_uv(uv, v3, seed, rot_jitter, r3);
	vec3 n1 = textureGrad(tex, uv1, r1 * ddx, r1 * ddy).xyz * 2.0 - 1.0;
	vec3 n2 = textureGrad(tex, uv2, r2 * ddx, r2 * ddy).xyz * 2.0 - 1.0;
	vec3 n3 = textureGrad(tex, uv3, r3 * ddx, r3 * ddy).xyz * 2.0 - 1.0;
	n1.xy = transpose(r1) * n1.xy;
	n2.xy = transpose(r2) * n2.xy;
	n3.xy = transpose(r3) * n3.xy;
	vec3 n = n1 * w.x + n2 * w.y + n3 * w.z;
	// Restore slope amplitude lost in blend zones (softened vs albedo restore).
	n.xy *= mix(1.0, inversesqrt(dot(w, w)), 0.5);
	return normalize(n);
}
