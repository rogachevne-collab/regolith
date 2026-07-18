class_name PistonPlacementUtil
extends RefCounted


static func is_piston_archetype(archetype: ElementArchetype) -> bool:
	return (
		archetype != null
		and archetype.piston_definition != null
	)


static func head_origin_cell(
	base_origin_cell: Vector3i,
	orientation_index: int,
	definition: PistonDefinition
) -> Vector3i:
	var offset := OrientationUtil.rotate_cell(
		definition.head_axis_offset_cell(),
		orientation_index
	)
	return base_origin_cell + offset


static func validate_piston_archetype(
	base_archetype: ElementArchetype,
	head_archetype: ElementArchetype,
	registry: ArchetypeRegistry
) -> Array[String]:
	if base_archetype == null or base_archetype.piston_definition == null:
		return ["missing piston definition"]
	if head_archetype == null:
		head_archetype = registry.get_archetype(
			base_archetype.piston_definition.head_archetype_id
		)
	return base_archetype.piston_definition.validate(
		base_archetype,
		head_archetype
	)


static func preview_elements(
	command: PlaceElementCommand,
	head_archetype: ElementArchetype,
	placement_resource_id: String,
	placement_amount: float
) -> Dictionary:
	var base_preview := SimulationElement.frame(
		-1,
		command.assembly_id,
		command.archetype,
		command.origin_cell,
		command.orientation_index,
		{placement_resource_id: placement_amount}
	)
	var head_origin := head_origin_cell(
		command.origin_cell,
		command.orientation_index,
		command.archetype.piston_definition
	)
	var head_preview := SimulationElement.frame(
		-2,
		command.assembly_id,
		head_archetype,
		head_origin,
		command.orientation_index,
		{}
	)
	return {
		"base": base_preview,
		"head": head_preview,
	}


static func collect_rigid_connections(
	world: SimulationWorld,
	assembly_id: int,
	preview: SimulationElement,
	exclude_element_ids: Array[int] = []
) -> Array[Dictionary]:
	var exclude: Dictionary = {}
	for element_id: int in exclude_element_ids:
		exclude[element_id] = true
	var connections: Array[Dictionary] = []
	if assembly_id == 0:
		return connections
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return connections
	var occupancy := world._assembly_occupancy_index(assembly)
	var preview_cells := preview.occupied_cells()
	var neighbour_ids := world._neighbour_element_ids(preview_cells, occupancy)
	for existing_id: int in neighbour_ids:
		if exclude.has(existing_id):
			continue
		var existing := world.get_element(existing_id)
		var connection := RuntimeConnectivity.find_rigid_connection(
			existing,
			preview
		)
		if connection.is_empty():
			continue
		connections.append({
			"existing_element_id": existing_id,
			"existing_port_id": connection["left_port_id"],
			"new_port_id": connection["right_port_id"],
		})
	return connections


static func find_piston_joint_for_element(
	world: SimulationWorld,
	element_id: int
) -> SimulationJoint:
	if world == null or element_id <= 0:
		return null
	for joint: SimulationJoint in world.list_joints():
		if joint.kind != SimulationJoint.Kind.PISTON:
			continue
		if joint.element_a_id == element_id or joint.element_b_id == element_id:
			return joint
	return null


static func enrich_interaction_metadata(
	world: SimulationWorld,
	element_id: int,
	metadata: Dictionary
) -> void:
	var joint := find_piston_joint_for_element(world, element_id)
	if joint == null or joint.motor == null:
		return
	var motor := joint.motor
	metadata["piston_joint_id"] = joint.joint_id
	metadata["piston_base_element_id"] = joint.element_a_id
	metadata["piston_head_element_id"] = joint.element_b_id
	metadata["piston_observed_position_m"] = motor.observed_position_m
	metadata["piston_target_position_m"] = _display_target_position_m(motor)
	metadata["piston_lower_limit_m"] = motor.lower_limit_m
	metadata["piston_upper_limit_m"] = motor.upper_limit_m
	metadata["piston_force_limit_n"] = motor.force_limit_n
	metadata["piston_speed_limit_mps"] = motor.speed_limit_mps
	metadata["piston_extend_velocity_mps"] = motor.extend_velocity_mps
	metadata["piston_retract_velocity_mps"] = motor.retract_velocity_mps
	metadata["piston_target_velocity_mps"] = motor.clamp_target_velocity()
	metadata["piston_powered"] = PistonProjectionUtil.is_piston_powered(
		world,
		joint.element_a_id
	)
	metadata["piston_motor_enabled"] = motor.enabled
	var base_element := world.get_element(joint.element_a_id)
	if base_element != null:
		var archetype := base_element.get_archetype()
		if archetype != null and archetype.piston_definition != null:
			var definition := archetype.piston_definition
			metadata["piston_authored_lower_limit_m"] = definition.lower_limit_m
			metadata["piston_authored_upper_limit_m"] = definition.upper_limit_m
			metadata["piston_max_velocity_mps"] = definition.max_velocity_mps
			metadata["piston_max_force_limit_n"] = definition.max_force_limit_n
	var actuator_status := ActuatorSimulationService.status_name_for_motor(motor)
	metadata["actuator_status"] = actuator_status
	if StringName(metadata.get("status_reason", &"ok")) in [&"ok", &"standby"]:
		metadata["status_reason"] = actuator_status


static func _display_target_position_m(motor: SimulationMotorState) -> float:
	match motor.control_mode:
		SimulationMotorState.ControlMode.POSITION:
			return motor.clamp_target_position()
		SimulationMotorState.ControlMode.VELOCITY:
			if motor.clamp_target_velocity() >= 0.0:
				return motor.upper_limit_m
			return motor.lower_limit_m
	return motor.observed_position_m


static func piston_joint_for_elements(
	joints: Array[SimulationJoint],
	base_element_id: int,
	head_element_id: int
) -> SimulationJoint:
	for joint: SimulationJoint in joints:
		if joint.kind != SimulationJoint.Kind.PISTON:
			continue
		if (
			joint.element_a_id == base_element_id
			and joint.element_b_id == head_element_id
		):
			return joint
	return null


static func piston_joint_ids_in_assembly(
	world: SimulationWorld,
	assembly_id: int
) -> Array[int]:
	var ids: Array[int] = []
	if world == null or assembly_id <= 0:
		return ids
	for joint: SimulationJoint in world.list_joints():
		if (
			joint.assembly_id == assembly_id
			and joint.kind == SimulationJoint.Kind.PISTON
		):
			ids.append(joint.joint_id)
	ids.sort()
	return ids
