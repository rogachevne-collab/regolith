class_name GridSurfaceUtil
extends RefCounted

const STRUCTURAL_ID_PREFIX := "structural_"

const _FACE_SUFFIXES: PackedStringArray = [
	"px",
	"nx",
	"py",
	"ny",
	"pz",
	"nz",
]

const _FACE_ORDER: Array[OrientationUtil.Face] = [
	OrientationUtil.Face.POS_X,
	OrientationUtil.Face.NEG_X,
	OrientationUtil.Face.POS_Y,
	OrientationUtil.Face.NEG_Y,
	OrientationUtil.Face.POS_Z,
	OrientationUtil.Face.NEG_Z,
]

static var _descriptor_cache: Dictionary = {}
static var _world_face_lookup_cache: Dictionary = {}


class SurfaceFaceDescriptor:
	var local_cell: Vector3i = Vector3i.ZERO
	var local_face: OrientationUtil.Face = OrientationUtil.Face.POS_X
	var structural_id: String = ""
	var socket_tag: String = ""


static func is_structural_surface_id(port_id: String) -> bool:
	return port_id.begins_with(STRUCTURAL_ID_PREFIX)


static func structural_id_for(
	local_cell: Vector3i,
	local_face: OrientationUtil.Face
) -> String:
	return "%s%d_%d_%d_%s" % [
		STRUCTURAL_ID_PREFIX,
		local_cell.x,
		local_cell.y,
		local_cell.z,
		_face_suffix(local_face),
	]


static func parse_structural_id(port_id: String) -> Dictionary:
	if not is_structural_surface_id(port_id):
		return {}
	var body := port_id.substr(STRUCTURAL_ID_PREFIX.length())
	var parts: PackedStringArray = body.split("_")
	if parts.size() != 4:
		return {}
	var face := _face_from_suffix(parts[3])
	if face < 0:
		return {}
	return {
		"local_cell": Vector3i(
			int(parts[0]),
			int(parts[1]),
			int(parts[2])
		),
		"local_face": face,
	}


static func get_surface_descriptors(
	archetype: ElementArchetype,
	orientation_index: int
) -> Array[SurfaceFaceDescriptor]:
	if archetype == null:
		return []
	var cache_key := _descriptor_cache_key(archetype, orientation_index)
	if _descriptor_cache.has(cache_key):
		return _descriptor_cache[cache_key]
	var policy := archetype.resolved_structural_surface_policy()
	if policy == ElementArchetype.StructuralSurfacePolicy.NONE:
		_descriptor_cache[cache_key] = []
		return []
	var allowed_faces: Dictionary = {}
	match policy:
		ElementArchetype.StructuralSurfacePolicy.FULL_SURFACE:
			for face_data: Dictionary in _external_faces(archetype.footprint_cells):
				allowed_faces[_face_key(face_data)] = face_data
		ElementArchetype.StructuralSurfacePolicy.MOUNT_PADS:
			for pad: StructuralMountPad in archetype.effective_mount_pads():
				if pad == null:
					continue
				var face_data := {
					"local_cell": pad.local_cell,
					"local_face": pad.local_face,
					"socket_tag": pad.socket_tag,
				}
				if _is_external_face(archetype.footprint_cells, face_data):
					allowed_faces[_face_key(face_data)] = face_data
	var descriptors: Array[SurfaceFaceDescriptor] = []
	for face_key: Variant in _sorted_face_keys(allowed_faces):
		var face_data: Dictionary = allowed_faces[face_key]
		var descriptor := SurfaceFaceDescriptor.new()
		descriptor.local_cell = face_data["local_cell"]
		descriptor.local_face = face_data["local_face"]
		descriptor.socket_tag = str(face_data.get("socket_tag", ""))
		descriptor.structural_id = structural_id_for(
			descriptor.local_cell,
			descriptor.local_face
		)
		descriptors.append(descriptor)
	_descriptor_cache[cache_key] = descriptors
	return descriptors


