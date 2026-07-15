class_name TerrainAnchorProbe
extends RefCounted

const SUPPORT_EPSILON := 0.12
const SUPPORT_PROBE_RADIUS := 0.12

const _BOTTOM_SAMPLES: Array[Vector2] = [
	Vector2(0.0, 0.0),
	Vector2(-1.0, -1.0),
	Vector2(1.0, -1.0),
	Vector2(-1.0, 1.0),
	Vector2(1.0, 1.0),
]


static func is_construction_archetype(archetype_id: String) -> bool:
	return (
		ToolController.CONSTRUCTION_ARCHETYPES.has(archetype_id)
		or archetype_id == "foundation"
	)


static func touching_element_ids(
	voxel_tool: VoxelTool,
	assembly: SimulationAssembly,
	elements: Array[SimulationElement],
	space_state: PhysicsDirectSpaceState3D = null,
	terrain: VoxelTerrain = null
) -> Array[int]:
	var touching: Array[int] = []
	if assembly == null:
		return touching
	var assembly_transform := assembly.motion.transform
	for element: SimulationElement in elements:
		if not is_construction_archetype(element.archetype_id):
			continue
		if element_touches_terrain(
			assembly_transform,
			element,
			space_state,
			voxel_tool,
			terrain
		):
			touching.append(element.element_id)
	touching.sort()
	return touching


static func element_touches_terrain(
	assembly_transform: Transform3D,
	element: SimulationElement,
	space_state: PhysicsDirectSpaceState3D = null,
	voxel_tool: VoxelTool = null,
	terrain: VoxelTerrain = null
) -> bool:
	var archetype := element.get_archetype()
	if archetype == null:
		return false
	for collider: ColliderDefinition in archetype.colliders:
		if collider.shape_kind != ColliderDefinition.ShapeKind.BOX:
			continue
		var collider_transform := GridPoseUtil.collider_world_transform(
			assembly_transform,
			element.origin_cell,
			element.orientation_index,
			collider
		)
		var half := collider.size * 0.5
		for sample: Vector2 in _BOTTOM_SAMPLES:
			var local_point := Vector3(
				sample.x * half.x,
				-half.y,
				sample.y * half.z
			)
			var world_point := collider_transform * local_point
			if _point_overlaps_terrain(
				space_state,
				world_point,
				voxel_tool,
				terrain
			):
				return true
	return false


static func _point_overlaps_terrain(
	space_state: PhysicsDirectSpaceState3D,
	world_point: Vector3,
	voxel_tool: VoxelTool = null,
	terrain: VoxelTerrain = null
) -> bool:
	if space_state != null:
		for offset: Vector3 in [
			Vector3.ZERO,
			Vector3.DOWN * SUPPORT_EPSILON,
			Vector3.UP * SUPPORT_EPSILON * 0.5,
		]:
			if _physics_overlaps_terrain(
				space_state,
				world_point + offset,
				terrain
			):
				return true
	if voxel_tool != null:
		return _voxel_supports_point(voxel_tool, world_point, terrain)
	return false


static func _physics_overlaps_terrain(
	space_state: PhysicsDirectSpaceState3D,
	world_point: Vector3,
	terrain: VoxelTerrain
) -> bool:
	var shape := SphereShape3D.new()
	shape.radius = SUPPORT_PROBE_RADIUS
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, world_point)
	params.collision_mask = 1
	params.collide_with_bodies = true
	params.collide_with_areas = false
	for hit: Dictionary in space_state.intersect_shape(params, 16):
		if _is_terrain_collider(hit.get("collider"), terrain):
			return true
	return false


## Physics ray along `direction` that hits voxel terrain only (layer 1 default).
## Returns the engine ray hit dict or `{}` when nothing terrain-like is struck.
static func raycast_terrain(
	space_state: PhysicsDirectSpaceState3D,
	terrain: VoxelTerrain,
	from: Vector3,
	direction: Vector3,
	max_distance: float,
	collision_mask: int = 1,
	exclude_rids: Array[RID] = []
) -> Dictionary:
	if space_state == null or max_distance <= 0.000001:
		return {}
	if direction.length_squared() <= 0.000001:
		return {}
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
		return {}
	if not _is_terrain_collider(hit.get("collider"), terrain):
		return {}
	return hit


static func _is_terrain_collider(
	collider: Variant,
	terrain: VoxelTerrain
) -> bool:
	if collider == null or not collider is Node:
		return false
	if collider is PhysicsBody3D:
		if int((collider as PhysicsBody3D).get_meta("assembly_id", 0)) != 0:
			return false
	if terrain == null:
		return collider is VoxelTerrain
	var node := collider as Node
	while node != null:
		if node == terrain:
			return true
		node = node.get_parent()
	return false


static func _voxel_supports_point(
	voxel_tool: VoxelTool,
	world_point: Vector3,
	terrain: VoxelTerrain = null
) -> bool:
	var cell: Vector3i = (
		VoxelSpaceUtil.world_cell_from_point(terrain, world_point)
		if terrain != null
		else Vector3i(
			floori(world_point.x),
			floori(world_point.y),
			floori(world_point.z)
		)
	)
	if voxel_tool.get_voxel_f(cell) <= SUPPORT_EPSILON:
		return true
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		voxel_tool,
		terrain,
		world_point + Vector3.UP * 2.0,
		Vector3.DOWN,
		2.0 + SUPPORT_EPSILON
	)
	return hit != null
