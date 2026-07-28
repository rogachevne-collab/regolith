class_name CoopSeatControlRelayUtil
extends RefCounted


## Client: while seated as driver with local owner-sim, apply locomotion here
## (host is a kinematic ghost). PAX / missing-seat fallbacks unchanged.
static func tick_client_control_input(session, delta: float) -> void:
	if session._gateway == null:
		session._control_input_accum = 0.0
		session._seat_edge_dampeners = false
		session._seat_edge_parking_brake = false
		return
	var seat_id: int = session._gateway.get_local_seat_element_id()
	if seat_id <= 0:
		session._control_input_accum = 0.0
		session._seat_edge_dampeners = false
		session._seat_edge_parking_brake = false
		return
	# Cheap while-seated fallback: seat element or body gone → detach locally
	# (covers a lost force-release RPC after the host destroyed the cockpit).
	if not client_seat_replica_ok(session, seat_id):
		session._end_local_driver_physics()
		session._gateway.release_local_seat_attach()
		session._control_input_accum = 0.0
		session._seat_edge_dampeners = false
		session._seat_edge_parking_brake = false
		return
	session._gateway.ensure_local_seat_binding()
	if not session._gateway.is_local_seat_driver():
		session._control_input_accum = 0.0
		session._seat_edge_dampeners = false
		session._seat_edge_parking_brake = false
		return
	# Owner-authoritative: drive locally; state upload is separate.
	if session._local_physics_assembly_id > 0:
		session._gateway.tick_rover_locomotion_input()
		return
	# Legacy fallback if local sim failed to start — keep host input relay.
	var modal_blocks: bool = (
		session._player != null
		and session._player.has_method("is_gameplay_input_enabled")
		and not bool(session._player.call("is_gameplay_input_enabled"))
	)
	if not modal_blocks:
		if Input.is_action_just_pressed(&"toggle_dampeners"):
			session._seat_edge_dampeners = true
		if Input.is_action_just_pressed(&"toggle_parking_brake"):
			session._seat_edge_parking_brake = true
	session._control_input_accum += delta
	if session._control_input_accum < session.CONTROL_INPUT_INTERVAL:
		return
	session._control_input_accum = 0.0
	var raw: Dictionary = session._gateway.collect_seat_raw_input(modal_blocks)
	var edges := {
		"toggle_dampeners": session._seat_edge_dampeners,
		"toggle_parking_brake": session._seat_edge_parking_brake,
	}
	session._seat_edge_dampeners = false
	session._seat_edge_parking_brake = false
	session.rpc_id(1, "_srv_control_input", raw, edges)


static func client_seat_replica_ok(session, element_id: int) -> bool:
	if element_id <= 0 or session._session == null or session._session.world == null:
		return false
	var element: SimulationElement = session._session.world.get_element(element_id)
	if element == null or not element.is_operational():
		return false
	if session._session.projection == null:
		return false
	var body := (
		session._session.projection.get_element_projection(element_id).get("body")
		as PhysicsBody3D
	)
	return body != null and is_instance_valid(body)


static func srv_control_input(session, raw: Dictionary, edges: Dictionary) -> void:
	if session._mode != session.Mode.HOST or session._gateway == null:
		return
	var peer: int = session.multiplayer.get_remote_sender_id()
	var uid: String = session._registry.uid_of(peer)
	if uid.is_empty():
		return
	# Owner-sim guest already integrates loco locally; ignore stale input relay.
	for assembly_id_variant: Variant in session._remote_physics_owners.keys():
		if str(session._remote_physics_owners[assembly_id_variant]) == uid:
			return
	session._remote_driver_last_input_ms[uid] = Time.get_ticks_msec()
	session._gateway.apply_remote_driver_input(uid, raw, edges)


## Host → seated guest: seat destroyed / non-operational. Reliable on CH_MAIN.
static func notify_remote_seat_force_release(
	session,
	player_id: String,
	_seat_element_id: int,
	_assembly_id: int
) -> void:
	if session._mode != session.Mode.HOST or player_id.is_empty():
		return
	var peer: int = session._registry.peer_of(player_id)
	if peer <= 0:
		return
	session._remote_driver_last_input_ms.erase(player_id)
	CoopAssemblyStreamService.clear_remote_physics_owner_for_uid(session, player_id)
	session.rpc_id(peer, "_cli_force_seat_release")


static func cli_force_seat_release(session) -> void:
	if session._mode != session.Mode.CLIENT or session._gateway == null:
		return
	session._end_local_driver_physics()
	session._gateway.release_local_seat_attach()
	session._control_input_accum = 0.0
	session._seat_edge_dampeners = false
	session._seat_edge_parking_brake = false


static func tick_remote_driver_watchdog(session) -> void:
	if session._gateway == null or session._remote_driver_last_input_ms.is_empty():
		return
	var now: int = Time.get_ticks_msec()
	var stale: Array[String] = []
	for uid: String in session._remote_driver_last_input_ms.keys():
		if now - int(session._remote_driver_last_input_ms[uid]) > session.CONTROL_INPUT_STALE_MS:
			stale.append(uid)
	for uid: String in stale:
		session._gateway.clear_remote_driver_input(uid)
		session._remote_driver_last_input_ms.erase(uid)


static func clear_remote_driver(session, uid: String) -> void:
	if uid.is_empty() or session._gateway == null:
		return
	session._gateway.clear_remote_driver_input(uid)
	if session._session != null and session._session.world != null:
		session._session.world.clear_player_seat_context(uid)
	session._remote_driver_last_input_ms.erase(uid)
