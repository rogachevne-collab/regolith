class_name StationaryDrillService
extends RefCounted

const EPSILON := 0.000001

var _drill_contact_probe: Callable = Callable()
var _drill_carve: Callable = Callable()
var _material_source := TerrainMaterialSource.new()


func set_drill_carve_stub(stub: Callable) -> void:
	# Compatibility hook for deterministic headless fixtures. A carve stub also
	# implies contact unless the test installs an explicit probe.
	_drill_carve = stub
	_drill_contact_probe = func(_element_id: int) -> bool: return true


func set_drill_terrain_hooks(
	contact_probe: Callable,
	carve: Callable
) -> void:
	_drill_contact_probe = contact_probe
	_drill_carve = carve


func tick(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	dt: float
) -> void:
	if world == null or dt <= 0.0:
		return
	for element: SimulationElement in world.list_elements():
		if element.archetype_id != "stationary_drill" and not (
			element.archetype_id.begins_with("test_stationary_drill")
		):
			continue
		_tick_drill(world, cargo_graph, transfer_service, element, dt)


func _tick_drill(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement,
	_dt: float
) -> void:
	IndustryStoreService.sync_element_storage(world, element)
	var runtime := world.ensure_industry_element_runtime(element.element_id)

	if not element.is_operational():
		element.industry_functional_reason = element.status_reason()
		return
	if not runtime.machine_enabled:
		element.industry_functional_reason = &"disabled"
		return
	if (
		IndustryArchetypeProfile.drill_requires_power()
		and not runtime.powered
	):
		element.industry_functional_reason = runtime.power_reason
		return

	# Free the staging buffer before reserving room for another terrain edit.
	_push_drill_buffer(world, cargo_graph, transfer_service, element)
	if not _has_terrain_contact(element.element_id):
		element.industry_functional_reason = &"no_terrain_contact"
		return
	var maximum_yield := _raw_amount_from_volume(
		IndustryArchetypeProfile.drill_max_request_volume_m3()
	)
	if not _can_accept_yield(world, cargo_graph, element, maximum_yield):
		element.industry_functional_reason = &"storage_full"
		return

	var carved_volume := _carve_volume(element.element_id)
	if carved_volume <= EPSILON:
		element.industry_functional_reason = &"no_terrain_contact"
		return

	var credited := _credit_raw_regolith(world, element, carved_volume)
	if credited <= EPSILON:
		element.industry_functional_reason = &"ok"
		return

	_push_drill_buffer(world, cargo_graph, transfer_service, element)
	element.industry_functional_reason = &"ok"
	element.bump_state_revision()


func _has_terrain_contact(element_id: int) -> bool:
	if not _drill_contact_probe.is_valid():
		return false
	return bool(_drill_contact_probe.call(element_id))


func _carve_volume(element_id: int) -> float:
	if not _drill_carve.is_valid():
		return 0.0
	return maxf(float(_drill_carve.call(element_id)), 0.0)


func _raw_amount_from_volume(volume_m3: float) -> float:
	if volume_m3 <= EPSILON:
		return 0.0
	var yields := _material_source.yield_for_removed_volume(
		volume_m3,
		IndustryArchetypeProfile.terrain_collectible_fraction()
	)
	if yields.is_empty():
		return 0.0
	var yield_entry: Dictionary = yields[0]
	var resource_id := String(yield_entry.get("resource_id", ""))
	var mass_kg := float(yield_entry.get("mass_kg", 0.0))
	var unit_mass := ResourceCatalog.mass_per_unit_kg(resource_id)
	if unit_mass <= EPSILON:
		return 0.0
	return mass_kg / unit_mass


func _credit_raw_regolith(
	world: SimulationWorld,
	element: SimulationElement,
	volume_m3: float
) -> float:
	var amount := _raw_amount_from_volume(volume_m3)
	if amount <= EPSILON:
		return 0.0
	var capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
		element.archetype_id
	)
	if not element.industry_buffer.can_add("raw_regolith", amount, capacity):
		return 0.0
	element.industry_buffer.add("raw_regolith", amount, capacity)
	return amount


func _can_accept_yield(
	_world: SimulationWorld,
	_cargo_graph: CargoGraph,
	element: SimulationElement,
	amount: float
) -> bool:
	var capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
		element.archetype_id
	)
	return element.industry_buffer.can_add(
		"raw_regolith",
		amount,
		capacity
	)


func _push_drill_buffer(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement
) -> void:
	var machine_cargo := MachineCargoService.new()
	machine_cargo.push_outputs_from_buffer(
		world,
		cargo_graph,
		transfer_service,
		element,
		PackedStringArray(["raw_regolith"])
	)
