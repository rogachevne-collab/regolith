#include "moon_heightmap_bake.hpp"

#include "moon_terrain_sampler.hpp"

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

using namespace godot;

namespace {

/// Extra shell padding (voxels) beyond the relief clamp when deciding
/// whether a sample/block can skip the analytic height evaluation.
constexpr float kShellMarginVoxels = 4.f;

inline uint16_t encode_sdf_s16(float sdf, float encode_scale) {
	/// Mirror voxel tools: snorm_to_s16(sdf * QUANTIZED_SDF_16_BITS_SCALE),
	/// snorm_to_s16(v) = clamp(int(32767 * clamp(v, -1, 1)), -32767, 32767).
	float s = sdf * encode_scale;
	s = s < -1.f ? -1.f : (s > 1.f ? 1.f : s);
	int v = static_cast<int>(32767.f * s);
	v = std::clamp(v, -32767, 32767);
	return static_cast<uint16_t>(static_cast<int16_t>(v));
}

} // namespace

struct MoonBakeBandResult {
	int y0 = 0;
	std::vector<float> buffer;
};

void MoonHeightmapBake::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("bake_panorama", "width", "height", "radius_voxels"),
			&MoonHeightmapBake::bake_panorama);
	ClassDB::bind_method(
			D_METHOD(
					"sample_fnl",
					"seed_value",
					"period_voxels",
					"octaves",
					"gain",
					"lacunarity",
					"position"),
			&MoonHeightmapBake::sample_fnl);
	ClassDB::bind_method(D_METHOD("setup", "radius_voxels"), &MoonHeightmapBake::setup);
	ClassDB::bind_method(
			D_METHOD("classify_block", "origin", "size", "stride"),
			&MoonHeightmapBake::classify_block);
	ClassDB::bind_method(
			D_METHOD("sample_block_sdf_f", "origin", "size", "stride"),
			&MoonHeightmapBake::sample_block_sdf_f);
	ClassDB::bind_method(
			D_METHOD("sample_block_sdf16", "origin", "size", "stride", "encode_scale"),
			&MoonHeightmapBake::sample_block_sdf16);
	ClassDB::bind_method(
			D_METHOD("encode_values_s16", "values", "encode_scale"),
			&MoonHeightmapBake::encode_values_s16);
	ClassDB::bind_method(
			D_METHOD("height_clamp_voxels"), &MoonHeightmapBake::height_clamp_voxels);

	BIND_ENUM_CONSTANT(BLOCK_MIXED);
	BIND_ENUM_CONSTANT(BLOCK_AIR);
	BIND_ENUM_CONSTANT(BLOCK_SOLID);
}

void MoonHeightmapBake::setup(float radius_voxels) {
	std::lock_guard<std::mutex> guard(setup_mutex_);
	if (sampler_ != nullptr && std::fabs(sampler_radius_voxels_ - radius_voxels) < 0.001f) {
		return;
	}
	/// Sampler is immutable after construction; generation threads only read it.
	sampler_ = std::make_shared<const MoonTerrainSampler>(radius_voxels);
	sampler_radius_voxels_ = radius_voxels;
}

float MoonHeightmapBake::height_clamp_voxels() const {
	return MoonTerrainSampler::kHeightClampM / MoonTerrainSampler::kVoxelScale;
}

int MoonHeightmapBake::classify_block(
		const Vector3i &origin,
		const Vector3i &size,
		int stride) const {
	if (sampler_ == nullptr || size.x <= 0 || size.y <= 0 || size.z <= 0 || stride <= 0) {
		return BLOCK_MIXED;
	}
	const float radius = sampler_radius_voxels_;
	const float shell = height_clamp_voxels() + kShellMarginVoxels;

	/// AABB of sampled voxel centers: [origin, origin + (size-1)*stride].
	const float min_c[3] = { float(origin.x), float(origin.y), float(origin.z) };
	const float max_c[3] = {
		float(origin.x + (size.x - 1) * stride),
		float(origin.y + (size.y - 1) * stride),
		float(origin.z + (size.z - 1) * stride),
	};

	float near_sq = 0.f;
	float far_sq = 0.f;
	for (int axis = 0; axis < 3; ++axis) {
		const float nearest = std::clamp(0.f, min_c[axis], max_c[axis]);
		near_sq += nearest * nearest;
		const float farthest = std::max(std::fabs(min_c[axis]), std::fabs(max_c[axis]));
		far_sq += farthest * farthest;
	}
	const float near_r = std::sqrt(near_sq);
	const float far_r = std::sqrt(far_sq);

	if (near_r > radius + shell) {
		return BLOCK_AIR;
	}
	if (far_r < radius - shell) {
		return BLOCK_SOLID;
	}
	return BLOCK_MIXED;
}

float MoonHeightmapBake::sample_sdf(float px, float py, float pz, float shell_margin) const {
	const float r = std::sqrt(px * px + py * py + pz * pz);
	const float radius = sampler_radius_voxels_;
	if (r <= 0.000001f) {
		return -radius;
	}
	const float sphere_sd = r - radius;
	/// Far-field fast path: relief cannot move the surface here, and only
	/// values near the zero crossing shape the mesh.
	if (std::fabs(sphere_sd) > shell_margin) {
		return sphere_sd;
	}
	const float inv = 1.f / r;
	const Vector3f n{ px * inv, py * inv, pz * inv };
	return sphere_sd - sampler_->height_voxels(n);
}

