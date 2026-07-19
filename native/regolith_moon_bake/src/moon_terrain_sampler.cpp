#include "moon_terrain_sampler.hpp"

#include <algorithm>
#include <cmath>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace {
constexpr float kTau = static_cast<float>(M_PI * 2.0);
}

void MoonTerrainSampler::configure_fnl(
		FastNoiseLite &fnl,
		int seed_value,
		float period_voxels,
		int octaves,
		float gain,
		float lacunarity) {
	/// Match ZN_FastNoiseLite: set_period(p) → SetFrequency(1/p).
	const float period = period_voxels < 0.0001f ? 0.0001f : period_voxels;
	fnl.SetSeed(seed_value);
	fnl.SetFrequency(1.f / period);
	fnl.SetNoiseType(FastNoiseLite::NoiseType_OpenSimplex2);
	fnl.SetFractalType(FastNoiseLite::FractalType_FBm);
	fnl.SetFractalOctaves(octaves);
	fnl.SetFractalGain(gain);
	fnl.SetFractalLacunarity(lacunarity);
}

MoonTerrainSampler::MoonTerrainSampler(float radius_voxels) : radius_voxels_(radius_voxels) {
	const float scale = kVoxelScale;
	configure_fnl(mare_field_, kSeed + 11, 480.f / scale, 2, 0.32f, 2.f);
	configure_fnl(highland_rough_, kSeed + 41, 55.f / scale, 3, 0.42f, 2.f);
	configure_fnl(surface_, kSeed + 73, 20.f / scale, 2, 0.45f, 2.f);
	configure_fnl(regolith_, kSeed + 67, 4.5f / scale, 2, 0.5f, 2.f);
	build_mare_regions();
	rebuild_crater_index();
}

void MoonTerrainSampler::build_mare_regions() {
	for (int i = 0; i < kMareCount; ++i) {
		mare_centers_[i] = seed_dir(kSeed + 801 + i * 53);
		mare_radii_[i] = lerpf(0.30f, 0.44f, hash01(kSeed + 802 + i * 71));
	}
}

void MoonTerrainSampler::register_class(
		int count,
		int seed_base,
		int class_id,
		float rad_min,
		float rad_max,
		float depth_m,
		float rim_frac) {
	for (int i = 0; i < count; ++i) {
		const Vector3f center = seed_dir(seed_base + i * 17);
		const float u = hash01(seed_base + i * 31);
		const float rad = lerpf(rad_min, rad_max, u);
		/// depth_m is a depth/diameter FACTOR (lunar simple craters ~0.1-0.2):
		/// meter depths on km-wide bowls read as flat noise on big moons.
		const float diameter_m = 2.f * rad * radius_voxels_ * kVoxelScale;
		const float depth = std::min(depth_m * diameter_m, kMaxCraterDepthM) *
				lerpf(0.82f, 1.0f, hash01(seed_base + i * 47));
		const int idx = static_cast<int>(craters_.size());
		craters_.push_back(Crater{
				center, rad, depth, rim_frac, class_id, seed_base + i * 17,
				std::cos(rad * 1.35f) });

		/// Exact influence box (query reads a SINGLE cell, so every cell the
		/// crater touches must be registered): angular reach 1.35*rad over a
		/// [-1,1] cube → rad*1.35*grid/2 cells, +1 for center quantization.
		const int half =
				static_cast<int>(std::ceil(float(kCraterGrid) * rad * 1.35f * 0.5f)) + 1;
		const int c0 = dir_to_cell_index(center);
		const int cx = c0 % kCraterGrid;
		const int cy = (c0 / kCraterGrid) % kCraterGrid;
		const int cz = c0 / (kCraterGrid * kCraterGrid);

		for (int dz = -half; dz <= half; ++dz) {
			for (int dy = -half; dy <= half; ++dy) {
				for (int dx = -half; dx <= half; ++dx) {
					const int ix = std::clamp(cx + dx, 0, kCraterGrid - 1);
					const int iy = std::clamp(cy + dy, 0, kCraterGrid - 1);
					const int iz = std::clamp(cz + dz, 0, kCraterGrid - 1);
					const int cell = ix + iy * kCraterGrid + iz * kCraterGrid * kCraterGrid;
					crater_cells_[cell].push_back(idx);
				}
			}
		}
	}
}

