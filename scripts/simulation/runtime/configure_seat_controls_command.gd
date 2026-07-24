class_name ConfigureSeatControlsCommand
extends RefCounted
## Per-ControlSeat routing policy mutation (semantic seat control frame).
## Optional fields: omit a channel to leave it unchanged.

var seat_element_id: int = 0
## Variant bool or null (unset).
var control_wheels = null
var control_thrusters = null
var control_gyros = null


func kind() -> StringName:
	return &"configure_seat_controls"
