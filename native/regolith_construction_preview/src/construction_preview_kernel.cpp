#include "construction_preview_kernel.hpp"

#include "orientation_tables.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace godot;
using namespace regolith_construction;

namespace {

constexpr double kCellSizeM = 0.5;
constexpr double kHalfCellSizeM = 0.25;

constexpr int kFlagSuspension = 1;
constexpr int kFlagWheel = 2;

constexpr int kJointRigid = 0;
constexpr int kJointAnchor = 1;
constexpr int kJointPiston = 2;
constexpr int kJointRotor = 3;
constexpr int kJointHinge = 4;

constexpr int kMaxDrivenJointsOnPath = 16;

Vector3i meters_to_cell_floor(const Vector3 &position_m) {
	return Vector3i(
			static_cast<int32_t>(std::floor(position_m.x / kCellSizeM)),
			static_cast<int32_t>(std::floor(position_m.y / kCellSizeM)),
			static_cast<int32_t>(std::floor(position_m.z / kCellSizeM)));
}

Vector3 cell_center_meters(const Vector3i &cell) {
	return Vector3(cell) * kCellSizeM + Vector3(kHalfCellSizeM, kHalfCellSizeM, kHalfCellSizeM);
}

Vector3 cell_to_meters(const Vector3i &cell) {
	return Vector3(cell) * kCellSizeM;
}

uint64_t pack_cell(int32_t x, int32_t y, int32_t z) {
	// Pack signed 21-bit-ish coords into 64 bits (enough for construction grids).
	const uint64_t ux = static_cast<uint32_t>(x) & 0x1FFFFFu;
	const uint64_t uy = static_cast<uint32_t>(y) & 0x1FFFFFu;
	const uint64_t uz = static_cast<uint32_t>(z) & 0x1FFFFFu;
	return ux | (uy << 21) | (uz << 42);
}

bool unpack_occupancy(
		const PackedInt32Array &occupancy,
		std::unordered_map<uint64_t, int32_t> &out,
		Vector3i *minimum = nullptr,
		Vector3i *maximum = nullptr) {
	if (occupancy.size() % 4 != 0) {
		return false;
	}
	out.clear();
	out.reserve(static_cast<size_t>(occupancy.size() / 4));
	bool first = true;
	for (int i = 0; i + 3 < occupancy.size(); i += 4) {
		const int32_t x = occupancy[i];
		const int32_t y = occupancy[i + 1];
		const int32_t z = occupancy[i + 2];
		out[pack_cell(x, y, z)] = occupancy[i + 3];
		if (minimum != nullptr && maximum != nullptr) {
			const Vector3i cell(x, y, z);
			if (first) {
				*minimum = cell;
				*maximum = cell;
				first = false;
			} else {
				*minimum = Vector3i(
						std::min(minimum->x, cell.x),
						std::min(minimum->y, cell.y),
						std::min(minimum->z, cell.z));
				*maximum = Vector3i(
						std::max(maximum->x, cell.x),
						std::max(maximum->y, cell.y),
						std::max(maximum->z, cell.z));
			}
		}
	}
	return true;
}

/// Match Godot `str(Vector3i)` used in ConstructionSnapResolver face keys.
String vector3i_key(const Vector3i &v) {
	return String("(") + String::num_int64(v.x) + String(", ") + String::num_int64(v.y) + String(", ") +
			String::num_int64(v.z) + String(")");
}

std::vector<Vector3i> build_magnet_offsets() {
	std::vector<Vector3i> offsets;
	for (int x = -2; x <= 2; ++x) {
		for (int y = -2; y <= 2; ++y) {
			for (int z = -2; z <= 2; ++z) {
				const int manhattan = std::abs(x) + std::abs(y) + std::abs(z);
				if (manhattan == 0 || manhattan > 2) {
					continue;
				}
				offsets.emplace_back(x, y, z);
			}
		}
	}
	return offsets;
}

const std::vector<Vector3i> &magnet_offsets() {
	static const auto offsets = build_magnet_offsets();
	return offsets;
}

std::vector<Vector3i> face_directions_toward(const Vector3i &offset) {
	std::vector<Vector3i> directions;
	if (offset.x != 0) {
		directions.emplace_back(-((offset.x > 0) - (offset.x < 0)), 0, 0);
	}
	if (offset.y != 0) {
		directions.emplace_back(0, -((offset.y > 0) - (offset.y < 0)), 0);
	}
	if (offset.z != 0) {
		directions.emplace_back(0, 0, -((offset.z > 0) - (offset.z < 0)));
	}
	return directions;
}

Vector3i dominant_grid_direction(const Vector3 &direction) {
	const Vector3 absolute = direction.abs();
	if (absolute.x >= absolute.y && absolute.x >= absolute.z) {
		return direction.x >= 0.0 ? Vector3i(1, 0, 0) : Vector3i(-1, 0, 0);
	}
	if (absolute.y >= absolute.z) {
		return direction.y >= 0.0 ? Vector3i(0, 1, 0) : Vector3i(0, -1, 0);
	}
	return direction.z >= 0.0 ? Vector3i(0, 0, 1) : Vector3i(0, 0, -1);
}

bool ray_hits_aabb(const AABB &bounds, const Vector3 &origin, const Vector3 &direction, double max_distance) {
	const Variant hit = bounds.intersects_segment(origin, origin + direction * max_distance);
	return hit.get_type() != Variant::NIL;
}

bool is_in_corridor(
		const Vector3 &ray_origin,
		const Vector3 &ray_direction,
		const Vector3 &world_point,
		double max_distance,
		double max_lateral,
		double min_forward_dot) {
	const Vector3 to_point = world_point - ray_origin;
	const double along = to_point.dot(ray_direction);
	if (along < 0.05 || along > max_distance) {
		return false;
	}
	if (to_point.cross(ray_direction).length() > max_lateral) {
		return false;
	}
	if (to_point.length_squared() <= 0.000001) {
		return true;
	}
	return ray_direction.dot(to_point.normalized()) >= min_forward_dot;
}

double score_geometric(
		const Vector3 &ray_origin,
		const Vector3 &ray_direction,
		const Vector2 &viewport_center,
		bool has_camera,
		const Vector3 &world_point,
		double max_ray_distance,
		double max_screen_penalty_radius,
		const Callable &unproject) {
	const Vector3 to_point = world_point - ray_origin;
	const double ray_distance = to_point.cross(ray_direction).length();
	double angle_penalty = 0.0;
	if (to_point.length_squared() > 0.000001) {
		angle_penalty = 1.0 - std::clamp(ray_direction.dot(to_point.normalized()), 0.0, 1.0);
	}
	const double distance = ray_origin.distance_to(world_point);
	const double distance_penalty = std::clamp(distance / max_ray_distance, 0.0, 1.0);
	double screen_penalty = 0.0;
	if (has_camera && viewport_center.length_squared() > 0.000001 && unproject.is_valid()) {
		const Vector2 screen = unproject.call(world_point);
		screen_penalty = std::clamp(
				screen.distance_to(viewport_center) / viewport_center.length(),
				0.0,
				max_screen_penalty_radius);
	}
	double score = 10.0;
	score -= ray_distance * 2.0;
	score -= angle_penalty;
	score -= distance_penalty * 0.5;
	score -= screen_penalty * 0.3;
	return score;
}

struct JointRec {
	int kind = 0;
	int a = 0;
	int b = 0;
	int joint_id = 0;
};

bool is_driven_kind(int kind) {
	return kind == kJointPiston || kind == kJointRotor || kind == kJointHinge;
}

} // namespace

