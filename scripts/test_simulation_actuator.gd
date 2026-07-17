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
const ROTOR_BASE_LARGE := preload(
	"res://resources/archetypes/slice01/rotor_base_large.tres"
)
const ROTOR_TOP_LARGE := preload(
	"res://resources/archetypes/slice01/rotor_top_large.tres"
)
const HINGE_BASE := preload(
	"res://resources/archetypes/slice01/hinge_base.tres"
)
const HINGE_TOP := preload(
	"res://resources/archetypes/slice01/hinge_top.tres"
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
		_test_rotor_large_atomic_placement,
		_test_rotor_body_groups_and_reconstruct,
		_test_rotor_snapshot_roundtrip,
		_test_rotor_target_and_configure,
		_test_rotor_wrap_and_overload,
		_test_rotor_dismantle_splits_top,
		_test_rotor_moving_top_construction_rejected,
		_test_hinge_atomic_placement,
		_test_hinge_body_groups_and_reconstruct,
		_test_hinge_snapshot_roundtrip,
		_test_hinge_target_and_configure,
		_test_hinge_joint_limit_status,
		_test_hinge_overload_and_no_power,
		_test_hinge_dismantle_splits_top,
		_test_hinge_moving_top_construction_rejected,
		_test_hinge_jolt_limit_offset_math,
		_test_hinge_near_limit_torque_taper,
		_test_nested_rotor_hinge_reconstruct_order,
		_test_piston_axis_follows_bent_hinge_basis,
		_test_construction_rejected_on_bent_hinge_branch,
		_test_driven_chain_length_limit,
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


func _test_rotor_large_atomic_placement() -> bool:
	var world := _rotor_large_world_with_top()
	var setup := _rotor_large_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("large rotor setup failed")
	var rotor: StructuralCommandResult = setup["rotor"]
	var base_id := int(rotor.data["element_id"])
	var top_id := int(rotor.data["head_element_id"])
	var joint_id := int(rotor.data["rotor_joint_id"])
	if int(rotor.data["driven_joint_id"]) != joint_id:
		world.free()
		return _fail("large rotor driven_joint_id mismatch")
	if world.get_element(base_id) == null or world.get_element(top_id) == null:
		world.free()
		return _fail("large rotor elements missing")
	var joint := world.get_joint(joint_id)
	if (
		joint == null
		or joint.kind != SimulationJoint.Kind.ROTOR
		or joint.motor == null
		or not joint.motor.angular
		or not joint.motor.continuous
	):
		world.free()
		return _fail("large rotor joint missing angular motor state")
	var validation := RotorPlacementUtil.validate_rotor_archetype(
		ROTOR_BASE_LARGE,
		ROTOR_TOP_LARGE,
		world.get_archetype_registry()
	)
	if not validation.is_empty():
		world.free()
		return _fail(
			"large rotor archetype validation failed: %s"
			% ", ".join(validation)
		)
	if joint.motor.extend_velocity_mps != 5.0:
		world.free()
		return _fail("large rotor forward velocity not scaled")
	if joint.motor.force_limit_n != 15000.0:
		world.free()
		return _fail("large rotor torque limit not scaled")
	world.free()
	return true


func _rotor_large_world_with_top() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 200.0)
	world.get_archetype_registry().register(ROTOR_TOP_LARGE)
	return world


func _rotor_large_setup(world: SimulationWorld) -> Dictionary:
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	if not foundation.is_ok():
		return {}
	var assembly_id := int(foundation.data["assembly_id"])
	var platform := PlaceElementCommand.new()
	platform.assembly_id = assembly_id
	platform.expected_assembly_revision = int(foundation.data["topology_revision"])
	platform.archetype = Slice01Archetypes.large_frame()
	platform.origin_cell = Vector3i(0, 1, 0)
	platform.orientation_index = 0
	platform.store_id = "player"
	var platform_result := world.apply_structural_command_now(platform)
	if not platform_result.is_ok():
		push_error(
			"large rotor platform placement failed: %s %s"
			% [platform_result.reason, platform_result.data]
		)
		return {}
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(platform_result.data["topology_revision"])
	place.archetype = ROTOR_BASE_LARGE
	place.origin_cell = Vector3i(0, 6, 0)
	place.orientation_index = 0
	place.store_id = "player"
	var rotor := world.apply_structural_command_now(place)
	if not rotor.is_ok():
		push_error(
			"large rotor placement failed: %s %s"
			% [rotor.reason, rotor.data]
		)
		return {}
	return {
		"assembly_id": assembly_id,
		"rotor": rotor,
	}


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


