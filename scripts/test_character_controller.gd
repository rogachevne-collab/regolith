extends Node3D

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
const PHYSICS_HZ := 60.0
const FLOOR_ORIGIN_Y := 0.9

@onready var _probe: CharacterBody3D = $LocomotionProbe

var _metrics: Array[String] = []


func _ready() -> void:
	_build_benchmark_geometry()
	call_deferred("_run_test")


func _run_test() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "PLAYER1")
	await _test_acceleration_and_stop()
	await _test_speed_caps()
	await _test_jump()
	await _test_steps()
	await _test_low_ceiling_and_wall()
	await _test_slopes()
	_assert_valid("final state")
	for metric: String in _metrics:
		print("PLAYER1: %s" % metric)
	print("PLAYER1: PASS")
	get_tree().quit(0)


func _test_acceleration_and_stop() -> void:
	await _reset_probe(Vector3(-10.0, FLOOR_ORIGIN_Y, -12.0))
	_probe.set("move_input", Vector3.RIGHT)
	var acceleration_frames := 0
	while _horizontal_speed() < 4.5 and acceleration_frames < 30:
		await get_tree().physics_frame
		acceleration_frames += 1
		_assert_valid("acceleration")
	var acceleration_time := acceleration_frames / PHYSICS_HZ
	if acceleration_time > 0.3:
		_fail("90%% walk took %.3f s" % acceleration_time)
	await _physics_frames(10)
	var walk_speed := _horizontal_speed()
	if absf(walk_speed - 5.0) > 0.05:
		_fail("walk speed %.3f is not 5.0 m/s" % walk_speed)

	_probe.set("move_input", Vector3.ZERO)
	var stop_start := _probe.global_position
	var stop_frames := 0
	while _horizontal_speed() > 0.05 and stop_frames < 30:
		await get_tree().physics_frame
		stop_frames += 1
		_assert_valid("deceleration")
	var stop_time := stop_frames / PHYSICS_HZ
	var stop_distance := _xz_distance(stop_start, _probe.global_position)
	if _horizontal_speed() > 0.05:
		_fail("stop retained %.3f m/s" % _horizontal_speed())
	if stop_time > 0.25:
		_fail("stop took %.3f s" % stop_time)
	_metrics.append(
		"walk=%.3fm/s t90=%.3fs stop=%.3fs/%.3fm"
		% [walk_speed, acceleration_time, stop_time, stop_distance]
	)


func _test_speed_caps() -> void:
	await _reset_probe(Vector3(-10.0, FLOOR_ORIGIN_Y, -10.0))
	_probe.set("move_input", Vector3.RIGHT)
	_probe.set("sprint_input", true)
	await _physics_frames(30)
	var sprint_speed := _horizontal_speed()
	if absf(sprint_speed - 7.5) > 0.05:
		_fail("sprint speed %.3f is not 7.5 m/s" % sprint_speed)

	await _reset_probe(Vector3(-10.0, FLOOR_ORIGIN_Y, -10.0))
	_probe.set("sprint_input", false)
	_probe.set("move_input", Vector3(1.0, 0.0, 1.0))
	await _physics_frames(30)
	var diagonal_speed := _horizontal_speed()
	if diagonal_speed > 5.05 or diagonal_speed < 4.95:
		_fail("diagonal speed %.3f is not capped at 5 m/s" % diagonal_speed)
	_metrics.append(
		"sprint=%.3fm/s diagonal=%.3fm/s"
		% [sprint_speed, diagonal_speed]
	)


func _test_jump() -> void:
	await _reset_probe(Vector3(-10.0, FLOOR_ORIGIN_Y, -8.0))
	var start_y := _probe.global_position.y
	_probe.call("request_jump")
	var peak_y := start_y
	var airborne_frames := 0
	var left_floor := false
	while airborne_frames < 300:
		await get_tree().physics_frame
		peak_y = maxf(peak_y, _probe.global_position.y)
		if not _probe.is_on_floor():
			left_floor = true
		if left_floor and _probe.is_on_floor():
			break
		airborne_frames += 1
	if not left_floor or not _probe.is_on_floor():
		_fail("jump did not complete within 5 seconds")
	var jump_height := peak_y - start_y
	var airtime := airborne_frames / PHYSICS_HZ
	if jump_height < 1.2 or jump_height > 1.4:
		_fail("jump height %.3f outside 1.2..1.4 m" % jump_height)
	if airtime < 2.3 or airtime > 2.7:
		_fail("jump airtime %.3f outside 2.3..2.7 s" % airtime)
	_metrics.append(
		"jump_height=%.3fm airtime=%.3fs gravity=1.62m/s2"
		% [jump_height, airtime]
	)


