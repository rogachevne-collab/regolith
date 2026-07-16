class_name ConfigureActuatorCommand
extends RefCounted

var joint_id: int = 0
var extend_velocity_mps: float = -1.0
var retract_velocity_mps: float = -1.0
var force_limit_n: float = -1.0
var lower_limit_m: float = -1.0
var upper_limit_m: float = -1.0
## Angular limits may legitimately be negative (hinge min angle), so the
## piston "-1 means unchanged" sentinel is unusable there: senders set these
## flags explicitly. Piston keeps reading the sentinel fields above.
var lower_limit_set: bool = false
var upper_limit_set: bool = false


func kind() -> StringName:
	return &"configure_actuator"