PackedFloat32Array MoonHeightmapBake::sample_block_sdf_f(
		const Vector3i &origin,
		const Vector3i &size,
		int stride) const {
	PackedFloat32Array out;
	if (sampler_ == nullptr || size.x <= 0 || size.y <= 0 || size.z <= 0 || stride <= 0) {
		return out;
	}
	const float shell = height_clamp_voxels() + kShellMarginVoxels;
	out.resize(int64_t(size.x) * size.y * size.z);
	float *dst = out.ptrw();
	/// VoxelBuffer memory order: index = y + sy * (x + sx * z).
	for (int z = 0; z < size.z; ++z) {
		const float pz = float(origin.z + z * stride);
		for (int x = 0; x < size.x; ++x) {
			const float px = float(origin.x + x * stride);
			for (int y = 0; y < size.y; ++y) {
				const float py = float(origin.y + y * stride);
				*dst++ = sample_sdf(px, py, pz, shell);
			}
		}
	}
	return out;
}

PackedByteArray MoonHeightmapBake::sample_block_sdf16(
		const Vector3i &origin,
		const Vector3i &size,
		int stride,
		float encode_scale) const {
	PackedByteArray out;
	if (sampler_ == nullptr || size.x <= 0 || size.y <= 0 || size.z <= 0 || stride <= 0) {
		return out;
	}
	const float shell = height_clamp_voxels() + kShellMarginVoxels;
	out.resize(int64_t(size.x) * size.y * size.z * 2);
	uint8_t *dst = out.ptrw();
	for (int z = 0; z < size.z; ++z) {
		const float pz = float(origin.z + z * stride);
		for (int x = 0; x < size.x; ++x) {
			const float px = float(origin.x + x * stride);
			for (int y = 0; y < size.y; ++y) {
				const float py = float(origin.y + y * stride);
				const uint16_t raw = encode_sdf_s16(sample_sdf(px, py, pz, shell), encode_scale);
				/// Little-endian, matching VoxelBuffer channel bytes on x86/ARM.
				dst[0] = uint8_t(raw & 0xFF);
				dst[1] = uint8_t(raw >> 8);
				dst += 2;
			}
		}
	}
	return out;
}

PackedByteArray MoonHeightmapBake::encode_values_s16(
		const PackedFloat32Array &values,
		float encode_scale) const {
	PackedByteArray out;
	out.resize(values.size() * 2);
	uint8_t *dst = out.ptrw();
	const float *src = values.ptr();
	for (int64_t i = 0; i < values.size(); ++i) {
		const uint16_t raw = encode_sdf_s16(src[i], encode_scale);
		dst[0] = uint8_t(raw & 0xFF);
		dst[1] = uint8_t(raw >> 8);
		dst += 2;
	}
	return out;
}

float MoonHeightmapBake::sample_fnl(
		int seed_value,
		float period_voxels,
		int octaves,
		float gain,
		float lacunarity,
		const Vector3 &position) const {
	FastNoiseLite fnl;
	MoonTerrainSampler::configure_fnl(fnl, seed_value, period_voxels, octaves, gain, lacunarity);
	return MoonTerrainSampler::sample_fnl(
			fnl, Vector3f{float(position.x), float(position.y), float(position.z)});
}

godot::PackedFloat32Array MoonHeightmapBake::bake_panorama(
		int width,
		int height,
		float radius_voxels) {
	godot::PackedFloat32Array out;
	if (width <= 0 || height <= 0) {
		return out;
	}

	const int cpu = OS::get_singleton()->get_processor_count();
	const int worker_count = std::clamp(cpu, 1, height);

	std::vector<std::unique_ptr<MoonTerrainSampler>> samplers;
	samplers.reserve(static_cast<size_t>(worker_count));
	for (int i = 0; i < worker_count; ++i) {
		samplers.push_back(std::make_unique<MoonTerrainSampler>(radius_voxels));
	}

	const int band_size = (height + worker_count - 1) / worker_count;
	std::vector<MoonBakeBandResult> results(static_cast<size_t>(worker_count));
	std::vector<std::thread> threads;
	threads.reserve(static_cast<size_t>(worker_count));

	for (int band = 0; band < worker_count; ++band) {
		const int y0 = band * band_size;
		const int y1 = std::min(y0 + band_size, height);
		if (y0 >= height) {
			break;
		}
		MoonTerrainSampler *sampler = samplers[static_cast<size_t>(band)].get();
		threads.emplace_back([width, height, y0, y1, &results, band, sampler]() {
			MoonBakeBandResult band_result;
			band_result.y0 = y0;
			const int band_h = y1 - y0;
			band_result.buffer.resize(static_cast<size_t>(band_h) * static_cast<size_t>(width));
			for (int local_y = 0; local_y < band_h; ++local_y) {
				const int y = y0 + local_y;
				const float v = (float(y) + 0.5f) / float(height);
				const int row_offset = local_y * width;
				for (int x = 0; x < width; ++x) {
					const float u = (float(x) + 0.5f) / float(width);
					const Vector3f n = MoonTerrainSampler::direction_from_node_uv(u, v);
					band_result.buffer[static_cast<size_t>(row_offset + x)] =
							sampler->height_voxels(n);
				}
			}
			results[static_cast<size_t>(band)] = std::move(band_result);
		});
	}

	for (std::thread &thread : threads) {
		if (thread.joinable()) {
			thread.join();
		}
	}

	out.resize(width * height);
	for (const MoonBakeBandResult &band_result : results) {
		if (band_result.buffer.empty()) {
			continue;
		}
		const int band_h = static_cast<int>(band_result.buffer.size()) / width;
		for (int local_y = 0; local_y < band_h; ++local_y) {
			const int dst = (band_result.y0 + local_y) * width;
			const int src = local_y * width;
			for (int x = 0; x < width; ++x) {
				out[dst + x] = band_result.buffer[static_cast<size_t>(src + x)];
			}
		}
	}

	return out;
}
