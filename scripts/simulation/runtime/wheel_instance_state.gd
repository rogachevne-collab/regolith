class_name WheelInstanceState
extends RefCounted

var steerable: bool = false
var drive_torque_scale: float = 1.0
var brake_torque_n_m: float = -1.0


func duplicate_state() -> WheelInstanceState:
	var copy := WheelInstanceState.new()
	copy.steerable = steerable
	copy.drive_torque_scale = drive_torque_scale
	copy.brake_torque_n_m = brake_torque_n_m
	return copy


func to_dict() -> Dictionary:
	return {
		"steerable": steerable,
		"drive_torque_scale": drive_torque_scale,
		"brake_torque_n_m": brake_torque_n_m,
	}


static func from_dict(data: Dictionary) -> WheelInstanceState:
	var state := WheelInstanceState.new()
	state.steerable = bool(data.get("steerable", false))
	state.drive_torque_scale = float(data.get("drive_torque_scale", 1.0))
	state.brake_torque_n_m = float(data.get("brake_torque_n_m", -1.0))
	return state
