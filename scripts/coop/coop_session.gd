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
const ASSEMBLY_INTERVAL := 1.0 / 15.0
const ASSEMBLY_SPEED_SQ := 0.0025  # (0.05 m/s)^2
const ASSEMBLY_SPIN_SQ := 0.0025   # (0.05 rad/s)^2
## Client-side smoothing of the assembly stream, same scheme as RemotePlayer:
## render ~120 ms in the past, blend between buffered frames. A stream that
## goes quiet (assembly parked) is dropped after STALE_MS — the sim-truth pose
## from the last packet stays where it is.
const ASSEMBLY_INTERP_DELAY_MS := 120
const ASSEMBLY_BUFFER_LIMIT := 8
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
var _control_input_accum := 0.0
## Host: last wire payloads for change detection (1 Hz store sync). Cleared on
## host start/stop so a new session does not suppress the first flush.
## Stores key off `SimulationResourceStore.revision` (COOP-05), not wire
## content — content-equality would wrongly suppress a resend for a value
## that churned back to what an earlier, unacked send already stamped.
var _last_store_revision: Dictionary = {}
var _last_buffer_wire: Dictionary = {}
var _last_inventory_revision_sent := -1
## just_pressed edges accumulate every physics tick and flush with the next
## 50 ms control packet (sampling only at send rate would drop taps).
var _seat_edge_dampeners := false
var _seat_edge_parking_brake := false
## Host: remote uid -> last _srv_control_input receive time (msec). Watchdog
## zeros stuck throttle if a seated guest goes quiet (alt-tab / lag).
var _remote_driver_last_input_ms: Dictionary = {}
## Client: assembly_id -> {"root_id": int, "samples": [{t: int, motions:
## {group_id: AssemblyMotionState}}]}. Fed by _cli_assembly_motion, consumed
## by _process — bodies are re-written every frame, which also reseats a
## mid-drive snapshot restore (fresh replica bodies get the streamed pose on
## the very next frame instead of waiting for the next packet).
var _assembly_streams: Dictionary = {}
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
	_registry = CoopPeerRegistry.new()
	_pending_results.clear()
	_guest_dig_retries.clear()
	_dig_ops.clear()
	_last_poses.clear()
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
	await _bootstrap.flush_digs_for_coop_join()
	var dig_mark := _dig_ops.size()
	var bulk: Dictionary = _bootstrap.capture_coop_terrain_bulk()
	var sqlite_bytes: PackedByteArray = bulk.get("sqlite", PackedByteArray())
	var granular: Dictionary = bulk.get("granular", {})
	## Cold bulk present → dig_ops = post-flush tail only (avoid double-carve).
	## Empty sqlite → full session ring (pre-bulk fallback).
	var join_dig_ops: Array = CoopTerrainBulk.select_join_dig_ops(
		_dig_ops, dig_mark, sqlite_bytes
	)
	var fallback_dig_ops: Array = (
		_dig_ops.slice(0, clampi(dig_mark, 0, _dig_ops.size()))
		if not sqlite_bytes.is_empty()
		else []
	)
	return {
		"join_dig_ops": join_dig_ops,
		"sqlite_bytes": sqlite_bytes,
		"granular": granular,
		"fallback_dig_ops": fallback_dig_ops,
	}


func _send_terrain_bulk_chunks(
	peer: int,
	sqlite_bytes: PackedByteArray,
	meta: Variant
) -> void:
	if sqlite_bytes.is_empty() or not (meta is Dictionary):
		return
	var chunk_count := int((meta as Dictionary).get("chunk_count", 0))
	if chunk_count <= 0:
		return
	var chunks := CoopTerrainBulk.split_sqlite_chunks(sqlite_bytes)
	for i: int in chunks.size():
		rpc_id(peer, "_cli_terrain_bulk_chunk", i, chunks.size(), chunks[i])


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
	# Per-uid tool instances + hotbar (COOP-HOST-V0 Persistence). Fresh peers
	# get starter resources + inventory; rejoin keeps an existing store but
	# still ensures a registry so a missing hotbar is seeded.
	if world.get_resource_store(PlayerIdentity.store_id(uid)) == null:
		IndustryStoreService.seed_player_starter_resources(world, uid)
	else:
		world.ensure_player_inventory(uid)


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
	# Flush this machine's own save first, then stop persisting the replica.
	await _bootstrap.save_now_then_inhibit_persistence()

	var world := _world()
	world.authoritative = false
	world.restore_snapshot(payload["snapshot"])
	## Cold digs (SQLite + granular) before session dig_ops tail — bulk is the
	## host dig-stream truth; dig_ops only cover ops after the host flush.
	await _apply_join_terrain_bulk(payload.get("terrain_bulk"))
	_pending_dig_ops.clear()
	_pending_dig_accum = 0.0
	var dig_ok := 0
	var dig_fail := 0
	for op_variant: Variant in payload.get("dig_ops", []):
		if op_variant is Dictionary:
			if _gateway.replay_remote_dig(op_variant):
				dig_ok += 1
			else:
				dig_fail += 1
				_pending_dig_ops.append(op_variant)
		else:
			dig_fail += 1
	if dig_fail > 0:
		push_warning(
			"join dig replay: %d ok, %d queued for retry (chunk not editable yet)"
			% [dig_ok, _pending_dig_ops.size()]
		)
	await _finish_apply_join(payload)


