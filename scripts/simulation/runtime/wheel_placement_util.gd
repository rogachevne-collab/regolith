class_name WheelPlacementUtil
extends RefCounted


static func is_wheel_archetype(archetype: ElementArchetype) -> bool:
	return archetype != null and archetype.archetype_id == "drive_wheel"


static func is_suspension_archetype(archetype: ElementArchetype) -> bool:
	return archetype != null and archetype.archetype_id == "wheel_suspension"


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


static func enrich_interaction_metadata(
	world: SimulationWorld,
	element_id: int,
	metadata: Dictionary
) -> void:
	if world == null or element_id <= 0:
		return
	var element := world.get_element(element_id)
	if element == null:
		return
	var archetype := element.get_archetype()
	if archetype == null:
		return
	if is_wheel_archetype(archetype):
		_enrich_wheel_metadata(world, element, metadata)
	elif is_suspension_archetype(archetype):
		_enrich_suspension_metadata(world, element, metadata)


static func enrich_control_seat_metadata(
	world: SimulationWorld,
	element: SimulationElement,
	metadata: Dictionary
) -> void:
	if (
		world == null
		or element == null
		or element.get_archetype() == null
		or not element.get_archetype().roles.has("ControlSeat")
		or not element.is_operational()
	):
		return
	metadata["control_seat"] = true
	metadata["seat_offset_local"] = _seat_offset_local(element)
	metadata["locomotive"] = WheelSimulationService.is_locomotive_assembly(
		world,
		element.assembly_id
	)
	metadata["flight"] = ThrusterSimulationService.is_flight_assembly(
		world,
		element.assembly_id
	)
	metadata["mobile"] = ThrusterSimulationService.is_mobile_assembly(
		world,
		element.assembly_id
	)


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
		if existing == null or existing.archetype_id != "wheel_suspension":
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
	for joint: SimulationJoint in world.list_joints():
		if (
			joint.assembly_id != assembly_id
			or joint.kind != SimulationJoint.Kind.RIGID
		):
			continue
		var other_id := 0
		if joint.element_a_id == suspension_element_id:
			other_id = joint.element_b_id
		elif joint.element_b_id == suspension_element_id:
			other_id = joint.element_a_id
		else:
			continue
		var other := world.get_element(other_id)
		if other != null and other.archetype_id == "drive_wheel":
			return other_id
	return 0


static func _enrich_wheel_metadata(
	world: SimulationWorld,
	element: SimulationElement,
	metadata: Dictionary
) -> void:
	var definition := element.get_archetype().wheel_definition
	if definition == null:
		return
	var state := world.ensure_wheel_instance_state(element.element_id)
	metadata["wheel_element_id"] = element.element_id
	metadata["wheel_steerable"] = state.steerable
	metadata["wheel_drive_torque_scale"] = state.drive_torque_scale
	metadata["wheel_brake_torque_n_m"] = (
		state.brake_torque_n_m
		if state.brake_torque_n_m >= 0.0
		else definition.brake_torque_n_m
	)
	metadata["wheel_max_brake_torque_n_m"] = definition.brake_torque_n_m
	metadata["wheel_authored_drive_torque_n_m"] = definition.drive_torque_n_m
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	metadata["wheel_powered"] = runtime.machine_enabled and runtime.powered
	var wheel_runtime := world.get_wheel_runtime(element.element_id)
	metadata["wheel_status"] = StringName(
		wheel_runtime.get("status", runtime.power_reason)
	)
	metadata["wheel_grounded"] = bool(
		wheel_runtime.get("grounded", false)
	)
	metadata["wheel_compression_m"] = float(
		wheel_runtime.get("compression_m", 0.0)
	)
	metadata["wheel_normal_force_n"] = float(
		wheel_runtime.get("normal_force_n", 0.0)
	)
	metadata["wheel_slip_speed_mps"] = float(
		wheel_runtime.get("slip_speed_mps", 0.0)
	)


static func _enrich_suspension_metadata(
	world: SimulationWorld,
	element: SimulationElement,
	metadata: Dictionary
) -> void:
	var definition := element.get_archetype().suspension_definition
	if definition == null:
		return
	var state := world.ensure_suspension_instance_state(element.element_id)
	metadata["suspension_element_id"] = element.element_id
	metadata["suspension_travel_m"] = (
		state.travel_m
		if state.travel_m > 0.0
		else definition.suspension_travel_m
	)
	metadata["suspension_spring_stiffness_n_per_m"] = (
		state.spring_stiffness_n_per_m
		if state.spring_stiffness_n_per_m >= 0.0
		else definition.spring_stiffness_n_per_m
	)
	metadata["suspension_spring_damping_n_s_per_m"] = (
		state.spring_damping_n_s_per_m
		if state.spring_damping_n_s_per_m >= 0.0
		else definition.spring_damping_n_s_per_m
	)
	metadata["suspension_min_travel_m"] = definition.min_travel_m
	metadata["suspension_max_travel_m"] = definition.max_travel_m


static func _seat_offset_local(element: SimulationElement) -> Vector3:
	var archetype := element.get_archetype()
	var pivot := GridPoseUtil.oriented_footprint_pivot(
		archetype,
		element.origin_cell,
		element.orientation_index
	)
	var local := GridPoseUtil.element_local_transform(
		element.origin_cell,
		element.orientation_index
	)
	return pivot + local.basis.y * GridMetric.HALF_CELL_SIZE_M * 0.5
