extends Node


const PISTON_BASE := preload(
	"res://resources/archetypes/slice01/piston_base.tres"
)
const PISTON_HEAD := preload(
	"res://resources/archetypes/slice01/piston_head.tres"
)
const STATIONARY_DRILL := preload(
	"res://resources/archetypes/slice01/stationary_drill.tres"
)
const WHEEL_SUSPENSION := preload(
	"res://resources/archetypes/slice01/wheel_suspension.tres"
)
const DRIVE_WHEEL := preload(
	"res://resources/archetypes/slice01/drive_wheel.tres"
)


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _test_collider_mapping_and_anchor():
		return
	if not _test_projection_global_transform():
		return
	if not _test_split_velocity_inheritance():
		return
	if not _test_alignment_authority():
		return
	if not _test_motion_snapshot_validation():
		return
	if not _test_sync_motion_writeback():
		return
	if not _test_merge_reference_com_math():
		return
	if not await _test_merge_momentum_and_cleanup():
		return
	if not await _test_dual_anchor_merge():
		return
	if not await _test_piston_multibody_projection():
		return
	print("KERNEL-PROJECTION-V0: PASS")
	get_tree().quit(0)


func _test_collider_mapping_and_anchor() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	var anchored: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	if not anchored.is_ok():
		return _fail("anchored spawn failed")
	var anchored_id: int = int(anchored.data["assembly_id"])
	if not projection.get_physics_body(anchored_id) is StaticBody3D:
		return _fail("Anchor did not project as StaticBody3D")
	var foundation_id: int = int(anchored.data["element_ids"][0])
	var foundation_projection: Dictionary = (
		projection.get_element_projection(foundation_id)
	)
	if (
		int(foundation_projection.get("assembly_id", 0)) != anchored_id
		or projection.get_element_colliders(foundation_id).size() != 1
	):
		return _fail("foundation collider owner mapping missing")

	var frame := GridTransform.new()
	frame.translation = Vector3i(4, 0, 0)
	var beam: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame_beam()),
		frame
	)
	var beam_id: int = int(beam.data["element_ids"][0])
	if projection.get_element_colliders(beam_id).size() != 2:
		return _fail("multi-cell collider projection is incomplete")
	_free_fixture(fixture)
	return true


func _test_projection_global_transform() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	projection.transform = Transform3D(
		Basis.IDENTITY.rotated(Vector3.UP, 0.6),
		Vector3(8.0, -3.0, 5.0)
	)
	var frame := GridTransform.new()
	frame.translation = Vector3i(2, 4, -1)
	var spawn: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		frame
	)
	var assembly_id: int = int(spawn.data["assembly_id"])
	var expected: Transform3D = (
		world.get_assembly_raw(assembly_id).motion.transform
	)
	var body: PhysicsBody3D = projection.get_physics_body(assembly_id)
	if not body.global_transform.is_equal_approx(expected):
		return _fail("projected body treated global pose as local")
	_free_fixture(fixture)
	return true


