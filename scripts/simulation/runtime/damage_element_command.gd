class_name DamageElementCommand
extends StructuralCommand

var element_id: int = 0
var expected_state_revision: int = -1
var damage: float = 0.0


func kind() -> StringName:
	return &"damage_element"


func execution_copy() -> StructuralCommand:
	var copy := DamageElementCommand.new()
	copy.element_id = element_id
	copy.expected_state_revision = expected_state_revision
	copy.damage = damage
	return copy