func _apply_join_terrain_bulk(meta_variant: Variant) -> void:
	if not (meta_variant is Dictionary):
		_clear_terrain_bulk_state()
		return
	var meta: Dictionary = meta_variant
	var nbytes := int(meta.get("sqlite_bytes", 0))
	var chunk_count := int(meta.get("chunk_count", 0))
	var granular: Dictionary = meta.get("granular", {})
	var sqlite := PackedByteArray()
	if meta.has("sqlite") and meta["sqlite"] is PackedByteArray:
		sqlite = CoopTerrainBulk.resolve_join_sqlite(meta)
	elif nbytes > 0 and chunk_count > 0:
		_terrain_bulk_expect_bytes = nbytes
		_terrain_bulk_expect_chunks = chunk_count
		sqlite = await _wait_terrain_bulk_chunks(chunk_count, nbytes)
		if sqlite.is_empty() and nbytes > 0:
			push_warning(
				"join terrain bulk: timed out or incomplete (%d/%d chunks)"
				% [_terrain_bulk_chunks.size(), chunk_count]
			)
			## DIG-03: the sqlite bulk never arrived, so any cold holes the
			## host excluded from dig_ops (tail-only decision) exist nowhere
			## else — replay the fallback ring instead of losing them.
			_replay_fallback_dig_ops(meta.get("fallback_dig_ops", []))
	_clear_terrain_bulk_state()
	if sqlite.is_empty() and granular.is_empty():
		return
	_bootstrap.apply_coop_terrain_bulk(sqlite, granular)


## Same soft-recovery shape as the join dig_ops tail (_apply_join) and live
## ops (_cli_dig_op) — a replay that fails here (chunk not editable yet) is
## queued into _pending_dig_ops for the existing retry loop.
func _replay_fallback_dig_ops(ops_variant: Variant) -> void:
	if not (ops_variant is Array) or _gateway == null:
		return
	for op_variant: Variant in (ops_variant as Array):
		if not (op_variant is Dictionary):
			continue
		if not _gateway.replay_remote_dig(op_variant):
			_pending_dig_ops.append(op_variant)


func _wait_terrain_bulk_chunks(chunk_count: int, expected_bytes: int) -> PackedByteArray:
	var deadline_ms := (
		Time.get_ticks_msec() + int(TERRAIN_BULK_CHUNK_WAIT_SEC * 1000.0)
	)
	while true:
		var complete := true
		for seq: int in range(chunk_count):
			if not _terrain_bulk_chunks.has(seq):
				complete = false
				break
		if complete:
			break
		if Time.get_ticks_msec() >= deadline_ms:
			return PackedByteArray()
		await get_tree().process_frame
	var resolved := CoopTerrainBulk.resolve_join_sqlite(
		{"sqlite_bytes": expected_bytes, "chunk_count": chunk_count},
		_terrain_bulk_chunks
	)
	return resolved


func _clear_terrain_bulk_state() -> void:
	_terrain_bulk_chunks.clear()
	_terrain_bulk_expect_bytes = 0
	_terrain_bulk_expect_chunks = 0


func _finish_apply_join(payload: Dictionary) -> void:
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

	var you_pose: Variant = payload.get("you_pose")
	if you_pose is Dictionary and (you_pose as Dictionary).has("p"):
		await _bootstrap.reseat_player_near(_pose_position(you_pose))
	else:
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
	_route_guest_submit(peer, local_id, command, 0)