void ConstructionPreviewKernel::set_compatible_tag_pairs(const PackedStringArray &pairs) {
	_compatible_pairs.clear();
	for (int i = 0; i < pairs.size(); ++i) {
		const String pair = pairs[i];
		const PackedStringArray parts = pair.split("|");
		if (parts.size() != 2) {
			continue;
		}
		const String a = normalize_tag(parts[0]);
		const String b = normalize_tag(parts[1]);
		_compatible_pairs.insert(pair_key(a, b));
		_compatible_pairs.insert(pair_key(b, a));
	}
	// Builtin fallback if caller passed nothing.
	if (_compatible_pairs.empty()) {
		_compatible_pairs.insert(pair_key(String("structural"), String("structural")));
		_compatible_pairs.insert(pair_key(String("wheel_socket"), String("wheel_plug")));
		_compatible_pairs.insert(pair_key(String("wheel_plug"), String("wheel_socket")));
	}
}

String ConstructionPreviewKernel::normalize_tag(const String &tag) {
	return tag.is_empty() ? String("structural") : tag;
}

std::string ConstructionPreviewKernel::pair_key(const String &a, const String &b) {
	return std::string((a + String("|") + b).utf8().get_data());
}

bool ConstructionPreviewKernel::socket_tags_compatible(const String &left, const String &right) const {
	if (_compatible_pairs.empty()) {
		const String a = normalize_tag(left);
		const String b = normalize_tag(right);
		if (a == String("structural") && b == String("structural")) {
			return true;
		}
		return (a == String("wheel_socket") && b == String("wheel_plug")) ||
				(a == String("wheel_plug") && b == String("wheel_socket"));
	}
	return _compatible_pairs.find(pair_key(normalize_tag(left), normalize_tag(right))) != _compatible_pairs.end();
}

