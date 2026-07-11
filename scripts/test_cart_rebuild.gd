extends Node3D

@onready var _cart: RigidBody3D = $Cart


func _ready() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	await get_tree().create_timer(3.0).timeout
	_cart.call("set_drive_command", 1.0, 0.0)
	await get_tree().create_timer(4.0).timeout

	if int(_cart.call("structure_element_count")) != 15:
		_fail("rover did not initialize with 11 frame and 4 wheel elements")
		return
	if absf(float(_cart.call("structure_total_mass")) - 400.0) >= 0.01:
		_fail("initial rover structure mass is not 400 kg")
		return

	var event_count: int = int(_cart.call("structure_event_count"))
	var position_before: Vector3 = _cart.global_position
	var velocity_before: Vector3 = _cart.linear_velocity
	if not bool(_cart.call(
		"request_detach_frame_element",
		Vector3i.ZERO
	)):
		_fail("moving rover rejected center block detach")
		return
	if not await _wait_for_structure_event(event_count):
		_fail("detach command produced no structural event")
		return
	if not _position_is_continuous(
		position_before,
		velocity_before.length()
	):
		_fail("moving rover teleported during detach")
		return
	if _relative_speed_change(
		velocity_before,
		_cart.linear_velocity
	) >= 0.15:
		_fail("moving rover speed jumped during detach")
		return
	if int(_cart.call("structure_element_count")) != 14:
		_fail("center detach did not remove exactly one element")
		return
	if _valid_fragments().size() != 1:
		_fail("center detach did not create one physical fragment")
		return

	await get_tree().create_timer(1.0).timeout
	event_count = int(_cart.call("structure_event_count"))
	position_before = _cart.global_position
	velocity_before = _cart.linear_velocity
	if not bool(_cart.call(
		"request_attach_frame_element",
		Vector3i.ZERO
	)):
		_fail("moving rover rejected center block attach")
		return
	if not await _wait_for_structure_event(event_count):
		_fail("attach command produced no structural event")
		return
	await get_tree().process_frame
	if not _position_is_continuous(
		position_before,
		velocity_before.length()
	):
		_fail("moving rover teleported during attach")
		return
	if _relative_speed_change(
		velocity_before,
		_cart.linear_velocity
	) >= 0.15:
		_fail("moving rover speed jumped during attach")
		return
	if int(_cart.call("structure_element_count")) != 15:
		_fail("center attach did not restore the frame")
		return
	if _valid_fragments().size() != 0:
		_fail("welded fragment was not consumed")
		return

	event_count = int(_cart.call("structure_event_count"))
	if not bool(_cart.call(
		"request_detach_frame_element",
		Vector3i(0, 0, 1)
	)):
		_fail("moving rover rejected bridge detach")
		return
	if not await _wait_for_structure_event(event_count):
		_fail("bridge detach produced no structural event")
		return
	await get_tree().process_frame
	if int(_cart.call("structure_element_count")) != 13:
		_fail("bridge split did not leave 13 elements on rover")
		return
	if _valid_fragments().size() != 2:
		_fail("bridge split did not create two physical bodies")
		return
	if int(_cart.call("active_wheel_count")) != 4:
		_fail("unaffected suspension disappeared after rebuild")
		return
	if absf(_world_structure_mass() - 400.0) >= 0.02:
		_fail(
			"mass was not conserved: %.3f kg"
			% _world_structure_mass()
		)
		return

	var speed_after_split: float = _cart.linear_velocity.length()
	await get_tree().create_timer(2.0).timeout
	if _cart.linear_velocity.length() <= speed_after_split:
		_fail("drive stopped working after structural split")
		return
	if _vector_is_invalid(_cart.global_position):
		_fail("rover position became invalid")
		return

	print("POC2-ROVER: PASS")
	get_tree().quit(0)


func _wait_for_structure_event(previous_count: int) -> bool:
	for _frame: int in 10:
		await get_tree().process_frame
		if int(_cart.call("structure_event_count")) > previous_count:
			return true
	return false


func _valid_fragments() -> Array[RigidBody3D]:
	var result: Array[RigidBody3D] = []
	var values: Array = _cart.call("spawned_fragments")
	for value: Variant in values:
		var fragment: RigidBody3D = value
		if is_instance_valid(fragment) and not fragment.is_queued_for_deletion():
			result.append(fragment)
	return result


func _world_structure_mass() -> float:
	var result: float = float(_cart.call("structure_total_mass"))
	for fragment: RigidBody3D in _valid_fragments():
		result += float(fragment.call("total_mass"))
	return result


func _relative_speed_change(before: Vector3, after: Vector3) -> float:
	return (
		absf(after.length() - before.length())
		/ maxf(before.length(), 0.001)
	)


func _position_is_continuous(before: Vector3, speed: float) -> bool:
	var physics_step := 1.0 / float(Engine.physics_ticks_per_second)
	var movement_budget: float = speed * physics_step * 4.0 + 0.02
	return _cart.global_position.distance_to(before) <= movement_budget


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
	print("POC2-ROVER: FAIL %s" % reason)
	get_tree().quit(1)
