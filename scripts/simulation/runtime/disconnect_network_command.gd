class_name DisconnectNetworkCommand
extends StructuralCommand

var assembly_id: int = 0
var expected_assembly_revision: int = -1
var link_id: int = 0
var element_a_id: int = 0
var port_a_id: String = ""
var element_b_id: int = 0
var port_b_id: String = ""


func kind() -> StringName:
	return &"disconnect_network"


func execution_copy() -> StructuralCommand:
	var copy := DisconnectNetworkCommand.new()
	copy.assembly_id = assembly_id
	copy.expected_assembly_revision = expected_assembly_revision
	copy.link_id = link_id
	copy.element_a_id = element_a_id
	copy.port_a_id = port_a_id
	copy.element_b_id = element_b_id
	copy.port_b_id = port_b_id
	return copy
