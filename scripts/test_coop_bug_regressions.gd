extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Locks 5 confirmed coop bugs from docs/BUG-HUNT-RC-2026-07-25.md as headless
## regressions (DIG-01, DIG-02, DIG-03, COOP-04, COOP-05). All five assert the
## CORRECT contract, not today's buggy behavior — per the hunt's instruction
## to prove the bug rather than skip it, every one of them is expected-red
## right now. No production fix lives here; each will flip green once the
## underlying defect is actually fixed. `coop_session.gd` gained two pure
## extract-method testability hooks (`_prepare_join_terrain_bulk`,
## `_compute_store_broadcast_payload`) and one const→var (chunk wait timeout)
## so these tests drive the real join/broadcast code paths — see the doc
## comments on those symbols.

const COLD_POINT := Vector3(1.0, 0.0, 1.0)
const TAIL_POINT := Vector3(4.0, 0.0, 4.0)
const COLD_SAMPLE := COLD_POINT + Vector3(0.0, -0.35, 0.0)
const TAIL_SAMPLE := TAIL_POINT + Vector3(0.0, -0.35, 0.0)


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "COOP-BUG-REGRESSIONS", 30.0)
	PlayerIdentity.override_local_uid("player")
	var tests: Array[Dictionary] = [
		{"id": "DIG-01", "fn": _test_dig01_flush_join_ships_stale_sqlite},
		{"id": "DIG-02", "fn": _test_dig02_concurrent_dig_during_flush_double_carves},
		{"id": "DIG-03", "fn": _test_dig03_chunk_timeout_loses_cold_holes},
		{"id": "COOP-04", "fn": _test_coop04_live_dig_replay_failure_not_queued},
		{"id": "COOP-05", "fn": _test_coop05_store_sync_no_redelivery_after_settle},
	]
	var failed: Array[String] = []
	for entry: Dictionary in tests:
		var ok := bool(await (entry["fn"] as Callable).call())
		print("COOP-BUG-REGRESSIONS: %s %s" % [entry["id"], "PASS" if ok else "FAIL"])
		if not ok:
			failed.append(String(entry["id"]))
	if not failed.is_empty():
		print(
			"COOP-BUG-REGRESSIONS: FAIL — confirmed open bug(s): %s"
			% ", ".join(failed)
		)
		get_tree().quit(1)
		return
	print("COOP-BUG-REGRESSIONS: PASS — all confirmed bugs fixed")
	get_tree().quit(0)


# --------------------------------------------------------------------- DIG-01

## Mirrors the *fixed* contract for bootstrap.gd's `flush_digs_for_coop_join`
## (previously bugged at bootstrap.gd:743-745 — `_persist_digs_durable`
## returned immediately if a save was already `_dig_persist_in_flight`,
## instead of waiting for it to finish, see `_persist_digs_durable`'s
## in-flight wait loop). `busy` starts true to stand in for "a save was
## already in flight when this join started"; the fixed contract guarantees
## the flush call does not return until that save has actually completed, so
## `busy` is always false by the time `_prepare_join_terrain_bulk` captures.
class _FakeBootstrapDig01:
	extends RefCounted
	var busy := true
	var stale_sqlite := PackedByteArray([0])
	var fresh_sqlite := PackedByteArray([0, 1, 2])

	func flush_digs_for_coop_join() -> void:
		busy = false

	func capture_coop_terrain_bulk() -> Dictionary:
		return {"sqlite": (stale_sqlite if busy else fresh_sqlite), "granular": {}}


func _test_dig01_flush_join_ships_stale_sqlite() -> bool:
	var coop := CoopSession.new()
	var fake := _FakeBootstrapDig01.new()
	coop._bootstrap = fake
	coop._dig_ops = []
	var terrain_bulk: Dictionary = await coop._prepare_join_terrain_bulk()
	coop.queue_free()
	var sqlite_bytes: PackedByteArray = terrain_bulk.get(
		"sqlite_bytes", PackedByteArray()
	)
	if sqlite_bytes == fake.fresh_sqlite:
		return true
	return _fail(
		"DIG-01: _prepare_join_terrain_bulk shipped stale sqlite bytes (%s) "
		% [sqlite_bytes]
		+ "while an earlier dig persist was still in flight — "
		+ "flush_digs_for_coop_join must not return before that in-flight "
		+ "save actually completes (bootstrap.gd _persist_digs_durable:743-745)"
	)


