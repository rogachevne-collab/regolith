class_name CoopJoinService
extends RefCounted


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
static func prepare_join_terrain_bulk(session) -> Dictionary:
	await session._bootstrap.flush_digs_for_coop_join()
	var dig_mark: int = session._dig_ops.size()
	var bulk: Dictionary = session._bootstrap.capture_coop_terrain_bulk()
	var sqlite_bytes: PackedByteArray = bulk.get("sqlite", PackedByteArray())
	var granular: Dictionary = bulk.get("granular", {})
	## Cold bulk present → dig_ops = post-flush tail only (avoid double-carve).
	## Empty sqlite → full session ring (pre-bulk fallback).
	var join_dig_ops: Array = CoopTerrainBulk.select_join_dig_ops(
		session._dig_ops, dig_mark, sqlite_bytes
	)
	var fallback_dig_ops: Array = (
		session._dig_ops.slice(0, clampi(dig_mark, 0, session._dig_ops.size()))
		if not sqlite_bytes.is_empty()
		else []
	)
	return {
		"join_dig_ops": join_dig_ops,
		"sqlite_bytes": sqlite_bytes,
		"granular": granular,
		"fallback_dig_ops": fallback_dig_ops,
	}


static func send_terrain_bulk_chunks(
	session,
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
		session.rpc_id(peer, "_cli_terrain_bulk_chunk", i, chunks.size(), chunks[i])


static func seed_joiner(session, uid: String) -> void:
	var world: SimulationWorld = session._world()
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


static func apply_join(session, payload: Dictionary) -> void:
	# Flush this machine's own save first, then stop persisting the replica.
	await session._bootstrap.save_now_then_inhibit_persistence()

	var world: SimulationWorld = session._world()
	world.authoritative = false
	session._replica_ready = false
	session._assembly_streams.clear()
	session._observer_wheel_spin.clear()
	session._observer_wheel_mounts.clear()
	world.restore_snapshot(payload["snapshot"])
	# Spawn host/peer avatars NOW — before terrain-bulk wait. Otherwise the
	# guest drops ~15–20s of `_cli_pose` (host invisible until bulk finishes /
	# viewers kick and it "feels like a reload").
	spawn_join_roster_avatars(session, payload)
	## Cold digs (SQLite + granular) before session dig_ops tail — bulk is the
	## host dig-stream truth; dig_ops only cover ops after the host flush.
	await apply_join_terrain_bulk(session, payload.get("terrain_bulk"))
	session._pending_dig_ops.clear()
	session._pending_dig_accum = 0.0
	var dig_ok := 0
	var dig_fail := 0
	for op_variant: Variant in payload.get("dig_ops", []):
		if op_variant is Dictionary:
			if session._gateway.replay_remote_dig(op_variant):
				dig_ok += 1
			else:
				dig_fail += 1
				session._pending_dig_ops.append(op_variant)
		else:
			dig_fail += 1
	if dig_fail > 0:
		push_warning(
			"join dig replay: %d ok, %d queued for retry (chunk not editable yet)"
			% [dig_ok, session._pending_dig_ops.size()]
		)
	await finish_apply_join(session, payload)


static func apply_join_terrain_bulk(session, meta_variant: Variant) -> void:
	if not (meta_variant is Dictionary):
		clear_terrain_bulk_state(session)
		return
	var meta: Dictionary = meta_variant
	var nbytes := int(meta.get("sqlite_bytes", 0))
	var chunk_count := int(meta.get("chunk_count", 0))
	var granular: Dictionary = meta.get("granular", {})
	var sqlite := PackedByteArray()
	if meta.has("sqlite") and meta["sqlite"] is PackedByteArray:
		sqlite = CoopTerrainBulk.resolve_join_sqlite(meta)
	elif nbytes > 0 and chunk_count > 0:
		session._terrain_bulk_expect_bytes = nbytes
		session._terrain_bulk_expect_chunks = chunk_count
		sqlite = await wait_terrain_bulk_chunks(session, chunk_count, nbytes)
		if sqlite.is_empty() and nbytes > 0:
			push_warning(
				"join terrain bulk: timed out or incomplete (%d/%d chunks)"
				% [session._terrain_bulk_chunks.size(), chunk_count]
			)
			## DIG-03: the sqlite bulk never arrived, so any cold holes the
			## host excluded from dig_ops (tail-only decision) exist nowhere
			## else — replay the fallback ring instead of losing them.
			replay_fallback_dig_ops(session, meta.get("fallback_dig_ops", []))
	clear_terrain_bulk_state(session)
	if sqlite.is_empty() and granular.is_empty():
		return
	session._bootstrap.apply_coop_terrain_bulk(sqlite, granular)


## Same soft-recovery shape as the join dig_ops tail (_apply_join) and live
## ops (_cli_dig_op) — a replay that fails here (chunk not editable yet) is
## queued into _pending_dig_ops for the existing retry loop.
static func replay_fallback_dig_ops(session, ops_variant: Variant) -> void:
	if not (ops_variant is Array) or session._gateway == null:
		return
	for op_variant: Variant in (ops_variant as Array):
		if not (op_variant is Dictionary):
			continue
		if not session._gateway.replay_remote_dig(op_variant):
			session._pending_dig_ops.append(op_variant)


static func wait_terrain_bulk_chunks(
	session,
	chunk_count: int,
	expected_bytes: int
) -> PackedByteArray:
	var deadline_ms := (
		Time.get_ticks_msec() + int(session.TERRAIN_BULK_CHUNK_WAIT_SEC * 1000.0)
	)
	while true:
		var complete := true
		for seq: int in range(chunk_count):
			if not session._terrain_bulk_chunks.has(seq):
				complete = false
				break
		if complete:
			break
		if Time.get_ticks_msec() >= deadline_ms:
			return PackedByteArray()
		await session.get_tree().process_frame
	var resolved := CoopTerrainBulk.resolve_join_sqlite(
		{"sqlite_bytes": expected_bytes, "chunk_count": chunk_count},
		session._terrain_bulk_chunks
	)
	return resolved


static func clear_terrain_bulk_state(session) -> void:
	session._terrain_bulk_chunks.clear()
	session._terrain_bulk_expect_bytes = 0
	session._terrain_bulk_expect_chunks = 0


## Avatars from the join roster (host + already-connected peers). Safe to call
## more than once — `_spawn_avatar` is idempotent per uid.
static func spawn_join_roster_avatars(session, payload: Dictionary) -> void:
	var host_info: Dictionary = payload.get("host", {})
	var host_uid := String(host_info.get("uid", ""))
	if not host_uid.is_empty():
		var host_avatar: RemotePlayer = session._spawn_avatar(
			host_uid,
			String(host_info.get("nick", host_uid.substr(0, 6)))
		)
		var host_pose: Variant = host_info.get("pose")
		if host_pose is Dictionary and (host_pose as Dictionary).has("p"):
			host_avatar.push_pose(host_pose)
	var peers: Dictionary = payload.get("peers", {})
	for peer_key: Variant in peers:
		var row: Dictionary = peers[peer_key]
		var uid := String(row.get("uid", ""))
		if uid.is_empty() or uid == session._local_uid or uid == host_uid:
			continue
		session._spawn_avatar(uid, String(row.get("nick", uid.substr(0, 6))))


static func finish_apply_join(session, payload: Dictionary) -> void:
	if session._meteorites != null:
		session._meteorites.set("enabled", false)
		if "debug_spawn_enabled" in session._meteorites:
			session._meteorites.set("debug_spawn_enabled", false)
		session._meteorites.set_process(false)
		session._meteorites.set_physics_process(false)

	session._gateway.set_network_submit(session._on_local_submit)

	# Idempotent — usually already spawned before terrain bulk.
	spawn_join_roster_avatars(session, payload)

	var host_info: Dictionary = payload["host"]
	var you_pose: Variant = payload.get("you_pose")
	if you_pose is Dictionary and (you_pose as Dictionary).has("p"):
		await session._bootstrap.reseat_player_near(session._pose_position(you_pose))
	else:
		var host_pos: Vector3 = session._pose_position(host_info["pose"])
		await session._bootstrap.reseat_player_near(
			host_pos + session._tangent_offset(host_pos, 4.0)
		)
	session._replica_ready = true
	session._info("joined '%s' — welcome to their Moon" % String(host_info["nick"]))