ConstructionPreviewKernel::SideSpec ConstructionPreviewKernel::parse_side(const Dictionary &side) {
	SideSpec spec;
	spec.origin_cell = side.get("origin_cell", Vector3i());
	spec.orientation_index = int(side.get("orientation_index", 0));
	spec.footprint_size = int(side.get("footprint_size", 0));
	const Array faces = side.get("faces", Array());
	spec.faces.reserve(faces.size());
	for (int i = 0; i < faces.size(); ++i) {
		const Dictionary face = faces[i];
		FaceDesc desc;
		desc.local_cell = face.get("local_cell", Vector3i());
		desc.local_face = int(face.get("local_face", 0));
		desc.port_id = face.get("port_id", String());
		desc.socket_tag = face.get("socket_tag", String());
		spec.faces.push_back(desc);
	}
	if (spec.footprint_size <= 0) {
		spec.footprint_size = int(side.get("footprint_cells_size", int(spec.faces.size())));
	}
	return spec;
}

uint64_t ConstructionPreviewKernel::world_face_key(const Vector3i &cell, const Vector3i &direction) {
	// Distinct from occupancy pack: include direction in high bits via XOR mix.
	const uint64_t cell_bits = pack_cell(cell.x, cell.y, cell.z);
	const uint64_t dir_bits = pack_cell(direction.x + 1, direction.y + 1, direction.z + 1);
	return cell_bits ^ (dir_bits << 3);
}

void ConstructionPreviewKernel::build_world_face_lookup(
		const SideSpec &side,
		std::unordered_map<uint64_t, WorldFace> &out) {
	out.clear();
	for (const FaceDesc &desc : side.faces) {
		const Vector3i cell = side.origin_cell + rotate_cell(desc.local_cell, side.orientation_index);
		const Vector3i direction =
				rotate_direction(face_to_vector(desc.local_face), side.orientation_index);
		WorldFace face;
		face.port_id = desc.port_id;
		face.socket_tag = desc.socket_tag;
		out[world_face_key(cell, direction)] = face;
	}
}

Dictionary ConstructionPreviewKernel::find_canonical_pair_scan(const SideSpec &left, const SideSpec &right) const {
	std::unordered_map<uint64_t, WorldFace> right_lookup;
	build_world_face_lookup(right, right_lookup);

	struct Match {
		String left_port;
		String right_port;
	};
	std::vector<Match> matches;
	for (const FaceDesc &left_desc : left.faces) {
		const Vector3i left_cell = left.origin_cell + rotate_cell(left_desc.local_cell, left.orientation_index);
		const Vector3i left_dir =
				rotate_direction(face_to_vector(left_desc.local_face), left.orientation_index);
		const Vector3i adjacent_cell = left_cell + left_dir;
		const Vector3i adjacent_dir(-left_dir.x, -left_dir.y, -left_dir.z);
		const auto it = right_lookup.find(world_face_key(adjacent_cell, adjacent_dir));
		if (it == right_lookup.end()) {
			continue;
		}
		if (!socket_tags_compatible(left_desc.socket_tag, it->second.socket_tag)) {
			continue;
		}
		matches.push_back({ left_desc.port_id, it->second.port_id });
	}
	if (matches.empty()) {
		return Dictionary();
	}
	std::sort(matches.begin(), matches.end(), [](const Match &a, const Match &b) {
		if (a.left_port != b.left_port) {
			return a.left_port < b.left_port;
		}
		return a.right_port < b.right_port;
	});
	Dictionary out;
	out["left_port_id"] = matches[0].left_port;
	out["right_port_id"] = matches[0].right_port;
	return out;
}

