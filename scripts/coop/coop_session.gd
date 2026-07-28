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
const CH_STREAM := 2      # poses + suit/store sync + assembly motion (unreliable_ordered)
const CH_INPUT := 3       # guest seat control stream (unreliable_ordered; own seq)

const POSE_INTERVAL := 0.05        # 20 Hz
const SUIT_INTERVAL := 1.0
## Stage-5 interim: same cadence as suits — changed resource stores / industry
## buffers / player inventories only (not a full snapshot, not a delta system).
const STORE_INTERVAL := 1.0
## Guest steering relay (spike stage C): 20 Hz on CH_INPUT (own seq vs poses).
## NOT a gateway command — ok-completion would dirty-mark the world and storm
## snapshot re-broadcasts plus reliable result echoes every frame.
const CONTROL_INPUT_INTERVAL := 0.05
const CONTROL_INPUT_STALE_MS := 300
## Moving-assembly motion stream (spike stage C): rate and the squared
## linear/angular velocity thresholds below which an assembly counts as parked
## and is not streamed (clients keep it from the last snapshot).
const ASSEMBLY_INTERVAL := 1.0 / 30.0
const ASSEMBLY_SPEED_SQ := 0.0025  # (0.05 m/s)^2
const ASSEMBLY_SPIN_SQ := 0.0025   # (0.05 rad/s)^2
## Client-side smoothing of the assembly stream, same scheme as RemotePlayer:
## render ~100 ms in the past, blend between buffered frames. A stream that
## goes quiet (assembly parked) is dropped after STALE_MS — the sim-truth pose
## from the last packet stays where it is.
const ASSEMBLY_INTERP_DELAY_MS := 100
const ASSEMBLY_BUFFER_LIMIT := 10
const ASSEMBLY_STALE_MS := 1500
const SNAPSHOT_DEBOUNCE := 0.3
## Min gap between full-snapshot broadcasts. Slightly above 1s so structural
## + command_completed bursts (and multi-command flushes) coalesce without
## flooding CH_BULK; join still gets a fresh capture on hello.
const SNAPSHOT_FLOOR_MS := 1500
## Client: retry join dig_ops that failed while chunks were not editable.
const PENDING_DIG_RETRY_INTERVAL := 0.5
## Client: assembling host dig-stream CH_BULK chunks during join. Var (not
## const) so headless tests can shrink it instead of waiting out the real
## timeout (see test_coop_bug_regressions.gd — DIG-03).
var TERRAIN_BULK_CHUNK_WAIT_SEC := CoopTerrainBulk.CHUNK_WAIT_TIMEOUT_SEC
## Host: guest dig hit terrain_unavailable (Clipbox still loading around the
## R-COOP-7 proxy) — soft-retry locally before returning failure. No extra RPCs.
## Max re-submits after the first fail (total tries = 1 + MAX).
const GUEST_DIG_RETRY_MAX := 2
const GUEST_DIG_RETRY_INTERVAL := 0.3
const NICK_PATH := "user://player_nick.txt"
## Loopback single-instance mutex. The first game process on a machine binds it;
## a second process (two windows for testing) fails to bind, learns it is a
## secondary instance, and takes a distinct session uid — otherwise both would
## read the same user://player_uid.txt and coop would mistake them for the same
## player. Different machines each bind their own, so real peers are unaffected.
const INSTANCE_LOCK_PORT := 47800
## Autojoin (`--coop-autojoin`): host may come up later; retry until admitted.
const AUTOJOIN_INTERVAL_SEC := 1.0
const AUTOJOIN_MAX_ATTEMPTS := 30

## Host command kinds that must NOT trigger a snapshot broadcast (terrain /
## granular churn — host drilling would storm client rebuilds). Everything else
## that completes ok marks the world dirty.
const NO_BROADCAST_KINDS := {
	&"voxel_remove": true,
	&"dig_terrain_debris": true,
	&"scoop_spoil": true,
	&"dump_scoop": true,
	&"debug_spawn_spoil": true,
	# Stage-5 interim store channel covers these; full snapshot would rebuild
	# topology for amount-only HUD updates (C1 client stays read-only).
	&"transfer_resource": true,
	&"assign_hotbar_instance": true,
	&"oxygen_refill": true,
	# Seat attach/owner-sim rides `_cli_result` + physics ownership; a full
	# snapshot mid-drive snaps the guest back to the host pose and rebuilds
	# bodies under a still-claimed local sim.
	&"toggle_control_seat": true,
}

## Dig kinds replicated as confirmed operations on the reliable channel instead
## of snapshots (spike stage B): the host re-broadcasts the sanitized command
## and every client replays the carve on its own field. Stays disjoint from
## snapshots on purpose — see NO_BROADCAST_KINDS above.
const DIG_OP_KINDS := {
	&"voxel_remove": true,
	&"scoop_spoil": true,
	&"dump_scoop": true,
}
## Ring cap for host session dig log (join catch-up + live relay). Drop-oldest
## beyond this — late joiners miss terrain carved before the window.
const MAX_DIG_OPS := 8192

