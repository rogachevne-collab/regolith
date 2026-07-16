class_name InteractionQuery
extends Node3D

signal hit_updated(hit: InteractionHit)

@export var player_path: NodePath = NodePath("..")
@export var camera_path: NodePath = NodePath("../Camera")
@export var tool_controller_path: NodePath = NodePath("../ToolController")
@export var terrain_path: NodePath = NodePath("../../VoxelTerrain")
@export var simulation_session_path: NodePath = NodePath("../../SimulationSession")
@export var max_distance := 4.0
## Layers 1 (terrain), 4 (interaction wire colliders), 8 (loot pickup only).
@export_flags_3d_physics var collision_mask := 13

var current_hit := InteractionHit.empty()

var _player: CollisionObject3D
var _camera: Camera3D
var _tools: ToolController
var _terrain: VoxelTerrain
var _voxel_tool: VoxelTool
var _session: SimulationSession


func _ready() -> void:
	_player = get_node(player_path)
	_camera = get_node(camera_path)
	_tools = get_node_or_null(tool_controller_path) as ToolController
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
	var exclude: Array = [_player.get_rid()]
	var skips_left := 8
	while skips_left >= 0:
		var query := PhysicsRayQueryParameters3D.create(
			origin,
			origin + direction * max_distance
		)
		query.exclude = exclude
		query.collision_mask = collision_mask
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var raw := get_world_3d().direct_space_state.intersect_ray(query)
		if raw.is_empty():
			return InteractionHit.empty()

		var collider: Object = raw["collider"]
		var metadata := _target_metadata(collider, raw)
		if metadata.has("loot_pile_id") and _should_skip_loot_for_drill():
			return InteractionHit.empty()
		var kind := _target_kind(collider, metadata)
		if (
			kind == InteractionHit.KIND_ELECTRIC_CABLE
			and _should_skip_cable_for_build()
			and collider is CollisionObject3D
		):
			exclude.append((collider as CollisionObject3D).get_rid())
			skips_left -= 1
			continue
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
	return InteractionHit.empty()


func _query_voxel(
	origin: Vector3,
	direction: Vector3
) -> InteractionHit:
	var raw: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		_voxel_tool,
		_terrain,
		origin,
		direction,
		max_distance
	)
	if raw == null:
		return InteractionHit.empty()
	var world_point: Vector3 = VoxelSpaceUtil.raycast_hit_world_point(
		_terrain,
		origin,
		direction,
		raw
	)
	return InteractionHit.create(
		world_point,
		-direction,
		origin.distance_to(world_point),
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
	if metadata.has("control_seat"):
		return InteractionHit.KIND_CONTROL_SEAT
	if metadata.has("element_id"):
		return InteractionHit.KIND_SIMULATION_ELEMENT
	if metadata.has("loot_pile_id"):
		return InteractionHit.KIND_WORLD_LOOT
	if metadata.has("electric_link_id"):
		return InteractionHit.KIND_ELECTRIC_CABLE
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
				var pending_recipe := ""
				if machine.queue.is_empty():
					if _tools != null:
						pending_recipe = _tools.selected_recipe_for_element(
							element.element_id,
							element.archetype_id
						)
					else:
						pending_recipe = (
							RecipeCatalog.default_recipe_for_machine(
								element.archetype_id
							)
						)
				else:
					pending_recipe = str(machine.queue[0])
				metadata["pending_recipe_id"] = pending_recipe
				metadata["missing_input_resource_id"] = (
					RecipeRunnerService.missing_input_for_recipe(
						_session.world,
						element,
						pending_recipe
					)
				)
				if machine.active_recipe_id.is_empty() and element.is_operational():
					var display_status := StringName(
						metadata.get("status_reason", &"ok")
					)
					if (
						runtime.machine_enabled
						and runtime.powered
						and display_status in [
							&"ok",
							&"standby",
							&"no_input",
							&"storage_full",
							&"port_disconnected",
							&"cargo_disconnected",
						]
					):
						metadata["status_reason"] = (
							RecipeRunnerService.preview_idle_reason_for_recipe(
								_session.world,
								element,
								pending_recipe
							)
						)
				metadata["cargo_network_connected"] = (
					RecipeRunnerService.connected_cargo_has_path(
						_session.world,
						element.element_id
					)
				)
				metadata["cargo_network_raw_regolith"] = (
					RecipeRunnerService.connected_supply_amount(
						_session.world,
						element.element_id,
						"raw_regolith"
					)
				)
				metadata["cargo_network_regolith_fines"] = (
					RecipeRunnerService.connected_supply_amount(
						_session.world,
						element.element_id,
						"regolith_fines"
					)
				)
				metadata["recipe_progress_s"] = machine.progress_s
				var duration_s := (
					RecipeCatalog.duration_s(machine.active_recipe_id)
					if not machine.active_recipe_id.is_empty()
					else 0.0
				)
				metadata["recipe_duration_s"] = duration_s
			PistonPlacementUtil.enrich_interaction_metadata(
				_session.world,
				int(metadata["element_id"]),
				metadata
			)
			RotorPlacementUtil.enrich_interaction_metadata(
				_session.world,
				int(metadata["element_id"]),
				metadata
			)
			HingePlacementUtil.enrich_interaction_metadata(
				_session.world,
				int(metadata["element_id"]),
				metadata
			)
			WheelPlacementUtil.enrich_interaction_metadata(
				_session.world,
				int(metadata["element_id"]),
				metadata
			)
			WheelPlacementUtil.enrich_control_seat_metadata(
				_session.world,
				element,
				metadata
			)
	return metadata


func _should_skip_loot_for_drill() -> bool:
	if _tools == null or _tools.active_tool != &"drill":
		return false
	if Input.is_action_pressed(&"tool_primary"):
		return true
	return (
		_tools.state == ToolController.ActionState.HOLDING
		or _tools.state == ToolController.ActionState.COMPLETED
	)


func _should_skip_cable_for_build() -> bool:
	return _tools != null and _tools.active_tool == &"build"


func _publish(hit: InteractionHit) -> void:
	current_hit = hit
	hit_updated.emit(current_hit)
