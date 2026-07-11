extends Node

@export var head_path: NodePath = NodePath("../Camera")
@export var placed_blocks_path: NodePath
@export var terrain_path: NodePath
@export var reach := 4.0
@export var place_cooldown := 0.12

var _head: Camera3D
var _placed_blocks: Node
var _terrain: VoxelTerrain
var _player: Node3D
var _tool: VoxelTool
var _cooldown := 0.0


func _ready() -> void:
	_head = get_node(head_path)
	_placed_blocks = get_node(placed_blocks_path)
	_terrain = get_node(terrain_path)
	_player = get_parent()
	_tool = _terrain.get_voxel_tool()
	_tool.channel = VoxelBuffer.CHANNEL_SDF


func _physics_process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)

	if _player.has_method("is_spawn_ready") and not _player.is_spawn_ready():
		return

	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return
	if _cooldown > 0.0:
		return

	var origin: Vector3 = _head.global_position
	var direction: Vector3 = -_head.global_transform.basis.z.normalized()
	var hit := _raycast(origin, direction)
	if hit.is_empty():
		return

	var cell: Vector3i = _placed_blocks.placement_cell_from_hit(hit["position"], hit["normal"])
	if _placed_blocks.try_place(cell, _player):
		_cooldown = place_cooldown


func _raycast(origin: Vector3, direction: Vector3) -> Dictionary:
	var space := _terrain.get_world_3d().direct_space_state
	var end: Vector3 = origin + direction * reach
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.exclude = [_player.get_rid()]
	query.collision_mask = 3
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var phys_hit := space.intersect_ray(query)
	if not phys_hit.is_empty():
		return {
			"position": phys_hit["position"],
			"normal": phys_hit["normal"],
		}

	var voxel_hit: VoxelRaycastResult = _tool.raycast(origin, direction, reach)
	if voxel_hit != null:
		return {
			"position": origin + direction * voxel_hit.distance,
			"normal": -direction,
		}

	return {}
