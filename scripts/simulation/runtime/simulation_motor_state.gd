class_name SimulationMotorState
extends RefCounted

const _SCRIPT := preload(
	"res://scripts/simulation/runtime/simulation_motor_state.gd"
)

const PISTON_DRIVE_PORT := "piston_drive"
const PISTON_CARRIAGE_PORT := "piston_carriage"
const ROTOR_DRIVE_PORT := "rotor_drive"
const ROTOR_TOP_PORT := "rotor_top"

const OVERLOAD_ERROR_M := 0.02
const OVERLOAD_VELOCITY_MPS := 0.003
const STATUS_POSITION_PROGRESS_M := 0.00003
const STUCK_FORCE_FRACTION := 0.1
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
var extend_velocity_mps: float = 0.25
var retract_velocity_mps: float = 0.25
var force_limit_n: float = 5000.0
var lower_limit_m: float = 0.0
var upper_limit_m: float = 2.0
var stiffness_n_per_m: float = 8000.0
var damping_n_s_per_m: float = 400.0
var power_draw_w: float = 1500.0
var enabled: bool = true
var overload_policy: OverloadPolicy = OverloadPolicy.STOP
## Angular motor (Rotor): positions are rad, velocities rad/s, force N·m.
var angular: bool = false
## Continuous rotation: travel limits unused, observed angle wraps (-PI, PI].
var continuous: bool = false

var observed_position_m: float = 0.0
var observed_velocity_mps: float = 0.0
var applied_force_n: float = 0.0
var status: Status = Status.IDLE
var saturation_time_s: float = 0.0
var stuck_time_s: float = 0.0
var force_saturated: bool = false
var status_reference_position_m: float = 0.0


static func from_piston_definition(definition: PistonDefinition) -> SimulationMotorState:
	var motor: SimulationMotorState = _SCRIPT.new()
	motor.target_position_m = definition.retracted_offset_m
	motor.observed_position_m = definition.retracted_offset_m
	motor.status_reference_position_m = definition.retracted_offset_m
	var extend_v := definition.extend_velocity_mps
	var retract_v := definition.retract_velocity_mps
	if extend_v <= 0.0 and retract_v <= 0.0:
		extend_v = definition.default_speed_limit_mps
		retract_v = definition.default_speed_limit_mps
	motor.extend_velocity_mps = extend_v
	motor.retract_velocity_mps = retract_v
	motor.speed_limit_mps = maxf(extend_v, retract_v)
	motor.force_limit_n = definition.force_limit_n
	motor.lower_limit_m = definition.lower_limit_m
	motor.upper_limit_m = definition.upper_limit_m
	motor.stiffness_n_per_m = definition.stiffness_n_per_m
	motor.damping_n_s_per_m = definition.damping_n_s_per_m
	motor.power_draw_w = definition.power_draw_w
	motor.overload_policy = definition.overload_policy
	return motor


static func from_rotor_definition(definition: RotorDefinition) -> SimulationMotorState:
	var motor: SimulationMotorState = _SCRIPT.new()
	motor.angular = true
	motor.continuous = true
	motor.target_position_m = 0.0
	motor.observed_position_m = 0.0
	motor.status_reference_position_m = 0.0
	var forward_v := definition.forward_velocity_rad_s
	var reverse_v := definition.reverse_velocity_rad_s
	if forward_v <= 0.0 and reverse_v <= 0.0:
		forward_v = definition.default_speed_limit_rad_s
		reverse_v = definition.default_speed_limit_rad_s
	motor.extend_velocity_mps = forward_v
	motor.retract_velocity_mps = reverse_v
	motor.speed_limit_mps = maxf(forward_v, reverse_v)
	motor.force_limit_n = definition.torque_limit_nm
	motor.lower_limit_m = 0.0
	motor.upper_limit_m = 0.0
	motor.stiffness_n_per_m = 0.0
	motor.damping_n_s_per_m = definition.damping_nm_s_per_rad
	motor.power_draw_w = definition.power_draw_w
	motor.overload_policy = definition.overload_policy
	return motor


static func wrap_angle(angle_rad: float) -> float:
	var wrapped := wrapf(angle_rad, -PI, PI)
	if wrapped == -PI:
		wrapped = PI
	return wrapped


