class_name WorldCommandGateway
extends Node

signal command_completed(command_id: int, result: Dictionary)

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


func _ready() -> void:
	_terrain = get_node(terrain_path)
	_placed_blocks = get_node(placed_blocks_path)
	_session = get_node_or_null(simulation_session_path) as SimulationSession
	_voxel_tool = _terrain.get_voxel_tool()
	_voxel_tool.channel = VoxelBuffer.CHANNEL_SDF


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
		&"place_block":
			return _place_block(command, target)
		&"toggle_control_seat":
			return _toggle_control_seat(command, target)
		&"construction_apply":
			return _construction_apply(command, target)
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
	var archetype := Slice01Archetypes.load_required(archetype_id)
	return ConstructionPlacement.plan(
		_session.world,
		target,
		archetype,
		orientation_index
	)


func construction_resource_amount() -> float:
	if _session == null:
		return 0.0
	var store := _session.world.get_resource_store("player")
	return (
		store.amount("construction_component")
		if store != null else 0.0
	)


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
	if target_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
		var metadata: Dictionary = target.get("metadata", {})
		var element := _session.world.get_element(
			int(metadata.get("element_id", 0))
		)
		if element == null:
			return _result(&"invalid_target")
		if construction_mode == &"repair":
			var repair := RepairElementCommand.new()
			repair.element_id = element.element_id
			repair.expected_state_revision = element.state_revision
			repair.store_id = "player"
			repair.max_material_amount = 1.0
			return _structural_result(
				_session.world.apply_structural_command_now(repair)
			)
		if construction_mode == &"weld":
			var weld := WeldElementCommand.new()
			weld.element_id = element.element_id
			weld.expected_state_revision = element.state_revision
			weld.store_id = "player"
			weld.max_material_amount = 1.0
			return _structural_result(
				_session.world.apply_structural_command_now(weld)
			)
		if construction_mode == &"context" and element.is_broken():
			var repair := RepairElementCommand.new()
			repair.element_id = element.element_id
			repair.expected_state_revision = element.state_revision
			repair.store_id = "player"
			repair.max_material_amount = 1.0
			return _structural_result(
				_session.world.apply_structural_command_now(repair)
			)
		if construction_mode == &"context" and not element.is_complete():
			var weld := WeldElementCommand.new()
			weld.element_id = element.element_id
			weld.expected_state_revision = element.state_revision
			weld.store_id = "player"
			weld.max_material_amount = 1.0
			return _structural_result(
				_session.world.apply_structural_command_now(weld)
			)
		var archetype := element.get_archetype()
		if (
			construction_mode == &"context"
			and archetype != null
			and element.integrity < archetype.max_integrity
		):
			var repair := RepairElementCommand.new()
			repair.element_id = element.element_id
			repair.expected_state_revision = element.state_revision
			repair.store_id = "player"
			repair.max_material_amount = 1.0
			return _structural_result(
				_session.world.apply_structural_command_now(repair)
			)
		if construction_mode == &"weld":
			return _result(&"already_complete")
		if construction_mode == &"repair":
			return _result(&"not_damaged")

	var archetype_id := str(parameters.get("archetype_id", "frame"))
	var orientation_index := int(parameters.get("orientation_index", 0))
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
	var place := plan.get("command") as PlaceElementCommand
	var result := _session.world.apply_structural_command_now(place)
	if result.is_ok() and place.assembly_id == 0:
		var assembly_id := int(result.data["assembly_id"])
		var motion := GridSpawnUtil.motion_from_transform(
			plan["assembly_world_transform"],
			true
		)
		_session.projection.project_assembly_now(assembly_id, motion)
		_session.visuals.rebuild_all()
	return _structural_result(result)


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
