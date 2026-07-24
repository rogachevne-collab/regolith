extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless gate for COOP-HOST-V0 stage 2: SimulationWorld as read-only
## replica. Covers snapshot round-trip identity, replica no-drift under gated
## ticks, C1 mutation refusal, restore idempotence and an inert kinematic
## physics projection on replica worlds.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "COOP-REPLICA-V0")
	PlayerIdentity.override_local_uid("player")
	if not _test_roundtrip_identity():
		_abort()
		return
	if not _test_replica_no_drift():
		_abort()
		return
	if not _test_replica_rejects_mutation():
		_abort()
		return
	if not _test_restore_idempotent():
		_abort()
		return
	if not await _test_replica_projection_inert():
		_abort()
		return
	print("COOP-REPLICA-V0: PASS")
	get_tree().quit(0)


## Authoritative fixture: anchored assembly with a welded frame and a driven
## piston (non-default motor state), industry runtime flags, a renamed
## element, a hurt suit and a loot pile. Built authoritative on purpose — the
## build helper drives apply_structural_command_now, which replicas refuse.
func _build_rich_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	# The piston head auto-spawns from the registry when the base is placed.
	world.get_archetype_registry().register(Slice01Archetypes.piston_head())
	var helper := AssemblyBuildHelper.new(
		world,
		PlayerIdentity.store_id("player")
	)
	helper.ensure_materials(500.0)
	if not helper.spawn_anchor(Slice01Archetypes.foundation()):
		push_error("fixture anchor failed: %s" % helper.last_error)
		world.free()
		return null
	if not helper.place(Slice01Archetypes.frame(), Vector3i(4, 0, 0), 0, "frame"):
		push_error("fixture frame failed: %s" % helper.last_error)
		world.free()
		return null
	if not helper.place(
		Slice01Archetypes.piston_base(),
		Vector3i(5, 0, 0),
		0,
		"piston"
	):
		push_error("fixture piston failed: %s" % helper.last_error)
		world.free()
		return null
	helper.weld_all()
	var joint_id := int(helper.element_ids.get("piston_joint", 0))
	if joint_id <= 0:
		push_error("fixture piston joint missing")
		world.free()
		return null
	var target := SetActuatorTargetCommand.new()
	target.joint_id = joint_id
	target.mode = SimulationMotorState.ControlMode.POSITION
	target.target_position_m = 1.0
	world.apply_set_actuator_target(target)
	world.sync_actuator_observation(joint_id, 0.5, 0.1, 1200.0, false)
	var runtime := world.ensure_industry_element_runtime(
		int(helper.element_ids["piston"])
	)
	runtime.machine_enabled = true
	runtime.powered = true
	var rename := SetElementNameCommand.new()
	rename.element_id = int(helper.element_ids["frame"])
	rename.element_name = "replica-frame"
	world.apply_set_element_name(rename)
	world.ensure_suit_state("p1")
	world.apply_suit_damage("p1", 10.0)
	world.add_world_loot_pile(Vector3(1.0, 0.0, 1.0), "ore_mare_regolith", 12.5)
	return world


func _make_replica(snapshot: Dictionary) -> SimulationWorld:
	var replica := SimulationWorld.new()
	replica.authoritative = false
	if not replica.restore_snapshot(snapshot):
		push_error(
			"replica restore failed: %s" % SimulationSnapshot.last_validate_error
		)
		replica.free()
		return null
	return replica


## A place command that is structurally valid against the fixture world (the
## host control in _test_replica_rejects_mutation proves it), so a replica
## refusal below can only come from the authoritative gate.
func _frame_place_command(world: SimulationWorld) -> PlaceElementCommand:
	var assemblies: Array = world.list_assemblies()
	if assemblies.is_empty():
		return null
	var assembly: SimulationAssembly = assemblies[0]
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly.assembly_id
	place.expected_assembly_revision = assembly.topology_revision
	place.archetype = Slice01Archetypes.frame()
	# Sideways off the frame, away from the piston head: a cell adjacent to
	# both base- and head-side structure would trip driven_joint_cycle.
	place.origin_cell = Vector3i(4, 0, 1)
	place.orientation_index = 0
	place.store_id = PlayerIdentity.store_id("player")
	return place


func _test_roundtrip_identity() -> bool:
	var world := _build_rich_world()
	if world == null:
		return _fail("fixture failed")
	var snapshot := world.capture_snapshot()
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(
		snapshot
	)
	if restored == null:
		world.free()
		return _fail(
			"create_from_snapshot failed: %s"
			% SimulationSnapshot.last_validate_error
		)
	var equal := SimulationSnapshot.semantic_equals(
		snapshot,
		restored.capture_snapshot()
	)
	restored.free()
	world.free()
	if not equal:
		return _fail("restored world snapshot differs from source")
	return true


func _test_replica_no_drift() -> bool:
	var world := _build_rich_world()
	if world == null:
		return _fail("fixture failed")
	var snapshot := world.capture_snapshot()
	# Sensitivity control: the same tick must move an authoritative world,
	# otherwise "no drift" below would prove nothing.
	world.tick_suits(30.0)
	var host_moved := not SimulationSnapshot.semantic_equals(
		snapshot,
		world.capture_snapshot()
	)
	world.free()
	if not host_moved:
		return _fail("sensitivity control: tick_suits moved nothing on host")
	var replica := _make_replica(snapshot)
	if replica == null:
		return _fail("replica restore failed")
	var baseline := replica.capture_snapshot()
	# Expected push_errors below: the gate screams on purpose (invariant C1).
	replica.tick_suits(30.0)
	replica.tick_actuators(0.5)
	replica.industry_tick(1.0)
	replica.advance_industry_time(60.0)
	if replica.submit_structural_command(_frame_place_command(replica)) != 0:
		replica.free()
		return _fail("replica queued a structural command")
	var same := SimulationSnapshot.semantic_equals(
		baseline,
		replica.capture_snapshot()
	)
	replica.free()
	if not same:
		return _fail("replica drifted after gated ticks")
	return true


