class_name TerrainCompat
extends RefCounted

## Thin contract for VoxelTerrain | VoxelLodTerrain call sites.
## Both expose get_voxel_tool(); collider ownership may sit on child bodies.


static func is_terrain(node: Object) -> bool:
	if node == null:
		return false
	return node is VoxelTerrain or node is VoxelLodTerrain


static func is_terrain_collider(
	collider: Object,
	terrain: Node = null
) -> bool:
	if collider == null or not collider is Node:
		return false
	if collider is PhysicsBody3D:
		if int((collider as PhysicsBody3D).get_meta("assembly_id", 0)) != 0:
			return false
	if terrain == null:
		return is_terrain(collider) or _parent_chain_has_terrain(collider as Node)
	var node := collider as Node
	while node != null:
		if node == terrain:
			return true
		node = node.get_parent()
	return false


## Sub-voxel raycast refinement (VoxelToolLodTerrain). With the default 0 the
## raycast stops at voxel granularity and reports hits up to ~1 voxel above
## the smooth SDF surface, so ground-seated blocks float above the terrain.
## 8 halvings refine a 1.0 m voxel to ~4 mm.
const RAYCAST_BINARY_SEARCH_ITERATIONS := 8


## The material a terrain draws its surface with. The two classes spell it
## differently — `VoxelLodTerrain` calls it `material`, `VoxelTerrain` calls it
## `material_override` — and loose material has to read it off whichever one the
## world happens to use, so that a heap is shaded by the very same thing as the
## ground it is lying on.
##
## Deliberately the live instance and not a copy: the planet's shader gets
## `u_radial_up`, `u_planet_radius` and the baked brightness map set on it at
## runtime by the bootstrap, and a copy taken at region-creation time would
## quietly drift from whatever the ground is actually using.
static func get_surface_material(terrain: Node) -> Material:
	if terrain is VoxelLodTerrain:
		return (terrain as VoxelLodTerrain).material
	if terrain is VoxelTerrain:
		return (terrain as VoxelTerrain).material_override
	return null


static func get_voxel_tool(terrain: Node) -> VoxelTool:
	if terrain == null or not terrain.has_method("get_voxel_tool"):
		return null
	var tool := terrain.call("get_voxel_tool") as VoxelTool
	if (
		tool != null
		and tool.has_method("set_raycast_binary_search_iterations")
	):
		tool.call(
			"set_raycast_binary_search_iterations",
			RAYCAST_BINARY_SEARCH_ITERATIONS
		)
	return tool


static func _parent_chain_has_terrain(node: Node) -> bool:
	var cursor := node
	while cursor != null:
		if is_terrain(cursor):
			return true
		cursor = cursor.get_parent()
	return false