Dictionary ConstructionPreviewKernel::find_rigid_connection(const Dictionary &left, const Dictionary &right) const {
	SideSpec left_spec = parse_side(left);
	SideSpec right_spec = parse_side(right);
	if (left_spec.footprint_size > right_spec.footprint_size) {
		Dictionary swapped = find_canonical_pair_scan(right_spec, left_spec);
		if (swapped.is_empty()) {
			return Dictionary();
		}
		Dictionary out;
		out["left_port_id"] = swapped["right_port_id"];
		out["right_port_id"] = swapped["left_port_id"];
		return out;
	}
	return find_canonical_pair_scan(left_spec, right_spec);
}

bool ConstructionPreviewKernel::prefilter_attach_fits(
		const PackedInt32Array &occupancy,
		const PackedVector3Array &footprint,
		const Vector3i &origin,
		int orientation_index) const {
	std::unordered_map<uint64_t, int32_t> occ;
	if (!unpack_occupancy(occupancy, occ)) {
		return true;
	}
	for (int i = 0; i < footprint.size(); ++i) {
		const Vector3 cell_f = footprint[i];
		const Vector3i local(static_cast<int32_t>(std::lround(cell_f.x)),
				static_cast<int32_t>(std::lround(cell_f.y)),
				static_cast<int32_t>(std::lround(cell_f.z)));
		const Vector3i world = origin + rotate_cell(local, orientation_index);
		if (occ.find(pack_cell(world.x, world.y, world.z)) != occ.end()) {
			return false;
		}
	}
	return true;
}

PackedInt32Array ConstructionPreviewKernel::neighbour_element_ids(
		const PackedVector3Array &preview_cells,
		const PackedInt32Array &occupancy) const {
	std::unordered_map<uint64_t, int32_t> occ;
	if (!unpack_occupancy(occupancy, occ)) {
		return PackedInt32Array();
	}
	static const Vector3i neighbours[] = {
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1),
	};
	std::unordered_set<int32_t> seen;
	for (int i = 0; i < preview_cells.size(); ++i) {
		const Vector3 cell_f = preview_cells[i];
		const Vector3i cell(static_cast<int32_t>(std::lround(cell_f.x)),
				static_cast<int32_t>(std::lround(cell_f.y)),
				static_cast<int32_t>(std::lround(cell_f.z)));
		for (const Vector3i &offset : neighbours) {
			const Vector3i n = cell + offset;
			const auto it = occ.find(pack_cell(n.x, n.y, n.z));
			if (it != occ.end()) {
				seen.insert(it->second);
			}
		}
	}
	std::vector<int32_t> ids(seen.begin(), seen.end());
	std::sort(ids.begin(), ids.end());
	PackedInt32Array out;
	out.resize(static_cast<int64_t>(ids.size()));
	for (size_t i = 0; i < ids.size(); ++i) {
		out[static_cast<int>(i)] = ids[i];
	}
	return out;
}

bool ConstructionPreviewKernel::check_preview_overlap(
		const PackedVector3Array &preview_cells,
		const PackedInt32Array &occupancy) const {
	std::unordered_map<uint64_t, int32_t> occ;
	if (!unpack_occupancy(occupancy, occ)) {
		return false;
	}
	for (int i = 0; i < preview_cells.size(); ++i) {
		const Vector3 cell_f = preview_cells[i];
		const Vector3i cell(static_cast<int32_t>(std::lround(cell_f.x)),
				static_cast<int32_t>(std::lround(cell_f.y)),
				static_cast<int32_t>(std::lround(cell_f.z)));
		if (occ.find(pack_cell(cell.x, cell.y, cell.z)) != occ.end()) {
			return true;
		}
	}
	return false;
}

