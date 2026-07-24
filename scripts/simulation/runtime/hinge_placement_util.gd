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
	return (
		GridPoseUtil.element_pose_delta(
			base_element.origin_cell,
			base_element.orientation_index,
			base_element.pose_offset
		).basis * Vector3(axis_cell)
	).normalized()


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
	return GridPoseUtil.element_pose_delta(
		base_element.origin_cell,
		base_element.orientation_index,
		base_element.pose_offset
	) * GridMetric.cell_center_meters(top_cell)


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
	var joint := world.driven_joint_for_element(element_id)
	if joint == null or joint.kind != SimulationJoint.Kind.HINGE:
		return null
	return joint


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
