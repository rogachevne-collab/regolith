class_name SeatInputRouter
extends RefCounted
## Pure semantic seat input router (CONTROL-AXES-V0).
## Maps raw action strengths + per-seat policy + latched parking brake into a
## typed SeatInputFrame. Does not know assembly capabilities or Godot Input.

## raw keys (floats unless noted):
##   move_forward, move_back, move_left, move_right,
##   space (normalized jump∪move_up), move_down,
##   look_x, look_y, roll_left, roll_right,
##   zero_frame (bool) — modal / seat-loss: clear continuous pilot commands.


static func route(
	raw: Dictionary,
	policy: SeatControlState,
	parking_brake: bool
) -> SeatInputFrame:
	var frame := SeatInputFrame.new()
	if policy == null:
		policy = SeatControlState.new()
	frame.wheels_route_enabled = policy.control_wheels
	frame.thrusters_route_enabled = policy.control_thrusters
	frame.gyros_route_enabled = policy.control_gyros
	if bool(raw.get("zero_frame", false)):
		return frame

	var forward := clampf(float(raw.get("move_forward", 0.0)), 0.0, 1.0)
	var back := clampf(float(raw.get("move_back", 0.0)), 0.0, 1.0)
	var left := clampf(float(raw.get("move_left", 0.0)), 0.0, 1.0)
	var right := clampf(float(raw.get("move_right", 0.0)), 0.0, 1.0)
	var space := clampf(float(raw.get("space", 0.0)), 0.0, 1.0)
	var down := clampf(float(raw.get("move_down", 0.0)), 0.0, 1.0)
	var look_x := clampf(float(raw.get("look_x", 0.0)), -1.0, 1.0)
	var look_y := clampf(float(raw.get("look_y", 0.0)), -1.0, 1.0)
	var roll_left := clampf(float(raw.get("roll_left", 0.0)), 0.0, 1.0)
	var roll_right := clampf(float(raw.get("roll_right", 0.0)), 0.0, 1.0)

	# Latched assembly-wide parking brake is a safety hold: always publish
	# brake=1 / drive=steer=0 even when Control Wheels is OFF (pilot channels
	# gated). Service brake (Space) only when control_wheels.
	if parking_brake:
		frame.drive_command = 0.0
		frame.steering_command = 0.0
		frame.brake_command = 1.0
	elif policy.control_wheels:
		frame.drive_command = clampf(forward - back, -1.0, 1.0)
		# Match legacy Input.get_axis(move_right, move_left).
		frame.steering_command = clampf(left - right, -1.0, 1.0)
		frame.brake_command = space
	if policy.control_thrusters:
		# Seat forward is body −Z: move_forward → −z translate.
		frame.translate_command = Vector3(
			clampf(right - left, -1.0, 1.0),
			clampf(space - down, -1.0, 1.0),
			clampf(back - forward, -1.0, 1.0)
		)
	if policy.control_gyros:
		var roll := clampf(roll_right - roll_left, -1.0, 1.0)
		# −Z forward: pitch up = +X torque (mouse up), yaw right = −Y, roll E = −Z.
		frame.pitch_command = clampf(-look_y, -1.0, 1.0)
		frame.yaw_command = clampf(-look_x, -1.0, 1.0)
		frame.roll_command = clampf(-roll, -1.0, 1.0)
	return frame