Array ConstructionPreviewKernel::scan_magnetic_faces(
		const Dictionary &snapshot,
		const Dictionary &ray,
		const Dictionary &limits) const {
	Array faces_out;
	const Array assemblies = snapshot.get("assemblies", Array());
	const Vector3 ray_origin = ray.get("origin", Vector3());
	Vector3 ray_direction = ray.get("direction", Vector3(0, 0, -1));
	if (ray_direction.length_squared() < 1e-12) {
		return faces_out;
	}
	ray_direction = ray_direction.normalized();
	const Vector2 viewport_center = ray.get("viewport_center", Vector2());
	const bool has_camera = bool(ray.get("has_camera", false));
	const Callable unproject = ray.get("unproject", Callable());

	const double max_ray_distance = double(limits.get("max_ray_distance", 4.0));
	const double max_lateral = double(limits.get("max_lateral", 1.2));
	const double min_forward_dot = double(limits.get("min_forward_dot", 0.15));
	const double ray_step = double(limits.get("ray_step", kHalfCellSizeM));
	const double max_screen_penalty = double(limits.get("max_screen_penalty_radius", 0.65));

	for (int ai = 0; ai < assemblies.size(); ++ai) {
		const Dictionary assembly = assemblies[ai];
		if (!bool(assembly.get("attach_allowed", true))) {
			continue;
		}
		const int assembly_id = int(assembly.get("assembly_id", 0));
		const bool single_group = bool(assembly.get("single_group", true));
		const Transform3D root_transform = assembly.get("root_transform", Transform3D());
		const PackedInt32Array occupancy_packed = assembly.get("occupancy", PackedInt32Array());
		std::unordered_map<uint64_t, int32_t> occupancy;
		Vector3i minimum;
		Vector3i maximum;
		if (!unpack_occupancy(occupancy_packed, occupancy, &minimum, &maximum) || occupancy.empty()) {
			continue;
		}

		AABB bounds(cell_to_meters(minimum), cell_to_meters(maximum + Vector3i(1, 1, 1)) - cell_to_meters(minimum));
		bounds = bounds.grow(max_lateral);

		const Transform3D inverse = root_transform.affine_inverse();
		const Vector3 local_origin = inverse.xform(ray_origin);
			const Vector3 local_direction = inverse.basis.xform(ray_direction).normalized();
		if (!ray_hits_aabb(bounds, local_origin, local_direction, max_ray_distance)) {
			continue;
		}

		const Dictionary elements = assembly.get("elements", Dictionary());
		std::unordered_set<uint64_t> visited;
		std::unordered_set<uint64_t> seen_faces;
		Vector3i previous_cell = meters_to_cell_floor(local_origin);
		double travelled = 0.0;

		auto append_face = [&](const Vector3i &face_cell, const Vector3i &face_dir) {
			const uint64_t face_key = world_face_key(face_cell, face_dir);
			if (seen_faces.find(face_key) != seen_faces.end()) {
				return;
			}
			seen_faces.insert(face_key);
			const auto occ_it = occupancy.find(pack_cell(face_cell.x, face_cell.y, face_cell.z));
			if (occ_it == occupancy.end()) {
				return;
			}
			const int element_id = occ_it->second;
			const Dictionary element = elements.get(String::num_int64(element_id), Dictionary());
			if (element.is_empty()) {
				return;
			}
			const Transform3D group_transform = element.get("group_transform", root_transform);
			const bool driven_at_home = bool(element.get("driven_path_at_home", true));
			if (!single_group && !group_transform.is_equal_approx(root_transform) && !driven_at_home) {
				return;
			}
			const Transform3D pose_transform =
					group_transform.is_equal_approx(root_transform) ? root_transform : group_transform;
			const Vector3 local_normal(face_dir);
			const Vector3 local_point = cell_center_meters(face_cell) + local_normal * kHalfCellSizeM;
			const Vector3 world_point = pose_transform.xform(local_point);
			if (!is_in_corridor(ray_origin, ray_direction, world_point, max_ray_distance, max_lateral, min_forward_dot)) {
				return;
			}
			const Vector3 world_normal = pose_transform.basis.xform(local_normal).normalized();
			const Vector3i origin_cell = element.get("origin_cell", Vector3i());
			const int orientation_index = int(element.get("orientation_index", 0));
			const Vector3 delta(Vector3(face_cell) - Vector3(origin_cell));
			const int oi = std::clamp(orientation_index, 0, kOrientationCount - 1);
			const Vector3 local = orientations()[oi].inverse().xform(delta);
			const Vector3i collider_local(
					static_cast<int32_t>(std::lround(local.x)),
					static_cast<int32_t>(std::lround(local.y)),
					static_cast<int32_t>(std::lround(local.z)));

			Dictionary target_metadata;
			target_metadata["element_id"] = element_id;
			target_metadata["assembly_id"] = assembly_id;
			target_metadata["snap_cell"] = face_cell;
			target_metadata["snap_dir"] = face_dir;
			target_metadata["collider_local_cell"] = collider_local;

			Dictionary entry;
			entry["key"] = String::num_int64(element_id) + String("|") + vector3i_key(face_cell) + String("|") +
					vector3i_key(face_dir);
			entry["score"] = score_geometric(
					ray_origin,
					ray_direction,
					viewport_center,
					has_camera,
					world_point,
					max_ray_distance,
					max_screen_penalty,
					unproject);
			entry["target_metadata"] = target_metadata;
			entry["world_point"] = world_point;
			entry["world_normal"] = world_normal;
			entry["distance"] = ray_origin.distance_to(world_point);
			faces_out.push_back(entry);
		};

		while (travelled <= max_ray_distance) {
			const Vector3 sample = local_origin + local_direction * travelled;
			travelled += ray_step;
			const Vector3i cell = meters_to_cell_floor(sample);
			const uint64_t cell_key = pack_cell(cell.x, cell.y, cell.z);
			if (visited.find(cell_key) != visited.end()) {
				continue;
			}
			visited.insert(cell_key);
			if (occupancy.find(cell_key) != occupancy.end()) {
				Vector3i entry_dir;
				const Vector3i delta = previous_cell - cell;
				const Vector3i toward_offset(-delta.x, -delta.y, -delta.z);
				for (const Vector3i &face_dir : face_directions_toward(toward_offset)) {
					if (occupancy.find(pack_cell(cell.x + face_dir.x, cell.y + face_dir.y, cell.z + face_dir.z)) ==
							occupancy.end()) {
						entry_dir = face_dir;
						break;
					}
				}
				if (entry_dir == Vector3i()) {
					const Vector3i dominant = dominant_grid_direction(-local_direction);
					if (occupancy.find(pack_cell(cell.x + dominant.x, cell.y + dominant.y, cell.z + dominant.z)) ==
							occupancy.end()) {
						entry_dir = dominant;
					}
				}
				if (entry_dir != Vector3i()) {
					append_face(cell, entry_dir);
				}
				break;
			}
			for (const Vector3i &offset : magnet_offsets()) {
				const Vector3i occupied = cell + offset;
				if (occupancy.find(pack_cell(occupied.x, occupied.y, occupied.z)) == occupancy.end()) {
					continue;
				}
				for (const Vector3i &face_dir : face_directions_toward(offset)) {
					const Vector3i blocked = occupied + face_dir;
					if (occupancy.find(pack_cell(blocked.x, blocked.y, blocked.z)) != occupancy.end()) {
						continue;
					}
					append_face(occupied, face_dir);
				}
			}
			previous_cell = cell;
		}
	}
	return faces_out;
}

