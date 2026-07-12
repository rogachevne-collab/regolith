class_name RepairElementCommand
extends StructuralCommand

var element_id: int = 0
var expected_state_revision: int = -1
var store_id: String = "player"
var max_material_amount: float = 1.0


func kind() -> StringName:
	return &"repair_element"


func execution_copy() -> StructuralCommand:
	var copy := RepairElementCommand.new()
	copy.element_id = element_id
	copy.expected_state_revision = expected_state_revision
	copy.store_id = store_id
	copy.max_material_amount = max_material_amount
	return copy
