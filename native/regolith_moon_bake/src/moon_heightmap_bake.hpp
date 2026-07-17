#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <godot_cpp/core/class_db.hpp>

class MoonHeightmapBake : public godot::RefCounted {
	GDCLASS(MoonHeightmapBake, godot::RefCounted)

public:
	godot::PackedFloat32Array bake_panorama(
			int width,
			int height,
			float radius_voxels,
			const godot::Variant &mare_field,
			const godot::Variant &highland_rough,
			const godot::Variant &surface,
			const godot::Variant &regolith);

protected:
	static void _bind_methods();
};
