extends Node

## Kernel tests for POC-THRUSTERS-V0 (no gameplay flight feel).


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var tests: Array[Callable] = [
		_test_archetypes_validate,
		_test_flight_assembly_detection,
		_test_thrust_and_gyro_math,
		_test_power_demand_scales_with_throttle,
		_test_hopper_demo_spawn,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("POC-THRUSTERS-V0: PASS")
	get_tree().quit(0)


func _fail(message: String) -> bool:
	push_error(message)
	print("POC-THRUSTERS-V0: FAIL — %s" % message)
	get_tree().quit(1)
	return false


func _boot_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 500.0)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_flight_archetypes():
		world.get_archetype_registry().register(archetype)
	return world


func _test_archetypes_validate() -> bool:
	var thruster := Slice01Archetypes.thruster()
	var gyro := Slice01Archetypes.gyro()
	var leg := Slice01Archetypes.landing_leg()
	if thruster == null or gyro == null or leg == null:
		return _fail("flight archetypes failed to load")
	var thruster_result := BlueprintValidator.validate_archetype(thruster)
	if not thruster_result.ok:
		return _fail("thruster archetype invalid: %s" % str(thruster_result.errors))
	var gyro_result := BlueprintValidator.validate_archetype(gyro)
	if not gyro_result.ok:
		return _fail("gyro archetype invalid: %s" % str(gyro_result.errors))
	var leg_result := BlueprintValidator.validate_archetype(leg)
	if not leg_result.ok:
		return _fail("landing_leg archetype invalid: %s" % str(leg_result.errors))
	if thruster.thruster_definition == null or thruster.thruster_definition.max_thrust_n <= 0.0:
		return _fail("thruster_definition missing")
	if gyro.gyro_definition == null or gyro.gyro_definition.max_torque_nm <= 0.0:
		return _fail("gyro_definition missing")
	if leg.max_integrity < 200.0:
		return _fail("landing_leg should be high-integrity")
	if not ImpactResolver.is_landing_gear_archetype("landing_leg"):
		return _fail("landing_leg not recognized as landing gear")
	var soft := ImpactResolver.damage_amount(24.0, 400.0, 0.08 / 0.35)
	var hard := ImpactResolver.damage_amount(24.0, 400.0, 1.0)
	if soft >= hard * 0.5:
		return _fail("landing gear terrain scale should soften damage")
	return true


func _test_flight_assembly_detection() -> bool:
	var world := _boot_world()
	var helper := AssemblyBuildHelper.new(world, "player")
	helper.ensure_materials(200.0)
	if not helper.spawn_anchor(Slice01Archetypes.rover_frame()):
		return _fail("spawn frame: %s" % helper.last_error)
	if ThrusterSimulationService.is_flight_assembly(world, helper.assembly_id):
		return _fail("frame-only must not be flight")
	if not helper.place(Slice01Archetypes.thruster(), Vector3i(0, -1, 0), 0, "thruster"):
		return _fail("place thruster: %s" % helper.last_error)
	helper.weld_all()
	if not ThrusterSimulationService.is_flight_assembly(world, helper.assembly_id):
		return _fail("assembly with thruster must be flight")
	if not ThrusterSimulationService.is_mobile_assembly(world, helper.assembly_id):
		return _fail("flight assembly must be mobile")
	return true


