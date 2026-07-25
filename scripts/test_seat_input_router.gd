extends Node
## Kernel-pure SeatInputRouter matrix (CONTROL-AXES-V0).
## Proves Space fan-out and per-seat toggles on the router itself — not by
## manually poking AssemblyLocomotionController fields.

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "SEAT-INPUT-ROUTER")
	var tests: Array[Callable] = [
		_test_stock_defaults_space_is_brake_only,
		_test_hybrid_defaults_w,
		_test_hybrid_space_fanout,
		_test_wheels_off_space_stays_flight_up,
		_test_thrusters_off_space_stays_wheel_brake,
		_test_thrusters_off_clears_translate_and_gate,
		_test_gyros_independent_of_thrusters,
		_test_each_toggle_clears_stale_channel,
		_test_parking_brake_spares_flight,
		_test_parking_brake_holds_when_wheels_off,
		_test_modal_zero_frame,
		_test_baked_drive_steer_axes,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("SEAT-INPUT-ROUTER: PASS")
	get_tree().quit(0)


func _fail(message: String) -> bool:
	push_error(message)
	print("SEAT-INPUT-ROUTER: FAIL — %s" % message)
	get_tree().quit(1)
	return false


func _policy(
	wheels: bool = true,
	thrusters: bool = true,
	gyros: bool = true
) -> SeatControlState:
	var state := SeatControlState.new()
	state.control_wheels = wheels
	state.control_thrusters = thrusters
	state.control_gyros = gyros
	return state


func _raw(overrides: Dictionary = {}) -> Dictionary:
	var raw := {
		"zero_frame": false,
		"move_forward": 0.0,
		"move_back": 0.0,
		"move_left": 0.0,
		"move_right": 0.0,
		"space": 0.0,
		"move_down": 0.0,
		"look_x": 0.0,
		"look_y": 0.0,
		"roll_left": 0.0,
		"roll_right": 0.0,
	}
	for key: Variant in overrides.keys():
		raw[key] = overrides[key]
	return raw


func _test_stock_defaults_space_is_brake_only() -> bool:
	## New SeatControlState: thrusters OFF — Space must not fan out to lift.
	var frame := SeatInputRouter.route(
		_raw({"space": 1.0}),
		SeatControlState.new(),
		false
	)
	if absf(frame.brake_command - 1.0) > 0.001:
		return _fail("stock default Space: brake expected 1")
	if frame.translate_command.length() > 0.001:
		return _fail("stock default Space: translate must stay zero")
	if frame.thrusters_route_enabled:
		return _fail("stock default: thrusters_route_enabled must be false")
	return true


func _test_hybrid_defaults_w() -> bool:
	var frame := SeatInputRouter.route(_raw({"move_forward": 1.0}), _policy(), false)
	if absf(frame.drive_command - 1.0) > 0.001:
		return _fail("hybrid W: drive expected 1, got %s" % frame.drive_command)
	if absf(frame.translate_command.z - (-1.0)) > 0.001:
		return _fail(
			"hybrid W: translate.z expected -1, got %s" % frame.translate_command.z
		)
	if not (
		frame.wheels_route_enabled
		and frame.thrusters_route_enabled
		and frame.gyros_route_enabled
	):
		return _fail("hybrid defaults: all route gates should be on")
	return true


func _test_hybrid_space_fanout() -> bool:
	var frame := SeatInputRouter.route(_raw({"space": 1.0}), _policy(), false)
	if absf(frame.brake_command - 1.0) > 0.001:
		return _fail("hybrid Space: brake expected 1")
	if absf(frame.translate_command.y - 1.0) > 0.001:
		return _fail("hybrid Space: translate.y up expected 1")
	return true


func _test_wheels_off_space_stays_flight_up() -> bool:
	var frame := SeatInputRouter.route(
		_raw({"space": 1.0}),
		_policy(false, true, true),
		false
	)
	if absf(frame.drive_command) > 0.001 or absf(frame.brake_command) > 0.001:
		return _fail("wheels off: drive/brake must be 0")
	if absf(frame.translate_command.y - 1.0) > 0.001:
		return _fail("wheels off: Space must still publish flight up")
	if frame.wheels_route_enabled:
		return _fail("wheels off: wheels_route_enabled must be false")
	return true


func _test_thrusters_off_space_stays_wheel_brake() -> bool:
	var frame := SeatInputRouter.route(
		_raw({"space": 1.0}),
		_policy(true, false, true),
		false
	)
	if absf(frame.brake_command - 1.0) > 0.001:
		return _fail("thrusters off: Space must stay wheel brake")
	if frame.translate_command.length() > 0.001:
		return _fail("thrusters off: translate must be zero")
	return true


func _test_thrusters_off_clears_translate_and_gate() -> bool:
	var frame := SeatInputRouter.route(
		_raw({"move_forward": 1.0, "move_right": 1.0, "space": 1.0}),
		_policy(true, false, true),
		false
	)
	if frame.translate_command.length() > 0.001:
		return _fail("thrusters off: translate not cleared")
	if frame.thrusters_route_enabled:
		return _fail("thrusters off: thrusters_route_enabled must be false")
	if absf(frame.drive_command - 1.0) > 0.001:
		return _fail("thrusters off: wheel drive should still publish")
	return true


func _test_gyros_independent_of_thrusters() -> bool:
	var frame := SeatInputRouter.route(
		_raw({"look_x": 0.5, "look_y": -0.25, "roll_right": 1.0}),
		_policy(false, false, true),
		false
	)
	if not frame.gyros_route_enabled:
		return _fail("gyros on without thrusters: gate false")
	if absf(frame.pitch_command - 0.25) > 0.001:
		return _fail("gyro pitch: expected 0.25 from -look_y")
	if absf(frame.yaw_command - (-0.5)) > 0.001:
		return _fail("gyro yaw: expected -0.5 from -look_x")
	if absf(frame.roll_command - (-1.0)) > 0.001:
		return _fail("gyro roll: expected -1 from -roll")
	if frame.thrusters_route_enabled or frame.translate_command.length() > 0.001:
		return _fail("gyros-only: thruster channel must stay off")
	return true


func _test_each_toggle_clears_stale_channel() -> bool:
	var wheels_off := SeatInputRouter.route(
		_raw({"move_forward": 1.0, "space": 1.0}),
		_policy(false, true, true),
		false
	)
	if (
		absf(wheels_off.drive_command) > 0.001
		or absf(wheels_off.brake_command) > 0.001
		or absf(wheels_off.steering_command) > 0.001
	):
		return _fail("toggle wheels off did not clear wheel channels")
	var gyros_off := SeatInputRouter.route(
		_raw({"look_x": 1.0, "roll_left": 1.0}),
		_policy(true, true, false),
		false
	)
	if (
		absf(gyros_off.pitch_command) > 0.001
		or absf(gyros_off.yaw_command) > 0.001
		or absf(gyros_off.roll_command) > 0.001
	):
		return _fail("toggle gyros off did not clear attitude")
	if gyros_off.gyros_route_enabled:
		return _fail("gyros off: gate must be false")
	return true


func _test_parking_brake_spares_flight() -> bool:
	var frame := SeatInputRouter.route(
		_raw({"move_forward": 1.0, "space": 1.0, "look_x": 0.2}),
		_policy(),
		true
	)
	if (
		absf(frame.drive_command) > 0.001
		or absf(frame.steering_command) > 0.001
		or absf(frame.brake_command - 1.0) > 0.001
	):
		return _fail("PB: wheels must be drive=0 steer=0 brake=1")
	if absf(frame.translate_command.y - 1.0) > 0.001:
		return _fail("PB must not touch flight translate")
	if absf(frame.yaw_command - (-0.2)) > 0.001:
		return _fail("PB must not touch gyro attitude")
	return true


func _test_parking_brake_holds_when_wheels_off() -> bool:
	## SE safety: latched PB publishes brake=1 even when Control Wheels is OFF.
	var frame := SeatInputRouter.route(
		_raw({"move_forward": 1.0, "space": 1.0}),
		_policy(false, true, true),
		true
	)
	if frame.wheels_route_enabled:
		return _fail("wheels off: route gate must be false")
	if (
		absf(frame.drive_command) > 0.001
		or absf(frame.steering_command) > 0.001
		or absf(frame.brake_command - 1.0) > 0.001
	):
		return _fail("PB with wheels off must still hold brake=1")
	if absf(frame.translate_command.y - 1.0) > 0.001:
		return _fail("PB + wheels off: Space still fans out to flight up")
	return true


func _test_modal_zero_frame() -> bool:
	var frame := SeatInputRouter.route(
		_raw({
			"zero_frame": true,
			"move_forward": 1.0,
			"space": 1.0,
			"look_x": 1.0,
		}),
		_policy(),
		false
	)
	if (
		absf(frame.drive_command) > 0.001
		or frame.translate_command.length() > 0.001
		or absf(frame.yaw_command) > 0.001
	):
		return _fail("modal zero_frame must clear continuous commands")
	if not (
		frame.wheels_route_enabled
		and frame.thrusters_route_enabled
		and frame.gyros_route_enabled
	):
		return _fail("modal zero_frame keeps route gates from policy")
	return true


## Coop stream bakes drive/steer via Input.get_axis; prefer those over move_*.
func _test_baked_drive_steer_axes() -> bool:
	var frame := SeatInputRouter.route(
		_raw({
			"move_forward": 0.0,
			"move_left": 0.0,
			"drive": 0.75,
			"steer": -0.5,
		}),
		_policy(),
		false
	)
	if absf(frame.drive_command - 0.75) > 0.001:
		return _fail("baked drive axis ignored: %s" % frame.drive_command)
	if absf(frame.steering_command - (-0.5)) > 0.001:
		return _fail("baked steer axis ignored: %s" % frame.steering_command)
	return true
