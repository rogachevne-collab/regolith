extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
const FIXTURE := preload(
	"res://resources/blueprints/baked/kernel_fixture_valid.tres"
)
const CUSTOM := preload(
	"res://resources/archetypes/runtime_custom.tres"
)

var _queued_completion_ids: Array[int] = []
var _queued_completion_results: Array[StructuralCommandResult] = []


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "KERNEL-RUNTIME-V0")
	var tests: Array[Callable] = [
		_test_typed_spawn_and_unique_ids,
		_test_grid_transform_roundtrip,
		_test_deterministic_joints_and_stale_atomicity,
		_test_split_policy_and_runtime_state,
		_test_merge_a_wins_preserves_identity,
		_test_merge_b_wins_fixed_endpoint_order,
		_test_rotated_frame_derivation,
		_test_dual_anchor_and_rejections,
		_test_split_reconciles_ground_anchors,
		_test_placement_anchors_every_touching_block,
		_test_dismantle_support_pole_drops_elevated_structure,
		_test_custom_archetype_snapshot_restore,
		_test_unified_grid_edge_surface_joint,
		_test_unified_grid_middle_surface_joint,
		_test_unified_grid_mount_pad_policy,
		_test_unified_grid_descriptor_cache,
		_test_unified_grid_full_surface_contact_count,
		_test_snapshot_canonical_joint_roundtrip,
		_test_legacy_snapshot_version_rejected,
		_test_malformed_snapshot_atomicity,
		_test_archetype_conflict_and_allocator_continuity,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	if not await _test_typed_queued_completion():
		return
	print("KERNEL-RUNTIME-V0: PASS")
	get_tree().quit(0)


func _test_typed_spawn_and_unique_ids() -> bool:
	var world := SimulationWorld.new()
	var first := _spawn(world, FIXTURE, GridTransform.identity())
	var second_frame := GridTransform.new()
	second_frame.translation = Vector3i(10, 0, 0)
	var second := _spawn(world, FIXTURE, second_frame)
	if not first.is_ok() or not second.is_ok():
		return _fail("typed Blueprint spawn failed")
	if first.data["assembly_id"] == second.data["assembly_id"]:
		return _fail("duplicate spawn reused AssemblyId")
	for element_id: int in first.data["element_ids"]:
		if second.data["element_ids"].has(element_id):
			return _fail("duplicate spawn reused ElementId")
	var mapping: Dictionary = first.data["local_to_element_id"]
	for local_id: String in ["foundation_0", "frame_0", "beam_0"]:
		if not mapping.has(local_id):
			return _fail("spawn mapping missing %s" % local_id)
		if world.get_element(int(mapping[local_id])) == null:
			return _fail("mapped element does not exist")
	world.free()
	return true


func _test_grid_transform_roundtrip() -> bool:
	for orientation: int in range(OrientationUtil.ORIENTATION_COUNT):
		var transform := GridTransform.new()
		transform.translation = Vector3i(3, -2, 5)
		transform.orientation_index = orientation
		var inverse := transform.inverse()
		if not transform.compose(inverse).equals(GridTransform.identity()):
			return _fail("grid transform inverse failed at %d" % orientation)
		var cell := Vector3i(2, 1, -3)
		if inverse.map_cell(transform.map_cell(cell)) != cell:
			return _fail("grid cell roundtrip failed")
	return true


func _test_deterministic_joints_and_stale_atomicity() -> bool:
	var first := SimulationWorld.new()
	var second := SimulationWorld.new()
	_spawn(first, FIXTURE, GridTransform.identity())
	_spawn(second, FIXTURE, GridTransform.identity())
	if _joint_keys(first) != _joint_keys(second):
		return _fail("materialized joints are not deterministic")
	var joint_id := _first_rigid_joint(first)
	var assembly := first.list_assemblies()[0]
	var before := first.capture_snapshot()
	var before_allocator := first.get_allocator().to_dict()
	var command := BreakRigidJointCommand.new()
	command.joint_id = joint_id
	command.expected_assembly_revision = assembly.topology_revision + 1
	var result := first.apply_structural_command_now(command)
	if result.reason != StructuralCommandResult.REASON_STALE_REVISION:
		return _fail("stale command was not rejected")
	var after_allocator := first.get_allocator().to_dict()
	for key: String in ["next_element_id", "next_assembly_id", "next_joint_id"]:
		if before_allocator[key] != after_allocator[key]:
			return _fail("failed command consumed topology ID")
	if not SimulationSnapshot.semantic_equals(before, first.capture_snapshot()):
		# Command IDs are journal state and are allowed to advance.
		var normalized := first.capture_snapshot()
		normalized["allocator"]["next_command_id"] = before["allocator"]["next_command_id"]
		if not SimulationSnapshot.semantic_equals(before, normalized):
			return _fail("stale command mutated topology")
	first.free()
	second.free()
	return true


func _test_split_policy_and_runtime_state() -> bool:
	var world := SimulationWorld.new()
	var result := _spawn(
		world,
		_chain_blueprint(4),
		GridTransform.identity()
	)
	if not result.is_ok():
		return _fail("chain spawn failed")
	var ids: Array = result.data["element_ids"]
	var left_object := world.get_element(int(ids[0]))
	left_object.build_progress = 0.4
	left_object.integrity = 17.0
	left_object.condition = 0.8
	var center_joint := _joint_between(world, int(ids[1]), int(ids[2]))
	var command := BreakRigidJointCommand.new()
	command.joint_id = center_joint
	command.expected_assembly_revision = int(result.data["topology_revision"])
	var split := world.apply_structural_command_now(command)
	if not split.is_ok() or not split.data["split"]:
		return _fail("equal split failed")
	var survivor := world.get_assembly(int(split.data["survivor_assembly_id"]))
	if not survivor.element_ids.has(int(ids[0])):
		return _fail("split tie did not choose lowest ElementId")
	if world.get_element(int(ids[0])) != left_object:
		return _fail("split replaced element object")
	if (
		left_object.build_progress != 0.4
		or left_object.integrity != 17.0
		or left_object.condition != 0.8
	):
		return _fail("split lost runtime element state")
	world.free()
	return true


func _test_merge_a_wins_preserves_identity() -> bool:
	var world := SimulationWorld.new()
	var a := _spawn(world, _foundation_frame_blueprint(), GridTransform.identity())
	var b_frame := GridTransform.new()
	b_frame.translation = Vector3i(5, 0, 1)
	var b := _spawn(world, _single_blueprint(Slice01Archetypes.frame()), b_frame)
	var a_element := world.get_element(
		int(a.data["local_to_element_id"]["frame_0"])
	)
	var b_element := world.get_element(
		int(b.data["local_to_element_id"]["element_0"])
	)
	b_element.build_progress = 0.3
	b_element.integrity = 11.0
	b_element.condition = 0.6
	var connection := _merge_connection_ports(
		world,
		int(a.data["assembly_id"]),
		int(b.data["assembly_id"]),
		a_element.element_id,
		b_element.element_id
	)
	var merge := _merge(
		world,
		a,
		b,
		a_element.element_id,
		connection["left_port_id"],
		b_element.element_id,
		connection["right_port_id"]
	)
	if not merge.is_ok() or merge.data["survivor_assembly_id"] != a.data["assembly_id"]:
		return _fail("A-wins automatic merge failed")
	if world.get_element(b_element.element_id) != b_element:
		return _fail("merge replaced loser element object")
	if (
		b_element.build_progress != 0.3
		or b_element.integrity != 11.0
		or b_element.condition != 0.6
	):
		return _fail("merge lost runtime element state")
	var raw_loser := world.get_assembly_raw(int(b.data["assembly_id"]))
	if raw_loser == null or not raw_loser.tombstoned:
		return _fail("raw loser lookup did not expose tombstone")
	if world.get_assembly(int(b.data["assembly_id"])).assembly_id != a.data["assembly_id"]:
		return _fail("canonical assembly lookup did not resolve redirect")
	world.free()
	return true


func _test_merge_b_wins_fixed_endpoint_order() -> bool:
	var world := SimulationWorld.new()
	var a_frame := GridTransform.new()
	a_frame.translation = Vector3i(-1, 0, 1)
	var a := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		a_frame
	)
	var b := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var a_id := int(a.data["element_ids"][0])
	var b_id := int(b.data["element_ids"][0])
	var connection := _merge_connection_ports(
		world,
		int(a.data["assembly_id"]),
		int(b.data["assembly_id"]),
		a_id,
		b_id
	)
	var merge := _merge(
		world,
		a,
		b,
		a_id,
		connection["left_port_id"],
		b_id,
		connection["right_port_id"]
	)
	if not merge.is_ok() or merge.data["survivor_assembly_id"] != b.data["assembly_id"]:
		return _fail("B-wins merge failed with fixed A/B endpoints")
	var bridge := world.get_joint(int(merge.data["bridge_joint_id"]))
	if bridge.element_a_id != a_id or bridge.element_b_id != b_id:
		return _fail("merge reordered A/B bridge endpoints")
	if world.get_element(a_id).origin_cell != Vector3i(-1, 0, 1):
		return _fail("B-wins merge used wrong inverse frame")
	world.free()
	return true