func _test_split_velocity_inheritance() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	var spawn: StructuralCommandResult = _spawn(
		world,
		_chain_blueprint(2),
		GridTransform.identity()
	)
	var assembly_id: int = int(spawn.data["assembly_id"])
	var parent: RigidBody3D = (
		projection.get_physics_body(assembly_id) as RigidBody3D
	)
	parent.gravity_scale = 0.0
	parent.global_transform = Transform3D(
		Basis.IDENTITY.rotated(Vector3.UP, 0.37),
		Vector3(3.2, 4.1, -1.7)
	)
	parent.linear_velocity = Vector3(2.0, -0.5, 0.25)
	parent.angular_velocity = Vector3(0.0, 0.0, 2.0)
	var parent_com: Vector3 = parent.to_global(parent.center_of_mass)
	var parent_linear: Vector3 = parent.linear_velocity
	var parent_angular: Vector3 = parent.angular_velocity
	var joint_id: int = _first_rigid_joint(world, assembly_id)
	var command := BreakRigidJointCommand.new()
	command.joint_id = joint_id
	command.expected_assembly_revision = (
		world.get_assembly_raw(assembly_id).topology_revision
	)
	var split: StructuralCommandResult = (
		world.apply_structural_command_now(command)
	)
	if not split.is_ok() or not bool(split.data["split"]):
		return _fail("split command failed")
	var split_ids: Array[int] = [
		int(split.data["survivor_assembly_id"]),
		int(split.data["new_assembly_ids"][0]),
	]
	for split_id: int in split_ids:
		var child: RigidBody3D = (
			projection.get_physics_body(split_id) as RigidBody3D
		)
		if child == null:
			return _fail("split child body missing")
		child.gravity_scale = 0.0
		var child_com: Vector3 = child.to_global(child.center_of_mass)
		var expected: Vector3 = AssemblyPhysicsMath.velocity_at_point(
			parent_linear,
			parent_angular,
			child_com,
			parent_com
		)
		if not child.linear_velocity.is_equal_approx(expected):
			return _fail("split child did not inherit COM velocity")
		if not child.angular_velocity.is_equal_approx(parent_angular):
			return _fail("split child lost angular velocity")
	_free_fixture(fixture)
	return true


func _test_alignment_authority() -> bool:
	if not _test_almost_aligned_merge():
		return false
	if not _test_misaligned_merge(Vector3(0.2, 0.0, 0.0), 0.0):
		return false
	if not _test_misaligned_merge(Vector3.ZERO, deg_to_rad(9.0)):
		return false
	if not _test_malicious_alignment_command():
		return false
	return _test_b_wins_alignment()


func _test_almost_aligned_merge() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var a: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	var b_frame := GridTransform.new()
	b_frame.translation = Vector3i.RIGHT
	var b: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		b_frame
	)
	var assembly_b: SimulationAssembly = world.get_assembly_raw(
		int(b.data["assembly_id"])
	)
	assembly_b.motion.transform = Transform3D(
		Basis.IDENTITY.rotated(Vector3.UP, deg_to_rad(5.0)),
		Vector3(GridMetric.CELL_SIZE_M + 0.1, 0.0, 0.0)
	)
	var command: MergeAssembliesCommand = _gateway_merge(world, a, b)
	if command == null:
		return _fail("almost-aligned gateway merge was rejected")
	var result: StructuralCommandResult = (
		world.apply_structural_command_now(command)
	)
	if not result.is_ok():
		return _fail("almost-aligned authoritative merge failed")
	_free_fixture(fixture)
	return true


func _test_misaligned_merge(
	position_error: Vector3,
	angle_error: float
) -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var a: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	var b_frame := GridTransform.new()
	b_frame.translation = Vector3i.RIGHT
	var b: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		b_frame
	)
	var assembly_b: SimulationAssembly = world.get_assembly_raw(
		int(b.data["assembly_id"])
	)
	assembly_b.motion.transform = Transform3D(
		Basis.IDENTITY.rotated(Vector3.UP, angle_error),
		Vector3.RIGHT * GridMetric.CELL_SIZE_M + position_error
	)
	if _gateway_merge(world, a, b) != null:
		return _fail("gateway accepted out-of-tolerance alignment")
	var command: MergeAssembliesCommand = _raw_merge(world, a, b)
	command.b_to_a_grid = GridTransform.identity()
	command.b_to_a_grid.translation = Vector3i.RIGHT
	var before: Dictionary = _topology_signature(world)
	var result: StructuralCommandResult = (
		world.apply_structural_command_now(command)
	)
	if (
		result.reason
		!= StructuralCommandResult.REASON_MISALIGNED_CONNECTION
	):
		return _fail("authority accepted out-of-tolerance alignment")
	if before != _topology_signature(world):
		return _fail("misaligned merge mutated topology")
	_free_fixture(fixture)
	return true


