class_name SetActuatorTargetCommand
extends RefCounted

var joint_id: int = 0
var mode: SimulationMotorState.ControlMode = SimulationMotorState.ControlMode.STOP
var target_position_m: float = 0.0
var target_velocity_mps: float = 0.0
var speed_limit_mps: float = -1.0
var enabled: bool = true


func kind() -> StringName:
	return &"set_actuator_target"