void MoonTerrainSampler::rebuild_crater_index() {
	craters_.clear();
	crater_cells_.assign(kCraterGrid * kCraterGrid * kCraterGrid, {});
	/// Area-based density scale vs the reference Ø1 km moon. pow 0.7 (not 1.0)
	/// keeps counts sane on big worlds; cap bounds memory. Ø19 km → ~62x.
	const float radius_m = radius_voxels_ * kVoxelScale;
	const float area = (radius_m / 500.f) * (radius_m / 500.f);
	const float s = std::min(std::pow(area, 0.7f), 100.f);
	const int huge_n = std::min(12, std::max(kHugeCraterCount, int(5.f * std::pow(s, 0.35f))));
	/// 6th arg = depth/diameter factor (basins shallower, small craters
	/// relatively deeper — real lunar morphology).
	register_class(huge_n, kSeed + 50, kClassHuge, 0.11f, 0.20f, 0.05f, 0.18f);
	register_class(int(kLargeCraterCount * s), kSeed + 100, kClassLarge, 0.040f, 0.095f, 0.12f, 0.16f);
	register_class(int(kMedCraterCount * s), kSeed + 200, kClassMed, 0.015f, 0.044f, 0.14f, 0.14f);
	register_class(int(kSmallCraterCount * s), kSeed + 300, kClassSmall, 0.005f, 0.015f, 0.15f, 0.12f);
	/// Meter-scale peppering near the player; amp-faded away by LOD 2-3.
	register_class(int(kTinyCraterCount * s), kSeed + 400, kClassTiny, 0.0008f, 0.0025f, 0.16f, 0.10f);
}

float MoonTerrainSampler::height_voxels(const Vector3f &n, float stride_m) const {
	const float h_m = height_meters(n, stride_m);
	return meters_to_voxels(clampf(h_m, -kHeightClampM, kHeightClampM));
}

float MoonTerrainSampler::height_meters(const Vector3f &n, float stride_m) const {
	const Vector3f domain = n * radius_voxels_;
	const float mare = mare_factor(domain);
	const float highland = 1.f - mare;
	float h = lerpf(-kMariaDepthM, kHighlandLiftM, highland);
	const float rough_fade = detail_fade(kHighlandRoughAmpM, stride_m);
	if (rough_fade > 0.f) {
		h += highland_meso_roughness(domain, highland) * rough_fade;
	}
	h += crater_field(n, mare, highland, stride_m);
	h += surface_texture(domain, mare, highland, stride_m);
	return h;
}

float MoonTerrainSampler::height_meters_map(const Vector3f &n) const {
	const Vector3f domain = n * radius_voxels_;
	const float mare = mare_factor(domain);
	const float highland = 1.f - mare;
	float h = lerpf(-kMariaDepthM, kHighlandLiftM, highland);
	h += highland_meso_roughness(domain, highland) * 0.35f;
	h += crater_field_map(n, mare, highland);
	return h;
}

float MoonTerrainSampler::mare_factor(const Vector3f &domain) const {
	const Vector3f n = domain / radius_voxels_;
	float mare = 0.f;
	for (int i = 0; i < kMareCount; ++i) {
		const float ang = std::acos(clampf(n.dot(mare_centers_[i]), -1.f, 1.f));
		const float rad = mare_radii_[i];
		const float edge0 = rad * 0.62f;
		const float edge1 = rad * 0.94f;
		const float t = clampf((ang - edge0) / (edge1 - edge0), 0.f, 1.f);
		const float blob = 1.f - t * t * (3.f - 2.f * t);
		mare = std::max(mare, blob);
	}
	if (mare > 0.04f) {
		const Vector3f scaled = domain * 0.85f;
		const float warp = sample_fnl(mare_field_, scaled);
		mare = clampf(mare + warp * 0.12f * mare * (1.f - mare), 0.f, 1.f);
	}
	return std::pow(clampf(mare, 0.f, 1.f), 1.28f);
}

float MoonTerrainSampler::highland_meso_roughness(const Vector3f &domain, float highland) const {
	if (highland < 0.08f || kHighlandRoughAmpM <= 0.001f) {
		return 0.f;
	}
	const float r = sample_fnl(highland_rough_, domain);
	return highland * r * kHighlandRoughAmpM;
}

float MoonTerrainSampler::surface_texture(
		const Vector3f &domain, float /*mare*/, float highland, float stride_m) const {
	/// Fade each band by its max amplitude; skip the sample entirely at zero.
	const float mid_fade = detail_fade(kSurfaceTextureM, stride_m);
	const float fine_fade = detail_fade(kMicroAmpM, stride_m);
	float h = 0.f;
	if (mid_fade > 0.f) {
		h += sample_fnl(surface_, domain) *
				lerpf(kPlainsTextureM, kSurfaceTextureM, highland) * mid_fade;
	}
	if (fine_fade > 0.f) {
		h += sample_fnl(regolith_, domain) *
				lerpf(kMicroAmpM * 0.45f, kMicroAmpM, highland) * fine_fade;
	}
	return h;
}

