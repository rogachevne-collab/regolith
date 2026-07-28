class_name CoopCommandRouteService
extends RefCounted


## Installed as the gateway's client hook. Blocked kinds fail locally; the rest
## go to the host, stripped of live Objects.
static func on_local_submit(session, local_id: int, command: Dictionary) -> void:
	var kind := StringName(command.get("kind", &""))
	if CoopCommandCodec.is_kind_blocked(kind):
		session._gateway.call_deferred("complete_remote", local_id, {
			"status": &"failed",
			"reason": &"not_in_coop_yet",
			"data": {},
			"command_kind": kind,
		})
		return
	session.rpc_id(1, "_srv_submit", local_id, CoopCommandCodec.sanitize_command(command))


static func srv_submit(session, local_id: int, command: Dictionary) -> void:
	if session._mode != session.Mode.HOST:
		return
	var peer: int = session.multiplayer.get_remote_sender_id()
	if not session._registry.has_peer(peer):
		return
	var kind := StringName(command.get("kind", &""))
	if CoopCommandCodec.is_kind_blocked(kind):
		session.rpc_id(peer, "_cli_result", local_id, {
			"status": &"failed", "reason": &"not_in_coop_yet",
			"data": {}, "command_kind": kind,
		})
		return
	route_guest_submit(session, peer, local_id, command, 0)


static func cli_result(session, local_id: int, result: Dictionary) -> void:
	if (
		session._gateway != null
		and StringName(result.get("command_kind", &"")) == &"toggle_control_seat"
		and StringName(result.get("status", &"")) == &"ok"
	):
		var data: Dictionary = result.get("data", {})
		if bool(data.get("seated", false)):
			var assembly_id := int(data.get("assembly_id", 0))
			var passenger := bool(data.get("passenger", false))
			var runtimes: Variant = data.get("industry_runtimes", {})
			if runtimes is Dictionary and not (runtimes as Dictionary).is_empty():
				var world: SimulationWorld = session._world()
				if world != null:
					world.sync_industry_element_runtimes(runtimes)
			session._gateway.apply_local_seat_attach(
				session._player,
				int(data.get("element_id", 0)),
				assembly_id,
				passenger
			)
			if not passenger and assembly_id > 0:
				session._begin_local_driver_physics(assembly_id)
		else:
			session._end_local_driver_physics()
			session._gateway.release_local_seat_attach()
	session._gateway.complete_remote(local_id, result)


static func on_host_command_completed(session, command_id: int, result: Dictionary) -> void:
	var seat_peer := 0
	var seat_uid := ""
	if session._pending_results.has(command_id):
		var route: Array = session._pending_results[command_id]
		session._pending_results.erase(command_id)
		var peer := int(route[0])
		var local_id := int(route[1])
		var command: Dictionary = route[2]
		var attempts := int(route[3])
		seat_peer = peer
		seat_uid = session._registry.uid_of(peer)
		if CoopDigRelayUtil.should_soft_retry_guest_dig(session, result, attempts):
			session._guest_dig_retries.append({
				"peer": peer,
				"local_id": local_id,
				"command": command,
				"attempts": attempts + 1,
				"wait": session.GUEST_DIG_RETRY_INTERVAL,
			})
			return
		session.rpc_id(peer, "_cli_result", local_id, CoopCommandCodec.sanitize_result(result))
	CoopAssemblyStreamService.host_update_physics_ownership_from_seat(
		session, result, seat_peer, seat_uid
	)
	if StringName(result.get("status", &"")) != &"ok":
		return
	if session.NO_BROADCAST_KINDS.has(StringName(result.get("command_kind", &""))):
		return
	CoopSnapshotBroadcastUtil.mark_snapshot_dirty(session)


static func route_guest_submit(
	session,
	peer: int,
	local_id: int,
	command: Dictionary,
	attempts: int
) -> void:
	if not session._registry.has_peer(peer) or session._gateway == null:
		return
	var host_id: int = session._gateway.submit_as(
		session._registry.uid_of(peer),
		command,
		session._registry.avatar_of(peer)
	)
	session._pending_results[host_id] = [peer, local_id, command, attempts]
