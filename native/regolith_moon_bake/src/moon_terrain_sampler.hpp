#pragma once

#include "FastNoiseLite.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <vector>

struct Vector3f {
	float x = 0.f;
	float y = 0.f;
	float z = 0.f;

	Vector3f normalized() const {
		const float len_sq = x * x + y * y + z * z;
		if (len_sq <= 0.000001f) {
			return {0.f, 1.f, 0.f};
		}
		const float inv = 1.f / std::sqrt(len_sq);
		return {x * inv, y * inv, z * inv};
	}

	float dot(const Vector3f &o) const { return x * o.x + y * o.y + z * o.z; }

	Vector3f operator*(float s) const { return {x * s, y * s, z * s}; }
	Vector3f operator/(float s) const { return {x / s, y / s, z / s}; }
	Vector3f operator+(const Vector3f &o) const { return {x + o.x, y + o.y, z + o.z}; }
	Vector3f operator-(const Vector3f &o) const { return {x - o.x, y - o.y, z - o.z}; }

	Vector3f cross(const Vector3f &o) const {
		return {y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x};
	}

	float length() const { return std::sqrt(x * x + y * y + z * z); }
};

struct Crater {
	Vector3f center;
	float rad = 0.f;
	float depth = 0.f;
	float rim_frac = 0.f;
	int cclass = 0;
	int seed = 0;
	/// Precomputed cos(rad*1.35) — the reject test runs ~100x per sample.
	float cos_cutoff = -1.f;
	/// 0 fresh (sharp crest, bright ejecta), 1 mature, 2 degraded (soft
	/// shallow saucer). Age is where most real lunar visual variety lives.
	int age = 1;
};

/// Bright ray system of a fresh crater (albedo only, no relief).
struct RaySource {
	Vector3f center;
	Vector3f e1;
	Vector3f e2;
	float rad = 0.f;
	float cos_far = -1.f;
	float spokes = 9.f;
	float phase = 0.f;
	float phase2 = 0.f;
	float strength = 0.f;
};

/// Sinuous rille (lava channel) segment: a carved valley along a sphere
/// walk. Macro-scale → lives only in the baked layer, runtime-free.
/// Width/depth interpolate along the segment (cone, not cylinder) and are
/// shared at junctions — the channel narrows and shallows continuously.
struct RilleSegment {
	Vector3f a;
	Vector3f b;
	Vector3f mid;
	float cos_reach = -1.f;
	float wa = 0.f;
	float wb = 0.f;
	float da = 0.f;
	float db = 0.f;
};

/// Lava-tube cave: capsule-chain tunnel below the local surface plus a
/// collapsed skylight shaft and entrance bowl. Carved out of the crust by SDF
/// subtraction (SE2-style local 3D features over a heightfield base, but
/// analytic and deterministic — no storage). All coordinates in voxel space.
struct CaveFeature {
	static constexpr int kMaxPoints = 8;
	Vector3f pts[kMaxPoints];
	int point_count = 0;
	float tube_radius = 0.f;
	Vector3f shaft_top;
	Vector3f shaft_bottom;
	float shaft_radius = 0.f;
	Vector3f entrance_center;
	float entrance_radius = 0.f;
	Vector3f aabb_min;
	Vector3f aabb_max;
};

class MoonTerrainSampler;

/// Baked macro relief — the SE2 "macro heightmap" idea applied as a CACHE,
/// not a representation: mare/highland base + huge/large/med craters are
/// sampled once into cube-sphere grids (~7 m/px height, ~29 m/px mare mask)
/// and shared across sampler instances of the same radius. Meter-scale
/// detail (small/tiny craters, surface noise) stays analytic on top, so
/// H(n) = bilerp(macro) + detail(n) is stride-free and identical at every
/// LOD (see the detail_fade seam rule). Each face carries a 1-texel apron:
/// bilinear taps never cross faces, and adjacent faces disagree only by
/// their own interpolation error (sub-centimeter on macro wavelengths).
class MoonMacroRelief {
public:
	static constexpr int kHeightFaceN = 2048;
	static constexpr int kMareFaceN = 512;
	/// Adjacent faces reconstruct from different lattices, so their
	/// interpolation errors disagree at sharp crater rims (~1 m steps along
	/// cube edges, measured). Fix: within |minor|/|major| > kFaceBlendQ of an
	/// edge, blend the 2 (edge) or 3 (corner) face reconstructions with
	/// weights linear in that ratio — C0 by construction; the slope kink at
	/// the blend boundary is far below the surface-noise amplitude. Aprons
	/// are sized so blend-region taps (|uv01| ≤ ~1.0051) stay in-face.
	static constexpr float kFaceBlendQ = 0.99f;
	static constexpr int kHeightApron = 12;
	static constexpr int kMareApron = 4;

	/// Process-wide registry keyed by radius: the play generator, panorama
	/// bake workers and map tools all share one bake (weak refs — memory is
	/// returned once every sampler of that radius is gone). Builds
	/// multithreaded on first acquire (~seconds), then free.
	static std::shared_ptr<const MoonMacroRelief> acquire(
			const MoonTerrainSampler &sampler, float radius_voxels);

