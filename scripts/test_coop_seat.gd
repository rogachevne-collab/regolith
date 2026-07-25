extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Co-op seat occupancy + driver/passenger routing (COOP spike stage C).
## Pure gateway/world logic — no HUD, no network transport.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "COOP-SEAT")
	PlayerIdentity.override_local_uid("local_player")
	var tests: Array[Callable] = [
		_test_occupied_seat_blocks_second_actor,
		_test_passenger_seat_auto_resolves,
		_test_remote_passenger_input_ignored,
		_test_local_passenger_not_driver,
		_test_remote_driver_input_applies,
	]
	for test: Callable in tests:
		if not bool(await test.call()):
			get_tree().quit(1)
			return
	print("COOP-SEAT: PASS")
	get_tree().quit(0)


func _boot() -> Dictionary:
	for _frame: int in range(2):
		await get_tree().process_frame
	var terrain := VoxelTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.generate_collisions = false
	var generator := VoxelGeneratorFlat.new()
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height = 0.0
	terrain.generator = generator
	terrain.mesher = VoxelMesherTransvoxel.new()
	terrain.run_stream_in_editor = true
	add_child(terrain)
	var placed := Node3D.new()
	placed.name = "PlacedBlocks"
	add_child(placed)
	var session_scene: PackedScene = load(
		"res://scenes/simulation_session.tscn"
	)
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
	session.world.ensure_resource_store(PlayerIdentity.store_id("local_player"))
	var intent := RoverIntent.from_phrase("широкий")
	var compose := RoverComposer.compose(session.world, intent)
	if not bool(compose.get("ok", false)):
		gateway.queue_free()
		session.queue_free()
		return {"ok": false, "error": compose.get("error", "?")}
	var assembly_id := int(compose.get("assembly_id", 0))
	session.projection.project_assembly_now(assembly_id)
	for _frame: int in range(6):
		await get_tree().physics_frame
	return {
		"ok": true,
		"gateway": gateway,
		"session": session,
		"terrain": terrain,
		"placed": placed,
		"world": session.world,
		"assembly_id": assembly_id,
		"seats": _find_seats(session.world, assembly_id),
	}


func _free_boot(boot: Dictionary) -> void:
	var gateway: WorldCommandGateway = boot.get("gateway")
	var session: SimulationSession = boot.get("session")
	var terrain: Node = boot.get("terrain")
	var placed: Node = boot.get("placed")
	if gateway != null:
		gateway.queue_free()
	if session != null:
		session.queue_free()
	if placed != null:
		placed.queue_free()
	if terrain != null:
		terrain.queue_free()


func _find_seats(world: SimulationWorld, assembly_id: int) -> Dictionary:
	var out := {"cockpit": 0, "passenger": 0}
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return out
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element == null:
			continue
		if element.archetype_id == "cockpit":
			out["cockpit"] = element_id
		elif element.archetype_id == "passenger_seat":
			out["passenger"] = element_id
	return out


func _seat_target(
	element_id: int,
	assembly_id: int
) -> Dictionary:
	return {
		"valid": true,
		"point": Vector3.ZERO,
		"normal": Vector3.UP,
		"target_kind": InteractionHit.KIND_CONTROL_SEAT,
		"element_id": element_id,
		"assembly_id": assembly_id,
		"control_seat": true,
	}


func _exec_seat(
	gateway: WorldCommandGateway,
	actor_uid: String,
	element_id: int,
	assembly_id: int,
	parameters: Dictionary = {}
) -> Dictionary:
	var previous := gateway.actor_uid
	gateway.actor_uid = actor_uid
	var result := gateway._execute({
		"kind": &"toggle_control_seat",
		"target": _seat_target(element_id, assembly_id),
		"parameters": parameters,
	})
	gateway.actor_uid = previous
	return result


func _test_occupied_seat_blocks_second_actor() -> bool:
	var boot := await _boot()
	if not bool(boot.get("ok", false)):
		return _fail("boot failed: %s" % boot.get("error", "?"))
	var gateway: WorldCommandGateway = boot["gateway"]
	var world: SimulationWorld = boot["world"]
	var assembly_id: int = boot["assembly_id"]
	var seats: Dictionary = boot["seats"]
	var cockpit_id := int(seats.get("cockpit", 0))
	if cockpit_id <= 0:
		_free_boot(boot)
		return _fail("wide rover missing cockpit")
	var first := _exec_seat(gateway, "driver_a", cockpit_id, assembly_id)
	if StringName(first.get("status", &"")) != &"ok":
		_free_boot(boot)
		return _fail("first driver should seat: %s" % first)
	if not world.is_seat_occupied(cockpit_id):
		_free_boot(boot)
		return _fail("cockpit not marked occupied after first seat")
	var second := _exec_seat(gateway, "driver_b", cockpit_id, assembly_id)
	_free_boot(boot)
	if StringName(second.get("status", &"")) != &"failed":
		return _fail("second actor status should be failed, got %s" % second)
	if StringName(second.get("reason", &"")) != &"blocked":
		return _fail("second actor reason should be blocked, got %s" % second)
	if StringName((second.get("data", {}) as Dictionary).get("detail", &"")) != &"occupied":
		return _fail("blocked detail should be occupied, got %s" % second)
	return true


