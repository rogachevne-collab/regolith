extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless gate for RoverComposer / RoverIntent / RoverValidator.


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "ROVER-COMPOSE")
	var tests: Array[Callable] = [
		_test_phrase_defaults,
		_test_phrase_six_long_low,
		_test_compose_default_four,
		_test_compose_six_long,
		_test_compose_twelve_sausage,
		_test_compose_short_wide,
		_test_unsupported_wheel_count,
		_test_bad_com_fixture,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("ROVER-COMPOSE: PASS")
	get_tree().quit(0)


func _boot_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 800.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 800.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 800.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 800.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 800.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 800.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 800.0)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		world.get_archetype_registry().register(archetype)
	return world


func _fail(message: String) -> bool:
	push_error("ROVER-COMPOSE FAIL: %s" % message)
	print("ROVER-COMPOSE: FAIL — %s" % message)
	get_tree().quit(1)
	return false


func _test_phrase_defaults() -> bool:
	var intent := RoverIntent.from_phrase("собери ровер")
	if intent.wheel_count != 4 or intent.length != "normal":
		return _fail("defaults broken: %s" % intent.to_dict())
	return true


func _test_phrase_six_long_low() -> bool:
	var intent := RoverIntent.from_phrase("ровер на 6 колёс, длинный, низкий")
	if intent.wheel_count != 6:
		return _fail("expected 6 wheels, got %d" % intent.wheel_count)
	if intent.length != "long":
		return _fail("expected long, got %s" % intent.length)
	if intent.height != "low":
		return _fail("expected low, got %s" % intent.height)
	return true


func _test_compose_default_four() -> bool:
	var world := _boot_world()
	var result := RoverComposer.compose(world, RoverIntent.defaults())
	if not bool(result.get("ok", false)):
		world.free()
		return _fail("default compose: %s %s" % [
			result.get("error", ""),
			result.get("failures", []),
		])
	var assembly_id := int(result["assembly_id"])
	var pairs := WheelSimulationService.discover_pairs(world, assembly_id)
	var complete := 0
	for pair: Dictionary in pairs:
		if WheelSimulationService.is_complete_pair(pair):
			complete += 1
	world.free()
	if complete != 4:
		return _fail("default expected 4 pairs, got %d" % complete)
	return true


func _test_compose_six_long() -> bool:
	var world := _boot_world()
	var intent := RoverIntent.from_phrase("длинный ровер на 6 колес")
	var result := RoverComposer.compose(world, intent)
	if not bool(result.get("ok", false)):
		world.free()
		return _fail("six long compose: %s %s" % [
			result.get("error", ""),
			result.get("failures", []),
		])
	var assembly_id := int(result["assembly_id"])
	var pairs := WheelSimulationService.discover_pairs(world, assembly_id)
	var complete := 0
	for pair: Dictionary in pairs:
		if WheelSimulationService.is_complete_pair(pair):
			complete += 1
	if complete != 6:
		world.free()
		return _fail("six long expected 6 pairs, got %d" % complete)
	if intent.battery_count() < 2:
		world.free()
		return _fail("six wheels should request >=2 batteries")
	var battery_ids := 0
	for key: Variant in result.get("element_ids", {}).keys():
		var key_str := str(key)
		if key_str == "battery" or key_str.begins_with("battery_"):
			battery_ids += 1
	if battery_ids < 2:
		world.free()
		return _fail("six long should place 2 batteries, got %d" % battery_ids)
	var locomotion := world.get_locomotion_controller(assembly_id)
	locomotion.activate()
	locomotion.set_drive_command(1.0)
	IndustryElectricBudget.apply_tick(world, 1.0 / 60.0)
	var powered := 0
	for pair: Dictionary in pairs:
		var wheel_id := int(pair.get("wheel_element_id", 0))
		var runtime := world.get_industry_element_runtime(wheel_id)
		if runtime != null and runtime.powered:
			powered += 1
	world.free()
	if powered != 6:
		return _fail("six long under drive should power all wheels, got %d" % powered)
	return true


func _test_compose_twelve_sausage() -> bool:
	var world := _boot_world()
	var intent := RoverIntent.from_phrase("колбаса на 12 колес, низкая")
	if intent.wheel_count != 12 or intent.length != "long":
		world.free()
		return _fail("phrase parse: %s" % intent.to_dict())
	var result := RoverComposer.compose(world, intent)
	if not bool(result.get("ok", false)):
		world.free()
		return _fail("twelve sausage compose: %s %s" % [
			result.get("error", ""),
			result.get("failures", []),
		])
	var assembly_id := int(result["assembly_id"])
	var pairs := WheelSimulationService.discover_pairs(world, assembly_id)
	var complete := 0
	for pair: Dictionary in pairs:
		if WheelSimulationService.is_complete_pair(pair):
			complete += 1
	if complete != 12:
		world.free()
		return _fail("expected 12 pairs, got %d" % complete)
	if intent.battery_count() < 3:
		world.free()
		return _fail("12 wheels need >=3 batteries, got %d" % intent.battery_count())
	var locomotion := world.get_locomotion_controller(assembly_id)
	locomotion.activate()
	locomotion.set_drive_command(1.0)
	IndustryElectricBudget.apply_tick(world, 1.0 / 60.0)
	var powered := 0
	for pair: Dictionary in pairs:
		var runtime := world.get_industry_element_runtime(
			int(pair.get("wheel_element_id", 0))
		)
		if runtime != null and runtime.powered:
			powered += 1
	world.free()
	if powered != 12:
		return _fail("twelve sausage should power all wheels, got %d" % powered)
	return true


