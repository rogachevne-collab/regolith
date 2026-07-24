extends Node
## Kernel test: InteractionIndex / driven_joint_for_element (Phase 1).
## World API only — no InteractionQuery / HUD (R2).

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
const PISTON_BASE := preload(
	"res://resources/archetypes/slice01/piston_base.tres"
)
const PISTON_HEAD := preload(
	"res://resources/archetypes/slice01/piston_head.tres"
)


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "KERNEL-INTERACTION-INDEX")
	var tests: Array[Callable] = [
		_test_piston_dual_endpoint,
		_test_frame_has_no_driven_joint,
		_test_dismantle_clears_mapping,
		_test_restore_clears_and_rebuilds,
		_test_interaction_card_frame_and_piston,
		_test_actuator_display_pose_push,
		_test_industry_display_on_card,
		_test_broken_seat_not_enterable,
		_test_oxygen_module_card_keys,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("KERNEL-INTERACTION-INDEX: PASS")
	get_tree().quit(0)


func _test_piston_dual_endpoint() -> bool:
	var world := _world_with_stock()
	var placed := _place_piston_stack(world)
	if placed.is_empty():
		world.free()
		return _fail("piston stack setup failed")
	var base_id := int(placed["base_id"])
	var head_id := int(placed["head_id"])
	var joint_id := int(placed["joint_id"])
	var from_base := world.driven_joint_for_element(base_id)
	var from_head := world.driven_joint_for_element(head_id)
	if from_base == null or from_head == null:
		world.free()
		return _fail("driven_joint missing on base or head")
	if from_base.joint_id != joint_id or from_head.joint_id != joint_id:
		world.free()
		return _fail(
			"dual-endpoint mismatch base=%d head=%d want=%d"
			% [from_base.joint_id, from_head.joint_id, joint_id]
		)
	if from_base.kind != SimulationJoint.Kind.PISTON:
		world.free()
		return _fail("driven joint kind is not PISTON")
	var structure := world.get_interaction_structure(base_id)
	if structure == null or structure.driven_joint_id != joint_id:
		world.free()
		return _fail("get_interaction_structure missing driven_joint")
	if structure.display_actuator_status == &"":
		world.free()
		return _fail("display pose/status not seeded on rebuild")
	var via_find := PistonPlacementUtil.find_piston_joint_for_element(
		world,
		head_id
	)
	if via_find == null or via_find.joint_id != joint_id:
		world.free()
		return _fail("find_piston_joint_for_element head path broken")
	world.free()
	return true


func _test_frame_has_no_driven_joint() -> bool:
	var world := _world_with_stock()
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
	frame_place.expected_assembly_revision = int(
		foundation.data["topology_revision"]
	)
	frame_place.archetype = Slice01Archetypes.frame()
	frame_place.origin_cell = Vector3i(4, 0, 0)
	frame_place.orientation_index = 0
	frame_place.store_id = PlayerIdentity.store_id("player")
	var frame_result := world.apply_structural_command_now(frame_place)
	if not frame_result.is_ok():
		world.free()
		return _fail("frame place failed")
	var frame_id := int(frame_result.data["element_id"])
	if world.driven_joint_for_element(frame_id) != null:
		world.free()
		return _fail("plain frame should have no driven joint")
	var structure := world.get_interaction_structure(frame_id)
	if structure == null or structure.driven_joint_id != 0:
		world.free()
		return _fail("frame structure should not list driven_joint_id")
	world.free()
	return true


func _test_dismantle_clears_mapping() -> bool:
	var world := _world_with_stock()
	var placed := _place_piston_stack(world)
	if placed.is_empty():
		world.free()
		return _fail("piston stack setup failed for dismantle")
	var base_id := int(placed["base_id"])
	var head_id := int(placed["head_id"])
	var assembly_id := int(placed["assembly_id"])
	# Warm index before mutate.
	if world.driven_joint_for_element(base_id) == null:
		world.free()
		return _fail("warm joint lookup failed")
	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = base_id
	dismantle.expected_assembly_revision = world.get_assembly_raw(
		assembly_id
	).topology_revision
	dismantle.store_id = PlayerIdentity.store_id("player")
	var result := world.apply_structural_command_now(dismantle)
	if not result.is_ok():
		world.free()
		return _fail("dismantle failed: %s" % result.reason)
	if world.get_element(base_id) != null:
		world.free()
		return _fail("base element still present after dismantle")
	if world.driven_joint_for_element(base_id) != null:
		world.free()
		return _fail("driven_joint still resolves removed base")
	# Head may survive on a split assembly without the piston joint.
	if world.get_element(head_id) != null:
		if world.driven_joint_for_element(head_id) != null:
			world.free()
			return _fail("head still maps to a driven joint after split")
	world.free()
	return true


func _test_restore_clears_and_rebuilds() -> bool:
	var world := _world_with_stock()
	var placed := _place_piston_stack(world)
	if placed.is_empty():
		world.free()
		return _fail("piston stack setup failed for restore")
	var base_id := int(placed["base_id"])
	var head_id := int(placed["head_id"])
	var joint_id := int(placed["joint_id"])
	if world.driven_joint_for_element(base_id) == null:
		world.free()
		return _fail("pre-snapshot joint missing")
	var snapshot := world.capture_snapshot()
	if not world.restore_snapshot(snapshot, false):
		world.free()
		return _fail("restore_snapshot failed")
	# Index must have been cleared; lazy rebuild recreates dual-endpoint map.
	var from_base := world.driven_joint_for_element(base_id)
	var from_head := world.driven_joint_for_element(head_id)
	if (
		from_base == null
		or from_head == null
		or from_base.joint_id != joint_id
		or from_head.joint_id != joint_id
	):
		world.free()
		return _fail("post-restore dual-endpoint joint map broken")
	world.free()
	return true


func _test_interaction_card_frame_and_piston() -> bool:
	var world := _world_with_stock()
	var placed := _place_piston_stack(world)
	if placed.is_empty():
		world.free()
		return _fail("piston stack setup failed for card")
	var base_id := int(placed["base_id"])
	var head_id := int(placed["head_id"])
	var joint_id := int(placed["joint_id"])
	var frame_id := 0
	for element: SimulationElement in world.list_elements():
		if element.archetype_id == "frame":
			frame_id = element.element_id
			break
	if frame_id <= 0:
		world.free()
		return _fail("frame element missing for card test")
	var frame_card := world.get_interaction_card(frame_id)
	if frame_card == null:
		world.free()
		return _fail("get_interaction_card null for frame")
	if frame_card.keys.get("piston_joint_id", 0) != 0:
		world.free()
		return _fail("frame card must not carry piston_joint_id")
	if frame_card.keys.has("locomotive") or frame_card.keys.has("mobile"):
		world.free()
		return _fail("Drop keys locomotive/mobile must not appear on card")
	if not frame_card.keys.has("status_reason"):
		world.free()
		return _fail("frame card missing status_reason")
	var base_card := world.get_interaction_card(base_id)
	var head_card := world.get_interaction_card(head_id)
	if base_card == null or head_card == null:
		world.free()
		return _fail("get_interaction_card null for piston endpoints")
	if (
		int(base_card.keys.get("piston_joint_id", 0)) != joint_id
		or int(head_card.keys.get("piston_joint_id", 0)) != joint_id
	):
		world.free()
		return _fail("card missing dual-endpoint piston_joint_id")
	if base_card.keys.has("piston_base_element_id"):
		world.free()
		return _fail("Drop key piston_base_element_id must not appear")
	if not base_card.keys.has("piston_observed_position_m"):
		world.free()
		return _fail("piston live pose missing on card")
	# Same RefCounted reused; second call refreshes in-place.
	var again := world.get_interaction_card(base_id)
	if again != base_card:
		world.free()
		return _fail("get_interaction_card should reuse cached card")
	world.free()
	return true


func _test_actuator_display_pose_push() -> bool:
	var world := _world_with_stock()
	var placed := _place_piston_stack(world)
	if placed.is_empty():
		world.free()
		return _fail("piston stack setup failed for display pose")
	var base_id := int(placed["base_id"])
	var head_id := int(placed["head_id"])
	var joint_id := int(placed["joint_id"])
	# Warm index seed.
	if world.get_interaction_structure(base_id) == null:
		world.free()
		return _fail("structure warm failed")
	var joint := world.get_joint(joint_id)
	if joint == null or joint.motor == null:
		world.free()
		return _fail("joint missing")
	joint.motor.observed_position_m = 0.42
	joint.motor.status = SimulationMotorState.Status.MOVING
	if not world.patch_actuator_display_pose(joint_id, true):
		world.free()
		return _fail("forced display pose patch failed")
	var base_s := world.get_interaction_structure(base_id)
	var head_s := world.get_interaction_structure(head_id)
	if (
		base_s == null
		or head_s == null
		or not is_equal_approx(base_s.display_pose_m, 0.42)
		or not is_equal_approx(head_s.display_pose_m, 0.42)
		or base_s.display_actuator_status != &"moving"
		or head_s.display_actuator_status != &"moving"
	):
		world.free()
		return _fail("dual-endpoint DisplayPose mismatch after push")
	# Silence: same pose/status, not forced.
	if world.patch_actuator_display_pose(joint_id, false):
		world.free()
		return _fail("identical pose/status should not write")
	# Hz: pose changes within window should not write.
	joint.motor.observed_position_m = 0.55
	if world.patch_actuator_display_pose(joint_id, false):
		world.free()
		return _fail("pose change inside Hz window should not write")
	if not is_equal_approx(
		world.get_interaction_structure(base_id).display_pose_m,
		0.42
	):
		world.free()
		return _fail("Hz-capped pose should stay at last written value")
	# Status change flushes immediately (and may carry latest pose).
	joint.motor.status = SimulationMotorState.Status.IDLE
	if not world.patch_actuator_display_pose(joint_id, false):
		world.free()
		return _fail("status change should flush DisplayPose")
	if world.get_interaction_structure(base_id).display_actuator_status != &"idle":
		world.free()
		return _fail("status flush did not update structure")
	var card := world.get_interaction_card(head_id)
	if card == null:
		world.free()
		return _fail("card null after display push")
	if not is_equal_approx(
		float(card.keys.get("piston_observed_position_m", -1.0)),
		world.get_interaction_structure(head_id).display_pose_m
	):
		world.free()
		return _fail("card observed pose should follow DisplayPose")
	world.free()
	return true


func _test_industry_display_on_card() -> bool:
	var world := _world_with_stock()
	var helper := AssemblyBuildHelper.new(world)
	helper.ensure_materials()
	if not helper.spawn_anchor(Slice01Archetypes.processor()):
		world.free()
		return _fail("processor anchor spawn failed: %s" % helper.last_error)
	var element_id := int(helper.element_ids["anchor"])
	var element := world.get_element(element_id)
	var graph := world.ensure_cargo_graph_current()
	RecipeRunnerService.new().sync_display_fields(world, graph, element)
	var runtime := world.get_industry_element_runtime(element_id)
	if runtime == null or not runtime.display_ready:
		world.free()
		return _fail("sync_display_fields did not set display_ready")
	var card := world.get_interaction_card(element_id)
	if card == null:
		world.free()
		return _fail("card null for processor")
	if StringName(card.keys.get("status_reason", &"")) != runtime.display_status_reason:
		world.free()
		return _fail("card status_reason != display_status_reason")
	if not card.keys.has("cargo_network_connected"):
		world.free()
		return _fail("card missing cargo_network_connected from display_*")
	if not card.keys.has("missing_input_resource_id"):
		world.free()
		return _fail("card missing missing_input_resource_id from display_*")
	world.free()
	return true


func _test_broken_seat_not_enterable() -> bool:
	## Incomplete / broken ControlSeat keeps structural role but must not mark
	## enterable (Query KIND_CONTROL_SEAT / enter prompt).
	var world := _world_with_stock()
	world.get_archetype_registry().register(Slice01Archetypes.control_terminal())
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	if not foundation.is_ok():
		world.free()
		return _fail("broken-seat foundation spawn failed")
	var assembly_id := int(foundation.data["assembly_id"])
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(foundation.data["topology_revision"])
	place.archetype = Slice01Archetypes.control_terminal()
	place.origin_cell = Vector3i(4, 0, 0)
	place.store_id = PlayerIdentity.store_id("player")
	var placed := world.apply_structural_command_now(place)
	if not placed.is_ok():
		world.free()
		return _fail("control_terminal place failed: %s" % placed.reason)
	var host_id := int(placed.data["element_id"])
	var host := world.get_element(host_id)
	if host == null or host.is_operational():
		world.free()
		return _fail("unwelded terminal must be non-operational")
	var structure := world.get_interaction_structure(host_id)
	if structure == null or not structure.control_seat:
		world.free()
		return _fail("structure must still mark ControlSeat role")
	if InteractionCard.is_enterable_control_seat(world, host_id):
		world.free()
		return _fail("incomplete seat must not be enterable")
	var card := world.get_interaction_card(host_id)
	if card != null and bool(card.keys.get("control_seat", false)):
		world.free()
		return _fail("incomplete seat card must omit control_seat key")
	# Break an operational seat — same contract.
	var weld := WeldElementCommand.new()
	weld.element_id = host_id
	weld.expected_state_revision = host.state_revision
	weld.max_material_amount = 100.0
	weld.store_id = PlayerIdentity.store_id("player")
	world.apply_structural_command_now(weld)
	host = world.get_element(host_id)
	if host == null or not host.is_operational():
		world.free()
		return _fail("welded terminal should be operational")
	if not InteractionCard.is_enterable_control_seat(world, host_id):
		world.free()
		return _fail("operational seat must be enterable")
	host.integrity = 0.0
	host.sync_build_progress_from_integrity()
	if InteractionCard.is_enterable_control_seat(world, host_id):
		world.free()
		return _fail("broken seat must not be enterable")
	var broken_card := world.get_interaction_card(host_id)
	if broken_card != null and bool(broken_card.keys.get("control_seat", false)):
		world.free()
		return _fail("broken seat card must omit control_seat key")
	world.free()
	return true


func _test_oxygen_module_card_keys() -> bool:
	## O(1) OxygenModule keys for aim/HUD — liters + enable/power/status.
	var world := _world_with_stock()
	world.get_archetype_registry().register(Slice01Archetypes.o2_module())
	var spawn := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.o2_module()),
		GridTransform.identity()
	)
	if not spawn.is_ok():
		world.free()
		return _fail("oxygen module spawn failed")
	var element_id := int(spawn.data["element_ids"][0])
	var element := world.get_element(element_id)
	if element == null:
		world.free()
		return _fail("oxygen module missing after spawn")
	IndustryStoreService.ensure_element_keyed_store(world, element)
	var runtime := world.ensure_industry_element_runtime(element_id)
	runtime.machine_enabled = true
	runtime.powered = true
	runtime.power_reason = &"ok"
	var card := world.get_interaction_card(element_id)
	if card == null or not bool(card.keys.get("oxygen_module", false)):
		world.free()
		return _fail("card missing oxygen_module flag")
	var capacity_l := float(card.keys.get("oxygen_capacity_l", 0.0))
	var current_l := float(card.keys.get("oxygen_current_l", -1.0))
	if capacity_l <= 0.0:
		world.free()
		return _fail("card missing oxygen_capacity_l")
	if current_l < 0.0 or current_l > capacity_l + 0.001:
		world.free()
		return _fail("card oxygen_current_l out of range")
	if not bool(card.keys.get("machine_enabled", false)):
		world.free()
		return _fail("card missing machine_enabled")
	if not bool(card.keys.get("powered", false)):
		world.free()
		return _fail("card missing powered")
	if not card.keys.has("status_reason"):
		world.free()
		return _fail("card missing status_reason")
	runtime.machine_enabled = false
	card = world.get_interaction_card(element_id)
	if StringName(card.keys.get("status_reason", &"")) != &"disabled":
		world.free()
		return _fail("disabled oxygen module should report disabled status")
	if IndustryTransferUtil.is_transfer_target(element):
		world.free()
		return _fail("oxygen module must not be a generic transfer target")
	world.free()
	return true