enum Mode { OFFLINE, HOST, CLIENT }

@export var gateway_path: NodePath = ^"../WorldCommandGateway"
@export var session_path: NodePath = ^"../SimulationSession"
@export var player_path: NodePath = ^"../Player"
@export var meteorites_path: NodePath = ^"../MeteoriteSystem"

var _mode := Mode.OFFLINE
var _gateway: WorldCommandGateway
var _session: SimulationSession
var _player: Node3D
var _tools: ToolController
var _meteorites: Node
## Untyped so dynamic method calls (is_world_ready, and the two spawn/persist
## coroutines) dispatch and `await` correctly against bootstrap.gd.
var _bootstrap

var _local_uid := ""
var _local_nick := ""

var _registry := CoopPeerRegistry.new()          # host only
## host: host_cmd_id -> [peer, local_id, command, attempts]
var _pending_results: Dictionary = {}
## host: [{peer, local_id, command, attempts, wait}] soft-retry dig queue
var _guest_dig_retries: Array = []
var _avatars: Dictionary = {}                    # uid -> RemotePlayer
var _avatars_root: Node3D

var _pose_accum := 0.0
var _suit_accum := 0.0
var _store_accum := 0.0
var _assembly_accum := 0.0
## Client owner-sim: upload local assembly state to host at ASSEMBLY_INTERVAL.
var _owner_motion_accum := 0.0
var _control_input_accum := 0.0
## Host: last wire payloads for change detection (1 Hz store sync). Cleared on
## host start/stop so a new session does not suppress the first flush.
## Stores key off `SimulationResourceStore.revision` (COOP-05), not wire
## content — content-equality would wrongly suppress a resend for a value
## that churned back to what an earlier, unacked send already stamped.
var _last_store_revision: Dictionary = {}
var _last_buffer_wire: Dictionary = {}
## element_id → last IndustryElementRuntime wire (powered/battery interim sync).
var _last_industry_runtime_wire: Dictionary = {}
var _last_inventory_revision_sent := -1
## just_pressed edges accumulate every physics tick and flush with the next
## 50 ms control packet (sampling only at send rate would drop taps).
var _seat_edge_dampeners := false
var _seat_edge_parking_brake := false
## Host: remote uid -> last _srv_control_input receive time (msec). Watchdog
## zeros stuck throttle if a seated guest goes quiet (alt-tab / lag).
var _remote_driver_last_input_ms: Dictionary = {}
## Client (and host ghost for guest-owned): assembly_id -> {"root_id": int,
## "samples": [{t, motions, wheels}]}. Fed by assembly motion RPCs, consumed
## by _process — bodies are re-written every frame, which also reseats a
## mid-drive snapshot restore (fresh replica bodies get the streamed pose on
## the very next frame instead of waiting for the next packet).
var _assembly_streams: Dictionary = {}
## Host: assembly_id → driver uid for assemblies whose Jolt runs on a guest.
## Those assemblies are kinematic ghosts here; owner uploads state.
var _remote_physics_owners: Dictionary = {}
## Client: assembly we currently simulate locally as the seated driver (0 = none).
var _local_physics_assembly_id := 0
## Observer/ghost: wheel_element_id → integrated spin angle (rad). Driven by
## streamed wheel_speed; never slerped from body transforms.
var _observer_wheel_spin: Dictionary = {}
## assembly_id → {wheel_element_id: mount dict} for scalar reconstruct.
var _observer_wheel_mounts: Dictionary = {}
## Client: false from `join` until `_finish_apply_join` (snapshot + terrain bulk
## applied). Drops assembly-motion during the wait so blend cannot touch a
## half-swapped world. Host stays true while hosting.
var _replica_ready := false
## uid → latest pose received before the RemotePlayer existed (join race:
## host poses arrive while the guest is still awaiting terrain bulk).
var _pose_inbox: Dictionary = {}
var _snapshot_dirty := false
var _snapshot_debounce := 0.0
var _last_broadcast_ms := 0
## Process frame of the last _mark_snapshot_dirty — same-frame re-entry from
## structural_event + command_completed for one mutate must not reset debounce.
var _snapshot_dirty_frame := -1
## Host-only log of confirmed dig ops since `host` — replayed to late joiners.
var _dig_ops: Array = []
## Client: join dig_ops that failed (chunk not editable) — retried lightly.
var _pending_dig_ops: Array = []
var _pending_dig_accum := 0.0
## Client: host dig-stream bulk chunks (seq -> PackedByteArray) during join.
var _terrain_bulk_chunks: Dictionary = {}
var _terrain_bulk_expect_bytes := 0
var _terrain_bulk_expect_chunks := 0
## Host: uid -> last pose dict from pose relay (session rejoin reseat).
## Seeded from WorldPersistence cold `players{}` on `host` after restart.
var _last_poses: Dictionary = {}
var _host_hooks_connected := false
## Held for the process lifetime by the primary instance (see INSTANCE_LOCK_PORT).
var _instance_lock: PacketPeerUDP
## Set when the client is admitted (`_cli_join_payload`); stops autojoin retries.
var _autojoin_admitted := false


