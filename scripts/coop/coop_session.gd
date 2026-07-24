class_name CoopSession
extends Node
## COOP-HOST-V0 stage 3 transport. One node, identical NodePath on every peer,
## so all @rpc methods resolve. Owns the ENet peer, the host peer registry, the
## pose relay, the snapshot re-broadcast, the console commands and the
## join/leave flow. The gateway gets one thin client hook; nothing else in the
## game touches `multiplayer`.
##
## Stage 3 scope: see each other move and build together (full-snapshot
## re-broadcast). Terrain digging, rovers-in-motion between snapshots, seats and
## per-peer save state are later stages — see docs/specs/COOP-HOST-V0.md.

const RemotePlayerScene := preload("res://scenes/remote_player.tscn")

const PORT_DEFAULT := 7777
const MAX_PEERS := 8
const CHANNELS := 4
const CH_MAIN := 0        # handshake, commands, results, peer up/down (reliable)
const CH_BULK := 1        # join payload + snapshot broadcasts (reliable)
const CH_STREAM := 2      # poses + suit sync (unreliable_ordered)

const POSE_INTERVAL := 0.05        # 20 Hz
const SUIT_INTERVAL := 1.0
const SNAPSHOT_DEBOUNCE := 0.3
const SNAPSHOT_FLOOR_MS := 1000
const NICK_PATH := "user://player_nick.txt"
## Loopback single-instance mutex. The first game process on a machine binds it;
## a second process (two windows for testing) fails to bind, learns it is a
## secondary instance, and takes a distinct session uid — otherwise both would
## read the same user://player_uid.txt and coop would mistake them for the same
## player. Different machines each bind their own, so real peers are unaffected.
const INSTANCE_LOCK_PORT := 47800

## Host command kinds that must NOT trigger a snapshot broadcast (terrain /
## granular churn — host drilling would storm client rebuilds). Everything else
## that completes ok marks the world dirty.
const NO_BROADCAST_KINDS := {
	&"voxel_remove": true,
	&"dig_terrain_debris": true,
	&"scoop_spoil": true,
	&"dump_scoop": true,
	&"debug_spawn_spoil": true,
}

enum Mode { OFFLINE, HOST, CLIENT }

@export var gateway_path: NodePath = ^"../WorldCommandGateway"
@export var session_path: NodePath = ^"../SimulationSession"
@export var player_path: NodePath = ^"../Player"
@export var meteorites_path: NodePath = ^"../MeteoriteSystem"

var _mode := Mode.OFFLINE
var _gateway: WorldCommandGateway
var _session: SimulationSession
var _player: Node3D
var _meteorites: Node
## Untyped so dynamic method calls (is_world_ready, and the two spawn/persist
## coroutines) dispatch and `await` correctly against bootstrap.gd.
var _bootstrap

var _local_uid := ""
var _local_nick := ""

var _registry := CoopPeerRegistry.new()          # host only
var _pending_results: Dictionary = {}            # host: host_cmd_id -> [peer, local_id]
var _avatars: Dictionary = {}                    # uid -> RemotePlayer
var _avatars_root: Node3D

var _pose_accum := 0.0
var _suit_accum := 0.0
var _snapshot_dirty := false
var _snapshot_debounce := 0.0
var _last_broadcast_ms := 0
var _host_hooks_connected := false
## Held for the process lifetime by the primary instance (see INSTANCE_LOCK_PORT).
var _instance_lock: PacketPeerUDP


func _ready() -> void:
	_gateway = get_node_or_null(gateway_path) as WorldCommandGateway
	_session = get_node_or_null(session_path) as SimulationSession
	_player = get_node_or_null(player_path) as Node3D
	_meteorites = get_node_or_null(meteorites_path)
	_bootstrap = get_parent()

	_avatars_root = Node3D.new()
	_avatars_root.name = "RemoteAvatars"
	add_child(_avatars_root)

	if not _apply_sandbox_override():
		_apply_instance_disambiguation()
	_local_uid = PlayerIdentity.local_uid()
	_local_nick = _load_nick()

	_register_console_commands()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _exit_tree() -> void:
	for name: String in ["host", "join", "leave", "nick", "coop_status"]:
		if LimboConsole != null and LimboConsole.has_method("unregister_command"):
			LimboConsole.unregister_command(name)


