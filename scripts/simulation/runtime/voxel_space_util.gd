class_name VoxelSpaceUtil
extends RefCounted

const EPSILON := 0.000001


static func voxel_size_m(terrain: Node3D) -> float:
	if terrain == null:
		return 1.0
	var scale := terrain.scale
	return scale.x


static func cell_volume_m3(terrain: Node3D) -> float:
	var size := voxel_size_m(terrain)
	return size * size * size


static func world_to_local(terrain: Node3D, world_point: Vector3) -> Vector3:
	if terrain == null:
		return world_point
	return terrain.global_transform.affine_inverse() * world_point


static func world_direction_to_local(
	terrain: Node3D,
	direction: Vector3
) -> Vector3:
	if terrain == null or direction.length_squared() <= EPSILON:
		return direction
	return (
		terrain.global_transform.affine_inverse().basis * direction
	).normalized()


static func local_to_world(terrain: Node3D, local_point: Vector3) -> Vector3:
	if terrain == null:
		return local_point
	return terrain.global_transform * local_point


static func world_distance_to_local(
	terrain: Node3D,
	distance_m: float
) -> float:
	var size := voxel_size_m(terrain)
	if size <= EPSILON:
		return distance_m
	return distance_m / size


static func local_distance_to_world(
	terrain: Node3D,
	distance_local: float
) -> float:
	return distance_local * voxel_size_m(terrain)


static func world_cell_from_point(
	terrain: Node3D,
	world_point: Vector3
) -> Vector3i:
	var local := world_to_local(terrain, world_point)
	return Vector3i(
		floori(local.x),
		floori(local.y),
		floori(local.z)
	)


static func raycast_world(
	voxel_tool: VoxelTool,
	terrain: Node3D,
	world_origin: Vector3,
	world_direction: Vector3,
	world_max_distance: float
) -> VoxelRaycastResult:
	if voxel_tool == null:
		return null
	var local_origin := world_to_local(terrain, world_origin)
	var local_direction := world_direction_to_local(terrain, world_direction)
	var local_distance := world_distance_to_local(
		terrain,
		world_max_distance
	)
	return voxel_tool.raycast(
		local_origin,
		local_direction,
		local_distance
	)


static func raycast_hit_world_distance(
	terrain: Node3D,
	hit: VoxelRaycastResult
) -> float:
	if hit == null:
		return 0.0
	return local_distance_to_world(terrain, hit.distance)


static func raycast_hit_world_point(
	terrain: Node3D,
	world_origin: Vector3,
	world_direction: Vector3,
	hit: VoxelRaycastResult
) -> Vector3:
	if hit == null:
		return world_origin
	return (
		world_origin
		+ world_direction.normalized()
		* raycast_hit_world_distance(terrain, hit)
	)