func _test_malicious_alignment_command() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var a: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	var b_frame := GridTransform.new()
	b_frame.translation = Vector3i.RIGHT
	var b: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		b_frame
	)
	var command: MergeAssembliesCommand = _raw_merge(world, a, b)
	command.b_to_a_grid = GridTransform.identity()
	var before: Dictionary = _topology_signature(world)
	var result: StructuralCommandResult = (
		world.apply_structural_command_now(command)
	)
	if (
		result.reason
		!= StructuralCommandResult.REASON_MISALIGNED_CONNECTION
		or before != _topology_signature(world)
	):
		return _fail("authority trusted malicious snapped transform")
	_free_fixture(fixture)
	return true


func _test_b_wins_alignment() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var a_frame := GridTransform.new()
	a_frame.translation = Vector3i(-1, 0, 1)
	var a: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		a_frame
	)
	var b: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var command: MergeAssembliesCommand = _gateway_merge(world, a, b)
	var result: StructuralCommandResult = (
		world.apply_structural_command_now(command)
	)
	if (
		not result.is_ok()
		or int(result.data["survivor_assembly_id"])
		!= int(b.data["assembly_id"])
	):
		return _fail("B-wins alignment semantics changed")
	_free_fixture(fixture)
	return true


func _test_motion_snapshot_validation() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	_spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	var original: Dictionary = world.capture_snapshot()
	var scaled: Dictionary = original.duplicate(true)
	scaled["assemblies"][0]["motion"]["transform"]["basis"][0] = (
		Vector3(2.0, 0.0, 0.0)
	)
	if world.restore_snapshot(scaled):
		return _fail("snapshot accepted scaled motion basis")
	if not SimulationSnapshot.semantic_equals(
		original,
		world.capture_snapshot()
	):
		return _fail("scaled motion rejection was not atomic")
	var reflected: Dictionary = original.duplicate(true)
	reflected["assemblies"][0]["motion"]["transform"]["basis"][0] = (
		Vector3.LEFT
	)
	if world.restore_snapshot(reflected):
		return _fail("snapshot accepted reflected motion basis")
	if not SimulationSnapshot.semantic_equals(
		original,
		world.capture_snapshot()
	):
		return _fail("reflected motion rejection was not atomic")
	_free_fixture(fixture)
	return true


func _test_sync_motion_writeback() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var spawn: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	var assembly_id: int = int(spawn.data["assembly_id"])
	var assembly: SimulationAssembly = world.get_assembly_raw(assembly_id)
	var baseline: AssemblyMotionState = assembly.motion.duplicate_state()

	# Valid rigid motion is accepted and stored.
	var good := AssemblyMotionState.new()
	good.transform = Transform3D(
		Basis.IDENTITY.rotated(Vector3.UP, 0.4),
		Vector3(3.0, 1.0, -2.0)
	)
	good.linear_velocity = Vector3(0.5, 0.0, 0.0)
	if not world.sync_assembly_motion(assembly_id, good):
		return _fail("sync rejected valid rigid motion")
	if not assembly.motion.equals(good):
		return _fail("sync did not store valid motion")

	# Each rejection must leave the previously stored motion untouched.
	var scaled := AssemblyMotionState.new()
	scaled.transform = Transform3D(
		Basis.from_scale(Vector3(2.0, 1.0, 1.0)),
		Vector3.ZERO
	)
	var reflected := AssemblyMotionState.new()
	reflected.transform = Transform3D(
		Basis(Vector3.LEFT, Vector3.UP, Vector3.BACK),
		Vector3.ZERO
	)
	var non_finite := AssemblyMotionState.new()
	non_finite.transform = Transform3D(
		Basis.IDENTITY,
		Vector3(INF, 0.0, 0.0)
	)
	for bad: AssemblyMotionState in [scaled, reflected, non_finite]:
		if world.sync_assembly_motion(assembly_id, bad):
			return _fail("sync accepted non-rigid motion")
		if not assembly.motion.equals(good):
			return _fail("sync mutated motion on rejected input")

	# Null and unknown/tombstoned ids never mutate.
	if world.sync_assembly_motion(assembly_id, null):
		return _fail("sync accepted null motion")
	if world.sync_assembly_motion(9999, good):
		return _fail("sync accepted unknown assembly id")
	if not assembly.motion.equals(good):
		return _fail("sync mutated motion on invalid target")

	# Restore baseline so fixture teardown is clean.
	world.sync_assembly_motion(assembly_id, baseline)
	_free_fixture(fixture)
	return true


