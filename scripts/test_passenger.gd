extends Node3D

@onready var _cart: RigidBody3D = $Cart
@onready var _probe: CharacterBody3D = $PassengerProbe


func _ready() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	await get_tree().create_timer(3.0).timeout
	if not _probe.is_on_floor():
		_fail("probe did not settle on a floor")
		return
	if _support_carrier() != _cart:
		_fail("probe did not enter the rover support frame")
		return

	var initial_cart_position: Vector3 = _cart.global_position
	var initial_local: Vector3 = _cart.to_local(
		_probe.global_position
	)
	_cart.call("set_drive_command", 1.0, 0.0)
	await get_tree().create_timer(4.0).timeout
	var cart_distance: float = _cart.global_position.distance_to(
		initial_cart_position
	)
	if cart_distance < 6.0:
		_fail("rover drove only %.2f m" % cart_distance)
		return
	var drive_drift: float = _local_xz_drift(initial_local)
	if drive_drift >= 0.5:
		_fail("passenger drifted %.3f m during acceleration" % drive_drift)
		return
	if _support_carrier() != _cart:
		_fail("passenger left rover during acceleration")
		return

	_cart.call("set_drive_command", 0.5, 0.0)
	_cart.call("set_steering_command", 1.0)
	await get_tree().create_timer(2.0).timeout
	var turn_drift: float = _local_xz_drift(initial_local)
	if turn_drift >= 0.8:
		_fail("passenger drifted %.3f m during turn" % turn_drift)
		return
	if _support_carrier() != _cart:
		_fail("passenger left rover during turn")
		return

	_cart.call("set_steering_command", 0.0)
	# A passenger inherits takeoff velocity, not the rover's future
	# acceleration. Test the moving-platform jump while coasting so landing
	# back on the deck remains a physically valid expectation.
	_cart.call("set_drive_command", 0.0, 0.0)
	await get_tree().create_timer(1.0).timeout
	var jump_local: Vector3 = _cart.to_local(_probe.global_position)
	_probe.call("request_jump")
	var landing_timeout := 4.5
	var left_floor := false
	while landing_timeout > 0.0:
		await get_tree().create_timer(0.1).timeout
		landing_timeout -= 0.1
		if not _probe.is_on_floor():
			left_floor = true
		if (
			left_floor
			and _probe.is_on_floor()
			and _support_carrier() == _cart
		):
			break
	if not _probe.is_on_floor() or _support_carrier() != _cart:
		_fail(
			"passenger landing invalid floor=%s carrier=%s drift=%.3f"
			% [
				_probe.is_on_floor(),
				_support_carrier() == _cart,
				_local_xz_drift(jump_local),
			]
		)
		return
	var jump_drift: float = _local_xz_drift(jump_local)
	if jump_drift >= 1.0:
		_fail("passenger drifted %.3f m during jump" % jump_drift)
		return

	_cart.call("set_drive_command", 0.0, 1.0)
	var brake_timeout := 8.0
	while _cart.linear_velocity.length() > 0.2 and brake_timeout > 0.0:
		await get_tree().create_timer(0.1).timeout
		brake_timeout -= 0.1
	if brake_timeout <= 0.0:
		_fail("rover did not stop before dismount test")
		return

	_probe.set("walk_input", Vector2(1.0, 0.0))
	await get_tree().create_timer(1.5).timeout
	_probe.set("walk_input", Vector2.ZERO)
	await get_tree().create_timer(1.0).timeout
	if _support_carrier() != null:
		_fail("passenger remained in rover frame after walking off")
		return
	if not _probe.is_on_floor():
		_fail("passenger did not land on static floor")
		return
	if _probe.global_position.y < 0.85 or _probe.global_position.y > 1.25:
		_fail(
			"passenger floor height %.3f is invalid"
			% _probe.global_position.y
		)
		return
	if _vector_is_invalid(_probe.global_position):
		_fail("passenger position became invalid")
		return

	print("POC3: PASS")
	get_tree().quit(0)


func _support_carrier() -> RigidBody3D:
	return _probe.call("support_carrier")


func _local_xz_drift(reference: Vector3) -> float:
	var current: Vector3 = _cart.to_local(_probe.global_position)
	return Vector2(
		current.x - reference.x,
		current.z - reference.z
	).length()


func _vector_is_invalid(value: Vector3) -> bool:
	return (
		is_nan(value.x)
		or is_nan(value.y)
		or is_nan(value.z)
		or is_inf(value.x)
		or is_inf(value.y)
		or is_inf(value.z)
	)


func _fail(reason: String) -> void:
	print("POC3: FAIL %s" % reason)
	get_tree().quit(1)
