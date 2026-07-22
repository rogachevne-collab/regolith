extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")

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
	_HeadlessTestHarness.arm_watchdog(self, "KERNEL-PROJECTION-V0")
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
	if not await _test_piston_split_keeps_extended_carriage_pose():
		return
	if not await _test_rope_tension_pulls_and_breaks():
		return
	if not await _test_rope_cannot_launch_a_body():
		return
	if not await _test_rope_wakes_a_parked_body():
		return
	if not _test_rope_rest_length_respects_routed_path():
		return
	if not await _test_rope_carries_the_actuator_rating():
		return
	if not await _test_ground_anchor_tears_out_with_the_ground():
		return
	if not await _test_rope_lies_on_the_world():
		return
	if not await _test_rope_does_not_saw_through_a_thin_beam():
		return
	if not await _test_rope_is_never_born_inside_geometry():
		return
	if not _test_render_spline_subdivides_where_it_bends():
		return
	if not _test_rope_settles_and_stays_still():
		return
	if not _test_cable_damps_ripple_faster_than_swing():
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
	var parent_body: RigidBody3D = (
		projection.get_physics_body(assembly_id) as RigidBody3D
	)
	parent_body.gravity_scale = 0.0
	parent_body.global_transform = Transform3D(
		Basis.IDENTITY.rotated(Vector3.UP, 0.37),
		Vector3(3.2, 4.1, -1.7)
	)
	parent_body.linear_velocity = Vector3(2.0, -0.5, 0.25)
	parent_body.angular_velocity = Vector3(0.0, 0.0, 2.0)
	var parent_com: Vector3 = parent_body.to_global(parent_body.center_of_mass)
	var parent_linear: Vector3 = parent_body.linear_velocity
	var parent_angular: Vector3 = parent_body.angular_velocity
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
		var child_body: RigidBody3D = (
			projection.get_physics_body(split_id) as RigidBody3D
		)
		if child_body == null:
			return _fail("split child body missing")
		child_body.gravity_scale = 0.0
		var child_com: Vector3 = child_body.to_global(child_body.center_of_mass)
		var expected: Vector3 = AssemblyPhysicsMath.velocity_at_point(
			parent_linear,
			parent_angular,
			child_com,
			parent_com
		)
		if not child_body.linear_velocity.is_equal_approx(expected):
			return _fail("split child did not inherit COM velocity")
		if not child_body.angular_velocity.is_equal_approx(parent_angular):
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
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 100.0)
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