func _test_merge_reference_com_math() -> bool:
	var actual_com := Vector3(0.6, 0.0, 0.0)
	var result: Dictionary = AssemblyPhysicsMath.merge_dynamic_momentum(
		1.0,
		Vector3.ZERO,
		Vector3(0.0, 1.0, 0.0),
		Vector3.ZERO,
		Vector3.ONE,
		Basis.IDENTITY,
		1.0,
		Vector3.RIGHT,
		Vector3(0.0, -1.0, 0.0),
		Vector3.ZERO,
		Vector3.ONE,
		Basis.IDENTITY,
		actual_com,
		2.0,
		Vector3.ONE,
		Basis.IDENTITY
	)
	var expected_angular: Vector3 = (
		(Vector3.ZERO - actual_com).cross(Vector3(0.0, 1.0, 0.0))
		+ (Vector3.RIGHT - actual_com).cross(
			Vector3(0.0, -1.0, 0.0)
		)
	)
	if not Vector3(result["angular_momentum"]).is_equal_approx(
		expected_angular
	):
		return _fail("merge math ignored actual rebuilt COM reference")
	return true


func _test_merge_momentum_and_cleanup() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	var a: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	var b_frame := GridTransform.new()
	b_frame.translation = Vector3i.RIGHT
	var b: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		b_frame
	)
	var a_id: int = int(a.data["assembly_id"])
	var b_id: int = int(b.data["assembly_id"])
	var body_a: RigidBody3D = (
		projection.get_physics_body(a_id) as RigidBody3D
	)
	var body_b: RigidBody3D = (
		projection.get_physics_body(b_id) as RigidBody3D
	)
	body_a.gravity_scale = 0.0
	body_b.gravity_scale = 0.0
	body_a.linear_velocity = Vector3(0.0, 1.0, 0.0)
	body_b.linear_velocity = Vector3(0.0, -1.0, 0.0)
	body_a.angular_velocity = Vector3.ZERO
	body_b.angular_velocity = Vector3.ZERO
	var connection := _canonical_connection_ports(
		world,
		int(a.data["assembly_id"]),
		int(b.data["assembly_id"]),
		int(a.data["element_ids"][0]),
		int(b.data["element_ids"][0])
	)
	if connection.is_empty():
		return _fail("dynamic merge could not resolve canonical ports")
	var command: MergeAssembliesCommand = (
		SimulationMergeGateway.merge_command(
			world,
			int(a.data["assembly_id"]),
			int(b.data["assembly_id"]),
			int(a.data["element_ids"][0]),
			connection["left_port_id"],
			int(b.data["element_ids"][0]),
			connection["right_port_id"]
		)
	)
	var old_loser: PhysicsBody3D = body_b
	var merge: StructuralCommandResult = (
		world.apply_structural_command_now(command)
	)
	if not merge.is_ok():
		return _fail("dynamic merge failed")
	var survivor_id: int = int(merge.data["survivor_assembly_id"])
	var loser_id: int = int(merge.data["loser_assembly_id"])
	var merged: RigidBody3D = (
		projection.get_physics_body(survivor_id) as RigidBody3D
	)
	if merged == null:
		return _fail("merged dynamic body missing")
	merged.gravity_scale = 0.0
	if merged.linear_velocity.length() > 0.0001:
		return _fail("merge did not preserve total linear momentum")
	if absf(merged.angular_velocity.z) < 0.01:
		return _fail("merge omitted orbital angular momentum")
	if (
		projection.get_physics_body(loser_id) != null
		or old_loser.collision_layer != 0
		or old_loser.collision_mask != 0
	):
		return _fail("loser body remained active after tombstone")
	for element_id: int in world.get_assembly_raw(survivor_id).element_ids:
		var record: Dictionary = projection.get_element_projection(element_id)
		if record.get("body") != merged:
			return _fail("merged element retained stale body mapping")
	await get_tree().process_frame
	if is_instance_valid(old_loser):
		return _fail("loser body was not freed")
	_free_fixture(fixture)
	return true