func clamp_target_position() -> float:
	if continuous:
		return wrap_angle(target_position_m)
	return clampf(target_position_m, lower_limit_m, upper_limit_m)


func velocity_limit_for_sign(sign: float) -> float:
	return extend_velocity_mps if sign >= 0.0 else retract_velocity_mps


func clamp_target_velocity() -> float:
	if target_velocity_mps >= 0.0:
		return clampf(target_velocity_mps, 0.0, extend_velocity_mps)
	return clampf(target_velocity_mps, -retract_velocity_mps, 0.0)


func clamp_observed_position() -> float:
	if continuous:
		return wrap_angle(observed_position_m)
	return clampf(observed_position_m, lower_limit_m, upper_limit_m)


func position_error() -> float:
	if continuous:
		return wrap_angle(clamp_target_position() - observed_position_m)
	return clamp_target_position() - observed_position_m


func position_progress_from(reference_position: float) -> float:
	if continuous:
		return absf(wrap_angle(observed_position_m - reference_position))
	return absf(observed_position_m - reference_position)


func is_at_lower_limit() -> bool:
	if continuous:
		return false
	return observed_position_m <= lower_limit_m + LIMIT_EPSILON_M


func is_at_upper_limit() -> bool:
	if continuous:
		return false
	return observed_position_m >= upper_limit_m - LIMIT_EPSILON_M


func to_dict() -> Dictionary:
	return {
		"control_mode": control_mode,
		"target_position_m": target_position_m,
		"target_velocity_mps": target_velocity_mps,
		"speed_limit_mps": speed_limit_mps,
		"extend_velocity_mps": extend_velocity_mps,
		"retract_velocity_mps": retract_velocity_mps,
		"force_limit_n": force_limit_n,
		"lower_limit_m": lower_limit_m,
		"upper_limit_m": upper_limit_m,
		"stiffness_n_per_m": stiffness_n_per_m,
		"damping_n_s_per_m": damping_n_s_per_m,
		"power_draw_w": power_draw_w,
		"enabled": enabled,
		"overload_policy": overload_policy,
		"angular": angular,
		"continuous": continuous,
		"observed_position_m": observed_position_m,
		"observed_velocity_mps": observed_velocity_mps,
		"applied_force_n": applied_force_n,
		"status": status,
		"saturation_time_s": saturation_time_s,
		"stuck_time_s": stuck_time_s,
		"force_saturated": force_saturated,
		"status_reference_position_m": status_reference_position_m,
	}


static func from_dict(data: Dictionary) -> SimulationMotorState:
	var motor: SimulationMotorState = _SCRIPT.new()
	motor.control_mode = int(data.get("control_mode", ControlMode.STOP))
	motor.target_position_m = float(data.get("target_position_m", 0.0))
	motor.target_velocity_mps = float(data.get("target_velocity_mps", 0.0))
	motor.speed_limit_mps = float(data.get("speed_limit_mps", 0.25))
	motor.extend_velocity_mps = float(
		data.get("extend_velocity_mps", motor.speed_limit_mps)
	)
	motor.retract_velocity_mps = float(
		data.get("retract_velocity_mps", motor.speed_limit_mps)
	)
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
	motor.angular = bool(data.get("angular", false))
	motor.continuous = bool(data.get("continuous", false))
	motor.observed_position_m = float(data.get("observed_position_m", 0.0))
	motor.observed_velocity_mps = float(
		data.get("observed_velocity_mps", 0.0)
	)
	motor.applied_force_n = float(data.get("applied_force_n", 0.0))
	motor.status = int(data.get("status", Status.IDLE))
	motor.saturation_time_s = float(data.get("saturation_time_s", 0.0))
	motor.stuck_time_s = float(data.get("stuck_time_s", 0.0))
	motor.force_saturated = bool(data.get("force_saturated", false))
	motor.status_reference_position_m = float(
		data.get("status_reference_position_m", motor.observed_position_m)
	)
	motor.observed_position_m = motor.clamp_observed_position()
	return motor


func duplicate_state() -> SimulationMotorState:
	return from_dict(to_dict())
