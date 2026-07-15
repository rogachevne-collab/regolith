class_name ConfigureSuspensionCommand
extends RefCounted

var suspension_element_id: int = 0
var travel_m: float = -1.0
var spring_stiffness_n_per_m: float = -1.0
var spring_damping_n_s_per_m: float = -1.0


func kind() -> StringName:
	return &"configure_suspension"
