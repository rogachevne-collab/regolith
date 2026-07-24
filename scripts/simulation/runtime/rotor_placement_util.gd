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
	var joint := world.driven_joint_for_element(element_id)
	if joint == null or joint.kind != SimulationJoint.Kind.ROTOR:
		return null
	return joint


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
