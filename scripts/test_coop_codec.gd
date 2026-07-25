extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless gate for COOP-HOST-V0 stage 3/5 pure-logic pieces: command sanitizer,
## block-list, peer registry, join-payload round-trip, and sanctioned replica
## sync_* writes (suit, resource stores, industry buffers, player inventories).
## Networked flows are human-verified (two instances) — see the plan's manual
## script.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "COOP-CODEC-V0")
	PlayerIdentity.override_local_uid("player")
	if not _test_sanitizer_strips_objects():
		_abort()
		return
	if not _test_block_list():
		_abort()
		return
	if not _test_registry():
		_abort()
		return
	if not _test_join_payload_roundtrip():
		_abort()
		return
	if not _test_join_payload_dig_ops():
		_abort()
		return
	if not _test_terrain_bulk_chunk_roundtrip():
		_abort()
		return
	if not _test_join_dig_ops_bulk_contract():
		_abort()
		return
	if not _test_build_dig_op():
		_abort()
		return
	if not _test_sanitize_preserves_seat_target():
		_abort()
		return
	if not _test_sync_suit_state():
		_abort()
		return
	if not _test_join_snapshot_per_uid_inventories():
		_abort()
		return
	if not _test_sync_resource_stores():
		_abort()
		return
	if not _test_sync_element_industry_buffers():
		_abort()
		return
	if not _test_sync_player_inventories():
		_abort()
		return
	print("COOP-CODEC-V0: PASS")
	get_tree().quit(0)


func _test_sanitizer_strips_objects() -> bool:
	var node := Node.new()
	var nested_ref := RefCounted.new()
	var command := {
		"kind": &"construction_apply",
		"id": 42,
		"actor_uid": "someone_else",
		"store_id": "player:someone_else",
		"source": node,
		"target": {
			"valid": true,
			"point": Vector3(1.0, 2.0, 3.0),
			"collider": node,
		},
		"parameters": {
			"archetype_id": "frame",
			"orientation_index": 0,
			"placement_plan": {"command": nested_ref},
			"nested_list": [1, node, {"deep": nested_ref, "keep": 7}],
		},
	}
	var clean := CoopCommandCodec.sanitize_command(command)
	node.free()

	for stripped: String in ["source", "id", "actor_uid", "store_id"]:
		if clean.has(stripped):
			return _fail("top-level %s survived sanitize" % stripped)
	if (clean["target"] as Dictionary).has("collider"):
		return _fail("target.collider survived")
	if (clean["parameters"] as Dictionary).has("placement_plan"):
		return _fail("placement_plan survived")
	if _has_object(clean):
		return _fail("an Object survived the recursive strip")
	# Serializable payload preserved.
	if clean["kind"] != &"construction_apply":
		return _fail("kind lost")
	if not (clean["target"] as Dictionary)["point"].is_equal_approx(Vector3(1, 2, 3)):
		return _fail("Vector3 target point lost")
	if str((clean["parameters"] as Dictionary)["archetype_id"]) != "frame":
		return _fail("archetype_id lost")
	var nested_list: Array = (clean["parameters"] as Dictionary)["nested_list"]
	# node removed from the list, dict entry kept minus its nested Object.
	if nested_list.size() != 2:
		return _fail("nested Object not removed from array (size %d)" % nested_list.size())
	var kept_dict: Dictionary = nested_list[1]
	if kept_dict.has("deep"):
		return _fail("nested Object in list-dict survived")
	if int(kept_dict.get("keep", 0)) != 7:
		return _fail("sibling scalar dropped with nested Object")
	# JSON round-trips only pure data — the real wire guarantee.
	if JSON.stringify(clean).is_empty():
		return _fail("sanitized command is not JSON-serializable")
	return true


func _test_block_list() -> bool:
	for blocked: StringName in [
		&"dig_terrain_debris", &"debug_spawn_spoil", &"place_block",
	]:
		if not CoopCommandCodec.is_kind_blocked(blocked):
			return _fail("%s should be blocked" % blocked)
	for allowed: StringName in [
		&"voxel_remove", &"scoop_spoil", &"dump_scoop",
		&"construction_apply", &"weld_element", &"transfer_resource",
		&"assign_hotbar_instance",
		&"collect_world_loot", &"enqueue_recipe", &"oxygen_refill",
		&"set_actuator_target", &"connect_network",
		&"toggle_control_seat",
	]:
		if CoopCommandCodec.is_kind_blocked(allowed):
			return _fail("%s should be allowed" % allowed)
	return true