	/// One face lookup serves both grids: baked macro height (meters) and
	/// the mare mask the analytic detail layer needs for visibility scaling.
	void sample(const Vector3f &n, float &height_m, float &mare01) const;

private:
	MoonMacroRelief() = default;
	void build(const MoonTerrainSampler &sampler);

	/// face = axis*2 + (negative ? 1 : 0); u,v gnomonic in [-1,1] (apron
	/// texels reach slightly beyond — direction is normalized anyway).
	static Vector3f face_uv_to_dir(int face, float u, float v);

	template <typename T>
	static float sample_face_grid(
			const std::vector<T> &grid,
			int face_n,
			int apron,
			int face,
			float u,
			float v);

	float height_scale_m_ = 0.f;
	std::vector<uint16_t> height_;
	std::vector<uint8_t> mare_;
};

/// Lunar height sampler matching scripts/simulation/runtime/moon_terrain_generator.gd.
/// Noise: local FastNoiseLite configured like ZN_FastNoiseLite (period → freq = 1/period).
class MoonTerrainSampler {
public:
	/// Base counts for the reference Ø1 km moon; rebuild_crater_index scales
	/// them by surface area (pow 0.7, capped) so Ø19 km stays SE-dense.
	static constexpr int kHugeCraterCount = 5;
	static constexpr int kLargeCraterCount = 95;
	static constexpr int kMedCraterCount = 280;
	static constexpr int kSmallCraterCount = 520;
	static constexpr int kTinyCraterCount = 700;
	static constexpr int kCraterGrid = 64;
	static constexpr int kMareCount = 5;
	/// Med craters split across layers: bowl (smooth, survives ~7 m/px
	/// bilerp) bakes into macro; rim+ejecta (sharp) stays analytic detail.
	enum CraterParts {
		kPartsFull = 0,
		kPartsMacroLayer = 1,
		kPartsDetailLayer = 2,
	};

	static constexpr int kClassHuge = 0;
	static constexpr int kClassLarge = 1;
	static constexpr int kClassMed = 2;
	static constexpr int kClassSmall = 3;
	static constexpr int kClassTiny = 4;

	/// Cave counts scale with area like craters (see build_caves).
	static constexpr int kCaveBaseCount = 4;
	/// Smooth-subtraction blend width (voxels) where tube meets crust.
	static constexpr float kCaveSmoothK = 3.f;

	static constexpr int kSeed = 0x4D004E;
	static constexpr float kVoxelScale = 1.0f;
	static constexpr float kMariaDepthM = 18.f;
	static constexpr float kHighlandLiftM = 6.5f;
	static constexpr float kHighlandRoughAmpM = 1.15f;
	static constexpr float kCraterLargeAmpM = 18.f;
	static constexpr float kCraterMedAmpM = 9.f;
	static constexpr float kCraterSmallAmpM = 3.5f;
	static constexpr float kCraterTinyAmpM = 1.3f;
	static constexpr float kCraterHugeAmpM = 30.f;
	static constexpr float kSurfaceTextureM = 0.9f;
	static constexpr float kPlainsTextureM = 0.3f;
	static constexpr float kMicroAmpM = 0.3f;
	static constexpr float kMaxCraterDepthM = 200.f;
	static constexpr float kHeightClampM = 240.f;

	/// bake_macro=false keeps the pure-analytic path (parity tests, tools
	/// that sample a handful of directions and don't want a cube bake).
	explicit MoonTerrainSampler(float radius_voxels, bool bake_macro = true);

	/// Macro layer only (mare/highland base, meso roughness, huge/large/med
	/// craters) — what MoonMacroRelief bakes. No stride: macro wavelengths
	/// are ≥ ~140 m, far above any voxel stride we mesh.
	void analytic_macro(const Vector3f &n, float &height_m, float &mare01) const;

	/// stride_m > 0 fades out features smaller than the sampling step
	/// (LOD-aware: cheaper far blocks, no sub-voxel aliasing). 0 = full detail.
	float height_voxels(const Vector3f &n, float stride_m = 0.f) const;

	/// Cave query API (positions/AABBs in voxel space, moon-centered).
	/// Subtraction-only: caves never ADD matter, so an AIR block stays AIR —
	/// only SOLID classification must consult caves_touch_aabb.
	bool caves_touch_aabb(const Vector3f &aabb_min, const Vector3f &aabb_max) const;
	void gather_caves(
			const Vector3f &aabb_min,
			const Vector3f &aabb_max,
			std::vector<int> &out) const;
	/// SDF of the union of the listed cave volumes (negative inside).
	float cave_carve_sdf_voxels(
			const Vector3f &p, const std::vector<int> &cave_indices) const;
	const std::vector<CaveFeature> &caves() const { return caves_; }

