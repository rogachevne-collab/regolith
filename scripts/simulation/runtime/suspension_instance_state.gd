class_name SuspensionInstanceState
extends RefCounted

var travel_m: float = -1.0
var spring_stiffness_n_per_m: float = -1.0
var spring_damping_n_s_per_m: float = -1.0


func duplicate_state() -> SuspensionInstanceState:
	var copy := SuspensionInstanceState.new()
	copy.travel_m = travel_m
	copy.spring_stiffness_n_per_m = spring_stiffness_n_per_m
	copy.spring_damping_n_s_per_m = spring_damping_n_s_per_m
	return copy


func to_dict() -> Dictionary:
	return {
		"travel_m": travel_m,
		"spring_stiffness_n_per_m": spring_stiffness_n_per_m,
		"spring_damping_n_s_per_m": spring_damping_n_s_per_m,
	}


static func from_dict(data: Dictionary) -> SuspensionInstanceState:
	var state := SuspensionInstanceState.new()
	state.travel_m = float(data.get("travel_m", -1.0))
	state.spring_stiffness_n_per_m = float(
		data.get("spring_stiffness_n_per_m", -1.0)
	)
	state.spring_damping_n_s_per_m = float(
		data.get("spring_damping_n_s_per_m", -1.0)
	)
	return state
