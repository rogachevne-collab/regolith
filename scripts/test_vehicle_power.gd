extends Node
## Kernel coverage for vehicle battery drain + cabin power snapshot (ETA).


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var tests: Array[Callable] = [
		_test_seed_once_no_refill_after_drain,
		_test_drive_demand_drains_battery,
		_test_snapshot_eta_matches_drain,
		_test_drill_and_cable_rover_snapshot,
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
	return RoverComposer.spawn_on_terrain(session, Vector3(8.0, 0.0, 0.0))


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


## Реальный ровер несёт буры (потребители-инструменты) И провод
## battery→distributor. Дефолтный демо-ровер их не имеет, поэтому этот тест
## гоняет снапшот через изменённый билдер именно на этой топологии: cached_graph
## + сеть только по компонентам сборки должны корректно признать ровер запитанным
## своим кабелем и учесть спрос при живом линке и множестве потребителей.
func _test_drill_and_cable_rover_snapshot() -> bool:
	var session := _boot_demo_session()
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_actuator_archetypes():
		session.world.get_archetype_registry().register(archetype)
	var world := session.world
	var result: Dictionary = RoverComposer.spawn_on_terrain_from_phrase(
		session,
		Vector3(8.0, 0.0, 0.0),
		"колбаса на 12 колёсах, кокпит в центре, питание сбоку, два бура на морде"
	)
	if not bool(result.get("ok", false)):
		session.queue_free()
		return _fail(
			"drill rover spawn failed: %s %s"
			% [result.get("error", ""), result.get("failures", [])]
		)
	var assembly_id := int(result["assembly_id"])

	var drill_count := 0
	for element: SimulationElement in world.list_elements():
		if element.assembly_id != assembly_id:
			continue
		var arch := element.get_archetype()
		if arch != null and arch.archetype_id == "stationary_drill":
			drill_count += 1
	if drill_count < 2:
		session.queue_free()
		return _fail("drill rover должен нести 2 бура, got %d" % drill_count)

	var links := world.get_industry_network().list_links()
	if links.is_empty():
		session.queue_free()
		return _fail("drill rover должен нести провод battery→distributor")

	var locomotion := world.get_locomotion_controller(assembly_id)
	locomotion.activate()
	locomotion.set_parking_brake(false)
	locomotion.set_drive_command(1.0)
	IndustryElectricBudget.apply_tick(world, 0.25)
	var snap := VehiclePowerSnapshotBuilder.build(world, assembly_id)
	if not bool(snap.get("valid", false)):
		session.queue_free()
		return _fail("drill rover snapshot invalid: %s" % str(snap.get("reason", "?")))
	if not bool(snap.get("powered", false)):
		session.queue_free()
		return _fail(
			"drill rover должен быть запитан своим кабелем — cached_graph/скоуп "
			+ "сети потеряли покрытие потребителей"
		)
	if float(snap.get("demand_w", 0.0)) <= 0.0:
		session.queue_free()
		return _fail("drill rover под газом должен иметь demand_w>0")
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
