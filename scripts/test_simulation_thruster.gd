extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Kernel tests for POC-THRUSTERS-V0 (no gameplay flight feel).


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "POC-THRUSTERS-V0")
	var tests: Array[Callable] = [
		_test_archetypes_validate,
		_test_flight_assembly_detection,
		_test_thrust_and_gyro_math,
		_test_power_demand_scales_with_throttle,
		_test_locomotion_flight_snapshot_roundtrip,
		_test_hopper_demo_spawn,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	if not await _test_hopper_thruster_powered():
		return
	if not await _test_hopper_no_power_when_battery_empty():
		return
	if not await _test_hopper_lifts_off():
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
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 500.0)
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
	var helper := AssemblyBuildHelper.new(world, PlayerIdentity.store_id("player"))
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
	var helper := AssemblyBuildHelper.new(world, PlayerIdentity.store_id("player"))
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


func _test_locomotion_flight_snapshot_roundtrip() -> bool:
	var locomotion := AssemblyLocomotionController.new()
	locomotion.set_translate_command(Vector3(0.5, 1.0, -0.25))
	locomotion.set_attitude_commands(0.1, -0.2, 0.3)
	locomotion.set_dampeners(false)
	var row := locomotion.to_dict()
	if row.get("translate_command") is Vector3:
		return _fail("translate_command must serialize JSON-safe, not Vector3")
	# Saves go through JSON (WorldPersistence); the row must survive it.
	var parsed: Variant = JSON.parse_string(JSON.stringify(row))
	if not parsed is Dictionary:
		return _fail("locomotion row is not JSON-serializable")
	var restored := AssemblyLocomotionController.new()
	restored.apply_dict(parsed)
	if not restored.translate_command.is_equal_approx(Vector3(0.5, 1.0, -0.25)):
		return _fail(
			"translate_command lost in JSON roundtrip: %s"
			% restored.translate_command
		)
	if restored.is_dampeners():
		return _fail("dampeners=false lost in JSON roundtrip")
	if not is_equal_approx(restored.pitch_command, 0.1):
		return _fail("pitch_command lost in JSON roundtrip")
	var legacy := AssemblyLocomotionController.new()
	legacy.apply_dict({"thrust_command": 0.7})
	if not is_equal_approx(legacy.translate_command.y, 0.7):
		return _fail(
			"legacy thrust_command must map to translate.y, got %s"
			% legacy.translate_command
		)
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


func _boot_session() -> SimulationSession:
	var session_scene: PackedScene = load("res://scenes/simulation_session.tscn")
	var session := session_scene.instantiate() as SimulationSession
	add_child(session)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_flight_archetypes():
		session.world.get_archetype_registry().register(archetype)
	return session


func _spawn_hopper(session: SimulationSession) -> Dictionary:
	return HopperDemoSpawn.spawn_at_transform(
		session,
		Transform3D(Basis.IDENTITY, Vector3(0.0, 12.0, 0.0))
	)


func _test_hopper_thruster_powered() -> bool:
	var session := _boot_session()
	var result := _spawn_hopper(session)
	if not bool(result.get("ok", false)):
		session.queue_free()
		return _fail("hopper spawn failed: %s" % result.get("error", "?"))
	var assembly_id := int(result.get("assembly_id", 0))
	var locomotion := session.world.get_locomotion_controller(assembly_id)
	locomotion.activate()
	locomotion.set_translate_command(Vector3(0.0, 1.0, 0.0))
	ThrusterSimulationService.sync_power_demand(session.world)
	IndustryElectricBudget.apply_tick(session.world, 0.1)
	var thruster_id := int(result.get("element_ids", {}).get("thruster", 0))
	var thruster := session.world.get_element(thruster_id)
	if not ThrusterSimulationService.is_element_powered(session.world, thruster):
		session.queue_free()
		return _fail("hopper thruster must be powered with battery linked")
	session.queue_free()
	return true


func _test_hopper_no_power_when_battery_empty() -> bool:
	var session := _boot_session()
	var result := _spawn_hopper(session)
	if not bool(result.get("ok", false)):
		session.queue_free()
		return _fail("hopper spawn failed: %s" % result.get("error", "?"))
	var battery_id := int(result.get("element_ids", {}).get("battery", 0))
	session.world.ensure_industry_element_runtime(battery_id).battery_kwh = 0.0
	var assembly_id := int(result.get("assembly_id", 0))
	var locomotion := session.world.get_locomotion_controller(assembly_id)
	locomotion.activate()
	locomotion.set_translate_command(Vector3(0.0, 1.0, 0.0))
	ThrusterSimulationService.sync_power_demand(session.world)
	IndustryElectricBudget.apply_tick(session.world, 0.1)
	var thruster_id := int(result.get("element_ids", {}).get("thruster", 0))
	var thruster := session.world.get_element(thruster_id)
	if ThrusterSimulationService.is_element_powered(session.world, thruster):
		session.queue_free()
		return _fail("empty battery must leave thruster unpowered")
	var thrust := ThrusterProjectionUtil.compute_thrust_n(
		Slice01Archetypes.thruster().thruster_definition,
		1.0,
		false
	)
	if thrust != 0.0:
		session.queue_free()
		return _fail("unpowered thruster must produce 0 N")
	session.queue_free()
	return true


func _test_hopper_lifts_off() -> bool:
	var session := _boot_session()
	var result := _spawn_hopper(session)
	if not bool(result.get("ok", false)):
		session.queue_free()
		return _fail("hopper spawn failed: %s" % result.get("error", "?"))
	var assembly_id := int(result.get("assembly_id", 0))
	var locomotion := session.world.get_locomotion_controller(assembly_id)
	locomotion.set_parking_brake(false)
	locomotion.set_translate_command(Vector3(0.0, 1.0, 0.0))
	HopperDemoSpawn.wake_flight_body(session, assembly_id)
	var body := session.projection.get_physics_body(assembly_id) as RigidBody3D
	if body == null:
		session.queue_free()
		return _fail("hopper physics body missing")
	var thrusters := ThrusterSimulationService.list_thruster_elements(
		session.world,
		assembly_id
	)
	if thrusters.is_empty():
		session.queue_free()
		return _fail("hopper has no thruster elements")
	var thruster: SimulationElement = thrusters[0]
	var start := body.global_position
	for _step: int in range(180):
		IndustryElectricBudget.apply_tick(session.world, 1.0 / 60.0)
		if not ThrusterSimulationService.is_element_powered(
			session.world,
			thruster
		):
			session.queue_free()
			return _fail("thruster lost power during lift")
		await get_tree().physics_frame
	var lift_m := body.global_position.y - start.y
	if lift_m < 2.0:
		session.queue_free()
		return _fail("hopper lifted only %.2f m in 3 s" % lift_m)
	locomotion.set_attitude_commands(0.35, 0.0, 0.0)
	var hop_start := body.global_position
	for _step: int in range(360):
		IndustryElectricBudget.apply_tick(session.world, 1.0 / 60.0)
		await get_tree().physics_frame
	var horizontal_m := Vector2(
		body.global_position.x - hop_start.x,
		body.global_position.z - hop_start.z
	).length()
	session.queue_free()
	if horizontal_m < 5.0:
		return _fail(
			"hopper pitched hop only %.2f m horizontally" % horizontal_m
		)
	return true
