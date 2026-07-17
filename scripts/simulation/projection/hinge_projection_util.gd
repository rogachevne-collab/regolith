class_name HingeProjectionUtil
extends RefCounted
## Hinge (ServoHinge) constraint projection. Motor math is shared with the
## rotor (RotorProjectionUtil.compute_motor_torque_scalar handles the
## non-continuous position error transparently); this util owns the joint
## frame (bend axis on local X — Jolt's twist axis, which supports the
## asymmetric angle limits) and the hard angular stops.
##
## Jolt measures angular X from the relative pose at joint creation. Motor
## observed angle is home-relative. `angle_offset_rad` is the measured angle
## at create time; Jolt limits are motor limits shifted by that offset so
## hard stops stay aligned after snapshot restore / bent reproject.


## Softness / damping on the twist stop — keeps stock torque from fighting
## the hard limit into a solver explosion while status stays joint_limit.
const LIMIT_SOFTNESS := 0.15
const LIMIT_DAMPING := 1.0
const LIMIT_RESTITUTION := 0.0


## Joint frame with X along the bend axis; angular X is Jolt's twist DOF.
static func basis_with_x_axis(axis: Vector3) -> Basis:
	var x_axis := axis.normalized()
	if x_axis.length_squared() <= 0.000001:
		return Basis.IDENTITY
	var y_axis := x_axis.cross(Vector3.UP)
	if y_axis.length_squared() <= 0.000001:
		y_axis = x_axis.cross(Vector3.RIGHT)
	y_axis = y_axis.normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)


## Convert home-relative motor limits into Jolt rest-relative limits.
static func jolt_angle_limits(
	motor: SimulationMotorState,
	angle_offset_rad: float
) -> Vector2:
	if motor == null:
		return Vector2.ZERO
	return Vector2(
		motor.lower_limit_m - angle_offset_rad,
		motor.upper_limit_m - angle_offset_rad
	)


## Full joint setup (locked linear + swing, limited twist). Call once when
## the constraint is created.
static func configure_hinge_limit_joint(
	joint: Generic6DOFJoint3D,
	motor: SimulationMotorState,
	angle_offset_rad: float = 0.0
) -> void:
	for axis: String in ["x", "y", "z"]:
		joint.set("linear_limit_%s/enabled" % axis, true)
		joint.set("linear_limit_%s/lower_distance" % axis, 0.0)
		joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
	for axis: String in ["y", "z"]:
		joint.set("angular_limit_%s/enabled" % axis, true)
		joint.set("angular_limit_%s/lower_angle" % axis, 0.0)
		joint.set("angular_limit_%s/upper_angle" % axis, 0.0)
	joint.set("angular_limit_x/enabled", true)
	joint.set("angular_limit_x/softness", LIMIT_SOFTNESS)
	joint.set("angular_limit_x/damping", LIMIT_DAMPING)
	joint.set("angular_limit_x/restitution", LIMIT_RESTITUTION)
	update_hinge_angle_limits(joint, motor, angle_offset_rad)


## Live retune of twist stops only (configure_actuator may change min/max).
## Does not rewrite locked DOFs — preserves Jolt warm-starting.
static func update_hinge_angle_limits(
	joint: Generic6DOFJoint3D,
	motor: SimulationMotorState,
	angle_offset_rad: float = 0.0
) -> void:
	if joint == null or motor == null:
		return
	var limits := jolt_angle_limits(motor, angle_offset_rad)
	joint.set("angular_limit_x/lower_angle", limits.x)
	joint.set("angular_limit_x/upper_angle", limits.y)