func _test_compose_short_wide() -> bool:
	var world := _boot_world()
	var intent := RoverIntent.from_dict({
		"wheel_count": 4,
		"length": "short",
		"width": "wide",
		"height": "normal",
		"cockpit": "front",
		"power": "rear",
	})
	var result := RoverComposer.compose(world, intent)
	if not bool(result.get("ok", false)):
		world.free()
		return _fail("short wide compose: %s %s" % [
			result.get("error", ""),
			result.get("failures", []),
		])
	world.free()
	return true


func _test_unsupported_wheel_count() -> bool:
	var world := _boot_world()
	var intent := RoverIntent.from_dict({"wheel_count": 5})
	var result := RoverComposer.compose(world, intent)
	world.free()
	if bool(result.get("ok", false)):
		return _fail("5 wheels should be rejected")
	if str(result.get("error", "")) != "unsupported_wheel_count":
		return _fail("expected unsupported_wheel_count, got %s" % result.get("error"))
	return true


func _test_bad_com_fixture() -> bool:
	# Narrow track + batteries on long +X spur → CoM outside support bbox.
	var world := _boot_world()
	var helper := AssemblyBuildHelper.new(world, PlayerIdentity.store_id("player"))
	helper.ensure_materials(800.0)
	if not helper.spawn_anchor(Slice01Archetypes.rover_frame()):
		world.free()
		return _fail("bad com anchor")
	for cell: Vector3i in [
		Vector3i(1, 0, 0), Vector3i(2, 0, 0),
		Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(2, 0, 1),
		Vector3i(0, 0, 2), Vector3i(1, 0, 2), Vector3i(2, 0, 2),
		Vector3i(0, 0, 3), Vector3i(1, 0, 3), Vector3i(2, 0, 3),
		Vector3i(3, 0, 1), Vector3i(4, 0, 1), Vector3i(5, 0, 1),
		Vector3i(6, 0, 1), Vector3i(7, 0, 1), Vector3i(8, 0, 1),
	]:
		if not helper.place(Slice01Archetypes.rover_frame(), cell):
			world.free()
			return _fail("bad com frame %s: %s" % [cell, helper.last_error])
	for z: int in [0, 3]:
		for side: int in [-1, 1]:
			var x := -1 if side < 0 else 3
			var face := Vector3i.RIGHT if side < 0 else Vector3i.LEFT
			var ori := AssemblyBuildHelper.orientation_with_local_face(
				Vector3i.RIGHT,
				face
			)
			if not helper.place(
				Slice01Archetypes.wheel_suspension(),
				Vector3i(x, 0, z),
				ori
			):
				world.free()
				return _fail("bad com suspension: %s" % helper.last_error)
			if not helper.place(
				Slice01Archetypes.drive_wheel(),
				Vector3i(x, -1, z)
			):
				world.free()
				return _fail("bad com wheel: %s" % helper.last_error)
	if not helper.place(Slice01Archetypes.cockpit(), Vector3i(0, 1, 0), 0, "cockpit"):
		world.free()
		return _fail("bad com cockpit: %s" % helper.last_error)
	for offset_y: int in [1, 4, 7]:
		if not helper.place(
			Slice01Archetypes.power_battery_small(),
			Vector3i(7, offset_y, 1),
			0,
			"battery_%d" % offset_y
		):
			world.free()
			return _fail("bad com battery y=%d: %s" % [offset_y, helper.last_error])
	if not helper.place(
		Slice01Archetypes.power_distributor_small(),
		Vector3i(0, 1, 2),
		0,
		"distributor"
	):
		world.free()
		return _fail("bad com distributor: %s" % helper.last_error)
	helper.weld_all()
	var intent := RoverIntent.defaults()
	var validate := RoverValidator.validate(world, helper.assembly_id, intent)
	var com: Vector3 = validate.get("com_local", Vector3.ZERO)
	world.free()
	if bool(validate.get("ok", false)):
		return _fail(
			"cantilever batteries should fail validate, com=%s" % com
		)
	var failures: Array = validate.get("failures", [])
	var joined := " ".join(failures)
	if (
		joined.find("com_outside_wheelbase") < 0
		and joined.find("tipping_risk") < 0
	):
		return _fail("expected com/tipping fail, got %s com=%s" % [failures, com])
	return true