## Cutting the base of an extended piston must leave the carriage (and welded
## blocks) at the live world pose — not snap them back to home grid.
func _test_piston_split_keeps_extended_carriage_pose() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 100.0)
	world.get_archetype_registry().register(PISTON_HEAD)
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	if not foundation.is_ok():
		return _fail("extended-split foundation failed")
	var assembly_id := int(foundation.data["assembly_id"])
	var frame := _place_frame_for_piston(
		world,
		assembly_id,
		Vector3i(4, 0, 0),
		foundation
	)
	if not frame.is_ok():
		return _fail("extended-split frame failed")
	var piston := _place_piston_for_projection(
		world,
		assembly_id,
		Vector3i(5, 0, 0),
		frame
	)
	if not piston.is_ok():
		return _fail("extended-split piston failed")
	var base_id := int(piston.data["element_id"])
	var head_id := int(piston.data["head_element_id"])
	var joint_id := int(piston.data["piston_joint_id"])
	var tip := _place_element_for_projection(
		world,
		assembly_id,
		Slice01Archetypes.frame(),
		Vector3i(5, 2, 0),
		piston
	)
	if not tip.is_ok():
		return _fail("extended-split tip frame failed")
	var tip_id := int(tip.data["element_id"])
	for element_id: int in [base_id, head_id, tip_id]:
		_weld_piston_element(world, element_id)
	projection.project_assembly_now(
		assembly_id,
		world.get_assembly_raw(assembly_id).motion.duplicate_state()
	)
	var compiled := BodyGroupCompiler.compile(
		world.get_assembly_raw(assembly_id).element_ids,
		_elements_by_id(world, assembly_id),
		_joints_for_assembly(world, assembly_id)
	)
	var head_group := int(
		(compiled["element_to_group"] as Dictionary).get(head_id, 0)
	)
	var head_body := projection.get_group_physics_body(assembly_id, head_group)
	if head_body == null:
		return _fail("extended-split missing carriage body")
	(head_body as RigidBody3D).gravity_scale = 0.0
	var root_body := projection.get_physics_body(assembly_id) as RigidBody3D
	if root_body != null:
		root_body.gravity_scale = 0.0
	# Force an extended carriage pose without waiting on the motor.
	var axis := Vector3.UP
	var extended_origin: Vector3 = (
		head_body.global_transform.origin + axis * 1.0
	)
	head_body.global_transform = Transform3D(
		head_body.global_transform.basis,
		extended_origin
	)
	world.get_joint(joint_id).motor.observed_position_m = 1.0
	var tip_before: Vector3 = (
		projection.get_element_projection(tip_id).get("body") as PhysicsBody3D
	).global_transform.origin
	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = base_id
	dismantle.expected_assembly_revision = world.get_assembly_raw(
		assembly_id
	).topology_revision
	dismantle.store_id = PlayerIdentity.store_id("player")
	var result := world.apply_structural_command_now(dismantle)
	if not result.is_ok() or not bool(result.data.get("split", false)):
		_free_fixture(fixture)
		return _fail("extended-split dismantle base did not split")
	var tip_element := world.get_element(tip_id)
	if tip_element == null:
		_free_fixture(fixture)
		return _fail("extended-split tip vanished")
	var tip_after_body := projection.get_element_projection(tip_id).get(
		"body"
	) as PhysicsBody3D
	if tip_after_body == null:
		_free_fixture(fixture)
		return _fail("extended-split tip body missing after split")
	var tip_after: Vector3 = tip_after_body.global_transform.origin
	if tip_before.distance_to(tip_after) > 0.15:
		_free_fixture(fixture)
		return _fail(
			"extended carriage snapped on piston cut: before=%s after=%s"
			% [tip_before, tip_after]
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
	place.store_id = PlayerIdentity.store_id("player")
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
	place.store_id = PlayerIdentity.store_id("player")
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
	place.store_id = PlayerIdentity.store_id("player")
	return world.apply_structural_command_now(place)


func _weld_piston_element(world: SimulationWorld, element_id: int) -> void:
	var element := world.get_element(element_id)
	var weld := WeldElementCommand.new()
	weld.element_id = element_id
	weld.expected_state_revision = element.state_revision
	weld.max_material_amount = 100.0
	weld.store_id = PlayerIdentity.store_id("player")
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


## Rope physics contract: slack does nothing at all, a taut rope pulls the free
## end back toward its anchor, and a hard enough yank exceeds the break
## threshold. Two bare bodies — no world needed, the solver is the unit.
func _test_rope_tension_pulls_and_breaks() -> bool:
	var root := Node3D.new()
	add_child(root)
	var anchor_point := Vector3.ZERO
	var runaway := RigidBody3D.new()
	runaway.mass = 500.0
	runaway.gravity_scale = 0.0
	root.add_child(runaway)
	runaway.global_position = Vector3(9.0, 0.0, 0.0)
	await get_tree().process_frame
	var rest_length := 10.0
	# Slack: the body is inside the rest length, nothing may happen.
	var slack_tension := CableTensionUtil.solve(
		anchor_point,
		null,
		runaway.global_position,
		runaway,
		rest_length,
		0.016
	)
	if slack_tension != 0.0 or runaway.linear_velocity.length() > 0.000001:
		root.queue_free()
		return _fail("a slack rope must apply nothing at all")
	# Taut and still running: the rope has to pull the body back.
	runaway.global_position = Vector3(12.0, 0.0, 0.0)
	runaway.linear_velocity = Vector3(6.0, 0.0, 0.0)
	await get_tree().physics_frame
	var taut_tension := CableTensionUtil.solve(
		anchor_point,
		null,
		runaway.global_position,
		runaway,
		rest_length,
		0.016
	)
	if taut_tension <= 0.0:
		root.queue_free()
		return _fail("a taut rope must pull")
	await get_tree().physics_frame
	# A rope catches; it does not throw. Slowed, but never fired back the way it
	# came — that is what smashed small objects tied to masts.
	if runaway.linear_velocity.x >= 6.0:
		root.queue_free()
		return _fail(
			"rope must slow the runaway end, vx=%.3f" % runaway.linear_velocity.x
		)
	if runaway.linear_velocity.x < -1.0:
		root.queue_free()
		return _fail(
			"rope threw the end back instead of catching it, vx=%.3f"
			% runaway.linear_velocity.x
		)
	# A light object on a long fall must never take more than it arrived with.
	var pebble := RigidBody3D.new()
	pebble.mass = 12.0
	pebble.gravity_scale = 0.0
	root.add_child(pebble)
	pebble.global_position = Vector3(13.0, 0.0, 0.0)
	pebble.linear_velocity = Vector3(9.0, 0.0, 0.0)
	await get_tree().physics_frame
	var arriving := pebble.linear_velocity.x
	CableTensionUtil.solve(
		anchor_point,
		null,
		pebble.global_position,
		pebble,
		rest_length,
		0.016
	)
	await get_tree().physics_frame
	if absf(pebble.linear_velocity.x) > arriving:
		root.queue_free()
		return _fail(
			"rope gave a light body more speed than it had: %.3f from %.3f"
			% [pebble.linear_velocity.x, arriving]
		)
	# A heavy body ripping away at speed must be over the snap threshold.
	var heavy := RigidBody3D.new()
	heavy.mass = 6000.0
	heavy.gravity_scale = 0.0
	root.add_child(heavy)
	heavy.global_position = Vector3(14.0, 0.0, 0.0)
	heavy.linear_velocity = Vector3(30.0, 0.0, 0.0)
	await get_tree().physics_frame
	var yank_n := CableTensionUtil.solve(
		anchor_point,
		null,
		heavy.global_position,
		heavy,
		rest_length,
		0.016
	)
	if yank_n <= CableTensionUtil.break_force_n(0.0):
		root.queue_free()
		return _fail(
			"a 6 t body tearing off at 30 m/s must snap the rope, %.0f N"
			% yank_n
		)
	root.queue_free()
	return true


## A crane has to be able to pull a parked machine. A parked assembly is a frozen
## RigidBody3D and CableTensionUtil reads frozen as "world anchor", so before the
## thaw a winch rigged to one pulled against a wall — nothing lifted, and since
## the tension was only ever what it took to arrest the light end, the rope did
## not even snap. The other half of the contract matters just as much: a rope
## that merely hangs taut must leave a parked body parked, or nothing moored
## would ever sleep again.
func _test_rope_wakes_a_parked_body() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	var spawned: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	if not spawned.is_ok():
		_free_fixture(fixture)
		return _fail("parked-body rope spawn failed: %s" % spawned.reason)
	var assembly_id: int = int(spawned.data["assembly_id"])
	var element_id: int = int(spawned.data["element_ids"][0])
	var parked := projection.get_physics_body(assembly_id) as RigidBody3D
	if parked == null:
		_free_fixture(fixture)
		return _fail("a loose frame must project as a RigidBody3D")
	var element_origin := world.element_world_transform(element_id).origin
	var anchor_point := element_origin + Vector3(6.0, 0.0, 0.0)
	await get_tree().physics_frame
	# Everything below is driven by hand, with no physics frame in between: the
	# projection ticks ropes in its own _physics_process, and _tick_cable_anchors
	# would tear a world-nailed end that has no ground stand-in under it — the
	# rest of the test would then be asserting against a rope that is gone.
	var roped := world.connect_rope(
		element_id,
		element_origin,
		0,
		anchor_point,
		0.5
	)
	if not roped.is_ok():
		_free_fixture(fixture)
		return _fail("rope to the ground failed: %s" % str(roped.reason))
	var link_id := int(roped.data["link_id"])
	var link: IndustryElectricLink = (
		world.get_industry_network().get_link(link_id)
	)
	# A test winch that cannot part: snapping would pull the link out mid-run and
	# leave the later ticks quietly asserting nothing.
	link.break_force_n = 1.0e9
	# Reel in past the span: the rope is now taut and still taking up.
	link.rest_length_m = element_origin.distance_to(anchor_point) - 0.25
	parked.freeze = true
	parked.sleeping = true
	projection._tick_cable_tension(1.0 / 60.0)
	if world.get_industry_network().get_link(link_id) == null:
		_free_fixture(fixture)
		return _fail("the test winch must not snap")
	if parked.freeze:
		_free_fixture(fixture)
		return _fail("a rope running out must thaw the parked body it pulls")
	# Park it again and hold the rope exactly where it is. A taut rope does no
	# work; re-thawing here is what would keep a moored rover awake forever.
	parked.freeze = true
	parked.sleeping = true
	projection._tick_cable_tension(1.0 / 60.0)
	if not parked.freeze:
		_free_fixture(fixture)
		return _fail("a rope hanging taut and still must leave a park alone")
	# Winch takes up another half metre: that is a pull, and it must land.
	link.rest_length_m -= 0.5
	projection._tick_cable_tension(1.0 / 60.0)
	if parked.freeze:
		_free_fixture(fixture)
		return _fail("taking up more rope must thaw the parked body again")
	_free_fixture(fixture)
	return true


## A rope routed AROUND something is longer than the straight line between its
## ends, and the build command must honour that: rest length is floored by the
## routed length the player actually laid (CABLE-ROPE-V0 `routed_m`). Built off
## the chord alone the rope was born metres overstretched, and the tension
## solver spent that phantom stretch yanking the machine — which is how a wire
## bent around a block tore itself off on placement. The floor must also never
## SHORTEN a rope: a generous slack setting wins over a smaller routed hint.
func _test_rope_rest_length_respects_routed_path() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var spawned: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	if not spawned.is_ok():
		_free_fixture(fixture)
		return _fail("routed-rest rope spawn failed: %s" % spawned.reason)
	var element_id: int = int(spawned.data["element_ids"][0])
	var origin := world.element_world_transform(element_id).origin
	# Wrapped case: laid path is far longer than the chord — the routed length
	# must become the rest length, so the rope is born with zero tension.
	var wrapped_anchor := origin + Vector3(4.0, 0.0, 0.0)
	var wrapped_routed := 9.5
	var wrapped := world.connect_rope(
		element_id,
		origin,
		0,
		wrapped_anchor,
		0.0,
		wrapped_routed
	)
	if not wrapped.is_ok():
		_free_fixture(fixture)
		return _fail("wrapped rope failed: %s" % str(wrapped.reason))
	var wrapped_rest := float(wrapped.data["rest_length_m"])
	if not is_equal_approx(wrapped_rest, wrapped_routed):
		_free_fixture(fixture)
		return _fail(
			"wrapped rope must be born its routed length: rest %.2f, routed %.2f"
			% [wrapped_rest, wrapped_routed]
		)
	# Slack case: the wheel asked for more rope than the routed hint — the hint
	# must not cinch it down.
	var slack_anchor := origin + Vector3(0.0, 0.0, 4.0)
	var slack_span := origin.distance_to(slack_anchor)
	var slack := world.connect_rope(
		element_id,
		origin,
		0,
		slack_anchor,
		1.0,
		slack_span * 1.05
	)
	if not slack.is_ok():
		_free_fixture(fixture)
		return _fail("slack rope failed: %s" % str(slack.reason))
	var slack_rest := float(slack.data["rest_length_m"])
	var wheel_rest := CableAnchorUtil.rest_length_m(slack_span, 1.0)
	if not is_equal_approx(slack_rest, wheel_rest):
		_free_fixture(fixture)
		return _fail(
			"routed hint must never shorten a slack rope: rest %.2f, wheel %.2f"
			% [slack_rest, wheel_rest]
		)
	_free_fixture(fixture)
	return true


## A crane is as strong as its winch, not as its hook. A rope on a piston
## carriage pulls against the machine the piston is bolted to and is capped by
## what the motor is rated for. Solved as a free 20 kg hook — which is all the
## point-mass solve can see on its own — a 5 kN piston delivered a few hundred
## newtons, and a crane rigged over a two-tonne structure lifted nothing at all.
func _test_rope_carries_the_actuator_rating() -> bool:
	var root := Node3D.new()
	add_child(root)
	# Two carriages, so the backed measurement starts from rest instead of from
	# whatever the unbacked one was left holding.
	var bare_hook := RigidBody3D.new()
	bare_hook.mass = 20.0
	bare_hook.gravity_scale = 0.0
	root.add_child(bare_hook)
	bare_hook.global_position = Vector3(30.0, 0.0, 0.0)
	var hook := RigidBody3D.new()
	hook.mass = 20.0
	hook.gravity_scale = 0.0
	root.add_child(hook)
	hook.global_position = Vector3.ZERO
	# The machine behind the piston.
	var mast := RigidBody3D.new()
	mast.mass = 800.0
	mast.gravity_scale = 0.0
	root.add_child(mast)
	mast.global_position = Vector3(0.0, 2.0, 0.0)
	var slung := RigidBody3D.new()
	slung.mass = 2210.0
	slung.gravity_scale = 0.0
	root.add_child(slung)
	slung.global_position = Vector3(0.0, -12.0, 0.0)
	await get_tree().physics_frame
	var rest_length := 11.5
	var delta := 1.0 / 60.0
	var lunar_weight_n := 2210.0 * 1.62
	var bare := CableTensionUtil.solve(
		bare_hook.global_position,
		bare_hook,
		slung.global_position + Vector3(30.0, 0.0, 0.0),
		null,
		rest_length,
		delta
	)
	if bare >= lunar_weight_n:
		root.queue_free()
		return _fail(
			"a bare 20 kg hook must not out-pull two tonnes, %.0f N" % bare
		)
	# Same rope, now told what is behind the hook: a 5 kN piston on an 800 kg
	# mast. The rope is tied to a port face, NOT to the hook's centre of mass —
	# that offset is the whole reason the reaction may not land on the hook.
	var rating_n := 5000.0
	var hook_anchor := hook.global_position + Vector3(0.0, 0.0, 0.9)
	var backed := CableTensionUtil.solve(
		hook_anchor,
		hook,
		slung.global_position,
		slung,
		rest_length,
		delta,
		0.0,
		{
			"inverse_mass": 1.0 / mast.mass,
			"force_cap_n": rating_n,
			"reaction_body": mast,
		},
		{}
	)
	if backed <= lunar_weight_n:
		root.queue_free()
		return _fail(
			"a %.0f N piston must out-pull %.0f N of lunar weight, got %.0f N"
			% [rating_n, lunar_weight_n, backed]
		)
	if backed > rating_n + 0.5:
		root.queue_free()
		return _fail(
			"rope transmitted %.0f N through a %.0f N motor" % [backed, rating_n]
		)
	await get_tree().physics_frame
	# The impulse is sized by the mast's mass. Land it on the 20 kg carriage
	# instead and a metre of lever arm spins it to the engine's angular ceiling
	# in one tick — which is exactly how the piston head got torn off.
	if hook.angular_velocity.length() > 0.5 or hook.linear_velocity.length() > 0.5:
		root.queue_free()
		return _fail(
			"the carriage must not take the pull: v=%.2f m/s, w=%.2f rad/s"
			% [hook.linear_velocity.length(), hook.angular_velocity.length()]
		)
	if mast.linear_velocity.length() <= 0.0:
		root.queue_free()
		return _fail("the machine behind the piston must take the reaction")
	if slung.linear_velocity.y <= 0.0:
		root.queue_free()
		return _fail(
			"the slung load must be pulled up, vy=%.3f" % slung.linear_velocity.y
		)
	root.queue_free()
	return true


## A rope end hammered into the ground is only as good as the ground: while
## there is terrain under it the anchor holds, and when the ground is dug out
## the rope tears loose instead of hanging off thin air.
func _test_ground_anchor_tears_out_with_the_ground() -> bool:
	var fixture: Dictionary = _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	var spawned: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	if not spawned.is_ok():
		_free_fixture(fixture)
		return _fail("ground anchor scenario spawn failed: %s" % spawned.reason)
	var element_id: int = int(spawned.data["element_ids"][0])
	var anchor_point := Vector3(4.0, 0.0, 0.0)
	# Stand-in for terrain: a static body on layer 1, the terrain layer.
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var ground_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 1.0, 2.0)
	ground_shape.shape = box
	ground.add_child(ground_shape)
	(fixture["root"] as Node).add_child(ground)
	ground.global_position = anchor_point
	await get_tree().physics_frame
	var roped := world.connect_rope(
		element_id,
		world.element_world_transform(element_id).origin,
		0,
		anchor_point,
		0.2
	)
	if not roped.is_ok():
		_free_fixture(fixture)
		return _fail("rope to the ground failed: %s" % str(roped.reason))
	var link_id := int(roped.data["link_id"])
	projection._tick_cable_anchors(10.0)
	if world.get_industry_network().get_link(link_id) == null:
		_free_fixture(fixture)
		return _fail("anchor with ground under it must hold")
	# Dig it out.
	ground.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	projection._tick_cable_anchors(10.0)
	if world.get_industry_network().get_link(link_id) != null:
		_free_fixture(fixture)
		return _fail("anchor must tear loose when the ground is gone")
	_free_fixture(fixture)
	return true


