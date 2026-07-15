class_name AssemblyLocomotionController
extends RefCounted

var drive_command: float = 0.0
var brake_command: float = 0.0
var steering_command: float = 0.0


func set_drive_command(throttle: float) -> void:
	drive_command = clampf(throttle, -1.0, 1.0)


func set_brake_command(brake: float) -> void:
	brake_command = clampf(brake, 0.0, 1.0)


func set_steering_command(steering: float) -> void:
	steering_command = clampf(steering, -1.0, 1.0)


func has_active_input() -> bool:
	return (
		absf(drive_command) > 0.001
		or brake_command > 0.001
		or absf(steering_command) > 0.001
	)


func duplicate_state() -> AssemblyLocomotionController:
	var copy := AssemblyLocomotionController.new()
	copy.drive_command = drive_command
	copy.brake_command = brake_command
	copy.steering_command = steering_command
	return copy
