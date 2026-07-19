extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless acceptance scaffold for docs/specs/INDUSTRY-V1.md.
## Uses test-only fixtures; does not modify production archetypes or runtime.

const EPSILON := 0.000001
const PLAYER_CARRY_CAPACITY_L := 100.0
const INDUSTRY_TICK_HZ := 1.0
const INDUSTRY_SIMULATION_SCRIPT := preload(
	"res://scripts/simulation/industry/industry_simulation.gd"
)

const ITEM_CATALOG: Dictionary = {
	"ore_mare_regolith": {
		"category": "ore",
		"mass_per_unit_kg": 2.0,
		"volume_per_unit_l": 2.5,
		"unit": "bulk",
	},
	"regolith_fines": {
		"category": "ore",
		"mass_per_unit_kg": 1.5,
		"volume_per_unit_l": 1.8,
		"unit": "bulk",
	},
	"sintered_basalt": {
		"category": "material",
		"mass_per_unit_kg": 3.0,
		"volume_per_unit_l": 1.5,
		"unit": "bulk",
	},
	"ilmenite_concentrate": {
		"category": "material",
		"mass_per_unit_kg": 2.2,
		"volume_per_unit_l": 1.2,
		"unit": "bulk",
	},
	"ingot_iron": {
		"category": "ingot",
		"mass_per_unit_kg": 4.0,
		"volume_per_unit_l": 0.6,
		"unit": "bulk",
	},
	"plate_metal": {
		"category": "component",
		"mass_per_unit_kg": 2.5,
		"volume_per_unit_l": 3.0,
		"unit": "discrete",
	},
	"hydrogen": {
		"category": "consumable",
		"mass_per_unit_kg": 0.05,
		"volume_per_unit_l": 2.5,
		"unit": "bulk",
	},
	"water": {
		"category": "consumable",
		"mass_per_unit_kg": 1.0,
		"volume_per_unit_l": 1.0,
		"unit": "bulk",
	},
	"oxygen": {
		"category": "consumable",
		"mass_per_unit_kg": 0.2,
		"volume_per_unit_l": 2.0,
		"unit": "bulk",
	},
}

const RECIPE_FIXTURES: Dictionary = {
	"crush_mare": {
		"machine": "Processor",
		"inputs": {"ore_mare_regolith": 1.0},
		"outputs": {"regolith_fines": 1.0},
		"duration_s": 6.0,
		"power_w": 200.0,
	},
	"sinter_basalt": {
		"machine": "Processor",
		"inputs": {"regolith_fines": 2.0},
		"outputs": {"sintered_basalt": 1.0},
		"duration_s": 8.0,
		"power_w": 250.0,
	},
	"beneficiate_ilmenite": {
		"machine": "Processor",
		"inputs": {"regolith_fines": 2.0},
		"outputs": {"ilmenite_concentrate": 1.0},
		"duration_s": 10.0,
		"power_w": 400.0,
	},
	"smelt_iron": {
		"machine": "Fabricator",
		"inputs": {"ilmenite_concentrate": 1.0},
		"outputs": {"ingot_iron": 1.0},
		"duration_s": 12.0,
		"power_w": 600.0,
	},
	"craft_plate_metal": {
		"machine": "Fabricator",
		"inputs": {"ingot_iron": 1.0},
		"outputs": {"plate_metal": 1.0},
		"duration_s": 10.0,
		"power_w": 500.0,
	},
}

func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "INDUSTRY-V1", 30.0)
	var tests: Array[Callable] = [
		_test_resource_catalog_contract,
		_test_capacity_store_no_overflow,
		_test_capacity_store_no_loss_on_reject,
		_test_discrete_fractional_rejection,
		_test_player_carry_capacity_fixture,
		_test_mass_coupling_reference,
		_test_recipe_fixture_chain,
		_test_cargo_graph_reference_adjacency,
		_test_cargo_graph_spawned_topology,
		_test_cargo_graph_rebuild_on_weld,
		_test_cargo_connect_network_absent_or_rejects_cargo,
		_test_electric_connect_network_runtime,
		_test_electric_link_dormancy_survives_damage_repair,
		_test_electric_consumer_wire_rejected,
		_test_electric_cable_waypoints_polyline,
		_test_industry_simulation_tick_runtime,
		_test_drill_mining_storage_full_runtime,
		_test_stationary_drill_set_machine_enabled,
		_test_hand_drill_loot_merge_runtime,
		_test_terrain_excavation_contract,
		_test_processor_pulls_from_connected_store,
		_test_processor_pulls_from_stocked_far_store,
		_test_integration_isru_scenario,
	]
	for test: Callable in tests:
		if not bool(await test.call()):
			return
	print("INDUSTRY-V1: PASS")
	get_tree().quit(0)


func _test_resource_catalog_contract() -> bool:
	for item_id: String in ITEM_CATALOG.keys():
		if not ResourceCatalog.has_resource(item_id):
			return _fail("ResourceCatalog missing %s" % item_id)
		var fixture: Dictionary = ITEM_CATALOG[item_id]
		if ResourceCatalog.category(item_id) != str(fixture["category"]):
			return _fail("ResourceCatalog category mismatch for %s" % item_id)
		if not is_equal_approx(
			ResourceCatalog.mass_per_unit_kg(item_id),
			float(fixture["mass_per_unit_kg"])
		):
			return _fail("ResourceCatalog mass mismatch for %s" % item_id)
		if not is_equal_approx(
			ResourceCatalog.volume_per_unit_l(item_id),
			float(fixture["volume_per_unit_l"])
		):
			return _fail("ResourceCatalog volume mismatch for %s" % item_id)
		if ResourceCatalog.unit(item_id) != str(fixture["unit"]):
			return _fail("ResourceCatalog unit mismatch for %s" % item_id)
		if float(fixture["mass_per_unit_kg"]) <= 0.0:
			return _fail("catalog mass must be positive for %s" % item_id)
		if float(fixture["volume_per_unit_l"]) <= 0.0:
			return _fail("catalog volume must be positive for %s" % item_id)
	var fines_volume: float = _catalog_volume({"regolith_fines": 2.0})
	if not is_equal_approx(fines_volume, 3.6):
		return _fail("catalog volume sum expected 3.6 L, got %.3f" % fines_volume)
	return true


func _test_capacity_store_no_overflow() -> bool:
	var store := _capacity_store(6.0)
	if not store.try_add("ore_mare_regolith", 2.0):
		return _fail("expected first add to succeed")
	if not store.try_add("ore_mare_regolith", 0.4):
		return _fail("expected second add within capacity to succeed")
	if store.try_add("ore_mare_regolith", 0.1):
		return _fail("overflow add must be rejected")
	if not is_equal_approx(store.total_volume_l(), 6.0):
		return _fail(
			"store volume after rejected overflow expected 6.0 L, got %.3f"
			% store.total_volume_l()
		)
	return true


func _test_capacity_store_no_loss_on_reject() -> bool:
	var store := _capacity_store(1.0)
	store.try_add("ingot_iron", 1.0)
	var before: float = store.inner.amount("ingot_iron")
	if store.try_add("ingot_iron", 1.0):
		return _fail("expected capacity rejection")
	if not is_equal_approx(store.inner.amount("ingot_iron"), before):
		return _fail("rejected add mutated store contents")
	return true


func _test_discrete_fractional_rejection() -> bool:
	var world := SimulationWorld.new()
	IndustryStoreService.ensure_player_store(world, "player")
	var store := world.get_resource_store(PlayerIdentity.store_id("player"))
	if store == null:
		world.free()
		return _fail("player store missing")
	if store.add("plate_metal", 0.5):
		world.free()
		return _fail("fractional discrete add must reject")
	if not store.add("plate_metal", 1.0):
		world.free()
		return _fail("whole discrete add must succeed")
	world.free()
	return true


