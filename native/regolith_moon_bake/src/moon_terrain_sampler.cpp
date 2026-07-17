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
		const float depth = depth_m * lerpf(0.82f, 1.0f, hash01(seed_base + i * 47));
		const int idx = static_cast<int>(craters_.size());
		craters_.push_back(Crater{center, rad, depth, rim_frac, class_id, seed_base + i * 17});

		const int half = static_cast<int>(std::ceil(float(kCraterGrid) * rad * 1.35f)) + 1;
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
	register_class(kHugeCraterCount, kSeed + 50, kClassHuge, 0.11f, 0.20f, kCraterHugeAmpM, 0.18f);
	register_class(kLargeCraterCount, kSeed + 100, kClassLarge, 0.040f, 0.095f, kCraterLargeAmpM, 0.16f);
	register_class(kMedCraterCount, kSeed + 200, kClassMed, 0.015f, 0.044f, kCraterMedAmpM, 0.14f);
	register_class(kSmallCraterCount, kSeed + 300, kClassSmall, 0.005f, 0.015f, kCraterSmallAmpM, 0.12f);
}

float MoonTerrainSampler::height_voxels(const Vector3f &n) const {
	const float h_m = height_meters(n);
	return meters_to_voxels(clampf(h_m, -kHeightClampM, kHeightClampM));
}

float MoonTerrainSampler::height_meters(const Vector3f &n) const {
	const Vector3f domain = n * radius_voxels_;
	const float mare = mare_factor(domain);
	const float highland = 1.f - mare;
	float h = lerpf(-kMariaDepthM, kHighlandLiftM, highland);
	h += highland_meso_roughness(domain, highland);
	h += crater_field(n, mare, highland);
	h += surface_texture(domain, mare, highland);
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

float MoonTerrainSampler::surface_texture(const Vector3f &domain, float /*mare*/, float highland) const {
	const float mid = sample_fnl(surface_, domain);
	const float fine = sample_fnl(regolith_, domain);
	const float mid_amp = lerpf(kPlainsTextureM, kSurfaceTextureM, highland);
	const float fine_amp = lerpf(kMicroAmpM * 0.45f, kMicroAmpM, highland);
	return mid * mid_amp + fine * fine_amp;
}

float MoonTerrainSampler::crater_field(const Vector3f &n, float mare, float highland) const {
	float carve = 0.f;
	float rim = 0.f;
	const int cell = dir_to_cell_index(n);
	const int cx = cell % kCraterGrid;
	const int cy = (cell / kCraterGrid) % kCraterGrid;
	const int cz = cell / (kCraterGrid * kCraterGrid);

	std::array<bool, 900> seen{}; // max craters ~900
	int seen_count = 0;

	for (int dz = -1; dz <= 1; ++dz) {
		for (int dy = -1; dy <= 1; ++dy) {
			for (int dx = -1; dx <= 1; ++dx) {
				const int ix = std::clamp(cx + dx, 0, kCraterGrid - 1);
				const int iy = std::clamp(cy + dy, 0, kCraterGrid - 1);
				const int iz = std::clamp(cz + dz, 0, kCraterGrid - 1);
				const int key = ix + iy * kCraterGrid + iz * kCraterGrid * kCraterGrid;
				for (int idx : crater_cells_[key]) {
					if (idx < 0 || idx >= static_cast<int>(seen.size()) || seen[idx]) {
						continue;
					}
					seen[idx] = true;
					++seen_count;
					const Crater &crater = craters_[idx];
					const float cos_a = clampf(n.dot(crater.center), -1.f, 1.f);
					if (cos_a < std::cos(crater.rad * 1.35f)) {
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
			}
		}
	}
	return carve + rim;
}

float MoonTerrainSampler::crater_visibility(int cclass, float highland) const {
	float base = lerpf(0.05f, 1.f, highland);
	if (cclass >= kClassMed) {
		base *= lerpf(0.03f, 1.f, highland);
	}
	if (cclass == kClassSmall) {
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
		const float rim_w = lerpf(0.20f, 0.15f, float(cclass) / 3.f);
		const float rim_bump = std::exp(-std::pow((t - 1.f) / rim_w, 2.f));
		rim = std::max(rim, d * rim_frac * rim_bump);
	}

	if (t > 0.88f) {
		const float edge0 = 0.92f;
		const float edge1 = 1.85f;
		const float t_smooth = clampf((edge1 - t) / (edge1 - edge0), 0.f, 1.f);
		float falloff = t_smooth * t_smooth * (3.f - 2.f * t_smooth);
		falloff *= std::exp(-std::max(0.f, t - 1.f) * 1.6f);
		const float ej_amp = d * rim_frac * lerpf(0.42f, 0.26f, float(cclass) / 3.f);
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
