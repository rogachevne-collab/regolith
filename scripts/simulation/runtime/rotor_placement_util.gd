class_name RotorPlacementUtil
extends RefCounted


static func is_rotor_archetype(archetype: ElementArchetype) -> bool:
	return (
		archetype != null
		and archetype.rotor_definition != null
	)


static func top_origin_cell(
	base_origin_cell: Vector3i,
	orientation_index: int,
	definition: RotorDefinition
) -> Vector3i:
	var offset := OrientationUtil.rotate_cell(
		definition.top_axis_offset_cell(),
		orientation_index
	)
	return base_origin_cell + offset


static func validate_rotor_archetype(
	base_archetype: ElementArchetype,
	top_archetype: ElementArchetype,
	registry: ArchetypeRegistry
) -> Array[String]:
	if base_archetype == null or base_archetype.rotor_definition == null:
		return ["missing rotor definition"]
	if top_archetype == null:
		top_archetype = registry.get_archetype(
			base_archetype.rotor_definition.top_archetype_id
		)
	return base_archetype.rotor_definition.validate(
		base_archetype,
		top_archetype
	)


static func preview_elements(
	command: PlaceElementCommand,
	top_archetype: ElementArchetype,
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
	var top_origin := top_origin_cell(
		command.origin_cell,
		command.orientation_index,
		command.archetype.rotor_definition
	)
	var top_preview := SimulationElement.frame(
		-2,
		command.assembly_id,
		top_archetype,
		top_origin,
		command.orientation_index,
		{}
	)
	return {
		"base": base_preview,
		"head": top_preview,
	}


static func find_rotor_joint_for_element(
	world: SimulationWorld,
	element_id: int
) -> SimulationJoint:
	if world == null or element_id <= 0:
		return null
	for joint: SimulationJoint in world.list_joints():
		if joint.kind != SimulationJoint.Kind.ROTOR:
			continue
		if joint.element_a_id == element_id or joint.element_b_id == element_id:
			return joint
	return null


static func enrich_interaction_metadata(
	world: SimulationWorld,
	element_id: int,
	metadata: Dictionary
) -> void:
	var joint := find_rotor_joint_for_element(world, element_id)
	if joint == null or joint.motor == null:
		return
	var motor := joint.motor
	metadata["rotor_joint_id"] = joint.joint_id
	metadata["rotor_base_element_id"] = joint.element_a_id
	metadata["rotor_top_element_id"] = joint.element_b_id
	metadata["rotor_observed_angle_rad"] = motor.observed_position_m
	metadata["rotor_observed_velocity_rad_s"] = motor.observed_velocity_mps
	metadata["rotor_target_velocity_rad_s"] = motor.clamp_target_velocity()
	metadata["rotor_forward_velocity_rad_s"] = motor.extend_velocity_mps
	metadata["rotor_reverse_velocity_rad_s"] = motor.retract_velocity_mps
	metadata["rotor_torque_limit_nm"] = motor.force_limit_n
	metadata["rotor_powered"] = PistonProjectionUtil.is_piston_powered(
		world,
		joint.element_a_id
	)
	metadata["rotor_motor_enabled"] = motor.enabled
	var base_element := world.get_element(joint.element_a_id)
	if base_element != null:
		var archetype := base_element.get_archetype()
		if archetype != null and archetype.rotor_definition != null:
			var definition := archetype.rotor_definition
			metadata["rotor_max_velocity_rad_s"] = definition.max_velocity_rad_s
			metadata["rotor_max_torque_limit_nm"] = definition.max_torque_limit_nm
	var actuator_status := ActuatorSimulationService.status_name_for_motor(motor)
	metadata["actuator_status"] = actuator_status
	if StringName(metadata.get("status_reason", &"ok")) in [&"ok", &"standby"]:
		metadata["status_reason"] = actuator_status


static func rotor_joint_for_elements(
	joints: Array[SimulationJoint],
	base_element_id: int,
	top_element_id: int
) -> SimulationJoint:
	for joint: SimulationJoint in joints:
		if joint.kind != SimulationJoint.Kind.ROTOR:
			continue
		if (
			joint.element_a_id == base_element_id
			and joint.element_b_id == top_element_id
		):
			return joint
	return null
