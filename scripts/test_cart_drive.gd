extends Node3D

@onready var _cart: RigidBody3D = $Cart

var _elapsed := 0.0
var _drive_started := false
var _brake_started := false
var _drive_start_z := 0.0
var _drive_distance := 0.0
var _speed_before_braking := 0.0
var _saw_slip := false


func _physics_process(delta: float) -> void:
	_elapsed += delta

	if _elapsed < 3.0:
		_cart.set_drive_command(0.0, 0.0)
		return

	if not _drive_started:
		_drive_started = true
		_drive_start_z = _cart.global_position.z

	if _elapsed < 7.0:
		_cart.set_drive_command(1.0, 0.0)
		_saw_slip = _saw_slip or _cart.is_slipping()
		return

	if not _brake_started:
		_brake_started = true
		_drive_distance = _drive_start_z - _cart.global_position.z
		_speed_before_braking = _cart.linear_velocity.length()

	if _elapsed < 15.0:
		_cart.set_drive_command(0.0, 1.0)
		return

	set_physics_process(false)
	if _drive_distance < 2.0:
		_fail("drive distance %.3f m is too short" % _drive_distance)
		return
	if _speed_before_braking < 1.0:
		_fail(
			"speed before braking %.3f m/s is too low"
			% _speed_before_braking
		)
		return
	if not _saw_slip:
		_fail("grip saturation was never observed")
		return
	if _cart.linear_velocity.length() >= 0.2:
		_fail(
			"velocity=%s after drive distance=%.2f speed=%.2f"
			% [
				_cart.linear_velocity,
				_drive_distance,
				_speed_before_braking,
			]
		)
		return

	print(
		"POC1B: PASS distance=%.2f speed=%.2f stopped=%.3f"
		% [
			_drive_distance,
			_speed_before_braking,
			_cart.linear_velocity.length(),
		]
	)
	get_tree().quit(0)


func _fail(reason: String) -> void:
	print("POC1B: FAIL %s" % reason)
	get_tree().quit(1)
