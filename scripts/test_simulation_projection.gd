extends Node


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
		Vector3(1.1, 0.0, 0.0)
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
		Vector3.RIGHT + position_error
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
	a_frame.translation = Vector3i.LEFT
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
	var command: MergeAssembliesCommand = (
		SimulationMergeGateway.merge_command(
			world,
			a_id,
			b_id,
			int(a.data["element_ids"][0]),
			"structural_0_0_0_px",
			int(b.data["element_ids"][0]),
			"structural_0_0_0_nx"
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
	b_frame.translation = Vector3i.RIGHT
	var b: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		b_frame
	)
	var command: MergeAssembliesCommand = (
		SimulationMergeGateway.merge_command(
			world,
			int(a.data["assembly_id"]),
			int(b.data["assembly_id"]),
			int(a.data["element_ids"][0]),
			"structural_0_0_0_px",
			int(b.data["element_ids"][0]),
			"structural_0_0_0_nx"
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
	return SimulationMergeGateway.merge_command(
		world,
		int(a.data["assembly_id"]),
		int(b.data["assembly_id"]),
		int(a.data["element_ids"][0]),
		"structural_0_0_0_px",
		int(b.data["element_ids"][0]),
		"structural_0_0_0_nx"
	)


func _raw_merge(
	world: SimulationWorld,
	a: StructuralCommandResult,
	b: StructuralCommandResult
) -> MergeAssembliesCommand:
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
	command.port_a_id = "structural_0_0_0_px"
	command.element_b_id = int(b.data["element_ids"][0])
	command.port_b_id = "structural_0_0_0_nx"
	return command


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