func _ready() -> void:
	_gateway = get_node_or_null(gateway_path) as WorldCommandGateway
	_session = get_node_or_null(session_path) as SimulationSession
	_player = get_node_or_null(player_path) as Node3D
	if _player != null:
		_tools = _player.get_node_or_null("ToolController") as ToolController
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
	_kickoff_cmdline_autostart()


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
	if _mode == Mode.CLIENT:
		_tick_client_control_input(delta)
		# Must not depend on `_assembly_streams` (often empty while we alone
		# drive) — that early-return lived in `_process` and silently dropped
		# every owner-sim upload, so the host ghost never moved.
		_tick_local_owner_motion_upload(delta)
		_tick_pending_dig_reapply(delta)
	if _mode == Mode.HOST:
		_tick_guest_dig_retries(delta)
		_tick_remote_driver_watchdog()
		_tick_snapshot_broadcast(delta)
		_suit_accum += delta
		if _suit_accum >= SUIT_INTERVAL:
			_suit_accum = 0.0
			_broadcast_suits()
		_store_accum += delta
		if _store_accum >= STORE_INTERVAL:
			_store_accum = 0.0
			_broadcast_stores()
		_assembly_accum += delta
		if _assembly_accum >= ASSEMBLY_INTERVAL:
			_assembly_accum = 0.0
			_broadcast_assembly_motion()


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


## Host-only connected peer count. Used by the host-side perf overlay
## (COOP-PERF-PLAYBOOK.md Phase 0) to correlate FPS/VT stats with churn from
## a joining/leaving peer. Zero offline or on a client.
func peer_count() -> int:
	return _registry.peer_ids().size()


# --------------------------------------------------------- cmdline autostart

## `--coop-autohost` / `--coop-autojoin[=ip[:port]]` after `--`. Waits for
## world ready (host refuses joiners with host_not_ready until then), then
## reuses the same paths as console `host` / `join`. Autojoin retries.
func _kickoff_cmdline_autostart() -> void:
	var want_autohost := false
	var want_autojoin := false
	var join_ip := "127.0.0.1"
	var join_port := PORT_DEFAULT
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--coop-autohost":
			want_autohost = true
		elif arg == "--coop-autojoin":
			want_autojoin = true
		elif arg.begins_with("--coop-autojoin="):
			want_autojoin = true
			var spec := arg.substr("--coop-autojoin=".length()).strip_edges()
			if not spec.is_empty():
				var sep := spec.rfind(":")
				if sep > 0 and spec.substr(sep + 1).is_valid_int():
					join_ip = spec.substr(0, sep)
					join_port = int(spec.substr(sep + 1))
				else:
					join_ip = spec
	if want_autohost:
		print("CoopSession: autohost armed (port %d)" % PORT_DEFAULT)
		_autohost_when_ready()
	if want_autojoin:
		print("CoopSession: autojoin armed → %s:%d" % [join_ip, join_port])
		_autojoin_when_ready(join_ip, join_port)


func _await_world_ready() -> void:
	while _bootstrap == null or not _bootstrap.is_world_ready():
		await get_tree().process_frame


func _autohost_when_ready() -> void:
	await _await_world_ready()
	print("CoopSession: autohost — world ready, hosting")
	_cmd_host()


func _autojoin_when_ready(ip: String, port: int) -> void:
	await _await_world_ready()
	print("CoopSession: autojoin — world ready, connecting to %s:%d" % [ip, port])
	var attempt := 0
	while attempt < AUTOJOIN_MAX_ATTEMPTS:
		if _autojoin_admitted:
			print("CoopSession: autojoin succeeded")
			return
		if _mode == Mode.OFFLINE:
			attempt += 1
			print(
				"CoopSession: autojoin attempt %d/%d → %s:%d"
				% [attempt, AUTOJOIN_MAX_ATTEMPTS, ip, port]
			)
			_cmd_join(ip, port)
		await get_tree().create_timer(AUTOJOIN_INTERVAL_SEC).timeout
	if _autojoin_admitted:
		print("CoopSession: autojoin succeeded")
		return
	print(
		"CoopSession: autojoin gave up after %d attempts → %s:%d"
		% [AUTOJOIN_MAX_ATTEMPTS, ip, port]
	)


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
	_replica_ready = true
	_registry = CoopPeerRegistry.new()
	_pending_results.clear()
	_guest_dig_retries.clear()
	_dig_ops.clear()
	_last_poses.clear()
	_pose_inbox.clear()
	_seed_last_poses_from_cold()
	_clear_store_wire_cache()
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
	# Snapshot + terrain bulk land later; ignore loco/stream until then.
	_replica_ready = false
	_pose_inbox.clear()
	_assembly_streams.clear()
	_observer_wheel_spin.clear()
	_observer_wheel_mounts.clear()
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
	_clear_remote_driver(uid)
	_clear_remote_physics_owner_for_uid(uid)
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
	var terrain_bulk := await _prepare_join_terrain_bulk()
	if _mode != Mode.HOST or not _registry.has_peer(peer):
		return
	var sqlite_bytes: PackedByteArray = terrain_bulk["sqlite_bytes"]
	var granular: Dictionary = terrain_bulk["granular"]
	var join_dig_ops: Array = terrain_bulk["join_dig_ops"]
	var fallback_dig_ops: Array = terrain_bulk.get("fallback_dig_ops", [])
	var payload := CoopCommandCodec.make_join_payload(
		_world().capture_snapshot(),
		_registry.peers_payload(),
		_local_uid,
		_local_nick,
		_local_pose(),
		peer,
		join_dig_ops
	)
	# Optional: last known pose for this uid (rejoin). Clients without the
	# field keep reseating near the host.
	var known_pose: Variant = _last_poses.get(uid)
	if known_pose is Dictionary and (known_pose as Dictionary).has("p"):
		payload["you_pose"] = known_pose
	CoopTerrainBulk.attach_to_join_payload(
		payload, sqlite_bytes, granular, fallback_dig_ops
	)
	rpc_id(peer, "_cli_join_payload", payload)
	_send_terrain_bulk_chunks(peer, sqlite_bytes, payload.get("terrain_bulk", {}))
	for other: int in _registry.peer_ids():
		if other != peer:
			rpc_id(other, "_cli_peer_joined", {"uid": uid, "nick": nick})
	_info("'%s' joined" % nick)


