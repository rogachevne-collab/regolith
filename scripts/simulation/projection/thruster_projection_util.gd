class_name ThrusterProjectionUtil
extends RefCounted

const ATTITUDE_EPS := 0.001


static func compute_thrust_n(
	definition: ThrusterDefinition,
	thrust_command: float,
	powered: bool
) -> float:
	if definition == null or not powered:
		return 0.0
	return definition.max_thrust_n * clampf(thrust_command, 0.0, 1.0)


static func thrust_axis_local(
	definition: ThrusterDefinition,
	orientation_index: int
) -> Vector3:
	if definition == null:
		return Vector3.UP
	var face_vec := OrientationUtil.face_to_vector(definition.thrust_axis_face)
	var basis := OrientationUtil.orientation_basis(orientation_index)
	return (basis * Vector3(face_vec)).normalized()


static func nozzle_offset_local(
	definition: ThrusterDefinition,
	element: SimulationElement
) -> Vector3:
	if definition == null or element == null:
		return Vector3.ZERO
	var element_xform := GridPoseUtil.element_local_transform(
		element.origin_cell,
		element.orientation_index
	)
	return (
		element_xform.origin
		+ element_xform.basis * definition.nozzle_offset_local
	)


static func compute_gyro_torque_local(
	definition: GyroDefinition,
	pitch_command: float,
	yaw_command: float,
	roll_command: float,
	dampeners: bool,
	angular_velocity_local: Vector3,
	gyro_count: int,
	powered: bool
) -> Vector3:
	if definition == null or not powered or gyro_count <= 0:
		return Vector3.ZERO
	var share := 1.0 / float(gyro_count)
	var attitude := Vector3(
		clampf(pitch_command, -1.0, 1.0),
		clampf(yaw_command, -1.0, 1.0),
		clampf(roll_command, -1.0, 1.0)
	)
	if attitude.length() > ATTITUDE_EPS:
		return attitude * definition.max_torque_nm * share
	if not dampeners:
		return Vector3.ZERO
	var damp := -angular_velocity_local * definition.dampen_gain * share
	var limit := definition.max_torque_nm * share
	return Vector3(
		clampf(damp.x, -limit, limit),
		clampf(damp.y, -limit, limit),
		clampf(damp.z, -limit, limit)
	)