func _test_registry() -> bool:
	var registry := CoopPeerRegistry.new()
	if registry.register(7, "uid_a", "Ann") != &"ok":
		return _fail("first register should be ok")
	if registry.register(7, "uid_a", "Ann") != &"already_registered":
		return _fail("re-register same peer should fail")
	if registry.register(9, "uid_a", "Imposter") != &"uid_conflict":
		return _fail("same uid on a new peer should conflict")
	if registry.register(9, "uid_b", "Bob") != &"ok":
		return _fail("distinct uid should register")
	if registry.uid_of(7) != "uid_a":
		return _fail("uid_of mismatch")
	if registry.store_id_of(9) != PlayerIdentity.store_id("uid_b"):
		return _fail("store_id_of mismatch")
	var payload := registry.peers_payload()
	if payload.size() != 2:
		return _fail("peers_payload size %d" % payload.size())
	registry.unregister(7)
	if registry.has_peer(7):
		return _fail("unregister did not remove peer")
	return true


func _test_join_payload_roundtrip() -> bool:
	var world := _build_world()
	if world == null:
		return _fail("world build failed")
	var snapshot := world.capture_snapshot()
	var registry := CoopPeerRegistry.new()
	registry.register(11, "uid_b", "Bob")
	var payload := CoopCommandCodec.make_join_payload(
		snapshot, registry.peers_payload(), "player", "Host", {"p": Vector3.ZERO}, 11
	)
	world.free()

	if CoopCommandCodec.validate_join_payload(payload) != &"ok":
		return _fail("valid payload rejected")
	if int(payload.get("you")) != 11:
		return _fail("you peer id not stamped")

	var bad_protocol := payload.duplicate(true)
	bad_protocol["protocol"] = 999
	if CoopCommandCodec.validate_join_payload(bad_protocol) != &"protocol_mismatch":
		return _fail("protocol mismatch not caught")
	var bad_real := payload.duplicate(true)
	bad_real["real_t_bits"] = 32 if CoopCommandCodec.real_t_bits() == 64 else 64
	if CoopCommandCodec.validate_join_payload(bad_real) != &"real_t_mismatch":
		return _fail("real_t mismatch not caught")
	var bad_gen := payload.duplicate(true)
	bad_gen["generator_version"] = -1
	if CoopCommandCodec.validate_join_payload(bad_gen) != &"generator_mismatch":
		return _fail("generator mismatch not caught")
	var bad_snap := payload.duplicate(true)
	bad_snap["snapshot"] = "not a dict"
	if CoopCommandCodec.validate_join_payload(bad_snap) != &"bad_snapshot":
		return _fail("bad snapshot not caught")

	# Apply to a replica and confirm identity — the client's join path.
	var replica := SimulationWorld.new()
	replica.authoritative = false
	if not replica.restore_snapshot(payload["snapshot"]):
		replica.free()
		return _fail("replica restore of join snapshot failed")
	var same := SimulationSnapshot.semantic_equals(snapshot, replica.capture_snapshot())
	replica.free()
	if not same:
		return _fail("join snapshot did not round-trip into a replica")
	return true