## Host join catch-up: flush dig SQLite first so cold + session-flushed holes
## are in the file, then decide what `dig_ops` the joiner still needs.
## Extracted from `_srv_hello` (unchanged order) so a headless test can drive
## it against a fake `_bootstrap` — see test_coop_bug_regressions.gd
## (DIG-01/DIG-02/DIG-03). `dig_mark` is captured *after* awaiting the flush
## (not before), so a dig executed by the host while the flush was running is
## already folded into `_dig_ops` by the time we mark the tail — it lands in
## the fresh sqlite bulk only, never doubled into the dig_ops tail. The
## fallback ring (ops before the mark) rides along in the terrain_bulk meta so
## a joiner whose chunked sqlite transfer times out can still recover the cold
## holes instead of losing them silently (DIG-03).
func _prepare_join_terrain_bulk() -> Dictionary:
	return await CoopJoinService.prepare_join_terrain_bulk(self)


func _send_terrain_bulk_chunks(
	peer: int,
	sqlite_bytes: PackedByteArray,
	meta: Variant
) -> void:
	CoopJoinService.send_terrain_bulk_chunks(self, peer, sqlite_bytes, meta)


func _reject(peer_id: int, reason: StringName) -> void:
	rpc_id(peer_id, "_cli_join_denied", reason)
	_registry.unregister(peer_id)
	multiplayer.multiplayer_peer.disconnect_peer(peer_id)
	_info("rejected a join: %s" % reason)


func _seed_joiner(uid: String) -> void:
	CoopJoinService.seed_joiner(self, uid)


# ----------------------------------------------------------------- client: join

func _on_connected_to_server() -> void:
	rpc_id(1, "_srv_hello", CoopCommandCodec.make_hello(_local_uid, _local_nick))
	_info("connected — requesting world ...")


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	_replica_ready = false
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
	_replica_ready = false
	_mode = Mode.OFFLINE


@rpc("authority", "call_remote", "reliable", CH_BULK)
func _cli_join_payload(payload: Dictionary) -> void:
	var verdict := CoopCommandCodec.validate_join_payload(payload)
	if verdict != &"ok":
		_err("cannot join: %s" % verdict)
		multiplayer.multiplayer_peer = null
		_replica_ready = false
		_mode = Mode.OFFLINE
		return
	_autojoin_admitted = true
	await _apply_join(payload)


@rpc("authority", "call_remote", "reliable", CH_BULK)
func _cli_terrain_bulk_chunk(seq: int, total: int, data: PackedByteArray) -> void:
	if _mode != Mode.CLIENT:
		return
	if seq < 0 or total <= 0 or data.is_empty():
		return
	_terrain_bulk_expect_chunks = total
	_terrain_bulk_chunks[seq] = data


func _apply_join(payload: Dictionary) -> void:
	await CoopJoinService.apply_join(self, payload)


func _apply_join_terrain_bulk(meta_variant: Variant) -> void:
	await CoopJoinService.apply_join_terrain_bulk(self, meta_variant)


func _replay_fallback_dig_ops(ops_variant: Variant) -> void:
	CoopJoinService.replay_fallback_dig_ops(self, ops_variant)


func _wait_terrain_bulk_chunks(chunk_count: int, expected_bytes: int) -> PackedByteArray:
	return await CoopJoinService.wait_terrain_bulk_chunks(
		self, chunk_count, expected_bytes
	)


func _clear_terrain_bulk_state() -> void:
	CoopJoinService.clear_terrain_bulk_state(self)


func _spawn_join_roster_avatars(payload: Dictionary) -> void:
	CoopJoinService.spawn_join_roster_avatars(self, payload)