func _test_rotated_frame_derivation() -> bool:
	var orientation := _orientation_mapping(Vector3i.RIGHT, Vector3i.BACK)
	if orientation < 0:
		return _fail("required rotation missing")
	var a_frame := GridTransform.new()
	a_frame.translation = Vector3i(7, 2, -4)
	a_frame.orientation_index = orientation
	var b_frame := a_frame.duplicate_transform()
	b_frame.translation = a_frame.map_cell(Vector3i.RIGHT)
	var world := SimulationWorld.new()
	var a := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		a_frame
	)
	var b := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		b_frame
	)
	var a_id := int(a.data["element_ids"][0])
	var b_id := int(b.data["element_ids"][0])
	var connection := _merge_connection_ports(
		world,
		int(a.data["assembly_id"]),
		int(b.data["assembly_id"]),
		a_id,
		b_id
	)
	var merge := _merge(
		world,
		a,
		b,
		a_id,
		connection["left_port_id"],
		b_id,
		connection["right_port_id"]
	)
	if not merge.is_ok():
		return _fail("rotated/translated frame-derived merge failed")
	if world.get_element(int(b.data["element_ids"][0])).origin_cell != Vector3i.RIGHT:
		return _fail("relative transform was not derived from grid frames")
	world.free()
	return true