func _test_passenger_seat_auto_resolves() -> bool:
	var boot := await _boot()
	if not bool(boot.get("ok", false)):
		return _fail("boot failed: %s" % boot.get("error", "?"))
	var gateway: WorldCommandGateway = boot["gateway"]
	var assembly_id: int = boot["assembly_id"]
	var passenger_id := int((boot["seats"] as Dictionary).get("passenger", 0))
	if passenger_id <= 0:
		_free_boot(boot)
		return _fail("wide rover missing passenger_seat")
	# No explicit parameters.passenger — archetype alone must classify the seat.
	var result := _exec_seat(gateway, "guest_pax", passenger_id, assembly_id)
	_free_boot(boot)
	if StringName(result.get("status", &"")) != &"ok":
		return _fail("passenger seat enter failed: %s" % result)
	if not bool((result.get("data", {}) as Dictionary).get("passenger", false)):
		return _fail("passenger_seat must auto-resolve passenger=true")
	return true


func _test_remote_passenger_input_ignored() -> bool:
	var boot := await _boot()
	if not bool(boot.get("ok", false)):
		return _fail("boot failed: %s" % boot.get("error", "?"))
	var gateway: WorldCommandGateway = boot["gateway"]
	var world: SimulationWorld = boot["world"]
	var assembly_id: int = boot["assembly_id"]
	var passenger_id := int((boot["seats"] as Dictionary).get("passenger", 0))
	if passenger_id <= 0:
		_free_boot(boot)
		return _fail("wide rover missing passenger_seat")
	var seat := _exec_seat(gateway, "guest_pax", passenger_id, assembly_id)
	if StringName(seat.get("status", &"")) != &"ok":
		_free_boot(boot)
		return _fail("passenger seat enter failed")
	var locomotion := world.get_locomotion_controller(assembly_id)
	locomotion.clear_driver_input()
	gateway.apply_remote_driver_input(
		"guest_pax",
		{"drive": 1.0, "steer": 1.0, "zero_frame": false},
		{}
	)
	var drive := locomotion.drive_command
	var steer := locomotion.steering_command
	_free_boot(boot)
	if absf(drive) > 0.001 or absf(steer) > 0.001:
		return _fail(
			"passenger stream must not steer (drive=%s steer=%s)"
			% [drive, steer]
		)
	return true


func _test_local_passenger_not_driver() -> bool:
	var boot := await _boot()
	if not bool(boot.get("ok", false)):
		return _fail("boot failed: %s" % boot.get("error", "?"))
	var gateway: WorldCommandGateway = boot["gateway"]
	var assembly_id: int = boot["assembly_id"]
	var passenger_id := int((boot["seats"] as Dictionary).get("passenger", 0))
	if passenger_id <= 0:
		_free_boot(boot)
		return _fail("wide rover missing passenger_seat")
	var player := _MockSeatPlayer.new()
	add_child(player)
	gateway.actor_uid = PlayerIdentity.local_uid()
	var enter := gateway._execute({
		"kind": &"toggle_control_seat",
		"source": player,
		"target": _seat_target(passenger_id, assembly_id),
		"parameters": {},
	})
	if StringName(enter.get("reason", &"")) != &"ok":
		_free_boot(boot)
		player.queue_free()
		return _fail("local passenger enter failed: %s" % enter)
	if gateway.is_local_seat_driver():
		_free_boot(boot)
		player.queue_free()
		return _fail("passenger attach must not count as driver")
	var world: SimulationWorld = boot["world"]
	var locomotion := world.get_locomotion_controller(assembly_id)
	locomotion.clear_driver_input()
	locomotion.set_drive_command(0.0)
	gateway.tick_rover_locomotion_input()
	var after_drive := locomotion.drive_command
	_free_boot(boot)
	player.queue_free()
	if absf(after_drive) > 0.001:
		return _fail("tick_rover_locomotion_input must skip passenger seats")
	return true


func _test_remote_driver_input_applies() -> bool:
	var boot := await _boot()
	if not bool(boot.get("ok", false)):
		return _fail("boot failed: %s" % boot.get("error", "?"))
	var gateway: WorldCommandGateway = boot["gateway"]
	var world: SimulationWorld = boot["world"]
	var assembly_id: int = boot["assembly_id"]
	var cockpit_id := int((boot["seats"] as Dictionary).get("cockpit", 0))
	if cockpit_id <= 0:
		_free_boot(boot)
		return _fail("wide rover missing cockpit")
	var seat := _exec_seat(gateway, "guest_driver", cockpit_id, assembly_id)
	if StringName(seat.get("status", &"")) != &"ok":
		_free_boot(boot)
		return _fail("driver seat enter failed: %s" % seat)
	if bool((seat.get("data", {}) as Dictionary).get("passenger", true)):
		_free_boot(boot)
		return _fail("cockpit must not resolve as passenger")
	var locomotion := world.get_locomotion_controller(assembly_id)
	locomotion.set_parking_brake(false)
	locomotion.clear_driver_input()
	gateway.apply_remote_driver_input(
		"guest_driver",
		{"drive": 0.8, "steer": -0.4, "zero_frame": false},
		{}
	)
	var drive := locomotion.drive_command
	var steer := locomotion.steering_command
	_free_boot(boot)
	if absf(drive - 0.8) > 0.001:
		return _fail("remote driver drive expected 0.8 got %s" % drive)
	if absf(steer - (-0.4)) > 0.001:
		return _fail("remote driver steer expected -0.4 got %s" % steer)
	return true


func _fail(message: String) -> bool:
	push_error(message)
	print("COOP-SEAT: FAIL — %s" % message)
	return false


class _MockSeatPlayer:
	extends Node3D

	var _vehicle: Node3D = null

	func enter_vehicle(body: Node3D, _offset: Vector3) -> void:
		_vehicle = body

	func is_in_vehicle() -> bool:
		return _vehicle != null

	func current_vehicle() -> Node3D:
		return _vehicle

	func set_vehicle_flight_controls(_enabled: bool) -> void:
		pass
