class_name WorldCommandGateway
extends Node

signal command_completed(command_id: int, result: Dictionary)

# A flat, gravity-upright block bottom cannot follow bumpy/sloped terrain, so the
# aim hit (near, highest footprint edge) leaves the rest of the base floating. We
# reseat a first-on-ground block onto the LOWEST terrain point under its whole
# footprint (plus a hairline embed) so no corner ever floats above the surface.
const GROUND_SEAT_EMBED := 0.02
const _GROUND_SEAT_SAMPLES: Array[Vector2] = [
	Vector2(0.0, 0.0),
	Vector2(-0.5, -0.5),
	Vector2(0.5, -0.5),
	Vector2(-0.5, 0.5),
	Vector2(0.5, 0.5),
]

@export var terrain_path: NodePath = NodePath("../VoxelTerrain")
@export var placed_blocks_path: NodePath = NodePath("../PlacedBlocks")
@export var simulation_session_path: NodePath = NodePath("../SimulationSession")

var _terrain: VoxelTerrain
var _placed_blocks: Node
var _voxel_tool: VoxelTool
var _session: SimulationSession
var _queue: Array[Dictionary] = []
var _flush_scheduled := false
var _next_command_id := 1
var _archetype_cache: Dictionary = {}
var _snap_face_cache := ConstructionSnapFaceCache.new()
var _snap_resolver := ConstructionSnapResolver.new()
var _resolve_result_cache_key: String = ""
var _resolve_result_cache: Dictionary = {}
var _snap_event_bound := false


func _ready() -> void:
	_terrain = get_node(terrain_path)
	_placed_blocks = get_node(placed_blocks_path)
	_session = get_node_or_null(simulation_session_path) as SimulationSession
	_voxel_tool = _terrain.get_voxel_tool()
	_voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
	for archetype_id: String in ToolController.CONSTRUCTION_ARCHETYPES:
		_get_archetype(archetype_id)
	_snap_resolver.bind_cache(_snap_face_cache)
	call_deferred("_bind_snap_cache_events")
	call_deferred("_bind_terrain_contact_probe")


func _bind_terrain_contact_probe() -> void:
	if _session == null or _session.world == null:
		return
	_session.world.set_terrain_contact_probe(
		_probe_assembly_terrain_contact
	)


func _probe_assembly_terrain_contact(
	assembly: SimulationAssembly,
	elements: Array[SimulationElement]
) -> Array[int]:
	var space_state: PhysicsDirectSpaceState3D = null
	if _terrain != null and _terrain.is_inside_tree():
		space_state = _terrain.get_world_3d().direct_space_state
	return TerrainAnchorProbe.touching_element_ids(
		_voxel_tool,
		assembly,
		elements,
		space_state,
		_terrain
	)


func submit(command: Dictionary) -> int:
	var queued := command.duplicate(true)
	var command_id := _next_command_id
	_next_command_id += 1
	queued["id"] = command_id
	_queue.append(queued)
	if not _flush_scheduled:
		_flush_scheduled = true
		call_deferred("_flush")
	return command_id


func _flush() -> void:
	_flush_scheduled = false
	while not _queue.is_empty():
		var command: Dictionary = _queue.pop_front()
		var command_id: int = command["id"]
		command_completed.emit(
			command_id,
			_execute(command)
		)


func _execute(command: Dictionary) -> Dictionary:
	if not command.has("kind") or not command.has("target"):
		return _result(&"invalid_target")
	var target: Dictionary = command["target"]
	if not bool(target.get("valid", false)):
		return _result(&"no_target")

	match StringName(command["kind"]):
		&"voxel_remove":
			return _remove_voxel(command, target)
		&"damage_element":
			return _damage_element(command, target)
		&"place_block":
			return _place_block(command, target)
		&"toggle_control_seat":
			return _toggle_control_seat(command, target)
		&"construction_apply":
			return _construction_apply(command, target)
		&"weld_element":
			return _weld_element(command, target)
		&"dismantle_element":
			return _dismantle_element(command, target)
		_:
			return _result(&"invalid_target")


