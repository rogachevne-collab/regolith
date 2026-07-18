extends Node3D

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
@onready var _assembly: RigidBody3D = $Assembly

var _fragments: Array[RigidBody3D] = []


func _ready() -> void:
	_assembly.connect(
		"fragment_spawned",
		Callable(self, "_on_fragment_spawned")
	)
	var cells: Array[Vector3i] = [
		Vector3i(0, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(2, 0, 0),
		Vector3i(3, 0, 0),
		Vector3i(4, 0, 0),
	]
	_assembly.call("build_from", cells)
	_assembly.freeze = false
	call_deferred("_run_test")


func _run_test() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "POC2")
	await get_tree().create_timer(4.0).timeout
	if _assembly.linear_velocity.length() >= 0.05:
		_fail(
			"initial assembly did not settle: %.4f m/s"
			% _assembly.linear_velocity.length()
		)
		return
	if not _mass_is(_assembly, 250.0):
		_fail("initial mass is not 250 kg")
		return

	var resting_origin: Vector3 = _assembly.global_position
	if not bool(_assembly.call(
		"attach_element",
		Vector3i(2, 1, 0),
		50.0
	)):
		_fail("2a attach was rejected")
		return
	await get_tree().physics_frame
	if not _mass_is(_assembly, 300.0):
		_fail("2a mass after attach is not 300 kg")
		return
	if not bool(_assembly.call(
		"detach_element",
		Vector3i(2, 1, 0)
	)):
		_fail("2a detach was rejected")
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not _mass_is(_assembly, 250.0):
		_fail("2a mass after detach is not 250 kg")
		return
	if _assembly.global_position.distance_to(resting_origin) >= 0.05:
		_fail("2a rebuild moved the body origin")
		return
	if _fragments.is_empty():
		_fail("2a detach did not spawn a fragment")
		return

	var temporary_fragment: RigidBody3D = _fragments.pop_back()
	temporary_fragment.queue_free()
	await get_tree().process_frame

	_assembly.apply_central_impulse(
		Vector3(0.0, 0.0, -_assembly.mass * 2.0)
	)
	await get_tree().create_timer(0.5).timeout
	var position_before_detach: Vector3 = _assembly.global_position
	var speed_before_detach: float = _assembly.linear_velocity.length()
	if not bool(_assembly.call(
		"detach_element",
		Vector3i(4, 0, 0)
	)):
		_fail("2b detach was rejected")
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	var position_delta: float = _assembly.global_position.distance_to(
		position_before_detach
	)
	var frame_budget: float = (
		speed_before_detach
		* (2.0 / float(Engine.physics_ticks_per_second))
		* 2.0
		+ 0.01
	)
	if position_delta > frame_budget:
		_fail(
			"2b origin jumped %.4f m (budget %.4f)"
			% [position_delta, frame_budget]
		)
		return
	var speed_after_detach: float = _assembly.linear_velocity.length()
	var relative_speed_change: float = (
		absf(speed_after_detach - speed_before_detach)
		/ maxf(speed_before_detach, 0.001)
	)
	if relative_speed_change >= 0.15:
		_fail(
			"2b speed changed by %.1f%%"
			% (relative_speed_change * 100.0)
		)
		return

	var fragment_count_before_split: int = _fragments.size()
	if not bool(_assembly.call(
		"detach_element",
		Vector3i(2, 0, 0)
	)):
		_fail("2c split detach was rejected")
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	if int(_assembly.call("element_count")) != 2:
		_fail(
			"2c source retained %d elements instead of 2"
			% int(_assembly.call("element_count"))
		)
		return
	if _fragments.size() < fragment_count_before_split + 2:
		_fail("2c did not spawn detached and disconnected bodies")
		return

	var disconnected: RigidBody3D = _find_fragment_with_cell(
		Vector3i(3, 0, 0)
	)
	if disconnected == null:
		_fail("2c disconnected component was not found")
		return
	if (
		disconnected.linear_velocity
		- _assembly.linear_velocity
	).length() >= 0.5:
		_fail(
			"2c velocity mismatch source=%s fragment=%s omega=%s"
			% [
				_assembly.linear_velocity,
				disconnected.linear_velocity,
				_assembly.angular_velocity,
			]
		)
		return
	if absf(_world_assembly_mass() - 250.0) >= 0.01:
		_fail(
			"2c total mass is %.3f kg instead of 250"
			% _world_assembly_mass()
		)
		return

	await get_tree().create_timer(2.0).timeout
	for node: Node in get_tree().get_nodes_in_group("assemblies"):
		var body: RigidBody3D = node as RigidBody3D
		if body == null or _vector_is_invalid(body.global_position):
			_fail("an assembly has an invalid position")
			return

	print("POC2: PASS")
	get_tree().quit(0)


func _on_fragment_spawned(fragment: RigidBody3D) -> void:
	_fragments.append(fragment)


func _find_fragment_with_cell(cell: Vector3i) -> RigidBody3D:
	for fragment: RigidBody3D in _fragments:
		if is_instance_valid(fragment) and bool(
			fragment.call("has_element", cell)
		):
			return fragment
	return null


func _mass_is(body: RigidBody3D, expected: float) -> bool:
	return absf(float(body.call("total_mass")) - expected) < 0.01


func _world_assembly_mass() -> float:
	var result := 0.0
	for node: Node in get_tree().get_nodes_in_group("assemblies"):
		if is_instance_valid(node):
			result += float(node.call("total_mass"))
	return result


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
	print("POC2: FAIL %s" % reason)
	get_tree().quit(1)
