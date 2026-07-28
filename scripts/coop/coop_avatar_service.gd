class_name CoopAvatarService
extends RefCounted


static func spawn_avatar(session, uid: String, nick: String) -> RemotePlayer:
	if session._avatars.has(uid):
		var existing: RemotePlayer = session._avatars[uid] as RemotePlayer
		flush_pose_inbox_to(session, uid, existing)
		return existing
	var avatar: RemotePlayer = session.RemotePlayerScene.instantiate() as RemotePlayer
	avatar.setup(uid, nick)
	avatar.set_seat_transform_resolver(session.resolve_seat_world_transform)
	session._avatars_root.add_child(avatar)
	session._avatars[uid] = avatar
	flush_pose_inbox_to(session, uid, avatar)
	# R-COOP-7: host must stream terrain around remote diggers (guest dig far
	# from host player → is_area_editable). Clients keep only the local viewer.
	if session._mode == session.Mode.HOST:
		avatar.enable_host_stream_proxy()
	return avatar


static func flush_pose_inbox_to(session, uid: String, avatar: RemotePlayer) -> void:
	if avatar == null or not session._pose_inbox.has(uid):
		return
	var pose: Variant = session._pose_inbox[uid]
	session._pose_inbox.erase(uid)
	if pose is Dictionary:
		avatar.push_pose(pose)


static func despawn_avatar(session, uid: String) -> void:
	if not session._avatars.has(uid):
		return
	var avatar: RemotePlayer = session._avatars[uid] as RemotePlayer
	if is_instance_valid(avatar):
		avatar.queue_free()
	session._avatars.erase(uid)
	session._pose_inbox.erase(uid)