func _remove_voxel(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if StringName(target["target_kind"]) != InteractionHit.KIND_VOXEL:
		return _result(&"invalid_target")
	var parameters: Dictionary = command.get("parameters", {})
	var radius := clampf(
		float(parameters.get("radius", 0.68)),
		0.05,
		2.0
	)
	var metadata: Dictionary = target.get("metadata", {})
	var direction := Vector3(
		metadata.get("aim_direction", Vector3.FORWARD)
	).normalized()
	var center := Vector3(target["point"]) - direction * radius * 0.25
	_voxel_tool.mode = VoxelTool.MODE_REMOVE
	_voxel_tool.do_sphere(center, radius)
	return _result(&"ok", {"point": target["point"]})


func _place_block(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	var source: Node3D = command.get("source")
	if source == null:
		return _result(&"not_ready")
	var cell: Vector3i = _placed_blocks.call(
		"placement_cell_from_hit",
		Vector3(target["point"]),
		Vector3(target["normal"])
	)
	if not _placed_blocks.call("try_place", cell, source):
		return _result(&"blocked", {"cell": cell})
	return _result(&"ok", {"cell": cell})


func _toggle_control_seat(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if (
		StringName(target["target_kind"])
		!= InteractionHit.KIND_CONTROL_SEAT
	):
		return _result(&"invalid_target")
	var vehicle: Object = target.get("collider")
	var source: Node3D = command.get("source")
	if (
		vehicle == null
		or source == null
		or not vehicle.has_method("handle_interact")
	):
		return _result(&"not_ready")
	if not vehicle.call("handle_interact", source):
		return _result(&"blocked")
	return _result(&"ok")


func preview_construction(
	target: Dictionary,
	archetype_id: String,
	orientation_index: int
) -> Dictionary:
	if _session == null:
		return {
			"valid": false,
			"reason": &"not_ready",
		}
	var archetype := _get_archetype(archetype_id)
	return _seat_ground_plan(
		ConstructionPlacement.plan(
			_session.world,
			target,
			archetype,
			orientation_index
		)
	)


func resolve_construction_placement(params: Dictionary) -> Dictionary:
	var archetype_id := str(params.get("archetype_id", "frame"))
	var orientation_index := int(params.get("orientation_index", 0))
	var direct_hit: Dictionary = params.get("direct_hit", {})
	var manual_index := int(params.get("manual_candidate_index", -1))
	if _session == null:
		var plan := preview_construction(
			direct_hit,
			archetype_id,
			orientation_index
		)
		var selected_index := 0 if bool(plan.get("valid", false)) else -1
		return {
			"candidates": [],
			"selected_index": selected_index,
			"selected_target": (
				direct_hit if selected_index >= 0 else {}
			),
			"selected_plan": plan,
			"sticky_key": "",
			"stats": ConstructionSnapResolver._empty_stats(),
		}
	_bind_snap_cache_events()
	var cache_key := _resolve_cache_key(params)
	if manual_index < 0 and cache_key == _resolve_result_cache_key:
		return _resolve_result_cache.duplicate(true)
	var archetype := _get_archetype(archetype_id)
	var result := _snap_resolver.resolve({
		"world": _session.world,
		"archetype": archetype,
		"orientation_index": orientation_index,
		"store_id": str(params.get("store_id", "player")),
		"ray_origin": params.get("ray_origin", Vector3.ZERO),
		"ray_direction": params.get("ray_direction", Vector3.FORWARD),
		"camera": params.get("camera"),
		"direct_hit": direct_hit,
		"manual_candidate_index": manual_index,
	})
	result["selected_plan"] = _seat_ground_plan(
		result.get("selected_plan", {})
	)
	if manual_index < 0:
		_resolve_result_cache_key = cache_key
		_resolve_result_cache = result.duplicate(true)
	return result


func snap_cache_generation() -> int:
	return _snap_face_cache.generation


func snap_resolve_stats() -> Dictionary:
	return _snap_resolver.last_stats.duplicate(true)


func reset_construction_snap() -> void:
	_snap_resolver.reset_sticky()
	_clear_resolve_result_cache()


func _clear_resolve_result_cache() -> void:
	_resolve_result_cache_key = ""
	_resolve_result_cache = {}


func _bind_snap_cache_events() -> void:
	if _session == null or _session.world == null:
		return
	_snap_face_cache.bind_world(_session.world)
	if _snap_event_bound:
		return
	_session.world.structural_event.connect(_on_structural_event_for_snap)
	_snap_event_bound = true


func _on_structural_event_for_snap(event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"world_restored", &"assembly_spawned", &"assembly_changed", &"assembly_removed", &"assembly_split", &"assembly_merged":
			_snap_face_cache.apply_structural_event(event)
			_clear_resolve_result_cache()


func _resolve_cache_key(params: Dictionary) -> String:
	var ray_origin: Vector3 = params.get("ray_origin", Vector3.ZERO)
	var ray_direction: Vector3 = Vector3(
		params.get("ray_direction", Vector3.FORWARD)
	).normalized()
	var direct_hit: Dictionary = params.get("direct_hit", {})
	var target_id := StringName(direct_hit.get("target_id", &""))
	return "%d|%s|%s|%s|%d|%s|%s" % [
		_snap_face_cache.generation,
		_quantize_vec3(ray_origin, 0.04),
		_quantize_vec3(ray_direction, 0.02),
		params.get("archetype_id", "frame"),
		int(params.get("orientation_index", 0)),
		target_id,
		str(bool(direct_hit.get("valid", false))),
	]


static func _quantize_vec3(value: Vector3, step: float) -> Vector3:
	if step <= 0.0:
		return value
	return Vector3(
		snapped(value.x, step),
		snapped(value.y, step),
		snapped(value.z, step),
	)


func construction_resource_amount() -> float:
	if _session == null:
		return 0.0
	var store := _session.world.get_resource_store("player")
	return (
		store.amount("construction_component")
		if store != null else 0.0
	)


## Read-only accessor for presentation (HUD Inventory / StoreView). Returns the
## authoritative store so the HUD can render its amounts; the HUD only reads it
## and never mutates simulation state (see docs/specs/HUD-UI-01.md).
func resource_store(store_id: String) -> SimulationResourceStore:
	if _session == null:
		return null
	return _session.world.get_resource_store(store_id)


func archetype_display_name(archetype_id: String) -> String:
	var archetype := _get_archetype(archetype_id)
	if archetype == null or archetype.display_name.is_empty():
		return archetype_id
	return archetype.display_name


func _damage_element(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if (
		_session == null
		or StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return _result(&"invalid_target")
	var metadata: Dictionary = target.get("metadata", {})
	var element_id := int(metadata.get("element_id", 0))
	var parameters: Dictionary = command.get("parameters", {})
	var amount := float(parameters.get("damage", 0.0))
	return apply_damage(element_id, amount)


func apply_damage(element_id: int, amount: float) -> Dictionary:
	if _session == null:
		return _result(&"not_ready")
	var element := _session.world.get_element(element_id)
	if element == null:
		return _result(&"invalid_target")
	var command := DamageElementCommand.new()
	command.element_id = element_id
	command.expected_state_revision = element.state_revision
	command.damage = amount
	return _structural_result(
		_session.world.apply_structural_command_now(command)
	)


func _construction_apply(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if _session == null:
		return _place_block(command, target)
	var parameters: Dictionary = command.get("parameters", {})
	var target_kind := StringName(target.get("target_kind", &""))
	var construction_mode := StringName(
		parameters.get("construction_mode", &"context")
	)
	var archetype_id := str(parameters.get("archetype_id", "frame"))
	var orientation_index := int(parameters.get("orientation_index", 0))
	var placement_plan: Dictionary = parameters.get("placement_plan", {})

	if (
		construction_mode == &"place"
		and not placement_plan.is_empty()
	):
		if bool(placement_plan.get("valid", false)):
			return _apply_place_plan(placement_plan)
		return _result(
			_map_structural_reason(
				StringName(placement_plan.get("reason", &"invalid_target"))
			),
			placement_plan.get("data", {})
		)

	if target_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
		var metadata: Dictionary = target.get("metadata", {})
		var element := _session.world.get_element(
			int(metadata.get("element_id", 0))
		)
		if element == null:
			return _result(&"invalid_target")
		if (
			construction_mode == &"repair"
			or (
				construction_mode == &"context"
				and (
					element.is_broken()
					or (
						element.get_archetype() != null
						and element.integrity
						< element.get_archetype().max_integrity
					)
				)
			)
		):
			var repair := RepairElementCommand.new()
			repair.element_id = element.element_id
			repair.expected_state_revision = element.state_revision
			repair.store_id = "player"
			repair.max_material_amount = 1.0
			return _structural_result(
				_session.world.apply_structural_command_now(repair)
			)
		var place_plan := preview_construction(
			target,
			archetype_id,
			orientation_index
		)
		if bool(place_plan.get("valid", false)):
			return _apply_place_plan(place_plan)
		if construction_mode == &"repair":
			return _result(&"not_damaged")
		return _result(
			_map_structural_reason(
				StringName(place_plan.get("reason", &"invalid_target"))
			),
			place_plan.get("data", {})
		)

	var plan := preview_construction(
		target,
		archetype_id,
		orientation_index
	)
	if not bool(plan.get("valid", false)):
		return _result(
			_map_structural_reason(
				StringName(plan.get("reason", &"invalid_target"))
			),
			plan.get("data", {})
		)
	return _apply_place_plan(plan)


func _weld_element(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if (
		_session == null
		or StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return _result(&"invalid_target")
	var metadata: Dictionary = target.get("metadata", {})
	var element := _session.world.get_element(
		int(metadata.get("element_id", 0))
	)
	if element == null:
		return _result(&"invalid_target")
	if element.is_complete():
		return _result(&"already_complete")
	if element.is_broken():
		return _result(&"element_broken")
	var weld := WeldElementCommand.new()
	weld.element_id = element.element_id
	weld.expected_state_revision = element.state_revision
	weld.store_id = "player"
	weld.max_material_amount = 1.0
	return _structural_result(
		_session.world.apply_structural_command_now(weld)
	)


func _apply_place_plan(plan: Dictionary) -> Dictionary:
	var place := plan.get("command") as PlaceElementCommand
	var result := _session.world.apply_structural_command_now(place)
	if result.is_ok() and place.assembly_id == 0:
		var assembly_id := int(result.data["assembly_id"])
		var anchored := _session.world.assembly_has_anchor(assembly_id)
		var motion := GridSpawnUtil.motion_from_transform(
			plan["assembly_world_transform"],
			anchored
		)
		_session.projection.project_assembly_now(assembly_id, motion)
		_session.visuals.rebuild_assembly(assembly_id)
	return _structural_result(result)


## Reseats a first-on-ground placement so its footprint rests on the lowest
## terrain sample beneath it. Only shifts the continuous root along world +Y/-Y;
## the discrete grid frame (topology) is untouched. Non-ground plans (attaching
## to an existing assembly) and invalid plans pass through unchanged.
func _seat_ground_plan(plan: Dictionary) -> Dictionary:
	if _voxel_tool == null or not bool(plan.get("valid", false)):
		return plan
	var command := plan.get("command") as PlaceElementCommand
	if command == null or command.assembly_id != 0:
		return plan
	var archetype := plan.get("archetype") as ElementArchetype
	if archetype == null:
		return plan
	var root: Transform3D = plan.get(
		"assembly_world_transform", Transform3D.IDENTITY
	)
	var origin_cell: Vector3i = plan.get("origin_cell", Vector3i.ZERO)
	var orientation_index := int(plan.get("orientation_index", 0))
	var footprint := AABB()
	var has_box := false
	for collider: ColliderDefinition in archetype.colliders:
		if collider.shape_kind != ColliderDefinition.ShapeKind.BOX:
			continue
		var box := GridPoseUtil.collider_world_aabb(
			root, origin_cell, orientation_index, collider
		)
		if not has_box:
			footprint = box
			has_box = true
		else:
			footprint = footprint.merge(box)
	if not has_box:
		return plan
	var bottom_y := footprint.position.y
	var probe_from_y := bottom_y + footprint.size.y + 1.0
	var probe_distance := (probe_from_y - bottom_y) + 4.0
	var center := footprint.position + footprint.size * 0.5
	var lowest_surface := INF
	for sample: Vector2 in _GROUND_SEAT_SAMPLES:
		var hit: VoxelRaycastResult = _voxel_tool.raycast(
			Vector3(
				center.x + sample.x * footprint.size.x,
				probe_from_y,
				center.z + sample.y * footprint.size.z
			),
			Vector3.DOWN,
			probe_distance
		)
		if hit == null:
			continue
		lowest_surface = minf(lowest_surface, probe_from_y - hit.distance)
	if is_inf(lowest_surface):
		return plan
	var delta_y := (lowest_surface - GROUND_SEAT_EMBED) - bottom_y
	if absf(delta_y) < 0.0001:
		return plan
	var shift := Vector3(0.0, delta_y, 0.0)
	var seated := plan.duplicate(true)
	var seated_root := root.translated(shift)
	seated["assembly_world_transform"] = seated_root
	seated["preview_root_transform"] = seated_root
	var world_transform: Transform3D = plan.get(
		"world_transform", root
	)
	seated["world_transform"] = world_transform.translated(shift)
	return seated


func _get_archetype(archetype_id: String) -> ElementArchetype:
	if not _archetype_cache.has(archetype_id):
		_archetype_cache[archetype_id] = Slice01Archetypes.load_required(
			archetype_id
		)
	return _archetype_cache[archetype_id] as ElementArchetype


func _dismantle_element(
	_command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if (
		_session == null
		or StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return _result(&"invalid_target")
	var metadata: Dictionary = target.get("metadata", {})
	var element := _session.world.get_element(
		int(metadata.get("element_id", 0))
	)
	if element == null:
		return _result(&"invalid_target")
	var assembly := _session.world.get_assembly(element.assembly_id)
	if assembly == null:
		return _result(&"invalid_target")
	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = element.element_id
	dismantle.expected_assembly_revision = assembly.topology_revision
	dismantle.store_id = "player"
	return _structural_result(
		_session.world.apply_structural_command_now(dismantle)
	)


func _structural_result(
	result: StructuralCommandResult
) -> Dictionary:
	if result == null:
		return _result(&"not_ready")
	return _result(
		&"ok" if result.is_ok() else _map_structural_reason(result.reason),
		result.data
	)


func _map_structural_reason(reason: StringName) -> StringName:
	match reason:
		StructuralCommandResult.REASON_OVERLAP:
			return &"blocked"
		StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION:
			return &"blocked"
		StructuralCommandResult.REASON_MISALIGNED_CONNECTION:
			return &"blocked"
		StructuralCommandResult.REASON_STALE_REVISION:
			return &"not_ready"
		StructuralCommandResult.REASON_INVALID_REFERENCE:
			return &"invalid_target"
		StructuralCommandResult.REASON_INVALID_TRANSFORM:
			return &"invalid_target"
		_:
			return reason


func _result(
	reason: StringName,
	data: Dictionary = {}
) -> Dictionary:
	return {
		"status": &"ok" if reason == &"ok" else &"failed",
		"reason": reason,
		"data": data,
	}
