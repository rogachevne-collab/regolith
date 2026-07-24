extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
const EPS := 0.0001


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "OXYGEN")
	if not _test_store_lifecycle_and_mass():
		return
	if not _test_atomic_refill():
		return
	if not _test_active_power_required_before_dispense():
		return
	if not _test_cargo_connectivity_and_contention():
		return
	if not _test_broken_seat_evicts_occupant():
		return
	print("OXYGEN: PASS")
	get_tree().quit(0)


func _test_store_lifecycle_and_mass() -> bool:
	var world := _make_world()
	var result := _spawn(world, [
		_placement("module", Slice01Archetypes.o2_module(), Vector3i.ZERO),
	])
	if not result.is_ok():
		return _fail("stock module blueprint did not spawn")
	var module_id := int(result.data["element_ids"][0])
	var module := world.get_element(module_id)
	var store := IndustryStoreService.ensure_element_keyed_store(world, module)
	if absf(store.amount("oxygen") - 100.0) > EPS:
		return _fail("initial 200 L was not seeded as 100 bulk units")
	if store.add("plate_metal", 1.0):
		return _fail("oxygen module accepted a non-oxygen item")
	var transfer := CargoTransferService.new().transfer_between_stores(
		world,
		IndustryStoreService.element_store_id(module_id),
		PlayerIdentity.store_id("player"),
		"oxygen",
		1.0
	)
	if StringName(transfer.get("reason", &"")) != &"transfer_blocked":
		return _fail("generic transfer drained oxygen module")
	world.set_resource_amount(PlayerIdentity.store_id("player"), "oxygen", 10.0)
	var inbound := CargoTransferService.new().transfer_between_stores(
		world,
		PlayerIdentity.store_id("player"),
		IndustryStoreService.element_store_id(module_id),
		"oxygen",
		1.0
	)
	if StringName(inbound.get("reason", &"")) != &"transfer_blocked":
		return _fail("generic cargo transfer refilled oxygen module")
	var recipe := EnqueueRecipeCommand.new()
	recipe.element_id = module_id
	recipe.recipe_id = "oxygen"
	if StringName(world.apply_enqueue_recipe(recipe).get("reason", &"")) == &"ok":
		return _fail("oxygen module accepted recipe ingress")
	var expected_mass := module.dry_mass_kg() + 20.0
	if absf(world.get_element_content_mass_kg(module_id) - 20.0) > EPS:
		return _fail("module oxygen mass did not use ResourceCatalog conversion")
	if absf(IndustryStoreService.total_mass_kg(world, module) - expected_mass) > EPS:
		return _fail("module total mass coupling is wrong")
	store.set_amount("oxygen", 7.0)
	IndustryStoreService.sync_element_storage(world, module)
	if absf(store.amount("oxygen") - 7.0) > EPS:
		return _fail("ordinary resync re-seeded module")
	var snapshot := world.capture_snapshot()
	if not world.restore_snapshot(snapshot, false):
		return _fail("oxygen module snapshot did not restore")
	module = world.get_element(module_id)
	store = world.get_resource_store(IndustryStoreService.element_store_id(module_id))
	if store == null or absf(store.amount("oxygen") - 7.0) > EPS:
		return _fail("snapshot restore re-seeded module")
	var player_store_id := PlayerIdentity.store_id("builder")
	world.set_resource_amount(player_store_id, "plate_metal", 100.0)
	module.integrity = module.get_archetype().max_integrity * 0.05
	module.sync_build_progress_from_integrity()
	var weld := WeldElementCommand.new()
	weld.element_id = module_id
	weld.expected_state_revision = module.state_revision
	weld.store_id = player_store_id
	weld.max_material_amount = 100.0
	if not world.apply_structural_command_now(weld).is_ok():
		return _fail("existing oxygen module weld failed")
	if absf(store.amount("oxygen") - 7.0) > EPS:
		return _fail("weld re-seeded an existing oxygen module")
	var damage := DamageElementCommand.new()
	damage.element_id = module_id
	damage.expected_state_revision = module.state_revision
	damage.damage = module.get_archetype().max_integrity * 0.1
	if not world.apply_structural_command_now(damage).is_ok():
		return _fail("oxygen module damage fixture failed")
	var repair := RepairElementCommand.new()
	repair.element_id = module_id
	repair.expected_state_revision = module.state_revision
	repair.store_id = player_store_id
	repair.max_material_amount = 100.0
	if not world.apply_structural_command_now(repair).is_ok():
		return _fail("existing oxygen module repair failed")
	if absf(store.amount("oxygen") - 7.0) > EPS:
		return _fail("repair re-seeded an existing oxygen module")
	_free_world(world)
	return true