Dictionary ConstructionPreviewKernel::compile_body_groups(
		const PackedInt32Array &element_ids,
		const PackedInt32Array &element_flags,
		const PackedInt32Array &joints) const {
	Dictionary failed;
	failed["valid"] = false;

	if (element_ids.size() != element_flags.size() || joints.size() % 4 != 0) {
		failed["reason"] = StringName("invalid_input");
		return failed;
	}

	std::unordered_map<int, int> flags_by_id;
	std::vector<int> ids;
	ids.reserve(element_ids.size());
	for (int i = 0; i < element_ids.size(); ++i) {
		ids.push_back(element_ids[i]);
		flags_by_id[element_ids[i]] = element_flags[i];
	}

	std::vector<JointRec> all_joints;
	all_joints.reserve(joints.size() / 4);
	for (int i = 0; i + 3 < joints.size(); i += 4) {
		all_joints.push_back({ joints[i], joints[i + 1], joints[i + 2], joints[i + 3] });
	}

	auto is_suspension = [&](int id) {
		return (flags_by_id[id] & kFlagSuspension) != 0;
	};
	auto is_wheel = [&](int id) {
		return (flags_by_id[id] & kFlagWheel) != 0;
	};
	auto is_wheel_pair = [&](const JointRec &j) {
		if (j.kind != kJointRigid) {
			return false;
		}
		return (is_suspension(j.a) && is_wheel(j.b)) || (is_wheel(j.a) && is_suspension(j.b));
	};

	// Union-find over glue (non-wheel-pair) rigid joints.
	std::unordered_map<int, int> parent;
	for (int id : ids) {
		parent[id] = id;
	}
	std::function<int(int)> find = [&](int x) -> int {
		int &p = parent[x];
		if (p != x) {
			p = find(p);
		}
		return p;
	};
	auto unite = [&](int a, int b) {
		a = find(a);
		b = find(b);
		if (a == b) {
			return;
		}
		if (a < b) {
			parent[b] = a;
		} else {
			parent[a] = b;
		}
	};

	std::vector<JointRec> wheel_joints;
	std::vector<JointRec> glue_joints;
	for (const JointRec &j : all_joints) {
		if (is_wheel_pair(j)) {
			wheel_joints.push_back(j);
		} else if (j.kind == kJointRigid) {
			glue_joints.push_back(j);
			if (parent.count(j.a) && parent.count(j.b)) {
				unite(j.a, j.b);
			}
		}
	}

	std::unordered_map<int, std::vector<int>> groups_map;
	std::unordered_map<int, int> element_to_group;
	for (int id : ids) {
		const int root = find(id);
		groups_map[root].push_back(id);
	}
	for (auto &kv : groups_map) {
		std::sort(kv.second.begin(), kv.second.end());
		const int group_id = kv.second.empty() ? 0 : kv.second.front();
		for (int id : kv.second) {
			element_to_group[id] = group_id;
		}
	}

	Array wheel_specs;
	std::unordered_set<int> wheel_group_ids;
	for (const JointRec &j : wheel_joints) {
		int suspension_id = j.a;
		int wheel_id = j.b;
		if (!is_suspension(suspension_id) || !is_wheel(wheel_id)) {
			suspension_id = j.b;
			wheel_id = j.a;
		}
		const int suspension_group = element_to_group[suspension_id];
		const int wheel_group = element_to_group[wheel_id];
		if (suspension_group <= 0 || wheel_group <= 0 || suspension_group == wheel_group) {
			failed["reason"] = StringName("invalid_wheel_groups");
			return failed;
		}
		Dictionary spec;
		spec["joint_id"] = j.joint_id;
		spec["suspension_element_id"] = suspension_id;
		spec["wheel_element_id"] = wheel_id;
		spec["suspension_group_id"] = suspension_group;
		spec["wheel_group_id"] = wheel_group;
		wheel_specs.push_back(spec);
		wheel_group_ids.insert(wheel_group);
	}

	Array driven_specs;
	for (const JointRec &j : all_joints) {
		if (!is_driven_kind(j.kind)) {
			continue;
		}
		const int base_group = element_to_group[j.a];
		const int head_group = element_to_group[j.b];
		if (base_group <= 0 || head_group <= 0 || base_group == head_group) {
			failed["reason"] = StringName("invalid_piston_groups");
			return failed;
		}
		Dictionary spec;
		spec["joint_id"] = j.joint_id;
		spec["joint_kind"] = j.kind;
		spec["base_element_id"] = j.a;
		spec["head_element_id"] = j.b;
		spec["base_group_id"] = base_group;
		spec["head_group_id"] = head_group;
		driven_specs.push_back(spec);
	}

	// Root group: prefer unique anchored group, else first non-wheel group.
	std::unordered_set<int> anchored_groups;
	for (const JointRec &j : all_joints) {
		if (j.kind != kJointAnchor) {
			continue;
		}
		const auto it = element_to_group.find(j.a);
		if (it != element_to_group.end() && it->second > 0) {
			anchored_groups.insert(it->second);
		}
	}
	int root_group_id = 0;
	if (anchored_groups.empty()) {
		std::vector<int> group_ids;
		for (const auto &kv : groups_map) {
			if (!kv.second.empty()) {
				group_ids.push_back(kv.second.front());
			}
		}
		std::sort(group_ids.begin(), group_ids.end());
		for (int gid : group_ids) {
			if (wheel_group_ids.find(gid) == wheel_group_ids.end()) {
				root_group_id = gid;
				break;
			}
		}
		if (root_group_id <= 0 && !group_ids.empty()) {
			root_group_id = group_ids.front();
		}
	} else if (anchored_groups.size() == 1) {
		root_group_id = *anchored_groups.begin();
	} else {
		for (int i = 0; i < driven_specs.size(); ++i) {
			const Dictionary spec = driven_specs[i];
			const int base_group = int(spec["base_group_id"]);
			if (anchored_groups.count(base_group)) {
				root_group_id = base_group;
				break;
			}
		}
		if (root_group_id <= 0) {
			std::vector<int> anchored(anchored_groups.begin(), anchored_groups.end());
			std::sort(anchored.begin(), anchored.end());
			root_group_id = anchored.front();
		}
	}

	if (groups_map.size() > 1 && root_group_id <= 0) {
		failed["reason"] = StringName("ambiguous_root_group");
		return failed;
	}

	// Acyclic undirected driven graph.
	std::unordered_map<int, std::unordered_set<int>> adjacency;
	for (int i = 0; i < driven_specs.size(); ++i) {
		const Dictionary spec = driven_specs[i];
		const int left = int(spec["base_group_id"]);
		const int right = int(spec["head_group_id"]);
		adjacency[left].insert(right);
		adjacency[right].insert(left);
	}
	std::unordered_set<int> visited;
	std::function<bool(int, int)> dfs = [&](int node, int parent_id) -> bool {
		visited.insert(node);
		std::vector<int> neighbors(adjacency[node].begin(), adjacency[node].end());
		std::sort(neighbors.begin(), neighbors.end());
		for (int neighbor : neighbors) {
			if (neighbor == parent_id) {
				continue;
			}
			if (visited.count(neighbor)) {
				return false;
			}
			if (!dfs(neighbor, node)) {
				return false;
			}
		}
		return true;
	};
	std::vector<int> starts;
	for (const auto &kv : adjacency) {
		starts.push_back(kv.first);
	}
	std::sort(starts.begin(), starts.end());
	for (int start : starts) {
		if (visited.count(start)) {
			continue;
		}
		if (!dfs(start, -1)) {
			failed["reason"] = StringName("driven_joint_cycle");
			return failed;
		}
	}

	// Driven chain length from root.
	std::unordered_map<int, std::vector<int>> children_of;
	for (int i = 0; i < driven_specs.size(); ++i) {
		const Dictionary spec = driven_specs[i];
		children_of[int(spec["base_group_id"])].push_back(int(spec["head_group_id"]));
	}
	std::function<int(int, std::unordered_set<int> &)> longest = [&](int group_id, std::unordered_set<int> &stack) -> int {
		if (stack.count(group_id)) {
			return 0;
		}
		stack.insert(group_id);
		int best = 0;
		for (int child : children_of[group_id]) {
			best = std::max(best, 1 + longest(child, stack));
		}
		stack.erase(group_id);
		return best;
	};
	int longest_path = 0;
	if (!driven_specs.is_empty()) {
		std::vector<int> start_ids;
		if (root_group_id > 0) {
			start_ids.push_back(root_group_id);
		} else {
			for (const auto &kv : children_of) {
				start_ids.push_back(kv.first);
			}
			std::sort(start_ids.begin(), start_ids.end());
		}
		for (int start_id : start_ids) {
			std::unordered_set<int> stack;
			longest_path = std::max(longest_path, longest(start_id, stack));
		}
		if (longest_path > kMaxDrivenJointsOnPath) {
			failed["reason"] = StringName("driven_joint_chain_too_long");
			return failed;
		}
	}

	Dictionary groups_dict;
	for (const auto &kv : groups_map) {
		if (kv.second.empty()) {
			continue;
		}
		const int group_id = kv.second.front();
		Array members;
		for (int id : kv.second) {
			members.push_back(id);
		}
		groups_dict[group_id] = members;
	}
	Dictionary element_to_group_dict;
	for (const auto &kv : element_to_group) {
		element_to_group_dict[kv.first] = kv.second;
	}

	Dictionary out;
	out["valid"] = true;
	out["groups"] = groups_dict;
	out["element_to_group"] = element_to_group_dict;
	out["root_group_id"] = root_group_id;
	out["driven_specs"] = driven_specs;
	out["wheel_specs"] = wheel_specs;
	return out;
}

void ConstructionPreviewKernel::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_compatible_tag_pairs", "pairs"), &ConstructionPreviewKernel::set_compatible_tag_pairs);
	ClassDB::bind_method(D_METHOD("find_rigid_connection", "left", "right"), &ConstructionPreviewKernel::find_rigid_connection);
	ClassDB::bind_method(D_METHOD("scan_magnetic_faces", "snapshot", "ray", "limits"), &ConstructionPreviewKernel::scan_magnetic_faces);
	ClassDB::bind_method(
			D_METHOD("prefilter_attach_fits", "occupancy", "footprint", "origin", "orientation_index"),
			&ConstructionPreviewKernel::prefilter_attach_fits);
	ClassDB::bind_method(
			D_METHOD("neighbour_element_ids", "preview_cells", "occupancy"),
			&ConstructionPreviewKernel::neighbour_element_ids);
	ClassDB::bind_method(
			D_METHOD("check_preview_overlap", "preview_cells", "occupancy"),
			&ConstructionPreviewKernel::check_preview_overlap);
	ClassDB::bind_method(
			D_METHOD("compile_body_groups", "element_ids", "element_flags", "joints"),
			&ConstructionPreviewKernel::compile_body_groups);
}
