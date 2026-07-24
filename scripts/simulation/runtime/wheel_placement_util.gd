class_name WheelPlacementUtil
extends RefCounted


static func is_wheel_archetype(archetype: ElementArchetype) -> bool:
	return archetype != null and archetype.is_wheel()


static func is_suspension_archetype(archetype: ElementArchetype) -> bool:
	return archetype != null and archetype.is_suspension()


static func validate_wheel_placement(
	world: SimulationWorld,
	command: PlaceElementCommand,
	preview: SimulationElement
) -> Variant:
	if (
		world == null
		or command == null
		or preview == null
		or not is_wheel_archetype(command.archetype)
	):
		return null
	if command.assembly_id == 0:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION,
			{"detail": &"wheel_socket_required"}
		)
	var assembly := world.get_assembly_raw(command.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var diagnosis := _diagnose_socket_placement(world, assembly, preview)
	if diagnosis.is_empty():
		return null
	return StructuralCommandResult.failed(
		StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION,
		{"detail": diagnosis}
	)


static func wheel_attached_to_suspension(
	world: SimulationWorld,
	assembly_id: int,
	suspension_element_id: int
) -> bool:
	return _wheel_on_suspension(world, assembly_id, suspension_element_id) > 0


static func seat_offset_local(element: SimulationElement) -> Vector3:
	return _seat_offset_local(element)


static func _diagnose_socket_placement(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	preview: SimulationElement
) -> StringName:
	var occupancy := world._assembly_occupancy_index(assembly)
	var preview_cells := preview.occupied_cells()
	var neighbour_ids := world._neighbour_element_ids(preview_cells, occupancy)
	var nearby_suspensions: Array[int] = []
	var socket_match: Dictionary = {}
	for existing_id: int in neighbour_ids:
		var existing := world.get_element(existing_id)
		if existing == null or not is_suspension_archetype(existing.get_archetype()):
			continue
		nearby_suspensions.append(existing_id)
		var connection := RuntimeConnectivity.find_rigid_connection(
			existing,
			preview
		)
		if connection.is_empty():
			continue
		socket_match = {
			"suspension_element_id": existing_id,
			"connection": connection,
		}
		break
	if nearby_suspensions.is_empty():
		return &"wheel_socket_required"
	if socket_match.is_empty():
		return &"wrong_orientation"
	var suspension_id := int(socket_match["suspension_element_id"])
	if wheel_attached_to_suspension(
		world,
		assembly.assembly_id,
		suspension_id
	):
		return &"socket_occupied"
	return &""


static func _wheel_on_suspension(
	world: SimulationWorld,
	assembly_id: int,
	suspension_element_id: int
) -> int:
	for joint_variant: Variant in world.iter_joints_for_assembly(assembly_id):
		var joint := joint_variant as SimulationJoint
		if joint == null or joint.kind != SimulationJoint.Kind.RIGID:
			continue
		var other_id := 0
		if joint.element_a_id == suspension_element_id:
			other_id = joint.element_b_id
		elif joint.element_b_id == suspension_element_id:
			other_id = joint.element_a_id
		else:
			continue
		var other := world.get_element(other_id)
		if other != null and is_wheel_archetype(other.get_archetype()):
			return other_id
	return 0


static func _seat_offset_local(element: SimulationElement) -> Vector3:
	var archetype := element.get_archetype()
	var pivot := GridPoseUtil.oriented_footprint_pivot(
		archetype,
		element.origin_cell,
		element.orientation_index
	)
	var local := GridPoseUtil.element_local_transform(
		element.origin_cell,
		element.orientation_index,
		element.pose_offset
	)
	return pivot + local.basis.y * GridMetric.HALF_CELL_SIZE_M * 0.5