func _test_dual_anchor_merge() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	var a: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var b_frame := GridTransform.new()
	b_frame.translation = Vector3i(4, 0, 0)
	var b: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		b_frame
	)
	var connection := _canonical_connection_ports(
		world,
		int(a.data["assembly_id"]),
		int(b.data["assembly_id"]),
		int(a.data["element_ids"][0]),
		int(b.data["element_ids"][0])
	)
	if connection.is_empty():
		return _fail("dual-anchor merge could not resolve canonical ports")
	var command: MergeAssembliesCommand = (
		SimulationMergeGateway.merge_command(
			world,
			int(a.data["assembly_id"]),
			int(b.data["assembly_id"]),
			int(a.data["element_ids"][0]),
			connection["left_port_id"],
			int(b.data["element_ids"][0]),
			connection["right_port_id"]
		)
	)
	var merge: StructuralCommandResult = (
		world.apply_structural_command_now(command)
	)
	if not merge.is_ok():
		return _fail("dual-anchor merge failed")
	var survivor_id: int = int(merge.data["survivor_assembly_id"])
	if (
		not projection.get_physics_body(survivor_id) is StaticBody3D
		or not world.assembly_has_anchor(survivor_id)
	):
		return _fail("dual-anchor survivor did not remain anchored")
	await get_tree().process_frame
	_free_fixture(fixture)
	return true