## Pick the authored structural face on `element` closest to a world hit.
## Prefers faces whose outward normal aligns with `world_normal`.
## Returns { "cell": Vector3i, "direction": Vector3i } in assembly grid space.
static func nearest_assembly_face_to_hit(
	element: SimulationElement,
	world_point: Vector3,
	world_normal: Vector3,
	assembly_world_transform: Transform3D
) -> Dictionary:
	if element == null:
		return {}
	var archetype := element.get_archetype()
	if archetype == null:
		return {}
	var local_point := assembly_world_transform.affine_inverse() * world_point
	var local_normal := (
		assembly_world_transform.basis.inverse() * world_normal
	).normalized()
	var best: Dictionary = {}
	var best_score := -INF
	for descriptor: SurfaceFaceDescriptor in get_surface_descriptors(
		archetype,
		element.orientation_index
	):
		var world_face := _world_face(
			element.origin_cell,
			element.orientation_index,
			descriptor
		)
		var cell: Vector3i = world_face["cell"]
		var direction: Vector3i = world_face["direction"]
		var face_center := (
			GridMetric.cell_center_meters(cell)
			+ Vector3(direction) * GridMetric.HALF_CELL_SIZE_M
		)
		var alignment := local_normal.dot(Vector3(direction))
		var distance := local_point.distance_to(face_center)
		# Alignment dominates so a glancing hit on the deck still prefers
		# the pad facing the camera, not a nearer edge face.
		var score := alignment * 10.0 - distance
		if score > best_score:
			best_score = score
			best = {
				"cell": cell,
				"direction": direction,
			}
	return best


static func element_has_structural_surface(
	element: SimulationElement,
	structural_id: String
) -> bool:
	if element == null or structural_id.is_empty():
		return false
	for descriptor: SurfaceFaceDescriptor in get_surface_descriptors(
		element.get_archetype(),
		element.orientation_index
	):
		if descriptor.structural_id == structural_id:
			return true
	return false


static func find_rigid_connection(
	left: SimulationElement,
	right: SimulationElement
) -> Dictionary:
	return find_rigid_connection_specs(
		left.get_archetype(),
		left.origin_cell,
		left.orientation_index,
		right.get_archetype(),
		right.origin_cell,
		right.orientation_index
	)


static func find_rigid_connection_specs(
	left_archetype: ElementArchetype,
	left_origin: Vector3i,
	left_orientation: int,
	right_archetype: ElementArchetype,
	right_origin: Vector3i,
	right_orientation: int
) -> Dictionary:
	var canonical := _find_canonical_pair_specs(
		left_archetype,
		left_origin,
		left_orientation,
		right_archetype,
		right_origin,
		right_orientation
	)
	if canonical.is_empty():
		return {}
	return {
		"left_port_id": canonical["left_port_id"],
		"right_port_id": canonical["right_port_id"],
	}


static func placements_have_rigid_connection(
	left: BlueprintElementPlacement,
	right: BlueprintElementPlacement
) -> bool:
	if left == null or right == null:
		return false
	if left.archetype == null or right.archetype == null:
		return false
	return not find_rigid_connection_specs(
		left.archetype,
		left.origin_cell,
		left.orientation_index,
		right.archetype,
		right.origin_cell,
		right.orientation_index
	).is_empty()


static func validate_rigid_connection(
	left: SimulationElement,
	left_port_id: String,
	right: SimulationElement,
	right_port_id: String
) -> bool:
	return _validate_rigid_connection_specs(
		left.get_archetype(),
		left.origin_cell,
		left.orientation_index,
		left_port_id,
		right.get_archetype(),
		right.origin_cell,
		right.orientation_index,
		right_port_id
	)


static func count_matching_contact_faces(
	left: SimulationElement,
	right: SimulationElement
) -> int:
	return _count_matching_contact_faces_specs(
		left.get_archetype(),
		left.origin_cell,
		left.orientation_index,
		right.get_archetype(),
		right.origin_cell,
		right.orientation_index
	)


static func ground_anchor_structural_id(element: SimulationElement) -> String:
	var archetype := element.get_archetype()
	if archetype == null:
		return ""
	var descriptors := get_surface_descriptors(
		archetype,
		element.orientation_index
	)
	var best_id := ""
	var best_cell := Vector3i(2147483647, 2147483647, 2147483647)
	for descriptor: SurfaceFaceDescriptor in descriptors:
		var world_direction := OrientationUtil.rotate_direction(
			OrientationUtil.face_to_vector(descriptor.local_face),
			element.orientation_index
		)
		if world_direction != Vector3i(0, -1, 0):
			continue
		var world_cell := element.origin_cell + OrientationUtil.rotate_cell(
			descriptor.local_cell,
			element.orientation_index
		)
		if world_cell < best_cell or (world_cell == best_cell and (
			best_id.is_empty() or descriptor.structural_id < best_id
		)):
			best_cell = world_cell
			best_id = descriptor.structural_id
	return best_id