func _finish_apply_join(payload: Dictionary) -> void:
	await CoopJoinService.finish_apply_join(self, payload)


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
	CoopCommandRouteService.on_local_submit(self, local_id, command)


@rpc("any_peer", "call_remote", "reliable", CH_MAIN)
func _srv_submit(local_id: int, command: Dictionary) -> void:
	CoopCommandRouteService.srv_submit(self, local_id, command)


@rpc("authority", "call_remote", "reliable", CH_MAIN)
func _cli_result(local_id: int, result: Dictionary) -> void:
	CoopCommandRouteService.cli_result(self, local_id, result)


func _on_host_command_completed(command_id: int, result: Dictionary) -> void:
	CoopCommandRouteService.on_host_command_completed(self, command_id, result)


## Guest driver → ghost on host; host driver → clear any guest claim on that assembly.
func _host_update_physics_ownership_from_seat(
	result: Dictionary,
	seat_peer: int,
	seat_uid: String
) -> void:
	CoopAssemblyStreamService.host_update_physics_ownership_from_seat(
		self, result, seat_peer, seat_uid
	)


func _set_remote_physics_owner(assembly_id: int, uid: String) -> void:
	CoopAssemblyStreamService.set_remote_physics_owner(self, assembly_id, uid)


func _clear_remote_physics_owner_for_uid(uid: String) -> void:
	CoopAssemblyStreamService.clear_remote_physics_owner_for_uid(self, uid)


func _clear_remote_physics_owner_assembly(assembly_id: int) -> void:
	CoopAssemblyStreamService.clear_remote_physics_owner_assembly(self, assembly_id)


## Host: write newest buffer sample into assembly.motion so unghost / snapshot
## / seat-exit see the driven pose, not the pre-sit spawn.
func _commit_streamed_assembly_pose(assembly_id: int) -> void:
	CoopAssemblyStreamService.commit_streamed_assembly_pose(self, assembly_id)


func _begin_local_driver_physics(assembly_id: int) -> void:
	CoopAssemblyStreamService.begin_local_driver_physics(self, assembly_id)


func _end_local_driver_physics() -> void:
	CoopAssemblyStreamService.end_local_driver_physics(self)


## Host-only (connected in _connect_host_hooks). Fires for every executed
## command — the host's own digs and guests' digs alike — so every peer's holes
## reach every other peer through the same ordered stream.
func _on_host_command_executed(command: Dictionary, result: Dictionary) -> void:
	if _mode != Mode.HOST:
		return
	var kind := StringName(command.get("kind", &""))
	if not DIG_OP_KINDS.has(kind):
		return
	if StringName(result.get("status", &"")) != &"ok":
		return
	var op := CoopCommandCodec.build_dig_op(command, result)
	CoopDigRelayUtil.append_dig_op(self, op)
	if _registry.peer_ids().is_empty():
		return
	rpc("_cli_dig_op", op)


@rpc("authority", "call_remote", "reliable", CH_MAIN)
func _cli_dig_op(op: Dictionary) -> void:
	if _mode != Mode.CLIENT or _gateway == null:
		return
	## COOP-04: same soft-recovery as the join path (_apply_join) — a failed
	## replay (e.g. chunk not editable yet) must not be dropped silently, or
	## this hole never carves for the guest.
	if not _gateway.replay_remote_dig(op):
		_pending_dig_ops.append(op)


func _on_host_structural_event(event: Dictionary) -> void:
	if StringName(event.get("kind", &"")) == &"world_restored":
		return
	_mark_snapshot_dirty()


# ------------------------------------------------------------ snapshot broadcast

func _mark_snapshot_dirty() -> void:
	CoopSnapshotBroadcastUtil.mark_snapshot_dirty(self)


func _tick_snapshot_broadcast(delta: float) -> void:
	CoopSnapshotBroadcastUtil.tick_snapshot_broadcast(self, delta)


@rpc("authority", "call_remote", "reliable", CH_BULK)
func _cli_apply_snapshot(snapshot: Dictionary) -> void:
	var world := _world()
	# restore → rebuild_all clears bodies; keep/reclaim local driver sim so
	# joints stay owner-authoritative if we are still seated.
	var resume_id := _local_physics_assembly_id
	if world != null:
		world.restore_snapshot(snapshot)
	if resume_id > 0 and _mode == Mode.CLIENT:
		_rebind_local_driver_physics_after_snapshot(resume_id)


## Snapshot rebuild leaves local-sim flagged but may orphan the seat bind;
## force a fresh local-sim reproject + reseat when still driving.
func _rebind_local_driver_physics_after_snapshot(assembly_id: int) -> void:
	if assembly_id <= 0 or _session == null or _session.projection == null:
		return
	var world := _world()
	if world == null or world.get_assembly_raw(assembly_id) == null:
		_end_local_driver_physics()
		return
	_local_physics_assembly_id = assembly_id
	_session.projection.rebind_local_assembly_sim(assembly_id)
	var loco: AssemblyLocomotionController = (
		world.get_locomotion_controller(assembly_id)
	)
	if loco != null:
		loco.activate()
	if _gateway != null:
		_gateway.ensure_local_seat_binding()


