class_name AssemblyLocomotionController
extends RefCounted

var drive_command: float = 0.0
var brake_command: float = 0.0
var steering_command: float = 0.0
var activated: bool = false
## One-shot chassis lift already applied; skip on re-enter / reload.
var released_from_anchor: bool = false


func activate() -> void:
	activated = true


func deactivate() -> void:
	activated = false
	drive_command = 0.0
	steering_command = 0.0
	brake_command = 1.0


func is_activated() -> bool:
	return activated


func mark_released_from_anchor() -> void:
	released_from_anchor = true


func has_released_from_anchor() -> bool:
	return released_from_anchor


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


func to_dict() -> Dictionary:
	return {
		"activated": activated,
		"released_from_anchor": released_from_anchor,
		"drive_command": drive_command,
		"brake_command": brake_command,
		"steering_command": steering_command,
	}


func apply_dict(data: Dictionary) -> void:
	activated = bool(data.get("activated", false))
	released_from_anchor = bool(data.get("released_from_anchor", false))
	drive_command = float(data.get("drive_command", 0.0))
	brake_command = float(data.get("brake_command", 0.0))
	steering_command = float(data.get("steering_command", 0.0))


func duplicate_state() -> AssemblyLocomotionController:
	var copy := AssemblyLocomotionController.new()
	copy.drive_command = drive_command
	copy.brake_command = brake_command
	copy.steering_command = steering_command
	copy.activated = activated
	copy.released_from_anchor = released_from_anchor
	return copy
