extends Node
## Headless pure-logic gate for terminal inventory snapshots and item icons
## (INDUSTRY-V1 § Terminal inventory, Phase 2a).

const EPSILON := 0.000001


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _test_unknown_store_failure():
		_abort()
		return
	if not _test_player_store_snapshot():
		_abort()
		return
	if not _test_keyed_store_snapshot():
		_abort()
		return
	if not _test_buffer_store_snapshot():
		_abort()
		return
	if not _test_processor_machine_metadata():
		_abort()
		return
	if not _test_item_icon_mapping():
		_abort()
		return
	if not _test_gateway_not_ready():
		_abort()
		return
	print("STORE-SNAPSHOT: PASS")
	get_tree().quit(0)

func _test_unknown_store_failure() -> bool:
	var world := SimulationWorld.new()
	var snap := StoreSnapshotBuilder.build(world, "missing_store")
	if bool(snap.get("valid", true)):
		world.free()
		return _fail("unknown store must return valid=false")
	if StringName(snap.get("reason", &"")) != &"invalid_reference":
		world.free()
		return _fail("unknown store reason expected invalid_reference")
	var empty := StoreSnapshotBuilder.build(world, "")
	world.free()
	if bool(empty.get("valid", true)):
		return _fail("empty store_id must fail")
	return true


func _test_player_store_snapshot() -> bool:
	var world := SimulationWorld.new()
	var store := IndustryStoreService.ensure_player_store(world)
	store.set_amount("raw_regolith", 2.5)
	store.set_amount("construction_component", 1.0)
	var snap := StoreSnapshotBuilder.build(world, IndustryStoreService.PLAYER_STORE_ID)
	world.free()
	if not bool(snap.get("valid", false)):
		return _fail("player snapshot must be valid")
	if snap.get("store_id", "") != IndustryStoreService.PLAYER_STORE_ID:
		return _fail("player snapshot store_id mismatch")
	if snap.get("title", "") != HudTokens.store_label(IndustryStoreService.PLAYER_STORE_ID):
		return _fail("player snapshot title mismatch")
	var entries: Array = snap.get("entries", [])
	if entries.size() != 2:
		return _fail("player snapshot expected 2 entries, got %d" % entries.size())
	var regolith := _find_entry(entries, "raw_regolith")
	if regolith.is_empty():
		return _fail("player snapshot missing raw_regolith entry")
	if not is_equal_approx(float(regolith.get("amount", 0.0)), 2.5):
		return _fail("player raw_regolith amount mismatch")
	if regolith.get("category", "") != "ore":
		return _fail("player raw_regolith category must be ore")
	if bool(regolith.get("discrete", true)):
		return _fail("raw_regolith must not be discrete")
	var component := _find_entry(entries, "construction_component")
	if component.is_empty() or bool(component.get("discrete", false)) != true:
		return _fail("construction_component entry must be discrete")
	if float(snap.get("used_l", 0.0)) <= 0.0:
		return _fail("player used_l must be positive with cargo")
	if not is_equal_approx(
		float(snap.get("capacity_l", 0.0)),
		IndustryArchetypeProfile.player_carry_capacity_l()
	):
		return _fail("player capacity_l mismatch")
	if float(snap.get("mass_kg", 0.0)) <= 0.0:
		return _fail("player mass_kg must be positive with cargo")
	if bool(snap.get("is_machine", true)):
		return _fail("player store must not be machine")
	if snap.get("machine", false) != null:
		return _fail("player store machine must be null")
	return true


func _test_keyed_store_snapshot() -> bool:
	var world := SimulationWorld.new()
	var element := _place_operational_element(
		world,
		Slice01Archetypes.cargo_store(),
		11
	)
	if element == null:
		world.free()
		return _fail("cargo_store placement failed")
	var store_id := IndustryStoreService.element_store_id(element.element_id)
	var store := IndustryStoreService.ensure_element_keyed_store(world, element)
	store.set_amount("metal_ingot", 3.0)
	var snap := StoreSnapshotBuilder.build(world, store_id)
	world.free()
	if not bool(snap.get("valid", false)):
		return _fail("keyed store snapshot must be valid")
	if snap.get("store_id", "") != store_id:
		return _fail("keyed store_id mismatch")
	if bool(snap.get("is_machine", true)):
		return _fail("cargo_store snapshot must not be machine")
	var entries: Array = snap.get("entries", [])
	if entries.size() != 1 or str(entries[0].get("item_id", "")) != "metal_ingot":
		return _fail("keyed store entries mismatch")
	return true


