class_name DismantleElementCommand
extends StructuralCommand

var element_id: int = 0
var expected_assembly_revision: int = -1
## Which store pays for / receives materials. No default: an
## unset owner used to silently mean the one global "player" store.
var store_id: String = ""


func kind() -> StringName:
	return &"dismantle_element"


func execution_copy() -> StructuralCommand:
	var copy := DismantleElementCommand.new()
	copy.element_id = element_id
	copy.expected_assembly_revision = expected_assembly_revision
	copy.store_id = store_id
	return copy
