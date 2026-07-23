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
		_test_compose_authored_pair,
		_test_unsupported_wheel_count,
		_test_bad_com_fixture,
		_test_load_margin_long_vs_short,
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


## Испечённая визардом пара собирается тем же композером, что и стоковая.
## Её геометрия другая — гнездо колеса смотрит вбок, а не вниз, и футпринт
## колеса смещён от начала детали, — поэтому зашитые клетки тут не работают.
## Пары в authored нет (у другого разработчика) — тест молча пропускается.
func _test_compose_authored_pair() -> bool:
	var pair := Slice01Archetypes.authored_wheel_pair()
	if pair.is_empty():
		print("ROVER-COMPOSE: authored пары нет — тест пропущен")
		return true
	var world := _boot_world()
	var intent := RoverIntent.defaults()
	if not intent.use_authored_wheels():
		world.free()
		return _fail("authored pair found but intent refused it")
	var result := RoverComposer.compose(world, intent)
	if not bool(result.get("ok", false)):
		var error := str(result.get("error", ""))
		var failures: Variant = result.get("failures", [])
		world.free()
		return _fail("authored rover compose failed: %s %s" % [error, failures])
	var assembly_id := int(result.get("assembly_id", 0))
	var complete := 0
	for wheel_pair: Dictionary in WheelSimulationService.discover_pairs(
		world,
		assembly_id
	):
		if WheelSimulationService.is_complete_pair(wheel_pair):
			complete += 1
	# Tip (wheel_plug) must sit inboard of the tire hub on every board —
	# starboard hubs facing out means compose/orientation flipped the axle.
	var assembly := world.get_assembly_raw(assembly_id)
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element == null or element.get_archetype() == null:
			continue
		if not element.get_archetype().is_wheel():
			continue
		var tip := WheelBodyProjectionUtil.plug_point_assembly_local(element)
		var hub := WheelBodyProjectionUtil.axle_point_assembly_local(element)
		var outboard := Vector3(signf(tip.x), 0.0, 0.0)
		if outboard.is_zero_approx():
			continue
		var stub_out := (tip - hub).normalized().dot(outboard)
		if stub_out > 0.3:
			world.free()
			return _fail(
				"wheel %d tip faces outboard (stub·out=%.2f tip=%s hub=%s)"
				% [element_id, stub_out, tip, hub]
			)
	world.free()
	if complete != intent.wheel_count:
		return _fail(
			"authored rover has %d working wheel pairs, expected %d"
			% [complete, intent.wheel_count]
		)
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
	if not helper.spawn_anchor(Slice01Archetypes.frame()):
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
		if not helper.place(Slice01Archetypes.frame(), cell):
			world.free()
			return _fail("bad com frame %s: %s" % [cell, helper.last_error])
	var pair_intent := RoverIntent.defaults()
	for z: int in [0, 3]:
		for side: int in [-1, 1]:
			var x := -1 if side < 0 else 3
			var face := Vector3i.RIGHT if side < 0 else Vector3i.LEFT
			# Позу пары считает тот же планировщик, что и композер: у точной
			# детали гнездо смотрит вбок и зашитые клетки для неё не работают.
			var plan := RoverComposer._plan_wheel_pair(
				pair_intent.suspension_archetype(),
				pair_intent.wheel_archetype(),
				Vector3i(x, 0, z) + face,
				-face
			)
			if plan.is_empty():
				world.free()
				return _fail("bad com wheel pair pose")
			if not helper.place(
				pair_intent.suspension_archetype(),
				plan["suspension_origin"],
				int(plan["suspension_orientation"])
			):
				world.free()
				return _fail("bad com suspension: %s" % helper.last_error)
			if not helper.place(
				pair_intent.wheel_archetype(),
				plan["wheel_origin"],
				int(plan["wheel_orientation"])
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


func _compose_load_report(intent: RoverIntent) -> Dictionary:
	var world := _boot_world()
	var result := RoverComposer.compose(world, intent)
	if not bool(result.get("ok", false)):
		world.free()
		return {"ok": false, "error": result.get("error", "")}
	var report := RoverLoadReport.analyze(
		world,
		int(result["assembly_id"]),
		intent
	)
	world.free()
	return report


func _test_load_margin_long_vs_short() -> bool:
	var short_report := _compose_load_report(RoverIntent.defaults())
	if not bool(short_report.get("ok", false)):
		return _fail("short load report: %s" % short_report.get("error", ""))
	var long_report := _compose_load_report(
		RoverIntent.from_phrase(
			"колбаса низкая на 6 колёсах, кокпит в центре, питание сбоку"
		)
	)
	if not bool(long_report.get("ok", false)):
		return _fail("long load report: %s" % long_report.get("error", ""))
	var long_accel: Dictionary = long_report.get("accel_05g", {})
	var long_brake: Dictionary = long_report.get("brake_05g", {})
	if bool(long_accel.get("wheelie_risk", false)):
		return _fail("long center rover wheelies at 0.5g accel oracle")
	if bool(long_brake.get("nose_dive_risk", false)):
		return _fail("long center rover nose-dives at 0.5g brake oracle")
	var short_accel: Dictionary = short_report.get("accel_05g", {})
	var short_brake: Dictionary = short_report.get("brake_05g", {})
	var long_front_brake := float(long_brake.get("front_load_n", 0.0))
	var short_front_brake := float(short_brake.get("front_load_n", 0.0))
	if long_front_brake <= short_front_brake:
		return _fail(
			"long center should carry more front load under 0.5g brake (%.0f vs %.0f N)"
			% [long_front_brake, short_front_brake]
		)
	var long_front_accel := float(long_accel.get("front_load_n", 0.0))
	var short_front_accel := float(short_accel.get("front_load_n", 0.0))
	if long_front_accel <= short_front_accel:
		return _fail(
			"long center should retain more front load under 0.5g accel (%.0f vs %.0f N)"
			% [long_front_accel, short_front_accel]
		)
	return true