func _test_atomic_refill() -> bool:
	var world := _make_world()
	var result := _spawn(world, [
		_placement("module", Slice01Archetypes.o2_module(), Vector3i.ZERO),
		_placement("frame", Slice01Archetypes.frame(), Vector3i(1, 0, 0)),
		_placement("frame_corner", Slice01Archetypes.frame(), Vector3i(1, 0, 1)),
		_placement(
			"distributor",
			Slice01Archetypes.load_required("power_distributor"),
			Vector3i(2, 0, 1)
		),
		_placement("source", Slice01Archetypes.power_source(), Vector3i(4, 0, 0)),
	])
	if not result.is_ok():
		return _fail("powered refill fixture did not spawn: %s" % result.reason)
	var powered_ids: Dictionary = result.data["local_to_element_id"]
	if not world.connect_network(
		int(powered_ids["source"]),
		"power_out",
		int(powered_ids["distributor"]),
		"power_in"
	).is_ok():
		return _fail("powered refill source link failed")
	var module_id := int(result.data["element_ids"][0])
	var module := world.get_element(module_id)
	var store := IndustryStoreService.ensure_element_keyed_store(world, module)
	store.set_amount("oxygen", 0.25) # 0.5 L
	var suit := world.ensure_suit_state("player")
	suit.set_oxygen(99.8)
	var command := OxygenRefillCommand.new()
	command.player_id = "player"
	command.module_element_id = module_id
	command.delta_s = 1000.0 # Untrusted caller value must be ignored.
	var queued := world.apply_oxygen_refill(command)
	if StringName(queued.get("reason", &"")) != &"queued":
		return _fail("manual refill intent was not queued")
	if absf(suit.oxygen - 99.8) > EPS or absf(store.amount("oxygen") - 0.25) > EPS:
		return _fail("manual intent dispensed before industry cadence")
	world.industry_tick(0.24)
	if absf(suit.oxygen - 99.8) > EPS:
		return _fail("manual refill trusted caller cadence")
	world.industry_tick(0.01)
	if absf(suit.oxygen - 99.925) > EPS:
		var failed_runtime := world.get_industry_element_runtime(module_id)
		return _fail(
			"atomic refill did not fill suit exactly (o2=%.3f power=%s reason=%s)"
			% [
				suit.oxygen,
				failed_runtime.powered if failed_runtime != null else false,
				failed_runtime.power_reason if failed_runtime != null else &"missing",
			]
		)
	if absf(store.amount("oxygen") - 0.1875) > EPS:
		return _fail("module did not consume exactly accepted liters")
	if not IndustryElectricProfile.is_power_consumer(module):
		return _fail("oxygen module is not an electric consumer")
	var runtime := world.ensure_industry_element_runtime(module_id)
	runtime.dynamic_power_w = module.get_archetype().oxygen_module_definition.active_w
	if absf(
		runtime.demand_w(module)
		- (
			module.get_archetype().oxygen_module_definition.idle_w
			+ module.get_archetype().oxygen_module_definition.active_w
		)
	) > EPS:
		return _fail("active dispense power demand is wrong")
	var toggle := SetMachineEnabledCommand.new()
	toggle.element_id = module_id
	toggle.enabled = false
	var toggle_result := world.apply_set_machine_enabled(toggle)
	if (
		StringName(toggle_result.get("reason", &"")) != &"ok"
		or runtime.machine_enabled
		or runtime.demand_w(module) != 0.0
	):
		return _fail("existing machine-enabled command did not disable module")
	_free_world(world)
	return true


