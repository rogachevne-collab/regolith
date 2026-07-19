class_name WeldElementCommand
extends StructuralCommand

var element_id: int = 0
var expected_state_revision: int = -1
## Which store pays for / receives materials. No default: an
## unset owner used to silently mean the one global "player" store.
var store_id: String = ""
var max_material_amount: float = 1.0


func kind() -> StringName:
	return &"weld_element"


func execution_copy() -> StructuralCommand:
	var copy := WeldElementCommand.new()
	copy.element_id = element_id
	copy.expected_state_revision = expected_state_revision
	copy.store_id = store_id
	copy.max_material_amount = max_material_amount
	return copy
