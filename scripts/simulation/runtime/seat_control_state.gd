class_name SeatControlState
extends RefCounted
## Per-ControlSeat routing policy (semantic seat control frame).
## Belongs to the seat element, not the assembly — same side-table pattern as
## ActionBarState. Defaults keep legacy saves / new seats fully routed.

## Shared default instance for read-only paths (R9). Never mutate.
static var _DEFAULTS: SeatControlState = null

var control_wheels: bool = true
var control_thrusters: bool = true
var control_gyros: bool = true


## Immutable defaults ref — no alloc; callers must not mutate.
static func defaults_ref() -> SeatControlState:
	if _DEFAULTS == null:
		_DEFAULTS = SeatControlState.new()
	return _DEFAULTS


static func flag_of(state: SeatControlState, key: String) -> bool:
	if state == null:
		state = defaults_ref()
	match key:
		"control_wheels":
			return state.control_wheels
		"control_thrusters":
			return state.control_thrusters
		"control_gyros":
			return state.control_gyros
	return true


func duplicate_state() -> SeatControlState:
	var copy := SeatControlState.new()
	copy.control_wheels = control_wheels
	copy.control_thrusters = control_thrusters
	copy.control_gyros = control_gyros
	return copy


func to_dict() -> Dictionary:
	return {
		"control_wheels": control_wheels,
		"control_thrusters": control_thrusters,
		"control_gyros": control_gyros,
	}


static func from_dict(data: Dictionary) -> SeatControlState:
	var state := SeatControlState.new()
	if data == null or data.is_empty():
		return state
	state.control_wheels = bool(data.get("control_wheels", true))
	state.control_thrusters = bool(data.get("control_thrusters", true))
	state.control_gyros = bool(data.get("control_gyros", true))
	return state