## What the rope is for: slack has to pile ON the ground, not sink through it,
## and a rope strung across an obstacle has to lie over it instead of passing
## through. Both ends pinned above a floor, with a block in the middle.
func _test_rope_lies_on_the_world() -> bool:
	var root := Node3D.new()
	add_child(root)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(40.0, 1.0, 40.0)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	# Floor top surface at y = 0.
	floor_body.global_position = Vector3(0.0, -0.5, 0.0)
	var obstacle := StaticBody3D.new()
	obstacle.collision_layer = 1
	obstacle.collision_mask = 0
	var obstacle_shape := CollisionShape3D.new()
	var obstacle_box := BoxShape3D.new()
	obstacle_box.size = Vector3(1.0, 2.0, 1.0)
	obstacle_shape.shape = obstacle_box
	obstacle.add_child(obstacle_shape)
	root.add_child(obstacle)
	obstacle.global_position = Vector3(0.0, 1.0, 0.0)
	await get_tree().physics_frame
	var anchor_a := Vector3(-4.0, 2.2, 0.0)
	var anchor_b := Vector3(4.0, 2.2, 0.0)
	# Twice the straight span: it has to end up draped, not stretched.
	var rest_length := anchor_a.distance_to(anchor_b) * 2.0
	var space_state := get_viewport().get_world_3d().direct_space_state
	var state := CableRopeSolver.create_state(
		anchor_a,
		anchor_b,
		rest_length,
		Vector3.UP,
		space_state
	)
	for _step: int in range(300):
		CableRopeSolver.step(
			state,
			anchor_a,
			anchor_b,
			rest_length,
			Vector3(0.0, -1.62, 0.0),
			1.0 / 60.0,
			space_state
		)
		await get_tree().physics_frame
	var path := CableRopeSolver.path(state)
	if path.size() < CableRopeSolver.MIN_PARTICLES:
		root.queue_free()
		return _fail("rope must keep its particles")
	var lowest := INF
	var inside_obstacle := 0
	for point: Vector3 in path:
		lowest = minf(lowest, point.y)
		if (
			absf(point.x) < 0.45
			and absf(point.z) < 0.45
			and point.y < 1.9
		):
			inside_obstacle += 1
	if lowest < -CableRopeSolver.COLLISION_RADIUS:
		root.queue_free()
		return _fail(
			"slack rope sank through the floor, lowest y=%.3f" % lowest
		)
	if inside_obstacle > 0:
		root.queue_free()
		return _fail(
			"rope passed through the obstacle at %d points" % inside_obstacle
		)
	# It really did go slack rather than hanging straight between the anchors.
	if lowest > 1.9:
		root.queue_free()
		return _fail("slack rope did not drape at all, lowest y=%.3f" % lowest)
	root.queue_free()
	return await _test_rope_hangs_smooth()