func _test_split_reconciles_ground_anchors() -> bool:
	var world := SimulationWorld.new()
	world.set_terrain_contact_probe(
		func(_assembly: SimulationAssembly, elements: Array[SimulationElement]) -> Array[int]:
			var touching: Array[int] = []
			for element: SimulationElement in elements:
				touching.append(element.element_id)
			return touching
	)
	var result := _spawn(
		world,
		_chain_blueprint(3),
		GridTransform.identity()
	)
	if not result.is_ok():
		return _fail("ground chain spawn failed")
	var ids: Array = result.data["element_ids"]
	var center_joint := _joint_between(world, int(ids[1]), int(ids[2]))
	var command := BreakRigidJointCommand.new()
	command.joint_id = center_joint
	command.expected_assembly_revision = int(result.data["topology_revision"])
	var split := world.apply_structural_command_now(command)
	if not split.is_ok() or not split.data["split"]:
		return _fail("ground anchor split failed")
	var survivor_id := int(split.data["survivor_assembly_id"])
	for assembly_id: int in [survivor_id] + split.data["new_assembly_ids"]:
		if not world.assembly_has_anchor(assembly_id):
			return _fail(
				"split assembly %d missing terrain anchor"
				% assembly_id
			)
	world.free()
	return true


func _test_placement_anchors_every_touching_block() -> bool:
	# Every block placed on terrain must anchor at placement, not just the first.
	# Otherwise the whole construction hangs off one anchor and detaching it frees
	# (and physically ejects) everything else.
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 100.0)
	world.set_terrain_contact_probe(
		func(_a: SimulationAssembly, elements: Array[SimulationElement]) -> Array[int]:
			var touching: Array[int] = []
			for element: SimulationElement in elements:
				touching.append(element.element_id)
			return touching
	)
	var first := _place_frame(world, 0, -1, Vector3i.ZERO, GridTransform.identity())
	if not first.is_ok():
		world.free()
		return _fail("first block placement failed")
	var assembly_id := int(first.data["assembly_id"])
	var first_id := int(first.data["element_id"])
	var second := _place_frame(
		world,
		assembly_id,
		int(first.data["topology_revision"]),
		Vector3i(1, 0, 0),
		GridTransform.identity()
	)
	if not second.is_ok():
		world.free()
		return _fail("second block placement failed")
	var second_id := int(second.data["element_id"])
	var second_element := world.get_element(second_id)
	if second_element == null or not second_element.terrain_contact:
		world.free()
		return _fail("placed block did not record terrain contact")
	if _anchor_for(world, second_id) == 0:
		world.free()
		return _fail("placed block on terrain was not anchored at placement")
	# Detaching the first (originally sole-anchored) block must leave the rest
	# anchored and static, never freed.
	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = first_id
	dismantle.expected_assembly_revision = (
		world.get_assembly_raw(assembly_id).topology_revision
	)
	dismantle.store_id = PlayerIdentity.store_id("player")
	var result := world.apply_structural_command_now(dismantle)
	if not result.is_ok():
		world.free()
		return _fail("dismantle of first block failed")
	if not world.assembly_has_anchor(assembly_id):
		world.free()
		return _fail("remaining construction lost its terrain anchor")
	world.free()
	return true


func _test_dismantle_support_pole_drops_elevated_structure() -> bool:
	# Reproduces the reported bug: a static structure built on top of a support
	# pole, where only the pole touches the ground. Dismantling the pole must
	# leave the elevated structure anchor-free (so it becomes a RigidBody3D and
	# falls), not stuck reporting an anchor it no longer physically has.
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 100.0)
	# Realistic probe: only the block at grid cell x==0 (the "pole") is actually
	# touching terrain. Everything built on top of it (x>0) is elevated and
	# must never be reported as touching ground.
	world.set_terrain_contact_probe(
		func(_a: SimulationAssembly, elements: Array[SimulationElement]) -> Array[int]:
			var touching: Array[int] = []
			for element: SimulationElement in elements:
				if element.origin_cell == Vector3i.ZERO:
					touching.append(element.element_id)
			return touching
	)
	var pole := _place_frame(world, 0, -1, Vector3i.ZERO, GridTransform.identity())
	if not pole.is_ok():
		world.free()
		return _fail("pole placement failed")
	var assembly_id := int(pole.data["assembly_id"])
	var pole_id := int(pole.data["element_id"])
	var structure := _place_frame(
		world,
		assembly_id,
		int(pole.data["topology_revision"]),
		Vector3i(1, 0, 0),
		GridTransform.identity()
	)
	if not structure.is_ok():
		world.free()
		return _fail("elevated structure placement failed")
	if not world.assembly_has_anchor(assembly_id):
		world.free()
		return _fail("assembly should start anchored via the pole")
	print("[ANCHOR-DBG] --- dismantling pole element=%d ---" % pole_id)
	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = pole_id
	dismantle.expected_assembly_revision = (
		world.get_assembly_raw(assembly_id).topology_revision
	)
	dismantle.store_id = PlayerIdentity.store_id("player")
	var result := world.apply_structural_command_now(dismantle)
	if not result.is_ok():
		world.free()
		return _fail("dismantle of pole failed")
	# The pole is gone; the surviving structure never touches ground per the
	# probe above. It must have lost its anchor.
	if world.assembly_has_anchor(assembly_id):
		world.free()
		return _fail(
			"BUG REPRODUCED: elevated structure still reports a terrain anchor "
			+ "after its support pole was dismantled -- it will stay static "
			+ "instead of falling"
		)
	world.free()
	return true