# --------------------------------------------------------------------- DIG-02

## Real bootstrap.gd's flush loop (_persist_digs_durable) re-checks
## _digs_dirty and folds a concurrent host dig into the SAME sqlite write
## before returning, so a dig that lands mid-flush is durably persisted by
## the time the caller's `await` resumes.
class _FakeBootstrapDig02:
	extends RefCounted
	var session: CoopSession
	var concurrent_op: Dictionary
	var sqlite_bytes: PackedByteArray

	func flush_digs_for_coop_join() -> void:
		session._dig_ops.append(concurrent_op)

	func capture_coop_terrain_bulk() -> Dictionary:
		return {"sqlite": sqlite_bytes, "granular": {}}


func _test_dig02_concurrent_dig_during_flush_double_carves() -> bool:
	var coop := CoopSession.new()
	var cold_op := _wire_dig_op(COLD_POINT)
	var concurrent_op := _wire_dig_op(TAIL_POINT)
	coop._dig_ops = [cold_op]
	var fake := _FakeBootstrapDig02.new()
	fake.session = coop
	fake.concurrent_op = concurrent_op
	## Non-empty → stands in for "this concurrent dig is already durably
	## persisted"; select_join_dig_ops treats non-empty sqlite as "cold bulk
	## present, dig_ops = post-flush tail only".
	fake.sqlite_bytes = PackedByteArray([1, 2, 3])
	coop._bootstrap = fake
	var terrain_bulk: Dictionary = await coop._prepare_join_terrain_bulk()
	coop.queue_free()
	var join_dig_ops: Array = terrain_bulk.get("join_dig_ops", [])
	for op_variant: Variant in join_dig_ops:
		var op: Dictionary = op_variant
		var point: Vector3 = (
			(op.get("target", {}) as Dictionary).get("point", Vector3.ZERO)
		)
		if point.is_equal_approx(TAIL_POINT):
			return _fail(
				"DIG-02: dig_ops tail included a hole already covered by the "
				+ "fresh sqlite bulk — dig_mark is captured before awaiting "
				+ "the flush (coop_session.gd _prepare_join_terrain_bulk), so "
				+ "a host dig executed mid-flush is double-carved on the "
				+ "joiner (sqlite bulk restore, then dig_ops replay of the "
				+ "same hole)"
			)
	return true


# --------------------------------------------------------------------- DIG-03

func _test_dig03_chunk_timeout_loses_cold_holes() -> bool:
	var fixture := await _new_terrain_fixture()
	if fixture.is_empty():
		return _fail("DIG-03 fixture build failed (terrain not editable)")
	var gateway: WorldCommandGateway = fixture["gateway"]
	var tool: VoxelTool = (fixture["terrain"] as VoxelTerrain).get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var coop := CoopSession.new()
	add_child(coop)
	## Shrink the real 120s chunk-assembly timeout so the test proves the
	## timeout path instead of waiting it out.
	coop.TERRAIN_BULK_CHUNK_WAIT_SEC = 0.2
	var cold_before := _sample_sdf(tool, COLD_SAMPLE)
	var tail_before := _sample_sdf(tool, TAIL_SAMPLE)
	if cold_before >= -0.05 or tail_before >= -0.05:
		coop.queue_free()
		_free_terrain_fixture(fixture)
		return _fail("DIG-03 fixture must be solid at both sample points")
	## Host decided dig_ops = tail-only because sqlite was non-empty at send
	## time (CoopTerrainBulk.select_join_dig_ops); the cold hole only exists
	## in the chunked terrain_bulk (which never fully arrives below) and in
	## the `fallback_dig_ops` safety net _prepare_join_terrain_bulk rides
	## along in the same meta for exactly this timeout case.
	var cold_op := _wire_dig_op(COLD_POINT)
	var meta := {
		"sqlite_bytes": 999999,
		"chunk_count": 4,
		"granular": {},
		"fallback_dig_ops": [cold_op],
	}
	await coop._apply_join_terrain_bulk(meta)  # no chunks ever delivered → timeout → empty
	var tail_op := _wire_dig_op(TAIL_POINT)
	var tail_ok := gateway.replay_remote_dig(tail_op)
	var cold_after := _sample_sdf(tool, COLD_SAMPLE)
	var tail_after := _sample_sdf(tool, TAIL_SAMPLE)
	coop.queue_free()
	_free_terrain_fixture(fixture)
	if not tail_ok or (tail_after - tail_before) <= 0.05:
		return _fail("DIG-03 fixture sanity: tail dig_ops replay must carve")
	var cold_delta := cold_after - cold_before
	if absf(cold_delta) < 0.05:
		return _fail(
			"DIG-03: cold dig hole was never carved after the chunked "
			+ "terrain_bulk timed out — host sends dig_ops=tail-only whenever "
			+ "sqlite is non-empty (CoopTerrainBulk.select_join_dig_ops) with "
			+ "no fallback to the full ring when the client never finishes "
			+ "assembling the bulk (coop_session.gd _wait_terrain_bulk_chunks "
			+ "timeout) — the cold hole is permanently lost for this joiner"
		)
	return true