func _test_steps() -> void:
	var heights := [0.1, 0.2, 0.3, 0.4]
	var lanes := [-6.0, -2.0, 2.0, 6.0]
	var climbed: Array[String] = []
	for index: int in heights.size():
		var height: float = heights[index]
		await _reset_probe(
			Vector3(-2.0, FLOOR_ORIGIN_Y, lanes[index])
		)
		_probe.set("move_input", Vector3.RIGHT)
		var max_step := 0.0
		var reached_platform := false
		for frame: int in 90:
			await get_tree().physics_frame
			max_step = maxf(
				max_step,
				float(_probe.call("last_step_height"))
			)
			_assert_valid("%.1f m step" % height)
			if (
				_probe.global_position.x > 1.8
				and _probe.global_position.y
				> FLOOR_ORIGIN_Y + height - 0.08
			):
				reached_platform = true
				break
		_probe.set("move_input", Vector3.ZERO)
		if height <= 0.3:
			if not reached_platform:
				_fail("%.1f m step was not climbed" % height)
			if max_step < height - 0.05:
				_fail(
					"%.1f m step reported only %.3f m rise"
					% [height, max_step]
				)
			climbed.append("%.1f" % height)
		else:
			if reached_platform:
				_fail("0.4 m step was incorrectly climbed")
			if _probe.global_position.y > FLOOR_ORIGIN_Y + 0.08:
				_fail(
					"0.4 m rejection lifted probe to %.3f"
					% _probe.global_position.y
				)
	_metrics.append(
		"steps_pass=%s m step_reject=0.4m max=%.2fm"
		% [", ".join(climbed), _probe.get("step_height")]
	)


func _test_low_ceiling_and_wall() -> void:
	await _reset_probe(Vector3(-2.0, FLOOR_ORIGIN_Y, 10.0))
	_probe.set("move_input", Vector3.RIGHT)
	await _physics_frames(90)
	_probe.set("move_input", Vector3.ZERO)
	var ceiling_position := _probe.global_position
	if ceiling_position.x > 0.75:
		_fail("low-ceiling step was crossed: %s" % ceiling_position)
	if ceiling_position.y > FLOOR_ORIGIN_Y + 0.08:
		_fail("low ceiling penetrated at y=%.3f" % ceiling_position.y)
	_assert_valid("low ceiling rejection")

	await _reset_probe(Vector3(-2.0, FLOOR_ORIGIN_Y, 14.0))
	_probe.set("move_input", Vector3.RIGHT)
	await _physics_frames(90)
	_probe.set("move_input", Vector3.ZERO)
	var wall_x := _probe.global_position.x
	if wall_x > 0.75:
		_fail("vertical wall was climbed to x=%.3f" % wall_x)
	if _probe.global_position.y > FLOOR_ORIGIN_Y + 0.08:
		_fail("vertical wall lifted probe to y=%.3f" % _probe.global_position.y)
	_metrics.append(
		"ceiling_reject_x=%.3fm wall_reject_x=%.3fm"
		% [ceiling_position.x, wall_x]
	)