func _test_buffer_store_snapshot() -> bool:
	var world := SimulationWorld.new()
	var element := _place_operational_element(
		world,
		Slice01Archetypes.processor(),
		21
	)
	if element == null:
		world.free()
		return _fail("processor placement failed")
	element.industry_buffer = ElementIndustryBuffer.new()
	element.industry_buffer.add("raw_regolith", 1.0, 100.0)
	var store_id := IndustryStoreService.buffer_store_id(element.element_id)
	var snap := StoreSnapshotBuilder.build(world, store_id)
	if not bool(snap.get("valid", false)):
		world.free()
		return _fail("buffer snapshot must be valid")
	if snap.get("store_id", "") != store_id:
		world.free()
		return _fail("buffer store_id mismatch")
	var entries: Array = snap.get("entries", [])
	if entries.size() != 1 or str(entries[0].get("item_id", "")) != "raw_regolith":
		world.free()
		return _fail("buffer entries mismatch")
	var missing := StoreSnapshotBuilder.build(
		world,
		IndustryStoreService.buffer_store_id(99999)
	)
	world.free()
	if bool(missing.get("valid", true)):
		return _fail("missing buffer element must fail")
	return true


func _test_processor_machine_metadata() -> bool:
	var world := SimulationWorld.new()
	var element := _place_operational_element(
		world,
		Slice01Archetypes.processor(),
		31
	)
	if element == null:
		world.free()
		return _fail("processor placement failed")
	element.industry_buffer = ElementIndustryBuffer.new()
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	runtime.machine_enabled = false
	var machine := runtime.ensure_machine_state()
	machine.active_recipe_id = "crush_regolith"
	machine.progress_s = 3.0
	machine.queue = ["sinter_basalt"]
	var store_id := IndustryStoreService.buffer_store_id(element.element_id)
	var snap := StoreSnapshotBuilder.build(world, store_id)
	world.free()
	if not bool(snap.get("is_machine", false)):
		return _fail("processor buffer target must be machine")
	var meta: Dictionary = snap.get("machine", {})
	if meta.is_empty():
		return _fail("processor machine metadata missing")
	if bool(meta.get("enabled", true)):
		return _fail("processor enabled flag mismatch")
	if meta.get("recipe_id", "") != "crush_regolith":
		return _fail("processor recipe_id mismatch")
	var recipes: Array = meta.get("recipes", [])
	if recipes.is_empty():
		return _fail("processor recipes list must not be empty")
	var queue: Array = meta.get("queue", [])
	if queue.size() != 1 or str(queue[0]) != "sinter_basalt":
		return _fail("processor queue mismatch")
	if not is_equal_approx(float(meta.get("progress", 0.0)), 0.5):
		return _fail("processor progress expected 0.5, got %s" % str(meta.get("progress")))
	if StringName(meta.get("status", &"")) != &"disabled":
		return _fail("disabled processor status expected disabled")
	return true


func _test_item_icon_mapping() -> bool:
	for item_id: String in ResourceCatalog.ENTRIES.keys():
		var code := HudTokens.item_code(item_id)
		if code.is_empty():
			return _fail("item_code empty for %s" % item_id)
		if not HudTokens.ITEM_CODES.has(item_id):
			return _fail("ITEM_CODES missing %s" % item_id)
		if not HudTokens.ITEM_COLORS.has(item_id):
			return _fail("ITEM_COLORS missing %s" % item_id)
		if HudTokens.item_color(item_id) != HudTokens.ITEM_COLORS[item_id]:
			return _fail("item_color must match ITEM_COLORS for %s" % item_id)
	var icon := HudTokens.make_item_icon("raw_regolith", 48.0)
	var label := _find_code_label(icon)
	if label == null or label.text != HudTokens.item_code("raw_regolith"):
		return _fail("make_item_icon must render item code label")
	if icon.custom_minimum_size != Vector2(48.0, 48.0):
		return _fail("make_item_icon must honor size parameter")
	return true


func _test_gateway_not_ready() -> bool:
	var gateway := WorldCommandGateway.new()
	var snap := gateway.store_snapshot(IndustryStoreService.PLAYER_STORE_ID)
	gateway.free()
	if bool(snap.get("valid", true)):
		return _fail("gateway without session must return valid=false")
	if StringName(snap.get("reason", &"")) != &"not_ready":
		return _fail("gateway without session must return not_ready")
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
		"store_snapshot_%s_%d" % [archetype.archetype_id, offset_x],
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


func _find_entry(entries: Array, item_id: String) -> Dictionary:
	for row: Variant in entries:
		if row is Dictionary and str(row.get("item_id", "")) == item_id:
			return row
	return {}


func _find_code_label(root: Node) -> Label:
	for child_node in root.get_children():
		if child_node is Label:
			return child_node as Label
		var nested := _find_code_label(child_node)
		if nested != null:
			return nested
	return null


func _fail(message: String) -> bool:
	push_error(message)
	print("STORE-SNAPSHOT: FAIL — %s" % message)
	return false


func _abort() -> void:
	get_tree().quit(1)