@rpc("authority", "call_remote", "reliable", CH_MAIN)
func _cli_result(local_id: int, result: Dictionary) -> void:
	if (
		_gateway != null
		and StringName(result.get("command_kind", &"")) == &"toggle_control_seat"
		and StringName(result.get("status", &"")) == &"ok"
	):
		var data: Dictionary = result.get("data", {})
		if bool(data.get("seated", false)):
			_gateway.apply_local_seat_attach(
				_player,
				int(data.get("element_id", 0)),
				int(data.get("assembly_id", 0)),
				bool(data.get("passenger", false))
			)
		else:
			_gateway.release_local_seat_attach()
	_gateway.complete_remote(local_id, result)


func _on_host_command_completed(command_id: int, result: Dictionary) -> void:
	if _pending_results.has(command_id):
		var route: Array = _pending_results[command_id]
		_pending_results.erase(command_id)
		var peer := int(route[0])
		var local_id := int(route[1])
		var command: Dictionary = route[2]
		var attempts := int(route[3])
		if _should_soft_retry_guest_dig(result, attempts):
			_guest_dig_retries.append({
				"peer": peer,
				"local_id": local_id,
				"command": command,
				"attempts": attempts + 1,
				"wait": GUEST_DIG_RETRY_INTERVAL,
			})
			return
		rpc_id(peer, "_cli_result", local_id, CoopCommandCodec.sanitize_result(result))
	if StringName(result.get("status", &"")) != &"ok":
		return
	if NO_BROADCAST_KINDS.has(StringName(result.get("command_kind", &""))):
		return
	_mark_snapshot_dirty()


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
	_dig_ops.append(op)
	var truncated := 0
	while _dig_ops.size() > MAX_DIG_OPS:
		_dig_ops.pop_front()
		truncated += 1
	if truncated > 0:
		push_warning(
			"Coop: dig_ops ring truncated — dropped %d oldest (cap %d); late joiners miss early digs"
			% [truncated, MAX_DIG_OPS]
		)
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
	# Same-frame structural_event + command_completed for one mutate: keep a
	# single debounce start. Later frames still refresh debounce (burst coalesce).
	var frame := Engine.get_process_frames()
	if _snapshot_dirty and _snapshot_dirty_frame == frame:
		return
	_snapshot_dirty = true
	_snapshot_dirty_frame = frame
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


# -------------------------------------------------------------- store sync

## Stage-5 interim (not a full delta system): 1 Hz like suits. Only stores /
## buffers / inventories whose content changed since the last send. Topology
## still rides the existing full-snapshot path. Dig ops stay on NO_BROADCAST +
## their own channel — store credits from dig reach clients here.
func _broadcast_stores() -> void:
	if _registry.peer_ids().is_empty():
		return
	var world := _world()
	if world == null:
		return
	var payload := _compute_store_broadcast_payload(world)
	var stores_out: Dictionary = payload["resource_stores"]
	var buffers_out: Dictionary = payload["buffers"]
	var inventories_out: Dictionary = payload["player_inventories"]
	if (
		stores_out.is_empty()
		and buffers_out.is_empty()
		and inventories_out.is_empty()
	):
		return
	rpc("_cli_stores", payload)


## Diffs stores/buffers/inventories against the last-sent cache and stamps the
## cache for whatever it finds changed. Extracted from `_broadcast_stores`
## (unchanged order/logic) so a headless test can call it without a live
## multiplayer peer — see test_coop_bug_regressions.gd (COOP-05). Stores diff
## on `revision`, not wire content: content-equality would wrongly treat a
## value that churned back to an earlier, unacked-send's content as
## "unchanged" and never resend it over the `unreliable_ordered` CH_STREAM.
func _compute_store_broadcast_payload(world: SimulationWorld) -> Dictionary:
	var stores_out: Dictionary = {}
	for store: SimulationResourceStore in world.list_resource_stores():
		var prev_rev: Variant = _last_store_revision.get(store.store_id, -1)
		if store.revision != prev_rev:
			stores_out[store.store_id] = store.to_dict()
			_last_store_revision[store.store_id] = store.revision
	var buffers_out: Dictionary = {}
	for element: SimulationElement in world.list_elements_unsorted():
		if (
			element == null
			or element.industry_buffer == null
			or not IndustryArchetypeProfile.has_internal_buffer(
				element.archetype_id
			)
		):
			continue
		var wire: Dictionary = element.industry_buffer.to_dict()
		var prev: Variant = _last_buffer_wire.get(element.element_id)
		if prev != wire:
			buffers_out[element.element_id] = wire
			_last_buffer_wire[element.element_id] = wire
	var inventories_out: Dictionary = {}
	var inv_rev := world.get_player_inventory_revision()
	if inv_rev != _last_inventory_revision_sent:
		_last_inventory_revision_sent = inv_rev
		for player_uid: String in world.list_player_inventory_uids():
			var registry := world.get_player_inventory(player_uid)
			if registry != null:
				inventories_out[player_uid] = registry.to_dict()
	return {
		"resource_stores": stores_out,
		"buffers": buffers_out,
		"player_inventories": inventories_out,
	}