func _place_frame(
	world: SimulationWorld,
	assembly_id: int,
	expected_revision: int,
	origin_cell: Vector3i,
	grid_frame: GridTransform
) -> StructuralCommandResult:
	var command := PlaceElementCommand.new()
	command.assembly_id = assembly_id
	command.expected_assembly_revision = expected_revision
	command.archetype = Slice01Archetypes.frame()
	command.origin_cell = origin_cell
	command.orientation_index = 0
	command.new_assembly_grid_frame = grid_frame
	command.store_id = PlayerIdentity.store_id("player")
	return world.apply_structural_command_now(command)


func _test_dual_anchor_and_rejections() -> bool:
	var world := SimulationWorld.new()
	var a := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	var b_frame := GridTransform.new()
	b_frame.translation = Vector3i(4, 0, 0)
	var b := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		b_frame
	)
	var loser_anchor := _anchor_for(world, int(b.data["element_ids"][0]))
	var connection := _merge_connection_ports(
		world,
		int(a.data["assembly_id"]),
		int(b.data["assembly_id"]),
		int(a.data["element_ids"][0]),
		int(b.data["element_ids"][0])
	)
	var merge := _merge(
		world,
		a,
		b,
		int(a.data["element_ids"][0]),
		connection["left_port_id"],
		int(b.data["element_ids"][0]),
		connection["right_port_id"]
	)
	if not merge.is_ok() or not merge.data["removed_anchor_joint_ids"].has(loser_anchor):
		return _fail("dual-anchor merge did not remove loser Anchor")
	world.free()

	var reject_world := SimulationWorld.new()
	var left := _spawn(
		reject_world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	var overlap := _spawn(
		reject_world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	var overlap_result := _merge(
		reject_world,
		left,
		overlap,
		int(left.data["element_ids"][0]),
		"structural_0_0_0_px",
		int(overlap.data["element_ids"][0]),
		"structural_0_0_0_nx"
	)
	if overlap_result.reason != StructuralCommandResult.REASON_OVERLAP:
		return _fail("overlap merge was not rejected")
	var far_frame := GridTransform.new()
	far_frame.translation = Vector3i(3, 0, 0)
	var far := _spawn(
		reject_world,
		_single_blueprint(Slice01Archetypes.frame()),
		far_frame
	)
	var far_connection := _merge_connection_ports(
		reject_world,
		int(left.data["assembly_id"]),
		int(far.data["assembly_id"]),
		int(left.data["element_ids"][0]),
		int(far.data["element_ids"][0])
	)
	var incompatible := _merge(
		reject_world,
		left,
		far,
		int(left.data["element_ids"][0]),
		far_connection.get("left_port_id", "structural_0_0_0_px"),
		int(far.data["element_ids"][0]),
		far_connection.get("right_port_id", "structural_0_0_0_nx")
	)
	if incompatible.reason != StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION:
		return _fail("incompatible connection was not rejected")
	reject_world.free()
	return true


func _test_custom_archetype_snapshot_restore() -> bool:
	var world := SimulationWorld.new()
	var spawn := _spawn(
		world,
		_single_blueprint(CUSTOM),
		GridTransform.identity()
	)
	if not spawn.is_ok():
		return _fail("custom archetype outside Slice-01 failed to spawn")
	var element := world.get_element(int(spawn.data["element_ids"][0]))
	element.installed_materials = {"custom_component": 0.25}
	element.integrity = 9.0
	element.sync_build_progress_from_integrity()
	element.condition = 0.75
	var snapshot := world.capture_snapshot()
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(
		snapshot
	)
	if restored == null:
		return _fail("custom archetype snapshot failed restore")
	var restored_element: SimulationElement = restored.get_element(
		element.element_id
	)
	var expected_progress := 9.0 / CUSTOM.max_integrity
	if (
		restored_element.get_archetype() == null
		or restored_element.archetype_id != "runtime_custom"
		or not is_equal_approx(restored_element.build_progress, expected_progress)
		or restored_element.integrity != 9.0
		or restored_element.condition != 0.75
	):
		return _fail("custom archetype/runtime state did not restore")
	if not SimulationSnapshot.semantic_equals(
		snapshot,
		restored.capture_snapshot()
	):
		return _fail("snapshot canonical roundtrip changed semantics")
	world.free()
	restored.free()
	return true


func _test_unified_grid_edge_surface_joint() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 100.0)
	var large := _place_large_frame(world, Vector3i.ZERO, 0, -1)
	if not large.is_ok():
		world.free()
		return _fail("large_frame ground placement failed: %s" % large.reason)
	var assembly_id := int(large.data["assembly_id"])
	var large_id := int(large.data["element_id"])
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(large.data["topology_revision"])
	place.archetype = Slice01Archetypes.frame()
	place.origin_cell = Vector3i(5, 0, 0)
	place.orientation_index = 0
	place.store_id = PlayerIdentity.store_id("player")
	var placed := world.apply_structural_command_now(place)
	if not placed.is_ok():
		world.free()
		return _fail("edge surface placement failed")
	var joint_id := _joint_between(world, large_id, int(placed.data["element_id"]))
	var joint := world.get_joint(joint_id)
	if joint == null:
		world.free()
		return _fail("edge surface placement did not create rigid joint")
	var canonical := GridSurfaceUtil.find_rigid_connection(
		world.get_element(large_id),
		world.get_element(int(placed.data["element_id"]))
	)
	if (
		joint.port_a_id != canonical["left_port_id"]
		or joint.port_b_id != canonical["right_port_id"]
	):
		world.free()
		return _fail(
			"edge joint stored non-canonical derived IDs: %s/%s expected %s/%s"
			% [
				joint.port_a_id,
				joint.port_b_id,
				canonical["left_port_id"],
				canonical["right_port_id"],
			]
		)
	if (
		joint.port_a_id != "structural_4_0_0_px"
		or joint.port_b_id != "structural_0_0_0_nx"
	):
		world.free()
		return _fail("edge joint used center-only structural port IDs")
	if GridSurfaceUtil.count_matching_contact_faces(
		world.get_element(large_id),
		world.get_element(int(placed.data["element_id"]))
	) != 1:
		world.free()
		return _fail("edge placement should expose exactly one contact face")
	world.free()
	return true


func _test_unified_grid_middle_surface_joint() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 100.0)
	var large := _place_large_frame(world, Vector3i.ZERO, 0, -1)
	if not large.is_ok():
		world.free()
		return _fail("large_frame placement failed for middle joint")
	var assembly_id := int(large.data["assembly_id"])
	var large_id := int(large.data["element_id"])
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(large.data["topology_revision"])
	place.archetype = Slice01Archetypes.frame()
	place.origin_cell = Vector3i(5, 2, 0)
	place.orientation_index = 0
	place.store_id = PlayerIdentity.store_id("player")
	var placed := world.apply_structural_command_now(place)
	if not placed.is_ok():
		world.free()
		return _fail("middle surface placement failed")
	var joint := world.get_joint(
		_joint_between(world, large_id, int(placed.data["element_id"]))
	)
	if joint == null:
		world.free()
		return _fail("middle surface placement did not create rigid joint")
	var canonical := GridSurfaceUtil.find_rigid_connection(
		world.get_element(large_id),
		world.get_element(int(placed.data["element_id"]))
	)
	if (
		joint.port_a_id != canonical["left_port_id"]
		or joint.port_b_id != canonical["right_port_id"]
	):
		world.free()
		return _fail("middle joint stored non-canonical derived IDs")
	if (
		joint.port_a_id != "structural_4_2_0_px"
		or joint.port_b_id != "structural_0_0_0_nx"
	):
		world.free()
		return _fail("middle joint used unexpected derived port IDs")
	world.free()
	return true


