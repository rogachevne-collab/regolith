class_name RotorProjectionUtil
extends RefCounted

const POSITION_ARRIVE_EPSILON_RAD := 0.005
const STOP_BRAKE_DAMPING_SCALE := 3.0
const VELOCITY_RESPONSE_TIME_S := 0.25
const MIN_INERTIA_KG_M2 := 0.001


static func rotor_axis_assembly_local(
	base_element: SimulationElement,
	definition: RotorDefinition
) -> Vector3:
	var axis_cell: Vector3i = OrientationUtil.rotate_cell(
		definition.top_axis_offset_cell(),
		base_element.orientation_index
	)
	return Vector3(axis_cell).normalized()


static func configure_hinge_joint(joint: Generic6DOFJoint3D) -> void:
	for axis: String in ["x", "y", "z"]:
		joint.set("linear_limit_%s/enabled" % axis, true)
		joint.set("linear_limit_%s/lower_distance" % axis, 0.0)
		joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
	for axis: String in ["x", "z"]:
		joint.set("angular_limit_%s/enabled" % axis, true)
		joint.set("angular_limit_%s/lower_angle" % axis, 0.0)
		joint.set("angular_limit_%s/upper_angle" % axis, 0.0)
	# Continuous rotation: the rotor axis stays unconstrained.
	joint.set("angular_limit_y/enabled", false)


static func measure_angular_state(
	base_body: PhysicsBody3D,
	head_body: PhysicsBody3D,
	axis_world: Vector3
) -> Dictionary:
	var axis := axis_world.normalized()
	var relative: Basis = (
		head_body.global_transform.basis
		* base_body.global_transform.basis.inverse()
	)
	var quat := relative.get_rotation_quaternion()
	var sin_half := Vector3(quat.x, quat.y, quat.z).dot(axis)
	var angle_rad := SimulationMotorState.wrap_angle(
		2.0 * atan2(sin_half, quat.w)
	)
	var base_omega := Vector3.ZERO
	if base_body is RigidBody3D:
		base_omega = (base_body as RigidBody3D).angular_velocity
	var head_omega := Vector3.ZERO
	if head_body is RigidBody3D:
		head_omega = (head_body as RigidBody3D).angular_velocity
	return {
		"angle_rad": angle_rad,
		"relative_velocity_rad_s": (head_omega - base_omega).dot(axis),
	}


static func is_dynamic_rigid(body: PhysicsBody3D) -> bool:
	return body is RigidBody3D and not (body as RigidBody3D).freeze


static func inertia_about_axis(
	body: PhysicsBody3D,
	axis_world: Vector3
) -> float:
	if not body is RigidBody3D:
		return MIN_INERTIA_KG_M2
	var axis := axis_world.normalized()
	var inverse_inertia: Basis = (
		(body as RigidBody3D).get_inverse_inertia_tensor()
	)
	var inverse_about_axis := axis.dot(inverse_inertia * axis)
	if inverse_about_axis <= 0.000001:
		return MIN_INERTIA_KG_M2
	return maxf(1.0 / inverse_about_axis, MIN_INERTIA_KG_M2)


static func reduced_inertia_about_axis(
	head_body: PhysicsBody3D,
	base_body: PhysicsBody3D,
	axis_world: Vector3
) -> float:
	var top_inertia := inertia_about_axis(head_body, axis_world)
	if not is_dynamic_rigid(base_body):
		return top_inertia
	var base_inertia := inertia_about_axis(base_body, axis_world)
	var inv_sum := (1.0 / top_inertia) + (1.0 / base_inertia)
	if inv_sum <= 0.000001:
		return MIN_INERTIA_KG_M2
	return maxf(1.0 / inv_sum, MIN_INERTIA_KG_M2)


static func desired_angular_velocity_rad_s(motor: SimulationMotorState) -> float:
	match motor.control_mode:
		SimulationMotorState.ControlMode.POSITION:
			var error := motor.position_error()
			if absf(error) <= POSITION_ARRIVE_EPSILON_RAD:
				return 0.0
			var direction := signf(error)
			return direction * motor.velocity_limit_for_sign(direction)
		SimulationMotorState.ControlMode.VELOCITY:
			return motor.clamp_target_velocity()
	return 0.0


static func compute_motor_torque_scalar(
	motor: SimulationMotorState,
	observed_velocity_rad_s: float,
	powered: bool,
	effective_inertia_kg_m2: float
) -> Dictionary:
	if motor == null or not powered or not motor.enabled:
		return {"torque_nm": 0.0, "saturated": false}
	if motor.status == SimulationMotorState.Status.OVERLOADED:
		return {"torque_nm": 0.0, "saturated": false}
	var stop_mode := (
		motor.control_mode == SimulationMotorState.ControlMode.STOP
	)
	var desired_velocity := 0.0
	if not stop_mode:
		desired_velocity = desired_angular_velocity_rad_s(motor)
	var response_time := VELOCITY_RESPONSE_TIME_S
	if stop_mode:
		response_time /= STOP_BRAKE_DAMPING_SCALE
	var effective_inertia := maxf(
		effective_inertia_kg_m2,
		MIN_INERTIA_KG_M2
	)
	var velocity_error := desired_velocity - observed_velocity_rad_s
	var ideal_torque_nm := (
		effective_inertia * velocity_error / maxf(response_time, 0.0001)
	)
	if stop_mode:
		ideal_torque_nm -= (
			motor.damping_n_s_per_m * observed_velocity_rad_s
		)
	var saturated := absf(ideal_torque_nm) >= motor.force_limit_n - 0.001
	return {
		"torque_nm": clampf(
			ideal_torque_nm,
			-motor.force_limit_n,
			motor.force_limit_n
		),
		"saturated": saturated,
	}