float MoonTerrainSampler::crater_field(
		const Vector3f &n, float mare, float highland, float stride_m) const {
	float carve = 0.f;
	float rim = 0.f;
	/// Craters are registered into EVERY cell they influence (see
	/// register_class) → one cell lookup, no dedup needed (min/max are
	/// idempotent anyway), no crater-count ceiling.
	const int cell = dir_to_cell_index(n);
	for (int idx : crater_cells_[cell]) {
		const Crater &crater = craters_[idx];
		/// LOD fade by crater DEPTH (see detail_fade: height-based culling
		/// keeps LOD seams tight; diameter-based tears them).
		const float lod_fade = detail_fade(crater.depth, stride_m);
		if (lod_fade <= 0.f) {
			continue;
		}
		const float cos_a = clampf(n.dot(crater.center), -1.f, 1.f);
		if (cos_a < crater.cos_cutoff) {
			continue;
		}
		const float t = std::acos(cos_a) / crater.rad;
		float visibility = lod_fade * crater_visibility(crater.cclass, highland);
		visibility *= lerpf(1.f, 0.03f, mare);
		if (visibility <= 0.001f) {
			continue;
		}
		const float d = crater.depth * visibility;
		float c = 0.f;
		float r = 0.f;
		crater_contribution(t, d, crater.rim_frac, crater.cclass, crater.seed, c, r);
		carve = std::min(carve, c);
		rim = std::max(rim, r);
	}
	return carve + rim;
}

float MoonTerrainSampler::crater_field_map(
		const Vector3f &n, float mare, float highland) const {
	float carve = 0.f;
	float rim = 0.f;
	const int cell = dir_to_cell_index(n);
	for (int idx : crater_cells_[cell]) {
		const Crater &crater = craters_[idx];
		if (crater.cclass >= kClassSmall) {
			continue;
		}
		const float cos_a = clampf(n.dot(crater.center), -1.f, 1.f);
		if (cos_a < crater.cos_cutoff) {
			continue;
		}
		const float t = std::acos(cos_a) / crater.rad;
		float visibility = crater_visibility(crater.cclass, highland);
		visibility *= lerpf(1.f, 0.03f, mare);
		if (visibility <= 0.001f) {
			continue;
		}
		const float d = crater.depth * visibility;
		float c = 0.f;
		float r = 0.f;
		crater_contribution(t, d, crater.rim_frac, crater.cclass, crater.seed, c, r);
		carve = std::min(carve, c);
		rim = std::max(rim, r);
	}
	return carve + rim;
}

float MoonTerrainSampler::crater_visibility(int cclass, float highland) const {
	float base = lerpf(0.05f, 1.f, highland);
	if (cclass >= kClassMed) {
		base *= lerpf(0.03f, 1.f, highland);
	}
	if (cclass >= kClassSmall) {
		base *= lerpf(0.08f, 1.f, highland);
	}
	return base;
}

