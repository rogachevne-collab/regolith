class_name SimulationMergeGateway
extends RefCounted


static func compute_b_to_a_grid(
	world,
	assembly_a_id: int,
	assembly_b_id: int
) -> GridTransform:
	if world == null:
		return null
	var assembly_a: SimulationAssembly = world.get_assembly_raw(assembly_a_id)
	var assembly_b: SimulationAssembly = world.get_assembly_raw(assembly_b_id)
	if (
		assembly_a == null
		or assembly_b == null
		or assembly_a.tombstoned
		or assembly_b.tombstoned
		or assembly_a == assembly_b
		or assembly_a.motion == null
		or assembly_b.motion == null
		or not assembly_a.motion.is_valid()
		or not assembly_b.motion.is_valid()
	):
		return null
	var alignment: Dictionary = GridAlignment.nearest_alignment(
		assembly_a.motion.transform,
		assembly_b.motion.transform
	)
	if not bool(alignment["aligned"]):
		return null
	return alignment["grid_transform"]


static func merge_command(
	world,
	assembly_a_id: int,
	assembly_b_id: int,
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String
) -> MergeAssembliesCommand:
	if world == null:
		return null
	var assembly_a: SimulationAssembly = world.get_assembly_raw(assembly_a_id)
	var assembly_b: SimulationAssembly = world.get_assembly_raw(assembly_b_id)
	var b_to_a: GridTransform = compute_b_to_a_grid(
		world,
		assembly_a_id,
		assembly_b_id
	)
	if (
		assembly_a == null
		or assembly_b == null
		or b_to_a == null
	):
		return null
	var command := MergeAssembliesCommand.new()
	command.assembly_a_id = assembly_a_id
	command.assembly_b_id = assembly_b_id
	command.expected_revision_a = assembly_a.topology_revision
	command.expected_revision_b = assembly_b.topology_revision
	command.element_a_id = element_a_id
	command.port_a_id = port_a_id
	command.element_b_id = element_b_id
	command.port_b_id = port_b_id
	command.b_to_a_grid = b_to_a
	return command