# --------------------------------------------------------------------- suit sync

func _broadcast_suits() -> void:
	CoopStateSyncUtil.broadcast_suits(self)


@rpc("authority", "call_remote", "unreliable_ordered", CH_STREAM)
func _cli_suits(suits: Dictionary) -> void:
	CoopStateSyncUtil.cli_suits(self, suits)


# -------------------------------------------------------------- store sync

## Stage-5 interim (not a full delta system): 1 Hz like suits. Only stores /
## buffers / inventories whose content changed since the last send. Topology
## still rides the existing full-snapshot path. Dig ops stay on NO_BROADCAST +
## their own channel — store credits from dig reach clients here.
func _broadcast_stores() -> void:
	CoopStateSyncUtil.broadcast_stores(self)


## Diffs stores/buffers/inventories against the last-sent cache and stamps the
## cache for whatever it finds changed. Extracted from `_broadcast_stores`
## (unchanged order/logic) so a headless test can call it without a live
## multiplayer peer — see test_coop_bug_regressions.gd (COOP-05). Stores diff
## on `revision`, not wire content: content-equality would wrongly treat a
## value that churned back to an earlier, unacked-send's content as
## "unchanged" and never resend it over the `unreliable_ordered` CH_STREAM.
func _compute_store_broadcast_payload(world: SimulationWorld) -> Dictionary:
	return CoopStateSyncUtil.compute_store_broadcast_payload(self, world)


@rpc("authority", "call_remote", "unreliable_ordered", CH_STREAM)
func _cli_stores(payload: Dictionary) -> void:
	CoopStateSyncUtil.cli_stores(self, payload)


func _clear_store_wire_cache() -> void:
	CoopStateSyncUtil.clear_store_wire_cache(self)


# ------------------------------------------------------- assembly motion stream

## Host: stream root + child body-group motions of every assembly that is
## actually moving (unreliable_ordered, like poses — a lost frame is replaced
## 66 ms later). Parked/sleeping assemblies cost nothing; clients keep them
## where the last snapshot put them. The host's Jolt read-back refreshes
## assembly.motion / body_group_motions every physics tick, so the world state
## read here is current.
##
## Packet shape per assembly: `{ "m": {group_id: motion_dict}, "w": {wheel_id: scalars} }`.
## `"m"` is root + non-wheel groups only. Wheels are observer-reconstructed from
## `"w"` scalars (compression / steer / spin rate) glued to the strut.
## Legacy flat `{group_id: motion}` still parses via `_unpack_assembly_stream_entry`.
func _broadcast_assembly_motion() -> void:
	CoopAssemblyStreamService.broadcast_assembly_motion(self)


## Non-wheel body poses + per-wheel scalars. Empty if assembly unknown, or
## (when `require_live`) parked under the speed gate. Guest owner-upload passes
## `require_live=false` so the host ghost keeps updating at crawl / airborne.
func _pack_assembly_motion_entry(
	assembly_id: int,
	require_live: bool = true
) -> Dictionary:
	return CoopAssemblyMotionUtil.pack_assembly_motion_entry(
		self, assembly_id, require_live
	)


func _wheel_group_ids(assembly_id: int) -> Dictionary:
	return CoopAssemblyMotionUtil.wheel_group_ids(self, assembly_id)


func _pack_wheel_scalars(assembly_id: int) -> Dictionary:
	return CoopAssemblyMotionUtil.pack_wheel_scalars(self, assembly_id)


func _unpack_assembly_stream_entry(packed: Dictionary) -> Dictionary:
	return CoopAssemblyMotionUtil.unpack_assembly_stream_entry(packed)


func _motion_is_live(motion: AssemblyMotionState) -> bool:
	return CoopAssemblyMotionUtil.motion_is_live(self, motion)


@rpc("authority", "call_remote", "unreliable_ordered", CH_STREAM)
func _cli_assembly_motion(batch: Dictionary) -> void:
	CoopAssemblyStreamService.cli_assembly_motion(self, batch)


## Guest driver → host: same packet shape as host broadcast. Host ghosts the
## assembly and rebroadcasts to other peers.
@rpc("any_peer", "call_remote", "unreliable_ordered", CH_STREAM)
func _srv_assembly_motion(assembly_id: int, entry: Dictionary) -> void:
	CoopAssemblyStreamService.srv_assembly_motion(self, assembly_id, entry)


func _ingest_assembly_motion_batch(
	batch: Dictionary,
	host_ghost: bool = false
) -> void:
	CoopAssemblyStreamService.ingest_assembly_motion_batch(self, batch, host_ghost)


func _sync_ghost_wheel_kernel_motions(
	assembly_id: int,
	chassis_motions: Dictionary,
	wheels: Dictionary
) -> void:
	CoopAssemblyStreamService.sync_ghost_wheel_kernel_motions(
		self, assembly_id, chassis_motions, wheels
	)