func _test_hinge_atomic_placement() -> bool:
	var world := _hinge_world_with_foundation()
	var setup := _hinge_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("hinge setup failed")
	var hinge: StructuralCommandResult = setup["hinge"]
	var base_id := int(hinge.data["element_id"])
	var top_id := int(hinge.data["head_element_id"])
	var joint_id := int(hinge.data["hinge_joint_id"])
	if int(hinge.data["driven_joint_id"]) != joint_id:
		world.free()
		return _fail("hinge driven_joint_id mismatch")
	if world.get_element(base_id) == null or world.get_element(top_id) == null:
		world.free()
		return _fail("hinge elements missing")
	var joint := world.get_joint(joint_id)
	if (
		joint == null
		or joint.kind != SimulationJoint.Kind.HINGE
		or joint.motor == null
		or not joint.motor.angular
		or joint.motor.continuous
	):
		world.free()
		return _fail("hinge joint missing bounded angular motor state")
	if (
		not is_equal_approx(joint.motor.lower_limit_m, -PI / 2.0)
		or not is_equal_approx(joint.motor.upper_limit_m, PI / 2.0)
	):
		world.free()
		return _fail("hinge joint did not inherit authored angle bounds")
	if world.get_resource_store("player").amount("construction_component") >= 100.0:
		world.free()
		return _fail("hinge placement did not spend materials")
	world.free()
	return true


func _test_hinge_body_groups_and_reconstruct() -> bool:
	var world := _hinge_world_with_foundation()
	var setup := _hinge_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("hinge setup failed")
	var hinge: StructuralCommandResult = setup["hinge"]
	var assembly_id := int(setup["assembly_id"])
	var top_id := int(hinge.data["head_element_id"])

	# Attach the swing arm on the top's +Y face: the bend axis is +X, so a
	# +Y branch sweeps in the Y-Z plane around the top cell center.
	var platform := PlaceElementCommand.new()
	platform.assembly_id = assembly_id
	platform.expected_assembly_revision = int(hinge.data["topology_revision"])
	platform.archetype = Slice01Archetypes.frame()
	platform.origin_cell = Vector3i(5, 2, 0)
	platform.orientation_index = 0
	platform.store_id = "player"
	var platform_result := world.apply_structural_command_now(platform)
	if not platform_result.is_ok():
		world.free()
		return _fail(
			"platform attach to hinge top failed: %s %s"
			% [platform_result.reason, platform_result.data]
		)
	var platform_id := int(platform_result.data["element_id"])
	var top_group := world.body_group_id_for_element(top_id)
	var platform_group := world.body_group_id_for_element(platform_id)
	var root_group := world.root_body_group_id(assembly_id)
	if top_group <= 0 or top_group != platform_group or top_group == root_group:
		world.free()
		return _fail("hinge top branch did not form its own body group")

	var joint := world.get_joint(int(hinge.data["hinge_joint_id"]))
	var cell_center_local := Vector3(0.25, 0.25, 0.25)
	var home_top_tf := world.element_world_transform(top_id)
	var home_platform_tf := world.element_world_transform(platform_id)
	var home_top_center := home_top_tf * cell_center_local
	var home_platform_center := home_platform_tf * cell_center_local
	joint.motor.observed_position_m = PI / 2.0
	var bent_top_tf := world.element_world_transform(top_id)
	var bent_platform_tf := world.element_world_transform(platform_id)
	var bent_top_center := bent_top_tf * cell_center_local
	var bent_platform_center := bent_platform_tf * cell_center_local
	if not bent_top_center.is_equal_approx(home_top_center):
		world.free()
		return _fail("hinge top center is the pivot and must not translate")
	var rotation_delta := (
		bent_top_tf.basis * home_top_tf.basis.inverse()
	).get_rotation_quaternion().get_angle()
	if absf(rotation_delta - PI / 2.0) > 0.01:
		world.free()
		return _fail(
			"hinge top rotation %.3f expected ~%.3f" % [rotation_delta, PI / 2.0]
		)
	var pivot := home_top_center
	var home_radius := Vector2(
		home_platform_center.y - pivot.y,
		home_platform_center.z - pivot.z
	).length()
	var bent_radius := Vector2(
		bent_platform_center.y - pivot.y,
		bent_platform_center.z - pivot.z
	).length()
	if absf(home_radius - bent_radius) > 0.01:
		world.free()
		return _fail("platform did not stay on the hinge swing radius")
	if not is_equal_approx(bent_platform_center.x, home_platform_center.x):
		world.free()
		return _fail("platform must not translate along the bend axis")
	if home_platform_center.is_equal_approx(bent_platform_center):
		world.free()
		return _fail("platform did not swing around the bend axis")
	world.free()
	return true


