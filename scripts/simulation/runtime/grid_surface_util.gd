class_name GridSurfaceUtil
extends RefCounted

const STRUCTURAL_ID_PREFIX := "structural_"

static var _descriptor_cache: Dictionary = {}
static var _world_face_lookup_cache: Dictionary = {}


class SurfaceFaceDescriptor:
	var local_cell: Vector3i = Vector3i.ZERO
	var local_face: OrientationUtil.Face = OrientationUtil.Face.POS_X
	var structural_id: String = ""
	var socket_tag: String = ""
	## The connector this face came from; carries the precise anchor point.
	var connector: ConnectorDefinition = null


static func is_structural_surface_id(port_id: String) -> bool:
	return port_id.begins_with(STRUCTURAL_ID_PREFIX)


static func structural_id_for(
	local_cell: Vector3i,
	local_face: OrientationUtil.Face
) -> String:
	return FootprintUtil.structural_id_for(local_cell, local_face)


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
	var allowed_faces: Dictionary = {}
	for connector: ConnectorDefinition in archetype.effective_connectors():
		if connector == null or not connector.is_grid:
			continue
		if not FootprintUtil.is_external_face(
			archetype.footprint_cells,
			connector.grid_cell,
			connector.grid_face
		):
			continue
		allowed_faces[_face_key(connector.grid_cell, connector.grid_face)] = (
			connector
		)
	var descriptors: Array[SurfaceFaceDescriptor] = []
	for face_key: Variant in _sorted_face_keys(allowed_faces):
		var connector: ConnectorDefinition = allowed_faces[face_key]
		var descriptor := SurfaceFaceDescriptor.new()
		descriptor.local_cell = connector.grid_cell
		descriptor.local_face = connector.grid_face
		descriptor.socket_tag = connector.tag
		descriptor.structural_id = connector.id
		descriptor.connector = connector
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
	var kernel := ConstructionPreviewKernelAccess.get_kernel()
	if kernel != null:
		var native: Dictionary = kernel.call(
			"find_rigid_connection",
			ConstructionPreviewKernelAccess.side_spec_from_archetype(
				left_archetype,
				left_origin,
				left_orientation
			),
			ConstructionPreviewKernelAccess.side_spec_from_archetype(
				right_archetype,
				right_origin,
				right_orientation
			)
		)
		if native.is_empty():
			return {}
		return {
			"left_port_id": str(native.get("left_port_id", "")),
			"right_port_id": str(native.get("right_port_id", "")),
		}
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


## Full wipe (tests / archetype reload). Prefer clear_world_face_lookup_cache on
## topology edits — archetype face tables are immutable.
static func clear_descriptor_cache() -> void:
	_descriptor_cache.clear()
	_world_face_lookup_cache.clear()


## Placement-probe lookups keyed by origin grow with aim/place; archetype
## descriptor tables do not and must not be flushed on every topology bump.
static func clear_world_face_lookup_cache() -> void:
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
	return ConnectorRuleTable.default_table().compatible(left_tag, right_tag)


static func _face_key(
	local_cell: Vector3i,
	local_face: OrientationUtil.Face
) -> String:
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


static func _face_from_suffix(suffix: String) -> int:
	var index := FootprintUtil.FACE_SUFFIXES.find(suffix)
	if index < 0:
		return -1
	return index
