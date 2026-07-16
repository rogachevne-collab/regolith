extends Node

const FIXTURE := preload(
	"res://resources/blueprints/baked/kernel_fixture_valid.tres"
)
const PISTON_BASE := preload(
	"res://resources/archetypes/slice01/piston_base.tres"
)
const PISTON_HEAD := preload(
	"res://resources/archetypes/slice01/piston_head.tres"
)
const ROTOR_BASE := preload(
	"res://resources/archetypes/slice01/rotor_base.tres"
)
const ROTOR_TOP := preload(
	"res://resources/archetypes/slice01/rotor_top.tres"
)


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var tests: Array[Callable] = [
		_test_piston_atomic_placement,
		_test_body_group_compiler,
		_test_reconstruct_carriage_from_extension,
		_test_piston_dual_anchor_root_group,
		_test_snapshot_v6_roundtrip,
		_test_piston_snapshot_tuning_migration,
		_test_set_actuator_target,
		_test_configure_actuator,
		_test_force_limit_caps_velocity,
		_test_overload_status,
		_test_dismantle_splits_carriage,
		_test_bridge_rejection,
		_test_rotor_atomic_placement,
		_test_rotor_body_groups_and_reconstruct,
		_test_rotor_snapshot_roundtrip,
		_test_rotor_target_and_configure,
		_test_rotor_wrap_and_overload,
		_test_rotor_dismantle_splits_top,
		_test_rotor_moving_top_construction_rejected,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("KERNEL-ACTUATOR-V1: PASS")
	get_tree().quit(0)


func _test_piston_atomic_placement() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	var archetypes := {"base": PISTON_BASE, "head": PISTON_HEAD}
	world.get_archetype_registry().register(archetypes["head"])
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	if not foundation.is_ok():
		world.free()
		return _fail("foundation spawn failed")
	var assembly_id := int(foundation.data["assembly_id"])
	var frame_place := PlaceElementCommand.new()
	frame_place.assembly_id = assembly_id
	frame_place.expected_assembly_revision = int(foundation.data["topology_revision"])
	frame_place.archetype = Slice01Archetypes.frame()
	frame_place.origin_cell = Vector3i(4, 0, 0)
	frame_place.orientation_index = 0
	frame_place.store_id = "player"
	var frame_result := world.apply_structural_command_now(frame_place)
	if not frame_result.is_ok():
		world.free()
		return _fail(
			"frame attach failed: %s %s"
			% [frame_result.reason, frame_result.data]
		)

	var piston_place := PlaceElementCommand.new()
	piston_place.assembly_id = assembly_id
	piston_place.expected_assembly_revision = int(
		frame_result.data["topology_revision"]
	)
	piston_place.archetype = archetypes["base"]
	piston_place.origin_cell = Vector3i(5, 0, 0)
	piston_place.orientation_index = 0
	piston_place.store_id = "player"
	var piston_result := world.apply_structural_command_now(piston_place)
	if not piston_result.is_ok():
		world.free()
		return _fail("piston placement failed: %s" % piston_result.reason)

	var base_id := int(piston_result.data["element_id"])
	var head_id := int(piston_result.data["head_element_id"])
	var piston_joint_id := int(piston_result.data["piston_joint_id"])
	if world.get_element(base_id) == null or world.get_element(head_id) == null:
		world.free()
		return _fail("piston elements missing")
	var piston_joint := world.get_joint(piston_joint_id)
	if (
		piston_joint == null
		or piston_joint.kind != SimulationJoint.Kind.PISTON
		or piston_joint.motor == null
	):
		world.free()
		return _fail("piston joint missing motor state")
	if world.get_resource_store("player").amount("construction_component") >= 100.0:
		world.free()
		return _fail("piston placement did not spend materials")
	world.free()
	return true


func _test_body_group_compiler() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	var archetypes := {"base": PISTON_BASE, "head": PISTON_HEAD}
	world.get_archetype_registry().register(archetypes["head"])
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return _fail("frame setup failed")
	var piston := _place_piston(world, assembly_id, Vector3i(5, 0, 0), frame)
	if not piston.is_ok():
		world.free()
		return _fail("piston setup failed")

	var platform := PlaceElementCommand.new()
	platform.assembly_id = assembly_id
	platform.expected_assembly_revision = int(piston.data["topology_revision"])
	platform.archetype = Slice01Archetypes.frame()
	platform.origin_cell = Vector3i(6, 1, 0)
	platform.orientation_index = 0
	platform.store_id = "player"
	var platform_result := world.apply_structural_command_now(platform)
	if not platform_result.is_ok():
		world.free()
		return _fail(
			"platform attach to piston head failed: %s %s"
			% [platform_result.reason, platform_result.data]
		)

	var assembly := world.get_assembly_raw(assembly_id)
	var elements_by_id: Dictionary = {}
	for element: SimulationElement in world.list_elements():
		elements_by_id[element.element_id] = element
	var compiled := BodyGroupCompiler.compile(
		assembly.element_ids,
		elements_by_id,
		world.list_joints()
	)
	if not bool(compiled.get("valid", false)):
		world.free()
		return _fail("body group compile failed")
	var groups: Dictionary = compiled["groups"]
	if groups.size() != 2:
		world.free()
		return _fail("expected two body groups, got %d" % groups.size())
	var head_group := int(
		(compiled["element_to_group"] as Dictionary).get(
			int(piston.data["head_element_id"]),
			0
		)
	)
	var platform_group := int(
		(compiled["element_to_group"] as Dictionary).get(
			int(platform_result.data["element_id"]),
			0
		)
	)
	if head_group <= 0 or head_group != platform_group:
		world.free()
		return _fail("head branch did not share carriage body group")
	world.free()
	return true


func _test_reconstruct_carriage_from_extension() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	world.get_archetype_registry().register(PISTON_HEAD)
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return _fail("reconstruct frame setup failed")
	var piston := _place_piston(world, assembly_id, Vector3i(5, 0, 0), frame)
	if not piston.is_ok():
		world.free()
		return _fail("reconstruct piston setup failed")
	var joint_id := int(piston.data.get("piston_joint_id", 0))
	var head_id := int(piston.data["head_element_id"])
	var joint := world.get_joint(joint_id)
	if joint == null or joint.motor == null:
		world.free()
		return _fail("missing piston joint")
	var head_group := world.body_group_id_for_element(head_id)
	var root_group := world.root_body_group_id(assembly_id)
	if head_group <= 0 or head_group == root_group:
		world.free()
		return _fail("expected distinct carriage group")
	var root_motion := AssemblyMotionState.new()
	root_motion.transform = Transform3D(Basis.IDENTITY, Vector3(10.0, 2.0, 3.0))
	if not world.sync_assembly_motion(assembly_id, root_motion):
		world.free()
		return _fail("root motion sync failed")
	joint.motor.observed_position_m = joint.motor.lower_limit_m
	joint.motor.observed_position_m = joint.motor.clamp_observed_position()
	var retracted := world.get_body_group_motion(assembly_id, head_group)
	var target_extension := minf(
		joint.motor.lower_limit_m + 0.5,
		joint.motor.upper_limit_m
	)
	joint.motor.observed_position_m = target_extension
	joint.motor.observed_position_m = joint.motor.clamp_observed_position()
	var extended := world.get_body_group_motion(assembly_id, head_group)
	var travel := (
		extended.transform.origin - retracted.transform.origin
	).length()
	var expected_travel := absf(
		joint.motor.observed_position_m - joint.motor.lower_limit_m
	)
	if absf(travel - expected_travel) > 0.05:
		world.free()
		return _fail(
			"carriage reconstruct travel %.3f expected ~%.3f"
			% [travel, expected_travel]
		)
	var element_tf := world.element_world_transform(head_id)
	var group_tf := extended.transform
	var head_element := world.get_element(head_id)
	var local := GridPoseUtil.element_local_transform(
		head_element.origin_cell,
		head_element.orientation_index
	)
	if not element_tf.is_equal_approx(group_tf * local):
		world.free()
		return _fail("element_world_transform mismatch")
	world.free()
	return true


func _test_piston_dual_anchor_root_group() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	world.get_archetype_registry().register(PISTON_HEAD)
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return _fail("dual anchor frame setup failed")
	var piston := _place_piston(world, assembly_id, Vector3i(5, 0, 0), frame)
	if not piston.is_ok():
		world.free()
		return _fail("dual anchor piston setup failed")
	var head_id := int(piston.data["head_element_id"])
	var base_id := int(piston.data["element_id"])

	var assembly := world.get_assembly_raw(assembly_id)
	var elements_by_id: Dictionary = {}
	for element: SimulationElement in world.list_elements():
		if element.assembly_id == assembly_id:
			elements_by_id[element.element_id] = element
	var assembly_joints: Array[SimulationJoint] = []
	for joint: SimulationJoint in world.list_joints():
		if joint.assembly_id == assembly_id:
			assembly_joints.append(joint)
	assembly_joints.append(
		SimulationJoint.anchor(
			99991,
			assembly_id,
			base_id,
			"structural_0_0_0_ny"
		)
	)
	assembly_joints.append(
		SimulationJoint.anchor(
			99992,
			assembly_id,
			head_id,
			"structural_1_0_1_px"
		)
	)
	var compiled := BodyGroupCompiler.compile(
		assembly.element_ids,
		elements_by_id,
		assembly_joints
	)
	if not bool(compiled.get("valid", false)):
		world.free()
		return _fail(
			"dual anchor compile failed: %s" % str(compiled.get("reason", ""))
		)
	var root_group := int(compiled.get("root_group_id", 0))
	var base_group := int(
		(compiled["element_to_group"] as Dictionary).get(
			base_id,
			0
		)
	)
	if root_group != base_group:
		world.free()
		return _fail("expected piston base group to be motion root")
	world.free()
	return true


func _test_snapshot_v6_roundtrip() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	var archetypes := {"base": PISTON_BASE, "head": PISTON_HEAD}
	world.get_archetype_registry().register(archetypes["head"])
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return _fail("frame setup failed")
	var piston := _place_piston(world, assembly_id, Vector3i(5, 0, 0), frame)
	if not piston.is_ok():
		world.free()
		return _fail("piston setup failed for snapshot")

	var base_id := int(piston.data["element_id"])
	var head_id := int(piston.data["head_element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, head_id)

	var command := SetActuatorTargetCommand.new()
	command.joint_id = int(piston.data["piston_joint_id"])
	command.mode = SimulationMotorState.ControlMode.POSITION
	command.target_position_m = 1.0
	var apply_result := world.apply_set_actuator_target(command)
	if StringName(apply_result.get("status", &"")) != &"ok":
		world.free()
		return _fail("set_actuator_target failed before snapshot")
	world.sync_actuator_observation(
		command.joint_id,
		0.5,
		0.1,
		1200.0,
		false
	)

	var snapshot := world.capture_snapshot()
	if int(snapshot.get("version", 0)) != SimulationSnapshot.VERSION:
		world.free()
		return _fail("snapshot version mismatch")
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(
		snapshot
	)
	if restored == null:
		world.free()
		return _fail(
			"snapshot restore failed: %s"
			% SimulationSnapshot.last_validate_error
		)
	var joint := restored.get_joint(int(piston.data["piston_joint_id"]))
	if (
		joint == null
		or joint.motor == null
		or not is_equal_approx(joint.motor.observed_position_m, 0.5)
		or joint.motor.control_mode != SimulationMotorState.ControlMode.POSITION
	):
		restored.free()
		world.free()
		return _fail("piston motor state did not roundtrip")
	if not SimulationSnapshot.semantic_equals(
		snapshot,
		restored.capture_snapshot()
	):
		restored.free()
		world.free()
		return _fail("piston snapshot semantics changed on roundtrip")
	restored.free()
	world.free()
	return true


func _test_piston_snapshot_tuning_migration() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	world.get_archetype_registry().register(PISTON_HEAD)
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return _fail("frame setup failed for tuning migration")
	var piston := _place_piston(world, assembly_id, Vector3i(5, 0, 0), frame)
	if not piston.is_ok():
		world.free()
		return _fail("piston setup failed for tuning migration")

	var snapshot := world.capture_snapshot()
	var legacy_fingerprint := ArchetypeRegistry.legacy_fingerprint_of(PISTON_BASE)
	for row_variant: Variant in snapshot.get("archetypes", []):
		if not row_variant is Dictionary:
			continue
		var row: Dictionary = row_variant
		if str(row.get("archetype_id", "")) != "piston_base":
			continue
		row["fingerprint"] = legacy_fingerprint

	var definition := PISTON_BASE.piston_definition
	var original_speed := definition.default_speed_limit_mps
	definition.default_speed_limit_mps = 0.77
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(snapshot)
	definition.default_speed_limit_mps = original_speed
	if restored == null:
		world.free()
		return _fail(
			"tuning migration restore failed: %s"
			% SimulationSnapshot.last_validate_error
		)
	restored.free()
	world.free()
	return true


func _test_set_actuator_target() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	var archetypes := {"base": PISTON_BASE, "head": PISTON_HEAD}
	world.get_archetype_registry().register(archetypes["head"])
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return _fail("frame setup failed")
	var piston := _place_piston(world, assembly_id, Vector3i(5, 0, 0), frame)
	var base_id := int(piston.data["element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, int(piston.data["head_element_id"]))
	var piston_joint := world.get_joint(int(piston.data["piston_joint_id"]))
	if ActuatorSimulationService.power_demand_w(piston_joint) != 0.0:
		world.free()
		return _fail("stopped piston should not draw actuator power")

	var command := SetActuatorTargetCommand.new()
	command.joint_id = int(piston.data["piston_joint_id"])
	command.mode = SimulationMotorState.ControlMode.POSITION
	command.target_position_m = 1.5
	var result := world.apply_set_actuator_target(command)
	if StringName(result.get("status", &"")) != &"ok":
		world.free()
		return _fail("set_actuator_target failed")
	var joint := world.get_joint(command.joint_id)
	if (
		joint.motor.control_mode != SimulationMotorState.ControlMode.POSITION
		or not is_equal_approx(joint.motor.target_position_m, 1.5)
	):
		world.free()
		return _fail("actuator target not applied")
	if not is_equal_approx(
		ActuatorSimulationService.power_demand_w(joint),
		joint.motor.power_draw_w
	):
		world.free()
		return _fail("commanded piston power demand was not published")
	world.free()
	return true


func _test_configure_actuator() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	var archetypes := {"base": PISTON_BASE, "head": PISTON_HEAD}
	world.get_archetype_registry().register(archetypes["head"])
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return _fail("frame setup failed")
	var piston := _place_piston(world, assembly_id, Vector3i(5, 0, 0), frame)
	var base_id := int(piston.data["element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, int(piston.data["head_element_id"]))

	var joint_id := int(piston.data["piston_joint_id"])
	var configure := ConfigureActuatorCommand.new()
	configure.joint_id = joint_id
	configure.extend_velocity_mps = 1.0
	configure.retract_velocity_mps = 0.5
	configure.force_limit_n = 45000.0
	configure.lower_limit_m = 0.2
	configure.upper_limit_m = 1.4
	var result := world.apply_configure_actuator(configure)
	if StringName(result.get("status", &"")) != &"ok":
		world.free()
		return _fail("configure_actuator failed")
	var joint := world.get_joint(joint_id)
	if (
		not is_equal_approx(joint.motor.extend_velocity_mps, 1.0)
		or not is_equal_approx(joint.motor.retract_velocity_mps, 0.5)
		or not is_equal_approx(joint.motor.force_limit_n, 45000.0)
		or not is_equal_approx(joint.motor.lower_limit_m, 0.2)
		or not is_equal_approx(joint.motor.upper_limit_m, 1.4)
	):
		world.free()
		return _fail("configure_actuator values not applied")

	var invalid := ConfigureActuatorCommand.new()
	invalid.joint_id = joint_id
	invalid.lower_limit_m = 1.5
	invalid.upper_limit_m = 1.2
	var invalid_result := world.apply_configure_actuator(invalid)
	if StringName(invalid_result.get("status", &"")) == &"ok":
		world.free()
		return _fail("expected configure_actuator to reject inverted limits")
	world.free()
	return true


func _test_force_limit_caps_velocity() -> bool:
	var motor := SimulationMotorState.from_piston_definition(
		PISTON_BASE.piston_definition
	)
	motor.control_mode = SimulationMotorState.ControlMode.VELOCITY
	motor.target_velocity_mps = 0.15
	motor.force_limit_n = 1000.0
	var gravity := Vector3(0.0, -1.62, 0.0)
	var low := PistonProjectionUtil.effective_desired_axial_velocity_mps(
		motor,
		200.0,
		Vector3.UP,
		gravity
	)
	motor.force_limit_n = 42000.0
	var high := PistonProjectionUtil.effective_desired_axial_velocity_mps(
		motor,
		200.0,
		Vector3.UP,
		gravity
	)
	if low >= high - 0.001:
		return _fail(
			"force limit did not reduce desired velocity: low=%.4f high=%.4f"
			% [low, high]
		)
	if low <= 0.0:
		return _fail("low force limit should still allow some motion")
	return true


func _test_overload_status() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	var archetypes := {"base": PISTON_BASE, "head": PISTON_HEAD}
	world.get_archetype_registry().register(archetypes["head"])
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return _fail("frame setup failed")
	var piston := _place_piston(world, assembly_id, Vector3i(5, 0, 0), frame)
	var base_id := int(piston.data["element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, int(piston.data["head_element_id"]))

	var command := SetActuatorTargetCommand.new()
	command.joint_id = int(piston.data["piston_joint_id"])
	command.mode = SimulationMotorState.ControlMode.POSITION
	command.target_position_m = 1.0
	var apply_result := world.apply_set_actuator_target(command)
	if StringName(apply_result.get("status", &"")) != &"ok":
		world.free()
		return _fail("set_actuator_target failed before overload test")
	var joint := world.get_joint(command.joint_id)
	world.sync_actuator_observation(
		command.joint_id,
		0.0,
		0.0,
		joint.motor.force_limit_n,
		true
	)
	for _i: int in range(30):
		world.tick_actuators(0.05)
	if joint.motor.status != SimulationMotorState.Status.OVERLOADED:
		world.free()
		return _fail("expected overloaded status")
	world.free()
	return true


func _test_dismantle_splits_carriage() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	var archetypes := {"base": PISTON_BASE, "head": PISTON_HEAD}
	world.get_archetype_registry().register(archetypes["head"])
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return _fail("frame setup failed")
	var piston := _place_piston(world, assembly_id, Vector3i(5, 0, 0), frame)
	_place_frame_on_head(world, assembly_id, piston)

	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = int(piston.data["element_id"])
	dismantle.expected_assembly_revision = world.get_assembly_raw(
		assembly_id
	).topology_revision
	dismantle.store_id = "player"
	var result := world.apply_structural_command_now(dismantle)
	if not result.is_ok() or not bool(result.data.get("split", false)):
		world.free()
		return _fail("dismantle piston base did not split assembly")
	world.free()
	return true


func _test_bridge_rejection() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	var archetypes := {"base": PISTON_BASE, "head": PISTON_HEAD}
	world.get_archetype_registry().register(archetypes["head"])
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return _fail("frame setup failed")
	var piston := _place_piston(world, assembly_id, Vector3i(5, 0, 0), frame)
	_place_frame_on_head(world, assembly_id, piston)

	var bridge := PlaceElementCommand.new()
	bridge.assembly_id = assembly_id
	bridge.expected_assembly_revision = world.get_assembly_raw(
		assembly_id
	).topology_revision
	bridge.archetype = Slice01Archetypes.frame()
	bridge.origin_cell = Vector3i(6, 0, 0)
	bridge.orientation_index = 0
	bridge.store_id = "player"
	var bridge_result := world.apply_structural_command_now(bridge)
	if bridge_result.reason != StructuralCommandResult.REASON_DRIVEN_JOINT_CYCLE:
		world.free()
		return _fail("bridge across piston groups was not rejected")
	world.free()
	return true


func _test_rotor_atomic_placement() -> bool:
	var world := _rotor_world_with_foundation()
	var setup := _rotor_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("rotor setup failed")
	var rotor: StructuralCommandResult = setup["rotor"]
	var base_id := int(rotor.data["element_id"])
	var top_id := int(rotor.data["head_element_id"])
	var joint_id := int(rotor.data["rotor_joint_id"])
	if int(rotor.data["driven_joint_id"]) != joint_id:
		world.free()
		return _fail("driven_joint_id mismatch")
	if world.get_element(base_id) == null or world.get_element(top_id) == null:
		world.free()
		return _fail("rotor elements missing")
	var joint := world.get_joint(joint_id)
	if (
		joint == null
		or joint.kind != SimulationJoint.Kind.ROTOR
		or joint.motor == null
		or not joint.motor.angular
		or not joint.motor.continuous
	):
		world.free()
		return _fail("rotor joint missing angular motor state")
	if world.get_resource_store("player").amount("construction_component") >= 100.0:
		world.free()
		return _fail("rotor placement did not spend materials")
	world.free()
	return true


func _test_rotor_body_groups_and_reconstruct() -> bool:
	var world := _rotor_world_with_foundation()
	var setup := _rotor_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("rotor setup failed")
	var rotor: StructuralCommandResult = setup["rotor"]
	var assembly_id := int(setup["assembly_id"])
	var top_id := int(rotor.data["head_element_id"])

	var platform := PlaceElementCommand.new()
	platform.assembly_id = assembly_id
	platform.expected_assembly_revision = int(rotor.data["topology_revision"])
	platform.archetype = Slice01Archetypes.frame()
	platform.origin_cell = Vector3i(6, 1, 0)
	platform.orientation_index = 0
	platform.store_id = "player"
	var platform_result := world.apply_structural_command_now(platform)
	if not platform_result.is_ok():
		world.free()
		return _fail(
			"platform attach to rotor top failed: %s %s"
			% [platform_result.reason, platform_result.data]
		)
	var platform_id := int(platform_result.data["element_id"])
	var top_group := world.body_group_id_for_element(top_id)
	var platform_group := world.body_group_id_for_element(platform_id)
	var root_group := world.root_body_group_id(assembly_id)
	if top_group <= 0 or top_group != platform_group or top_group == root_group:
		world.free()
		return _fail("rotor top branch did not form its own body group")

	var joint := world.get_joint(int(rotor.data["rotor_joint_id"]))
	var cell_center_local := Vector3(0.25, 0.25, 0.25)
	var home_top_tf := world.element_world_transform(top_id)
	var home_platform_tf := world.element_world_transform(platform_id)
	var home_top_center := home_top_tf * cell_center_local
	var home_platform_center := home_platform_tf * cell_center_local
	joint.motor.observed_position_m = PI / 2.0
	var turned_top_tf := world.element_world_transform(top_id)
	var turned_platform_tf := world.element_world_transform(platform_id)
	var turned_top_center := turned_top_tf * cell_center_local
	var turned_platform_center := turned_platform_tf * cell_center_local
	if not turned_top_center.is_equal_approx(home_top_center):
		world.free()
		return _fail("rotor top center on the axis must not translate")
	var rotation_delta := (
		turned_top_tf.basis * home_top_tf.basis.inverse()
	).get_rotation_quaternion().get_angle()
	if absf(rotation_delta - PI / 2.0) > 0.01:
		world.free()
		return _fail(
			"rotor top rotation %.3f expected ~%.3f" % [rotation_delta, PI / 2.0]
		)
	var pivot := home_top_center
	var home_radius := Vector2(
		home_platform_center.x - pivot.x,
		home_platform_center.z - pivot.z
	).length()
	var turned_radius := Vector2(
		turned_platform_center.x - pivot.x,
		turned_platform_center.z - pivot.z
	).length()
	if absf(home_radius - turned_radius) > 0.01:
		world.free()
		return _fail("platform did not stay on the rotor radius")
	if home_platform_center.is_equal_approx(turned_platform_center):
		world.free()
		return _fail("platform did not move around the rotor axis")
	world.free()
	return true


func _test_rotor_snapshot_roundtrip() -> bool:
	var world := _rotor_world_with_foundation()
	var setup := _rotor_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("rotor setup failed")
	var rotor: StructuralCommandResult = setup["rotor"]
	var joint_id := int(rotor.data["rotor_joint_id"])
	var base_id := int(rotor.data["element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, int(rotor.data["head_element_id"]))

	var command := SetActuatorTargetCommand.new()
	command.joint_id = joint_id
	command.mode = SimulationMotorState.ControlMode.VELOCITY
	command.target_velocity_mps = 0.8
	if StringName(world.apply_set_actuator_target(command).get("status", &"")) != &"ok":
		world.free()
		return _fail("rotor set_actuator_target failed before snapshot")
	world.sync_actuator_observation(joint_id, 2.0, 0.4, 900.0, false)

	var snapshot := world.capture_snapshot()
	if int(snapshot.get("version", 0)) != SimulationSnapshot.VERSION:
		world.free()
		return _fail("snapshot version mismatch")
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(
		snapshot
	)
	if restored == null:
		world.free()
		return _fail(
			"rotor snapshot restore failed: %s"
			% SimulationSnapshot.last_validate_error
		)
	var joint := restored.get_joint(joint_id)
	if (
		joint == null
		or joint.kind != SimulationJoint.Kind.ROTOR
		or joint.motor == null
		or not joint.motor.continuous
		or not is_equal_approx(joint.motor.observed_position_m, 2.0)
		or not is_equal_approx(joint.motor.target_velocity_mps, 0.8)
		or joint.motor.control_mode != SimulationMotorState.ControlMode.VELOCITY
	):
		restored.free()
		world.free()
		return _fail("rotor motor state did not roundtrip")
	if not SimulationSnapshot.semantic_equals(
		snapshot,
		restored.capture_snapshot()
	):
		restored.free()
		world.free()
		return _fail("rotor snapshot semantics changed on roundtrip")
	restored.free()
	world.free()
	return true


func _test_rotor_target_and_configure() -> bool:
	var world := _rotor_world_with_foundation()
	var setup := _rotor_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("rotor setup failed")
	var rotor: StructuralCommandResult = setup["rotor"]
	var joint_id := int(rotor.data["rotor_joint_id"])
	var base_id := int(rotor.data["element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, int(rotor.data["head_element_id"]))
	var joint := world.get_joint(joint_id)
	if ActuatorSimulationService.power_demand_w(joint) != 0.0:
		world.free()
		return _fail("stopped rotor should not draw actuator power")

	var command := SetActuatorTargetCommand.new()
	command.joint_id = joint_id
	command.mode = SimulationMotorState.ControlMode.VELOCITY
	command.target_velocity_mps = 5.0
	if StringName(world.apply_set_actuator_target(command).get("status", &"")) != &"ok":
		world.free()
		return _fail("rotor set_actuator_target failed")
	if not is_equal_approx(
		joint.motor.clamp_target_velocity(),
		joint.motor.extend_velocity_mps
	):
		world.free()
		return _fail("rotor velocity target was not clamped to forward limit")
	if not is_equal_approx(
		ActuatorSimulationService.power_demand_w(joint),
		joint.motor.power_draw_w
	):
		world.free()
		return _fail("commanded rotor power demand was not published")

	var configure := ConfigureActuatorCommand.new()
	configure.joint_id = joint_id
	configure.extend_velocity_mps = 2.0
	configure.retract_velocity_mps = 0.25
	configure.force_limit_n = 5000.0
	configure.lower_limit_m = 0.5
	configure.upper_limit_m = 1.5
	if StringName(world.apply_configure_actuator(configure).get("status", &"")) != &"ok":
		world.free()
		return _fail("rotor configure_actuator failed")
	if (
		not is_equal_approx(joint.motor.extend_velocity_mps, 2.0)
		or not is_equal_approx(joint.motor.retract_velocity_mps, 0.25)
		or not is_equal_approx(joint.motor.force_limit_n, 5000.0)
	):
		world.free()
		return _fail("rotor configure values not applied")
	if (
		not is_equal_approx(joint.motor.lower_limit_m, 0.0)
		or not is_equal_approx(joint.motor.upper_limit_m, 0.0)
	):
		world.free()
		return _fail("continuous rotor must ignore travel limit fields")
	world.free()
	return true


func _test_rotor_wrap_and_overload() -> bool:
	var world := _rotor_world_with_foundation()
	var setup := _rotor_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("rotor setup failed")
	var rotor: StructuralCommandResult = setup["rotor"]
	var joint_id := int(rotor.data["rotor_joint_id"])
	var base_id := int(rotor.data["element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, int(rotor.data["head_element_id"]))
	var joint := world.get_joint(joint_id)

	world.sync_actuator_observation(joint_id, 3.5, 0.0, 0.0, false)
	if absf(joint.motor.observed_position_m - (3.5 - TAU)) > 0.0001:
		world.free()
		return _fail(
			"observed rotor angle was not wrapped: %.4f"
			% joint.motor.observed_position_m
		)
	joint.motor.status_reference_position_m = 3.1
	joint.motor.observed_position_m = -3.1
	var progress := joint.motor.position_progress_from(3.1)
	if progress > 0.1:
		world.free()
		return _fail("wrapped progress across PI is wrong: %.4f" % progress)

	var command := SetActuatorTargetCommand.new()
	command.joint_id = joint_id
	command.mode = SimulationMotorState.ControlMode.VELOCITY
	command.target_velocity_mps = 1.0
	if StringName(world.apply_set_actuator_target(command).get("status", &"")) != &"ok":
		world.free()
		return _fail("rotor set_actuator_target failed before overload")
	world.sync_actuator_observation(
		joint_id,
		joint.motor.observed_position_m,
		0.0,
		joint.motor.force_limit_n,
		true
	)
	for _i: int in range(30):
		world.tick_actuators(0.05)
	if joint.motor.status != SimulationMotorState.Status.OVERLOADED:
		world.free()
		return _fail("expected overloaded rotor status")

	runtime.powered = false
	world.tick_actuators(0.05)
	if joint.motor.status != SimulationMotorState.Status.NO_POWER:
		world.free()
		return _fail("expected no_power rotor status")
	world.free()
	return true


func _test_rotor_dismantle_splits_top() -> bool:
	var world := _rotor_world_with_foundation()
	var setup := _rotor_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("rotor setup failed")
	var rotor: StructuralCommandResult = setup["rotor"]
	var assembly_id := int(setup["assembly_id"])

	var platform := PlaceElementCommand.new()
	platform.assembly_id = assembly_id
	platform.expected_assembly_revision = int(rotor.data["topology_revision"])
	platform.archetype = Slice01Archetypes.frame()
	platform.origin_cell = Vector3i(6, 1, 0)
	platform.orientation_index = 0
	platform.store_id = "player"
	if not world.apply_structural_command_now(platform).is_ok():
		world.free()
		return _fail("platform attach failed before dismantle")

	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = int(rotor.data["element_id"])
	dismantle.expected_assembly_revision = world.get_assembly_raw(
		assembly_id
	).topology_revision
	dismantle.store_id = "player"
	var result := world.apply_structural_command_now(dismantle)
	if not result.is_ok() or not bool(result.data.get("split", false)):
		world.free()
		return _fail("dismantle rotor base did not split assembly")
	world.free()
	return true


func _test_rotor_moving_top_construction_rejected() -> bool:
	var world := _rotor_world_with_foundation()
	var setup := _rotor_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("rotor setup failed")
	var rotor: StructuralCommandResult = setup["rotor"]
	var assembly_id := int(setup["assembly_id"])
	var joint := world.get_joint(int(rotor.data["rotor_joint_id"]))
	joint.motor.observed_position_m = 0.5

	var platform := PlaceElementCommand.new()
	platform.assembly_id = assembly_id
	platform.expected_assembly_revision = world.get_assembly_raw(
		assembly_id
	).topology_revision
	platform.archetype = Slice01Archetypes.frame()
	platform.origin_cell = Vector3i(6, 1, 0)
	platform.orientation_index = 0
	platform.store_id = "player"
	var result := world.apply_structural_command_now(platform)
	if result.reason != StructuralCommandResult.REASON_MOVING_TARGET_NOT_SUPPORTED:
		world.free()
		return _fail("construction on turned rotor top was not rejected")
	world.free()
	return true


func _rotor_world_with_foundation() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	world.get_archetype_registry().register(ROTOR_TOP)
	return world


func _rotor_setup(world: SimulationWorld) -> Dictionary:
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	if not foundation.is_ok():
		return {}
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		return {}
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(frame.data["topology_revision"])
	place.archetype = ROTOR_BASE
	place.origin_cell = Vector3i(5, 0, 0)
	place.orientation_index = 0
	place.store_id = "player"
	var rotor := world.apply_structural_command_now(place)
	if not rotor.is_ok():
		return {}
	return {
		"assembly_id": assembly_id,
		"rotor": rotor,
	}


func _place_frame(
	world: SimulationWorld,
	assembly_id: int,
	origin_cell: Vector3i,
	prior: StructuralCommandResult
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(prior.data["topology_revision"])
	place.archetype = Slice01Archetypes.frame()
	place.origin_cell = origin_cell
	place.orientation_index = 0
	place.store_id = "player"
	return world.apply_structural_command_now(place)


func _place_piston(
	world: SimulationWorld,
	assembly_id: int,
	origin_cell: Vector3i,
	prior: StructuralCommandResult
) -> StructuralCommandResult:
	var archetypes := {"base": PISTON_BASE, "head": PISTON_HEAD}
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(prior.data["topology_revision"])
	place.archetype = archetypes["base"]
	place.origin_cell = origin_cell
	place.orientation_index = 0
	place.store_id = "player"
	return world.apply_structural_command_now(place)


func _place_frame_on_head(
	world: SimulationWorld,
	assembly_id: int,
	piston: StructuralCommandResult
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(piston.data["topology_revision"])
	place.archetype = Slice01Archetypes.frame()
	place.origin_cell = Vector3i(6, 1, 0)
	place.orientation_index = 0
	place.store_id = "player"
	return world.apply_structural_command_now(place)


func _weld_element(world: SimulationWorld, element_id: int) -> void:
	var element := world.get_element(element_id)
	var weld := WeldElementCommand.new()
	weld.element_id = element_id
	weld.expected_state_revision = element.state_revision
	weld.max_material_amount = 100.0
	weld.store_id = "player"
	world.apply_structural_command_now(weld)


func _spawn(
	world: SimulationWorld,
	blueprint: Blueprint,
	grid_frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = grid_frame
	return world.apply_structural_command_now(command)


func _single_blueprint(archetype: ElementArchetype) -> Blueprint:
	var blueprint := Blueprint.new()
	blueprint.blueprint_id = "test_single"
	var placement := BlueprintElementPlacement.new()
	placement.local_id = "element_0"
	placement.archetype = archetype
	placement.origin_cell = Vector3i.ZERO
	placement.orientation_index = 0
	blueprint.placements = [placement]
	return blueprint


func _fail(message: String) -> bool:
	push_error(message)
	print("KERNEL-ACTUATOR-V1: FAIL - %s" % message)
	get_tree().quit(1)
	return false
