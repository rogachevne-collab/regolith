extends Node3D

@onready var _cart: RigidBody3D = $Cart

var _elapsed := 0.0
var _turn_started := false
var _turn_start_x := 0.0
var _saw_lateral_slip := false


func _physics_process(delta: float) -> void:
	_elapsed += delta

	if _elapsed < 3.0:
		_cart.set_drive_command(0.0, 0.0)
		_cart.set_steering_command(0.0)
		return

	if _elapsed < 7.0:
		_cart.set_drive_command(1.0, 0.0)
		_cart.set_steering_command(0.0)
		return

	if not _turn_started:
		_turn_started = true
		_turn_start_x = _cart.global_position.x

	if _elapsed < 11.0:
		_cart.set_drive_command(1.0, 0.0)
		_cart.set_steering_command(1.0)
		_saw_lateral_slip = (
			_saw_lateral_slip or _cart.is_lateral_slipping()
		)
		return

	set_physics_process(false)
	var lateral_distance: float = absf(
		_cart.global_position.x - _turn_start_x
	)
	var forward: Vector3 = -_cart.global_transform.basis.z.normalized()
	if lateral_distance < 1.0:
		_fail("lateral displacement %.3f m is too short" % lateral_distance)
		return
	if absf(forward.x) < 0.15:
		_fail("heading changed too little: %s" % forward)
		return
	if _cart.linear_velocity.length() < 1.0:
		_fail("speed %.3f m/s is too low" % _cart.linear_velocity.length())
		return
	if not _saw_lateral_slip:
		_fail("lateral grip saturation was never observed")
		return

	print(
		"POC1C: PASS lateral=%.2f heading_x=%.2f speed=%.2f"
		% [
			lateral_distance,
			forward.x,
			_cart.linear_velocity.length(),
		]
	)
	get_tree().quit(0)


func _fail(reason: String) -> void:
	print("POC1C: FAIL %s" % reason)
	get_tree().quit(1)