func _test_player_carry_capacity_fixture() -> bool:
	var world := SimulationWorld.new()
	IndustryStoreService.ensure_player_store(world, "player")
	var store := world.get_resource_store(PlayerIdentity.store_id("player"))
	if store == null:
		world.free()
		return _fail("player store missing")
	if not is_equal_approx(store.capacity_l, PLAYER_CARRY_CAPACITY_L):
		world.free()
		return _fail(
			"player store capacity expected %.1f L, got %.1f L"
			% [PLAYER_CARRY_CAPACITY_L, store.capacity_l]
		)
	if not store.add("plate_metal", 33.0):
		world.free()
		return _fail("33 components should fit the single 100 L pool (99 L used)")
	if store.add("plate_metal", 1.0):
		world.free()
		return _fail("34 components must overflow the 100 L pool")
	world.free()

	world = SimulationWorld.new()
	IndustryStoreService.ensure_player_store(world, "player")
	store = world.get_resource_store(PlayerIdentity.store_id("player"))
	if not store.add("ore_mare_regolith", 40.0):
		world.free()
		return _fail("40 ore_mare_regolith should fill 100 L exactly")
	if store.add("ore_mare_regolith", 0.1):
		world.free()
		return _fail("player store must reject volume overflow")
	world.free()
	return true


func _test_mass_coupling_reference() -> bool:
	var archetype := Slice01Archetypes.stationary_drill()
	var element := SimulationElement.frame(
		1,
		1,
		archetype,
		Vector3i.ZERO,
		0,
		{}
	)
	element.set_industry_buffer({"ore_mare_regolith": 2.5})
	var expected := archetype.mass_kg + 5.0
	var actual := element.total_mass_kg()
	if not is_equal_approx(actual, expected):
		return _fail(
			"mass coupling expected %.3f kg, got %.3f kg"
			% [expected, actual]
		)
	if actual <= archetype.mass_kg:
		return _fail("content mass must increase element mass above dry mass")
	return true


func _test_recipe_fixture_chain() -> bool:
	if not RECIPE_FIXTURES.has("crush_mare"):
		return _fail("missing crush_mare fixture")
	var basalt_inputs: Dictionary = RECIPE_FIXTURES["sinter_basalt"]["inputs"]
	var basalt_outputs: Dictionary = RECIPE_FIXTURES["sinter_basalt"]["outputs"]
	if float(basalt_inputs["regolith_fines"]) != 2.0:
		return _fail("sinter_basalt fixture expects 2 fines input")
	if float(basalt_outputs["sintered_basalt"]) != 1.0:
		return _fail("sinter_basalt fixture expects 1 basalt output")
	var component_recipe: Dictionary = RECIPE_FIXTURES["craft_plate_metal"]
	if str(component_recipe["machine"]) != "Fabricator":
		return _fail("craft_plate_metal must run on Fabricator")
	var chain := [
		"crush_mare",
		"beneficiate_ilmenite",
		"smelt_iron",
		"craft_plate_metal",
	]
	for recipe_id: String in chain:
		if not RECIPE_FIXTURES.has(recipe_id):
			return _fail("ISRU chain missing recipe %s" % recipe_id)
	return true


func _test_cargo_graph_reference_adjacency() -> bool:
	var elements := _line_topology_elements()
	var edges := _build_cargo_edges(elements)
	if edges.is_empty():
		return _fail("reference cargo graph produced no edges for line topology")
	var graph := _undirected_graph_from_edges(edges)
	var drill_id := 101
	var store_id := 103
	if not _graph_has_path(graph, drill_id, store_id):
		return _fail("reference cargo graph must connect drill to store through pipe")
	var duplicate_count := _count_duplicate_undirected_pairs(edges)
	if duplicate_count > 0:
		return _fail("cargo graph must deduplicate adjacent pairs")
	return true


func _test_cargo_graph_spawned_topology() -> bool:
	var world := SimulationWorld.new()
	var blueprint := _cargo_line_blueprint()
	var spawn := _spawn(world, blueprint, GridTransform.identity())
	if not spawn.is_ok():
		world.free()
		return _fail(
			"cargo line blueprint spawn failed: %s %s"
			% [spawn.reason, str(spawn.data)]
		)
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var drill_id := int(mapping["drill_0"])
	var corner_pipe_id := int(mapping["pipe_corner"])
	var east_pipe_id := int(mapping["pipe_east"])
	var store_id := int(mapping["store_0"])
	var edges := world.get_cargo_adjacency_graph()
	if edges.is_empty():
		world.free()
		return _fail("production world cargo graph produced no edges")
	var graph := world.get_cargo_graph()
	if not graph.elements_are_connected(drill_id, corner_pipe_id):
		world.free()
		return _fail("production cargo graph missing drill-to-corner edge")
	if not graph.elements_are_connected(corner_pipe_id, east_pipe_id):
		world.free()
		return _fail("production cargo graph missing L-shaped pipe turn")
	if not graph.elements_are_connected(east_pipe_id, store_id):
		world.free()
		return _fail("production cargo graph missing rotated store connection")
	if graph.shortest_hop_distance(drill_id, store_id) != 3:
		world.free()
		return _fail("production cargo graph expected three-hop L-shaped path")
	if _count_duplicate_undirected_pairs(edges) > 0:
		world.free()
		return _fail("production cargo graph emitted duplicate adjacent pairs")
	world.free()
	return true


func _test_cargo_graph_rebuild_on_weld() -> bool:
	var world := SimulationWorld.new()
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 100.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 100.0)
	var spawn := _spawn(world, _cargo_line_blueprint(), GridTransform.identity())
	if not spawn.is_ok():
		world.free()
		return _fail("cargo weld rebuild spawn failed: %s" % spawn.reason)
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var drill_id := int(mapping["drill_0"])
	var corner_pipe_id := int(mapping["pipe_corner"])
	var store_id := int(mapping["store_0"])
	var corner_pipe := world.get_element(corner_pipe_id)
	if corner_pipe == null:
		world.free()
		return _fail("cargo weld rebuild missing corner pipe")
	corner_pipe.integrity = corner_pipe.get_archetype().max_integrity * 0.05
	corner_pipe.sync_build_progress_from_integrity()
	world.get_cargo_graph().rebuild(world)
	var graph := world.get_cargo_graph()
	if graph.shortest_hop_distance(drill_id, store_id) >= 0:
		world.free()
		return _fail(
			"incomplete pipe must break cargo path before weld rebuild test"
		)
	var weld := WeldElementCommand.new()
	weld.element_id = corner_pipe_id
	weld.expected_state_revision = corner_pipe.state_revision
	weld.store_id = PlayerIdentity.store_id("player")
	weld.max_material_amount = 100.0
	var weld_result := world.apply_structural_command_now(weld)
	if not weld_result.is_ok():
		world.free()
		return _fail("cargo weld rebuild weld failed: %s" % weld_result.reason)
	if not corner_pipe.is_operational():
		world.free()
		return _fail("cargo weld rebuild pipe still incomplete after weld")
	graph = world.get_cargo_graph()
	if not graph.elements_are_connected(drill_id, corner_pipe_id):
		world.free()
		return _fail("welded pipe must join cargo graph to drill")
	var east_pipe_id := int(mapping["pipe_east"])
	if not graph.elements_are_connected(corner_pipe_id, east_pipe_id):
		world.free()
		return _fail("welded pipe must join cargo graph to next pipe segment")
	if not graph.elements_are_connected(east_pipe_id, store_id):
		world.free()
		return _fail("welded pipe chain must reach cargo store")
	if graph.shortest_hop_distance(drill_id, store_id) < 0:
		world.free()
		return _fail("welded pipe must restore drill-to-store cargo path")
	world.free()
	return true


