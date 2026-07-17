class_name WorldPersistence
extends RefCounted

const SAVE_PATH := "user://regolith_world_save.json"
const SAVE_VERSION := 1

## Optional override for alternate scenes (moon experiment). Empty → SAVE_PATH.
static var save_path_override := ""


static func active_save_path() -> String:
	if save_path_override.is_empty():
		return SAVE_PATH
	return save_path_override


static func has_save() -> bool:
	return FileAccess.file_exists(active_save_path())


static func read_payload() -> Dictionary:
	if not has_save():
		return {}
	var file := FileAccess.open(active_save_path(), FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not parsed is Dictionary:
		_backup_corrupt_save()
		return {}
	var payload: Dictionary = parsed
	if int(payload.get("save_version", 0)) != SAVE_VERSION:
		push_warning("WorldPersistence: save version mismatch")
		return {}
	if not save_path_override.is_empty():
		if (
			int(payload.get("generator_version", -1))
			!= MoonTerrainParams.GENERATOR_VERSION
		):
			push_warning("WorldPersistence: generator version mismatch")
			return {}
	return payload


static func save(world: SimulationWorld, player: Node3D) -> bool:
	if world == null or player == null:
		return false
	var payload := {
		"save_version": SAVE_VERSION,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
		"simulation": world.capture_snapshot(),
		"player": _serialize_player(player),
	}
	if not save_path_override.is_empty():
		payload["generator_version"] = MoonTerrainParams.GENERATOR_VERSION
	var json := JSON.stringify(payload, "\t")
	var path := active_save_path()
	var parent_dir := path.get_base_dir()
	if not parent_dir.is_empty() and not DirAccess.dir_exists_absolute(parent_dir):
		DirAccess.make_dir_recursive_absolute(parent_dir)
	var tmp_path := "%s.tmp" % path
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_warning("WorldPersistence: cannot write %s" % tmp_path)
		return false
	file.store_string(json)
	file.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var rename_error := DirAccess.rename_absolute(tmp_path, path)
	if rename_error != OK:
		push_warning(
			"WorldPersistence: rename failed (%s)" % error_string(rename_error)
		)
		return false
	return true


static func restore_snapshot_data(
	world: SimulationWorld,
	simulation: Dictionary
) -> bool:
	if world == null or simulation.is_empty():
		return false
	if not world.restore_snapshot(simulation, false):
		var detail := SimulationSnapshot.last_validate_error
		if detail.is_empty():
			detail = "unknown"
		push_warning(
			"WorldPersistence: snapshot restore rejected (%s)" % detail
		)
		return false
	return true


static func finalize_loaded_world(world: SimulationWorld) -> void:
	if world == null:
		return
	world.emit_world_restored()
	IndustryStoreService.sync_all_elements(world)
	world.ensure_cargo_graph_current()


static func load_into(world: SimulationWorld, player: Node3D) -> bool:
	var payload := read_payload()
	if payload.is_empty():
		return false
	var simulation: Variant = payload.get("simulation", {})
	if not simulation is Dictionary:
		_backup_corrupt_save()
		return false
	if not restore_snapshot_data(world, simulation):
		return false
	finalize_loaded_world(world)
	if player != null:
		_apply_player(player, payload.get("player", {}))
	return true


static func apply_player_view(
	player: Node3D,
	row: Variant,
	spawn_position: Vector3
) -> void:
	if player == null:
		return
	player.global_position = spawn_position
	if not row is Dictionary:
		return
	var data: Dictionary = row
	var head: Camera3D = player.get_node_or_null("Camera") as Camera3D
	if head != null and head.has_method("apply_view_angles"):
		head.call(
			"apply_view_angles",
			float(data.get("body_yaw", player.rotation.y)),
			float(data.get("head_pitch", 0.0)),
		)
	else:
		player.rotation.y = float(data.get("body_yaw", player.rotation.y))


static func _serialize_player(player: Node3D) -> Dictionary:
	var row := {
		"body_yaw": player.rotation.y,
	}
	var pos := player.global_position
	if _is_usable_save_position(pos):
		row["position"] = [pos.x, pos.y, pos.z]
	var head: Camera3D = player.get_node_or_null("Camera") as Camera3D
	if head != null and head.has_method("view_angles"):
		var angles: Vector2 = head.call("view_angles")
		row["body_yaw"] = angles.x
		row["head_pitch"] = angles.y
	return row


static func _apply_player(player: Node3D, row: Variant) -> void:
	if not row is Dictionary:
		return
	var data: Dictionary = row
	var position_data: Variant = data.get("position", [])
	var spawn_position := player.global_position
	if position_data is Array and position_data.size() >= 3:
		var saved := Vector3(
			float(position_data[0]),
			float(position_data[1]),
			float(position_data[2]),
		)
		if _is_usable_save_position(saved):
			spawn_position = saved
	apply_player_view(player, row, spawn_position)


static func _is_usable_save_position(pos: Vector3) -> bool:
	if not pos.is_finite():
		return false
	if absf(pos.x) < 0.25 and absf(pos.z) < 0.25 and pos.y < 2.0:
		return false
	return true


static func backup_rejected_save() -> String:
	return _backup_save_with_suffix("rejected")


static func _backup_corrupt_save() -> void:
	_backup_save_with_suffix("corrupt")


static func _backup_save_with_suffix(suffix: String) -> String:
	var path := active_save_path()
	if not FileAccess.file_exists(path):
		return ""
	var backup_path := "%s.%s.%d" % [
		path,
		suffix,
		int(Time.get_unix_time_from_system()),
	]
	var rename_error := DirAccess.rename_absolute(path, backup_path)
	if rename_error != OK:
		push_warning(
			"WorldPersistence: failed to backup save (%s)"
			% error_string(rename_error)
		)
		return ""
	return backup_path
