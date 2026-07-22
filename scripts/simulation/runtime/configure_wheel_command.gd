class_name ConfigureWheelCommand
extends RefCounted

var wheel_element_id: int = 0
var steerable_set: bool = false
var steerable: bool = false
## Направление привода: set-флаг, чтобы менять его не трогая прочие поля.
var invert_drive_set: bool = false
var invert_drive: bool = false
var drive_torque_scale: float = -1.0
var brake_torque_n_m: float = -1.0


func kind() -> StringName:
	return &"configure_wheel"