func _test_cargo_connect_network_absent_or_rejects_cargo() -> bool:
	return await _assert_connect_network_rejects_cargo_ports()


func _test_electric_connect_network_runtime() -> bool:
	return await _run_electric_wire_scenario()


func _test_electric_link_dormancy_survives_damage_repair() -> bool:
	return await _run_electric_link_dormancy_scenario()


func _test_electric_consumer_wire_rejected() -> bool:
	return await _run_electric_consumer_wire_rejected_scenario()


func _test_electric_cable_waypoints_polyline() -> bool:
	return await _run_electric_waypoints_scenario()


func _test_industry_simulation_tick_runtime() -> bool:
	return await _run_recipe_tick_scenario()


func _test_drill_mining_storage_full_runtime() -> bool:
	return await _run_drill_storage_full_scenario()


func _test_hand_drill_loot_merge_runtime() -> bool:
	var world := SimulationWorld.new()
	world.add_world_loot_pile(Vector3(1.0, 0.0, 0.0), "ore_mare_regolith", 4.0)
	world.add_world_loot_pile(Vector3(1.2, 0.0, 0.15), "ore_mare_regolith", 3.0)
	var piles := world.list_world_loot_piles()
	if piles.size() != 1:
		world.free()
		return _fail(
			"nearby hand-drill loot piles must merge, got %d" % piles.size()
		)
	if not is_equal_approx(float(piles[0]["amount_kg"]), 7.0):
		world.free()
		return _fail(
			"merged loot mass expected 7.0 kg, got %.3f"
			% float(piles[0]["amount_kg"])
		)
	world.add_world_loot_pile(Vector3(5.0, 0.0, 0.0), "ore_mare_regolith", 2.0)
	piles = world.list_world_loot_piles()
	if piles.size() != 2:
		world.free()
		return _fail(
			"distant loot pile must stay separate, got %d" % piles.size()
		)
	world.add_world_loot_pile(Vector3(1.1, 0.0, 0.05), "regolith_fines", 1.0)
	piles = world.list_world_loot_piles()
	if piles.size() != 3:
		world.free()
		return _fail(
			"different resource must not merge with regolith pile, got %d"
			% piles.size()
		)
	world.add_world_loot_pile(Vector3(2.0, 0.0, 0.0), "ore_mare_regolith", 20.0)
	world.add_world_loot_pile(Vector3(2.1, 0.0, 0.0), "ore_mare_regolith", 14.0)
	piles = world.list_world_loot_piles()
	if piles.size() != 5:
		world.free()
		return _fail(
			"loot pile must split when merge would exceed cap, got %d"
			% piles.size()
		)
	world.free()
	return true


func _test_terrain_excavation_contract() -> bool:
	var service := TerrainExcavationService.new()
	var empty := service.excavate(null, {"stamp_kind": &"sphere"})
	if float(empty.get("removed_volume_m3", -1.0)) != 0.0:
		return _fail("null voxel tool must return zero removed volume")

	var invalid := service.excavate(
		null,
		{"stamp_kind": &"grow_sphere"}
	)
	if float(invalid.get("removed_volume_m3", -1.0)) != 0.0:
		return _fail("invalid stamp kind must return zero removed volume")

	var terrain := Node3D.new()
	terrain.scale = Vector3(1.0, 1.0, 1.0)
	var before := VoxelBuffer.new()
	before.create(1, 1, 1)
	before.set_voxel_f(-0.5, 0, 0, 0, VoxelBuffer.CHANNEL_SDF)
	var after := VoxelBuffer.new()
	after.create(1, 1, 1)
	after.set_voxel_f(0.5, 0, 0, 0, VoxelBuffer.CHANNEL_SDF)
	var removed_cells: float = service._removed_volume_m3(before, after)
	if absf(removed_cells - 1.0) > 0.05:
		return _fail(
			"single-cell occupancy delta expected ~1.0, got %.6f" % removed_cells
		)
	var expected_m3: float = VoxelSpaceUtil.cell_volume_m3(terrain)
	if absf(expected_m3 - 1.0) > 0.0001:
		return _fail(
			"cell volume at scale 1.0 expected 1.0, got %.6f" % expected_m3
		)
	var world_m3 := removed_cells * expected_m3
	# Occupancy delta is ~0.98 (SDF snorm), not exact 1.0 — match the 0.05 cell tol.
	if absf(world_m3 - expected_m3) > 0.05:
		return _fail(
			"world m3 at scale 1.0 expected %.6f, got %.6f"
			% [expected_m3, world_m3]
		)

	if service._removed_volume_m3(after, after) > EPSILON:
		return _fail("repeat stamp over empty cells must measure zero delta")

	var material := TerrainMaterialSource.new()
	if not material.yield_for_removed_volume(0.0).is_empty():
		return _fail("zero removed volume must yield nothing")
	var yields := material.yield_for_removed_volume(
		0.01,
		IndustryArchetypeProfile.terrain_collectible_fraction()
	)
	if yields.is_empty():
		return _fail("collectible fraction must still yield on positive volume")
	var mass_kg := float(yields[0].get("mass_kg", 0.0))
	var expected_mass := (
		0.01
		* TerrainMaterialCatalog.density_kg_m3(
			TerrainMaterialCatalog.MAT_MARE_REGOLITH
		)
		* TerrainMaterialCatalog.collectible_fraction(
			TerrainMaterialCatalog.MAT_MARE_REGOLITH
		)
	)
	if not is_equal_approx(mass_kg, expected_mass):
		return _fail(
			"collectible yield mass expected %.6f, got %.6f"
			% [expected_mass, mass_kg]
		)
	terrain.free()
	return true


func _test_processor_pulls_from_connected_store() -> bool:
	var world := SimulationWorld.new()
	var spawn := _spawn(world, _integration_blueprint(), GridTransform.identity())
	if not spawn.is_ok():
		world.free()
		return _fail("processor pull scenario spawn failed: %s" % spawn.reason)
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var processor_id := int(mapping["processor_0"])
	var store_id := int(mapping["store_0"])
	var graph := world.get_cargo_graph()
	if graph.shortest_hop_distance(processor_id, store_id) < 0:
		world.free()
		return _fail("processor and cargo_store must share a cargo graph path")
	var keyed_store := IndustryStoreService.ensure_element_keyed_store(
		world,
		world.get_element(store_id)
	)
	if keyed_store == null:
		world.free()
		return _fail("cargo_store keyed store missing")
	keyed_store.set_amount("ore_mare_regolith", 4.0)
	var processor := world.get_element(processor_id)
	processor.set_industry_buffer({})
	var sim: IndustrySimulation = INDUSTRY_SIMULATION_SCRIPT.new()
	add_child(sim)
	sim.bind_world(world)
	_wire_integration_power(world)
	var runtime := world.ensure_industry_element_runtime(processor_id)
	runtime.machine_enabled = true
	_run_industry_ticks(sim, 3.0)
	if processor.industry_buffer_amount("ore_mare_regolith") + EPSILON < 1.0:
		sim.queue_free()
		world.free()
		return _fail(
			"processor expected to pull ore_mare_regolith from connected store, buffer=%s"
			% str(processor.industry_buffer.to_dict())
		)
	sim.queue_free()
	world.free()
	return true


