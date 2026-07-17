#include "moon_heightmap_bake.hpp"

#include "moon_terrain_sampler.hpp"

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <thread>
#include <vector>

using namespace godot;

struct MoonBakeBandResult {
	int y0 = 0;
	std::vector<float> buffer;
};

void MoonHeightmapBake::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("bake_panorama", "width", "height", "radius_voxels"),
			&MoonHeightmapBake::bake_panorama);
}

godot::PackedFloat32Array MoonHeightmapBake::bake_panorama(
		int width,
		int height,
		float radius_voxels) {
	godot::PackedFloat32Array out;
	if (width <= 0 || height <= 0) {
		return out;
	}

	const int worker_count = std::clamp(
			godot::OS::get_singleton()->get_processor_count(),
			1,
			height);
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
		threads.emplace_back([width, height, radius_voxels, y0, y1, &results, band]() {
			MoonTerrainSampler sampler(radius_voxels);
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
							sampler.height_voxels(n);
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
