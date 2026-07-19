extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless gate for MachineComposer / MachineIntent / MachineValidator.


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "MACHINE-COMPOSE")
	var tests: Array[Callable] = [
		_test_phrase_defaults,
		_test_phrase_long_wrist,
		_test_compose_default_drill_arm,
		_test_compose_long_reach,
		_test_compose_wrist,
		_test_compose_with_feed,
		_test_unsupported_recipe,
		_test_validator_missing_drill,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("MACHINE-COMPOSE: PASS")
	get_tree().quit(0)


func _boot_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 2000.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 2000.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 2000.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 2000.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 2000.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 2000.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 2000.0)
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_actuator_archetypes():
		world.get_archetype_registry().register(archetype)
	return world


func _fail(message: String) -> bool:
	push_error("MACHINE-COMPOSE FAIL: %s" % message)
	print("MACHINE-COMPOSE: FAIL — %s" % message)
	get_tree().quit(1)
	return false


func _test_phrase_defaults() -> bool:
	var intent := MachineIntent.from_phrase("собери буровой манипулятор")
	if intent.recipe != "drill_arm" or intent.reach != "short" or intent.wrist:
		return _fail("defaults broken: %s" % intent.to_dict())
	return true


func _test_phrase_long_wrist() -> bool:
	var intent := MachineIntent.from_phrase("длинная буровая стрела с запястьем")
	if intent.recipe != "drill_arm":
		return _fail("expected drill_arm, got %s" % intent.recipe)
	if intent.reach != "long":
		return _fail("expected long, got %s" % intent.reach)
	if not intent.wrist:
		return _fail("expected wrist")
	return true


func _test_compose_default_drill_arm() -> bool:
	var world := _boot_world()
	var result := MachineComposer.compose(world, MachineIntent.defaults())
	if not bool(result.get("ok", false)):
		world.free()
		return _fail("default compose: %s %s" % [
			result.get("error", ""),
			result.get("failures", []),
		])
	var validate: Dictionary = result.get("validate", {})
	if int(validate.get("driven_count", 0)) != 2:
		world.free()
		return _fail("default expected 2 driven, got %s" % validate)
	if int(result.get("element_ids", {}).get("drill", 0)) <= 0:
		world.free()
		return _fail("default missing drill element_id")
	world.free()
	return true


func _test_compose_long_reach() -> bool:
	var world := _boot_world()
	var intent := MachineIntent.from_phrase("длинный буровой манипулятор")
	var result := MachineComposer.compose(world, intent)
	if not bool(result.get("ok", false)):
		world.free()
		return _fail("long compose: %s %s" % [
			result.get("error", ""),
			result.get("failures", []),
		])
	var boom_keys := 0
	for key: Variant in result.get("element_ids", {}).keys():
		if str(key).begins_with("boom_"):
			boom_keys += 1
	if boom_keys != 2:
		world.free()
		return _fail("long reach expected 2 boom frames, got %d" % boom_keys)
	if int(result.get("validate", {}).get("driven_count", 0)) != 2:
		world.free()
		return _fail("long reach should stay at 2 driven")
	world.free()
	return true


func _test_compose_wrist() -> bool:
	var world := _boot_world()
	var intent := MachineIntent.from_dict({
		"recipe": "drill_arm",
		"reach": "short",
		"wrist": true,
	})
	var result := MachineComposer.compose(world, intent)
	if not bool(result.get("ok", false)):
		world.free()
		return _fail("wrist compose: %s %s" % [
			result.get("error", ""),
			result.get("failures", []),
		])
	var validate: Dictionary = result.get("validate", {})
	if int(validate.get("hinge_count", 0)) != 2:
		world.free()
		return _fail("wrist expected 2 hinges, got %s" % validate)
	if int(validate.get("driven_count", 0)) != 3:
		world.free()
		return _fail("wrist expected 3 driven, got %s" % validate)
	world.free()
	return true


func _test_compose_with_feed() -> bool:
	var world := _boot_world()
	var intent := MachineIntent.from_phrase("буровой манипулятор с подачей")
	if not intent.feed:
		world.free()
		return _fail("feed phrase should set feed=true")
	var result := MachineComposer.compose(world, intent)
	if not bool(result.get("ok", false)):
		world.free()
		return _fail("feed compose: %s %s" % [
			result.get("error", ""),
			result.get("failures", []),
		])
	if int(result.get("validate", {}).get("driven_count", 0)) != 3:
		world.free()
		return _fail("feed expected 3 driven")
	if int(result.get("element_ids", {}).get("piston", 0)) <= 0:
		world.free()
		return _fail("feed missing piston element_id")
	world.free()
	return true


func _test_unsupported_recipe() -> bool:
	var intent := MachineIntent.from_phrase("карусельный кран")
	if intent.unsupported_reason() != "unsupported_recipe":
		return _fail(
			"expected unsupported_recipe, got '%s' / %s"
			% [intent.unsupported_reason(), intent.to_dict()]
		)
	var world := _boot_world()
	var result := MachineComposer.compose(world, intent)
	world.free()
	if bool(result.get("ok", false)) or str(result.get("error", "")) != "unsupported_recipe":
		return _fail("compose should reject unsupported recipe: %s" % result)
	return true


func _test_validator_missing_drill() -> bool:
	var world := _boot_world()
	var helper := AssemblyBuildHelper.new(world, PlayerIdentity.store_id("player"))
	helper.ensure_materials(500.0)
	if not helper.spawn_anchor(Slice01Archetypes.foundation()):
		world.free()
		return _fail("fixture anchor failed: %s" % helper.last_error)
	if not helper.place(
		Slice01Archetypes.power_source(),
		Vector3i(4, 0, 0),
		0,
		"power"
	):
		world.free()
		return _fail("fixture power failed: %s" % helper.last_error)
	helper.weld_all()
	var validate := MachineValidator.validate(
		world,
		helper.assembly_id,
		MachineIntent.defaults()
	)
	world.free()
	if bool(validate.get("ok", false)):
		return _fail("validator should fail without drill/actuators")
	var failures: Array = validate.get("failures", [])
	if not failures.has("missing_drill"):
		return _fail("expected missing_drill in %s" % failures)
	return true