func _test_processor_pulls_from_stocked_far_store() -> bool:
	var world := SimulationWorld.new()
	var spawn := _spawn(world, _dual_store_blueprint(), GridTransform.identity())
	if not spawn.is_ok():
		world.free()
		return _fail(
			"dual-store processor pull scenario spawn failed: %s"
			% spawn.reason
		)
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var processor_id := int(mapping["processor_0"])
	var near_store_id := int(mapping["store_near"])
	var far_store_id := int(mapping["store_0"])
	var graph := world.get_cargo_graph()
	if graph.shortest_hop_distance(processor_id, near_store_id) < 0:
		world.free()
		return _fail("processor must reach near cargo_store")
	if graph.shortest_hop_distance(processor_id, far_store_id) < 0:
		world.free()
		return _fail("processor must reach far cargo_store")
	if (
		graph.shortest_hop_distance(processor_id, near_store_id)
		>= graph.shortest_hop_distance(processor_id, far_store_id)
	):
		world.free()
		return _fail("near store must be closer than far store for this scenario")
	var far_store := IndustryStoreService.ensure_element_keyed_store(
		world,
		world.get_element(far_store_id)
	)
	if far_store == null:
		world.free()
		return _fail("far cargo_store keyed store missing")
	far_store.set_amount("ore_mare_regolith", 4.0)
	var processor := world.get_element(processor_id)
	processor.set_industry_buffer({})
	var sim: IndustrySimulation = INDUSTRY_SIMULATION_SCRIPT.new()
	add_child(sim)
	sim.bind_world(world)
	_wire_integration_power(world)
	var runtime := world.ensure_industry_element_runtime(processor_id)
	runtime.machine_enabled = true
	_run_industry_ticks(sim, 3.0)
	if processor.industry_buffer_amount("ore_mare_regolith") + EPSILON < 1.0:
		sim.queue_free()
		world.free()
		return _fail(
			"processor must pull from stocked far store when near store is empty, buffer=%s"
			% str(processor.industry_buffer.to_dict())
		)
	sim.queue_free()
	world.free()
	return true


func _test_integration_isru_scenario() -> bool:
	return await _run_integration_isru_scenario()


func _run_electric_wire_scenario() -> bool:
	var world := SimulationWorld.new()
	var blueprint := _electric_cable_blueprint()
	var spawn := _spawn(world, blueprint, GridTransform.identity())
	if not spawn.is_ok():
		world.free()
		return _fail("electric cable fixture spawn failed: %s" % spawn.reason)
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var source_id := int(mapping["source_0"])
	var distributor_id := int(mapping["distributor_0"])
	var consumer_id := int(mapping["processor_0"])
	var outside_id := int(mapping["fabricator_outside"])
	var consumer_wire := world.connect_network(
		source_id,
		"power_out",
		outside_id,
		"power_in"
	)
	if (
		consumer_wire.is_ok()
		or consumer_wire.reason
		!= StructuralCommandResult.REASON_ENDPOINT_NOT_WIREABLE
	):
		world.free()
		return _fail("wire into a consumer must be rejected as not wireable")
	var source_link := world.connect_network(
		source_id,
		"power_out",
		distributor_id,
		"power_in"
	)
	if not source_link.is_ok():
		world.free()
		return _fail(
			"source-to-distributor link failed: %s" % source_link.reason
		)
	var links := world.list_electric_links()
	if links.size() != 1:
		world.free()
		return _fail(
			"wireless distribution expected only source-to-distributor link"
		)
	for machine_id: int in [consumer_id, outside_id]:
		if IndustryElectricPortUtil.find_port(
			world.get_element(machine_id),
			"power_out"
		) != null:
			world.free()
			return _fail("consumer fixture must not expose power_out pass-through")
	IndustryElectricBudget.apply_tick(world, 1.0)
	var consumer_runtime := world.get_industry_element_runtime(consumer_id)
	var outside_runtime := world.get_industry_element_runtime(outside_id)
	if consumer_runtime == null or not consumer_runtime.powered:
		world.free()
		return _fail("unwired in-radius consumer was not powered")
	if outside_runtime == null or outside_runtime.power_reason != &"outside_power_radius":
		world.free()
		return _fail("consumer beyond 12 m must report outside_power_radius")
	consumer_runtime.active_recipe_power_w = 2500.0
	IndustryElectricBudget.apply_tick(world, 1.0)
	if consumer_runtime.power_reason != &"no_power":
		world.free()
		return _fail("insufficient aggregate supply must report no_power")
	consumer_runtime.active_recipe_power_w = 0.0
	world.ensure_industry_element_runtime(source_id).machine_enabled = false
	IndustryElectricBudget.apply_tick(world, 1.0)
	if (
		consumer_runtime.power_reason != &"port_disconnected"
		or outside_runtime.power_reason != &"port_disconnected"
	):
		world.free()
		return _fail("missing supplied distributor network must report port_disconnected")
	world.free()
	return true


## Freeform routing: the cable length limit applies to each SPAN of the
## routed polyline (между скобами), not to the total. A single span longer
## than the limit is rejected; a long zigzag with short spans is accepted,
## and waypoints persist on the stored link in order.
func _run_electric_waypoints_scenario() -> bool:
	var world := SimulationWorld.new()
	var spawn := _spawn(
		world,
		_electric_cable_blueprint(),
		GridTransform.identity()
	)
	if not spawn.is_ok():
		world.free()
		return _fail("waypoints scenario spawn failed: %s" % spawn.reason)
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var source_id := int(mapping["source_0"])
	var distributor_id := int(mapping["distributor_0"])
	var long_span := PackedVector3Array([Vector3(1.5, 1001.0, 0.0)])
	var rejected := world.connect_network(
		source_id,
		"power_out",
		distributor_id,
		"power_in",
		-1,
		long_span
	)
	if (
		rejected.is_ok()
		or rejected.reason != StructuralCommandResult.REASON_CABLE_TOO_LONG
	):
		world.free()
		return _fail("routed span over the limit must be rejected")
	# Total routed length can exceed the span limit when every span stays under it.
	var detour := PackedVector3Array([
		Vector3(1.5, 1.0, 5.0),
		Vector3(2.5, 1.0, -5.0),
	])
	var routed := world.connect_network(
		source_id,
		"power_out",
		distributor_id,
		"power_in",
		-1,
		detour
	)
	if not routed.is_ok():
		world.free()
		return _fail("routed cable within limit failed: %s" % routed.reason)
	var rows := world.list_electric_links()
	if rows.size() != 1:
		world.free()
		return _fail("routed connect expected exactly one stored link")
	var stored_waypoints := PackedVector3Array(
		rows[0].get("waypoints", PackedVector3Array())
	)
	if stored_waypoints != detour:
		world.free()
		return _fail("stored link must keep routed waypoints in order")
	IndustryElectricBudget.apply_tick(world, 1.0)
	var consumer_runtime := world.get_industry_element_runtime(
		int(mapping["processor_0"])
	)
	if consumer_runtime == null or not consumer_runtime.powered:
		world.free()
		return _fail("routed supply network must power in-radius consumer")
	world.free()
	return true


## Wires connect only power infrastructure (source / distributor / battery).
## A cable into a consumer's power_in is rejected with endpoint_not_wireable
## and nothing is stored; machines are powered by distributor radius alone.
func _run_electric_consumer_wire_rejected_scenario() -> bool:
	var world := SimulationWorld.new()
	var spawn := _spawn(
		world,
		_electric_cable_blueprint(),
		GridTransform.identity()
	)
	if not spawn.is_ok():
		world.free()
		return _fail("consumer wire scenario spawn failed: %s" % spawn.reason)
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var source_id := int(mapping["source_0"])
	var consumer_id := int(mapping["processor_0"])
	var rejected := world.connect_network(
		source_id,
		"power_out",
		consumer_id,
		"power_in"
	)
	if (
		rejected.is_ok()
		or rejected.reason
		!= StructuralCommandResult.REASON_ENDPOINT_NOT_WIREABLE
	):
		world.free()
		return _fail(
			"consumer wire expected endpoint_not_wireable, got %s"
			% str(rejected.reason)
		)
	if not world.list_electric_links().is_empty():
		world.free()
		return _fail("rejected consumer wire must not be stored")
	var battery_pair := IndustryElectricPortUtil.diagnose_electric_pair(
		world,
		source_id,
		consumer_id
	)
	if StringName(battery_pair.get("reason", &"")) != &"endpoint_not_wireable":
		world.free()
		return _fail("diagnose must flag consumer endpoints as not wireable")
	world.free()
	return true