func _test_active_power_required_before_dispense() -> bool:
	var world := _make_world()
	var weak_module := Slice01Archetypes.o2_module()
	var original_active_w := weak_module.oxygen_module_definition.active_w
	weak_module.oxygen_module_definition.active_w = 1000000.0
	var result := _spawn(world, [
		_placement("module", weak_module, Vector3i.ZERO),
		_placement("frame", Slice01Archetypes.frame(), Vector3i(1, 0, 0)),
		_placement("frame_corner", Slice01Archetypes.frame(), Vector3i(1, 0, 1)),
		_placement(
			"distributor",
			Slice01Archetypes.load_required("power_distributor"),
			Vector3i(2, 0, 1)
		),
		_placement("source", Slice01Archetypes.power_source(), Vector3i(4, 0, 0)),
	])
	if not result.is_ok():
		return _fail("active-power fixture did not spawn")
	var weak_ids: Dictionary = result.data["local_to_element_id"]
	if not world.connect_network(
		int(weak_ids["source"]),
		"power_out",
		int(weak_ids["distributor"]),
		"power_in"
	).is_ok():
		return _fail("active-power source link failed")
	var module_id := int(result.data["local_to_element_id"]["module"])
	var module := world.get_element(module_id)
	var store := IndustryStoreService.ensure_element_keyed_store(world, module)
	var before_units := store.amount("oxygen")
	var suit := world.ensure_suit_state("power_test")
	suit.set_oxygen(0.0)
	var command := OxygenRefillCommand.new()
	command.player_id = "power_test"
	command.module_element_id = module_id
	command.delta_s = 999.0
	if StringName(world.apply_oxygen_refill(command).get("reason", &"")) != &"queued":
		return _fail("active-power intent was not queued")
	world.industry_tick(0.25)
	if suit.oxygen > EPS or absf(store.amount("oxygen") - before_units) > EPS:
		return _fail("oxygen dispensed before active power was budgeted")
	var runtime := world.get_industry_element_runtime(module_id)
	if runtime == null or runtime.powered:
		return _fail("insufficient active demand did not mark module unpowered")
	weak_module.oxygen_module_definition.active_w = original_active_w
	_free_world(world)
	return true


func _test_cargo_connectivity_and_contention() -> bool:
	var world := _make_world()
	var result := _spawn(world, [
		_placement("module", Slice01Archetypes.o2_module(), Vector3i(-2, 0, 0)),
		_placement("pipe", Slice01Archetypes.cargo_pipe(), Vector3i(-1, 0, 0)),
		_placement("seat", Slice01Archetypes.cockpit(), Vector3i.ZERO),
		_placement(
			"module_tie",
			Slice01Archetypes.o2_module(),
			Vector3i(-1, 0, 1),
			_orientation_for_x(Vector3i.FORWARD)
		),
		_placement("disconnected", Slice01Archetypes.o2_module(), Vector3i(3, 0, 0)),
	])
	if not result.is_ok():
		return _fail("cockpit/pipe/module fixture did not spawn")
	var ids: Dictionary = result.data["local_to_element_id"]
	var module_id := int(ids["module"])
	var module_tie_id := int(ids["module_tie"])
	var seat_id := int(ids["seat"])
	var disconnected_id := int(ids["disconnected"])
	var graph := world.ensure_cargo_graph_current()
	if graph.shortest_hop_distance(seat_id, module_id) != 2:
		return _fail("pipe cargo path did not produce two hops")
	if graph.shortest_hop_distance(seat_id, module_tie_id) != 2:
		return _fail("tie module was not in the same two-hop component")
	if graph.shortest_hop_distance(seat_id, disconnected_id) >= 0:
		return _fail("same-assembly cargo-disconnected module became eligible")
	for player_id: String in ["a", "b"]:
		world.ensure_suit_state(player_id).set_oxygen(0.0)
		if not world.register_player_seat_context(player_id, seat_id):
			return _fail("seat context registration failed")
	var service := OxygenRefillService.new()
	var lower_store := IndustryStoreService.ensure_element_keyed_store(
		world, world.get_element(module_id)
	)
	lower_store.set_amount("oxygen", 0.05) # 0.1 L, identifies lower-id claim.
	service.prepare_auto_refill(world, graph, 1.0)
	world.ensure_industry_element_runtime(module_id).powered = true
	world.ensure_industry_element_runtime(module_tie_id).powered = true
	service.execute_auto_refill(world)
	var a := world.get_suit_state("a").oxygen
	var b := world.get_suit_state("b").oxygen
	if absf(a - 0.1) > EPS or absf(b - 0.5) > EPS:
		return _fail("players did not claim distinct nearest modules by id order")
	world.clear_player_seat_context("b")
	world.get_suit_state("a").set_oxygen(0.0)
	service.prepare_auto_refill(world, graph, 0.25)
	world.ensure_industry_element_runtime(module_tie_id).powered = true
	service.execute_auto_refill(world)
	if world.get_suit_state("a").oxygen <= EPS:
		return _fail("empty nearest module blocked a farther usable module")
	world.get_suit_state("a").set_oxygen(0.0)
	world.ensure_industry_element_runtime(module_tie_id).machine_enabled = false
	service.prepare_auto_refill(world, graph, 0.25)
	service.execute_auto_refill(world)
	if world.get_suit_state("a").oxygen > EPS:
		return _fail("disabled module was claimed for auto refill")
	world.ensure_industry_element_runtime(module_tie_id).machine_enabled = true
	service.prepare_auto_refill(world, graph, 0.25)
	world.ensure_industry_element_runtime(module_tie_id).powered = false
	service.execute_auto_refill(world)
	if world.get_suit_state("a").oxygen > EPS:
		return _fail("unpowered auto-refill module dispensed oxygen")
	world.clear_player_seat_context("a")
	world.clear_player_seat_context("b")
	if not world.list_seat_context_player_ids().is_empty():
		return _fail("seat contexts did not clear")
	var snapshot := world.capture_snapshot()
	if snapshot.has("player_seat_contexts"):
		return _fail("ephemeral seat occupancy leaked into snapshot")
	_free_world(world)

	var direct_world := _make_world()
	var direct := _spawn(direct_world, [
		_placement("module", Slice01Archetypes.o2_module(), Vector3i(-1, 0, 0)),
		_placement("seat", Slice01Archetypes.cockpit(), Vector3i.ZERO),
	])
	if not direct.is_ok():
		return _fail("direct cockpit/module fixture did not spawn")
	var direct_ids: Dictionary = direct.data["local_to_element_id"]
	if direct_world.ensure_cargo_graph_current().shortest_hop_distance(
		int(direct_ids["seat"]),
		int(direct_ids["module"])
	) != 1:
		return _fail("direct cockpit cargo connection was not discovered")
	_free_world(direct_world)
	return true


