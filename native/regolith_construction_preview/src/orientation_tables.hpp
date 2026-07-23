#pragma once

#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <array>
#include <cmath>

namespace regolith_construction {

constexpr int kOrientationCount = 24;

inline int dot_i(const godot::Vector3i &a, const godot::Vector3i &b) {
	return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline godot::Vector3i cross_i(const godot::Vector3i &a, const godot::Vector3i &b) {
	return godot::Vector3i(
			a.y * b.z - a.z * b.y,
			a.z * b.x - a.x * b.z,
			a.x * b.y - a.y * b.x);
}

inline std::array<godot::Basis, kOrientationCount> build_orientations() {
	const godot::Vector3i x_axes[] = {
		godot::Vector3i(1, 0, 0),
		godot::Vector3i(-1, 0, 0),
		godot::Vector3i(0, 1, 0),
		godot::Vector3i(0, -1, 0),
		godot::Vector3i(0, 0, 1),
		godot::Vector3i(0, 0, -1),
	};
	const godot::Vector3i y_axes[] = {
		godot::Vector3i(0, 1, 0),
		godot::Vector3i(0, -1, 0),
		godot::Vector3i(1, 0, 0),
		godot::Vector3i(-1, 0, 0),
		godot::Vector3i(0, 0, 1),
		godot::Vector3i(0, 0, -1),
	};
	std::array<godot::Basis, kOrientationCount> out{};
	int count = 0;
	for (const auto &x_axis : x_axes) {
		for (const auto &y_axis : y_axes) {
			if (dot_i(x_axis, y_axis) != 0) {
				continue;
			}
			const godot::Vector3i z_axis = cross_i(x_axis, y_axis);
			out[count++] = godot::Basis(
					godot::Vector3(x_axis),
					godot::Vector3(y_axis),
					godot::Vector3(z_axis));
		}
	}
	return out;
}

inline const std::array<godot::Basis, kOrientationCount> &orientations() {
	static const auto tables = build_orientations();
	return tables;
}

inline godot::Vector3i face_to_vector(int face) {
	switch (face) {
		case 0:
			return godot::Vector3i(1, 0, 0);
		case 1:
			return godot::Vector3i(-1, 0, 0);
		case 2:
			return godot::Vector3i(0, 1, 0);
		case 3:
			return godot::Vector3i(0, -1, 0);
		case 4:
			return godot::Vector3i(0, 0, 1);
		case 5:
			return godot::Vector3i(0, 0, -1);
		default:
			return godot::Vector3i();
	}
}

inline godot::Vector3i rotate_cell(const godot::Vector3i &cell, int orientation_index) {
	if (orientation_index < 0 || orientation_index >= kOrientationCount) {
		return cell;
	}
	const godot::Vector3 rotated = orientations()[orientation_index].xform(godot::Vector3(cell));
	return godot::Vector3i(
			static_cast<int32_t>(std::lround(rotated.x)),
			static_cast<int32_t>(std::lround(rotated.y)),
			static_cast<int32_t>(std::lround(rotated.z)));
}

inline godot::Vector3i rotate_direction(const godot::Vector3i &direction, int orientation_index) {
	return rotate_cell(direction, orientation_index);
}

} // namespace regolith_construction