func _process(delta: float) -> void:
	if _mode == Mode.OFFLINE:
		return
	if _assembly_streams.is_empty():
		return
	if _session == null or _session.projection == null:
		return
	# Client observers + host ghosts for guest-owned assemblies.
	# Owner-sim upload runs from `_physics_process` (must not gate on streams).
	if _mode == Mode.CLIENT or not _remote_physics_owners.is_empty():
		CoopAssemblyStreamService.tick_assembly_stream_blend(self, delta)


func _tick_assembly_stream_blend(delta: float) -> void:
	CoopAssemblyStreamService.tick_assembly_stream_blend(self, delta)


func _apply_assembly_blend(
	assembly_id: int,
	root_id: int,
	from_motions: Dictionary,
	to_motions: Dictionary,
	from_wheels: Dictionary,
	to_wheels: Dictionary,
	factor: float,
	delta: float
) -> void:
	CoopAssemblyStreamService.apply_assembly_blend(
		self,
		assembly_id,
		root_id,
		from_motions,
		to_motions,
		from_wheels,
		to_wheels,
		factor,
		delta
	)


func _apply_observer_wheel_scalars(
	assembly_id: int,
	root_id: int,
	wheel_specs: Array,
	from_wheels: Dictionary,
	to_wheels: Dictionary,
	factor: float,
	delta: float
) -> void:
	CoopAssemblyStreamService.apply_observer_wheel_scalars(
		self,
		assembly_id,
		root_id,
		wheel_specs,
		from_wheels,
		to_wheels,
		factor,
		delta
	)


func _forget_observer_assembly(assembly_id: int) -> void:
	CoopAssemblyStreamService.forget_observer_assembly(self, assembly_id)


func _write_blended_body_pose(
	projection,
	assembly_id: int,
	root_id: int,
	group_id: int,
	from_motions: Dictionary,
	to_motions: Dictionary,
	factor: float
) -> void:
	CoopAssemblyStreamService.write_blended_body_pose(
		self,
		projection,
		assembly_id,
		root_id,
		group_id,
		from_motions,
		to_motions,
		factor
	)


# -------------------------------------------------------------------- pose relay

## Cold `players{}` extras for WorldPersistence.save (host only). Relay pose
## dicts keyed by uid — persistence normalizes to position/yaw rows.
func export_cold_poses() -> Dictionary:
	return CoopPoseRelayUtil.export_cold_poses(self)


## After host restart: session last-pose cache starts empty; seed from cold
## save so rejoin `you_pose` works without a prior live relay this session.
func _seed_last_poses_from_cold() -> void:
	CoopPoseRelayUtil.seed_last_poses_from_cold(self)


func _send_local_pose() -> void:
	if _player == null:
		return
	if _player.has_method("is_spawn_settled") and not _player.call("is_spawn_settled"):
		return
	var pose := CoopPoseRelayUtil.local_pose(self)
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
	_last_poses[uid] = pose
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
	else:
		# Avatar not spawned yet (terrain-bulk wait) — keep latest for flush.
		_pose_inbox[uid] = pose


func _local_pose() -> Dictionary:
	return CoopPoseRelayUtil.local_pose(self)


# ---------------------------------------------------------- seat control stream

## Client: while seated as driver with local owner-sim, apply locomotion here
## (host is a kinematic ghost). PAX / missing-seat fallbacks unchanged.
func _tick_client_control_input(delta: float) -> void:
	CoopSeatControlRelayUtil.tick_client_control_input(self, delta)


func _tick_local_owner_motion_upload(delta: float) -> void:
	CoopAssemblyStreamService.tick_local_owner_motion_upload(self, delta)


func _client_seat_replica_ok(element_id: int) -> bool:
	return CoopSeatControlRelayUtil.client_seat_replica_ok(self, element_id)


@rpc("any_peer", "call_remote", "unreliable_ordered", CH_INPUT)
func _srv_control_input(raw: Dictionary, edges: Dictionary) -> void:
	CoopSeatControlRelayUtil.srv_control_input(self, raw, edges)


## Host → seated guest: seat destroyed / non-operational. Reliable on CH_MAIN.
func _notify_remote_seat_force_release(
	player_id: String,
	_seat_element_id: int,
	_assembly_id: int
) -> void:
	CoopSeatControlRelayUtil.notify_remote_seat_force_release(
		self, player_id, _seat_element_id, _assembly_id
	)


@rpc("authority", "call_remote", "reliable", CH_MAIN)
func _cli_force_seat_release() -> void:
	CoopSeatControlRelayUtil.cli_force_seat_release(self)


func _tick_remote_driver_watchdog() -> void:
	CoopSeatControlRelayUtil.tick_remote_driver_watchdog(self)


func _clear_remote_driver(uid: String) -> void:
	CoopSeatControlRelayUtil.clear_remote_driver(self, uid)