## Wiring must survive an endpoint damage → repair cycle: the link goes dormant
## (out of the electric graph) while the endpoint is not operational and revives
## after repair, without ever being deleted from `electric_links[]`.
func _run_electric_link_dormancy_scenario() -> bool:
	var world := SimulationWorld.new()
	var spawn := _spawn(
		world,
		_electric_cable_blueprint(),
		GridTransform.identity()
	)
	if not spawn.is_ok():
		world.free()
		return _fail("dormancy scenario spawn failed: %s" % spawn.reason)
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var source_id := int(mapping["source_0"])
	var distributor_id := int(mapping["distributor_0"])
	var consumer_id := int(mapping["processor_0"])
	var source_link := world.connect_network(
		source_id,
		"power_out",
		distributor_id,
		"power_in"
	)
	if not source_link.is_ok():
		world.free()
		return _fail("dormancy source link failed: %s" % source_link.reason)
	var link_id := int(source_link.data["link_id"])
	IndustryElectricBudget.apply_tick(world, 1.0)
	var consumer_runtime := world.get_industry_element_runtime(consumer_id)
	if consumer_runtime == null or not consumer_runtime.powered:
		world.free()
		return _fail("dormancy baseline consumer was not powered")

	var source := world.get_element(source_id)
	var max_integrity := source.get_archetype().max_integrity
	var damage := DamageElementCommand.new()
	damage.element_id = source_id
	damage.expected_state_revision = source.state_revision
	damage.damage = max_integrity * 0.2
	var damage_result := world.apply_structural_command_now(damage)
	if not damage_result.is_ok():
		world.free()
		return _fail("dormancy damage failed: %s" % damage_result.reason)
	if source.is_operational():
		world.free()
		return _fail("damaged source must not stay operational")
	IndustryElectricBudget.apply_tick(world, 1.0)
	if world.list_electric_links().size() != 1:
		world.free()
		return _fail("dormant link must stay stored, not be deleted")
	if world.get_industry_network().is_link_active(world, link_id):
		world.free()
		return _fail("link with damaged endpoint must be dormant")
	if consumer_runtime.powered:
		world.free()
		return _fail("consumer must lose power while supply link is dormant")

	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 10.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 10.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 10.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 10.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 10.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 10.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 10.0)
	var repair := RepairElementCommand.new()
	repair.element_id = source_id
	repair.expected_state_revision = source.state_revision
	repair.store_id = PlayerIdentity.store_id("player")
	repair.max_material_amount = 10.0
	var repair_result := world.apply_structural_command_now(repair)
	if not repair_result.is_ok():
		world.free()
		return _fail("dormancy repair failed: %s" % repair_result.reason)
	if not source.is_operational():
		world.free()
		return _fail("repaired source must be operational again")
	IndustryElectricBudget.apply_tick(world, 1.0)
	if not consumer_runtime.powered:
		world.free()
		return _fail("repaired endpoint must revive dormant link without rewiring")
	if world.list_electric_links().size() != 1:
		world.free()
		return _fail("revived link must be the original, not a new connection")

	var disconnect_result := world.disconnect_network(0, "", 0, "", link_id)
	if not disconnect_result.is_ok():
		world.free()
		return _fail("disconnect by link_id failed: %s" % disconnect_result.reason)
	if not world.list_electric_links().is_empty():
		world.free()
		return _fail("disconnect must remove the stored link")
	world.free()
	return true


func _run_recipe_tick_scenario() -> bool:
	var world := SimulationWorld.new()
	var spawn := _spawn(
		world,
		_electric_cable_blueprint(),
		GridTransform.identity()
	)
	if not spawn.is_ok():
		world.free()
		return _fail("recipe scenario spawn failed: %s" % spawn.reason)
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var source_id := int(mapping["source_0"])
	var distributor_id := int(mapping["distributor_0"])
	var processor_id := int(mapping["processor_0"])
	var source_link := world.connect_network(
		source_id,
		"power_out",
		distributor_id,
		"power_in"
	)
	if not source_link.is_ok():
		world.free()
		return _fail(
			"recipe source-to-distributor link failed: %s"
			% source_link.reason
		)
	var processor := world.get_element(processor_id)
	processor.set_industry_buffer({"ore_mare_regolith": 1.0})
	var sim: IndustrySimulation = INDUSTRY_SIMULATION_SCRIPT.new()
	add_child(sim)
	sim.bind_world(world)
	_run_industry_ticks(sim, 7.0)
	var fines_amount := processor.industry_buffer_amount("regolith_fines")
	if fines_amount + EPSILON < 1.0:
		sim.queue_free()
		world.free()
		return _fail(
			"crush_mare tick expected >=1 fines, got %.3f" % fines_amount
		)
	sim.queue_free()
	world.free()
	return true


func _run_drill_storage_full_scenario() -> bool:
	var world := SimulationWorld.new()
	var blueprint := _cargo_line_blueprint()
	var spawn := _spawn(world, blueprint, GridTransform.identity())
	if not spawn.is_ok():
		world.free()
		return _fail("drill scenario spawn failed: %s" % spawn.reason)
	var sim: IndustrySimulation = INDUSTRY_SIMULATION_SCRIPT.new()
	add_child(sim)
	sim.bind_world(world)
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var source_link := world.connect_network(
		int(mapping["source_0"]),
		"power_out",
		int(mapping["distributor_0"]),
		"power_in"
	)
	if not source_link.is_ok():
		sim.queue_free()
		world.free()
		return _fail("drill supply network could not be connected")
	var drill_id := _find_element_id_by_archetype(world, "stationary_drill")
	if drill_id < 0:
		sim.queue_free()
		world.free()
		return _fail("drill element missing in cargo line blueprint")
	var carve_calls := {"count": 0, "volume": 0.15}
	_hook_drill_carve(sim, carve_calls)
	_run_industry_ticks(sim, 3.0)
	var raw_before := _read_element_buffer_amount(
		world.get_element(drill_id),
		"ore_mare_regolith"
	)
	if raw_before <= EPSILON and carve_calls["count"] == 0:
		sim.queue_free()
		world.free()
		return _fail("drill did not credit ore_mare_regolith with mocked carve")
	_fill_store_to_capacity(world)
	var drill_element := world.get_element(drill_id)
	var buffer_capacity_l := IndustryArchetypeProfile.internal_buffer_capacity_l(
		drill_element.archetype_id
	)
	drill_element.industry_buffer.add(
		"ore_mare_regolith",
		79.5,
		buffer_capacity_l
	)
	var carve_count_before := int(carve_calls["count"])
	_run_industry_ticks(sim, 1.0)
	var reason := _read_functional_reason(world, drill_id)
	if int(carve_calls["count"]) <= carve_count_before:
		sim.queue_free()
		world.free()
		return _fail(
			"drill must keep carving when storage is full, carve calls %d -> %d"
			% [carve_count_before, int(carve_calls["count"])]
		)
	if reason != &"storage_full":
		sim.queue_free()
		world.free()
		return _fail(
			"drill expected storage_full when outbound blocked, got %s" % str(reason)
		)
	sim.queue_free()
	world.free()
	return true