# -------------------------------------------------------------------- COOP-04

func _test_coop04_live_dig_replay_failure_not_queued() -> bool:
	var coop := CoopSession.new()
	var gateway := WorldCommandGateway.new()
	coop._gateway = gateway
	coop._mode = CoopSession.Mode.CLIENT
	var bad_op := {
		"kind": &"voxel_remove",
		"target": {"valid": false},
		"parameters": {"radius": 0.5},
	}
	coop._cli_dig_op(bad_op)
	var pending: Array = coop._pending_dig_ops
	coop.queue_free()
	gateway.free()
	if pending.is_empty():
		return _fail(
			"COOP-04: live _cli_dig_op dropped a failed replay silently — the "
			+ "join path queues the same kind of failure into _pending_dig_ops "
			+ "for retry (coop_session.gd _apply_join:643-649), but the live "
			+ "dig-op handler (_cli_dig_op) ignores replay_remote_dig's return "
			+ "value entirely, so a live guest dig that fails (e.g. terrain "
			+ "not yet editable) never recovers"
		)
	return true


# -------------------------------------------------------------------- COOP-05

func _test_coop05_store_sync_no_redelivery_after_settle() -> bool:
	var world := SimulationWorld.new()
	var store_id := PlayerIdentity.store_id("uid_b")
	world.ensure_resource_store(store_id)
	world.set_resource_amount(store_id, "ore_mare_regolith", 3.0)
	var coop := CoopSession.new()
	var first: Dictionary = coop._compute_store_broadcast_payload(world)
	var first_stores: Dictionary = first.get("resource_stores", {})
	if not first_stores.has(store_id):
		coop.queue_free()
		world.free()
		return _fail(
			"COOP-05 fixture sanity: first broadcast must include the changed store"
		)
	## Packet "lost" on the unreliable_ordered CH_STREAM — no replica ever
	## applies it. The store then churns and settles back to the exact value
	## already stamped into the host's wire cache by the (lost) first send.
	world.set_resource_amount(store_id, "ore_mare_regolith", 9.0)
	world.set_resource_amount(store_id, "ore_mare_regolith", 3.0)
	var second: Dictionary = coop._compute_store_broadcast_payload(world)
	var second_stores: Dictionary = second.get("resource_stores", {})
	coop.queue_free()
	world.free()
	if not second_stores.has(store_id):
		return _fail(
			"COOP-05: host stamps _last_store_wire with no delivery "
			+ "acknowledgement from the unreliable_ordered CH_STREAM send — "
			+ "after the store value churned 3→9→3 with the first (lost) send "
			+ "never acked, the second broadcast produced an empty diff, so a "
			+ "peer that missed the first packet can never converge until the "
			+ "value changes to something new"
		)
	return true


# ----------------------------------------------------------------------- helpers

