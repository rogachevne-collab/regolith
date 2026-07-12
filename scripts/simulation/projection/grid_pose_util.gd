class_name GridPoseUtil
extends RefCounted


static func grid_frame_to_transform(frame: GridTransform) -> Transform3D:
	var basis: Basis = OrientationUtil.orientation_basis(
		frame.orientation_index
	)
	return Transform3D(basis, Vector3(frame.translation))


static func b_to_a_from_grid_frames(
	frame_a: GridTransform,
	frame_b: GridTransform
) -> GridTransform:
	return frame_a.inverse().compose(frame_b)


static func b_to_a_from_motion(
	motion_a: AssemblyMotionState,
	motion_b: AssemblyMotionState
) -> GridTransform:
	var result: Dictionary = GridAlignment.nearest_alignment(
		motion_a.transform,
		motion_b.transform
	)
	return result["grid_transform"]


static func snap_transform_to_grid(relative: Transform3D) -> GridTransform:
	var result: Dictionary = GridAlignment.nearest_alignment(
		Transform3D.IDENTITY,
		relative
	)
	return result["grid_transform"]


static func element_local_transform(
	origin_cell: Vector3i,
	orientation_index: int
) -> Transform3D:
	return Transform3D(
		OrientationUtil.orientation_basis(orientation_index),
		Vector3(origin_cell)
	)


static func collider_local_transform(
	element_origin: Vector3i,
	element_orientation_index: int,
	collider: ColliderDefinition
) -> Transform3D:
	var element_transform: Transform3D = element_local_transform(
		element_origin,
		element_orientation_index
	)
	var rotated_offset: Vector3 = element_transform.basis * collider.offset_in_cell
	var rotated_cell: Vector3i = OrientationUtil.rotate_cell(
		collider.local_cell,
		element_orientation_index
	)
	var local_position: Vector3 = (
		Vector3(element_origin + rotated_cell) + rotated_offset
	)
	return Transform3D(element_transform.basis, local_position)


static func collider_world_transform(
	assembly_world_transform: Transform3D,
	origin_cell: Vector3i,
	orientation_index: int,
	collider: ColliderDefinition
) -> Transform3D:
	return (
		assembly_world_transform
		* collider_local_transform(origin_cell, orientation_index, collider)
	)


static func collider_world_aabb(
	assembly_world_transform: Transform3D,
	origin_cell: Vector3i,
	orientation_index: int,
	collider: ColliderDefinition
) -> AABB:
	var world_transform: Transform3D = collider_world_transform(
		assembly_world_transform,
		origin_cell,
		orientation_index,
		collider
	)
	var half_extents: Vector3 = collider.size * 0.5
	var bounds := AABB()
	for sx: int in [-1, 1]:
		for sy: int in [-1, 1]:
			for sz: int in [-1, 1]:
				bounds = bounds.expand(
					world_transform * Vector3(
						half_extents.x * sx,
						half_extents.y * sy,
						half_extents.z * sz
					)
				)
	return bounds


static func projected_element_collider_transforms(
	assembly_world_transform: Transform3D,
	origin_cell: Vector3i,
	orientation_index: int,
	archetype: ElementArchetype
) -> Array[Transform3D]:
	var transforms: Array[Transform3D] = []
	if archetype == null:
		return transforms
	for collider: ColliderDefinition in archetype.colliders:
		if collider.shape_kind != ColliderDefinition.ShapeKind.BOX:
			continue
		transforms.append(
			collider_world_transform(
				assembly_world_transform,
				origin_cell,
				orientation_index,
				collider
			)
		)
	return transforms
