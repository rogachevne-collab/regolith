#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

/// Geometry kernel for construction preview hot paths.
/// Authoritative validate_place / plan() stay in GDScript.
class ConstructionPreviewKernel : public godot::RefCounted {
	GDCLASS(ConstructionPreviewKernel, godot::RefCounted)

public:
	/// Compatible socket tag pairs as "left|right" (both directions should be listed
	/// or will be stored symmetrically). Empty tags normalize to "structural".
	void set_compatible_tag_pairs(const godot::PackedStringArray &pairs);

	/// Mirror of GridSurfaceUtil.find_rigid_connection_specs.
	/// Side dict: origin_cell, orientation_index, footprint_size, faces[{local_cell,local_face,port_id,socket_tag}].
	godot::Dictionary find_rigid_connection(const godot::Dictionary &left, const godot::Dictionary &right) const;

	/// Magnet face scan over a world snapshot (see ConstructionPreviewSnapshot.gd).
	godot::Array scan_magnetic_faces(
			const godot::Dictionary &snapshot,
			const godot::Dictionary &ray,
			const godot::Dictionary &limits) const;

	bool prefilter_attach_fits(
			const godot::PackedInt32Array &occupancy,
			const godot::PackedVector3Array &footprint,
			const godot::Vector3i &origin,
			int orientation_index) const;

	godot::PackedInt32Array neighbour_element_ids(
			const godot::PackedVector3Array &preview_cells,
			const godot::PackedInt32Array &occupancy) const;

	bool check_preview_overlap(
			const godot::PackedVector3Array &preview_cells,
			const godot::PackedInt32Array &occupancy) const;

	/// Overlap + rigid connections for attach preview validate (one IPC call).
	godot::Dictionary find_attach_connections(
			const godot::PackedInt32Array &occupancy,
			const godot::PackedVector3Array &preview_cells,
			const godot::Dictionary &preview_side,
			const godot::Array &neighbour_sides) const;

	/// Phase 4: body-group compile from packed joint/element tables.
	/// joints: PackedInt32Array flat [kind, a_id, b_id, joint_id] * N
	/// element_flags: PackedInt32Array parallel to element_ids (bit0=suspension, bit1=wheel)
	godot::Dictionary compile_body_groups(
			const godot::PackedInt32Array &element_ids,
			const godot::PackedInt32Array &element_flags,
			const godot::PackedInt32Array &joints) const;

protected:
	static void _bind_methods();

private:
	struct FaceDesc {
		godot::Vector3i local_cell;
		int local_face = 0;
		godot::String port_id;
		godot::String socket_tag;
	};

	struct SideSpec {
		godot::Vector3i origin_cell;
		int orientation_index = 0;
		int footprint_size = 0;
		std::vector<FaceDesc> faces;
	};

	struct WorldFace {
		godot::String port_id;
		godot::String socket_tag;
	};

	mutable std::unordered_set<std::string> _compatible_pairs;

	static godot::String normalize_tag(const godot::String &tag);
	static std::string pair_key(const godot::String &a, const godot::String &b);
	bool socket_tags_compatible(const godot::String &left, const godot::String &right) const;

	static SideSpec parse_side(const godot::Dictionary &side);
	static uint64_t world_face_key(const godot::Vector3i &cell, const godot::Vector3i &direction);
	static void build_world_face_lookup(const SideSpec &side, std::unordered_map<uint64_t, WorldFace> &out);
	godot::Dictionary find_canonical_pair_scan(const SideSpec &left, const SideSpec &right) const;

	static bool occupancy_has(const godot::PackedInt32Array &occupancy, const godot::Vector3i &cell, int *element_id = nullptr);
	static void pack_cell_key(int32_t x, int32_t y, int32_t z, int32_t *out);
};
