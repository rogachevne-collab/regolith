class_name SetMachineEnabledCommand
extends RefCounted

var element_id: int = 0
var enabled: bool = true


func kind() -> StringName:
	return &"set_machine_enabled"