func _test_join_payload_dig_ops() -> bool:
	var world := _build_world()
	if world == null:
		return _fail("world build failed")
	var snapshot := world.capture_snapshot()
	world.free()
	var host_command := {
		"kind": &"voxel_remove",
		"source": Node.new(),
		"actor_uid": "ignored",
		"target": {
			"valid": true,
			"point": Vector3(1, 2, 3),
			"target_kind": InteractionHit.KIND_VOXEL,
			"collider": RefCounted.new(),
		},
		"parameters": {"radius": 0.5, "discard_yield": false},
	}
	var host_result := {
		"status": &"ok",
		"data": {"removed_volume_m3": 0.12, "point": Vector3(1, 2, 3)},
	}
	var dig_ops: Array = [CoopCommandCodec.build_dig_op(host_command, host_result)]
	var payload := CoopCommandCodec.make_join_payload(
		snapshot, {}, "player", "Host", {"p": Vector3.ZERO}, 7, dig_ops
	)
	if not (payload.get("dig_ops") is Array):
		return _fail("dig_ops missing from join payload")
	if (payload["dig_ops"] as Array).size() != 1:
		return _fail("dig_ops count mismatch")
	var op: Dictionary = (payload["dig_ops"] as Array)[0]
	if StringName(op.get("kind", &"")) != &"voxel_remove":
		return _fail("join dig_op kind lost")
	if not is_equal_approx(
		float((op.get("parameters", {}) as Dictionary).get("radius", 0.0)),
		0.5
	):
		return _fail("join dig_op radius lost")
	if bool((op.get("parameters", {}) as Dictionary).get("discard_yield", true)):
		return _fail("join dig_op must preserve host discard_yield=false")
	if _has_object(op):
		return _fail("join dig_op must be wire-safe")
	# Optional field — old payloads without dig_ops still validate.
	var legacy := payload.duplicate(true)
	legacy.erase("dig_ops")
	if CoopCommandCodec.validate_join_payload(legacy) != &"ok":
		return _fail("join payload without dig_ops should still validate")
	# Optional you_pose (session last-pose reseat) must not break validation.
	payload["you_pose"] = {"p": Vector3(1, 2, 3), "q": Quaternion.IDENTITY}
	if CoopCommandCodec.validate_join_payload(payload) != &"ok":
		return _fail("join payload with you_pose should still validate")
	# Optional terrain_bulk (cold dig SQLite meta) — inline + chunked shapes.
	var tiny := PackedByteArray([1, 2, 3, 4])
	payload["terrain_bulk"] = CoopTerrainBulk.make_bulk_meta(tiny, {}, 0, tiny)
	if CoopCommandCodec.validate_join_payload(payload) != &"ok":
		return _fail("join payload with inline terrain_bulk should validate")
	var legacy_bulk := payload.duplicate(true)
	legacy_bulk.erase("terrain_bulk")
	if CoopCommandCodec.validate_join_payload(legacy_bulk) != &"ok":
		return _fail("join payload without terrain_bulk should still validate")
	return true


func _test_terrain_bulk_chunk_roundtrip() -> bool:
	var src := PackedByteArray()
	src.resize(CoopTerrainBulk.CHUNK_SIZE_BYTES + 17)
	for i: int in src.size():
		src[i] = i % 251
	var chunks := CoopTerrainBulk.split_sqlite_chunks(src)
	if chunks.size() != 2:
		return _fail("expected 2 chunks for CHUNK_SIZE+17, got %d" % chunks.size())
	var joined := CoopTerrainBulk.join_sqlite_chunks(chunks, src.size())
	if joined != src:
		return _fail("chunk join did not restore sqlite bytes")
	var meta := CoopTerrainBulk.make_bulk_meta(src, {"version": 1, "regions": []}, chunks.size())
	if CoopTerrainBulk.validate_bulk_meta(meta) != &"ok":
		return _fail("chunked terrain_bulk meta should validate")
	var inline := PackedByteArray([9, 8, 7])
	var inline_meta := CoopTerrainBulk.make_bulk_meta(inline, {}, 0, inline)
	if CoopTerrainBulk.validate_bulk_meta(inline_meta) != &"ok":
		return _fail("inline terrain_bulk meta should validate")
	var bad := inline_meta.duplicate(true)
	bad["chunk_count"] = 1
	if CoopTerrainBulk.validate_bulk_meta(bad) == &"ok":
		return _fail("inline+chunk_count mismatch must fail")
	var empty_ok := CoopTerrainBulk.validate_bulk_meta(null)
	if empty_ok != &"ok":
		return _fail("missing terrain_bulk must be ok")
	## Out-of-order chunk dict (client CH_BULK receive order) must still resolve.
	var by_seq := {1: chunks[1], 0: chunks[0]}
	var resolved := CoopTerrainBulk.resolve_join_sqlite(meta, by_seq)
	if resolved != src:
		return _fail("resolve_join_sqlite out-of-order chunks must restore bytes")
	var inline_resolved := CoopTerrainBulk.resolve_join_sqlite(inline_meta)
	if inline_resolved != inline:
		return _fail("resolve_join_sqlite inline path lost bytes")
	return true