@rpc("authority", "call_remote", "unreliable_ordered", CH_STREAM)
func _cli_stores(payload: Dictionary) -> void:
	if _mode != Mode.CLIENT:
		return
	var world := _world()
	if world == null:
		return
	var stores: Variant = payload.get("resource_stores", {})
	if stores is Dictionary and not (stores as Dictionary).is_empty():
		world.sync_resource_stores(stores)
	var buffers: Variant = payload.get("buffers", {})
	if buffers is Dictionary and not (buffers as Dictionary).is_empty():
		world.sync_element_industry_buffers(buffers)
	var inventories: Variant = payload.get("player_inventories", {})
	if (
		inventories is Dictionary
		and not (inventories as Dictionary).is_empty()
	):
		world.sync_player_inventories(inventories)


func _clear_store_wire_cache() -> void:
	_last_store_revision.clear()
	_last_buffer_wire.clear()
	_last_inventory_revision_sent = -1
	_store_accum = 0.0


# ------------------------------------------------------- assembly motion stream

## Host: stream root + child body-group motions of every assembly that is
## actually moving (unreliable_ordered, like poses — a lost frame is replaced
## 66 ms later). Parked/sleeping assemblies cost nothing; clients keep them
## where the last snapshot put them. The host's Jolt read-back refreshes
## assembly.motion / body_group_motions every physics tick, so the world state
## read here is current.
func _broadcast_assembly_motion() -> void:
	if _registry.peer_ids().is_empty():
		return
	var world := _world()
	if world == null:
		return
	var batch: Dictionary = {}
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly.tombstoned or assembly.motion == null:
			continue
		var root_id := world.root_body_group_id(assembly.assembly_id)
		if root_id <= 0:
			continue
		var moving := _motion_is_live(assembly.motion)
		var motions: Dictionary = {root_id: assembly.motion.to_dict()}
		for group_id_variant: Variant in assembly.body_group_motions:
			var group_motion: AssemblyMotionState = (
				assembly.body_group_motions[group_id_variant]
			)
			if group_motion == null:
				continue
			motions[int(group_id_variant)] = group_motion.to_dict()
			moving = moving or _motion_is_live(group_motion)
		if moving:
			batch[assembly.assembly_id] = motions
	if not batch.is_empty():
		rpc("_cli_assembly_motion", batch)


func _motion_is_live(motion: AssemblyMotionState) -> bool:
	if motion.frozen or motion.sleeping:
		return false
	return (
		motion.linear_velocity.length_squared() > ASSEMBLY_SPEED_SQ
		or motion.angular_velocity.length_squared() > ASSEMBLY_SPIN_SQ
	)