## No accordions. Distance constraints alone are perfectly happy with a rope
## folded back on itself, and lunar gravity is far too weak to shake a crease
## out — so a moving anchor used to leave a permanent zigzag. Every joint must
## stay open: neighbours no closer than half of two straight segments.
func _test_rope_hangs_smooth() -> bool:
	var anchor_a := Vector3(-3.0, 3.0, 0.0)
	var anchor_b := Vector3(3.0, 3.0, 0.0)
	var rest_length := anchor_a.distance_to(anchor_b) * 1.35
	var state := CableRopeSolver.create_state(
		anchor_a,
		anchor_b,
		rest_length,
		Vector3.UP
	)
	var gravity := Vector3(0.0, -1.62, 0.0)
	for step: int in range(240):
		# Jog the free end every few frames: a rope only creases when it is
		# being moved, which is exactly the case that used to look broken.
		var wobble := Vector3(sin(float(step) * 0.3) * 0.35, 0.0, 0.0)
		CableRopeSolver.step(
			state,
			anchor_a,
			anchor_b + wobble,
			rest_length,
			gravity,
			1.0 / 60.0,
			null
		)
	# A hard resize mid-flight — the aim jumping from a near wall to distant
	# terrain changes both the span and the particle count at once. The rope may
	# lurch; what it may not do is stay creased. A second and a half is the
	# honest budget: under 1.62 m/s² a rope with 2x slack physically needs that
	# long to hang its extra length out, and until it has, a gathered rope and a
	# folded one look the same to this metric.
	var jumped_end := anchor_b + Vector3(6.0, 0.0, 0.0)
	var jumped_rest := rest_length * 1.9
	for _recover: int in range(90):
		CableRopeSolver.step(
			state,
			anchor_a,
			jumped_end,
			jumped_rest,
			gravity,
			1.0 / 60.0,
			null
		)
	var path := CableRopeSolver.path(state)
	var segment_rest := jumped_rest / float(path.size() - 1)
	var sharpest := INF
	for index: int in range(1, path.size() - 1):
		sharpest = minf(
			sharpest,
			path[index + 1].distance_to(path[index - 1])
		)
	if sharpest < segment_rest:
		return _fail(
			"rope folded into an accordion: tightest joint spans %.3f m of %.3f m"
			% [sharpest, 2.0 * segment_rest]
		)
	return true