func _physics_process(delta: float) -> void:
	if _mode == Mode.OFFLINE:
		return
	_pose_accum += delta
	if _pose_accum >= POSE_INTERVAL:
		_pose_accum = 0.0
		_send_local_pose()
	if _mode == Mode.HOST:
		_tick_snapshot_broadcast(delta)
		_suit_accum += delta
		if _suit_accum >= SUIT_INTERVAL:
			_suit_accum = 0.0
			_broadcast_suits()


# ---------------------------------------------------------------- setup helpers

## For running two instances on one machine: `-- --coop-sandbox=<label>` isolates
## this instance's user:// stream/save and pins a distinct uid, so the guest
## does not collide with the host on uid or fight it for the dig SQLite lock.
## Runs before bootstrap._ready (child readies first), so the stream label lands
## before the dig stream is configured.
func _apply_sandbox_override() -> bool:
	var label := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--coop-sandbox="):
			label = arg.substr("--coop-sandbox=".length())
	if label.is_empty():
		return false
	MoonTerrainParams.set_test_stream_label("coop_" + label)
	PlayerIdentity.override_local_uid("sandbox_" + label)
	if _gateway != null:
		_gateway.actor_uid = PlayerIdentity.local_uid()
	print("CoopSession: sandbox '%s', uid=%s" % [label, PlayerIdentity.local_uid()])
	return true


## Give a second game process on this machine a distinct uid, so two windows can
## host+join each other without the --coop-sandbox flag. The primary binds the
## loopback mutex port and keeps its stable saved uid; a secondary fails the bind
## and appends a random session suffix. Real peers on other machines each bind
## successfully and keep their own stable uid.
func _apply_instance_disambiguation() -> void:
	var lock := PacketPeerUDP.new()
	if lock.bind(INSTANCE_LOCK_PORT, "127.0.0.1") == OK:
		_instance_lock = lock
		return
	var base := PlayerIdentity.local_uid()
	var distinct := "%s_w%08x" % [base, randi()]
	PlayerIdentity.override_local_uid(distinct)
	if _gateway != null:
		_gateway.actor_uid = PlayerIdentity.local_uid()
	print("CoopSession: secondary instance on this machine, uid=%s" % distinct)


func _load_nick() -> String:
	if FileAccess.file_exists(NICK_PATH):
		var file := FileAccess.open(NICK_PATH, FileAccess.READ)
		if file != null:
			var stored := file.get_as_text().strip_edges()
			if not stored.is_empty():
				return stored
	return _local_uid.substr(0, 6)


func _save_nick(nick: String) -> void:
	var file := FileAccess.open(NICK_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(nick)


func _register_console_commands() -> void:
	if LimboConsole == null:
		return
	LimboConsole.register_command(_cmd_host, "host", "Coop: host a session [port]")
	LimboConsole.register_command(_cmd_join, "join", "Coop: join a host <ip> [port]")
	LimboConsole.register_command(_cmd_leave, "leave", "Coop: leave the session")
	LimboConsole.register_command(_cmd_nick, "nick", "Coop: set your display name <name>")
	LimboConsole.register_command(_cmd_coop_status, "coop_status", "Coop: connection status")


func _world() -> SimulationWorld:
	return _session.world if _session != null else null


# --------------------------------------------------------------- console commands

func _cmd_host(port: int = PORT_DEFAULT) -> void:
	if _mode != Mode.OFFLINE:
		_err("already in a coop session — leave first")
		return
	if _bootstrap == null or not _bootstrap.is_world_ready():
		_err("world is still loading; try again in a moment")
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PEERS, CHANNELS)
	if err != OK:
		_err("could not host on port %d (error %d)" % [port, err])
		return
	multiplayer.multiplayer_peer = peer
	_mode = Mode.HOST
	_registry = CoopPeerRegistry.new()
	_pending_results.clear()
	_connect_host_hooks()
	_info("hosting on port %d as '%s' — share your Tailscale IP" % [port, _local_nick])


