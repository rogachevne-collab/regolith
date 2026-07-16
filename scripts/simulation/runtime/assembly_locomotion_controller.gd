class_name AssemblyLocomotionController
extends RefCounted

## Near-zero chassis speed required to engage parking brake (m/s, rad/s).
const PARKING_BRAKE_SPEED_EPS := 0.15

var drive_command: float = 0.0
var brake_command: float = 0.0
var steering_command: float = 0.0
var activated: bool = false
## SE-style wheel lock. Default on so undriven floating locos hold.
var parking_brake: bool = true
## One-shot chassis lift already applied; skip on re-enter / reload.
var released_from_anchor: bool = false


func activate() -> void:
	activated = true


func deactivate() -> void:
	activated = false
	clear_driver_input()


func clear_driver_input() -> void:
	drive_command = 0.0
	steering_command = 0.0
	brake_command = 0.0


func is_activated() -> bool:
	return activated


func is_parking_brake() -> bool:
	return parking_brake


func set_parking_brake(enabled: bool) -> void:
	parking_brake = enabled
	if enabled:
		drive_command = 0.0
		steering_command = 0.0
		brake_command = 1.0
	else:
		brake_command = 0.0


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
		"parking_brake": parking_brake,
		"released_from_anchor": released_from_anchor,
		"drive_command": drive_command,
		"brake_command": brake_command,
		"steering_command": steering_command,
	}


func apply_dict(data: Dictionary) -> void:
	activated = bool(data.get("activated", false))
	parking_brake = bool(data.get("parking_brake", true))
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
	copy.parking_brake = parking_brake
	copy.released_from_anchor = released_from_anchor
	return copy
