class_name ActuatorSimulationService
extends RefCounted


static func apply_set_actuator_target(
	world: SimulationWorld,
	command: SetActuatorTargetCommand
) -> Dictionary:
	if world == null or command == null:
		return {"status": &"failed", "reason": &"not_ready"}
	var joint := world.get_joint(command.joint_id)
	if joint == null or joint.kind != SimulationJoint.Kind.PISTON:
		return {"status": &"failed", "reason": &"invalid_reference"}
	if joint.motor == null:
		return {"status": &"failed", "reason": &"invalid_reference"}
	var base_element := world.get_element(joint.element_a_id)
	if base_element == null or not base_element.is_operational():
		return {
			"status": &"failed",
			"reason": &"element_incomplete",
			"joint_id": joint.joint_id,
		}

	var motor := joint.motor
	motor.enabled = command.enabled
	motor.control_mode = command.mode
	if command.speed_limit_mps >= 0.0:
		motor.speed_limit_mps = command.speed_limit_mps
	match command.mode:
		SimulationMotorState.ControlMode.POSITION:
			motor.target_position_m = command.target_position_m
			motor.target_velocity_mps = 0.0
		SimulationMotorState.ControlMode.VELOCITY:
			motor.target_velocity_mps = command.target_velocity_mps
		_:
			motor.target_position_m = motor.observed_position_m
			motor.target_velocity_mps = 0.0
	motor.saturation_time_s = 0.0
	motor.stuck_time_s = 0.0
	motor.force_saturated = false
	if motor.status == SimulationMotorState.Status.OVERLOADED:
		motor.status = SimulationMotorState.Status.IDLE
	if motor.status == SimulationMotorState.Status.STUCK:
		motor.status = SimulationMotorState.Status.IDLE
	_update_joint_status(world, joint)
	return {
		"status": &"ok",
		"reason": &"ok",
		"joint_id": joint.joint_id,
		"status_name": _status_name(joint.motor.status),
	}


static func sync_observation(
	joint: SimulationJoint,
	position_m: float,
	velocity_mps: float,
	applied_force_n: float,
	force_saturated: bool
) -> void:
	if joint == null or joint.motor == null:
		return
	var motor := joint.motor
	motor.observed_position_m = clampf(
		position_m,
		motor.lower_limit_m,
		motor.upper_limit_m
	)
	motor.observed_velocity_mps = velocity_mps
	motor.applied_force_n = applied_force_n
	motor.force_saturated = force_saturated


static func tick_joint(
	world: SimulationWorld,
	joint: SimulationJoint,
	delta_s: float
) -> void:
	if joint == null or joint.motor == null or delta_s <= 0.0:
		return
	_update_joint_status(world, joint, delta_s)


static func power_demand_w(joint: SimulationJoint) -> float:
	if joint == null or joint.motor == null or not joint.motor.enabled:
		return 0.0
	return joint.motor.power_draw_w


static func _update_joint_status(
	world: SimulationWorld,
	joint: SimulationJoint,
	delta_s: float = 0.0
) -> void:
	var motor := joint.motor
	var base_element := world.get_element(joint.element_a_id)
	if base_element == null or not base_element.is_operational():
		motor.status = SimulationMotorState.Status.ELEMENT_INCOMPLETE
		return
	if not _is_powered(world, base_element):
		motor.status = SimulationMotorState.Status.NO_POWER
		motor.saturation_time_s = 0.0
		motor.stuck_time_s = 0.0
		return
	if not motor.enabled:
		motor.status = SimulationMotorState.Status.IDLE
		motor.saturation_time_s = 0.0
		motor.stuck_time_s = 0.0
		return
	if motor.status == SimulationMotorState.Status.OVERLOADED:
		return
	if motor.status == SimulationMotorState.Status.STUCK:
		return

	var error := absf(motor.position_error())
	var moving := (
		absf(motor.observed_velocity_mps)
		> SimulationMotorState.OVERLOAD_VELOCITY_MPS
	)
	var pushing_outward := _pushing_outward(motor)
	if (
		motor.control_mode != SimulationMotorState.ControlMode.STOP
		and pushing_outward
		and (
			(motor.is_at_lower_limit() and motor.target_position_m < motor.observed_position_m - 0.0001)
			or (
				motor.is_at_upper_limit()
				and motor.target_position_m > motor.observed_position_m + 0.0001
			)
			or (
				motor.control_mode == SimulationMotorState.ControlMode.VELOCITY
				and (
					(motor.is_at_lower_limit() and motor.target_velocity_mps < 0.0)
					or (motor.is_at_upper_limit() and motor.target_velocity_mps > 0.0)
				)
			)
		)
	):
		motor.status = SimulationMotorState.Status.JOINT_LIMIT
		motor.saturation_time_s = 0.0
		motor.stuck_time_s = 0.0
		return

	var tracking := (
		motor.control_mode == SimulationMotorState.ControlMode.POSITION
		and error > SimulationMotorState.OVERLOAD_ERROR_M
	) or (
		motor.control_mode == SimulationMotorState.ControlMode.VELOCITY
		and absf(motor.target_velocity_mps) > 0.0001
	)
	if tracking and not moving:
		if motor.force_saturated:
			motor.saturation_time_s += delta_s
			motor.stuck_time_s = 0.0
			if motor.saturation_time_s >= SimulationMotorState.OVERLOAD_SATURATION_S:
				motor.status = SimulationMotorState.Status.OVERLOADED
				motor.control_mode = SimulationMotorState.ControlMode.STOP
				motor.target_position_m = motor.observed_position_m
				motor.target_velocity_mps = 0.0
				return
		else:
			motor.stuck_time_s += delta_s
			motor.saturation_time_s = 0.0
			if motor.stuck_time_s >= SimulationMotorState.STUCK_SATURATION_S:
				motor.status = SimulationMotorState.Status.STUCK
				return
	else:
		if motor.status != SimulationMotorState.Status.OVERLOADED:
			motor.saturation_time_s = 0.0
			motor.stuck_time_s = 0.0

	if moving:
		motor.status = SimulationMotorState.Status.MOVING
	elif motor.control_mode == SimulationMotorState.ControlMode.STOP:
		if motor.status != SimulationMotorState.Status.OVERLOADED:
			motor.status = SimulationMotorState.Status.IDLE
	else:
		motor.status = SimulationMotorState.Status.IDLE


static func _pushing_outward(motor: SimulationMotorState) -> bool:
	match motor.control_mode:
		SimulationMotorState.ControlMode.POSITION:
			return absf(motor.position_error()) > 0.0001
		SimulationMotorState.ControlMode.VELOCITY:
			return absf(motor.target_velocity_mps) > 0.0001
	return false


static func _is_powered(
	world: SimulationWorld,
	element: SimulationElement
) -> bool:
	var runtime := world.get_industry_element_runtime(element.element_id)
	if runtime == null:
		return false
	return runtime.powered and runtime.machine_enabled


static func status_name_for_motor(motor: SimulationMotorState) -> StringName:
	if motor == null:
		return &"idle"
	return _status_name(motor.status)


static func _status_name(status: SimulationMotorState.Status) -> StringName:
	match status:
		SimulationMotorState.Status.ELEMENT_INCOMPLETE:
			return &"element_incomplete"
		SimulationMotorState.Status.NO_POWER:
			return &"no_power"
		SimulationMotorState.Status.OVERLOADED:
			return &"overloaded"
		SimulationMotorState.Status.STUCK:
			return &"stuck"
		SimulationMotorState.Status.JOINT_LIMIT:
			return &"joint_limit"
		SimulationMotorState.Status.MOVING:
			return &"moving"
	return &"idle"
