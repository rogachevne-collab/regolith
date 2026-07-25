class_name WorldPersistence
extends RefCounted

const SAVE_PATH := "user://regolith_world_save.json"
## v4: cold `players{}` pose map keyed by player_uid (was singular `player` in
## v3). Hotbar/tool inventories stay per-uid inside the simulation snapshot.
## No converter — unreleased game, local dev saves; read_payload discards
## mismatched versions (wipe OK).
const SAVE_VERSION := 4

## Optional override for alternate scenes (moon experiment). Empty → SAVE_PATH.
static var save_path_override := ""

## Player map annotations (MAP-UI-01). Not part of the simulation snapshot —
## stored alongside player poses in world_save.json.
static var _map_markers: Array = []

## Cold pose map: uid -> {"pose": {position, body_yaw, head_pitch}}. Merged on
## every save so guest poses survive host-only autosaves before rejoin.
static var _players: Dictionary = {}


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


static func get_map_markers() -> Array:
	return _map_markers.duplicate(true)


static func set_map_markers(markers: Array) -> void:
	_map_markers = markers.duplicate(true)


static func clear_map_markers() -> void:
	_map_markers = []


static func clear_players() -> void:
	_players = {}


## Pose row for `uid` from the in-memory cold map (after load / last save).
static func player_pose_row(uid: String) -> Dictionary:
	if uid.is_empty() or not _players.has(uid):
		return {}
	var entry: Variant = _players[uid]
	if not entry is Dictionary:
		return {}
	return _pose_row_from_entry(entry as Dictionary)


## uid -> {"p": Vector3} for CoopSession `_last_poses` seed after host restart.
static func cold_relay_poses() -> Dictionary:
	var out := {}
	for uid_variant: Variant in _players.keys():
		var uid := str(uid_variant)
		if uid.is_empty():
			continue
		var row := player_pose_row(uid)
		var pos := _position_from_pose_row(row)
		if not pos.is_finite():
			continue
		if not _is_usable_save_position(pos):
			continue
		out[uid] = {"p": pos}
	return out


static func save(
	world: SimulationWorld,
	player: Node3D,
	extra_player_poses: Dictionary = {}
) -> bool:
	if world == null or player == null:
		return false
	_merge_players_for_save(player, extra_player_poses)
	var payload := {
		"save_version": SAVE_VERSION,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
		"simulation": world.capture_snapshot(),
		"players": _players.duplicate(true),
		"map_markers": _map_markers.duplicate(true),
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
		clear_map_markers()
		clear_players()
		return false
	var simulation: Variant = payload.get("simulation", {})
	if not simulation is Dictionary:
		_backup_corrupt_save()
		clear_map_markers()
		clear_players()
		return false
	if not restore_snapshot_data(world, simulation):
		return false
	finalize_loaded_world(world)
	restore_players_from_payload(payload)
	_restore_map_markers(payload.get("map_markers", []))
	if player != null:
		_apply_player(player, player_pose_row(PlayerIdentity.local_uid()))
	return true


static func restore_map_markers_from_payload(payload: Dictionary) -> void:
	_restore_map_markers(payload.get("map_markers", []))


static func restore_players_from_payload(payload: Dictionary) -> void:
	_players = {}
	var raw: Variant = payload.get("players", {})
	if not raw is Dictionary:
		return
	for uid_variant: Variant in (raw as Dictionary).keys():
		var uid := str(uid_variant).strip_edges()
		if uid.is_empty():
			continue
		var entry: Variant = (raw as Dictionary)[uid_variant]
		if not entry is Dictionary:
			continue
		var pose := _pose_row_from_entry(entry as Dictionary)
		if pose.is_empty():
			continue
		_players[uid] = {"pose": pose}


static func _restore_map_markers(raw: Variant) -> void:
	_map_markers = []
	if not raw is Array:
		return
	for item: Variant in raw:
		if not item is Dictionary:
			continue
		var row: Dictionary = item
		var marker_id := str(row.get("id", "")).strip_edges()
		var label := str(row.get("label", "")).strip_edges()
		var pos_data: Variant = row.get("position", [])
		if marker_id.is_empty() or not pos_data is Array:
			continue
		var pos_arr: Array = pos_data
		if pos_arr.size() < 3:
			continue
		var pos := Vector3(
			float(pos_arr[0]),
			float(pos_arr[1]),
			float(pos_arr[2]),
		)
		if not pos.is_finite():
			continue
		_map_markers.append({
			"id": marker_id,
			"label": label if not label.is_empty() else marker_id,
			"position": [pos.x, pos.y, pos.z],
		})


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


static func _merge_players_for_save(
	player: Node3D,
	extra_player_poses: Dictionary
) -> void:
	var local_uid := PlayerIdentity.local_uid()
	if not local_uid.is_empty():
		_players[local_uid] = {"pose": _serialize_player(player)}
	for uid_variant: Variant in extra_player_poses.keys():
		var uid := str(uid_variant).strip_edges()
		if uid.is_empty() or uid == local_uid:
			continue
		var pose := _normalize_pose_variant(extra_player_poses[uid_variant])
		if pose.is_empty():
			continue
		_players[uid] = {"pose": pose}


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


## Accept cold pose row, players{} entry, or coop relay pose (`p` Vector3).
static func _normalize_pose_variant(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	var data: Dictionary = raw
	if data.has("pose"):
		return _normalize_pose_variant(data.get("pose"))
	if data.has("p"):
		var p: Variant = data.get("p")
		var pos := Vector3.ZERO
		if p is Vector3:
			pos = p as Vector3
		elif p is Array and (p as Array).size() >= 3:
			var arr: Array = p
			pos = Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
		else:
			return {}
		if not _is_usable_save_position(pos):
			return {}
		var row := {"position": [pos.x, pos.y, pos.z]}
		var q: Variant = data.get("q")
		if q is Quaternion:
			var euler: Vector3 = (q as Quaternion).get_euler()
			row["body_yaw"] = euler.y
		return row
	return _pose_row_from_entry(data)


static func _pose_row_from_entry(entry: Dictionary) -> Dictionary:
	var pose_variant: Variant = entry.get("pose", entry)
	if not pose_variant is Dictionary:
		return {}
	var data: Dictionary = pose_variant
	var row := {}
	var position_data: Variant = data.get("position", [])
	if position_data is Array and (position_data as Array).size() >= 3:
		var arr: Array = position_data
		var pos := Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
		if _is_usable_save_position(pos):
			row["position"] = [pos.x, pos.y, pos.z]
	if data.has("body_yaw"):
		row["body_yaw"] = float(data.get("body_yaw", 0.0))
	if data.has("head_pitch"):
		row["head_pitch"] = float(data.get("head_pitch", 0.0))
	return row


static func _position_from_pose_row(row: Dictionary) -> Vector3:
	var position_data: Variant = row.get("position", [])
	if position_data is Array and (position_data as Array).size() >= 3:
		var arr: Array = position_data
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return Vector3(NAN, NAN, NAN)


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
