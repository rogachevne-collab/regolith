class_name HingeProjectionUtil
extends RefCounted
## Hinge (ServoHinge) constraint projection. Motor math is shared with the
## rotor (RotorProjectionUtil.compute_motor_torque_scalar handles the
## non-continuous position error transparently); this util owns the joint
## frame (bend axis on local X — Jolt's twist axis, which supports the
## asymmetric angle limits) and the hard angular stops.


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


## Lock everything except rotation around local X, hard-limited to the
## motor's [lower, upper] angle range. Called every physics tick: configure
## can retune the limits on a live joint.
static func configure_hinge_limit_joint(
	joint: Generic6DOFJoint3D,
	motor: SimulationMotorState
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
	joint.set("angular_limit_x/lower_angle", motor.lower_limit_m)
	joint.set("angular_limit_x/upper_angle", motor.upper_limit_m)