func _test_hinge_snapshot_roundtrip() -> bool:
	var world := _hinge_world_with_foundation()
	var setup := _hinge_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("hinge setup failed")
	var hinge: StructuralCommandResult = setup["hinge"]
	var joint_id := int(hinge.data["hinge_joint_id"])
	var base_id := int(hinge.data["element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, int(hinge.data["head_element_id"]))

	var configure := ConfigureActuatorCommand.new()
	configure.joint_id = joint_id
	configure.lower_limit_m = -PI / 4.0
	configure.lower_limit_set = true
	if StringName(world.apply_configure_actuator(configure).get("status", &"")) != &"ok":
		world.free()
		return _fail("hinge configure failed before snapshot")
	var command := SetActuatorTargetCommand.new()
	command.joint_id = joint_id
	command.mode = SimulationMotorState.ControlMode.VELOCITY
	command.target_velocity_mps = 0.8
	if StringName(world.apply_set_actuator_target(command).get("status", &"")) != &"ok":
		world.free()
		return _fail("hinge set_actuator_target failed before snapshot")
	world.sync_actuator_observation(joint_id, 0.6, 0.4, 900.0, false)

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
			"hinge snapshot restore failed: %s"
			% SimulationSnapshot.last_validate_error
		)
	var joint := restored.get_joint(joint_id)
	if (
		joint == null
		or joint.kind != SimulationJoint.Kind.HINGE
		or joint.motor == null
		or joint.motor.continuous
		or not is_equal_approx(joint.motor.observed_position_m, 0.6)
		or not is_equal_approx(joint.motor.target_velocity_mps, 0.8)
		or not is_equal_approx(joint.motor.lower_limit_m, -PI / 4.0)
		or not is_equal_approx(joint.motor.upper_limit_m, PI / 2.0)
		or joint.motor.control_mode != SimulationMotorState.ControlMode.VELOCITY
	):
		restored.free()
		world.free()
		return _fail("hinge motor state did not roundtrip")
	if not SimulationSnapshot.semantic_equals(
		snapshot,
		restored.capture_snapshot()
	):
		restored.free()
		world.free()
		return _fail("hinge snapshot semantics changed on roundtrip")
	restored.free()
	world.free()
	return true


func _test_hinge_target_and_configure() -> bool:
	var world := _hinge_world_with_foundation()
	var setup := _hinge_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("hinge setup failed")
	var hinge: StructuralCommandResult = setup["hinge"]
	var joint_id := int(hinge.data["hinge_joint_id"])
	var base_id := int(hinge.data["element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, int(hinge.data["head_element_id"]))
	var joint := world.get_joint(joint_id)
	if ActuatorSimulationService.power_demand_w(joint) != 0.0:
		world.free()
		return _fail("stopped hinge should not draw actuator power")

	var command := SetActuatorTargetCommand.new()
	command.joint_id = joint_id
	command.mode = SimulationMotorState.ControlMode.VELOCITY
	command.target_velocity_mps = 5.0
	if StringName(world.apply_set_actuator_target(command).get("status", &"")) != &"ok":
		world.free()
		return _fail("hinge set_actuator_target failed")
	if not is_equal_approx(
		joint.motor.clamp_target_velocity(),
		joint.motor.extend_velocity_mps
	):
		world.free()
		return _fail("hinge velocity target was not clamped to forward limit")
	if not is_equal_approx(
		ActuatorSimulationService.power_demand_w(joint),
		joint.motor.power_draw_w
	):
		world.free()
		return _fail("commanded hinge power demand was not published")

	var position := SetActuatorTargetCommand.new()
	position.joint_id = joint_id
	position.mode = SimulationMotorState.ControlMode.POSITION
	position.target_position_m = PI
	if StringName(world.apply_set_actuator_target(position).get("status", &"")) != &"ok":
		world.free()
		return _fail("hinge position target failed")
	if not is_equal_approx(
		joint.motor.clamp_target_position(),
		joint.motor.upper_limit_m
	):
		world.free()
		return _fail("hinge position target was not clamped into angle limits")

	var configure := ConfigureActuatorCommand.new()
	configure.joint_id = joint_id
	configure.extend_velocity_mps = 5.0
	configure.retract_velocity_mps = 0.25
	configure.force_limit_n = 5000.0
	configure.lower_limit_m = -PI / 4.0
	configure.lower_limit_set = true
	configure.upper_limit_m = PI / 4.0
	configure.upper_limit_set = true
	if StringName(world.apply_configure_actuator(configure).get("status", &"")) != &"ok":
		world.free()
		return _fail("hinge configure_actuator failed")
	if (
		not is_equal_approx(joint.motor.extend_velocity_mps, 2.0)
		or not is_equal_approx(joint.motor.retract_velocity_mps, 0.25)
		or not is_equal_approx(joint.motor.force_limit_n, 5000.0)
	):
		world.free()
		return _fail("hinge configure velocity/torque clamps not applied")
	if (
		not is_equal_approx(joint.motor.lower_limit_m, -PI / 4.0)
		or not is_equal_approx(joint.motor.upper_limit_m, PI / 4.0)
	):
		world.free()
		return _fail("hinge negative lower limit did not apply via set flag")
	if not is_equal_approx(
		joint.motor.clamp_target_position(),
		PI / 4.0
	):
		world.free()
		return _fail("hinge target was not re-clamped after limit change")

	var untouched := ConfigureActuatorCommand.new()
	untouched.joint_id = joint_id
	untouched.force_limit_n = 4000.0
	if StringName(world.apply_configure_actuator(untouched).get("status", &"")) != &"ok":
		world.free()
		return _fail("hinge torque-only configure failed")
	if (
		not is_equal_approx(joint.motor.lower_limit_m, -PI / 4.0)
		or not is_equal_approx(joint.motor.upper_limit_m, PI / 4.0)
	):
		world.free()
		return _fail("hinge limits changed without set flags")

	var invalid := ConfigureActuatorCommand.new()
	invalid.joint_id = joint_id
	invalid.lower_limit_m = PI / 3.0
	invalid.lower_limit_set = true
	invalid.upper_limit_m = -PI / 3.0
	invalid.upper_limit_set = true
	if StringName(world.apply_configure_actuator(invalid).get("status", &"")) == &"ok":
		world.free()
		return _fail("inverted hinge limits were not rejected")
	world.free()
	return true


func _test_hinge_joint_limit_status() -> bool:
	var world := _hinge_world_with_foundation()
	var setup := _hinge_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("hinge setup failed")
	var hinge: StructuralCommandResult = setup["hinge"]
	var joint_id := int(hinge.data["hinge_joint_id"])
	var base_id := int(hinge.data["element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, int(hinge.data["head_element_id"]))
	var joint := world.get_joint(joint_id)

	var command := SetActuatorTargetCommand.new()
	command.joint_id = joint_id
	command.mode = SimulationMotorState.ControlMode.VELOCITY
	command.target_velocity_mps = 1.0
	if StringName(world.apply_set_actuator_target(command).get("status", &"")) != &"ok":
		world.free()
		return _fail("hinge set_actuator_target failed before limit test")
	world.sync_actuator_observation(
		joint_id,
		joint.motor.upper_limit_m,
		0.0,
		joint.motor.force_limit_n,
		true
	)
	for _i: int in range(30):
		world.tick_actuators(0.05)
	if joint.motor.status != SimulationMotorState.Status.JOINT_LIMIT:
		world.free()
		return _fail(
			"expected joint_limit at the upper stop, got %s"
			% ActuatorSimulationService.status_name_for_motor(joint.motor)
		)

	# Observed angles beyond the stops must clamp into the travel range.
	world.sync_actuator_observation(joint_id, PI, 0.0, 0.0, false)
	if not is_equal_approx(
		joint.motor.observed_position_m,
		joint.motor.upper_limit_m
	):
		world.free()
		return _fail("hinge observed angle was not clamped into limits")
	world.free()
	return true


func _test_hinge_overload_and_no_power() -> bool:
	var world := _hinge_world_with_foundation()
	var setup := _hinge_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("hinge setup failed")
	var hinge: StructuralCommandResult = setup["hinge"]
	var joint_id := int(hinge.data["hinge_joint_id"])
	var base_id := int(hinge.data["element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(world, base_id)
	_weld_element(world, int(hinge.data["head_element_id"]))
	var joint := world.get_joint(joint_id)

	var command := SetActuatorTargetCommand.new()
	command.joint_id = joint_id
	command.mode = SimulationMotorState.ControlMode.VELOCITY
	command.target_velocity_mps = 1.0
	if StringName(world.apply_set_actuator_target(command).get("status", &"")) != &"ok":
		world.free()
		return _fail("hinge set_actuator_target failed before overload")
	# Saturated torque with zero progress mid-travel (away from both stops).
	world.sync_actuator_observation(
		joint_id,
		0.0,
		0.0,
		joint.motor.force_limit_n,
		true
	)
	for _i: int in range(30):
		world.tick_actuators(0.05)
	if joint.motor.status != SimulationMotorState.Status.OVERLOADED:
		world.free()
		return _fail("expected overloaded hinge status")

	runtime.powered = false
	world.tick_actuators(0.05)
	if joint.motor.status != SimulationMotorState.Status.NO_POWER:
		world.free()
		return _fail("expected no_power hinge status")
	world.free()
	return true


func _test_hinge_dismantle_splits_top() -> bool:
	var world := _hinge_world_with_foundation()
	var setup := _hinge_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("hinge setup failed")
	var hinge: StructuralCommandResult = setup["hinge"]
	var assembly_id := int(setup["assembly_id"])

	var platform := PlaceElementCommand.new()
	platform.assembly_id = assembly_id
	platform.expected_assembly_revision = int(hinge.data["topology_revision"])
	platform.archetype = Slice01Archetypes.frame()
	platform.origin_cell = Vector3i(5, 2, 0)
	platform.orientation_index = 0
	platform.store_id = "player"
	if not world.apply_structural_command_now(platform).is_ok():
		world.free()
		return _fail("platform attach failed before hinge dismantle")

	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = int(hinge.data["element_id"])
	dismantle.expected_assembly_revision = world.get_assembly_raw(
		assembly_id
	).topology_revision
	dismantle.store_id = "player"
	var result := world.apply_structural_command_now(dismantle)
	if not result.is_ok() or not bool(result.data.get("split", false)):
		world.free()
		return _fail("dismantle hinge base did not split assembly")
	world.free()
	return true


func _test_hinge_moving_top_construction_rejected() -> bool:
	var world := _hinge_world_with_foundation()
	var setup := _hinge_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("hinge setup failed")
	var hinge: StructuralCommandResult = setup["hinge"]
	var assembly_id := int(setup["assembly_id"])
	var joint := world.get_joint(int(hinge.data["hinge_joint_id"]))
	joint.motor.observed_position_m = 0.5

	var platform := PlaceElementCommand.new()
	platform.assembly_id = assembly_id
	platform.expected_assembly_revision = world.get_assembly_raw(
		assembly_id
	).topology_revision
	platform.archetype = Slice01Archetypes.frame()
	platform.origin_cell = Vector3i(5, 2, 0)
	platform.orientation_index = 0
	platform.store_id = "player"
	var result := world.apply_structural_command_now(platform)
	if result.reason != StructuralCommandResult.REASON_MOVING_TARGET_NOT_SUPPORTED:
		world.free()
		return _fail("construction on a bent hinge top was not rejected")
	world.free()
	return true


func _test_hinge_jolt_limit_offset_math() -> bool:
	var motor := SimulationMotorState.from_hinge_definition(
		HINGE_BASE.hinge_definition
	)
	var offset := 0.5
	var limits := HingeProjectionUtil.jolt_angle_limits(motor, offset)
	if not is_equal_approx(limits.x, motor.lower_limit_m - offset):
		return _fail("jolt lower limit offset mismatch")
	if not is_equal_approx(limits.y, motor.upper_limit_m - offset):
		return _fail("jolt upper limit offset mismatch")
	var at_home := HingeProjectionUtil.jolt_angle_limits(motor, 0.0)
	if not is_equal_approx(at_home.x, motor.lower_limit_m):
		return _fail("zero-offset lower limit should match motor")
	if not is_equal_approx(at_home.y, motor.upper_limit_m):
		return _fail("zero-offset upper limit should match motor")
	return true


func _test_hinge_near_limit_torque_taper() -> bool:
	var motor := SimulationMotorState.from_hinge_definition(
		HINGE_BASE.hinge_definition
	)
	motor.control_mode = SimulationMotorState.ControlMode.VELOCITY
	motor.target_velocity_mps = 1.0
	motor.observed_position_m = motor.upper_limit_m
	if RotorProjectionUtil.near_limit_torque_scale(motor) > 0.001:
		return _fail("torque scale at upper limit must be 0")
	motor.observed_position_m = motor.upper_limit_m - 0.01
	var mid_scale := RotorProjectionUtil.near_limit_torque_scale(motor)
	if mid_scale <= 0.0 or mid_scale >= 1.0:
		return _fail("torque scale inside taper band must be partial")
	motor.observed_position_m = 0.0
	if not is_equal_approx(
		RotorProjectionUtil.near_limit_torque_scale(motor),
		1.0
	):
		return _fail("mid-travel torque scale must be 1")
	var torque := RotorProjectionUtil.compute_motor_torque_scalar(
		motor,
		0.0,
		true,
		1.0
	)
	if absf(float(torque.get("torque_nm", 0.0))) <= 0.0:
		return _fail("mid-travel motor should still produce torque")
	motor.observed_position_m = motor.upper_limit_m
	var stopped := RotorProjectionUtil.compute_motor_torque_scalar(
		motor,
		0.0,
		true,
		1.0
	)
	if absf(float(stopped.get("torque_nm", 0.0))) > 0.001:
		return _fail("torque at hard stop must taper to 0")
	return true


func _test_nested_rotor_hinge_reconstruct_order() -> bool:
	var world := _nested_rotor_hinge_world()
	if world == null:
		return _fail("nested rotor+hinge setup failed")
	var assembly_id := int(world.get_meta("assembly_id"))
	var hinge_top_id := int(world.get_meta("hinge_top_id"))
	var platform_id := int(world.get_meta("platform_id"))
	var rotor_joint := world.get_joint(int(world.get_meta("rotor_joint_id")))
	var hinge_joint := world.get_joint(int(world.get_meta("hinge_joint_id")))
	rotor_joint.motor.observed_position_m = PI / 2.0
	hinge_joint.motor.observed_position_m = PI / 2.0
	var cell_center_local := Vector3(0.25, 0.25, 0.25)
	var top_tf := world.element_world_transform(hinge_top_id)
	var platform_tf := world.element_world_transform(platform_id)
	var top_center := top_tf * cell_center_local
	var platform_center := platform_tf * cell_center_local
	# Parent-before-child reconstruct: hinge top must leave the home column
	# after both rotor yaw and hinge pitch are applied.
	var home_top := Vector3(5.25, 3.25, 0.25)
	if top_center.is_equal_approx(home_top):
		world.free()
		return _fail("nested reconstruct left hinge top at home pose")
	var root := world.get_body_group_motion(
		assembly_id,
		world.root_body_group_id(assembly_id)
	)
	var hinge_top_group := world.body_group_id_for_element(hinge_top_id)
	var top_motion := world.get_body_group_motion(assembly_id, hinge_top_group)
	if top_motion.transform.basis.is_equal_approx(root.transform.basis):
		world.free()
		return _fail("hinge top basis should differ from root after nested bend")
	if platform_center.is_equal_approx(Vector3(5.25, 4.25, 0.25)):
		world.free()
		return _fail("platform on nested hinge did not leave home cell")
	world.free()
	return true


func _test_piston_axis_follows_bent_hinge_basis() -> bool:
	var world := _hinge_world_with_foundation()
	var setup := _hinge_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("hinge setup failed")
	var hinge: StructuralCommandResult = setup["hinge"]
	var assembly_id := int(setup["assembly_id"])
	var top_id := int(hinge.data["head_element_id"])
	var joint := world.get_joint(int(hinge.data["hinge_joint_id"]))
	joint.motor.observed_position_m = PI / 2.0
	var root_motion := world.get_body_group_motion(
		assembly_id,
		world.root_body_group_id(assembly_id)
	)
	var top_motion := world.get_body_group_motion(
		assembly_id,
		world.body_group_id_for_element(top_id)
	)
	var axis_local := Vector3.UP
	var root_axis := (root_motion.transform.basis * axis_local).normalized()
	var base_axis := (top_motion.transform.basis * axis_local).normalized()
	if root_axis.is_equal_approx(base_axis):
		world.free()
		return _fail(
			"bent hinge top basis must rotate piston axis away from root"
		)
	world.free()
	return true


func _test_construction_rejected_on_bent_hinge_branch() -> bool:
	var world := _hinge_world_with_foundation()
	var setup := _hinge_setup(world)
	if setup.is_empty():
		world.free()
		return _fail("hinge setup failed")
	var hinge: StructuralCommandResult = setup["hinge"]
	var assembly_id := int(setup["assembly_id"])
	var platform := PlaceElementCommand.new()
	platform.assembly_id = assembly_id
	platform.expected_assembly_revision = int(hinge.data["topology_revision"])
	platform.archetype = Slice01Archetypes.frame()
	platform.origin_cell = Vector3i(5, 2, 0)
	platform.orientation_index = 0
	platform.store_id = "player"
	var platform_result := world.apply_structural_command_now(platform)
	if not platform_result.is_ok():
		world.free()
		return _fail("platform attach before bend failed")
	var joint := world.get_joint(int(hinge.data["hinge_joint_id"]))
	joint.motor.observed_position_m = 0.5
	var tip := PlaceElementCommand.new()
	tip.assembly_id = assembly_id
	tip.expected_assembly_revision = world.get_assembly_raw(
		assembly_id
	).topology_revision
	tip.archetype = Slice01Archetypes.frame()
	tip.origin_cell = Vector3i(5, 3, 0)
	tip.orientation_index = 0
	tip.store_id = "player"
	var result := world.apply_structural_command_now(tip)
	if result.reason != StructuralCommandResult.REASON_MOVING_TARGET_NOT_SUPPORTED:
		world.free()
		return _fail(
			"construction on bent hinge branch frame was not rejected"
		)
	world.free()
	return true


func _test_driven_chain_length_limit() -> bool:
	var definition := HINGE_BASE.hinge_definition
	var frame := Slice01Archetypes.frame()
	var element_ids: Array[int] = []
	var elements_by_id: Dictionary = {}
	for index: int in range(1, 7):
		element_ids.append(index)
		elements_by_id[index] = SimulationElement.frame(
			index,
			1,
			frame,
			Vector3i(index, 0, 0),
			0,
			{}
		)
	var too_long: Array[SimulationJoint] = [
		SimulationJoint.anchor(100, 1, 1, "anchor"),
	]
	for index: int in range(1, 6):
		too_long.append(
			SimulationJoint.hinge(index, 1, index, index + 1, definition)
		)
	var rejected := BodyGroupCompiler.compile(
		element_ids,
		elements_by_id,
		too_long
	)
	if bool(rejected.get("valid", true)):
		return _fail("5 driven joints on a path should be rejected")
	if String(rejected.get("reason", "")) != "driven_joint_chain_too_long":
		return _fail(
			"expected driven_joint_chain_too_long, got %s"
			% str(rejected.get("reason", ""))
		)
	var ok_ids: Array[int] = []
	var ok_elements: Dictionary = {}
	for index: int in range(1, 6):
		ok_ids.append(index)
		ok_elements[index] = SimulationElement.frame(
			index,
			1,
			frame,
			Vector3i(index, 0, 0),
			0,
			{}
		)
	var ok_joints: Array[SimulationJoint] = [
		SimulationJoint.anchor(100, 1, 1, "anchor"),
	]
	for index: int in range(1, 5):
		ok_joints.append(
			SimulationJoint.hinge(index, 1, index, index + 1, definition)
		)
	var accepted := BodyGroupCompiler.compile(ok_ids, ok_elements, ok_joints)
	if not bool(accepted.get("valid", false)):
		return _fail(
			"4 driven joints on a path must remain valid: %s"
			% str(accepted.get("reason", ""))
		)
	return true


func _nested_rotor_hinge_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 200.0)
	world.get_archetype_registry().register(ROTOR_TOP)
	world.get_archetype_registry().register(HINGE_TOP)
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	if not foundation.is_ok():
		world.free()
		return null
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame(world, assembly_id, Vector3i(4, 0, 0), foundation)
	if not frame.is_ok():
		world.free()
		return null
	var rotor_place := PlaceElementCommand.new()
	rotor_place.assembly_id = assembly_id
	rotor_place.expected_assembly_revision = int(frame.data["topology_revision"])
	rotor_place.archetype = ROTOR_BASE
	rotor_place.origin_cell = Vector3i(5, 0, 0)
	rotor_place.orientation_index = 0
	rotor_place.store_id = "player"
	var rotor := world.apply_structural_command_now(rotor_place)
	if not rotor.is_ok():
		world.free()
		return null
	var mast := PlaceElementCommand.new()
	mast.assembly_id = assembly_id
	mast.expected_assembly_revision = int(rotor.data["topology_revision"])
	mast.archetype = Slice01Archetypes.frame()
	mast.origin_cell = Vector3i(5, 2, 0)
	mast.orientation_index = 0
	mast.store_id = "player"
	var mast_result := world.apply_structural_command_now(mast)
	if not mast_result.is_ok():
		world.free()
		return null
	var hinge_place := PlaceElementCommand.new()
	hinge_place.assembly_id = assembly_id
	hinge_place.expected_assembly_revision = int(
		mast_result.data["topology_revision"]
	)
	hinge_place.archetype = HINGE_BASE
	hinge_place.origin_cell = Vector3i(5, 3, 0)
	hinge_place.orientation_index = 0
	hinge_place.store_id = "player"
	var hinge := world.apply_structural_command_now(hinge_place)
	if not hinge.is_ok():
		world.free()
		return null
	var platform := PlaceElementCommand.new()
	platform.assembly_id = assembly_id
	platform.expected_assembly_revision = int(hinge.data["topology_revision"])
	platform.archetype = Slice01Archetypes.frame()
	platform.origin_cell = Vector3i(5, 5, 0)
	platform.orientation_index = 0
	platform.store_id = "player"
	var platform_result := world.apply_structural_command_now(platform)
	if not platform_result.is_ok():
		world.free()
		return null
	world.set_meta("assembly_id", assembly_id)
	world.set_meta("rotor_joint_id", int(rotor.data["rotor_joint_id"]))
	world.set_meta("hinge_joint_id", int(hinge.data["hinge_joint_id"]))
	world.set_meta("hinge_top_id", int(hinge.data["head_element_id"]))
	world.set_meta("platform_id", int(platform_result.data["element_id"]))
	return world


func _hinge_world_with_foundation() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	world.get_archetype_registry().register(HINGE_TOP)
	return world


func _hinge_setup(world: SimulationWorld) -> Dictionary:
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
	place.archetype = HINGE_BASE
	place.origin_cell = Vector3i(5, 0, 0)
	place.orientation_index = 0
	place.store_id = "player"
	var hinge := world.apply_structural_command_now(place)
	if not hinge.is_ok():
		push_error(
			"hinge placement failed: %s %s" % [hinge.reason, hinge.data]
		)
		return {}
	return {
		"assembly_id": assembly_id,
		"hinge": hinge,
	}


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