## Broken / removed ControlSeat must emit seat_occupant_evicted and clear
## occupancy — silent prune was the coop "stuck in wreck" trap.
func _test_broken_seat_evicts_occupant() -> bool:
	var world := _make_world()
	var spawned := _spawn(world, [
		_placement("seat", Slice01Archetypes.cockpit(), Vector3i.ZERO),
	])
	if not spawned.is_ok():
		return _fail("seat fixture did not spawn for eviction test")
	var seat_id := int(spawned.data["local_to_element_id"]["seat"])
	if not world.register_player_seat_context("driver", seat_id):
		return _fail("register seat context failed")
	var seen: Array = []
	world.seat_occupant_evicted.connect(
		func(player_id: String, element_id: int, assembly_id: int) -> void:
			seen.append({
				"player_id": player_id,
				"element_id": element_id,
				"assembly_id": assembly_id,
			})
	)
	var seat := world.get_element(seat_id)
	seat.integrity = 0.0
	seat.sync_build_progress_from_integrity()
	if seat.is_operational():
		return _fail("seat should be non-operational after integrity zero")
	world.prune_seat_contexts()
	if world.get_player_seat_element_id("driver") != 0:
		return _fail("prune must clear occupancy for a broken seat")
	if seen.is_empty():
		return _fail("prune must emit seat_occupant_evicted")
	if str(seen[0].get("player_id", "")) != "driver":
		return _fail("eviction signal player_id mismatch")
	if int(seen[0].get("element_id", 0)) != seat_id:
		return _fail("eviction signal seat_element_id mismatch")
	if int(seen[0].get("assembly_id", 0)) <= 0:
		return _fail("eviction signal must carry assembly_id")
	_free_world(world)
	return true


func _make_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	add_child(world)
	return world


func _free_world(world: SimulationWorld) -> void:
	if world._industry_runner != null:
		world._industry_runner.free()
		world._industry_runner = null
	remove_child(world)
	world.free()


func _placement(
	local_id: String,
	archetype: ElementArchetype,
	cell: Vector3i,
	orientation_index: int = 0
) -> BlueprintElementPlacement:
	var placement := BlueprintElementPlacement.new()
	placement.local_id = local_id
	placement.archetype = archetype
	placement.origin_cell = cell
	placement.orientation_index = orientation_index
	return placement


func _orientation_for_x(direction: Vector3i) -> int:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.rotate_direction(Vector3i.RIGHT, index) == direction:
			return index
	return 0


func _spawn(
	world: SimulationWorld,
	placements: Array[BlueprintElementPlacement]
) -> StructuralCommandResult:
	var blueprint := Blueprint.new()
	blueprint.blueprint_id = "oxygen_test"
	blueprint.placements = placements
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = GridTransform.new()
	return world.apply_structural_command_now(command)


func _fail(message: String) -> bool:
	push_error("OXYGEN: FAIL - %s" % message)
	print("OXYGEN: FAIL - %s" % message)
	get_tree().quit(1)
	return false
