#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <godot_cpp/core/class_db.hpp>

class MoonHeightmapBake : public godot::RefCounted {
	GDCLASS(MoonHeightmapBake, godot::RefCounted)

public:
	godot::PackedFloat32Array bake_panorama(int width, int height, float radius_voxels);

	/// Debug/parity: local FNL sample with ZN-equivalent config (period → 1/freq).
	float sample_fnl(
			int seed_value,
			float period_voxels,
			int octaves,
			float gain,
			float lacunarity,
			const godot::Vector3 &position) const;

protected:
	static void _bind_methods();
};
