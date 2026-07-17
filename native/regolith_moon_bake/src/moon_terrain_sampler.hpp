#pragma once

#include "../thirdparty/FastNoiseLite.h"

#include <array>
#include <cmath>
#include <cstdint>
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
};

struct Crater {
	Vector3f center;
	float rad = 0.f;
	float depth = 0.f;
	float rim_frac = 0.f;
	int cclass = 0;
	int seed = 0;
};

class MoonTerrainSampler {
public:
	static constexpr int kHugeCraterCount = 5;
	static constexpr int kLargeCraterCount = 95;
	static constexpr int kMedCraterCount = 280;
	static constexpr int kSmallCraterCount = 520;
	static constexpr int kCraterGrid = 24;
	static constexpr int kMareCount = 5;
	static constexpr int kClassHuge = 0;
	static constexpr int kClassLarge = 1;
	static constexpr int kClassMed = 2;
	static constexpr int kClassSmall = 3;

	static constexpr int kSeed = 0x4D004E;
	static constexpr float kVoxelScale = 0.65f;
	static constexpr float kMariaDepthM = 18.f;
	static constexpr float kHighlandLiftM = 6.5f;
	static constexpr float kHighlandRoughAmpM = 1.15f;
	static constexpr float kCraterLargeAmpM = 18.f;
	static constexpr float kCraterMedAmpM = 9.f;
	static constexpr float kCraterSmallAmpM = 3.5f;
	static constexpr float kCraterHugeAmpM = 30.f;
	static constexpr float kSurfaceTextureM = 0.9f;
	static constexpr float kPlainsTextureM = 0.3f;
	static constexpr float kMicroAmpM = 0.3f;
	static constexpr float kHeightClampM = 45.f;

	explicit MoonTerrainSampler(float radius_voxels);

	float height_voxels(const Vector3f &n) const;
	static Vector3f direction_from_node_uv(float u, float v);

private:
	float radius_voxels_ = 0.f;
	FastNoiseLite mare_field_;
	FastNoiseLite highland_rough_;
	FastNoiseLite surface_;
	FastNoiseLite regolith_;
	std::array<Vector3f, kMareCount> mare_centers_{};
	std::array<float, kMareCount> mare_radii_{};
	std::vector<Crater> craters_;
	std::vector<std::vector<int>> crater_cells_;

	void setup_noise();
	void build_mare_regions();
	void rebuild_crater_index();
	void register_class(
			int count,
			int seed_base,
			int class_id,
			float rad_min,
			float rad_max,
			float depth_m,
			float rim_frac);

	float height_meters(const Vector3f &n) const;
	float mare_factor(const Vector3f &domain) const;
	float highland_meso_roughness(const Vector3f &domain, float highland) const;
	float surface_texture(const Vector3f &domain, float mare, float highland) const;
	float crater_field(const Vector3f &n, float mare, float highland) const;
	float crater_visibility(int cclass, float highland) const;
	void crater_contribution(
			float t,
			float d,
			float rim_frac,
			int cclass,
			int crater_seed,
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
	static void configure_noise(FastNoiseLite &noise, int seed, float period_m, int octaves, float gain, float lacunarity = 2.f);
};