func _cmd_join(ip: String, port: int = PORT_DEFAULT) -> void:
	if _mode != Mode.OFFLINE:
		_err("already in a coop session — leave first")
		return
	if _bootstrap == null or not _bootstrap.is_world_ready():
		_err("world is still loading; try again in a moment")
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port, CHANNELS)
	if err != OK:
		_err("could not reach %s:%d (error %d)" % [ip, port, err])
		return
	multiplayer.multiplayer_peer = peer
	_mode = Mode.CLIENT
	_info("connecting to %s:%d ..." % [ip, port])


func _cmd_leave() -> void:
	if _mode == Mode.OFFLINE:
		_info("not in a coop session")
		return
	if _mode == Mode.HOST:
		_teardown_host()
	else:
		_teardown_client_and_reload()


func _cmd_nick(new_name: String) -> void:
	var clean := new_name.strip_edges()
	if clean.is_empty():
		_err("nick cannot be empty")
		return
	_local_nick = clean
	_save_nick(clean)
	_info("nick set to '%s'" % clean)
	if _mode == Mode.CLIENT:
		rpc_id(1, "_srv_set_nick", clean)
	elif _mode == Mode.HOST:
		rpc("_cli_peer_nick", _local_uid, clean)


func _cmd_coop_status() -> void:
	match _mode:
		Mode.OFFLINE:
			_info("coop: offline")
		Mode.HOST:
			_info("coop: HOSTING, %d peer(s)" % _registry.peer_ids().size())
			for peer_id: int in _registry.peer_ids():
				_info("  #%d %s (%s)" % [peer_id, _registry.nick_of(peer_id), _registry.uid_of(peer_id).substr(0, 6)])
		Mode.CLIENT:
			_info("coop: CLIENT, %d other avatar(s)" % _avatars.size())


# ------------------------------------------------------------------- host: join

