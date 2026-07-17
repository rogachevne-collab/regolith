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

## Flight (POC-THRUSTERS-V0): SE-like 6DOF in body local space.
## Godot body axes: x = right, y = up, −z = forward; each component −1..1.
var translate_command: Vector3 = Vector3.ZERO
var pitch_command: float = 0.0
var yaw_command: float = 0.0
var roll_command: float = 0.0
## Inertial dampeners; default on (SE-like).
var dampeners: bool = true


func activate() -> void:
	activated = true


func deactivate() -> void:
	activated = false
	clear_driver_input()


func clear_driver_input() -> void:
	drive_command = 0.0
	steering_command = 0.0
	brake_command = 0.0
	translate_command = Vector3.ZERO
	pitch_command = 0.0
	yaw_command = 0.0
	roll_command = 0.0


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


func set_translate_command(command: Vector3) -> void:
	translate_command = Vector3(
		clampf(command.x, -1.0, 1.0),
		clampf(command.y, -1.0, 1.0),
		clampf(command.z, -1.0, 1.0)
	)


func set_attitude_commands(pitch: float, yaw: float, roll: float) -> void:
	pitch_command = clampf(pitch, -1.0, 1.0)
	yaw_command = clampf(yaw, -1.0, 1.0)
	roll_command = clampf(roll, -1.0, 1.0)


func set_dampeners(enabled: bool) -> void:
	dampeners = enabled


func is_dampeners() -> bool:
	return dampeners


func translate_magnitude() -> float:
	return minf(translate_command.length(), 1.0)


func has_active_input() -> bool:
	return (
		absf(drive_command) > 0.001
		or brake_command > 0.001
		or absf(steering_command) > 0.001
		or translate_magnitude() > 0.001
		or absf(pitch_command) > 0.001
		or absf(yaw_command) > 0.001
		or absf(roll_command) > 0.001
	)


func has_active_flight_input() -> bool:
	return (
		translate_magnitude() > 0.001
		or absf(pitch_command) > 0.001
		or absf(yaw_command) > 0.001
		or absf(roll_command) > 0.001
	)


func to_dict() -> Dictionary:
	return {
		"activated": activated,
		"parking_brake": parking_brake,
		"released_from_anchor": released_from_anchor,
		"drive_command": drive_command,
		"brake_command": brake_command,
		"steering_command": steering_command,
		"translate_command": SnapshotCodec.vector3_to_array(translate_command),
		"pitch_command": pitch_command,
		"yaw_command": yaw_command,
		"roll_command": roll_command,
		"dampeners": dampeners,
	}


func apply_dict(data: Dictionary) -> void:
	activated = bool(data.get("activated", false))
	parking_brake = bool(data.get("parking_brake", true))
	released_from_anchor = bool(data.get("released_from_anchor", false))
	drive_command = float(data.get("drive_command", 0.0))
	brake_command = float(data.get("brake_command", 0.0))
	steering_command = float(data.get("steering_command", 0.0))
	if data.has("translate_command"):
		set_translate_command(
			SnapshotCodec.vector3_from_variant(data.get("translate_command"))
		)
	else:
		# Legacy scalar thrust_command → +Y translate.
		var legacy_thrust := float(data.get("thrust_command", 0.0))
		set_translate_command(Vector3(0.0, legacy_thrust, 0.0))
	pitch_command = float(data.get("pitch_command", 0.0))
	yaw_command = float(data.get("yaw_command", 0.0))
	roll_command = float(data.get("roll_command", 0.0))
	dampeners = bool(data.get("dampeners", true))


func duplicate_state() -> AssemblyLocomotionController:
	var copy := AssemblyLocomotionController.new()
	copy.apply_dict(to_dict())
	return copy