## Join catch-up contract: dig_ops tail vs full ring + attach inline/chunked
## + full payload validate. Fake sqlite bytes — no VoxelStream / dual process.
func _test_join_dig_ops_bulk_contract() -> bool:
	var cold_op := CoopCommandCodec.build_dig_op(
		{
			"kind": &"voxel_remove",
			"target": {
				"valid": true,
				"point": Vector3(1, 0, 1),
				"target_kind": InteractionHit.KIND_VOXEL,
			},
			"parameters": {"radius": 0.5, "discard_yield": true},
		},
		{"status": &"ok", "data": {"removed_volume_m3": 0.1}}
	)
	var live_op := CoopCommandCodec.build_dig_op(
		{
			"kind": &"voxel_remove",
			"target": {
				"valid": true,
				"point": Vector3(4, 0, 4),
				"target_kind": InteractionHit.KIND_VOXEL,
			},
			"parameters": {"radius": 0.5, "discard_yield": true},
		},
		{"status": &"ok", "data": {"removed_volume_m3": 0.1}}
	)
	var ring: Array = [cold_op, live_op]
	var dig_mark := 1
	var fake_sqlite := PackedByteArray([0x53, 0x51, 0x4c, 0x69, 0x74, 0x65])  # "SQLite"
	var with_bulk := CoopTerrainBulk.select_join_dig_ops(ring, dig_mark, fake_sqlite)
	if with_bulk.size() != 1:
		return _fail("non-empty sqlite must send dig_ops tail only (got %d)" % with_bulk.size())
	var tail_op: Dictionary = with_bulk[0]
	var tail_point: Vector3 = (tail_op.get("target", {}) as Dictionary).get(
		"point", Vector3.ZERO
	)
	if not tail_point.is_equal_approx(Vector3(4, 0, 4)):
		return _fail("dig_ops tail must keep the post-flush op")
	var no_bulk := CoopTerrainBulk.select_join_dig_ops(
		ring, dig_mark, PackedByteArray()
	)
	if no_bulk.size() != 2:
		return _fail("empty sqlite must fall back to full dig_ops ring")

	var world := _build_world()
	if world == null:
		return _fail("world build failed")
	var snapshot := world.capture_snapshot()
	world.free()
	var granular := {"version": 1, "regions": [{"id": "r0"}]}
	var payload := CoopCommandCodec.make_join_payload(
		snapshot, {}, "player", "Host", {"p": Vector3.ZERO}, 9, with_bulk
	)
	CoopTerrainBulk.attach_to_join_payload(payload, fake_sqlite, granular)
	if CoopCommandCodec.validate_join_payload(payload) != &"ok":
		return _fail("join payload with dig_ops+inline terrain_bulk rejected")
	var bulk_meta: Dictionary = payload.get("terrain_bulk", {})
	if int(bulk_meta.get("chunk_count", -1)) != 0:
		return _fail("tiny sqlite must attach inline (chunk_count=0)")
	if not (bulk_meta.get("sqlite") is PackedByteArray):
		return _fail("inline terrain_bulk missing sqlite bytes")
	if (bulk_meta["sqlite"] as PackedByteArray) != fake_sqlite:
		return _fail("inline terrain_bulk sqlite bytes mismatch")
	if not (bulk_meta.get("granular") is Dictionary):
		return _fail("terrain_bulk granular lost")
	if CoopTerrainBulk.resolve_join_sqlite(bulk_meta) != fake_sqlite:
		return _fail("client resolve of inline join bulk failed")

	## Chunked attach: just over INLINE max → no inline sqlite, chunks reassemble.
	var big := PackedByteArray()
	big.resize(CoopTerrainBulk.INLINE_SQLITE_MAX_BYTES + 1)
	for i: int in big.size():
		big[i] = (i * 17) % 256
	var chunked_payload := CoopCommandCodec.make_join_payload(
		snapshot, {}, "player", "Host", {"p": Vector3.ZERO}, 9, with_bulk
	)
	CoopTerrainBulk.attach_to_join_payload(chunked_payload, big, {})
	if CoopCommandCodec.validate_join_payload(chunked_payload) != &"ok":
		return _fail("chunked terrain_bulk join payload rejected")
	var chunk_meta: Dictionary = chunked_payload.get("terrain_bulk", {})
	if chunk_meta.has("sqlite"):
		return _fail("over-inline bulk must not embed sqlite in payload")
	var expected_chunks := CoopTerrainBulk.split_sqlite_chunks(big)
	if int(chunk_meta.get("chunk_count", 0)) != expected_chunks.size():
		return _fail("chunk_count mismatch after attach")
	## Simulate CH_BULK arrival shuffled, then client resolve.
	var recv := {}
	for i: int in expected_chunks.size():
		recv[expected_chunks.size() - 1 - i] = expected_chunks[expected_chunks.size() - 1 - i]
	var reassembled := CoopTerrainBulk.resolve_join_sqlite(chunk_meta, recv)
	if reassembled != big:
		return _fail("chunked join bulk did not reassemble host sqlite bytes")

	## Replica path: write/read fake bytes (path contract, not VoxelStream).
	var replica_dir := ProjectSettings.globalize_path(CoopTerrainBulk.REPLICA_DIR)
	if not DirAccess.dir_exists_absolute(replica_dir):
		DirAccess.make_dir_recursive_absolute(replica_dir)
	var replica_path := CoopTerrainBulk.replica_database_path()
	var file := FileAccess.open(replica_path, FileAccess.WRITE)
	if file == null:
		return _fail("cannot write fake sqlite to replica path")
	file.store_buffer(fake_sqlite)
	file.close()
	var read_back := FileAccess.get_file_as_bytes(replica_path)
	if read_back != fake_sqlite:
		return _fail("replica path roundtrip lost fake sqlite bytes")
	return true