func _on_peer_connected(peer_id: int) -> void:
	# Transport-level connect. Host waits for the peer's hello before admitting.
	if _mode == Mode.HOST:
		print("CoopSession: peer %d connected, awaiting hello" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if _mode != Mode.HOST:
		return
	var uid := _registry.uid_of(peer_id)
	_registry.unregister(peer_id)
	_despawn_avatar(uid)
	rpc("_cli_peer_left", uid)
	_info("a player left")


@rpc("any_peer", "call_remote", "reliable", CH_MAIN)
func _srv_hello(hello: Dictionary) -> void:
	if _mode != Mode.HOST:
		return
	var peer := multiplayer.get_remote_sender_id()
	if not _bootstrap.is_world_ready():
		_reject(peer, &"host_not_ready")
		return
	var compat := CoopCommandCodec.validate_handshake_fields(hello)
	if compat != &"ok":
		_reject(peer, compat)
		return
	var uid := String(hello.get("uid", ""))
	var nick := String(hello.get("nick", uid.substr(0, 6)))
	if uid.is_empty():
		_reject(peer, &"no_uid")
		return
	if uid == _local_uid:
		# Same identity as the host — two windows on one machine without the
		# --coop-sandbox flag, or a copied player_uid.txt. Refuse loudly instead
		# of letting them silently fail to see each other.
		_reject(peer, &"uid_is_host")
		return
	var reg := _registry.register(peer, uid, nick)
	if reg != &"ok":
		_reject(peer, reg)
		return
	_seed_joiner(uid)
	var avatar := _spawn_avatar(uid, nick)
	_registry.set_avatar(peer, avatar)
	var payload := CoopCommandCodec.make_join_payload(
		_world().capture_snapshot(),
		_registry.peers_payload(),
		_local_uid,
		_local_nick,
		_local_pose(),
		peer
	)
	rpc_id(peer, "_cli_join_payload", payload)
	for other: int in _registry.peer_ids():
		if other != peer:
			rpc_id(other, "_cli_peer_joined", {"uid": uid, "nick": nick})
	_info("'%s' joined" % nick)


func _reject(peer_id: int, reason: StringName) -> void:
	rpc_id(peer_id, "_cli_join_denied", reason)
	_registry.unregister(peer_id)
	multiplayer.multiplayer_peer.disconnect_peer(peer_id)
	_info("rejected a join: %s" % reason)


func _seed_joiner(uid: String) -> void:
	var world := _world()
	if world == null:
		return
	world.ensure_suit_state(uid)
	if world.get_resource_store(PlayerIdentity.store_id(uid)) == null:
		IndustryStoreService.seed_player_starter_resources(world, uid)


# ----------------------------------------------------------------- client: join

func _on_connected_to_server() -> void:
	rpc_id(1, "_srv_hello", CoopCommandCodec.make_hello(_local_uid, _local_nick))
	_info("connected — requesting world ...")


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	_mode = Mode.OFFLINE
	_err("connection failed — is the host up and the IP right?")


func _on_server_disconnected() -> void:
	_err("host disconnected — returning to your world")
	_teardown_client_and_reload()


@rpc("authority", "call_remote", "reliable", CH_MAIN)
func _cli_join_denied(reason: StringName) -> void:
	if reason == &"uid_is_host" or reason == &"uid_conflict":
		_err("join denied: same player identity as the host. Two windows on one machine need '-- --coop-sandbox=guest' on the second, or use 127.0.0.1.")
	else:
		_err("join denied by host: %s" % reason)
	multiplayer.multiplayer_peer = null
	_mode = Mode.OFFLINE


@rpc("authority", "call_remote", "reliable", CH_BULK)
func _cli_join_payload(payload: Dictionary) -> void:
	var verdict := CoopCommandCodec.validate_join_payload(payload)
	if verdict != &"ok":
		_err("cannot join: %s" % verdict)
		multiplayer.multiplayer_peer = null
		_mode = Mode.OFFLINE
		return
	await _apply_join(payload)


func _apply_join(payload: Dictionary) -> void:
	# Flush this machine's own save first, then stop persisting the replica.
	await _bootstrap.save_now_then_inhibit_persistence()

	var world := _world()
	world.authoritative = false
	world.restore_snapshot(payload["snapshot"])

	if _meteorites != null:
		_meteorites.set("enabled", false)
		if "debug_spawn_enabled" in _meteorites:
			_meteorites.set("debug_spawn_enabled", false)
		_meteorites.set_process(false)
		_meteorites.set_physics_process(false)

	_gateway.set_network_submit(_on_local_submit)

	var host_info: Dictionary = payload["host"]
	var host_uid := String(host_info["uid"])
	var host_avatar := _spawn_avatar(host_uid, String(host_info["nick"]))
	host_avatar.push_pose(host_info["pose"])
	var peers: Dictionary = payload.get("peers", {})
	for peer_key: Variant in peers:
		var row: Dictionary = peers[peer_key]
		var uid := String(row.get("uid", ""))
		if uid.is_empty() or uid == _local_uid or uid == host_uid:
			continue
		_spawn_avatar(uid, String(row.get("nick", uid.substr(0, 6))))

	var host_pos: Vector3 = _pose_position(host_info["pose"])
	await _bootstrap.reseat_player_near(host_pos + _tangent_offset(host_pos, 4.0))
	_info("joined '%s' — welcome to their Moon" % String(host_info["nick"]))


@rpc("authority", "call_remote", "reliable", CH_MAIN)
func _cli_peer_joined(info: Dictionary) -> void:
	var uid := String(info.get("uid", ""))
	if uid.is_empty() or uid == _local_uid:
		return
	_spawn_avatar(uid, String(info.get("nick", uid.substr(0, 6))))
	_info("'%s' joined" % String(info.get("nick", "")))


@rpc("authority", "call_remote", "reliable", CH_MAIN)
func _cli_peer_left(uid: String) -> void:
	_despawn_avatar(uid)
	_info("a player left")


@rpc("any_peer", "call_remote", "reliable", CH_MAIN)
func _srv_set_nick(nick: String) -> void:
	if _mode != Mode.HOST:
		return
	var peer := multiplayer.get_remote_sender_id()
	var uid := _registry.uid_of(peer)
	if uid.is_empty():
		return
	_registry.set_nick(peer, nick)
	rpc("_cli_peer_nick", uid, nick)


@rpc("authority", "call_remote", "reliable", CH_MAIN)
func _cli_peer_nick(uid: String, nick: String) -> void:
	if _avatars.has(uid):
		(_avatars[uid] as RemotePlayer).set_nick(nick)


# --------------------------------------------------------------- commands (RPC)

## Installed as the gateway's client hook. Blocked kinds fail locally; the rest
## go to the host, stripped of live Objects.
func _on_local_submit(local_id: int, command: Dictionary) -> void:
	var kind := StringName(command.get("kind", &""))
	if CoopCommandCodec.is_kind_blocked(kind):
		_gateway.call_deferred("complete_remote", local_id, {
			"status": &"failed",
			"reason": &"not_in_coop_yet",
			"data": {},
			"command_kind": kind,
		})
		return
	rpc_id(1, "_srv_submit", local_id, CoopCommandCodec.sanitize_command(command))


@rpc("any_peer", "call_remote", "reliable", CH_MAIN)
func _srv_submit(local_id: int, command: Dictionary) -> void:
	if _mode != Mode.HOST:
		return
	var peer := multiplayer.get_remote_sender_id()
	if not _registry.has_peer(peer):
		return
	var kind := StringName(command.get("kind", &""))
	if CoopCommandCodec.is_kind_blocked(kind):
		rpc_id(peer, "_cli_result", local_id, {
			"status": &"failed", "reason": &"not_in_coop_yet",
			"data": {}, "command_kind": kind,
		})
		return
	var host_id := _gateway.submit_as(
		_registry.uid_of(peer),
		command,
		_registry.avatar_of(peer)
	)
	_pending_results[host_id] = [peer, local_id]


@rpc("authority", "call_remote", "reliable", CH_MAIN)
func _cli_result(local_id: int, result: Dictionary) -> void:
	_gateway.complete_remote(local_id, result)


func _on_host_command_completed(command_id: int, result: Dictionary) -> void:
	if _pending_results.has(command_id):
		var route: Array = _pending_results[command_id]
		_pending_results.erase(command_id)
		rpc_id(int(route[0]), "_cli_result", int(route[1]), CoopCommandCodec.sanitize_result(result))
	if StringName(result.get("status", &"")) != &"ok":
		return
	if NO_BROADCAST_KINDS.has(StringName(result.get("command_kind", &""))):
		return
	_mark_snapshot_dirty()


func _on_host_structural_event(event: Dictionary) -> void:
	if StringName(event.get("kind", &"")) == &"world_restored":
		return
	_mark_snapshot_dirty()


# ------------------------------------------------------------ snapshot broadcast

func _mark_snapshot_dirty() -> void:
	_snapshot_dirty = true
	_snapshot_debounce = SNAPSHOT_DEBOUNCE


func _tick_snapshot_broadcast(delta: float) -> void:
	if not _snapshot_dirty:
		return
	_snapshot_debounce -= delta
	if _snapshot_debounce > 0.0:
		return
	if Time.get_ticks_msec() - _last_broadcast_ms < SNAPSHOT_FLOOR_MS:
		return
	_snapshot_dirty = false
	if _registry.peer_ids().is_empty():
		return
	_last_broadcast_ms = Time.get_ticks_msec()
	rpc("_cli_apply_snapshot", _world().capture_snapshot())


@rpc("authority", "call_remote", "reliable", CH_BULK)
func _cli_apply_snapshot(snapshot: Dictionary) -> void:
	var world := _world()
	if world != null:
		world.restore_snapshot(snapshot)


# --------------------------------------------------------------------- suit sync

func _broadcast_suits() -> void:
	if _registry.peer_ids().is_empty():
		return
	var world := _world()
	if world == null:
		return
	var suits: Dictionary = {}
	for uid: String in world.list_suit_state_ids():
		var suit := world.get_suit_state(uid)
		if suit != null:
			suits[uid] = suit.to_dict()
	rpc("_cli_suits", suits)


@rpc("authority", "call_remote", "unreliable_ordered", CH_STREAM)
func _cli_suits(suits: Dictionary) -> void:
	var world := _world()
	if world == null:
		return
	for uid: Variant in suits:
		world.sync_suit_state(String(uid), suits[uid])


# -------------------------------------------------------------------- pose relay

func _send_local_pose() -> void:
	if _player == null:
		return
	if _player.has_method("is_spawn_settled") and not _player.call("is_spawn_settled"):
		return
	var pose := _local_pose()
	if _mode == Mode.CLIENT:
		rpc_id(1, "_srv_pose", pose)
	elif _mode == Mode.HOST:
		rpc("_cli_pose", _local_uid, pose)


@rpc("any_peer", "call_remote", "unreliable_ordered", CH_STREAM)
func _srv_pose(pose: Dictionary) -> void:
	if _mode != Mode.HOST:
		return
	var peer := multiplayer.get_remote_sender_id()
	var uid := _registry.uid_of(peer)
	if uid.is_empty():
		return
	for other: int in _registry.peer_ids():
		if other != peer:
			rpc_id(other, "_cli_pose", uid, pose)
	if _avatars.has(uid):
		(_avatars[uid] as RemotePlayer).push_pose(pose)


@rpc("authority", "call_remote", "unreliable_ordered", CH_STREAM)
func _cli_pose(uid: String, pose: Dictionary) -> void:
	if uid == _local_uid:
		return
	if _avatars.has(uid):
		(_avatars[uid] as RemotePlayer).push_pose(pose)


func _local_pose() -> Dictionary:
	var body_basis := _player.global_transform.basis.orthonormalized()
	var head_basis := body_basis
	var camera := _player.get_node_or_null("Camera") as Node3D
	if camera != null:
		head_basis = camera.global_transform.basis.orthonormalized()
	var lamp := _player.get_node_or_null("Camera/MiningLight") as Node3D
	var velocity := Vector3.ZERO
	if "velocity" in _player:
		velocity = _player.get("velocity")
	return {
		"p": _player.global_position,
		"q": Quaternion(body_basis),
		"qh": Quaternion(head_basis),
		"l": lamp != null and lamp.visible,
		"v": velocity,
	}


# ------------------------------------------------------------------ avatars/teardown

func _spawn_avatar(uid: String, nick: String) -> RemotePlayer:
	if _avatars.has(uid):
		return _avatars[uid]
	var avatar := RemotePlayerScene.instantiate() as RemotePlayer
	avatar.setup(uid, nick)
	_avatars_root.add_child(avatar)
	_avatars[uid] = avatar
	return avatar


func _despawn_avatar(uid: String) -> void:
	if not _avatars.has(uid):
		return
	var avatar := _avatars[uid] as RemotePlayer
	if is_instance_valid(avatar):
		avatar.queue_free()
	_avatars.erase(uid)


func _teardown_host() -> void:
	_disconnect_host_hooks()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	for uid: String in _avatars.keys():
		_despawn_avatar(uid)
	_registry = CoopPeerRegistry.new()
	_pending_results.clear()
	_mode = Mode.OFFLINE
	_info("stopped hosting")


func _teardown_client_and_reload() -> void:
	if _gateway != null:
		_gateway.set_network_submit(Callable())
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_mode = Mode.OFFLINE
	# Reload rebuilds the single-player world from this machine's own save,
	# re-enables persistence + meteorites and drops the replica — cheaper and
	# safer than un-replicating in place.
	get_tree().reload_current_scene()


func _connect_host_hooks() -> void:
	if _host_hooks_connected:
		return
	_gateway.command_completed.connect(_on_host_command_completed)
	_world().structural_event.connect(_on_host_structural_event)
	_host_hooks_connected = true


func _disconnect_host_hooks() -> void:
	if not _host_hooks_connected:
		return
	if _gateway.command_completed.is_connected(_on_host_command_completed):
		_gateway.command_completed.disconnect(_on_host_command_completed)
	var world := _world()
	if world != null and world.structural_event.is_connected(_on_host_structural_event):
		world.structural_event.disconnect(_on_host_structural_event)
	_host_hooks_connected = false


# ----------------------------------------------------------------------- helpers

func _pose_position(pose: Dictionary) -> Vector3:
	return pose.get("p", Vector3.ZERO)


## A point `dist` metres to the side of `world_pos` along the local surface, so
## the joining client does not spawn inside the host's view.
func _tangent_offset(world_pos: Vector3, dist: float) -> Vector3:
	var up := world_pos.normalized()
	var tangent := up.cross(Vector3.RIGHT)
	if tangent.length_squared() < 0.01:
		tangent = up.cross(Vector3.FORWARD)
	return tangent.normalized() * dist


func _info(message: String) -> void:
	print("Coop: %s" % message)
	if LimboConsole != null and LimboConsole.has_method("info"):
		LimboConsole.info("Coop: %s" % message)


func _err(message: String) -> void:
	push_warning("Coop: %s" % message)
	if LimboConsole != null and LimboConsole.has_method("error"):
		LimboConsole.error("Coop: %s" % message)
