class_name StructuralCommand
extends RefCounted

var command_id: int = 0


func kind() -> StringName:
	return &"unknown"


func execution_copy() -> StructuralCommand:
	return null
