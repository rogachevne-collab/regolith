#include "moon_heightmap_bake.hpp"

#include "moon_terrain_sampler.hpp"

#include <godot_cpp/core/class_db.hpp>

#include <memory>

using namespace godot;

void MoonHeightmapBake::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD(
					"bake_panorama",
					"width",
					"height",
					"radius_voxels",
					"mare_field",
					"highland_rough",
					"surface",
					"regolith"),
			&MoonHeightmapBake::bake_panorama);
}

godot::PackedFloat32Array MoonHeightmapBake::bake_panorama(
		int width,
		int height,
		float radius_voxels,
		const Variant &mare_field,
		const Variant &highland_rough,
		const Variant &surface,
		const Variant &regolith) {
	godot::PackedFloat32Array out;
	if (width <= 0 || height <= 0) {
		return out;
	}

	/// ZN_FastNoiseLite must be created in GDScript (Voxel Tools). Godot
	/// Object::call is main-thread only — bake is single-threaded; crater math
	/// in C++ still beats full GDScript by a large margin.
	auto sampler = std::make_unique<MoonTerrainSampler>(
			radius_voxels,
			mare_field,
			highland_rough,
			surface,
			regolith);

	out.resize(width * height);
	for (int y = 0; y < height; ++y) {
		const float v = (float(y) + 0.5f) / float(height);
		const int row = y * width;
		for (int x = 0; x < width; ++x) {
			const float u = (float(x) + 0.5f) / float(width);
			const Vector3f n = MoonTerrainSampler::direction_from_node_uv(u, v);
			out[row + x] = sampler->height_voxels(n);
		}
	}

	return out;
}