func _test_slopes() -> void:
	await _reset_probe(Vector3(-2.0, FLOOR_ORIGIN_Y, 20.0))
	_probe.set("move_input", Vector3.RIGHT)
	await _physics_frames(100)
	_probe.set("move_input", Vector3.ZERO)
	var walkable_position := _probe.global_position
	if walkable_position.x < 1.5 or walkable_position.y < 1.4:
		_fail(
			"45 degree slope was not traversed: %s"
			% walkable_position
		)

	await _reset_probe(Vector3(-2.0, FLOOR_ORIGIN_Y, 26.0))
	_probe.set("move_input", Vector3.RIGHT)
	var steep_was_floor := false
	for frame: int in 100:
		await get_tree().physics_frame
		if (
			_probe.global_position.y > FLOOR_ORIGIN_Y + 0.12
			and _probe.is_on_floor()
		):
			steep_was_floor = true
		_assert_valid("50 degree slope")
	_probe.set("move_input", Vector3.ZERO)
	var steep_position := _probe.global_position
	if steep_position.x > 0.8 or steep_position.y > FLOOR_ORIGIN_Y + 0.12:
		_fail(
			"50 degree slope was crossed: %s"
			% steep_position
		)
	if steep_was_floor:
		_fail("50 degree slope was classified as floor")
	_metrics.append(
		"slope45=(%.3f,%.3f)m slope50_reject=(%.3f,%.3f)m"
		% [
			walkable_position.x,
			walkable_position.y,
			steep_position.x,
			steep_position.y,
		]
	)


func _reset_probe(world_position: Vector3) -> void:
	_probe.set_physics_process(false)
	_probe.set("move_input", Vector3.ZERO)
	_probe.set("sprint_input", false)
	_probe.velocity = Vector3.ZERO
	_probe.global_position = world_position
	_probe.call("clear_support_frame")
	_probe.set_physics_process(true)
	await _physics_frames(12)
	if not _probe.is_on_floor():
		_fail("probe did not settle at %s" % world_position)
	_assert_valid("reset")


func _physics_frames(count: int) -> void:
	for frame: int in count:
		await get_tree().physics_frame


func _horizontal_speed() -> float:
	return Vector2(_probe.velocity.x, _probe.velocity.z).length()


func _xz_distance(from: Vector3, to: Vector3) -> float:
	return Vector2(to.x - from.x, to.z - from.z).length()


func _build_benchmark_geometry() -> void:
	_add_box(Vector3(0.0, -0.25, 7.0), Vector3(80.0, 0.5, 64.0))
	var heights := [0.1, 0.2, 0.3, 0.4]
	var lanes := [-6.0, -2.0, 2.0, 6.0]
	for index: int in heights.size():
		var height: float = heights[index]
		_add_box(
			Vector3(4.0, height * 0.5, lanes[index]),
			Vector3(6.0, height, 2.0)
		)
	_add_box(Vector3(4.0, 0.1, 10.0), Vector3(6.0, 0.2, 2.0))
	_add_box(Vector3(2.75, 2.2, 10.0), Vector3(4.5, 0.5, 2.0))
	_add_box(Vector3(1.0, 1.5, 14.0), Vector3(0.5, 3.0, 2.0))
	_add_ramp(45.0, 20.0)
	_add_ramp(50.0, 26.0)


func _add_ramp(angle_degrees: float, lane_z: float) -> void:
	var angle := deg_to_rad(angle_degrees)
	var length := 6.0
	var thickness := 0.2
	var center := Vector3(
		cos(angle) * length * 0.5,
		sin(angle) * length * 0.5 - cos(angle) * thickness * 0.5,
		lane_z
	)
	_add_box(
		center,
		Vector3(length, thickness, 2.0),
		Vector3(0.0, 0.0, angle)
	)


func _add_box(
	world_position: Vector3,
	size: Vector3,
	rotation_radians := Vector3.ZERO
) -> void:
	var body := StaticBody3D.new()
	body.position = world_position
	body.rotation = rotation_radians
	body.collision_layer = 1
	body.collision_mask = 4
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	add_child(body)


func _fail(reason: String) -> void:
	print("PLAYER1: FAIL %s" % reason)
	get_tree().quit(1)
	await get_tree().process_frame


func _assert_valid(context: String) -> void:
	var values := [
		_probe.global_position.x,
		_probe.global_position.y,
		_probe.global_position.z,
		_probe.velocity.x,
		_probe.velocity.y,
		_probe.velocity.z,
	]
	for value: float in values:
		if is_nan(value) or is_inf(value):
			_fail("%s produced NaN/Inf" % context)