func _test_unified_grid_mount_pad_policy() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 100.0)
	var store := PlaceElementCommand.new()
	store.assembly_id = 0
	store.expected_assembly_revision = -1
	store.archetype = Slice01Archetypes.cargo_store()
	store.origin_cell = Vector3i.ZERO
	store.orientation_index = 0
	store.new_assembly_grid_frame = GridTransform.identity()
	store.store_id = PlayerIdentity.store_id("player")
	var store_result := world.apply_structural_command_now(store)
	if not store_result.is_ok():
		world.free()
		return _fail("cargo_store placement failed")
	var assembly_id := int(store_result.data["assembly_id"])
	var allow := PlaceElementCommand.new()
	allow.assembly_id = assembly_id
	allow.expected_assembly_revision = int(store_result.data["topology_revision"])
	allow.archetype = Slice01Archetypes.frame()
	allow.origin_cell = Vector3i(-1, 0, 1)
	allow.orientation_index = 0
	allow.store_id = PlayerIdentity.store_id("player")
	var allow_result := world.apply_structural_command_now(allow)
	if not allow_result.is_ok():
		world.free()
		return _fail("mount-pad-aligned frame placement failed")
	var deny := PlaceElementCommand.new()
	deny.assembly_id = assembly_id
	deny.expected_assembly_revision = int(allow_result.data["topology_revision"])
	deny.archetype = Slice01Archetypes.frame()
	deny.origin_cell = Vector3i(0, 0, 3)
	deny.orientation_index = 0
	deny.store_id = PlayerIdentity.store_id("player")
	var deny_result := world.apply_structural_command_now(deny)
	if deny_result.reason != StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION:
		world.free()
		return _fail("non-pad structural contact was not rejected")
	world.free()
	return true


func _test_unified_grid_descriptor_cache() -> bool:
	var archetype: ElementArchetype = Slice01Archetypes.large_frame()
	GridSurfaceUtil.clear_descriptor_cache()
	var first: Array = GridSurfaceUtil.get_surface_descriptors(archetype, 0)
	var second: Array = GridSurfaceUtil.get_surface_descriptors(archetype, 0)
	if first != second:
		return _fail("surface descriptor cache did not reuse cached descriptors")
	if first.is_empty():
		return _fail("large_frame produced no surface descriptors")
	GridSurfaceUtil.clear_descriptor_cache()
	var rebuilt: Array = GridSurfaceUtil.get_surface_descriptors(archetype, 0)
	if rebuilt.size() != first.size():
		return _fail("descriptor cache rebuild changed surface count")
	for index: int in range(first.size()):
		if (
			first[index].structural_id != rebuilt[index].structural_id
			or first[index].local_cell != rebuilt[index].local_cell
			or first[index].local_face != rebuilt[index].local_face
		):
			return _fail("descriptor cache rebuild changed surface content")
	var left := _preview_element(archetype, Vector3i.ZERO, 0)
	var right := _preview_element(
		Slice01Archetypes.frame(),
		Vector3i(5, 0, 0),
		0
	)
	var first_count := GridSurfaceUtil.count_matching_contact_faces(left, right)
	var second_count := GridSurfaceUtil.count_matching_contact_faces(left, right)
	if first_count != 1 or second_count != 1:
		return _fail("local-neighbor contact validation count mismatch")
	return true