func _test_thrust_and_gyro_math() -> bool:
	var thruster_def := Slice01Archetypes.thruster().thruster_definition
	var gyro_def := Slice01Archetypes.gyro().gyro_definition
	var thrust := ThrusterProjectionUtil.compute_thrust_n(thruster_def, 0.5, true)
	if not is_equal_approx(thrust, thruster_def.max_thrust_n * 0.5):
		return _fail("thrust scale wrong: %s" % thrust)
	if ThrusterProjectionUtil.compute_thrust_n(thruster_def, 1.0, false) != 0.0:
		return _fail("unpowered thrust must be 0")
	var up_throttle := ThrusterProjectionUtil.compute_thruster_throttle(
		Vector3.UP,
		Vector3(0.0, 1.0, 0.0),
		true,
		Vector3.ZERO,
		true
	)
	if not is_equal_approx(up_throttle, 1.0):
		return _fail("aligned translate throttle must be 1, got %s" % up_throttle)
	var side_throttle := ThrusterProjectionUtil.compute_thruster_throttle(
		Vector3.UP,
		Vector3(1.0, 0.0, 0.0),
		true,
		Vector3.ZERO,
		true
	)
	if side_throttle > 0.001:
		return _fail("perpendicular thruster must stay off")
	var damp_throttle := ThrusterProjectionUtil.compute_thruster_throttle(
		Vector3.UP,
		Vector3.ZERO,
		true,
		Vector3(0.0, -2.0, 0.0),
		true
	)
	if damp_throttle <= 0.5:
		return _fail("linear dampen should fire opposing fall, got %s" % damp_throttle)
	var torque := ThrusterProjectionUtil.compute_gyro_torque_local(
		gyro_def,
		1.0,
		0.0,
		0.0,
		true,
		Vector3.ZERO,
		2,
		true
	)
	if not is_equal_approx(torque.x, gyro_def.max_torque_nm * 0.5):
		return _fail("gyro attitude share wrong: %s" % torque)
	var damp := ThrusterProjectionUtil.compute_gyro_torque_local(
		gyro_def,
		0.0,
		0.0,
		0.0,
		true,
		Vector3(2.0, 0.0, 0.0),
		1,
		true
	)
	if damp.x >= 0.0:
		return _fail("dampeners must counter positive omega")
	var no_power := ThrusterProjectionUtil.compute_gyro_torque_local(
		gyro_def,
		1.0,
		0.0,
		0.0,
		true,
		Vector3.ZERO,
		1,
		false
	)
	if no_power != Vector3.ZERO:
		return _fail("unpowered gyro torque must be 0")
	return true


func _test_power_demand_scales_with_throttle() -> bool:
	var world := _boot_world()
	var helper := AssemblyBuildHelper.new(world, "player")
	helper.ensure_materials(300.0)
	if not helper.spawn_anchor(Slice01Archetypes.rover_frame()):
		return _fail("spawn: %s" % helper.last_error)
	if not helper.place(Slice01Archetypes.thruster(), Vector3i(0, -1, 0), 0, "thruster"):
		return _fail("thruster: %s" % helper.last_error)
	if not helper.place(Slice01Archetypes.gyro(), Vector3i(1, 0, 0), 0, "gyro"):
		return _fail("gyro: %s" % helper.last_error)
	helper.weld_all()
	var locomotion := world.get_locomotion_controller(helper.assembly_id)
	locomotion.activate()
	locomotion.set_translate_command(Vector3.ZERO)
	ThrusterSimulationService.sync_power_demand(world)
	var thruster_id := int(helper.element_ids["thruster"])
	var idle_dyn := world.ensure_industry_element_runtime(thruster_id).dynamic_power_w
	if idle_dyn > 0.001:
		return _fail("zero translate must demand 0 dynamic W, got %s" % idle_dyn)
	locomotion.set_translate_command(Vector3(0.0, 1.0, 0.0))
	ThrusterSimulationService.sync_power_demand(world)
	var full := world.ensure_industry_element_runtime(thruster_id).dynamic_power_w
	var expected := Slice01Archetypes.thruster().thruster_definition.power_draw_w
	if not is_equal_approx(full, expected):
		return _fail("full translate demand %s != %s" % [full, expected])
	return true


func _test_hopper_demo_spawn() -> bool:
	var session_scene: PackedScene = load("res://scenes/simulation_session.tscn")
	var session := session_scene.instantiate() as SimulationSession
	add_child(session)
	var result := HopperDemoSpawn.spawn_at_transform(
		session,
		Transform3D(Basis.IDENTITY, Vector3(0, 4, 0))
	)
	if not bool(result.get("ok", false)):
		return _fail("hopper spawn failed: %s" % result.get("error", "?"))
	var assembly_id := int(result.get("assembly_id", 0))
	if not ThrusterSimulationService.is_flight_assembly(session.world, assembly_id):
		return _fail("hopper is not flight assembly")
	var ids: Dictionary = result.get("element_ids", {})
	if int(ids.get("thruster", 0)) <= 0 or int(ids.get("gyro", 0)) <= 0:
		return _fail("hopper missing thruster/gyro ids")
	if int(ids.get("cockpit", 0)) <= 0:
		return _fail("hopper missing cockpit")
	for leg_index: int in range(4):
		if int(ids.get("leg_%d" % leg_index, 0)) <= 0:
			return _fail("hopper missing landing leg %d" % leg_index)
	session.queue_free()
	return true
