class_name ConnectNetworkCommand
extends StructuralCommand

var assembly_id: int = 0
var expected_assembly_revision: int = -1
var expected_revision_a: int = -1
var expected_revision_b: int = -1
var element_a_id: int = 0
var port_a_id: String = ""
var element_b_id: int = 0
var port_b_id: String = ""


func kind() -> StringName:
	return &"connect_network"


func execution_copy() -> StructuralCommand:
	var copy := ConnectNetworkCommand.new()
	copy.assembly_id = assembly_id
	copy.expected_assembly_revision = expected_assembly_revision
	copy.expected_revision_a = expected_revision_a
	copy.expected_revision_b = expected_revision_b
	copy.element_a_id = element_a_id
	copy.port_a_id = port_a_id
	copy.element_b_id = element_b_id
	copy.port_b_id = port_b_id
	return copy