func _test_piston_multibody_projection() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	world.get_archetype_registry().register(PISTON_HEAD)
	world.get_archetype_registry().register(STATIONARY_DRILL)
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	if not foundation.is_ok():
		return _fail("piston projection foundation failed")
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame_for_piston(
		world,
		assembly_id,
		Vector3i(4, 0, 0),
		foundation
	)
	if not frame.is_ok():
		return _fail("piston projection frame failed")
	var piston := _place_piston_for_projection(
		world,
		assembly_id,
		Vector3i(5, 0, 0),
		frame
	)
	if not piston.is_ok():
		return _fail("piston projection placement failed")
	var base_id := int(piston.data["element_id"])
	var head_id := int(piston.data["head_element_id"])
	var runtime := world.ensure_industry_element_runtime(base_id)
	runtime.machine_enabled = true
	runtime.powered = true
	var carriage_frame := _place_element_for_projection(
		world,
		assembly_id,
		Slice01Archetypes.rover_frame(),
		Vector3i(5, 1, -1),
		piston
	)
	if not carriage_frame.is_ok():
		return _fail("piston carriage frame placement failed")
	var suspension := _place_element_for_projection(
		world,
		assembly_id,
		WHEEL_SUSPENSION,
		Vector3i(4, 1, -1),
		carriage_frame
	)
	if not suspension.is_ok():
		return _fail("piston carriage suspension placement failed")
	var wheel := _place_element_for_projection(
		world,
		assembly_id,
		DRIVE_WHEEL,
		Vector3i(4, 0, -1),
		suspension
	)
	if not wheel.is_ok():
		return _fail("piston carriage wheel placement failed")
	var drill := _place_element_for_projection(
		world,
		assembly_id,
		STATIONARY_DRILL,
		Vector3i(6, 1, -1),
		wheel
	)
	if not drill.is_ok():
		return _fail(
			"piston carriage drill placement failed: %s" % drill.reason
		)
	var drill_id := int(drill.data["element_id"])
	var suspension_id := int(suspension.data["element_id"])
	var wheel_id := int(wheel.data["element_id"])
	for element_id: int in [
		base_id,
		head_id,
		int(carriage_frame.data["element_id"]),
		suspension_id,
		wheel_id,
		drill_id,
	]:
		_weld_piston_element(world, element_id)
	world.get_locomotion_controller(assembly_id).activate()
	projection.project_assembly_now(
		assembly_id,
		world.get_assembly_raw(assembly_id).motion.duplicate_state()
	)

	var compiled := BodyGroupCompiler.compile(
		world.get_assembly_raw(assembly_id).element_ids,
		_elements_by_id(world, assembly_id),
		_joints_for_assembly(world, assembly_id)
	)
	if not bool(compiled.get("valid", false)) or compiled["groups"].size() != 2:
		return _fail("piston projection body groups invalid")
	var root_group := int(compiled.get("root_group_id", 0))
	var head_group := int(
		(compiled["element_to_group"] as Dictionary).get(head_id, 0)
	)
	var drill_group := int(
		(compiled["element_to_group"] as Dictionary).get(drill_id, 0)
	)
	var suspension_group := int(
		(compiled["element_to_group"] as Dictionary).get(suspension_id, 0)
	)
	if (
		drill_group <= 0
		or drill_group != head_group
		or suspension_group != head_group
	):
		return _fail("drill/wheel modules did not join piston carriage body")
	var root_body := projection.get_group_physics_body(assembly_id, root_group)
	var head_body := projection.get_group_physics_body(assembly_id, head_group)
	if not root_body is RigidBody3D or not head_body is RigidBody3D:
		return _fail("locomotive piston projection did not create dynamic groups")
	if projection.list_piston_constraint_records(assembly_id).is_empty():
		return _fail("piston projection missing slider constraint")
	var drill_body := projection.get_element_projection(drill_id).get(
		"body"
	) as PhysicsBody3D
	if drill_body != head_body:
		return _fail("drill projection did not follow carriage body")
	var wheel_body := projection.get_element_projection(suspension_id).get(
		"body"
	) as PhysicsBody3D
	if wheel_body != head_body:
		return _fail("wheel projection did not follow carriage body")

	var command := SetActuatorTargetCommand.new()
	command.joint_id = int(piston.data["piston_joint_id"])
	command.mode = SimulationMotorState.ControlMode.POSITION
	command.target_position_m = 1.0
	world.apply_set_actuator_target(command)
	(root_body as RigidBody3D).gravity_scale = 0.0
	(head_body as RigidBody3D).gravity_scale = 0.0
	var start_extension := world.get_joint(command.joint_id).motor.observed_position_m
	for _i: int in range(120):
		await get_tree().physics_frame
	var end_extension := world.get_joint(command.joint_id).motor.observed_position_m
	var wheel_runtime := world.get_wheel_runtime(wheel_id)
	if (
		wheel_runtime.is_empty()
		or int(wheel_runtime.get("body_group_id", 0))
		!= int(head_body.get_meta("body_group_id", 0))
	):
		return _fail("wheel tick did not use carriage body group")
	if end_extension <= start_extension + 0.05:
		return _fail(
			"piston projection did not extend head: %.3f -> %.3f"
			% [start_extension, end_extension]
		)
	_free_fixture(fixture)
	return true


func _elements_by_id(world: SimulationWorld, assembly_id: int) -> Dictionary:
	var elements_by_id: Dictionary = {}
	for element: SimulationElement in world.list_elements():
		if element.assembly_id == assembly_id:
			elements_by_id[element.element_id] = element
	return elements_by_id


