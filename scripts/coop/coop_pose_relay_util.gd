class_name CoopPoseRelayUtil
extends RefCounted


## Cold `players{}` extras for WorldPersistence.save (host only). Relay pose
## dicts keyed by uid — persistence normalizes to position/yaw rows.
static func export_cold_poses(session) -> Dictionary:
	var mode: int = session._mode
	if mode != CoopSession.Mode.HOST:
		return {}
	var last_poses: Dictionary = session._last_poses
	return last_poses.duplicate(true)


## After host restart: session last-pose cache starts empty; seed from cold
## save so rejoin `you_pose` works without a prior live relay this session.
static func seed_last_poses_from_cold(session) -> void:
	var local_uid: String = session._local_uid
	var last_poses: Dictionary = session._last_poses
	var cold := WorldPersistence.cold_relay_poses()
	for uid_variant: Variant in cold.keys():
		var uid := str(uid_variant)
		if uid.is_empty() or uid == local_uid:
			continue
		var pose: Variant = cold[uid_variant]
		if pose is Dictionary and (pose as Dictionary).has("p"):
			last_poses[uid] = pose


static func local_pose(session) -> Dictionary:
	var player: Node3D = session._player
	var gateway: WorldCommandGateway = session._gateway
	var tools: ToolController = session._tools
	var body_basis := player.global_transform.basis.orthonormalized()
	var head_basis := body_basis
	var camera := player.get_node_or_null("Camera") as Node3D
	if camera != null:
		head_basis = camera.global_transform.basis.orthonormalized()
	var lamp := player.get_node_or_null("Camera/MiningLight") as Node3D
	var velocity := Vector3.ZERO
	if "velocity" in player:
		velocity = player.get("velocity")
	var seat_id := 0
	if gateway != null:
		seat_id = gateway.get_local_seat_element_id()
	return {
		"p": player.global_position,
		"q": Quaternion(body_basis),
		"qh": Quaternion(head_basis),
		"l": lamp != null and lamp.visible,
		"v": velocity,
		"tool": tools.active_tool if tools != null else StringName(),
		"ta": tools != null and tools.is_drill_excavating(),
		"seat": seat_id,
	}


static func pose_position(pose: Dictionary) -> Vector3:
	return pose.get("p", Vector3.ZERO)


## A point `dist` metres to the side of `world_pos` along the local surface, so
## the joining client does not spawn inside the host's view.
static func tangent_offset(world_pos: Vector3, dist: float) -> Vector3:
	var up := world_pos.normalized()
	var tangent := up.cross(Vector3.RIGHT)
	if tangent.length_squared() < 0.01:
		tangent = up.cross(Vector3.FORWARD)
	return tangent.normalized() * dist
