class_name ConfigureWheelCommand
extends RefCounted

var wheel_element_id: int = 0
var steerable_set: bool = false
var steerable: bool = false
var drive_torque_scale: float = -1.0
var brake_torque_n_m: float = -1.0


func kind() -> StringName:
	return &"configure_wheel"
