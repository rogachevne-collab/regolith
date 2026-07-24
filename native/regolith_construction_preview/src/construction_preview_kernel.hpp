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
	/// Legacy Dictionary-side path; prefer validate_attach_preview.
	godot::Dictionary find_attach_connections(
			const godot::PackedInt32Array &occupancy,
			const godot::PackedVector3Array &preview_cells,
			const godot::Dictionary &preview_side,
			const godot::Array &neighbour_sides) const;

	/// Full attach-geometry validate without Dictionary marshalling.
	/// elements: [element_id, ox, oy, oz, orientation, footprint_size, face_start, face_count] * E
	/// faces: [lx, ly, lz, local_face, port_index] * F
	/// port_ids / socket_tags indexed by port_index
	/// preview_footprint: [lx, ly, lz] * cells
	/// preview_faces / preview_port_ids / preview_socket_tags: same face layout
	/// element_to_group: [element_id, group_id] * G (optional; empty skips bridge check)
	/// driven_bridges: [base_group_id, head_group_id] * B (optional)
	/// Returns {ok, reason, existing_element_ids, existing_port_ids, new_port_ids}.
	godot::Dictionary validate_attach_preview(
			const godot::PackedInt32Array &occupancy,
			const godot::PackedInt32Array &elements,
			const godot::PackedInt32Array &faces,
			const godot::PackedStringArray &port_ids,
			const godot::PackedStringArray &socket_tags,
			const godot::Vector3i &preview_origin,
			int preview_orientation,
			int preview_footprint_size,
			const godot::PackedInt32Array &preview_footprint,
			const godot::PackedInt32Array &preview_faces,
			const godot::PackedStringArray &preview_port_ids,
			const godot::PackedStringArray &preview_socket_tags,
			const godot::PackedInt32Array &element_to_group,
			const godot::PackedInt32Array &driven_bridges) const;

	/// Phase 4: body-group compile from packed joint/element tables.
	/// joints: PackedInt32Array flat [kind, a_id, b_id, joint_id] * N
	/// element_flags: PackedInt32Array parallel to element_ids (bit0=suspension, bit1=wheel)
	godot::Dictionary compile_body_groups(
			const godot::PackedInt32Array &element_ids,
			const godot::PackedInt32Array &element_flags,
			const godot::PackedInt32Array &joints) const;

	/// Wall time of the last instrumented kernel op (scan / validate), microseconds.
	int64_t get_last_kernel_us() const;
	godot::String get_last_kernel_op() const;

protected:
	static void _bind_methods();

private:
	void _note_kernel_us(const char *op, int64_t us) const;
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
	mutable int64_t _last_kernel_us = 0;
	mutable godot::String _last_kernel_op;

	static godot::String normalize_tag(const godot::String &tag);
	static std::string pair_key(const godot::String &a, const godot::String &b);
	bool socket_tags_compatible(const godot::String &left, const godot::String &right) const;

	static SideSpec parse_side(const godot::Dictionary &side);
	static SideSpec side_from_packed(
			const godot::Vector3i &origin,
			int orientation_index,
			int footprint_size,
			const godot::PackedInt32Array &faces,
			int face_start,
			int face_count,
			const godot::PackedStringArray &port_ids,
			const godot::PackedStringArray &socket_tags);
	static uint64_t world_face_key(const godot::Vector3i &cell, const godot::Vector3i &direction);
	static void build_world_face_lookup(const SideSpec &side, std::unordered_map<uint64_t, WorldFace> &out);
	godot::Dictionary find_canonical_pair_scan(const SideSpec &left, const SideSpec &right) const;
	bool find_canonical_ports(
			const SideSpec &left,
			const SideSpec &right,
			godot::String &out_left_port,
			godot::String &out_right_port) const;

	static bool occupancy_has(const godot::PackedInt32Array &occupancy, const godot::Vector3i &cell, int *element_id = nullptr);
	static void pack_cell_key(int32_t x, int32_t y, int32_t z, int32_t *out);
};