	/// Surface albedo brightness (0..1, neutral 1/1.5): dark maria + bright
	/// ejecta blankets and ray spokes of fresh large craters. Display-only.
	float brightness01(const Vector3f &n) const;
	/// Orbital map globe: mare/highland + huge/large/med craters only — no
	/// meter-scale pepper or surface grain (reads as bubble-wrap at map scale).
	float height_meters_map(const Vector3f &n) const;
	static Vector3f direction_from_node_uv(float u, float v);

	/// Same config as MoonHeightmapUtil._make_zn_noise / MoonTerrainGenerator._setup_noise.
	static void configure_fnl(
			FastNoiseLite &fnl,
			int seed_value,
			float period_voxels,
			int octaves,
			float gain,
			float lacunarity = 2.f);

	static float sample_fnl(const FastNoiseLite &fnl, const Vector3f &p) {
		return fnl.GetNoise(p.x, p.y, p.z);
	}

	/// White-box hook for native tests (tests/macro_parity_test.cpp).
	friend struct MoonSamplerDebug;

private:
	float radius_voxels_ = 0.f;
	FastNoiseLite mare_field_;
	FastNoiseLite highland_rough_;
	FastNoiseLite surface_;
	FastNoiseLite regolith_;
	/// Km-scale crater-density patches: saturated fields vs calm plains
	/// (uniform-random placement reads as texture, not landscape).
	FastNoiseLite crater_density_;
	FastNoiseLite mare_ridge_;
	std::array<Vector3f, kMareCount> mare_centers_{};
	std::array<float, kMareCount> mare_radii_{};
	std::vector<Crater> craters_;
	/// Split by scale so the hot detail path never touches (or branches on)
	/// macro craters: macro = huge/large/med (baked or map), detail =
	/// small/tiny (always analytic — meter-scale rims don't survive ~7 m/px).
	std::vector<std::vector<int>> macro_cells_;
	std::vector<std::vector<int>> detail_cells_;
	std::vector<CaveFeature> caves_;
	std::vector<RilleSegment> rilles_;
	std::vector<std::vector<int>> rille_cells_;
	std::vector<RaySource> ray_sources_;
	void build_ray_sources();
	std::shared_ptr<const MoonMacroRelief> macro_;

	void build_mare_regions();
	void rebuild_crater_index();
	void build_rilles();
	/// Shared by register_class and secondary chains; routes the crater into
	/// the right cell grid(s), rolls/applies age. forced_age -1 = roll here.
	void register_crater(
			const Vector3f &center,
			float rad,
			float depth_factor,
			float rim_frac,
			int class_id,
			int seed,
			int forced_age);
	void build_secondary_chains(int parent_end);
	float rille_carve_m(const Vector3f &n) const;
	/// Needs mare + crater fields (anchors read final surface height).
	void build_caves();
	static float sd_capsule(
			const Vector3f &p, const Vector3f &a, const Vector3f &b, float r);
	void register_class(
			int count,
			int seed_base,
			int class_id,
			float rad_min,
			float rad_max,
			float depth_m,
			float rim_frac);

	float height_meters(const Vector3f &n, float stride_m) const;
	float detail_meters(
			const Vector3f &n, float mare, float stride_m, float macro_h_m) const;
	float mare_factor(const Vector3f &domain) const;
	float highland_meso_roughness(const Vector3f &domain, float highland) const;
	float surface_texture(
			const Vector3f &domain, float mare, float highland, float stride_m) const;
	float crater_field_cells(
			const std::vector<std::vector<int>> &cells,
			const Vector3f &n,
			float mare,
			float highland,
			float stride_m,
			int parts,
			float carve_init) const;
	float crater_field_map(const Vector3f &n, float mare, float highland) const;

	/// LOD detail fade is DISABLED (returns 1): Transvoxel transition meshes
	/// assume every LOD meshes the SAME field. Any per-LOD amplitude culling
	/// (tried at 12% and 3% of a coarse cell) opens grazing-angle gap lines
	/// at ring boundaries — empirically confirmed in-game 2026-07-19. Far
	/// LODs pay full H(n); the exact far-field/uniform fast paths (which
	/// never disagree between LODs) carry the perf budget instead. The
	/// stride plumbing is kept for a future viewer-continuous approach.
	static float detail_fade(float /*amp_m*/, float /*stride_m*/) {
		return 1.f;
	}
	float crater_visibility(int cclass, float highland) const;
	void crater_contribution(
			float t,
			float d,
			float rim_frac,
			int cclass,
			int crater_seed,
			int age,
			bool bowl_en,
			bool rim_en,
			float &carve,
			float &rim) const;

	static int dir_to_cell_index(const Vector3f &n);
	static float meters_to_voxels(float meters) { return meters / kVoxelScale; }
	static float hash01(int x);
	static Vector3f seed_dir(int seed_value);
	static float inv_skew3(float s);
	static float cbrt_signed(float a);
	static float clampf(float v, float lo, float hi) {
		return v < lo ? lo : (v > hi ? hi : v);
	}
	static float lerpf(float a, float b, float t) { return a + (b - a) * t; }
};
