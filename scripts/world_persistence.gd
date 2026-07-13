class_name WorldPersistence
extends RefCounted

const SAVE_PATH := "user://regolith_world_save.json"
const SAVE_VERSION := 1


static func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


static func read_payload() -> Dictionary:
	if not has_save():
		return {}
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
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
	var json := JSON.stringify(payload, "\t")
	var tmp_path := "%s.tmp" % SAVE_PATH
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_warning("WorldPersistence: cannot write %s" % tmp_path)
		return false
	file.store_string(json)
	file.close()
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)
	var rename_error := DirAccess.rename_absolute(tmp_path, SAVE_PATH)
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
		push_warning("WorldPersistence: snapshot restore rejected")
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


static func _backup_corrupt_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var backup_path := "%s.corrupt.%d" % [
		SAVE_PATH,
		int(Time.get_unix_time_from_system()),
	]
	DirAccess.rename_absolute(SAVE_PATH, backup_path)