func _test_build_dig_op() -> bool:
	var node := Node.new()
	var command := {
		"kind": &"voxel_remove",
		"source": node,
		"actor_uid": "guest",
		"target": {
			"valid": true,
			"point": Vector3(4, 5, 6),
			"target_kind": InteractionHit.KIND_VOXEL,
			"collider": node,
		},
		"parameters": {"radius": 0.35, "discard_yield": false},
	}
	var result := {
		"status": &"ok",
		"data": {"removed_volume_m3": 0.08},
	}
	var op := CoopCommandCodec.build_dig_op(command, result)
	node.free()
	if _has_object(op):
		return _fail("build_dig_op left an Object on the wire")
	if StringName(op.get("kind", &"")) != &"voxel_remove":
		return _fail("build_dig_op kind mismatch")
	var params: Dictionary = op.get("parameters", {})
	if not is_equal_approx(float(params.get("radius", 0.0)), 0.35):
		return _fail("build_dig_op radius lost")
	if bool(params.get("discard_yield", true)):
		return _fail("build_dig_op must preserve discard_yield=false")

	var scoop_cmd := {
		"kind": &"scoop_spoil",
		"target": {"valid": true, "point": Vector3.ZERO},
		"parameters": {},
	}
	var scoop_op := CoopCommandCodec.build_dig_op(
		scoop_cmd,
		{"data": {"scooped_volume_m3": 1.25}}
	)
	var scoop_params: Dictionary = scoop_op.get("parameters", {})
	if not is_equal_approx(float(scoop_params.get("max_volume_m3", 0.0)), 1.25):
		return _fail("build_dig_op scoop max_volume_m3 not stamped")

	var dump_op := CoopCommandCodec.build_dig_op(
		{
			"kind": &"dump_scoop",
			"target": {"valid": true, "point": Vector3.ONE},
			"parameters": {},
		},
		{"data": {"dumped_volume_m3": 0.75}}
	)
	var dump_params: Dictionary = dump_op.get("parameters", {})
	if not is_equal_approx(float(dump_params.get("volume_m3", 0.0)), 0.75):
		return _fail("build_dig_op dump volume_m3 not stamped")
	return true