@rpc("authority", "call_remote", "unreliable_ordered", CH_STREAM)
func _cli_assembly_motion(batch: Dictionary) -> void:
	if _mode != Mode.CLIENT:
		return
	var world := _world()
	if world == null:
		return
	for assembly_id_variant: Variant in batch:
		var assembly_id := int(assembly_id_variant)
		if world.get_assembly_raw(assembly_id) == null:
			# The assembly reached us mid-stream before the snapshot that
			# creates it; the next snapshot seats it, later frames apply.
			continue
		var packed: Dictionary = batch[assembly_id_variant]
		var motions: Dictionary = {}
		for group_id_variant: Variant in packed:
			var motion := AssemblyMotionState.from_dict(packed[group_id_variant])
			if motion.is_valid():
				motions[int(group_id_variant)] = motion
		if motions.is_empty():
			continue
		# Sim-side truth updates at packet rate; the smoothed body/visual pose
		# is written per-frame in _process from the sample buffer.
		world.sync_assembly_body_group_motions(assembly_id, motions)
		var stream: Dictionary = _assembly_streams.get_or_add(
			assembly_id,
			{"root_id": 0, "samples": []}
		)
		# Re-resolved every packet: a snapshot with a split/merge recompiles
		# body groups and the cached root id would silently go stale.
		# compile_body_groups caches by topology revision, so this is cheap.
		stream["root_id"] = world.root_body_group_id(assembly_id)
		var samples: Array = stream["samples"]
		samples.append({"t": Time.get_ticks_msec(), "motions": motions})
		while samples.size() > ASSEMBLY_BUFFER_LIMIT:
			samples.pop_front()


func _process(_delta: float) -> void:
	if _mode != Mode.CLIENT or _assembly_streams.is_empty():
		return
	if _session == null or _session.projection == null:
		return
	var now := Time.get_ticks_msec()
	var render_t := now - ASSEMBLY_INTERP_DELAY_MS
	for assembly_id_variant: Variant in _assembly_streams.keys():
		var stream: Dictionary = _assembly_streams[assembly_id_variant]
		var samples: Array = stream["samples"]
		var newest: Dictionary = samples[samples.size() - 1]
		if now - int(newest["t"]) > ASSEMBLY_STALE_MS:
			# Parked: the stream stopped on purpose; sim truth already holds
			# the final pose, so just stop touching the bodies.
			_assembly_streams.erase(assembly_id_variant)
			continue
		var previous: Dictionary = newest
		var factor := 1.0
		for index in range(samples.size() - 1):
			var a: Dictionary = samples[index]
			var b: Dictionary = samples[index + 1]
			if render_t < int(a["t"]) or render_t > int(b["t"]):
				continue
			previous = a
			newest = b
			var span := maxf(float(int(b["t"]) - int(a["t"])), 1.0)
			factor = clampf(float(render_t - int(a["t"])) / span, 0.0, 1.0)
			break
		_apply_assembly_blend(
			int(assembly_id_variant),
			int(stream["root_id"]),
			previous["motions"],
			newest["motions"],
			factor
		)


## Write the blended group poses onto the frozen kinematic replica bodies.
## Visual rigs are children of those bodies, so one write moves everything.
## Bodies are looked up fresh every frame: a snapshot restore mid-drive
## replaces them, and the stale-instance guard makes that a one-frame gap.
func _apply_assembly_blend(
	assembly_id: int,
	root_id: int,
	from_motions: Dictionary,
	to_motions: Dictionary,
	factor: float
) -> void:
	var projection := _session.projection
	for group_id_variant: Variant in to_motions:
		var group_id := int(group_id_variant)
		var to_motion: AssemblyMotionState = to_motions[group_id_variant]
		var from_motion: AssemblyMotionState = from_motions.get(
			group_id_variant,
			to_motion
		)
		var body: PhysicsBody3D = (
			projection.get_physics_body(assembly_id)
			if group_id == root_id
			else projection.get_group_physics_body(assembly_id, group_id)
		)
		if body == null or not is_instance_valid(body):
			continue
		var from_q := Quaternion(from_motion.transform.basis)
		var to_q := Quaternion(to_motion.transform.basis)
		body.global_transform = Transform3D(
			Basis(from_q.slerp(to_q, factor)),
			from_motion.transform.origin.lerp(to_motion.transform.origin, factor)
		)


# -------------------------------------------------------------------- pose relay

## Cold `players{}` extras for WorldPersistence.save (host only). Relay pose
## dicts keyed by uid — persistence normalizes to position/yaw rows.
func export_cold_poses() -> Dictionary:
	if _mode != Mode.HOST:
		return {}
	return _last_poses.duplicate(true)