## The case a chain of spheres cannot pass: a beam thinner than the particle
## spacing. Point collision lets the gap between two particles swallow it whole
## and the rope saws straight through; only a capsule over the whole segment
## sees it. Sampled at midpoints, which is exactly where the old solver failed.
func _test_rope_does_not_saw_through_a_thin_beam() -> bool:
	var root := Node3D.new()
	add_child(root)
	var beam := StaticBody3D.new()
	beam.collision_layer = 1
	beam.collision_mask = 0
	var beam_shape := CollisionShape3D.new()
	var beam_box := BoxShape3D.new()
	# 18 cm thick — a quarter of the particle spacing.
	beam_box.size = Vector3(6.0, 0.18, 0.18)
	beam_shape.shape = beam_box
	beam.add_child(beam_shape)
	root.add_child(beam)
	beam.global_position = Vector3(0.0, 1.0, 0.0)
	await get_tree().physics_frame
	var anchor_a := Vector3(0.0, 2.0, -2.5)
	var anchor_b := Vector3(0.0, 2.0, 2.5)
	var rest_length := anchor_a.distance_to(anchor_b) * 1.5
	var space_state := get_viewport().get_world_3d().direct_space_state
	var state := CableRopeSolver.create_state(
		anchor_a,
		anchor_b,
		rest_length,
		Vector3.UP,
		space_state
	)
	for _step: int in range(240):
		CableRopeSolver.step(
			state,
			anchor_a,
			anchor_b,
			rest_length,
			Vector3(0.0, -1.62, 0.0),
			1.0 / 60.0,
			space_state
		)
		await get_tree().physics_frame
	var path := CableRopeSolver.path(state)
	# Inside the beam, not merely below it: a rope draped over a thin beam has
	# both tails hanging past its sides, and that is the correct shape.
	var inside := 0
	var deepest := 0.0
	for index: int in range(path.size() - 1):
		for sample: float in [0.0, 0.2, 0.4, 0.6, 0.8]:
			var point := path[index].lerp(path[index + 1], sample)
			var into_z := 0.09 - absf(point.z)
			var into_y := 0.09 - absf(point.y - 1.0)
			if into_z > 0.0 and into_y > 0.0:
				inside += 1
				deepest = maxf(deepest, minf(into_z, into_y))
	if inside > 0:
		root.queue_free()
		return _fail(
			"rope inside the beam at %d points, %.3f m deep" % [inside, deepest]
		)
	root.queue_free()
	return true


