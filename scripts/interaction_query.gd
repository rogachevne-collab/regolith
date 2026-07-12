class_name InteractionQuery
extends Node3D

signal hit_updated(hit: InteractionHit)

@export var player_path: NodePath = NodePath("..")
@export var camera_path: NodePath = NodePath("../Camera")
@export var terrain_path: NodePath = NodePath("../../VoxelTerrain")
@export var max_distance := 4.0
@export_flags_3d_physics var collision_mask := 3

var current_hit := InteractionHit.empty()

var _player: CollisionObject3D
var _camera: Camera3D
var _terrain: VoxelTerrain
var _voxel_tool: VoxelTool


func _ready() -> void:
	_player = get_node(player_path)
	_camera = get_node(camera_path)
	_terrain = get_node(terrain_path)
	_voxel_tool = _terrain.get_voxel_tool()
	_voxel_tool.channel = VoxelBuffer.CHANNEL_SDF


func _physics_process(_delta: float) -> void:
	if (
		_player.has_method("is_spawn_ready")
		and not _player.call("is_spawn_ready")
	):
		_publish(InteractionHit.empty())
		return

	var aim: Transform3D = _camera.call("aim_transform")
	var origin := aim.origin
	var direction := -aim.basis.z.normalized()
	var physics_hit := _query_physics(origin, direction)
	if physics_hit.valid:
		_publish(physics_hit)
		return
	_publish(_query_voxel(origin, direction))


func _query_physics(
	origin: Vector3,
	direction: Vector3
) -> InteractionHit:
	var query := PhysicsRayQueryParameters3D.create(
		origin,
		origin + direction * max_distance
	)
	query.exclude = [_player.get_rid()]
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var raw := get_world_3d().direct_space_state.intersect_ray(query)
	if raw.is_empty():
		return InteractionHit.empty()

	var collider: Object = raw["collider"]
	var kind := _target_kind(collider)
	var metadata := _target_metadata(collider)
	metadata["aim_direction"] = direction
	return InteractionHit.create(
		raw["position"],
		raw["normal"],
		origin.distance_to(raw["position"]),
		kind,
		collider,
		StringName(str(collider.get_instance_id())),
		metadata
	)


func _query_voxel(
	origin: Vector3,
	direction: Vector3
) -> InteractionHit:
	var raw: VoxelRaycastResult = _voxel_tool.raycast(
		origin,
		direction,
		max_distance
	)
	if raw == null:
		return InteractionHit.empty()
	return InteractionHit.create(
		origin + direction * raw.distance,
		-direction,
		raw.distance,
		InteractionHit.KIND_VOXEL,
		null,
		StringName(),
		{"aim_direction": direction}
	)


func _target_kind(collider: Object) -> StringName:
	if collider.has_method("interaction_target_kind"):
		return collider.call("interaction_target_kind")
	if collider is VoxelTerrain:
		return InteractionHit.KIND_VOXEL
	if collider is Node and collider.is_in_group("placed_blocks"):
		return InteractionHit.KIND_PLACED_BLOCK
	return InteractionHit.KIND_BODY


func _target_metadata(collider: Object) -> Dictionary:
	if collider.has_method("interaction_metadata"):
		return collider.call("interaction_metadata")
	if collider is Node and collider.has_meta("interaction_metadata"):
		return Dictionary(
			collider.get_meta("interaction_metadata")
		).duplicate(true)
	return {}


func _publish(hit: InteractionHit) -> void:
	current_hit = hit
	hit_updated.emit(current_hit)
