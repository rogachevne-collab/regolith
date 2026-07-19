#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <godot_cpp/core/class_db.hpp>

#include <memory>
#include <mutex>

class MoonTerrainSampler;

class MoonHeightmapBake : public godot::RefCounted {
	GDCLASS(MoonHeightmapBake, godot::RefCounted)

public:
	/// classify_block results.
	enum BlockClass {
		BLOCK_MIXED = 0,
		BLOCK_AIR = 1,
		BLOCK_SOLID = 2,
	};

	godot::PackedFloat32Array bake_panorama(int width, int height, float radius_voxels);

	/// Debug/parity: local FNL sample with ZN-equivalent config (period → 1/freq).
	float sample_fnl(
			int seed_value,
			float period_voxels,
			int octaves,
			float gain,
			float lacunarity,
			const godot::Vector3 &position) const;

	/// Build the shared analytic sampler once; must be called before the
	/// block API below. Safe to call again with the same radius (no-op).
	void setup(float radius_voxels);

	/// Conservative AABB-vs-shell test for a generator request.
	/// Voxels sampled are origin + i*stride, i in [0, size).
	int classify_block(
			const godot::Vector3i &origin,
			const godot::Vector3i &size,
			int stride) const;

	/// SDF for a whole block in VoxelBuffer memory order (y innermost:
	/// index = y + sy*(x + sx*z)). Values in local voxel units.
	godot::PackedFloat32Array sample_block_sdf_f(
			const godot::Vector3i &origin,
			const godot::Vector3i &size,
			int stride) const;

	/// Fused: sample + encode to 16-bit signed norm (little-endian), same
	/// memory order as sample_block_sdf_f. encode_scale maps sdf voxels →
	/// snorm (voxel tools QUANTIZED_SDF_16_BITS_SCALE; calibrated by caller).
	godot::PackedByteArray sample_block_sdf16(
			const godot::Vector3i &origin,
			const godot::Vector3i &size,
			int stride,
			float encode_scale) const;

	/// Encode arbitrary values with the same quantizer as sample_block_sdf16
	/// (used by GDScript calibration to verify parity with VoxelBuffer).
	godot::PackedByteArray encode_values_s16(
			const godot::PackedFloat32Array &values,
			float encode_scale) const;

	float height_clamp_voxels() const;

	/// Equirect brightness panorama (R8, width*height bytes): dark maria +
	/// crater ray systems. Display-only albedo multiplier (value = b*1.5).
	/// Mapping: v = acos(ny)/pi, lon = (0.5-u)*2pi, dir=(r cos, ny, r sin).
	godot::PackedByteArray bake_brightness_panorama(int width, int height) const;

	/// Skylight-entrance centers of all cave features, voxel/world space
	/// (moon-centered). Debug/teleport aid — caves are hard to find by eye.
	godot::PackedVector3Array cave_entrances() const;

	/// Analytic relief H(n) in meters — same as MoonNativeSdfGenerator shell.
	float sample_height_meters(const godot::Vector3 &direction) const;
	/// Macro relief for the orbital map globe (no meter-scale craters/grain).
	float sample_height_meters_map(const godot::Vector3 &direction) const;

protected:
	static void _bind_methods();

private:
	/// stride_m flows as a parameter — generation threads share this object.
	float sample_sdf(
			float px, float py, float pz, float shell_margin, float stride_m) const;

	std::shared_ptr<const MoonTerrainSampler> sampler_;
	float sampler_radius_voxels_ = -1.f;
	std::mutex setup_mutex_;
};

VARIANT_ENUM_CAST(MoonHeightmapBake::BlockClass);