func _test_sanitize_preserves_seat_target() -> bool:
	var node := Node.new()
	var command := {
		"kind": &"toggle_control_seat",
		"source": node,
		"actor_uid": "guest",
		"target": {
			"valid": true,
			"point": Vector3(1, 2, 3),
			"target_kind": InteractionHit.KIND_CONTROL_SEAT,
			"element_id": 42,
			"assembly_id": 7,
			"control_seat": true,
			"collider": node,
		},
		"parameters": {"passenger": true},
	}
	var clean := CoopCommandCodec.sanitize_command(command)
	node.free()
	var target: Dictionary = clean.get("target", {})
	if int(target.get("element_id", 0)) != 42:
		return _fail("seat element_id stripped by sanitize")
	if int(target.get("assembly_id", 0)) != 7:
		return _fail("seat assembly_id stripped by sanitize")
	if not bool(target.get("control_seat", false)):
		return _fail("seat control_seat flag lost")
	if not bool((clean.get("parameters", {}) as Dictionary).get("passenger", false)):
		return _fail("seat passenger parameter lost")
	if target.has("collider"):
		return _fail("seat collider survived sanitize")
	return true


func _test_sync_suit_state() -> bool:
	var host := SimulationWorld.new()
	host.ensure_suit_state("uid_b")
	host.apply_suit_damage("uid_b", 15.0)
	var values := host.get_suit_state("uid_b").to_dict()
	host.free()

	var replica := SimulationWorld.new()
	replica.authoritative = false
	var fired := [false]
	replica.suit_changed.connect(func(pid: String) -> void:
		if pid == "uid_b":
			fired[0] = true
	)
	replica.sync_suit_state("uid_b", values)
	if not fired[0]:
		replica.free()
		return _fail("sync_suit_state did not emit suit_changed")
	var mirrored := replica.get_suit_state("uid_b")
	if mirrored == null or not is_equal_approx(mirrored.health, float(values["health"])):
		replica.free()
		return _fail("suit health not mirrored")
	replica.free()

	# On an authoritative world it must refuse (host owns suits).
	var authoritative := SimulationWorld.new()
	authoritative.sync_suit_state("uid_b", values)
	var still_absent := not authoritative.has_suit_state("uid_b")
	authoritative.free()
	if not still_absent:
		return _fail("authoritative world accepted sync_suit_state")
	return true


func _test_join_snapshot_per_uid_inventories() -> bool:
	var world := SimulationWorld.new()
	IndustryStoreService.ensure_player_store(world, "uid_host")
	IndustryStoreService.ensure_player_store(world, "uid_guest")
	world.ensure_player_inventory("uid_host")
	var guest := world.ensure_player_inventory("uid_guest")
	if guest == null or not guest.set_hotbar_ref(0, 0, ""):
		world.free()
		return _fail("guest hotbar setup failed")
	var snapshot := world.capture_snapshot()
	var registry := CoopPeerRegistry.new()
	registry.register(11, "uid_guest", "Guest")
	var payload := CoopCommandCodec.make_join_payload(
		snapshot,
		registry.peers_payload(),
		"uid_host",
		"Host",
		{"p": Vector3.ZERO},
		11
	)
	world.free()
	if CoopCommandCodec.validate_join_payload(payload) != &"ok":
		return _fail("inventory join payload rejected")
	var replica := SimulationWorld.new()
	replica.authoritative = false
	if not replica.restore_snapshot(payload["snapshot"]):
		replica.free()
		return _fail("replica restore of inventory join snapshot failed")
	var host_inv := replica.get_player_inventory("uid_host")
	var guest_inv := replica.get_player_inventory("uid_guest")
	if host_inv == null or guest_inv == null:
		replica.free()
		return _fail("join snapshot must carry both peer inventories")
	if host_inv.hotbar_instance_id(0, 0) != "starter_tool_drill":
		replica.free()
		return _fail("host hotbar must stay seeded on replica")
	if guest_inv.hotbar_instance_id(0, 0) != "":
		replica.free()
		return _fail("guest cleared hotbar must arrive on replica")
	replica.free()
	return true


func _test_sync_resource_stores() -> bool:
	var store_id := PlayerIdentity.store_id("uid_b")
	var host := SimulationWorld.new()
	host.ensure_resource_store(store_id)
	host.set_resource_amount(store_id, "ore_mare_regolith", 3.5)
	var wire := {store_id: host.get_resource_store(store_id).to_dict()}
	host.free()

	var replica := SimulationWorld.new()
	replica.authoritative = false
	replica.sync_resource_stores(wire)
	var mirrored := replica.get_resource_store(store_id)
	if (
		mirrored == null
		or not is_equal_approx(mirrored.amount("ore_mare_regolith"), 3.5)
	):
		replica.free()
		return _fail("resource store not mirrored")
	replica.free()

	var authoritative := SimulationWorld.new()
	authoritative.sync_resource_stores(wire)
	if authoritative.get_resource_store(store_id) != null:
		authoritative.free()
		return _fail("authoritative world accepted sync_resource_stores")
	authoritative.free()
	return true