## The seed curve is drawn between the anchors knowing nothing about what is in
## the way, so a rope tied from one side of a block to the other used to be born
## straight through it — and a particle that starts inside cannot be rescued: it
## shakes about until the depenetration happens to spit it out of the far face.
## Nothing between the anchors may start inside solid matter, and it must stay
## out afterwards.
func _test_rope_is_never_born_inside_geometry() -> bool:
	var root := Node3D.new()
	add_child(root)
	var block := StaticBody3D.new()
	block.collision_layer = 1
	block.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.5, 2.5, 2.5)
	shape.shape = box
	block.add_child(shape)
	root.add_child(block)
	block.global_position = Vector3(0.0, 1.25, 0.0)
	await get_tree().physics_frame
	# Anchors on opposite faces at mid-height: the straight line between them
	# runs through the middle of the block, which is the case that broke.
	var anchor_a := Vector3(-2.2, 1.25, 0.0)
	var anchor_b := Vector3(2.2, 1.25, 0.0)
	var rest_length := anchor_a.distance_to(anchor_b) * 1.2
	var space_state := get_viewport().get_world_3d().direct_space_state
	var state := CableRopeSolver.create_state(
		anchor_a,
		anchor_b,
		rest_length,
		Vector3.UP,
		space_state
	)
	var born_inside := _rope_points_inside_block(
		CableRopeSolver.path(state), 1.25, 1.25
	)
	if born_inside > 0:
		root.queue_free()
		return _fail(
			"rope seeded inside the block at %d points" % born_inside
		)
	for _step: int in range(180):
		CableRopeSolver.step(
			state,
			anchor_a,
			anchor_b,
			rest_length,
			Vector3(0.0, -1.62, 0.0),
			1.0 / 60.0,
			space_state
		)
		await get_tree().physics_frame
	var settled_inside := _rope_points_inside_block(
		CableRopeSolver.path(state), 1.25, 1.25
	)
	root.queue_free()
	if settled_inside > 0:
		return _fail(
			"rope ended up inside the block at %d points" % settled_inside
		)
	return true


