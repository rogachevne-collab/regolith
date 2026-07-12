class_name MergeAssembliesCommand
extends StructuralCommand

var assembly_a_id: int = 0
var assembly_b_id: int = 0
var expected_revision_a: int = -1
var expected_revision_b: int = -1
var element_a_id: int = 0
var port_a_id: String = ""
var element_b_id: int = 0
var port_b_id: String = ""
var b_to_a_grid: GridTransform


func kind() -> StringName:
	return &"merge_assemblies"


func execution_copy() -> StructuralCommand:
	var copy := MergeAssembliesCommand.new()
	copy.assembly_a_id = assembly_a_id
	copy.assembly_b_id = assembly_b_id
	copy.expected_revision_a = expected_revision_a
	copy.expected_revision_b = expected_revision_b
	copy.element_a_id = element_a_id
	copy.port_a_id = port_a_id
	copy.element_b_id = element_b_id
	copy.port_b_id = port_b_id
	copy.b_to_a_grid = (
		b_to_a_grid.duplicate_transform()
		if b_to_a_grid != null
		else null
	)
	return copy
