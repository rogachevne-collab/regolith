class_name WorldCommandGateway
extends Node

signal command_completed(command_id: int, result: Dictionary)

@export var terrain_path: NodePath = NodePath("../VoxelTerrain")
@export var placed_blocks_path: NodePath = NodePath("../PlacedBlocks")

var _terrain: VoxelTerrain
var _placed_blocks: Node
var _voxel_tool: VoxelTool
var _queue: Array[Dictionary] = []
var _flush_scheduled := false
var _next_command_id := 1


func _ready() -> void:
	_terrain = get_node(terrain_path)
	_placed_blocks = get_node(placed_blocks_path)
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


func _result(
	reason: StringName,
	data: Dictionary = {}
) -> Dictionary:
	return {
		"status": &"ok" if reason == &"ok" else &"failed",
		"reason": reason,
		"data": data,
	}