## After host restart: session last-pose cache starts empty; seed from cold
## save so rejoin `you_pose` works without a prior live relay this session.
func _seed_last_poses_from_cold() -> void:
	var cold := WorldPersistence.cold_relay_poses()
	for uid_variant: Variant in cold.keys():
		var uid := str(uid_variant)
		if uid.is_empty() or uid == _local_uid:
			continue
		var pose: Variant = cold[uid_variant]
		if pose is Dictionary and (pose as Dictionary).has("p"):
			_last_poses[uid] = pose


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
	var seat_id := 0
	if _gateway != null:
		seat_id = _gateway.get_local_seat_element_id()
	return {
		"p": _player.global_position,
		"q": Quaternion(body_basis),
		"qh": Quaternion(head_basis),
		"l": lamp != null and lamp.visible,
		"v": velocity,
		"tool": _tools.active_tool if _tools != null else StringName(),
		"ta": _tools != null and _tools.is_drill_excavating(),
		"seat": seat_id,
	}


# ---------------------------------------------------------- seat control stream

## Client: SimulationSession skips rover input on replicas, so sample here while
## seated and relay raw+edges to the host at 20 Hz on CH_INPUT (own sequence —
## sharing CH_STREAM with large pose packets can drop ordered control frames).
func _tick_client_control_input(delta: float) -> void:
	if _gateway == null:
		_control_input_accum = 0.0
		_seat_edge_dampeners = false
		_seat_edge_parking_brake = false
		return
	var seat_id := _gateway.get_local_seat_element_id()
	if seat_id <= 0:
		_control_input_accum = 0.0
		_seat_edge_dampeners = false
		_seat_edge_parking_brake = false
		return
	# Cheap while-seated fallback: seat element or body gone → detach locally
	# (covers a lost force-release RPC after the host destroyed the cockpit).
	if not _client_seat_replica_ok(seat_id):
		_gateway.release_local_seat_attach()
		_control_input_accum = 0.0
		_seat_edge_dampeners = false
		_seat_edge_parking_brake = false
		return
	_gateway.ensure_local_seat_binding()
	if not _gateway.is_local_seat_driver():
		_control_input_accum = 0.0
		_seat_edge_dampeners = false
		_seat_edge_parking_brake = false
		return
	var modal_blocks := (
		_player != null
		and _player.has_method("is_gameplay_input_enabled")
		and not bool(_player.call("is_gameplay_input_enabled"))
	)
	if not modal_blocks:
		if Input.is_action_just_pressed(&"toggle_dampeners"):
			_seat_edge_dampeners = true
		if Input.is_action_just_pressed(&"toggle_parking_brake"):
			_seat_edge_parking_brake = true
	_control_input_accum += delta
	if _control_input_accum < CONTROL_INPUT_INTERVAL:
		return
	_control_input_accum = 0.0
	var raw := _gateway.collect_seat_raw_input(modal_blocks)
	var edges := {
		"toggle_dampeners": _seat_edge_dampeners,
		"toggle_parking_brake": _seat_edge_parking_brake,
	}
	_seat_edge_dampeners = false
	_seat_edge_parking_brake = false
	rpc_id(1, "_srv_control_input", raw, edges)


func _client_seat_replica_ok(element_id: int) -> bool:
	if element_id <= 0 or _session == null or _session.world == null:
		return false
	var element := _session.world.get_element(element_id)
	if element == null or not element.is_operational():
		return false
	if _session.projection == null:
		return false
	var body := (
		_session.projection.get_element_projection(element_id).get("body")
		as PhysicsBody3D
	)
	return body != null and is_instance_valid(body)


@rpc("any_peer", "call_remote", "unreliable_ordered", CH_INPUT)
func _srv_control_input(raw: Dictionary, edges: Dictionary) -> void:
	if _mode != Mode.HOST or _gateway == null:
		return
	var peer := multiplayer.get_remote_sender_id()
	var uid := _registry.uid_of(peer)
	if uid.is_empty():
		return
	_remote_driver_last_input_ms[uid] = Time.get_ticks_msec()
	_gateway.apply_remote_driver_input(uid, raw, edges)


## Host → seated guest: seat destroyed / non-operational. Reliable on CH_MAIN.
func _notify_remote_seat_force_release(
	player_id: String,
	_seat_element_id: int,
	_assembly_id: int
) -> void:
	if _mode != Mode.HOST or player_id.is_empty():
		return
	var peer := _registry.peer_of(player_id)
	if peer <= 0:
		return
	_remote_driver_last_input_ms.erase(player_id)
	rpc_id(peer, "_cli_force_seat_release")


@rpc("authority", "call_remote", "reliable", CH_MAIN)
func _cli_force_seat_release() -> void:
	if _mode != Mode.CLIENT or _gateway == null:
		return
	_gateway.release_local_seat_attach()
	_control_input_accum = 0.0
	_seat_edge_dampeners = false
	_seat_edge_parking_brake = false