static func clear_descriptor_cache() -> void:
	_descriptor_cache.clear()
	_world_face_lookup_cache.clear()


static func _find_canonical_pair_specs(
	left_archetype: ElementArchetype,
	left_origin: Vector3i,
	left_orientation: int,
	right_archetype: ElementArchetype,
	right_origin: Vector3i,
	right_orientation: int
) -> Dictionary:
	# Iterate the smaller footprint; large_frame (125 cells / ~150 faces) as the
	# scan side made every preview_place on a rover-with-L25 several ms.
	if (
		left_archetype != null
		and right_archetype != null
		and left_archetype.footprint_cells.size()
		> right_archetype.footprint_cells.size()
	):
		var swapped := _find_canonical_pair_specs_scan(
			right_archetype,
			right_origin,
			right_orientation,
			left_archetype,
			left_origin,
			left_orientation
		)
		if swapped.is_empty():
			return {}
		return {
			"left_port_id": str(swapped["right_port_id"]),
			"right_port_id": str(swapped["left_port_id"]),
		}
	return _find_canonical_pair_specs_scan(
		left_archetype,
		left_origin,
		left_orientation,
		right_archetype,
		right_origin,
		right_orientation
	)


static func _find_canonical_pair_specs_scan(
	left_archetype: ElementArchetype,
	left_origin: Vector3i,
	left_orientation: int,
	right_archetype: ElementArchetype,
	right_origin: Vector3i,
	right_orientation: int
) -> Dictionary:
	var right_lookup := _world_face_lookup(
		right_archetype,
		right_origin,
		right_orientation
	)
	var matches: Array[Dictionary] = []
	for left_descriptor: SurfaceFaceDescriptor in get_surface_descriptors(
		left_archetype,
		left_orientation
	):
		var left_world := _world_face(
			left_origin,
			left_orientation,
			left_descriptor
		)
		var adjacent_key := _world_face_lookup_key(
			left_world["cell"] + left_world["direction"],
			-left_world["direction"]
		)
		var right_face: Variant = right_lookup.get(adjacent_key)
		if right_face == null:
			continue
		if not _socket_tags_compatible(
			left_descriptor.socket_tag,
			str(right_face.get("socket_tag", ""))
		):
			continue
		matches.append({
			"left_port_id": left_descriptor.structural_id,
			"right_port_id": str(right_face.get("port_id", "")),
		})
	if matches.is_empty():
		return {}
	matches.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			if left["left_port_id"] != right["left_port_id"]:
				return left["left_port_id"] < right["left_port_id"]
			return left["right_port_id"] < right["right_port_id"]
	)
	return matches[0]


static func _validate_rigid_connection_specs(
	left_archetype: ElementArchetype,
	left_origin: Vector3i,
	left_orientation: int,
	left_port_id: String,
	right_archetype: ElementArchetype,
	right_origin: Vector3i,
	right_orientation: int,
	right_port_id: String
) -> bool:
	var canonical := _find_canonical_pair_specs(
		left_archetype,
		left_origin,
		left_orientation,
		right_archetype,
		right_origin,
		right_orientation
	)
	return (
		not canonical.is_empty()
		and canonical["left_port_id"] == left_port_id
		and canonical["right_port_id"] == right_port_id
	)


static func _count_matching_contact_faces_specs(
	left_archetype: ElementArchetype,
	left_origin: Vector3i,
	left_orientation: int,
	right_archetype: ElementArchetype,
	right_origin: Vector3i,
	right_orientation: int
) -> int:
	if (
		left_archetype != null
		and right_archetype != null
		and left_archetype.footprint_cells.size()
		> right_archetype.footprint_cells.size()
	):
		return _count_matching_contact_faces_specs(
			right_archetype,
			right_origin,
			right_orientation,
			left_archetype,
			left_origin,
			left_orientation
		)
	var right_lookup := _world_face_lookup(
		right_archetype,
		right_origin,
		right_orientation
	)
	var count := 0
	for left_descriptor: SurfaceFaceDescriptor in get_surface_descriptors(
		left_archetype,
		left_orientation
	):
		var left_world := _world_face(
			left_origin,
			left_orientation,
			left_descriptor
		)
		var adjacent_key := _world_face_lookup_key(
			left_world["cell"] + left_world["direction"],
			-left_world["direction"]
		)
		if right_lookup.has(adjacent_key):
			var right_face: Dictionary = right_lookup[adjacent_key]
			if _socket_tags_compatible(
				left_descriptor.socket_tag,
				str(right_face.get("socket_tag", ""))
			):
				count += 1
	return count


