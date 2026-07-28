class_name CoopSessionConsoleUtil
extends RefCounted


static func load_nick(session) -> String:
	if FileAccess.file_exists(session.NICK_PATH):
		var file: FileAccess = FileAccess.open(session.NICK_PATH, FileAccess.READ)
		if file != null:
			var stored: String = file.get_as_text().strip_edges()
			if not stored.is_empty():
				return stored
	return session._local_uid.substr(0, 6)


static func save_nick(session, nick: String) -> void:
	var file: FileAccess = FileAccess.open(session.NICK_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(nick)


## `--coop-autohost` / `--coop-autojoin[=ip[:port]]` after `--`. Waits for
## world ready (host refuses joiners with host_not_ready until then), then
## reuses the same paths as console `host` / `join`. Autojoin retries.
static func kickoff_cmdline_autostart(session) -> void:
	var want_autohost := false
	var want_autojoin := false
	var join_ip := "127.0.0.1"
	var join_port: int = session.PORT_DEFAULT
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
		print("CoopSession: autohost armed (port %d)" % session.PORT_DEFAULT)
		session._autohost_when_ready()
	if want_autojoin:
		print("CoopSession: autojoin armed → %s:%d" % [join_ip, join_port])
		session._autojoin_when_ready(join_ip, join_port)


static func await_world_ready(session) -> void:
	while session._bootstrap == null or not session._bootstrap.is_world_ready():
		await session.get_tree().process_frame


static func autohost_when_ready(session) -> void:
	await await_world_ready(session)
	print("CoopSession: autohost — world ready, hosting")
	cmd_host(session)


static func autojoin_when_ready(session, ip: String, port: int) -> void:
	await await_world_ready(session)
	print("CoopSession: autojoin — world ready, connecting to %s:%d" % [ip, port])
	var attempt := 0
	while attempt < session.AUTOJOIN_MAX_ATTEMPTS:
		if session._autojoin_admitted:
			print("CoopSession: autojoin succeeded")
			return
		if session._mode == session.Mode.OFFLINE:
			attempt += 1
			print(
				"CoopSession: autojoin attempt %d/%d → %s:%d"
				% [attempt, session.AUTOJOIN_MAX_ATTEMPTS, ip, port]
			)
			cmd_join(session, ip, port)
		await session.get_tree().create_timer(session.AUTOJOIN_INTERVAL_SEC).timeout
	if session._autojoin_admitted:
		print("CoopSession: autojoin succeeded")
		return
	print(
		"CoopSession: autojoin gave up after %d attempts → %s:%d"
		% [session.AUTOJOIN_MAX_ATTEMPTS, ip, port]
	)


static func cmd_host(session, port: int = -1) -> void:
	if port < 0:
		port = session.PORT_DEFAULT
	if session._mode != session.Mode.OFFLINE:
		session._err("already in a coop session — leave first")
		return
	if session._bootstrap == null or not session._bootstrap.is_world_ready():
		session._err("world is still loading; try again in a moment")
		return
	var peer := ENetMultiplayerPeer.new()
	var err: int = peer.create_server(port, session.MAX_PEERS, session.CHANNELS)
	if err != OK:
		session._err("could not host on port %d (error %d)" % [port, err])
		return
	session.multiplayer.multiplayer_peer = peer
	session._mode = session.Mode.HOST
	session._replica_ready = true
	session._registry = CoopPeerRegistry.new()
	session._pending_results.clear()
	session._guest_dig_retries.clear()
	session._dig_ops.clear()
	session._last_poses.clear()
	session._pose_inbox.clear()
	session._seed_last_poses_from_cold()
	session._clear_store_wire_cache()
	session._connect_host_hooks()
	session._info(
		"hosting on port %d as '%s' — share your Tailscale IP" % [port, session._local_nick]
	)


static func cmd_join(session, ip: String, port: int = -1) -> void:
	if port < 0:
		port = session.PORT_DEFAULT
	if session._mode != session.Mode.OFFLINE:
		session._err("already in a coop session — leave first")
		return
	if session._bootstrap == null or not session._bootstrap.is_world_ready():
		session._err("world is still loading; try again in a moment")
		return
	var peer := ENetMultiplayerPeer.new()
	var err: int = peer.create_client(ip, port, session.CHANNELS)
	if err != OK:
		session._err("could not reach %s:%d (error %d)" % [ip, port, err])
		return
	session.multiplayer.multiplayer_peer = peer
	session._mode = session.Mode.CLIENT
	# Snapshot + terrain bulk land later; ignore loco/stream until then.
	session._replica_ready = false
	session._pose_inbox.clear()
	session._assembly_streams.clear()
	session._observer_wheel_spin.clear()
	session._observer_wheel_mounts.clear()
	session._info("connecting to %s:%d ..." % [ip, port])


static func cmd_leave(session) -> void:
	if session._mode == session.Mode.OFFLINE:
		session._info("not in a coop session")
		return
	if session._mode == session.Mode.HOST:
		session._teardown_host()
	else:
		session._teardown_client_and_reload()


static func cmd_nick(session, new_name: String) -> void:
	var clean: String = new_name.strip_edges()
	if clean.is_empty():
		session._err("nick cannot be empty")
		return
	session._local_nick = clean
	save_nick(session, clean)
	session._info("nick set to '%s'" % clean)
	if session._mode == session.Mode.CLIENT:
		session.rpc_id(1, "_srv_set_nick", clean)
	elif session._mode == session.Mode.HOST:
		session.rpc("_cli_peer_nick", session._local_uid, clean)


static func cmd_coop_status(session) -> void:
	match session._mode:
		session.Mode.OFFLINE:
			session._info("coop: offline")
		session.Mode.HOST:
			session._info("coop: HOSTING, %d peer(s)" % session._registry.peer_ids().size())
			for peer_id: int in session._registry.peer_ids():
				session._info(
					"  #%d %s (%s)"
					% [
						peer_id,
						session._registry.nick_of(peer_id),
						session._registry.uid_of(peer_id).substr(0, 6),
					]
				)
		session.Mode.CLIENT:
			session._info("coop: CLIENT, %d other avatar(s)" % session._avatars.size())