func _joints_for_assembly(
	world: SimulationWorld,
	assembly_id: int
) -> Array[SimulationJoint]:
	var joints: Array[SimulationJoint] = []
	for joint: SimulationJoint in world.list_joints():
		if joint.assembly_id == assembly_id:
			joints.append(joint)
	return joints


func _place_frame_for_piston(
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


func _place_piston_for_projection(
	world: SimulationWorld,
	assembly_id: int,
	origin_cell: Vector3i,
	prior: StructuralCommandResult
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(prior.data["topology_revision"])
	place.archetype = PISTON_BASE
	place.origin_cell = origin_cell
	place.orientation_index = 0
	place.store_id = "player"
	return world.apply_structural_command_now(place)


func _place_element_for_projection(
	world: SimulationWorld,
	assembly_id: int,
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	prior: StructuralCommandResult
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(prior.data["topology_revision"])
	place.archetype = archetype
	place.origin_cell = origin_cell
	place.orientation_index = 0
	place.store_id = "player"
	return world.apply_structural_command_now(place)


func _weld_piston_element(world: SimulationWorld, element_id: int) -> void:
	var element := world.get_element(element_id)
	var weld := WeldElementCommand.new()
	weld.element_id = element_id
	weld.expected_state_revision = element.state_revision
	weld.max_material_amount = 100.0
	weld.store_id = "player"
	world.apply_structural_command_now(weld)


func _new_fixture() -> Dictionary:
	var root := Node.new()
	add_child(root)
	var world := SimulationWorld.new()
	root.add_child(world)
	var projection := SimulationPhysicsProjection.new()
	root.add_child(projection)
	projection.bind_world(world)
	return {
		"root": root,
		"world": world,
		"projection": projection,
	}


func _free_fixture(fixture: Dictionary) -> void:
	var root: Node = fixture["root"]
	root.queue_free()


func _spawn(
	world: SimulationWorld,
	blueprint: Blueprint,
	frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = frame
	return world.apply_structural_command_now(command)


func _gateway_merge(
	world: SimulationWorld,
	a: StructuralCommandResult,
	b: StructuralCommandResult
) -> MergeAssembliesCommand:
	var connection := _canonical_connection_ports(
		world,
		int(a.data["assembly_id"]),
		int(b.data["assembly_id"]),
		int(a.data["element_ids"][0]),
		int(b.data["element_ids"][0])
	)
	if connection.is_empty():
		return null
	return SimulationMergeGateway.merge_command(
		world,
		int(a.data["assembly_id"]),
		int(b.data["assembly_id"]),
		int(a.data["element_ids"][0]),
		connection["left_port_id"],
		int(b.data["element_ids"][0]),
		connection["right_port_id"]
	)


func _raw_merge(
	world: SimulationWorld,
	a: StructuralCommandResult,
	b: StructuralCommandResult
) -> MergeAssembliesCommand:
	var connection := _canonical_connection_ports(
		world,
		int(a.data["assembly_id"]),
		int(b.data["assembly_id"]),
		int(a.data["element_ids"][0]),
		int(b.data["element_ids"][0])
	)
	var command := MergeAssembliesCommand.new()
	command.assembly_a_id = int(a.data["assembly_id"])
	command.assembly_b_id = int(b.data["assembly_id"])
	command.expected_revision_a = world.get_assembly_raw(
		command.assembly_a_id
	).topology_revision
	command.expected_revision_b = world.get_assembly_raw(
		command.assembly_b_id
	).topology_revision
	command.element_a_id = int(a.data["element_ids"][0])
	command.port_a_id = str(connection.get("left_port_id", "structural_0_0_0_px"))
	command.element_b_id = int(b.data["element_ids"][0])
	command.port_b_id = str(connection.get("right_port_id", "structural_0_0_0_nx"))
	return command


func _canonical_connection_ports(
	world: SimulationWorld,
	assembly_a_id: int,
	assembly_b_id: int,
	element_a_id: int,
	element_b_id: int
) -> Dictionary:
	var assembly_a: SimulationAssembly = world.get_assembly_raw(assembly_a_id)
	var assembly_b: SimulationAssembly = world.get_assembly_raw(assembly_b_id)
	var element_a: SimulationElement = world.get_element(element_a_id)
	var element_b: SimulationElement = world.get_element(element_b_id)
	if (
		assembly_a == null
		or assembly_b == null
		or element_a == null
		or element_b == null
	):
		return {}
	var elements_by_id: Dictionary = {}
	for element: SimulationElement in world.list_elements():
		elements_by_id[element.element_id] = element
	var score_a := SurvivorPolicy.assembly_score(
		assembly_a.assembly_id,
		assembly_a.element_ids,
		elements_by_id,
		world.list_joints()
	)
	var score_b := SurvivorPolicy.assembly_score(
		assembly_b.assembly_id,
		assembly_b.element_ids,
		elements_by_id,
		world.list_joints()
	)
	var survivor_id := SurvivorPolicy.pick_survivor_assembly([score_a, score_b])
	var b_to_a := GridPoseUtil.b_to_a_from_grid_frames(
		assembly_a.grid_frame,
		assembly_b.grid_frame
	)
	var connection_a := element_a
	var connection_b := element_b
	if survivor_id == assembly_a.assembly_id:
		connection_b = _preview_element_in_frame(
			element_b,
			b_to_a.map_element_pose(
				element_b.origin_cell,
				element_b.orientation_index
			)
		)
	else:
		connection_a = _preview_element_in_frame(
			element_a,
			b_to_a.inverse().map_element_pose(
				element_a.origin_cell,
				element_a.orientation_index
			)
		)
	return GridSurfaceUtil.find_rigid_connection(connection_a, connection_b)


func _preview_element_in_frame(
	source: SimulationElement,
	pose: Dictionary
) -> SimulationElement:
	var preview := SimulationElement.new()
	preview.archetype_id = source.archetype_id
	preview.bind_archetype(source.get_archetype())
	preview.origin_cell = pose["origin_cell"]
	preview.orientation_index = int(pose["orientation_index"])
	return preview


func _topology_signature(world: SimulationWorld) -> Dictionary:
	var snapshot: Dictionary = world.capture_snapshot()
	var allocator: Dictionary = snapshot["allocator"]
	allocator.erase("next_command_id")
	for assembly: Dictionary in snapshot["assemblies"]:
		assembly.erase("motion")
	return snapshot


func _single_blueprint(archetype: ElementArchetype) -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"projection_%s" % archetype.archetype_id,
		[_placement("element_0", archetype, Vector3i.ZERO)]
	)


func _chain_blueprint(count: int) -> Blueprint:
	var placements: Array[BlueprintElementPlacement] = []
	for index: int in range(count):
		placements.append(_placement(
			"frame_%d" % index,
			Slice01Archetypes.frame(),
			Vector3i(index, 0, 0)
		))
	return BlueprintBaker.bake_from_placements(
		"projection_chain",
		placements
	)


func _placement(
	local_id: String,
	archetype: ElementArchetype,
	cell: Vector3i
) -> BlueprintElementPlacement:
	var placement := BlueprintElementPlacement.new()
	placement.local_id = local_id
	placement.archetype = archetype
	placement.origin_cell = cell
	return placement


func _first_rigid_joint(
	world: SimulationWorld,
	assembly_id: int
) -> int:
	for joint: SimulationJoint in world.list_joints():
		if (
			joint.assembly_id == assembly_id
			and joint.kind == SimulationJoint.Kind.RIGID
		):
			return joint.joint_id
	return 0


func _fail(reason: String) -> bool:
	print("KERNEL-PROJECTION-V0: FAIL %s" % reason)
	get_tree().quit(1)
	return false
