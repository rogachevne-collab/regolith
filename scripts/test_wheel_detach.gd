extends Node3D

@onready var _cart: RigidBody3D = $Cart


func _ready() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	await get_tree().create_timer(3.0).timeout
	_cart.call("set_drive_command", 1.0, 0.0)
	await get_tree().create_timer(4.0).timeout

	var event_count: int = int(_cart.call("structure_event_count"))
	var source_velocity: Vector3 = _cart.linear_velocity
	var source_angular_velocity: Vector3 = _cart.angular_velocity
	var source_com_world: Vector3 = _cart.to_global(
		_cart.center_of_mass
	)
	if not bool(_cart.call("request_detach_wheel", 0)):
		_fail("front-left wheel detach command was rejected")
		return
	if not await _wait_for_structure_event(event_count):
		_fail("wheel detach produced no structural event")
		return

	if int(_cart.call("active_wheel_count")) != 3:
		_fail("rover did not switch to three active suspensions")
		return
	if int(_cart.call("structure_element_count")) != 14:
		_fail("wheel element remained in rover structure")
		return

	var detached_wheel: RigidBody3D = _detached_wheel()
	if detached_wheel == null:
		_fail("detached wheel did not become a physical body")
		return
	var expected_velocity: Vector3 = (
		source_velocity
		+ source_angular_velocity.cross(
			detached_wheel.global_position - source_com_world
		)
	)
	if (
		detached_wheel.linear_velocity - expected_velocity
	).length() >= 0.5:
		_fail("detached wheel did not inherit contact-point velocity")
		return
	if absf(
		float(_cart.call("structure_total_mass"))
		+ detached_wheel.mass
		- 400.0
	) >= 0.02:
		_fail("wheel detach did not conserve total mass")
		return

	var position_after_detach: Vector3 = _cart.global_position
	await get_tree().create_timer(2.0).timeout
	if _cart.global_position.distance_to(position_after_detach) < 1.0:
		_fail("three-wheel rover stopped responding to drive")
		return
	if _vector_is_invalid(_cart.global_position):
		_fail("rover position became invalid after wheel loss")
		return
	if _vector_is_invalid(detached_wheel.global_position):
		_fail("detached wheel position became invalid")
		return

	print("POC2-WHEEL: PASS")
	get_tree().quit(0)


func _wait_for_structure_event(previous_count: int) -> bool:
	for _frame: int in 10:
		await get_tree().process_frame
		if int(_cart.call("structure_event_count")) > previous_count:
			return true
	return false


func _detached_wheel() -> RigidBody3D:
	var nodes: Array[Node] = get_tree().get_nodes_in_group(
		"detached_wheels"
	)
	if nodes.is_empty():
		return null
	return nodes[0] as RigidBody3D


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
	print("POC2-WHEEL: FAIL %s" % reason)
	get_tree().quit(1)