func _test_stationary_drill_set_machine_enabled() -> bool:
	var world := SimulationWorld.new()
	var blueprint := _cargo_line_blueprint()
	var spawn := _spawn(world, blueprint, GridTransform.identity())
	if not spawn.is_ok():
		world.free()
		return _fail("drill enable spawn failed: %s" % spawn.reason)
	var sim: IndustrySimulation = INDUSTRY_SIMULATION_SCRIPT.new()
	add_child(sim)
	sim.bind_world(world)
	var drill_id := _find_element_id_by_archetype(world, "stationary_drill")
	if drill_id < 0:
		sim.queue_free()
		world.free()
		return _fail("drill element missing for enable toggle test")
	var disable := SetMachineEnabledCommand.new()
	disable.element_id = drill_id
	disable.enabled = false
	var disable_result := sim.apply_set_machine_enabled(disable)
	if StringName(disable_result.get("reason", &"")) != &"ok":
		sim.queue_free()
		world.free()
		return _fail(
			"drill disable expected ok, got %s" % str(disable_result.get("reason", ""))
		)
	var runtime := world.ensure_industry_element_runtime(drill_id)
	if runtime.machine_enabled:
		sim.queue_free()
		world.free()
		return _fail("drill runtime must be disabled after toggle")
	var drill := world.get_element(drill_id)
	if drill.industry_status_reason() != &"disabled":
		sim.queue_free()
		world.free()
		return _fail(
			"disabled drill expected functional reason disabled, got %s"
			% str(drill.industry_status_reason())
		)
	var enable := SetMachineEnabledCommand.new()
	enable.element_id = drill_id
	enable.enabled = true
	var enable_result := sim.apply_set_machine_enabled(enable)
	if StringName(enable_result.get("reason", &"")) != &"ok":
		sim.queue_free()
		world.free()
		return _fail(
			"drill enable expected ok, got %s" % str(enable_result.get("reason", ""))
		)
	if not runtime.machine_enabled:
		sim.queue_free()
		world.free()
		return _fail("drill runtime must be enabled after toggle")
	sim.queue_free()
	world.free()
	return true


func _run_integration_isru_scenario() -> bool:
	var world := SimulationWorld.new()
	var blueprint := _integration_blueprint()
	var spawn := _spawn(world, blueprint, GridTransform.identity())
	if not spawn.is_ok():
		world.free()
		return _fail("integration blueprint spawn failed: %s" % spawn.reason)
	var sim: IndustrySimulation = INDUSTRY_SIMULATION_SCRIPT.new()
	add_child(sim)
	sim.bind_world(world)
	_wire_integration_power(world)
	_seed_integration_inputs(world)
	_hook_drill_carve(sim, {"count": 0, "volume": 0.2})
	var ticks := 120.0
	_run_industry_ticks(sim, ticks)
	var store_id := "element:%d" % _find_element_id_by_archetype(
		world,
		"cargo_store"
	)
	var component_amount := world.get_resource_store(store_id)
	if component_amount == null:
		sim.queue_free()
		world.free()
		return _fail("integration cargo store missing keyed store")
	if component_amount.amount("plate_metal") + EPSILON < 1.0:
		var fabricator_id := _find_element_id_by_archetype(world, "fabricator")
		var fabricator := world.get_element(fabricator_id)
		var fabricator_buffer := str(fabricator.industry_buffer.to_dict())
		var fabricator_reason := str(fabricator.industry_status_reason())
		sim.queue_free()
		world.free()
		return _fail(
			(
				"integration ISRU expected plate_metal >=1 after %.0f s "
				+ "(fabricator buffer=%s, reason=%s)"
			)
			% [
				ticks,
				fabricator_buffer,
				fabricator_reason,
			]
		)
	sim.queue_free()
	world.free()
	return true


func _assert_connect_network_rejects_cargo_ports() -> bool:
	var world := SimulationWorld.new()
	var blueprint := _cargo_line_blueprint()
	var spawn := _spawn(world, blueprint, GridTransform.identity())
	if not spawn.is_ok():
		world.free()
		return _fail("cargo connect rejection spawn failed")
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	var result := world.connect_network(
		int(mapping["drill_0"]),
		"cargo_out",
		int(mapping["pipe_corner"]),
		"cargo_through_nz"
	)
	world.free()
	if result.is_ok():
		return _fail("connect_network must reject cargo ports (pipe adjacency only)")
	return true


func _assert_world_connect_network_rejects_cargo_ports() -> bool:
	return await _assert_connect_network_rejects_cargo_ports()


func _capacity_store(capacity_l: float) -> RefCounted:
	return IndustryV1CapacityStore.new(capacity_l, ITEM_CATALOG)


func _catalog_mass(amounts: Dictionary) -> float:
	var total := 0.0
	for resource_id: Variant in amounts.keys():
		total += ResourceCatalog.resource_mass_kg(
			str(resource_id),
			float(amounts[resource_id])
		)
	return total


func _catalog_volume(amounts: Dictionary) -> float:
	var total := 0.0
	for resource_id: Variant in amounts.keys():
		total += ResourceCatalog.resource_volume_l(
			str(resource_id),
			float(amounts[resource_id])
		)
	return total


func _element_mass_kg(dry_mass_kg: float, buffer: Dictionary) -> float:
	return dry_mass_kg + _catalog_mass(buffer)


func _line_topology_elements() -> Array:
	var drill := _make_test_element(
		101,
		1,
		_test_drill_archetype(),
		Vector3i.ZERO
	)
	var pipe := _make_test_element(
		102,
		1,
		_test_cargo_pipe_archetype(),
		Vector3i(2, 0, 0)
	)
	var store := _make_test_element(
		103,
		1,
		_test_cargo_store_archetype(),
		Vector3i(3, 0, 0)
	)
	return [drill, pipe, store]


func _build_cargo_edges(elements: Array) -> Array[Dictionary]:
	var edges: Array[Dictionary] = []
	var seen: Dictionary = {}
	var sorted_elements: Array = elements.duplicate()
	sorted_elements.sort_custom(
		func(left, right) -> bool:
			return left.element_id < right.element_id
	)
	for left_index: int in range(sorted_elements.size()):
		for right_index: int in range(left_index + 1, sorted_elements.size()):
			var left = sorted_elements[left_index]
			var right = sorted_elements[right_index]
			if not left.is_operational() or not right.is_operational():
				continue
			var pair_edges := _cargo_port_edges_between(left, right)
			for edge: Dictionary in pair_edges:
				var key := _undirected_pair_key(
					int(edge["element_a"]),
					str(edge["port_a"]),
					int(edge["element_b"]),
					str(edge["port_b"])
				)
				if seen.has(key):
					continue
				seen[key] = true
				edges.append(edge)
	edges.sort_custom(_sort_edge)
	return edges


func _cargo_port_edges_between(left, right) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var left_archetype: ElementArchetype = left.get_archetype()
	var right_archetype: ElementArchetype = right.get_archetype()
	if left_archetype == null or right_archetype == null:
		return result
	for left_port: PortDefinition in left_archetype.ports:
		if left_port.kind != PortDefinition.Kind.CARGO:
			continue
		for right_port: PortDefinition in right_archetype.ports:
			if right_port.kind != PortDefinition.Kind.CARGO:
				continue
			if not _cargo_ports_adjacent(left, left_port, right, right_port):
				continue
			result.append({
				"element_a": left.element_id,
				"port_a": left_port.port_id,
				"element_b": right.element_id,
				"port_b": right_port.port_id,
			})
	return result


