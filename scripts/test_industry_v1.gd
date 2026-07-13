extends Node

## Headless acceptance scaffold for docs/specs/INDUSTRY-V1.md.
## Uses test-only fixtures; does not modify production archetypes or runtime.

const EPSILON := 0.000001
const PLAYER_CARRY_CAPACITY_KG := 80.0
const INDUSTRY_TICK_HZ := 1.0
const INDUSTRY_SIMULATION_SCRIPT := preload(
	"res://scripts/simulation/industry/industry_simulation.gd"
)

const RESOURCE_CATALOG: Dictionary = {
	"raw_regolith": 2.0,
	"regolith_fines": 1.5,
	"sintered_basalt": 3.0,
	"calcined_oxide": 1.2,
	"metal_ingot": 4.0,
	"construction_component": 2.5,
}

const RECIPE_FIXTURES: Dictionary = {
	"crush_regolith": {
		"machine": "Processor",
		"inputs": {"raw_regolith": 1.0},
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
	"calcine_fines": {
		"machine": "Processor",
		"inputs": {"regolith_fines": 2.0},
		"outputs": {"calcined_oxide": 1.0},
		"duration_s": 10.0,
		"power_w": 400.0,
	},
	"reduce_oxide": {
		"machine": "Fabricator",
		"inputs": {"calcined_oxide": 1.0},
		"outputs": {"metal_ingot": 1.0},
		"duration_s": 12.0,
		"power_w": 600.0,
	},
	"sinter_component": {
		"machine": "Fabricator",
		"inputs": {"metal_ingot": 1.0},
		"outputs": {"construction_component": 1.0},
		"duration_s": 10.0,
		"power_w": 500.0,
	},
}

func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var tests: Array[Callable] = [
		_test_resource_catalog_contract,
		_test_capacity_store_no_overflow,
		_test_capacity_store_no_loss_on_reject,
		_test_player_carry_capacity_fixture,
		_test_mass_coupling_reference,
		_test_recipe_fixture_chain,
		_test_cargo_graph_reference_adjacency,
		_test_cargo_graph_spawned_topology,
		_test_cargo_connect_network_absent_or_rejects_cargo,
		_test_electric_connect_network_runtime,
		_test_industry_simulation_tick_runtime,
		_test_drill_mining_storage_full_runtime,
		_test_integration_isru_scenario,
	]
	for test: Callable in tests:
		if not bool(await test.call()):
			return
	print("INDUSTRY-V1: PASS")
	get_tree().quit(0)


func _test_resource_catalog_contract() -> bool:
	for resource_id: String in RESOURCE_CATALOG.keys():
		if not ResourceCatalog.has_resource(resource_id):
			return _fail("ResourceCatalog missing %s" % resource_id)
		if not is_equal_approx(
			ResourceCatalog.mass_per_unit_kg(resource_id),
			float(RESOURCE_CATALOG[resource_id])
		):
			return _fail(
				"ResourceCatalog mass mismatch for %s" % resource_id
			)
		if RESOURCE_CATALOG[resource_id] <= 0.0:
			return _fail("catalog mass must be positive for %s" % resource_id)
	var fines_mass: float = _catalog_mass({"regolith_fines": 2.0})
	if not is_equal_approx(fines_mass, 3.0):
		return _fail("catalog mass sum expected 3.0 kg, got %.3f" % fines_mass)
	return true


func _test_capacity_store_no_overflow() -> bool:
	var store := _capacity_store(6.0)
	if not store.try_add("raw_regolith", 2.0):
		return _fail("expected first add to succeed")
	if not store.try_add("raw_regolith", 1.0):
		return _fail("expected second add within capacity to succeed")
	if store.try_add("raw_regolith", 1.0):
		return _fail("overflow add must be rejected")
	if not is_equal_approx(store.total_mass_kg(), 6.0):
		return _fail(
			"store mass after rejected overflow expected 6.0, got %.3f"
			% store.total_mass_kg()
		)
	return true


func _test_capacity_store_no_loss_on_reject() -> bool:
	var store := _capacity_store(4.0)
	store.try_add("metal_ingot", 1.0)
	var before: float = store.inner.amount("metal_ingot")
	if store.try_add("metal_ingot", 1.0):
		return _fail("expected capacity rejection")
	if not is_equal_approx(store.inner.amount("metal_ingot"), before):
		return _fail("rejected add mutated store contents")
	return true


func _test_player_carry_capacity_fixture() -> bool:
	var player := _capacity_store(PLAYER_CARRY_CAPACITY_KG)
	if not player.try_add("construction_component", 30.0):
		return _fail("player store should accept 30 components (75 kg)")
	if player.try_add("construction_component", 3.0):
		return _fail("player store must reject exceeding 80 kg carry limit")
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
	element.set_industry_buffer({"raw_regolith": 2.5})
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
	if not RECIPE_FIXTURES.has("crush_regolith"):
		return _fail("missing crush_regolith fixture")
	var basalt_inputs: Dictionary = RECIPE_FIXTURES["sinter_basalt"]["inputs"]
	var basalt_outputs: Dictionary = RECIPE_FIXTURES["sinter_basalt"]["outputs"]
	if float(basalt_inputs["regolith_fines"]) != 2.0:
		return _fail("sinter_basalt fixture expects 2 fines input")
	if float(basalt_outputs["sintered_basalt"]) != 1.0:
		return _fail("sinter_basalt fixture expects 1 basalt output")
	var component_recipe: Dictionary = RECIPE_FIXTURES["sinter_component"]
	if str(component_recipe["machine"]) != "Fabricator":
		return _fail("sinter_component must run on Fabricator")
	var chain := [
		"crush_regolith",
		"calcine_fines",
		"reduce_oxide",
		"sinter_component",
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


func _test_cargo_connect_network_absent_or_rejects_cargo() -> bool:
	return await _assert_connect_network_rejects_cargo_ports()


func _test_electric_connect_network_runtime() -> bool:
	return await _run_electric_wire_scenario()


func _test_industry_simulation_tick_runtime() -> bool:
	return await _run_recipe_tick_scenario()


func _test_drill_mining_storage_full_runtime() -> bool:
	return await _run_drill_storage_full_scenario()


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
	var overlength := world.connect_network(
		source_id,
		"power_out",
		outside_id,
		"power_in"
	)
	if (
		overlength.is_ok()
		or overlength.reason != StructuralCommandResult.REASON_CABLE_TOO_LONG
	):
		world.free()
		return _fail("overlength electric cable must be rejected")
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
	processor.set_industry_buffer({"raw_regolith": 1.0})
	var sim: IndustrySimulation = INDUSTRY_SIMULATION_SCRIPT.new()
	add_child(sim)
	sim.bind_world(world)
	_run_industry_ticks(sim, 7.0)
	var fines_amount := processor.industry_buffer_amount("regolith_fines")
	if fines_amount + EPSILON < 1.0:
		sim.queue_free()
		world.free()
		return _fail(
			"crush_regolith tick expected >=1 fines, got %.3f" % fines_amount
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
		"raw_regolith"
	)
	if raw_before <= EPSILON and carve_calls["count"] == 0:
		sim.queue_free()
		world.free()
		return _fail("drill did not credit raw_regolith with mocked carve")
	_fill_store_to_capacity(world)
	_run_industry_ticks(sim, 2.0)
	var reason := _read_functional_reason(world, drill_id)
	if reason != &"storage_full":
		sim.queue_free()
		world.free()
		return _fail(
			"drill expected storage_full when outbound blocked, got %s" % str(reason)
		)
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
	if component_amount.amount("construction_component") + EPSILON < 1.0:
		var fabricator_id := _find_element_id_by_archetype(world, "fabricator")
		var fabricator := world.get_element(fabricator_id)
		var fabricator_buffer := str(fabricator.industry_buffer.to_dict())
		var fabricator_reason := str(fabricator.industry_status_reason())
		sim.queue_free()
		world.free()
		return _fail(
			(
				"integration ISRU expected construction_component >=1 after %.0f s "
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


func _capacity_store(capacity_kg: float) -> RefCounted:
	return IndustryV1CapacityStore.new(capacity_kg, RESOURCE_CATALOG)


func _catalog_mass(amounts: Dictionary) -> float:
	var total := 0.0
	for resource_id: Variant in amounts.keys():
		var mass_per_unit: float = float(
			RESOURCE_CATALOG.get(str(resource_id), 0.0)
		)
		total += float(amounts[resource_id]) * mass_per_unit
	return total


func _element_mass_kg(dry_mass_kg: float, buffer: Dictionary) -> float:
	return dry_mass_kg + _catalog_mass(buffer)


func _line_topology_elements() -> Array:
	var drill := _make_test_element(
		101,
		1,
		_test_drill_archetype(),
		Vector3i(1, 0, 0)
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
				"foundation_0",
				Slice01Archetypes.foundation(),
				Vector3i(-1, 0, 0)
			),
			_placement(
				"source_0",
				Slice01Archetypes.power_source(),
				Vector3i(0, 0, -2)
			),
			_placement(
				"distributor_0",
				Slice01Archetypes.load_required("power_distributor"),
				Vector3i(0, 0, -1)
			),
			_placement(
				"drill_0",
				Slice01Archetypes.stationary_drill(),
				Vector3i.ZERO
			),
			_placement(
				"pipe_corner",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(0, 0, 1)
			),
			_placement(
				"pipe_east",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(1, 0, 1)
			),
			_placement_facing(
				"store_0",
				Slice01Archetypes.cargo_store(),
				Vector3i(2, 0, 1),
				OrientationUtil.Face.NEG_Z,
				OrientationUtil.Face.NEG_X
			),
		]
	)


func _electric_cable_blueprint() -> Blueprint:
	var placements: Array[BlueprintElementPlacement] = [
		_placement(
			"foundation_0",
			Slice01Archetypes.foundation(),
			Vector3i(-1, 0, 0)
		),
		_placement(
			"source_0",
			Slice01Archetypes.power_source(),
			Vector3i.ZERO
		),
		_placement(
			"distributor_0",
			Slice01Archetypes.load_required("power_distributor"),
			Vector3i(3, 0, 0)
		),
		_placement(
			"processor_0",
			Slice01Archetypes.processor(),
			Vector3i(3, 0, 1)
		),
		_placement(
			"fabricator_outside",
			Slice01Archetypes.fabricator(),
			Vector3i(16, 0, 1)
		),
	]
	placements.append_array(_foundation_span("cable_frame", 1, 2, 0))
	placements.append_array(_foundation_span("radius_frame", 4, 15, 1))
	return BlueprintBaker.bake_from_placements(
		"industry_v1_distance_cable",
		placements
	)


func _integration_blueprint() -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"industry_v1_integration",
		[
			_placement(
				"foundation_0",
				Slice01Archetypes.foundation(),
				Vector3i(-1, 0, 0)
			),
			_placement(
				"power_0",
				Slice01Archetypes.power_source(),
				Vector3i(0, 0, -1)
			),
			_placement(
				"distributor_0",
				Slice01Archetypes.load_required("power_distributor"),
				Vector3i.ZERO
			),
			_placement(
				"drill_0",
				Slice01Archetypes.stationary_drill(),
				Vector3i(1, 0, 0)
			),
			_placement(
				"pipe_corner",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(1, 0, 1)
			),
			_placement(
				"pipe_east",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(2, 0, 1)
			),
			_placement_facing(
				"processor_0",
				Slice01Archetypes.processor(),
				Vector3i(3, 0, 1),
				OrientationUtil.Face.NEG_Z,
				OrientationUtil.Face.NEG_X
			),
			_placement(
				"pipe_after_processor",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(4, 0, 1)
			),
			_placement_facing(
				"fabricator_0",
				Slice01Archetypes.fabricator(),
				Vector3i(5, 0, 1),
				OrientationUtil.Face.NEG_Z,
				OrientationUtil.Face.NEG_X
			),
			_placement(
				"pipe_after_fabricator",
				Slice01Archetypes.load_required("cargo_pipe"),
				Vector3i(6, 0, 1)
			),
			_placement_facing(
				"store_0",
				Slice01Archetypes.cargo_store(),
				Vector3i(7, 0, 1),
				OrientationUtil.Face.NEG_Z,
				OrientationUtil.Face.NEG_X
			),
		]
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
				Slice01Archetypes.foundation(),
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
	_set_port_face(base, "cargo_out", OrientationUtil.Face.POS_X)
	return base


func _test_cargo_store_archetype() -> ElementArchetype:
	var base := Slice01Archetypes.cargo_store().duplicate(true)
	_set_port_face(base, "cargo_in", OrientationUtil.Face.NEG_X)
	return base


func _set_port_face(
	archetype: ElementArchetype,
	port_id: String,
	face: int
) -> void:
	for port: PortDefinition in archetype.ports:
		if port.port_id == port_id:
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
	store.set_amount("raw_regolith", 1000.0)


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
			{"raw_regolith": 4.0, "regolith_fines": 4.0}
		)
	var fabricator_id := _find_element_id_by_archetype(world, "fabricator")
	if fabricator_id >= 0:
		_seed_element_buffer(
			world.get_element(fabricator_id),
			{"calcined_oxide": 2.0, "metal_ingot": 2.0}
		)


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

	var capacity_kg: float = 0.0
	var inner: SimulationResourceStore = SimulationResourceStore.new()
	var _catalog: Dictionary = {}


	func _init(capacity: float, catalog: Dictionary) -> void:
		capacity_kg = capacity
		_catalog = catalog


	func total_mass_kg() -> float:
		var total := 0.0
		for resource_id: String in inner.resource_ids():
			total += inner.amount(resource_id) * float(
				_catalog.get(resource_id, 0.0)
			)
		return total


	func try_add(resource_id: String, amount: float) -> bool:
		if amount <= 0.0:
			return false
		var added_mass := amount * float(_catalog.get(resource_id, 0.0))
		if total_mass_kg() + added_mass > capacity_kg + 0.000001:
			return false
		return inner.add(resource_id, amount)
