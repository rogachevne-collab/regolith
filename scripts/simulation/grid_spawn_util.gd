class_name GridSpawnUtil
extends RefCounted


static func terrain_basis(
	terrain_tangent_x: Vector3,
	terrain_tangent_z: Vector3
) -> Basis:
	var terrain_up: Vector3 = (
		terrain_tangent_z.cross(terrain_tangent_x).normalized()
	)
	var forward: Vector3 = (
		Vector3.FORWARD
		- terrain_up * Vector3.FORWARD.dot(terrain_up)
	).normalized()
	var right: Vector3 = forward.cross(terrain_up).normalized()
	return Basis(right, terrain_up, -forward).orthonormalized()


static func transform_on_terrain(
	ground_point: Vector3,
	basis: Basis,
	height_offset: float
) -> Transform3D:
	return Transform3D(basis, ground_point + basis.y * height_offset)


static func grid_frame_from_transform(transform: Transform3D) -> GridTransform:
	var alignment: Dictionary = GridAlignment.nearest_alignment(
		Transform3D.IDENTITY,
		transform
	)
	return alignment["grid_transform"]


static func motion_from_transform(
	transform: Transform3D,
	anchored: bool
) -> AssemblyMotionState:
	var motion := AssemblyMotionState.new()
	motion.transform = transform
	motion.frozen = anchored
	if anchored:
		motion.linear_velocity = Vector3.ZERO
		motion.angular_velocity = Vector3.ZERO
		motion.sleeping = true
	return motion