## Particles strictly inside an origin-centred box of the given half extents
## (the block sits at y = half_height, so its interior is 0 < y < 2·half).
func _rope_points_inside_block(
	path: PackedVector3Array,
	half_width: float,
	half_height: float
) -> int:
	var inside := 0
	# A hair of tolerance: a particle correctly seated ON a face sits one
	# rope radius clear of it, so anything this far in is genuinely buried.
	var margin := 0.02
	for point: Vector3 in path:
		if (
			absf(point.x) < half_width - margin
			and absf(point.z) < half_width - margin
			and point.y > margin
			and point.y < half_height * 2.0 - margin
		):
			inside += 1
	return inside


## Adaptive belongs in the mesh, not in the simulation: the drawn spline must
## get dense where the rope turns and stay cheap where it runs straight, off
## the same uniform particles the solver uses.
func _test_render_spline_subdivides_where_it_bends() -> bool:
	var straight := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 0.0),
		Vector3(3.0, 0.0, 0.0),
		Vector3(4.0, 0.0, 0.0),
	])
	var elbow := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 0.0),
		Vector3(2.0, -1.0, 0.0),
		Vector3(2.0, -2.0, 0.0),
	])
	var straight_points := CableCurveUtil.smooth_adaptive(straight).size()
	var elbow_points := CableCurveUtil.smooth_adaptive(elbow).size()
	if straight_points != straight.size():
		return _fail(
			"a straight rope must not be subdivided, got %d points from %d"
			% [straight_points, straight.size()]
		)
	if elbow_points <= straight_points * 2:
		return _fail(
			"a bent rope must be subdivided, got %d points vs %d straight"
			% [elbow_points, straight_points]
		)
	# The extra points have to be AT the bend, not spread evenly.
	var smoothed := CableCurveUtil.smooth_adaptive(elbow)
	var near_corner := 0
	for point: Vector3 in smoothed:
		if point.distance_to(Vector3(2.0, 0.0, 0.0)) < 1.1:
			near_corner += 1
	if near_corner < smoothed.size() / 2:
		return _fail(
			"subdivision did not concentrate at the corner: %d of %d points"
			% [near_corner, smoothed.size()]
		)
	return true


## A rope between two still anchors has to actually stop. A verlet rope has no
## exact rest state — every pass leaves a fraction of a millimetre somewhere —
## so without a dead zone and a sleep it twitches for the rest of the session,
## which is precisely how it looked in play.
func _test_rope_settles_and_stays_still() -> bool:
	var anchor_a := Vector3(-3.0, 3.0, 0.0)
	var anchor_b := Vector3(3.0, 3.0, 0.0)
	var rest_length := anchor_a.distance_to(anchor_b) * 1.2
	var gravity := Vector3(0.0, -1.62, 0.0)
	var state := CableRopeSolver.create_state(
		anchor_a,
		anchor_b,
		rest_length,
		Vector3.UP
	)
	for _settle: int in range(600):
		CableRopeSolver.step(
			state,
			anchor_a,
			anchor_b,
			rest_length,
			gravity,
			1.0 / 60.0,
			null
		)
	var before := CableRopeSolver.path(state).duplicate()
	for _idle: int in range(120):
		CableRopeSolver.step(
			state,
			anchor_a,
			anchor_b,
			rest_length,
			gravity,
			1.0 / 60.0,
			null
		)
	var after := CableRopeSolver.path(state)
	var drift := 0.0
	for index: int in range(mini(before.size(), after.size())):
		drift = maxf(drift, before[index].distance_to(after[index]))
	if drift > 0.001:
		return _fail(
			"settled rope kept moving: %.4f m over two idle seconds" % drift
		)
	# And it must wake the moment an anchor moves.
	CableRopeSolver.step(
		state,
		anchor_a,
		anchor_b + Vector3(0.5, 0.0, 0.0),
		rest_length,
		gravity,
		1.0 / 60.0,
		null
	)
	var woken := CableRopeSolver.path(state)
	if woken[woken.size() - 1].distance_to(anchor_b) < 0.4:
		return _fail("rope stayed asleep when its anchor moved")
	return true


