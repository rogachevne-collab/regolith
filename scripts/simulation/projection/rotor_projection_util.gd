class_name RotorProjectionUtil
extends RefCounted

const POSITION_ARRIVE_EPSILON_RAD := 0.005
const STOP_BRAKE_DAMPING_SCALE := 3.0
const VELOCITY_RESPONSE_TIME_S := 0.25
const MIN_INERTIA_KG_M2 := 0.001
## Taper commanded torque as a bounded (non-continuous) hinge approaches a
## hard stop in the commanded direction. Keeps JOINT_LIMIT status reachable
## while avoiding full torque_limit vs Jolt constraint explosions.
const LIMIT_TAPER_RAD := 0.02


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
	update_angular_motor(joint, "y", 0.0, 0.0)


## Godot Generic6DOFJoint3D angular motors are clockwise when looking along
## the axis; Jolt's native CCW is flipped in the engine to match. Our sim
## angles / reconstruct use the right-hand rule (CCW), so the velocity written
## here is negated. See modules/jolt_physics/.../jolt_generic_6dof_joint_3d.cpp
## `_update_motor_velocity` ("Jolt is CCW but Godot is CW").
const GODOT_ANGULAR_MOTOR_SIGN := -1.0


## Solver-side angular drive (rotor spins about joint Y, hinge bends about
## joint X). Cheap to call per tick — never touches limits or springs.
## `target_velocity_rad_s` is right-hand / sim-space.
static func update_angular_motor(
	joint: Generic6DOFJoint3D,
	axis_name: String,
	target_velocity_rad_s: float,
	torque_limit_nm: float
) -> void:
	joint.set("angular_motor_%s/enabled" % axis_name, true)
	joint.set(
		"angular_motor_%s/target_velocity" % axis_name,
		GODOT_ANGULAR_MOTOR_SIGN * target_velocity_rad_s
	)
	joint.set(
		"angular_motor_%s/force_limit" % axis_name,
		maxf(torque_limit_nm, 0.0)
	)


## Target velocity for the solver motor; STOP and overload brake at zero.
static func drive_velocity_rad_s(
	motor: SimulationMotorState,
	active: bool
) -> float:
	if motor == null or not active or not motor.enabled:
		return 0.0
	if motor.status == SimulationMotorState.Status.OVERLOADED:
		return 0.0
	if motor.control_mode == SimulationMotorState.ControlMode.STOP:
		return 0.0
	return desired_angular_velocity_rad_s(motor)


## Solver-motor inputs for the physics tick. Bounded hinges taper the
## torque limit (and zero velocity at the stop) so full force_limit never
## fights Jolt hard angle constraints — the 7dc1046 anti-explosion rule,
## kept after the 245e434 move from apply_torque to angular_motor.
## Pass the freshly measured home-relative angle as `observed_override_m`.
static func solver_angular_drive(
	motor: SimulationMotorState,
	powered: bool,
	observed_override_m: float = NAN
) -> Dictionary:
	var velocity := drive_velocity_rad_s(motor, powered)
	if motor == null:
		return {"velocity_rad_s": 0.0, "torque_limit_nm": 0.0}
	var taper := near_limit_torque_scale(motor, observed_override_m)
	var limit_nm := motor.force_limit_n * taper if powered else 0.0
	if taper <= 0.0:
		velocity = 0.0
	return {
		"velocity_rad_s": velocity,
		"torque_limit_nm": limit_nm,
	}


## Estimated applied torque for the status machine / overlay: gravity hold
## torque of the head group about the joint axis while tracking, torque limit
## when the motor visibly cannot reach its commanded speed.
static func estimate_angular_drive_effort(
	motor: SimulationMotorState,
	desired_velocity_rad_s: float,
	observed_velocity_rad_s: float,
	head_body: PhysicsBody3D,
	anchor_world: Vector3,
	axis_world: Vector3,
	gravity: Vector3
) -> Dictionary:
	if motor == null:
		return {"torque_nm": 0.0, "saturated": false}
	var hold_abs := 0.0
	if head_body is RigidBody3D:
		var rigid := head_body as RigidBody3D
		var com_world: Vector3 = (
			rigid.global_transform * rigid.center_of_mass
		)
		hold_abs = absf(
			((com_world - anchor_world).cross(rigid.mass * gravity))
			.dot(axis_world.normalized())
		)
	var limit := maxf(motor.force_limit_n, 0.0)
	var commanded := absf(desired_velocity_rad_s) > 0.0005
	var tracking_broken := commanded and (
		observed_velocity_rad_s * desired_velocity_rad_s <= 0.0
		or absf(observed_velocity_rad_s)
		< absf(desired_velocity_rad_s)
		* PistonProjectionUtil.SATURATION_TRACKING_FRACTION
	)
	var saturated := tracking_broken or hold_abs >= limit
	return {
		"torque_nm": limit if saturated else minf(hold_abs, limit),
		"hold_nm": minf(hold_abs, limit),
		"saturated": saturated,
	}


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


## `observed_override_m` lets the physics tick taper against the freshly
## measured angle before observation sync (NAN → motor.observed_position_m).
static func near_limit_torque_scale(
	motor: SimulationMotorState,
	observed_override_m: float = NAN
) -> float:
	if motor == null or motor.continuous or not motor.angular:
		return 1.0
	if motor.control_mode == SimulationMotorState.ControlMode.STOP:
		return 1.0
	var position := (
		observed_override_m
		if not is_nan(observed_override_m)
		else motor.observed_position_m
	)
	var toward_upper := false
	var toward_lower := false
	match motor.control_mode:
		SimulationMotorState.ControlMode.VELOCITY:
			toward_upper = motor.target_velocity_mps > 0.0001
			toward_lower = motor.target_velocity_mps < -0.0001
		SimulationMotorState.ControlMode.POSITION:
			var error := (
				motor.clamp_target_position() - position
				if not is_nan(observed_override_m)
				else motor.position_error()
			)
			toward_upper = error > 0.0001
			toward_lower = error < -0.0001
	if toward_upper:
		var room := motor.upper_limit_m - position
		if room <= 0.0:
			return 0.0
		if room < LIMIT_TAPER_RAD:
			return clampf(room / LIMIT_TAPER_RAD, 0.0, 1.0)
	if toward_lower:
		var room_lower := position - motor.lower_limit_m
		if room_lower <= 0.0:
			return 0.0
		if room_lower < LIMIT_TAPER_RAD:
			return clampf(room_lower / LIMIT_TAPER_RAD, 0.0, 1.0)
	return 1.0


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
	var taper := near_limit_torque_scale(motor)
	ideal_torque_nm *= taper
	var saturated := (
		taper >= 0.999
		and absf(ideal_torque_nm) >= motor.force_limit_n - 0.001
	)
	return {
		"torque_nm": clampf(
			ideal_torque_nm,
			-motor.force_limit_n,
			motor.force_limit_n
		),
		"saturated": saturated,
	}
