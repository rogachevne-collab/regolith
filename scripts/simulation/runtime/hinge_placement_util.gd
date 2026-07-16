class_name HingePlacementUtil
extends RefCounted


static func is_hinge_archetype(archetype: ElementArchetype) -> bool:
	return (
		archetype != null
		and archetype.hinge_definition != null
	)


static func top_origin_cell(
	base_origin_cell: Vector3i,
	orientation_index: int,
	definition: HingeDefinition
) -> Vector3i:
	var offset := OrientationUtil.rotate_cell(
		definition.top_axis_offset_cell(),
		orientation_index
	)
	return base_origin_cell + offset


## Bend axis in assembly-local space (unit vector, right-hand positive angle).
static func bend_axis_assembly_local(
	base_element: SimulationElement,
	definition: HingeDefinition
) -> Vector3:
	var axis_cell: Vector3i = OrientationUtil.rotate_direction(
		OrientationUtil.face_to_vector(definition.bend_axis_face),
		base_element.orientation_index
	)
	return Vector3(axis_cell).normalized()


## Bend pivot in assembly-local space: the hinge_top cell center, so the top
## hub rotates in place and only the attached branch swings around the axis.
static func pivot_assembly_local(
	base_element: SimulationElement,
	definition: HingeDefinition
) -> Vector3:
	var top_cell := top_origin_cell(
		base_element.origin_cell,
		base_element.orientation_index,
		definition
	)
	return GridMetric.cell_center_meters(top_cell)


static func validate_hinge_archetype(
	base_archetype: ElementArchetype,
	top_archetype: ElementArchetype,
	registry: ArchetypeRegistry
) -> Array[String]:
	if base_archetype == null or base_archetype.hinge_definition == null:
		return ["missing hinge definition"]
	if top_archetype == null:
		top_archetype = registry.get_archetype(
			base_archetype.hinge_definition.top_archetype_id
		)
	return base_archetype.hinge_definition.validate(
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
		command.archetype.hinge_definition
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


static func find_hinge_joint_for_element(
	world: SimulationWorld,
	element_id: int
) -> SimulationJoint:
	if world == null or element_id <= 0:
		return null
	for joint: SimulationJoint in world.list_joints():
		if joint.kind != SimulationJoint.Kind.HINGE:
			continue
		if joint.element_a_id == element_id or joint.element_b_id == element_id:
			return joint
	return null


static func enrich_interaction_metadata(
	world: SimulationWorld,
	element_id: int,
	metadata: Dictionary
) -> void:
	var joint := find_hinge_joint_for_element(world, element_id)
	if joint == null or joint.motor == null:
		return
	var motor := joint.motor
	metadata["hinge_joint_id"] = joint.joint_id
	metadata["hinge_base_element_id"] = joint.element_a_id
	metadata["hinge_top_element_id"] = joint.element_b_id
	metadata["hinge_observed_angle_rad"] = motor.observed_position_m
	metadata["hinge_observed_velocity_rad_s"] = motor.observed_velocity_mps
	metadata["hinge_target_velocity_rad_s"] = motor.clamp_target_velocity()
	metadata["hinge_forward_velocity_rad_s"] = motor.extend_velocity_mps
	metadata["hinge_reverse_velocity_rad_s"] = motor.retract_velocity_mps
	metadata["hinge_torque_limit_nm"] = motor.force_limit_n
	metadata["hinge_lower_limit_rad"] = motor.lower_limit_m
	metadata["hinge_upper_limit_rad"] = motor.upper_limit_m
	metadata["hinge_powered"] = PistonProjectionUtil.is_piston_powered(
		world,
		joint.element_a_id
	)
	metadata["hinge_motor_enabled"] = motor.enabled
	var base_element := world.get_element(joint.element_a_id)
	if base_element != null:
		var archetype := base_element.get_archetype()
		if archetype != null and archetype.hinge_definition != null:
			var definition := archetype.hinge_definition
			metadata["hinge_max_velocity_rad_s"] = definition.max_velocity_rad_s
			metadata["hinge_max_torque_limit_nm"] = definition.max_torque_limit_nm
			metadata["hinge_authored_lower_limit_rad"] = definition.min_angle_rad
			metadata["hinge_authored_upper_limit_rad"] = definition.max_angle_rad
	var actuator_status := ActuatorSimulationService.status_name_for_motor(motor)
	metadata["actuator_status"] = actuator_status
	if StringName(metadata.get("status_reason", &"ok")) in [&"ok", &"standby"]:
		metadata["status_reason"] = actuator_status


static func hinge_joint_for_elements(
	joints: Array[SimulationJoint],
	base_element_id: int,
	top_element_id: int
) -> SimulationJoint:
	for joint: SimulationJoint in joints:
		if joint.kind != SimulationJoint.Kind.HINGE:
			continue
		if (
			joint.element_a_id == base_element_id
			and joint.element_b_id == top_element_id
		):
			return joint
	return null
