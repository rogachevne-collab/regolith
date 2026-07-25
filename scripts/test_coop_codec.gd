extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless gate for COOP-HOST-V0 stage 3 pure-logic pieces: command sanitizer,
## block-list, peer registry, join-payload round-trip, and the sanctioned
## sync_suit_state replica write. Networked flows are human-verified (two
## instances) — see the plan's manual script.


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
	if not _test_build_dig_op():
		_abort()
		return
	if not _test_sanitize_preserves_seat_target():
		_abort()
		return
	if not _test_sync_suit_state():
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
