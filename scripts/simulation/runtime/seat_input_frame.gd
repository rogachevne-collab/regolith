class_name SeatInputFrame
extends RefCounted
## Ephemeral continuous driver commands for one physics tick (CONTROL-AXES-V0).
## Not serialized. Physical key names never appear here — only semantic channels
## and effective seat-route gates for consumers.

var drive_command: float = 0.0
var brake_command: float = 0.0
var steering_command: float = 0.0
var translate_command: Vector3 = Vector3.ZERO
var pitch_command: float = 0.0
var yaw_command: float = 0.0
var roll_command: float = 0.0
## Effective consumer gates from the active seat's routing policy this tick.
var wheels_route_enabled: bool = false
var thrusters_route_enabled: bool = false
var gyros_route_enabled: bool = false


static func zero() -> SeatInputFrame:
	return SeatInputFrame.new()