static func _world_face(
	origin_cell: Vector3i,
	orientation_index: int,
	descriptor: SurfaceFaceDescriptor
) -> Dictionary:
	return {
		"cell": (
			origin_cell
			+ OrientationUtil.rotate_cell(
				descriptor.local_cell,
				orientation_index
			)
		),
		"direction": OrientationUtil.rotate_direction(
			OrientationUtil.face_to_vector(descriptor.local_face),
			orientation_index
		),
	}


static func _external_faces(footprint_cells: Array[Vector3i]) -> Array[Dictionary]:
	var occupied: Dictionary = {}
	for cell: Vector3i in footprint_cells:
		occupied[_cell_key(cell)] = true
	var faces: Array[Dictionary] = []
	for cell: Vector3i in footprint_cells:
		for face: OrientationUtil.Face in _FACE_ORDER:
			var neighbor := cell + OrientationUtil.face_to_vector(face)
			if occupied.has(_cell_key(neighbor)):
				continue
			faces.append({
				"local_cell": cell,
				"local_face": face,
			})
	return faces


static func _is_external_face(
	footprint_cells: Array[Vector3i],
	face_data: Dictionary
) -> bool:
	var occupied: Dictionary = {}
	for cell: Vector3i in footprint_cells:
		occupied[_cell_key(cell)] = true
	var local_cell: Vector3i = face_data["local_cell"]
	var local_face: OrientationUtil.Face = face_data["local_face"]
	if not occupied.has(_cell_key(local_cell)):
		return false
	var neighbor := local_cell + OrientationUtil.face_to_vector(local_face)
	return not occupied.has(_cell_key(neighbor))


static func _descriptor_cache_key(
	archetype: ElementArchetype,
	orientation_index: int
) -> String:
	return "%s|%d" % [archetype.archetype_id, orientation_index]


static func _world_face_lookup_key(cell: Vector3i, direction: Vector3i) -> String:
	return "%d,%d,%d|%d,%d,%d" % [
		cell.x,
		cell.y,
		cell.z,
		direction.x,
		direction.y,
		direction.z,
	]


static func _world_face_lookup(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> Dictionary:
	if archetype == null:
		return {}
	var cache_key := "%s|%d,%d,%d|%d" % [
		archetype.archetype_id,
		origin_cell.x,
		origin_cell.y,
		origin_cell.z,
		orientation_index,
	]
	var cached: Variant = _world_face_lookup_cache.get(cache_key)
	if cached is Dictionary:
		return cached
	var lookup: Dictionary = {}
	for descriptor: SurfaceFaceDescriptor in get_surface_descriptors(
		archetype,
		orientation_index
	):
		var world := _world_face(origin_cell, orientation_index, descriptor)
		lookup[_world_face_lookup_key(world["cell"], world["direction"])] = {
			"port_id": descriptor.structural_id,
			"socket_tag": descriptor.socket_tag,
		}
	_world_face_lookup_cache[cache_key] = lookup
	return lookup


static func _socket_tags_compatible(left_tag: String, right_tag: String) -> bool:
	if left_tag.is_empty() and right_tag.is_empty():
		return true
	if left_tag == "wheel_socket" and right_tag == "wheel_plug":
		return true
	if left_tag == "wheel_plug" and right_tag == "wheel_socket":
		return true
	return false


static func _face_key(face_data: Dictionary) -> String:
	var local_cell: Vector3i = face_data["local_cell"]
	var local_face: OrientationUtil.Face = face_data["local_face"]
	return "%d,%d,%d,%d" % [
		local_cell.x,
		local_cell.y,
		local_cell.z,
		int(local_face),
	]


static func _sorted_face_keys(allowed_faces: Dictionary) -> Array:
	var keys: Array = allowed_faces.keys()
	keys.sort()
	return keys


static func _cell_key(cell: Vector3i) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]


static func _face_suffix(face: OrientationUtil.Face) -> String:
	return _FACE_SUFFIXES[int(face)]


static func _face_from_suffix(suffix: String) -> int:
	var index := _FACE_SUFFIXES.find(suffix)
	if index < 0:
		return -1
	return index
