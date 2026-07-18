extends Node
## Kernel coverage for vehicle battery drain + cabin power snapshot (ETA).


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var tests: Array[Callable] = [
		_test_seed_once_no_refill_after_drain,
		_test_drive_demand_drains_battery,
		_test_snapshot_eta_matches_drain,
		_test_format_eta,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("VEHICLE-POWER-V1: PASS")
	get_tree().quit(0)


func _boot_demo_session() -> SimulationSession:
	var session_scene: PackedScene = load(
		"res://scenes/simulation_session.tscn"
	)
	var session := session_scene.instantiate() as SimulationSession
	add_child(session)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		session.world.get_archetype_registry().register(archetype)
	return session


func _spawn_demo_rover(session: SimulationSession) -> Dictionary:
	return RoverDemoSpawn.spawn_on_terrain(session, Vector3(8.0, 0.0, 0.0))


func _fail(message: String) -> bool:
	push_error("VEHICLE-POWER-V1: %s" % message)
	print("VEHICLE-POWER-V1: FAIL — %s" % message)
	get_tree().quit(1)
	return false


func _test_seed_once_no_refill_after_drain() -> bool:
	var session := _boot_demo_session()
	var spawn := _spawn_demo_rover(session)
	if not bool(spawn.get("ok", false)):
		session.queue_free()
		return _fail("demo rover spawn failed: %s" % spawn.get("error", "?"))
	var battery_id := int(spawn.get("element_ids", {}).get("battery", 0))
	if battery_id <= 0:
		session.queue_free()
		return _fail("demo rover missing battery")
	var runtime := session.world.ensure_industry_element_runtime(battery_id)
	if not runtime.battery_initialized:
		session.queue_free()
		return _fail("spawned battery must be initialized")
	var max_kwh := IndustryElectricProfile.battery_max_kwh(
		session.world.get_element(battery_id)
	)
	if absf(runtime.battery_kwh - max_kwh) > 0.001:
		session.queue_free()
		return _fail("spawned battery must start full")

	runtime.battery_kwh = 0.0
	IndustryElectricBudget.seed_battery_if_needed(session.world, battery_id)
	if runtime.battery_kwh > 0.000001:
		session.queue_free()
		return _fail("seed must not refill an initialized empty battery")

	session.queue_free()
	return true


func _test_drive_demand_drains_battery() -> bool:
	var session := _boot_demo_session()
	var spawn := _spawn_demo_rover(session)
	if not bool(spawn.get("ok", false)):
		session.queue_free()
		return _fail("demo rover spawn failed")
	var assembly_id := int(spawn.get("assembly_id", 0))
	var battery_id := int(spawn.get("element_ids", {}).get("battery", 0))
	var runtime := session.world.ensure_industry_element_runtime(battery_id)
	var before := runtime.battery_kwh

	var locomotion := session.world.get_locomotion_controller(assembly_id)
	locomotion.activate()
	locomotion.set_parking_brake(false)
	locomotion.set_drive_command(1.0)
	# ~30 s of full drive at industry tick granularity.
	for _i in range(120):
		IndustryElectricBudget.apply_tick(session.world, 0.25)

	var after := runtime.battery_kwh
	if after >= before - 0.00001:
		session.queue_free()
		return _fail(
			"battery must drain under drive load (before=%.4f after=%.4f)"
			% [before, after]
		)
	session.queue_free()
	return true


func _test_snapshot_eta_matches_drain() -> bool:
	var session := _boot_demo_session()
	var spawn := _spawn_demo_rover(session)
	if not bool(spawn.get("ok", false)):
		session.queue_free()
		return _fail("demo rover spawn failed")
	var assembly_id := int(spawn.get("assembly_id", 0))
	var locomotion := session.world.get_locomotion_controller(assembly_id)
	locomotion.activate()
	locomotion.set_parking_brake(false)
	locomotion.set_drive_command(1.0)
	IndustryElectricBudget.apply_tick(session.world, 0.25)

	var snap := VehiclePowerSnapshotBuilder.build(session.world, assembly_id)
	if not bool(snap.get("valid", false)):
		session.queue_free()
		return _fail("snapshot invalid: %s" % str(snap.get("reason", "?")))
	var demand_w := float(snap.get("demand_w", 0.0))
	if demand_w < 100.0:
		session.queue_free()
		return _fail("expected drive demand, got %.1f W" % demand_w)
	var battery_kwh := float(snap.get("battery_kwh", 0.0))
	var net_drain_w := float(snap.get("net_drain_w", 0.0))
	var eta_s := float(snap.get("eta_s", -1.0))
	if net_drain_w <= 0.0 or eta_s < 0.0:
		session.queue_free()
		return _fail("expected finite ETA under drive drain")
	var expected := battery_kwh / (
		net_drain_w * VehiclePowerSnapshotBuilder.WATTS_TO_KWH_PER_SECOND
	)
	if absf(eta_s - expected) > 0.5:
		session.queue_free()
		return _fail(
			"ETA mismatch got=%.2f expected=%.2f" % [eta_s, expected]
		)
	locomotion.set_drive_command(0.0)
	IndustryElectricBudget.apply_tick(session.world, 0.25)
	var idle_snap := VehiclePowerSnapshotBuilder.build(session.world, assembly_id)
	var idle_demand := float(idle_snap.get("demand_w", 0.0))
	if idle_demand >= demand_w:
		session.queue_free()
		return _fail(
			"idle demand (%.1f) must be below drive demand (%.1f)"
			% [idle_demand, demand_w]
		)
	session.queue_free()
	return true


func _test_format_eta() -> bool:
	if VehiclePowerSnapshotBuilder.format_eta_s(-1.0) != "∞":
		return _fail("negative ETA must format as ∞")
	if VehiclePowerSnapshotBuilder.format_eta_s(45.0) != "45с":
		return _fail("seconds format")
	if VehiclePowerSnapshotBuilder.format_eta_s(125.0) != "2м 05с":
		return _fail("minutes format")
	if VehiclePowerSnapshotBuilder.format_eta_s(3725.0) != "1ч 02м":
		return _fail("hours format")
	return true