func _place_piston_stack(world: SimulationWorld) -> Dictionary:
	world.get_archetype_registry().register(PISTON_HEAD)
	var foundation := _spawn(
		world,
		_single_blueprint(Slice01Archetypes.foundation()),
		GridTransform.identity()
	)
	if not foundation.is_ok():
		return {}
	var assembly_id := int(foundation.data["assembly_id"])
	var frame_place := PlaceElementCommand.new()
	frame_place.assembly_id = assembly_id
	frame_place.expected_assembly_revision = int(
		foundation.data["topology_revision"]
	)
	frame_place.archetype = Slice01Archetypes.frame()
	frame_place.origin_cell = Vector3i(4, 0, 0)
	frame_place.orientation_index = 0
	frame_place.store_id = PlayerIdentity.store_id("player")
	var frame_result := world.apply_structural_command_now(frame_place)
	if not frame_result.is_ok():
		return {}
	var piston_place := PlaceElementCommand.new()
	piston_place.assembly_id = assembly_id
	piston_place.expected_assembly_revision = int(
		frame_result.data["topology_revision"]
	)
	piston_place.archetype = PISTON_BASE
	piston_place.origin_cell = Vector3i(5, 0, 0)
	piston_place.orientation_index = 0
	piston_place.store_id = PlayerIdentity.store_id("player")
	var piston_result := world.apply_structural_command_now(piston_place)
	if not piston_result.is_ok():
		return {}
	return {
		"assembly_id": assembly_id,
		"base_id": int(piston_result.data["element_id"]),
		"head_id": int(piston_result.data["head_element_id"]),
		"joint_id": int(piston_result.data["piston_joint_id"]),
	}


func _world_with_stock() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 100.0)
	return world


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
	blueprint.blueprint_id = "test_interaction_index_single"
	var placement := BlueprintElementPlacement.new()
	placement.local_id = "element_0"
	placement.archetype = archetype
	placement.origin_cell = Vector3i.ZERO
	placement.orientation_index = 0
	blueprint.placements = [placement]
	return blueprint


func _fail(message: String) -> bool:
	push_error(message)
	print("KERNEL-INTERACTION-INDEX: FAIL - %s" % message)
	get_tree().quit(1)
	return false