func _cargo_ports_adjacent(left, left_port: PortDefinition, right, right_port: PortDefinition) -> bool:
	if left_port.face_slot != right_port.face_slot:
		return false
	if not _tags_are_compatible(
		left_port.compatibility_tags,
		right_port.compatibility_tags
	):
		return false
	var left_cell := _element_port_cell(left, left_port)
	var left_direction := _element_port_direction(left, left_port)
	var right_cell := _element_port_cell(right, right_port)
	var right_direction := _element_port_direction(right, right_port)
	return (
		right_cell == left_cell + left_direction
		and right_direction == -left_direction
	)


func _element_port_cell(element, port: PortDefinition) -> Vector3i:
	return (
		element.origin_cell
		+ OrientationUtil.rotate_cell(port.local_cell, element.orientation_index)
	)


func _element_port_direction(element, port: PortDefinition) -> Vector3i:
	return OrientationUtil.rotate_direction(
		OrientationUtil.face_to_vector(port.local_face),
		element.orientation_index
	)


func _tags_are_compatible(
	left_tags: PackedStringArray,
	right_tags: PackedStringArray
) -> bool:
	if left_tags.is_empty() or right_tags.is_empty():
		return true
	for left_tag: String in left_tags:
		if right_tags.has(left_tag):
			return true
	return false


func _undirected_graph_from_edges(edges: Array[Dictionary]) -> Dictionary:
	var graph: Dictionary = {}
	for edge: Dictionary in edges:
		var a := int(edge["element_a"])
		var b := int(edge["element_b"])
		if not graph.has(a):
			graph[a] = {}
		if not graph.has(b):
			graph[b] = {}
		graph[a][b] = true
		graph[b][a] = true
	return graph


func _graph_has_path(graph: Dictionary, from_id: int, to_id: int) -> bool:
	if from_id == to_id:
		return true
	if not graph.has(from_id):
		return false
	var pending: Array[int] = [from_id]
	var visited: Dictionary = {from_id: true}
	while not pending.is_empty():
		var current: int = pending.pop_back()
		if current == to_id:
			return true
		if not graph.has(current):
			continue
		var neighbors: Array = graph[current].keys()
		neighbors.sort()
		for neighbor_variant: Variant in neighbors:
			var neighbor_id: int = int(neighbor_variant)
			if visited.has(neighbor_id):
				continue
			visited[neighbor_id] = true
			pending.append(neighbor_id)
	return false


func _count_duplicate_undirected_pairs(edges: Array[Dictionary]) -> int:
	var seen: Dictionary = {}
	var duplicates := 0
	for edge: Dictionary in edges:
		var key := _undirected_pair_key(
			int(edge["element_a"]),
			str(edge["port_a"]),
			int(edge["element_b"]),
			str(edge["port_b"])
		)
		if seen.has(key):
			duplicates += 1
		else:
			seen[key] = true
	return duplicates


func _undirected_pair_key(
	element_a: int,
	port_a: String,
	element_b: int,
	port_b: String
) -> String:
	if element_a > element_b or (element_a == element_b and port_a > port_b):
		return "%d|%s|%d|%s" % [element_b, port_b, element_a, port_a]
	return "%d|%s|%d|%s" % [element_a, port_a, element_b, port_b]


func _sort_edge(left: Dictionary, right: Dictionary) -> bool:
	var left_key := _undirected_pair_key(
		int(left["element_a"]),
		str(left["port_a"]),
		int(left["element_b"]),
		str(left["port_b"])
	)
	var right_key := _undirected_pair_key(
		int(right["element_a"]),
		str(right["port_a"]),
		int(right["element_b"]),
		str(right["port_b"])
	)
	return left_key < right_key


func _cargo_line_blueprint() -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"industry_v1_cargo_l_path",
		[
			_placement(
				"source_0",
				Slice01Archetypes.power_source(),
				Vector3i(4, 0, 0)
			),
			_placement(
				"distributor_0",
				Slice01Archetypes.load_required("power_distributor"),
				Vector3i(2, 0, 1)
			),
			_placement(
				"drill_0",
				Slice01Archetypes.stationary_drill(),
				Vector3i.ZERO
			),
			_placement(
				"pipe_corner",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(0, 0, 2)
			),
			_placement(
				"pipe_east",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(1, 0, 2)
			),
			_placement(
				"store_0",
				Slice01Archetypes.cargo_store(),
				Vector3i(0, 0, 3)
			),
		]
	)


func _electric_cable_blueprint() -> Blueprint:
	var placements: Array[BlueprintElementPlacement] = [
		_placement(
			"source_0",
			Slice01Archetypes.power_source(),
			Vector3i.ZERO
		),
		_placement(
			"distributor_0",
			Slice01Archetypes.load_required("power_distributor"),
			Vector3i(3, 0, 1)
		),
		_placement(
			"processor_0",
			Slice01Archetypes.processor(),
			Vector3i(5, 0, 0)
		),
		_placement(
			"fabricator_outside",
			Slice01Archetypes.fabricator(),
			Vector3i(30, 0, 0)
		),
	]
	placements.append_array(_foundation_span("radius_frame", 9, 29, 1))
	return BlueprintBaker.bake_from_placements(
		"industry_v1_distance_cable",
		placements
	)


func _integration_blueprint() -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"industry_v1_integration",
		[
			_placement(
				"power_0",
				Slice01Archetypes.power_source(),
				Vector3i(4, 0, 0)
			),
			_placement(
				"distributor_0",
				Slice01Archetypes.load_required("power_distributor"),
				Vector3i(2, 0, 1)
			),
			_placement(
				"drill_0",
				Slice01Archetypes.stationary_drill(),
				Vector3i.ZERO
			),
			_placement(
				"pipe_corner",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(0, 0, 2)
			),
			_placement(
				"pipe_east",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(1, 0, 2)
			),
			_placement(
				"processor_0",
				Slice01Archetypes.processor(),
				Vector3i(0, 0, 3)
			),
			_placement(
				"pipe_after_processor",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(1, 0, 6)
			),
			_placement(
				"fabricator_0",
				Slice01Archetypes.fabricator(),
				Vector3i(0, 0, 7)
			),
			_placement(
				"pipe_after_fabricator",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(1, 0, 10)
			),
			_placement(
				"store_0",
				Slice01Archetypes.cargo_store(),
				Vector3i(0, 0, 11)
			),
		]
	)


func _dual_store_blueprint() -> Blueprint:
	var blueprint := BlueprintBaker.bake_from_placements(
		"industry_v1_dual_store",
		[
			_placement(
				"power_0",
				Slice01Archetypes.power_source(),
				Vector3i(4, 0, 0)
			),
			_placement(
				"distributor_0",
				Slice01Archetypes.load_required("power_distributor"),
				Vector3i(2, 0, 1)
			),
			_placement(
				"processor_0",
				Slice01Archetypes.processor(),
				Vector3i(0, 0, 3)
			),
			_placement(
				"pipe_1",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(1, 0, 6)
			),
			_placement(
				"pipe_2",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(2, 0, 6)
			),
			_placement(
				"pipe_3",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(3, 0, 6)
			),
			_placement(
				"pipe_4",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(4, 0, 6)
			),
			_placement(
				"pipe_5",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(5, 0, 6)
			),
			_placement(
				"pipe_6",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(6, 0, 6)
			),
			_placement(
				"pipe_7",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(7, 0, 6)
			),
			_placement(
				"pipe_8",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(8, 0, 6)
			),
			_placement(
				"store_near",
				Slice01Archetypes.cargo_store(),
				Vector3i(3, 0, 7)
			),
			_placement(
				"store_0",
				Slice01Archetypes.cargo_store(),
				Vector3i(7, 0, 7)
			),
		]
	)
	blueprint.allow_disconnected = true
	return blueprint


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