func _tick_remote_driver_watchdog() -> void:
	if _gateway == null or _remote_driver_last_input_ms.is_empty():
		return
	var now := Time.get_ticks_msec()
	var stale: Array[String] = []
	for uid: String in _remote_driver_last_input_ms.keys():
		if now - int(_remote_driver_last_input_ms[uid]) > CONTROL_INPUT_STALE_MS:
			stale.append(uid)
	for uid: String in stale:
		_gateway.clear_remote_driver_input(uid)
		_remote_driver_last_input_ms.erase(uid)


func _clear_remote_driver(uid: String) -> void:
	if uid.is_empty() or _gateway == null:
		return
	_gateway.clear_remote_driver_input(uid)
	if _session != null and _session.world != null:
		_session.world.clear_player_seat_context(uid)
	_remote_driver_last_input_ms.erase(uid)


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
	if _avatars.has(uid):
		return _avatars[uid]
	var avatar := RemotePlayerScene.instantiate() as RemotePlayer
	avatar.setup(uid, nick)
	avatar.set_seat_transform_resolver(resolve_seat_world_transform)
	_avatars_root.add_child(avatar)
	_avatars[uid] = avatar
	# R-COOP-7: host must stream terrain around remote diggers (guest dig far
	# from host player → is_area_editable). Clients keep only the local viewer.
	if _mode == Mode.HOST:
		avatar.enable_host_stream_proxy()
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
	_guest_dig_retries.clear()
	_dig_ops.clear()
	_last_poses.clear()
	_clear_store_wire_cache()
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
	return pose.get("p", Vector3.ZERO)


func _route_guest_submit(
	peer: int,
	local_id: int,
	command: Dictionary,
	attempts: int
) -> void:
	if not _registry.has_peer(peer) or _gateway == null:
		return
	var host_id := _gateway.submit_as(
		_registry.uid_of(peer),
		command,
		_registry.avatar_of(peer)
	)
	_pending_results[host_id] = [peer, local_id, command, attempts]


func _should_soft_retry_guest_dig(result: Dictionary, attempts: int) -> bool:
	if attempts >= GUEST_DIG_RETRY_MAX:
		return false
	if not DIG_OP_KINDS.has(StringName(result.get("command_kind", &""))):
		return false
	return StringName(result.get("reason", &"")) == &"terrain_unavailable"


## Host: re-run guest digs that failed while Clipbox loaded the proxy shell.
## Interval backoff — not every physics tick (R9); no extra client RPCs.
func _tick_guest_dig_retries(delta: float) -> void:
	if _guest_dig_retries.is_empty():
		return
	var remaining: Array = []
	for entry_variant: Variant in _guest_dig_retries:
		if not (entry_variant is Dictionary):
			continue
		var entry: Dictionary = entry_variant
		var wait := float(entry.get("wait", 0.0)) - delta
		if wait > 0.0:
			entry["wait"] = wait
			remaining.append(entry)
			continue
		var peer := int(entry.get("peer", 0))
		if not _registry.has_peer(peer):
			continue
		_route_guest_submit(
			peer,
			int(entry.get("local_id", 0)),
			entry.get("command", {}),
			int(entry.get("attempts", 0))
		)
	_guest_dig_retries = remaining


## Retry join dig_ops that failed while the local chunk was not editable.
## Light interval — not every physics tick (R9).
func _tick_pending_dig_reapply(delta: float) -> void:
	if _pending_dig_ops.is_empty() or _gateway == null:
		return
	_pending_dig_accum += delta
	if _pending_dig_accum < PENDING_DIG_RETRY_INTERVAL:
		return
	_pending_dig_accum = 0.0
	var remaining: Array = []
	var recovered := 0
	for op_variant: Variant in _pending_dig_ops:
		if op_variant is Dictionary and _gateway.replay_remote_dig(op_variant):
			recovered += 1
		else:
			remaining.append(op_variant)
	_pending_dig_ops = remaining
	if recovered > 0 and _pending_dig_ops.is_empty():
		_info("join dig replay: recovered %d pending op(s)" % recovered)
	elif recovered > 0:
		push_warning(
			"join dig replay: recovered %d, %d still pending"
			% [recovered, _pending_dig_ops.size()]
		)


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