func _test_sync_element_industry_buffers() -> bool:
	var host := _build_world()
	if host == null:
		return _fail("world build failed")
	var element_id := 0
	for element: SimulationElement in host.list_elements():
		element_id = element.element_id
		break
	if element_id <= 0:
		host.free()
		return _fail("no element to attach buffer")
	var host_element := host.get_element(element_id)
	host_element.industry_buffer = ElementIndustryBuffer.new()
	host_element.industry_buffer.add("ore_mare_regolith", 2.0, 100.0)
	var wire := {element_id: host_element.industry_buffer.to_dict()}
	var snapshot := host.capture_snapshot()
	host.free()

	var replica := SimulationWorld.new()
	replica.authoritative = false
	if not replica.restore_snapshot(snapshot):
		replica.free()
		return _fail("replica restore failed before buffer sync")
	var replica_element := replica.get_element(element_id)
	replica_element.industry_buffer = ElementIndustryBuffer.new()
	replica.sync_element_industry_buffers(wire)
	if not is_equal_approx(
		replica_element.industry_buffer.amount("ore_mare_regolith"),
		2.0
	):
		replica.free()
		return _fail("industry buffer not mirrored")
	replica.free()

	var authoritative := SimulationWorld.new()
	if not authoritative.restore_snapshot(snapshot):
		authoritative.free()
		return _fail("authoritative restore failed")
	var auth_element := authoritative.get_element(element_id)
	auth_element.industry_buffer = ElementIndustryBuffer.new()
	authoritative.sync_element_industry_buffers(wire)
	if auth_element.industry_buffer.amount("ore_mare_regolith") > 0.000001:
		authoritative.free()
		return _fail("authoritative world accepted sync_element_industry_buffers")
	authoritative.free()
	return true


func _test_sync_player_inventories() -> bool:
	var host := SimulationWorld.new()
	var registry := host.ensure_player_inventory("uid_b")
	if registry == null:
		host.free()
		return _fail("ensure_player_inventory failed")
	var wire := {"uid_b": registry.to_dict()}
	host.free()

	var replica := SimulationWorld.new()
	replica.authoritative = false
	var rev_before := replica.get_player_inventory_revision()
	replica.sync_player_inventories(wire)
	var mirrored := replica.get_player_inventory("uid_b")
	if mirrored == null or mirrored.list_instance_ids().is_empty():
		replica.free()
		return _fail("player inventory not mirrored")
	if replica.get_player_inventory_revision() <= rev_before:
		replica.free()
		return _fail("sync_player_inventories did not bump revision")
	replica.free()

	var authoritative := SimulationWorld.new()
	authoritative.sync_player_inventories(wire)
	if authoritative.get_player_inventory("uid_b") != null:
		authoritative.free()
		return _fail("authoritative world accepted sync_player_inventories")
	authoritative.free()
	return true


func _build_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	var helper := AssemblyBuildHelper.new(world, PlayerIdentity.store_id("player"))
	helper.ensure_materials(300.0)
	if not helper.spawn_anchor(Slice01Archetypes.foundation()):
		world.free()
		return null
	if not helper.place(Slice01Archetypes.frame(), Vector3i(4, 0, 0), 0, "frame"):
		world.free()
		return null
	helper.weld_all()
	world.ensure_suit_state("player")
	world.apply_suit_damage("player", 5.0)
	world.ensure_player_inventory("player")
	return world


func _has_object(value: Variant) -> bool:
	if typeof(value) == TYPE_OBJECT:
		return true
	if value is Dictionary:
		for key: Variant in (value as Dictionary):
			if _has_object((value as Dictionary)[key]):
				return true
	elif value is Array:
		for entry: Variant in (value as Array):
			if _has_object(entry):
				return true
	return false


func _fail(message: String) -> bool:
	push_error(message)
	print("COOP-CODEC-V0: FAIL — %s" % message)
	return false


func _abort() -> void:
	get_tree().quit(1)
