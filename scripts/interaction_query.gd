class_name InteractionQuery
extends Node3D

signal hit_updated(hit: InteractionHit)

@export var player_path: NodePath = NodePath("..")
@export var camera_path: NodePath = NodePath("../Camera")
@export var terrain_path: NodePath = NodePath("../../VoxelTerrain")
@export var simulation_session_path: NodePath = NodePath("../../SimulationSession")
@export var max_distance := 4.0
@export_flags_3d_physics var collision_mask := 3

var current_hit := InteractionHit.empty()

var _player: CollisionObject3D
var _camera: Camera3D
var _terrain: VoxelTerrain
var _voxel_tool: VoxelTool
var _session: SimulationSession


func _ready() -> void:
	_player = get_node(player_path)
	_camera = get_node(camera_path)
	_terrain = get_node(terrain_path)
	_session = get_node_or_null(simulation_session_path) as SimulationSession
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
	var metadata := _target_metadata(collider, raw)
	var kind := _target_kind(collider, metadata)
	metadata["aim_direction"] = direction
	var stable_target_id := (
		StringName(str(metadata["element_id"]))
		if kind == InteractionHit.KIND_SIMULATION_ELEMENT
		else StringName(str(collider.get_instance_id()))
	)
	return InteractionHit.create(
		raw["position"],
		raw["normal"],
		origin.distance_to(raw["position"]),
		kind,
		collider,
		stable_target_id,
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


func _target_kind(
	collider: Object,
	metadata: Dictionary = {}
) -> StringName:
	if collider.has_method("interaction_target_kind"):
		return collider.call("interaction_target_kind")
	if metadata.has("element_id"):
		return InteractionHit.KIND_SIMULATION_ELEMENT
	if metadata.has("loot_pile_id"):
		return InteractionHit.KIND_WORLD_LOOT
	if collider is VoxelTerrain:
		return InteractionHit.KIND_VOXEL
	if collider is Node and collider.is_in_group("placed_blocks"):
		return InteractionHit.KIND_PLACED_BLOCK
	return InteractionHit.KIND_BODY


func _target_metadata(
	collider: Object,
	raw_hit: Dictionary = {}
) -> Dictionary:
	if collider.has_method("interaction_metadata"):
		return collider.call("interaction_metadata")
	if collider is Node and collider.has_meta("interaction_metadata"):
		return Dictionary(
			collider.get_meta("interaction_metadata")
		).duplicate(true)
	var metadata: Dictionary = {}
	if collider is CollisionObject3D:
		var collision_object := collider as CollisionObject3D
		if collision_object.has_meta("assembly_id"):
			metadata["assembly_id"] = int(
				collision_object.get_meta("assembly_id")
			)
		var shape_index := int(raw_hit.get("shape", -1))
		if shape_index >= 0:
			var owner_id := collision_object.shape_find_owner(shape_index)
			if owner_id >= 0:
				var owner: Object = collision_object.shape_owner_get_owner(owner_id)
				if owner is Node and owner.has_meta("element_id"):
					metadata["element_id"] = int(owner.get_meta("element_id"))
					metadata["shape_index"] = shape_index
					metadata["collider_index"] = int(
						owner.get_meta("collider_index", -1)
					)
					metadata["collider_local_cell"] = owner.get_meta(
						"collider_local_cell",
						Vector3i.ZERO
					)
	if metadata.has("element_id") and _session != null:
		var element := _session.world.get_element(int(metadata["element_id"]))
		if element != null:
			metadata["assembly_id"] = element.assembly_id
			metadata["archetype_id"] = element.archetype_id
			metadata["build_progress"] = element.build_progress
			metadata["integrity"] = element.integrity
			metadata["state_revision"] = element.state_revision
			metadata["status_reason"] = IndustryStatusUtil.resolve_display_reason(
				_session.world,
				element
			)
			var runtime := _session.world.ensure_industry_element_runtime(
				element.element_id
			)
			metadata["machine_enabled"] = runtime.machine_enabled
			if element.archetype_id in ["processor", "fabricator"]:
				var machine := runtime.ensure_machine_state()
				metadata["active_recipe_id"] = machine.active_recipe_id
				metadata["recipe_queue"] = machine.queue.duplicate()
	return metadata


func _publish(hit: InteractionHit) -> void:
	current_hit = hit
	hit_updated.emit(current_hit)