void MoonTerrainSampler::crater_contribution(
		float t,
		float d,
		float rim_frac,
		int cclass,
		int crater_seed,
		float &carve,
		float &rim) const {
	carve = 0.f;
	rim = 0.f;

	if (t < 1.f) {
		if (cclass <= kClassLarge) {
			const float floor_depth = -d * 0.86f;
			if (t < 0.38f) {
				if (cclass == kClassHuge && t < 0.26f) {
					const float peak = std::exp(-std::pow(t / 0.19f, 2.f));
					carve = floor_depth + d * 0.14f * peak;
				} else {
					carve = floor_depth;
				}
			} else {
				const float wall_t = (t - 0.38f) / 0.62f;
				float bowl = 0.5f + 0.5f * std::cos(static_cast<float>(M_PI) * wall_t);
				bowl = bowl * bowl;
				carve = lerpf(floor_depth, 0.f, 1.f - bowl);
			}
		} else {
			float bowl = 0.5f + 0.5f * std::cos(static_cast<float>(M_PI) * t);
			bowl = bowl * bowl;
			carve = -d * bowl;
		}
	}

	if (cclass == kClassHuge) {
		const float edge0 = 0.42f;
		const float edge1 = 0.68f;
		const float t0 = clampf((t - edge0) / (edge1 - edge0), 0.f, 1.f);
		const float terrace_env = t0 * t0 * (3.f - 2.f * t0);
		const float edge2 = 1.06f;
		const float edge3 = 0.94f;
		const float t1 = clampf((edge2 - t) / (edge2 - edge3), 0.f, 1.f);
		const float env = terrace_env * (t1 * t1 * (3.f - 2.f * t1));
		if (env > 0.001f) {
			constexpr int step_count = 2;
			for (int tier = 0; tier < step_count; ++tier) {
				const float u0 = hash01(crater_seed + tier * 113);
				const float u1 = hash01(crater_seed + tier * 197 + 3);
				const float tc = lerpf(0.78f, 0.98f, u0) + (u1 - 0.5f) * 0.04f;
				const float tw = lerpf(0.028f, 0.048f, hash01(crater_seed + tier * 311));
				const float terr = std::exp(-std::pow((t - tc) / tw, 2.f));
				const float amp = d * rim_frac * lerpf(0.06f, 0.11f, u1) * env;
				rim = std::max(rim, amp * terr);
			}
		}
	} else {
		const float rim_w = lerpf(0.20f, 0.15f, std::min(float(cclass), 3.f) / 3.f);
		const float rim_bump = std::exp(-std::pow((t - 1.f) / rim_w, 2.f));
		rim = std::max(rim, d * rim_frac * rim_bump);
	}

	if (t > 0.88f) {
		const float edge0 = 0.92f;
		const float edge1 = 1.85f;
		const float t_smooth = clampf((edge1 - t) / (edge1 - edge0), 0.f, 1.f);
		float falloff = t_smooth * t_smooth * (3.f - 2.f * t_smooth);
		falloff *= std::exp(-std::max(0.f, t - 1.f) * 1.6f);
		const float ej_amp = d * rim_frac * lerpf(0.42f, 0.26f, std::min(float(cclass), 3.f) / 3.f);
		rim = std::max(rim, ej_amp * falloff);
	}
}

Vector3f MoonTerrainSampler::direction_from_node_uv(float u, float v) {
	const float lon = (0.5f - u) * kTau;
	const float ny = inv_skew3(clampf(1.f - 2.f * v, -1.f, 1.f));
	const float r = std::sqrt(std::max(0.f, 1.f - ny * ny));
	return Vector3f{r * std::cos(lon), ny, r * std::sin(lon)}.normalized();
}

int MoonTerrainSampler::dir_to_cell_index(const Vector3f &n) {
	const int x = std::clamp(
			static_cast<int>(std::floor((n.x * 0.5f + 0.5f) * float(kCraterGrid))),
			0,
			kCraterGrid - 1);
	const int y = std::clamp(
			static_cast<int>(std::floor((n.y * 0.5f + 0.5f) * float(kCraterGrid))),
			0,
			kCraterGrid - 1);
	const int z = std::clamp(
			static_cast<int>(std::floor((n.z * 0.5f + 0.5f) * float(kCraterGrid))),
			0,
			kCraterGrid - 1);
	return x + y * kCraterGrid + z * kCraterGrid * kCraterGrid;
}

float MoonTerrainSampler::hash01(int x) {
	/// Match GDScript int (64-bit) wrapping in moon_terrain_generator.gd.
	/// Shift count must be masked — bare `(v>>28)+4` can be ≥64 (UB/crash).
	uint64_t v = uint64_t(int64_t(x)) * 747796405ull + 2891336453ull;
	const uint64_t shift = ((v >> 28) + 4ull) & 63ull;
	v = ((v >> shift) ^ v) * 277803737ull;
	v = (v >> 22) ^ v;
	return float(v & 0xFFFFFFull) / float(0x1000000ull);
}

Vector3f MoonTerrainSampler::seed_dir(int seed_value) {
	const float z = hash01(seed_value) * 2.f - 1.f;
	const float a = hash01(seed_value + 913) * kTau;
	const float r = std::sqrt(std::max(0.f, 1.f - z * z));
	return Vector3f{std::cos(a) * r, z, std::sin(a) * r}.normalized();
}

float MoonTerrainSampler::inv_skew3(float s) {
	const float d = std::sqrt(s * s + 1.f / 27.f);
	const float x = cbrt_signed(s + d) + cbrt_signed(s - d);
	return clampf(x, -1.f, 1.f);
}

float MoonTerrainSampler::cbrt_signed(float a) {
	return (a >= 0.f ? 1.f : -1.f) * std::pow(std::fabs(a), 1.f / 3.f);
}