func _test_unified_grid_full_surface_contact_count() -> bool:
	var archetype: ElementArchetype = Slice01Archetypes.large_frame()
	var left := _preview_element(archetype, Vector3i.ZERO, 0)
	var right := _preview_element(archetype, Vector3i(5, 0, 0), 0)
	var contact_count := GridSurfaceUtil.count_matching_contact_faces(left, right)
	if contact_count != 25:
		return _fail(
			"full-surface contact count changed: expected 25, got %d"
			% contact_count
		)
	var connection := GridSurfaceUtil.find_rigid_connection(left, right)
	if (
		connection.get("left_port_id", "") != "structural_4_0_0_px"
		or connection.get("right_port_id", "") != "structural_0_0_0_nx"
	):
		return _fail("full-surface canonical connection changed")
	return true


func _test_snapshot_canonical_joint_roundtrip() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 100.0)
	var large := _place_large_frame(world, Vector3i.ZERO, 0, -1)
	if not large.is_ok():
		world.free()
		return _fail("large_frame placement failed for snapshot roundtrip")
	var assembly_id := int(large.data["assembly_id"])
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(large.data["topology_revision"])
	place.archetype = Slice01Archetypes.frame()
	place.origin_cell = Vector3i(5, 0, 0)
	place.orientation_index = 0
	place.store_id = PlayerIdentity.store_id("player")
	if not world.apply_structural_command_now(place).is_ok():
		world.free()
		return _fail("edge frame placement failed for snapshot roundtrip")
	var snapshot := world.capture_snapshot()
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(
		snapshot
	)
	if restored == null:
		world.free()
		return _fail("canonical joint snapshot failed restore")
	if not SimulationSnapshot.semantic_equals(
		snapshot,
		restored.capture_snapshot()
	):
		world.free()
		restored.free()
		return _fail("canonical joint snapshot roundtrip changed semantics")
	for row: Dictionary in snapshot["joints"]:
		if int(row.get("kind", -1)) != SimulationJoint.Kind.RIGID:
			continue
		if not str(row.get("port_a_id", "")).begins_with("structural_"):
			world.free()
			restored.free()
			return _fail("snapshot rigid joint missing derived structural port_a_id")
		if not str(row.get("port_b_id", "")).begins_with("structural_"):
			world.free()
			restored.free()
			return _fail("snapshot rigid joint missing derived structural port_b_id")
	world.free()
	restored.free()
	return true


func _place_large_frame(
	world: SimulationWorld,
	origin_cell: Vector3i,
	assembly_id: int,
	expected_revision: int
) -> StructuralCommandResult:
	var command := PlaceElementCommand.new()
	command.assembly_id = assembly_id
	command.expected_assembly_revision = expected_revision
	command.archetype = Slice01Archetypes.large_frame()
	command.origin_cell = origin_cell
	command.orientation_index = 0
	if assembly_id == 0:
		command.new_assembly_grid_frame = GridTransform.identity()
	command.store_id = PlayerIdentity.store_id("player")
	return world.apply_structural_command_now(command)