## Weight is read from behaviour, not from a mass number: in a rigid-constraint
## verlet rope the particle mass cancels out entirely, so "heavier" has to mean
## falls decisively and stops rippling. A jolted cable must lose most of its
## wobble within a second, and the ripple must die faster than the swing — that
## difference is what separates cable from cloth.
func _test_cable_damps_ripple_faster_than_swing() -> bool:
	var anchor_a := Vector3(-3.0, 3.0, 0.0)
	var anchor_b := Vector3(3.0, 3.0, 0.0)
	var rest_length := anchor_a.distance_to(anchor_b) * 1.25
	var gravity := Vector3(0.0, -1.62, 0.0)
	var state := CableRopeSolver.create_state(
		anchor_a,
		anchor_b,
		rest_length,
		Vector3.UP
	)
	for _settle: int in range(400):
		CableRopeSolver.step(
			state, anchor_a, anchor_b, rest_length, gravity, 1.0 / 60.0, null
		)
	# Kick every other particle sideways: pure ripple, no net swing.
	var positions := CableRopeSolver.path(state)
	var kicked := positions.duplicate()
	for index: int in range(1, kicked.size() - 1):
		kicked[index] += Vector3(0.0, 0.0, 0.25 if index % 2 == 0 else -0.25)
	state["positions"] = kicked
	state["quiescent_ticks"] = 0
	var ripple_start := _rope_ripple(CableRopeSolver.path(state))
	for _tick: int in range(60):
		CableRopeSolver.step(
			state, anchor_a, anchor_b, rest_length, gravity, 1.0 / 60.0, null
		)
	var ripple_end := _rope_ripple(CableRopeSolver.path(state))
	if ripple_end > ripple_start * 0.25:
		return _fail(
			"cable keeps flapping: ripple %.4f of %.4f after a second"
			% [ripple_end, ripple_start]
		)
	return true


## How much the rope zig-zags against its own local direction — the measure of
## flapping, as opposed to the rope swinging as a whole.
func _rope_ripple(path: PackedVector3Array) -> float:
	var ripple := 0.0
	for index: int in range(1, path.size() - 1):
		var chord := (path[index - 1] + path[index + 1]) * 0.5
		ripple += path[index].distance_to(chord)
	return ripple


## The rover-launch contract. Two ways a rope used to turn a routine cut into a
## catastrophe, both fixed here, both checked by watching the body: it must not
## gain velocity from either.
func _test_rope_cannot_launch_a_body() -> bool:
	var root := Node3D.new()
	add_child(root)
	var rover := RigidBody3D.new()
	rover.mass = 3000.0
	rover.gravity_scale = 0.0
	# No engine damping: any velocity change in this test must be the rope's.
	# REPLACE, not the default COMBINE — otherwise the project-wide default
	# damping is added on top of the zero and the body still bleeds speed.
	rover.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	rover.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	rover.linear_damp = 0.0
	rover.angular_damp = 0.0
	root.add_child(rover)
	rover.global_position = Vector3(20.0, 0.0, 0.0)
	rover.linear_velocity = Vector3(40.0, 0.0, 0.0)
	await get_tree().physics_frame
	# 1. Over the break threshold the rope must snap INSTEAD of pulling. It used
	# to pull first and break after, so the tick that broke it hit hardest.
	var speed_before := rover.linear_velocity
	var tension := CableTensionUtil.solve(
		Vector3.ZERO,
		null,
		rover.global_position,
		rover,
		10.0,
		1.0 / 60.0
	)
	await get_tree().physics_frame
	if tension <= CableTensionUtil.break_force_n(0.0):
		root.queue_free()
		return _fail("3 t at 40 m/s on a 10 m rope must be over the limit")
	if not rover.linear_velocity.is_equal_approx(speed_before):
		root.queue_free()
		return _fail(
			"a rope past its breaking force must not pull first: %s vs %s"
			% [rover.linear_velocity, speed_before]
		)
	# 2. An anchor that resolves nowhere near its body — a split child whose
	# motion has not been seeded resolves near the world origin — must be
	# ignored, not turned into an impulse at a kilometre-long lever arm.
	var spinner := RigidBody3D.new()
	spinner.mass = 3000.0
	spinner.gravity_scale = 0.0
	spinner.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	spinner.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	spinner.linear_damp = 0.0
	spinner.angular_damp = 0.0
	root.add_child(spinner)
	spinner.global_position = Vector3(0.0, 0.0, 0.0)
	spinner.angular_velocity = Vector3(0.0, 2.0, 0.0)
	await get_tree().physics_frame
	var spin_before := spinner.linear_velocity
	CableTensionUtil.solve(
		Vector3(9500.0, 0.0, 0.0),
		null,
		Vector3(9500.0, 0.0, 0.0),
		spinner,
		10.0,
		1.0 / 60.0
	)
	await get_tree().physics_frame
	if not spinner.linear_velocity.is_equal_approx(spin_before):
		root.queue_free()
		return _fail(
			"rope acted on an anchor 9.5 km from its body: %s"
			% spinner.linear_velocity
		)
	root.queue_free()
	return true


func _fail(reason: String) -> bool:
	print("KERNEL-PROJECTION-V0: FAIL %s" % reason)
	get_tree().quit(1)
	return false
