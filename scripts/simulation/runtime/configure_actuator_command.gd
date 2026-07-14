class_name ConfigureActuatorCommand
extends RefCounted

var joint_id: int = 0
var extend_velocity_mps: float = -1.0
var retract_velocity_mps: float = -1.0
var force_limit_n: float = -1.0
var lower_limit_m: float = -1.0
var upper_limit_m: float = -1.0


func kind() -> StringName:
	return &"configure_actuator"