func _test_replica_rejects_mutation() -> bool:
	var world := _build_rich_world()
	if world == null:
		return _fail("fixture failed")
	var snapshot := world.capture_snapshot()
	# Host control: the very same command must succeed on an authoritative
	# world, so the replica refusal is attributable to the gate alone.
	var host_result := world.apply_structural_command_now(
		_frame_place_command(world)
	)
	world.free()
	if host_result == null or not host_result.is_ok():
		return _fail(
			"control place failed on host: %s"
			% (host_result.reason if host_result != null else &"null")
		)
	var replica := _make_replica(snapshot)
	if replica == null:
		return _fail("replica restore failed")
	var baseline := replica.capture_snapshot()
	var result := replica.apply_structural_command_now(
		_frame_place_command(replica)
	)
	if result == null or result.is_ok():
		replica.free()
		return _fail("replica accepted a structural command")
	if result.reason != StructuralCommandResult.REASON_NOT_AUTHORITATIVE:
		replica.free()
		return _fail("replica refusal reason: %s" % result.reason)
	# Strict identity including allocator.next_command_id: the gate must sit
	# before command-id allocation.
	var same := SimulationSnapshot.semantic_equals(
		baseline,
		replica.capture_snapshot()
	)
	replica.free()
	if not same:
		return _fail("refused command still changed the replica")
	return true


func _test_restore_idempotent() -> bool:
	var world := _build_rich_world()
	if world == null:
		return _fail("fixture failed")
	var snapshot := world.capture_snapshot()
	world.free()
	# Restore into an already-populated world (the future join path), flipped
	# to replica before the apply — restore stays sanctioned on replicas.
	var other := SimulationWorld.new()
	var helper := AssemblyBuildHelper.new(
		other,
		PlayerIdentity.store_id("player")
	)
	helper.ensure_materials(100.0)
	if not helper.spawn_anchor(Slice01Archetypes.frame()):
		other.free()
		return _fail("second fixture failed: %s" % helper.last_error)
	other.authoritative = false
	if not other.restore_snapshot(snapshot):
		other.free()
		return _fail(
			"restore into populated world failed: %s"
			% SimulationSnapshot.last_validate_error
		)
	if not SimulationSnapshot.semantic_equals(
		snapshot,
		other.capture_snapshot()
	):
		other.free()
		return _fail("restore into populated world diverged")
	if not other.restore_snapshot(snapshot):
		other.free()
		return _fail("second restore failed")
	var same := SimulationSnapshot.semantic_equals(
		snapshot,
		other.capture_snapshot()
	)
	other.free()
	if not same:
		return _fail("second restore of the same snapshot diverged")
	return true


func _test_replica_projection_inert() -> bool:
	var world := _build_rich_world()
	if world == null:
		return _fail("fixture failed")
	var snapshot := world.capture_snapshot()
	world.free()
	var replica := _make_replica(snapshot)
	if replica == null:
		return _fail("replica restore failed")
	add_child(replica)
	var projection := SimulationPhysicsProjection.new()
	add_child(projection)
	projection.bind_world(replica)
	projection.rebuild_all()
	# Baseline is taken after the rebuild on purpose: projection lazily
	# inserts default locomotion rows (host projection does the identical
	# insertion), and the drift check below compares replica to replica.
	var baseline := replica.capture_snapshot()
	for assembly: SimulationAssembly in replica.list_assemblies():
		if assembly.tombstoned:
			continue
		var bodies: Array[PhysicsBody3D] = (
			projection.list_assembly_physics_bodies(assembly.assembly_id)
		)
		var single := projection.get_physics_body(assembly.assembly_id)
		if single != null and not bodies.has(single):
			bodies.append(single)
		if bodies.is_empty():
			_cleanup_projection(projection, replica)
			return _fail(
				"replica assembly %d projected no bodies" % assembly.assembly_id
			)
		for body: PhysicsBody3D in bodies:
			if not (body is RigidBody3D):
				continue
			var rigid := body as RigidBody3D
			if not rigid.freeze:
				_cleanup_projection(projection, replica)
				return _fail("replica rigid body is not frozen")
			if rigid.freeze_mode != RigidBody3D.FREEZE_MODE_KINEMATIC:
				_cleanup_projection(projection, replica)
				return _fail("replica rigid body is not kinematic")
		if not projection.list_piston_constraint_records(
			assembly.assembly_id
		).is_empty():
			_cleanup_projection(projection, replica)
			return _fail("replica projected piston constraints")
	for _i: int in range(10):
		await get_tree().physics_frame
	await get_tree().process_frame
	var same := SimulationSnapshot.semantic_equals(
		baseline,
		replica.capture_snapshot()
	)
	_cleanup_projection(projection, replica)
	if not same:
		return _fail("replica drifted under live physics frames")
	return true


func _cleanup_projection(
	projection: SimulationPhysicsProjection,
	replica: SimulationWorld
) -> void:
	projection.queue_free()
	replica.queue_free()


func _fail(message: String) -> bool:
	push_error(message)
	print("COOP-REPLICA-V0: FAIL — %s" % message)
	return false


func _abort() -> void:
	get_tree().quit(1)