## Resolve a ControlSeat element to its world transform on this peer's replica
## (body * seat_offset_local). Used by RemotePlayer when pose.seat > 0.
func resolve_seat_world_transform(element_id: int) -> Variant:
	if (
		element_id <= 0
		or _session == null
		or _session.world == null
		or _session.projection == null
	):
		return null
	var element := _session.world.get_element(element_id)
	if element == null:
		return null
	var body := (
		_session.projection.get_element_projection(element_id).get("body")
		as Node3D
	)
	if body == null or not is_instance_valid(body):
		return null
	var offset: Vector3 = WheelPlacementUtil.seat_offset_local(element)
	return Transform3D(body.global_transform.basis, body.global_transform * offset)


# ------------------------------------------------------------------ avatars/teardown

func _spawn_avatar(uid: String, nick: String) -> RemotePlayer:
	return CoopAvatarService.spawn_avatar(self, uid, nick)


func _flush_pose_inbox_to(uid: String, avatar: RemotePlayer) -> void:
	CoopAvatarService.flush_pose_inbox_to(self, uid, avatar)


func _despawn_avatar(uid: String) -> void:
	CoopAvatarService.despawn_avatar(self, uid)


func _teardown_host() -> void:
	_disconnect_host_hooks()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	for uid: String in _avatars.keys():
		_despawn_avatar(uid)
	_registry = CoopPeerRegistry.new()
	_pending_results.clear()
	_guest_dig_retries.clear()
	_dig_ops.clear()
	_last_poses.clear()
	_clear_store_wire_cache()
	var owned: Array = _remote_physics_owners.keys()
	for assembly_id_variant: Variant in owned:
		_clear_remote_physics_owner_assembly(int(assembly_id_variant))
	_remote_physics_owners.clear()
	_assembly_streams.clear()
	_observer_wheel_spin.clear()
	_observer_wheel_mounts.clear()
	_pose_inbox.clear()
	_replica_ready = false
	_mode = Mode.OFFLINE
	_info("stopped hosting")


func _teardown_client_and_reload() -> void:
	if _gateway != null:
		_gateway.set_network_submit(Callable())
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_pending_dig_ops.clear()
	_pending_dig_accum = 0.0
	_clear_terrain_bulk_state()
	_assembly_streams.clear()
	_observer_wheel_spin.clear()
	_observer_wheel_mounts.clear()
	_pose_inbox.clear()
	_replica_ready = false
	_mode = Mode.OFFLINE
	# Reload rebuilds the single-player world from this machine's own save,
	# re-enables persistence + meteorites and drops the replica — cheaper and
	# safer than un-replicating in place.
	get_tree().reload_current_scene()


func _connect_host_hooks() -> void:
	if _host_hooks_connected:
		return
	_gateway.command_completed.connect(_on_host_command_completed)
	_gateway.command_executed.connect(_on_host_command_executed)
	_gateway.set_seat_force_release_notify(_notify_remote_seat_force_release)
	_world().structural_event.connect(_on_host_structural_event)
	_host_hooks_connected = true


func _disconnect_host_hooks() -> void:
	if not _host_hooks_connected:
		return
	if _gateway.command_completed.is_connected(_on_host_command_completed):
		_gateway.command_completed.disconnect(_on_host_command_completed)
	if _gateway.command_executed.is_connected(_on_host_command_executed):
		_gateway.command_executed.disconnect(_on_host_command_executed)
	_gateway.set_seat_force_release_notify(Callable())
	var world := _world()
	if world != null and world.structural_event.is_connected(_on_host_structural_event):
		world.structural_event.disconnect(_on_host_structural_event)
	_host_hooks_connected = false


# ----------------------------------------------------------------------- helpers

func _pose_position(pose: Dictionary) -> Vector3:
	return CoopPoseRelayUtil.pose_position(pose)


func _route_guest_submit(
	peer: int,
	local_id: int,
	command: Dictionary,
	attempts: int
) -> void:
	CoopCommandRouteService.route_guest_submit(self, peer, local_id, command, attempts)


func _should_soft_retry_guest_dig(result: Dictionary, attempts: int) -> bool:
	return CoopDigRelayUtil.should_soft_retry_guest_dig(self, result, attempts)


## Host: re-run guest digs that failed while Clipbox loaded the proxy shell.
## Interval backoff — not every physics tick (R9); no extra client RPCs.
func _tick_guest_dig_retries(delta: float) -> void:
	CoopDigRelayUtil.tick_guest_dig_retries(self, delta)


## Retry join dig_ops that failed while the local chunk was not editable.
## Light interval — not every physics tick (R9).
func _tick_pending_dig_reapply(delta: float) -> void:
	CoopDigRelayUtil.tick_pending_dig_reapply(self, delta)


## A point `dist` metres to the side of `world_pos` along the local surface, so
## the joining client does not spawn inside the host's view.
func _tangent_offset(world_pos: Vector3, dist: float) -> Vector3:
	return CoopPoseRelayUtil.tangent_offset(world_pos, dist)


func _info(message: String) -> void:
	print("Coop: %s" % message)
	if LimboConsole != null and LimboConsole.has_method("info"):
		LimboConsole.info("Coop: %s" % message)


func _err(message: String) -> void:
	push_warning("Coop: %s" % message)
	if LimboConsole != null and LimboConsole.has_method("error"):
		LimboConsole.error("Coop: %s" % message)
