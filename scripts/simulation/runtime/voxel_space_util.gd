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


static func physics_surface_along_ray(
	space_state: PhysicsDirectSpaceState3D,
	from: Vector3,
	direction: Vector3,
	max_distance: float,
	collision_mask: int = 1,
	exclude_rids: Array[RID] = []
) -> Vector3:
	if space_state == null or max_distance <= EPSILON:
		return Vector3(NAN, NAN, NAN)
	if direction.length_squared() <= EPSILON:
		return Vector3(NAN, NAN, NAN)
	var dir := direction.normalized()
	var query := PhysicsRayQueryParameters3D.create(
		from,
		from + dir * max_distance
	)
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	query.collide_with_bodies = true
	if not exclude_rids.is_empty():
		query.exclude = exclude_rids
	var hit: Dictionary = space_state.intersect_ray(query)
	if hit.is_empty():
		return Vector3(NAN, NAN, NAN)
	return hit["position"] as Vector3


static func resolve_ground_surface_along_ray(
	space_state: PhysicsDirectSpaceState3D,
	from: Vector3,
	direction: Vector3,
	sdf_surface_point: Vector3,
	max_distance: float,
	collision_mask: int = 1,
	exclude_rids: Array[RID] = []
) -> Vector3:
	var physics_point := physics_surface_along_ray(
		space_state,
		from,
		direction,
		max_distance,
		collision_mask,
		exclude_rids
	)
	if (
		is_finite(physics_point.x)
		and is_finite(physics_point.y)
		and is_finite(physics_point.z)
	):
		return physics_point
	return sdf_surface_point


static func physics_down_surface_y(
	space_state: PhysicsDirectSpaceState3D,
	world_xz: Vector2,
	probe_y: float,
	max_distance: float,
	collision_mask: int = 1
) -> float:
	var point := physics_surface_along_ray(
		space_state,
		Vector3(world_xz.x, probe_y, world_xz.y),
		Vector3.DOWN,
		max_distance,
		collision_mask
	)
	if not is_finite(point.y):
		return NAN
	return point.y


static func resolve_ground_surface_y(
	space_state: PhysicsDirectSpaceState3D,
	world_xz: Vector2,
	sdf_surface_y: float,
	probe_y: float,
	max_distance: float,
	collision_mask: int = 1
) -> float:
	var resolved := resolve_ground_surface_along_ray(
		space_state,
		Vector3(world_xz.x, probe_y, world_xz.y),
		Vector3.DOWN,
		Vector3(world_xz.x, sdf_surface_y, world_xz.y),
		max_distance,
		collision_mask
	)
	return resolved.y


## VoxelTool.raycast: Godot world-space in/out (plugin applies terrain transform).
## Edit stamps (do_sphere, do_path, …) use world_to_local separately.
static func raycast_world(
	voxel_tool: VoxelTool,
	_terrain: Node3D,
	world_origin: Vector3,
	world_direction: Vector3,
	world_max_distance: float
) -> VoxelRaycastResult:
	if voxel_tool == null:
		return null
	var direction := world_direction
	if direction.length_squared() > EPSILON:
		direction = direction.normalized()
	else:
		return null
	return voxel_tool.raycast(
		world_origin,
		direction,
		world_max_distance
	)


static func raycast_hit_world_distance(
	_terrain: Node3D,
	hit: VoxelRaycastResult
) -> float:
	if hit == null:
		return 0.0
	return hit.distance


static func raycast_hit_world_point(
	_terrain: Node3D,
	world_origin: Vector3,
	world_direction: Vector3,
	hit: VoxelRaycastResult
) -> Vector3:
	if hit == null:
		return world_origin
	var direction := world_direction
	if direction.length_squared() <= EPSILON:
		return world_origin
	return world_origin + direction.normalized() * hit.distance
