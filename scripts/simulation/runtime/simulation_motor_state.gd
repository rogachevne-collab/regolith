class_name SimulationMotorState
extends RefCounted

const _SCRIPT := preload(
	"res://scripts/simulation/runtime/simulation_motor_state.gd"
)

const PISTON_DRIVE_PORT := "piston_drive"
const PISTON_CARRIAGE_PORT := "piston_carriage"

const OVERLOAD_ERROR_M := 0.02
const OVERLOAD_VELOCITY_MPS := 0.01
const LIMIT_EPSILON_M := 0.005
const OVERLOAD_SATURATION_S := 0.5
const STUCK_SATURATION_S := 0.5

enum ControlMode {
	STOP,
	POSITION,
	VELOCITY,
}

enum Status {
	IDLE,
	MOVING,
	JOINT_LIMIT,
	STUCK,
	OVERLOADED,
	NO_POWER,
	ELEMENT_INCOMPLETE,
}

enum OverloadPolicy {
	STOP,
}

var control_mode: ControlMode = ControlMode.STOP
var target_position_m: float = 0.0
var target_velocity_mps: float = 0.0
var speed_limit_mps: float = 0.25
var force_limit_n: float = 5000.0
var lower_limit_m: float = 0.0
var upper_limit_m: float = 2.0
var stiffness_n_per_m: float = 8000.0
var damping_n_s_per_m: float = 400.0
var power_draw_w: float = 1500.0
var enabled: bool = true
var overload_policy: OverloadPolicy = OverloadPolicy.STOP

var observed_position_m: float = 0.0
var observed_velocity_mps: float = 0.0
var applied_force_n: float = 0.0
var status: Status = Status.IDLE
var saturation_time_s: float = 0.0
var stuck_time_s: float = 0.0
var force_saturated: bool = false


static func from_piston_definition(definition: PistonDefinition) -> SimulationMotorState:
	var motor: SimulationMotorState = _SCRIPT.new()
	motor.target_position_m = definition.retracted_offset_m
	motor.observed_position_m = definition.retracted_offset_m
	motor.speed_limit_mps = definition.default_speed_limit_mps
	motor.force_limit_n = definition.force_limit_n
	motor.lower_limit_m = definition.lower_limit_m
	motor.upper_limit_m = definition.upper_limit_m
	motor.stiffness_n_per_m = definition.stiffness_n_per_m
	motor.damping_n_s_per_m = definition.damping_n_s_per_m
	motor.power_draw_w = definition.power_draw_w
	motor.overload_policy = definition.overload_policy
	return motor


func clamp_target_position() -> float:
	return clampf(target_position_m, lower_limit_m, upper_limit_m)


func clamp_target_velocity() -> float:
	return clampf(target_velocity_mps, -speed_limit_mps, speed_limit_mps)


func clamp_observed_position() -> float:
	return clampf(observed_position_m, lower_limit_m, upper_limit_m)


func position_error() -> float:
	return clamp_target_position() - observed_position_m


func is_at_lower_limit() -> bool:
	return observed_position_m <= lower_limit_m + LIMIT_EPSILON_M


func is_at_upper_limit() -> bool:
	return observed_position_m >= upper_limit_m - LIMIT_EPSILON_M


func to_dict() -> Dictionary:
	return {
		"control_mode": control_mode,
		"target_position_m": target_position_m,
		"target_velocity_mps": target_velocity_mps,
		"speed_limit_mps": speed_limit_mps,
		"force_limit_n": force_limit_n,
		"lower_limit_m": lower_limit_m,
		"upper_limit_m": upper_limit_m,
		"stiffness_n_per_m": stiffness_n_per_m,
		"damping_n_s_per_m": damping_n_s_per_m,
		"power_draw_w": power_draw_w,
		"enabled": enabled,
		"overload_policy": overload_policy,
		"observed_position_m": observed_position_m,
		"observed_velocity_mps": observed_velocity_mps,
		"applied_force_n": applied_force_n,
		"status": status,
		"saturation_time_s": saturation_time_s,
		"stuck_time_s": stuck_time_s,
		"force_saturated": force_saturated,
	}


static func from_dict(data: Dictionary) -> SimulationMotorState:
	var motor: SimulationMotorState = _SCRIPT.new()
	motor.control_mode = int(data.get("control_mode", ControlMode.STOP))
	motor.target_position_m = float(data.get("target_position_m", 0.0))
	motor.target_velocity_mps = float(data.get("target_velocity_mps", 0.0))
	motor.speed_limit_mps = float(data.get("speed_limit_mps", 0.25))
	motor.force_limit_n = float(data.get("force_limit_n", 5000.0))
	motor.lower_limit_m = float(data.get("lower_limit_m", 0.0))
	motor.upper_limit_m = float(data.get("upper_limit_m", 2.0))
	motor.stiffness_n_per_m = float(data.get("stiffness_n_per_m", 8000.0))
	motor.damping_n_s_per_m = float(data.get("damping_n_s_per_m", 400.0))
	motor.power_draw_w = float(data.get("power_draw_w", 1500.0))
	motor.enabled = bool(data.get("enabled", true))
	motor.overload_policy = int(
		data.get("overload_policy", OverloadPolicy.STOP)
	)
	motor.observed_position_m = float(data.get("observed_position_m", 0.0))
	motor.observed_velocity_mps = float(
		data.get("observed_velocity_mps", 0.0)
	)
	motor.applied_force_n = float(data.get("applied_force_n", 0.0))
	motor.status = int(data.get("status", Status.IDLE))
	motor.saturation_time_s = float(data.get("saturation_time_s", 0.0))
	motor.stuck_time_s = float(data.get("stuck_time_s", 0.0))
	motor.force_saturated = bool(data.get("force_saturated", false))
	motor.observed_position_m = motor.clamp_observed_position()
	return motor


func duplicate_state() -> SimulationMotorState:
	return from_dict(to_dict())
