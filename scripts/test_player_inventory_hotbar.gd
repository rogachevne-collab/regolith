extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless pure-logic gate for player tool instances, hotbar refs, transfer
## invalidation, and snapshot roundtrip (INDUSTRY-V1 § Player tool instances).


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "PLAYER-INVENTORY-HOTBAR")
	if not _test_starter_seed_and_hotbar_refs():
		_abort()
		return
	if not _test_hotbar_validation():
		_abort()
		return
	if not _test_transfer_removal_invalidates_hotbar():
		_abort()
		return
	if not _test_snapshot_roundtrip():
		_abort()
		return
	print("PLAYER-INVENTORY-HOTBAR: PASS")
	get_tree().quit(0)


func _test_starter_seed_and_hotbar_refs() -> bool:
	var world := SimulationWorld.new()
	IndustryStoreService.sync_all_elements(world)
	var registry := world.ensure_player_inventory()
	if not registry.has_instance("starter_tool_drill"):
		return _fail("starter drill instance missing")
	if registry.item_id_for_instance("starter_tool_drill") != "tool_hand_drill":
		return _fail("starter drill item_id mismatch")
	if registry.hotbar_instance_id(0, 0) != "starter_tool_drill":
		return _fail("default hotbar slot 0 must reference starter drill")
	if registry.hotbar_instance_id(0, 8) != "starter_tool_connector":
		return _fail("default hotbar slot 8 must reference starter connector")
	world.free()
	return true


func _test_hotbar_validation() -> bool:
	var registry := PlayerInventoryRegistry.new()
	registry.seed_starter_tools(false)
	if not PlayerHotbarBridge.slot_owns_instance(
		registry,
		0,
		1,
		"starter_tool_welder"
	):
		return _fail("slot 1 must own starter welder instance")
	var entry := {
		"kind": &"tool_instance",
		"instance_id": "starter_tool_grinder",
	}
	var resolved := PlayerHotbarBridge.resolve_slot_entry(registry, entry)
	if String(resolved.get("active_tool", "")) != "grinder":
		return _fail("grinder instance must resolve to grinder active_tool")
	registry.remove_instance("starter_tool_grinder")
	resolved = PlayerHotbarBridge.resolve_slot_entry(registry, entry)
	if not resolved.is_empty():
		return _fail("removed instance must not resolve")
	if registry.hotbar_instance_id(0, 2) != "":
		return _fail("hotbar ref for removed grinder must clear")
	return true


func _test_transfer_removal_invalidates_hotbar() -> bool:
	var world := SimulationWorld.new()
	IndustryStoreService.sync_all_elements(world)
	var registry := world.ensure_player_inventory()
	var element := _place_operational_element(
		world,
		Slice01Archetypes.cargo_store(),
		42
	)
	if element == null:
		world.free()
		return _fail("cargo store placement failed")
	var store_id := IndustryStoreService.element_store_id(element.element_id)
	var command := TransferResourceCommand.new()
	command.from_store_id = IndustryStoreService.PLAYER_STORE_ID
	command.to_store_id = store_id
	command.resource_id = "tool_hand_drill"
	command.instance_id = "starter_tool_drill"
	var result := world.apply_transfer_resource(command)
	if StringName(result.get("reason", &"")) != &"ok":
		return _fail("tool instance transfer must succeed")
	if registry.has_instance("starter_tool_drill"):
		return _fail("transferred instance must be removed from player registry")
	if registry.hotbar_instance_id(0, 0) != "":
		return _fail("hotbar ref must clear after transfer")
	var cargo := world.get_resource_store(store_id)
	if cargo == null or cargo.amount("tool_hand_drill") < 1.0 - ResourceCatalog.EPSILON:
		return _fail("destination must receive one tool stack")
	world.free()
	return true


func _test_snapshot_roundtrip() -> bool:
	var world := SimulationWorld.new()
	IndustryStoreService.sync_all_elements(world)
	world.get_resource_store(IndustryStoreService.PLAYER_STORE_ID).add(
		"ore_mare_regolith",
		2.0
	)
	var snap := world.capture_snapshot()
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(snap)
	if restored == null:
		return _fail("snapshot restore failed")
	var registry: PlayerInventoryRegistry = restored.ensure_player_inventory()
	if not registry.has_instance("starter_tool_welder"):
		return _fail("restored snapshot must keep starter welder")
	if registry.hotbar_instance_id(0, 1) != "starter_tool_welder":
		return _fail("restored snapshot must keep hotbar ref")
	var player_snap := StoreSnapshotBuilder.build(
		restored,
		IndustryStoreService.PLAYER_STORE_ID
	)
	if not bool(player_snap.get("valid", false)):
		return _fail("player snapshot must stay valid after roundtrip")
	var found_instance := false
	for row: Dictionary in player_snap.get("entries", []):
		if str(row.get("instance_id", "")) == "starter_tool_drill":
			found_instance = true
			break
	if not found_instance:
		return _fail("player snapshot must include tool instance rows")
	world.free()
	restored.free()
	return true


func _place_operational_element(
	world: SimulationWorld,
	archetype: ElementArchetype,
	offset_x: int
) -> SimulationElement:
	var grid_frame := GridTransform.new()
	grid_frame.translation = Vector3i(offset_x, 0, 0)
	var command := SpawnBlueprintCommand.new()
	command.blueprint = BlueprintBaker.bake_from_placements(
		"player_inv_hotbar_%s_%d" % [archetype.archetype_id, offset_x],
		[_placement("element_0", archetype, Vector3i.ZERO)]
	)
	command.grid_frame = grid_frame
	var result := world.apply_structural_command_now(command)
	if not result.is_ok():
		return null
	var mapping: Dictionary = result.data.get("local_to_element_id", {})
	var element_id := int(mapping.get("element_0", 0))
	if element_id <= 0:
		var element_ids: Array = result.data.get("element_ids", [])
		if element_ids.is_empty():
			return null
		element_id = int(element_ids[0])
	var element := world.get_element(element_id)
	if element == null:
		return null
	element.build_progress = 1.0
	element.integrity = archetype.max_integrity
	IndustryStoreService.sync_element_storage(world, element)
	return element


func _placement(
	local_id: String,
	archetype: ElementArchetype,
	cell: Vector3i
) -> BlueprintElementPlacement:
	var placement := BlueprintElementPlacement.new()
	placement.local_id = local_id
	placement.archetype = archetype
	placement.origin_cell = cell
	placement.orientation_index = 0
	return placement


func _fail(message: String) -> bool:
	push_error(message)
	print("PLAYER-INVENTORY-HOTBAR: FAIL — %s" % message)
	return false


func _abort() -> void:
	get_tree().quit(1)