func _placement_facing(
	local_id: String,
	archetype: ElementArchetype,
	cell: Vector3i,
	local_face: OrientationUtil.Face,
	world_face: OrientationUtil.Face
) -> BlueprintElementPlacement:
	var placement := _placement(local_id, archetype, cell)
	for orientation_index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if (
			OrientationUtil.rotate_face(local_face, orientation_index)
			== world_face
		):
			placement.orientation_index = orientation_index
			return placement
	return placement


func _foundation_span(
	id_prefix: String,
	from_x: int,
	to_x: int,
	z: int
) -> Array[BlueprintElementPlacement]:
	var placements: Array[BlueprintElementPlacement] = []
	for x: int in range(from_x, to_x + 1):
		placements.append(
			_placement(
				"%s_%d" % [id_prefix, x],
				Slice01Archetypes.frame(),
				Vector3i(x, 0, z)
			)
		)
	return placements


func _spawn(
	world: SimulationWorld,
	blueprint: Blueprint,
	grid_frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = grid_frame
	return world.apply_structural_command_now(command)


func _make_test_element(
	element_id: int,
	assembly_id: int,
	archetype: ElementArchetype,
	cell: Vector3i
) -> IndustryV1TestElement:
	return IndustryV1TestElement.new(element_id, assembly_id, archetype, cell, 0)


func _test_drill_archetype() -> ElementArchetype:
	var base := Slice01Archetypes.stationary_drill().duplicate(true)
	_set_port_pose(
		base,
		"cargo_out",
		Vector3i(1, 0, 0),
		OrientationUtil.Face.POS_X
	)
	return base


func _test_cargo_store_archetype() -> ElementArchetype:
	var base := Slice01Archetypes.cargo_store().duplicate(true)
	_set_port_pose(
		base,
		"cargo_in",
		Vector3i.ZERO,
		OrientationUtil.Face.NEG_X
	)
	return base


func _set_port_pose(
	archetype: ElementArchetype,
	port_id: String,
	local_cell: Vector3i,
	face: int
) -> void:
	for port: PortDefinition in archetype.ports:
		if port.port_id == port_id:
			port.local_cell = local_cell
			port.local_face = face
			return


func _test_cargo_pipe_archetype() -> ElementArchetype:
	var archetype := Slice01Archetypes.load_required("cargo_pipe").duplicate(true)
	archetype.archetype_id = "test_cargo_pipe"
	archetype.display_name = "Test Cargo Pipe"
	archetype.roles = PackedStringArray(["CargoPipe"])
	archetype.mass_kg = 20.0
	return archetype


func _run_industry_ticks(sim: IndustrySimulation, seconds: float) -> void:
	var remaining := seconds
	while remaining > EPSILON:
		var dt: float = minf(1.0 / INDUSTRY_TICK_HZ, remaining)
		sim.tick(dt)
		remaining -= dt


func _seed_element_buffer(
	element: SimulationElement,
	amounts: Dictionary
) -> void:
	element.set_industry_buffer(amounts)


func _read_element_buffer_amount(
	element: SimulationElement,
	resource_id: String
) -> float:
	if element == null:
		return 0.0
	return element.industry_buffer_amount(resource_id)


func _read_functional_reason(
	world: SimulationWorld,
	element_id: int
) -> StringName:
	var element := world.get_element(element_id)
	if element == null:
		return &""
	return element.industry_status_reason()


func _hook_drill_carve(
	sim: IndustrySimulation,
	carve_calls: Dictionary
) -> void:
	if sim.has_method("set_drill_carve_stub"):
		sim.set_drill_carve_stub(
			func(_element_id: int) -> float:
				carve_calls["count"] = int(carve_calls["count"]) + 1
				return float(carve_calls["volume"])
		)


func _fill_store_to_capacity(world: SimulationWorld) -> void:
	var store_element_id := _find_element_id_by_archetype(world, "cargo_store")
	if store_element_id < 0:
		return
	var store_id := "element:%d" % store_element_id
	var store := world.ensure_resource_store(store_id)
	if store == null:
		return
	store.set_amount("ore_mare_regolith", 1000.0)


func _wire_integration_power(world: SimulationWorld) -> void:
	var source_id := _find_element_id_by_archetype(world, "power_source")
	var distributor_id := _find_element_id_by_archetype(
		world,
		"power_distributor"
	)
	if source_id < 0 or distributor_id < 0:
		return
	world.connect_network(
		source_id,
		"power_out",
		distributor_id,
		"power_in"
	)


func _seed_integration_inputs(world: SimulationWorld) -> void:
	var processor_id := _find_element_id_by_archetype(world, "processor")
	if processor_id >= 0:
		_seed_element_buffer(
			world.get_element(processor_id),
			{"ore_mare_regolith": 4.0, "regolith_fines": 4.0}
		)
	var fabricator_id := _find_element_id_by_archetype(world, "fabricator")
	if fabricator_id >= 0:
		_seed_element_buffer(
			world.get_element(fabricator_id),
			{"ilmenite_concentrate": 2.0, "ingot_iron": 2.0}
		)
		var runtime := world.ensure_industry_element_runtime(fabricator_id)
		runtime.ensure_machine_state().queue.append("craft_plate_metal")


func _find_element_id_by_archetype(
	world: SimulationWorld,
	archetype_id: String
) -> int:
	for element: SimulationElement in world.list_elements():
		if element.archetype_id == archetype_id:
			return element.element_id
	return -1


func _cleanup_industry(
	sim: IndustrySimulation,
	world: SimulationWorld
) -> void:
	sim.queue_free()
	world.free()


func _fail(reason: String) -> bool:
	print("INDUSTRY-V1: FAIL %s" % reason)
	get_tree().quit(1)
	return false


class IndustryV1TestElement:
	var element_id: int = 0
	var assembly_id: int = 0
	var archetype_id: String = ""
	var origin_cell: Vector3i = Vector3i.ZERO
	var orientation_index: int = 0
	var _archetype: ElementArchetype = null


	func _init(
		new_element_id: int,
		new_assembly_id: int,
		archetype: ElementArchetype,
		cell: Vector3i,
		orientation: int
	) -> void:
		element_id = new_element_id
		assembly_id = new_assembly_id
		_archetype = archetype
		archetype_id = archetype.archetype_id if archetype != null else ""
		origin_cell = cell
		orientation_index = orientation


	func get_archetype() -> ElementArchetype:
		return _archetype


	func is_operational() -> bool:
		return _archetype != null


class IndustryV1CapacityStore:
	extends RefCounted

	var capacity_l: float = 0.0
	var inner: SimulationResourceStore = SimulationResourceStore.new()
	var _catalog: Dictionary = {}


	func _init(capacity: float, catalog: Dictionary) -> void:
		capacity_l = capacity
		_catalog = catalog


	func total_volume_l() -> float:
		var total := 0.0
		for resource_id: String in inner.resource_ids():
			var entry: Dictionary = _catalog.get(resource_id, {})
			total += inner.amount(resource_id) * float(
				entry.get("volume_per_unit_l", 0.0)
			)
		return total


	func try_add(resource_id: String, amount: float) -> bool:
		if amount <= 0.0:
			return false
		if ResourceCatalog.rejects_fractional_amount(resource_id, amount):
			return false
		var entry: Dictionary = _catalog.get(resource_id, {})
		var added_volume := amount * float(entry.get("volume_per_unit_l", 0.0))
		if total_volume_l() + added_volume > capacity_l + 0.000001:
			return false
		return inner.add(resource_id, amount)