func _preview_element(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> SimulationElement:
	var element := SimulationElement.new()
	element.archetype_id = archetype.archetype_id
	element.bind_archetype(archetype)
	element.origin_cell = origin_cell
	element.orientation_index = orientation_index
	return element


func _test_legacy_snapshot_version_rejected() -> bool:
	var world := SimulationWorld.new()
	_spawn(world, FIXTURE, GridTransform.identity())
	var snapshot := world.capture_snapshot()
	world.free()
	snapshot["version"] = 4
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(snapshot)
	if restored != null:
		restored.free()
		return _fail("legacy snapshot version 4 was accepted")
	return true


func _test_malformed_snapshot_atomicity() -> bool:
	var world := SimulationWorld.new()
	_spawn(world, FIXTURE, GridTransform.identity())
	var original := world.capture_snapshot()
	var malformed := original.duplicate(true)
	malformed["elements"][1]["element_id"] = malformed["elements"][0]["element_id"]
	if not _rejects_without_mutation(
		world, original, malformed, "duplicate ElementId"
	):
		return false
	var bad_allocator := original.duplicate(true)
	bad_allocator["allocator"]["next_element_id"] = 1
	if not _rejects_without_mutation(
		world, original, bad_allocator, "colliding allocator"
	):
		return false

	var overlap := original.duplicate(true)
	overlap["elements"][1]["origin_cell"] = overlap["elements"][0]["origin_cell"]
	if not _rejects_without_mutation(
		world, original, overlap, "overlapping occupancy"
	):
		return false

	var nonadjacent := original.duplicate(true)
	var rigid_row: Dictionary
	for row: Dictionary in nonadjacent["joints"]:
		if int(row["kind"]) == SimulationJoint.Kind.RIGID:
			rigid_row = row
			break
	for element_row: Dictionary in nonadjacent["elements"]:
		if int(element_row["element_id"]) == int(rigid_row["element_b_id"]):
			element_row["origin_cell"] = Vector3i(50, 0, 0)
			break
	if not _rejects_without_mutation(
		world, original, nonadjacent, "nonadjacent rigid joint"
	):
		return false

	var incompatible := original.duplicate(true)
	for row: Dictionary in incompatible["joints"]:
		if int(row["kind"]) == SimulationJoint.Kind.RIGID:
			row["port_b_id"] = "structural_0_0_0_py"
			break
	if not _rejects_without_mutation(
		world, original, incompatible, "incompatible rigid ports"
	):
		return false

	var fake_anchor := original.duplicate(true)
	for row: Dictionary in fake_anchor["joints"]:
		if int(row["kind"]) == SimulationJoint.Kind.ANCHOR:
			row["port_a_id"] = "structural_0_0_0_px"
			break
	if not _rejects_without_mutation(
		world, original, fake_anchor, "fake anchor port"
	):
		return false

	var duplicate_joint := original.duplicate(true)
	var copied_joint: Dictionary = duplicate_joint["joints"][0].duplicate(true)
	copied_joint["joint_id"] = int(
		duplicate_joint["allocator"]["next_joint_id"]
	)
	duplicate_joint["allocator"]["next_joint_id"] = (
		int(copied_joint["joint_id"]) + 1
	)
	duplicate_joint["joints"].append(copied_joint)
	if not _rejects_without_mutation(
		world, original, duplicate_joint, "duplicate canonical joint"
	):
		return false

	var disconnected := original.duplicate(true)
	for index: int in range(disconnected["joints"].size()):
		if (
			int(disconnected["joints"][index]["kind"])
			== SimulationJoint.Kind.RIGID
		):
			disconnected["joints"].remove_at(index)
			break
	if not _rejects_without_mutation(
		world, original, disconnected, "disconnected rigid graph"
	):
		return false

	var cyclic := original.duplicate(true)
	var active_id: int = cyclic["assemblies"][0]["assembly_id"]
	cyclic["assemblies"].append({
		"assembly_id": 99,
		"topology_revision": 1,
		"grid_frame": GridTransform.identity().to_dict(),
		"element_ids": [],
		"tombstoned": true,
		"redirect_to": 100,
	})
	cyclic["assemblies"].append({
		"assembly_id": 100,
		"topology_revision": 1,
		"grid_frame": GridTransform.identity().to_dict(),
		"element_ids": [],
		"tombstoned": true,
		"redirect_to": 99,
	})
	cyclic["redirects"] = [
		{"from_assembly_id": 99, "to_assembly_id": 100},
		{"from_assembly_id": 100, "to_assembly_id": 99},
	]
	cyclic["allocator"]["next_assembly_id"] = 101
	if not _rejects_without_mutation(
		world, original, cyclic, "cyclic redirects"
	):
		return false
	if world.get_assembly(active_id) == null:
		return _fail("cyclic redirect rejection damaged active world")
	world.free()
	return true


func _rejects_without_mutation(
	world: SimulationWorld,
	original: Dictionary,
	candidate: Dictionary,
	label: String
) -> bool:
	if world.restore_snapshot(candidate):
		return _fail("%s snapshot was accepted" % label)
	if not SimulationSnapshot.semantic_equals(
		original,
		world.capture_snapshot()
	):
		return _fail("%s rejection mutated world" % label)
	return true


func _test_archetype_conflict_and_allocator_continuity() -> bool:
	var world := SimulationWorld.new()
	_spawn(world, _single_blueprint(CUSTOM), GridTransform.identity())
	var conflict: ElementArchetype = CUSTOM.duplicate(true)
	conflict.mass_kg += 1.0
	var before := world.get_allocator().to_dict()
	var failed := _spawn(
		world,
		_single_blueprint(conflict),
		GridTransform.identity()
	)
	if failed.reason != StructuralCommandResult.REASON_ARCHETYPE_CONFLICT:
		return _fail("conflicting archetype definition was accepted")
	var after := world.get_allocator().to_dict()
	for key: String in ["next_element_id", "next_assembly_id", "next_joint_id"]:
		if before[key] != after[key]:
			return _fail("archetype conflict consumed topology IDs")
	var injected := SpawnBlueprintCommand.new()
	injected.blueprint = _single_blueprint(CUSTOM)
	injected.command_id = 1
	var collision := world.apply_structural_command_now(injected)
	if collision.reason != StructuralCommandResult.REASON_INVALID_COMMAND_ID:
		return _fail("externally supplied command ID was accepted")
	world.free()
	return true


func _test_typed_queued_completion() -> bool:
	var world := SimulationWorld.new()
	add_child(world)
	_queued_completion_ids.clear()
	_queued_completion_results.clear()
	world.structural_command_completed.connect(
		func(command_id: int, result: StructuralCommandResult) -> void:
			_queued_completion_ids.append(command_id)
			_queued_completion_results.append(result)
	)
	var command := SpawnBlueprintCommand.new()
	command.blueprint = _single_blueprint(CUSTOM)
	command.grid_frame.translation = Vector3i(1, 0, 0)
	var first_id := world.submit_structural_command(command)
	command.grid_frame.translation = Vector3i(5, 0, 0)
	var second_id := world.submit_structural_command(command)
	command.grid_frame.translation = Vector3i(9, 0, 0)
	command.blueprint = FIXTURE
	if (
		first_id <= 0
		or second_id <= 0
		or first_id == second_id
		or command.command_id != 0
	):
		return _fail("queued command IDs are not authority-owned and unique")
	await get_tree().process_frame
	await get_tree().process_frame
	if (
		_queued_completion_ids != [first_id, second_id]
		or _queued_completion_results.size() != 2
		or not _queued_completion_results[0].is_ok()
		or not _queued_completion_results[1].is_ok()
	):
		return _fail("typed queued completion signal missing")
	var first_assembly := world.get_assembly(
		int(_queued_completion_results[0].data["assembly_id"])
	)
	var second_assembly := world.get_assembly(
		int(_queued_completion_results[1].data["assembly_id"])
	)
	if (
		first_assembly.grid_frame.translation != Vector3i(1, 0, 0)
		or second_assembly.grid_frame.translation != Vector3i(5, 0, 0)
		or first_assembly.element_ids.size() != 1
		or second_assembly.element_ids.size() != 1
	):
		return _fail("queued commands did not capture immutable payloads")
	world.queue_free()
	return true


func _spawn(
	world: SimulationWorld,
	blueprint: Blueprint,
	frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = frame
	return world.apply_structural_command_now(command)


func _merge_connection_ports(
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
	var elements_by_id: Dictionary = {}
	for element: SimulationElement in world.list_elements():
		elements_by_id[element.element_id] = element
	var b_to_a := GridPoseUtil.b_to_a_from_grid_frames(
		assembly_a.grid_frame,
		assembly_b.grid_frame
	)
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


func _merge(
	world: SimulationWorld,
	a: StructuralCommandResult,
	b: StructuralCommandResult,
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String
) -> StructuralCommandResult:
	var command := MergeAssembliesCommand.new()
	command.assembly_a_id = int(a.data["assembly_id"])
	command.assembly_b_id = int(b.data["assembly_id"])
	command.expected_revision_a = int(a.data["topology_revision"])
	command.expected_revision_b = int(b.data["topology_revision"])
	command.element_a_id = element_a_id
	command.port_a_id = port_a_id
	command.element_b_id = element_b_id
	command.port_b_id = port_b_id
	var assembly_a: SimulationAssembly = world.get_assembly_raw(
		int(a.data["assembly_id"])
	)
	var assembly_b: SimulationAssembly = world.get_assembly_raw(
		int(b.data["assembly_id"])
	)
	command.b_to_a_grid = GridPoseUtil.b_to_a_from_grid_frames(
		assembly_a.grid_frame,
		assembly_b.grid_frame
	)
	return world.apply_structural_command_now(command)


func _single_blueprint(archetype: ElementArchetype) -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"runtime_single_%s" % archetype.archetype_id,
		[_placement("element_0", archetype, Vector3i.ZERO)]
	)


func _foundation_frame_blueprint() -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"runtime_foundation_frame",
		[
			_placement(
				"foundation_0",
				Slice01Archetypes.foundation(),
				Vector3i.ZERO
			),
			_placement(
				"frame_0",
				Slice01Archetypes.frame(),
				Vector3i(4, 0, 1)
			),
		]
	)


func _chain_blueprint(count: int) -> Blueprint:
	var placements: Array[BlueprintElementPlacement] = []
	for index: int in range(count):
		placements.append(_placement(
			"frame_%d" % index,
			Slice01Archetypes.frame(),
			Vector3i(index, 0, 0)
		))
	return BlueprintBaker.bake_from_placements("runtime_chain", placements)


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


func _joint_keys(world: SimulationWorld) -> PackedStringArray:
	var result := PackedStringArray()
	for joint: SimulationJoint in world.list_joints():
		result.append(joint.canonical_key())
	result.sort()
	return result


func _first_rigid_joint(world: SimulationWorld) -> int:
	for joint: SimulationJoint in world.list_joints():
		if joint.kind == SimulationJoint.Kind.RIGID:
			return joint.joint_id
	return 0


func _joint_between(world: SimulationWorld, a: int, b: int) -> int:
	for joint: SimulationJoint in world.list_joints():
		if (
			joint.kind == SimulationJoint.Kind.RIGID
			and (
				(joint.element_a_id == a and joint.element_b_id == b)
				or (joint.element_a_id == b and joint.element_b_id == a)
			)
		):
			return joint.joint_id
	return 0


func _anchor_for(world: SimulationWorld, element_id: int) -> int:
	for joint: SimulationJoint in world.list_joints():
		if (
			joint.kind == SimulationJoint.Kind.ANCHOR
			and joint.element_a_id == element_id
		):
			return joint.joint_id
	return 0


func _orientation_mapping(from: Vector3i, to: Vector3i) -> int:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.rotate_direction(from, index) == to:
			return index
	return -1


func _fail(reason: String) -> bool:
	print("KERNEL-RUNTIME-V0: FAIL %s" % reason)
	get_tree().quit(1)
	return false
