class_name IndustrySimulation
extends Node

const TICK_HZ := 4.0

var _world: SimulationWorld
var _cargo_graph := CargoGraph.new()
var _transfer_service := CargoTransferService.new()
var _recipe_runner := RecipeRunnerService.new()
var _drill_service := StationaryDrillService.new()
var _dozer_service := DozerBladeService.new()
var _tick_accumulator := 0.0
var _event_bound := false


func bind_world(world: SimulationWorld) -> void:
	_world = world
	if _world != null and not _event_bound:
		_world.structural_event.connect(_on_structural_event)
		_event_bound = true
	_rebuild_from_world()


func bind(world: SimulationWorld) -> void:
	bind_world(world)


func get_cargo_graph() -> CargoGraph:
	return _cargo_graph


func get_transfer_service() -> CargoTransferService:
	return _transfer_service


func set_drill_carve_stub(stub: Callable) -> void:
	_drill_service.set_drill_carve_stub(stub)


func set_drill_terrain_hooks(
	contact_probe: Callable,
	carve: Callable,
	carve_point: Callable = Callable()
) -> void:
	_drill_service.set_drill_terrain_hooks(contact_probe, carve, carve_point)


func set_dozer_blade_load_stub(stub: Callable) -> void:
	_dozer_service.set_dozer_blade_load_stub(stub)


func set_dozer_blade_hooks(
	contact_probe: Callable,
	load_hook: Callable,
	plow_hook: Callable,
	contact_point: Callable = Callable()
) -> void:
	_dozer_service.set_dozer_blade_hooks(
		contact_probe,
		load_hook,
		plow_hook,
		contact_point
	)


func tick(world_or_dt: Variant, delta_s: float = -1.0) -> void:
	if delta_s < 0.0:
		if _world == null:
			return
		tick(_world, float(world_or_dt))
		return
	var world := world_or_dt as SimulationWorld
	if world == null or delta_s <= 0.0:
		return
	_world = world
	_world.advance_industry_time(delta_s)
	_tick_accumulator += delta_s
	var tick_interval := 1.0 / TICK_HZ
	while _tick_accumulator >= tick_interval:
		_tick_accumulator -= tick_interval
		_tick_once(world, tick_interval)


func apply_transfer_command(
	command: TransferResourceCommand
) -> Dictionary:
	if _world == null:
		return {
			"status": &"failed",
			"reason": &"not_ready",
			"amount": 0.0,
		}
	return _transfer_service.transfer_resource_command(_world, command)


func apply_set_machine_enabled(command: SetMachineEnabledCommand) -> Dictionary:
	if _world == null:
		return {"status": &"failed", "reason": &"not_ready"}
	var element := _world.get_element(command.element_id)
	if element != null and (
		element.archetype_id == "stationary_drill"
		or element.archetype_id.begins_with("test_stationary_drill")
	):
		return _drill_service.apply_set_machine_enabled(_world, command)
	if element != null and (
		element.archetype_id == "dozer_blade"
		or element.archetype_id.begins_with("test_dozer_blade")
	):
		return _dozer_service.apply_set_machine_enabled(_world, command)
	_cargo_graph = _world.ensure_cargo_graph_current()
	return _recipe_runner.apply_set_machine_enabled(
		_world,
		command,
		_cargo_graph,
		_transfer_service
	)


func apply_enqueue_recipe(command: EnqueueRecipeCommand) -> Dictionary:
	if _world == null:
		return {"status": &"failed", "reason": &"not_ready"}
	_cargo_graph = _world.ensure_cargo_graph_current()
	return _recipe_runner.apply_enqueue_recipe(
		_world,
		command,
		_cargo_graph,
		_transfer_service
	)


func apply_dequeue_recipe(command: DequeueRecipeCommand) -> Dictionary:
	if _world == null:
		return {"status": &"failed", "reason": &"not_ready"}
	_cargo_graph = _world.ensure_cargo_graph_current()
	return _recipe_runner.apply_dequeue_recipe(
		_world,
		command,
		_cargo_graph,
		_transfer_service
	)


func _tick_once(world: SimulationWorld, tick_interval: float) -> void:
	_cargo_graph = world.ensure_cargo_graph_current()
	world.get_industry_network().ensure_graph_current(world)
	IndustryElectricBudget.apply_tick(world, tick_interval)
	_recipe_runner.tick(
		world,
		_cargo_graph,
		_transfer_service,
		tick_interval
	)
	_drill_service.tick(
		world,
		_cargo_graph,
		_transfer_service,
		tick_interval
	)
	_dozer_service.tick(
		world,
		_cargo_graph,
		_transfer_service,
		tick_interval
	)
	_transfer_service.auto_transfer_tick(world, _cargo_graph)
	_transfer_service.machine_cargo_tick(world, _cargo_graph)
	_sync_machine_power_draw(world)


func _sync_machine_power_draw(world: SimulationWorld) -> void:
	for element: SimulationElement in world.list_elements():
		if not IndustryArchetypeProfile.is_recipe_machine(element.archetype_id):
			continue
		var runtime := world.get_industry_element_runtime(element.element_id)
		if runtime == null:
			continue
		var machine := runtime.ensure_machine_state()
		if machine.active_recipe_id.is_empty():
			runtime.active_recipe_power_w = 0.0


func _on_structural_event(event: Dictionary) -> void:
	var kind := StringName(event.get("kind", &""))
	if kind == &"element_state_changed":
		_on_element_state_changed(event)
		return
	match kind:
		&"world_restored", &"assembly_spawned", &"assembly_changed", &"assembly_removed", &"assembly_split", &"assembly_merged", &"electric_link_added", &"electric_link_removed":
			_on_topology_or_state_changed(event)


func _on_element_state_changed(event: Dictionary) -> void:
	if _world == null:
		return
	if StringName(event.get("change_kind", &"")) == &"damage":
		return
	if bool(event.get("operational_changed", false)):
		_rebuild_from_world()


func _on_topology_or_state_changed(event: Dictionary) -> void:
	if _world == null:
		return
	var kind := StringName(event.get("kind", &""))
	if kind == &"world_restored" or _needs_cargo_graph_rebuild():
		_rebuild_from_world()


func _needs_cargo_graph_rebuild() -> bool:
	for assembly: SimulationAssembly in _world.list_assemblies():
		if assembly.tombstoned:
			continue
		if _cargo_graph.needs_rebuild_for_assembly(
			assembly.assembly_id,
			assembly.topology_revision
		):
			return true
	return false


func _rebuild_from_world() -> void:
	if _world == null:
		return
	IndustryStoreService.sync_all_elements(_world)
	_cargo_graph.rebuild(_world)