func _wire_dig_op(point: Vector3) -> Dictionary:
	return CoopCommandCodec.build_dig_op(
		{
			"kind": &"voxel_remove",
			"target": {
				"valid": true,
				"point": point,
				"target_kind": InteractionHit.KIND_VOXEL,
			},
			"parameters": {"radius": 0.5, "discard_yield": true},
		},
		{"status": &"ok", "data": {"removed_volume_m3": 0.1}}
	)


func _sample_sdf(tool: VoxelTool, point: Vector3) -> float:
	var cell := Vector3i(floori(point.x), floori(point.y), floori(point.z))
	return tool.get_voxel_f(cell)


func _new_terrain_fixture() -> Dictionary:
	for _frame: int in range(3):
		await get_tree().process_frame
	var terrain := VoxelTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.generate_collisions = true
	var generator := VoxelGeneratorFlat.new()
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height = 0.0
	terrain.generator = generator
	terrain.mesher = VoxelMesherTransvoxel.new()
	terrain.run_stream_in_editor = true
	terrain.automatic_loading_enabled = true
	add_child(terrain)
	var viewer := VoxelViewer.new()
	viewer.name = "TerrainViewer"
	viewer.view_distance = 64
	viewer.requires_collisions = true
	viewer.requires_visuals = false
	terrain.add_child(viewer)
	if not await _wait_for_editable_terrain(terrain):
		terrain.queue_free()
		return {}
	if not _seed_flat_terrain(terrain):
		terrain.queue_free()
		return {}
	var placed := Node3D.new()
	placed.name = "PlacedBlocks"
	add_child(placed)
	var session_scene: PackedScene = load("res://scenes/simulation_session.tscn")
	var session: SimulationSession = session_scene.instantiate()
	session.name = "SimulationSession"
	add_child(session)
	var gateway := WorldCommandGateway.new()
	gateway.name = "WorldCommandGateway"
	gateway.terrain_path = NodePath("../VoxelTerrain")
	gateway.placed_blocks_path = NodePath("../PlacedBlocks")
	gateway.simulation_session_path = NodePath("../SimulationSession")
	add_child(gateway)
	session.gateway_path = NodePath("../WorldCommandGateway")
	await get_tree().process_frame
	session.world.ensure_resource_store(PlayerIdentity.store_id("player"))
	for _frame: int in range(4):
		await get_tree().physics_frame
	return {
		"terrain": terrain,
		"gateway": gateway,
		"session": session,
		"placed": placed,
		"world": session.world,
	}


func _free_terrain_fixture(fixture: Dictionary) -> void:
	for key: String in ["gateway", "session", "placed", "terrain"]:
		var node: Node = fixture.get(key)
		if node != null:
			node.queue_free()


func _wait_for_editable_terrain(terrain: VoxelTerrain) -> bool:
	var tool: VoxelTool = terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var edit_box := AABB(Vector3(-8.0, -8.0, -8.0), Vector3(16.0, 16.0, 16.0))
	for _frame: int in range(180):
		if tool.is_area_editable(edit_box):
			return true
		await get_tree().physics_frame
	return false


## Direct block write after is_area_editable — avoids reading default SDF
## from blocks that have not streamed yet (see granular_corridor_test.gd).
func _seed_flat_terrain(terrain: VoxelTerrain, surface_y: float = 0.0) -> bool:
	var block_size := terrain.get_data_block_size()
	var block_pos := Vector3i.ZERO
	var buffer := VoxelBuffer.new()
	buffer.create(block_size, block_size, block_size)
	var block_origin := terrain.data_block_to_voxel(block_pos)
	for z: int in range(block_size):
		for x: int in range(block_size):
			for y: int in range(block_size):
				var world_y := float(block_origin.y + y)
				buffer.set_voxel_f(
					world_y - surface_y, x, y, z, VoxelBuffer.CHANNEL_SDF
				)
	return terrain.try_set_block_data(block_pos, buffer)


func _fail(message: String) -> bool:
	push_error(message)
	print("COOP-BUG-REGRESSIONS: FAIL — %s" % message)
	return false
