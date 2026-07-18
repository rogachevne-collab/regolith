class_name StationaryDrillService
extends RefCounted

const EPSILON := 0.000001
const _Field := preload(
	"res://scripts/simulation/runtime/moon_material_field.gd"
)

var _drill_contact_probe: Callable = Callable()
var _drill_carve: Callable = Callable()
var _drill_carve_point: Callable = Callable()
var _material_source := TerrainMaterialSource.new()
var _material_field: MoonMaterialField = _Field.new()
var _spawn_world: Vector3 = Vector3.ZERO


func set_spawn_world(spawn_world: Vector3) -> void:
	_spawn_world = spawn_world


func set_drill_carve_stub(stub: Callable) -> void:
	# Compatibility hook for deterministic headless fixtures. A carve stub also
	# implies contact unless the test installs an explicit probe.
	_drill_carve = stub
	_drill_contact_probe = func(_element_id: int) -> bool: return true
	_drill_carve_point = Callable()


func set_drill_terrain_hooks(
	contact_probe: Callable,
	carve: Callable,
	carve_point: Callable = Callable()
) -> void:
	_drill_contact_probe = contact_probe
	_drill_carve = carve
	_drill_carve_point = carve_point


func apply_set_machine_enabled(
	world: SimulationWorld,
	command: SetMachineEnabledCommand
) -> Dictionary:
	if command == null or command.element_id <= 0:
		return _command_result(&"invalid_target")
	var element := world.get_element(command.element_id)
	if element == null or not _is_stationary_drill(element):
		return _command_result(&"invalid_target")
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	runtime.machine_enabled = command.enabled
	element.industry_functional_reason = &"disabled" if not command.enabled else &"ok"
	element.bump_state_revision()
	return _command_result(&"ok")


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

	var carved_volume := _carve_volume(element.element_id)
	if carved_volume <= EPSILON:
		element.industry_functional_reason = &"no_terrain_contact"
		return

	var carve_point := _carve_world_point(element.element_id)
	var credited := _credit_ores(world, element, carved_volume, carve_point)
	_push_drill_buffer(world, cargo_graph, transfer_service, element)
	if credited <= EPSILON and _buffer_has_no_room_for_carve(
		element,
		carved_volume,
		carve_point
	):
		element.industry_functional_reason = &"storage_full"
	else:
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


func _carve_world_point(element_id: int) -> Vector3:
	if _drill_carve_point.is_valid():
		return Vector3(_drill_carve_point.call(element_id))
	return Vector3.ZERO


func _material_weights_at(world_point: Vector3) -> Dictionary:
	var material_id: String
	if world_point.length() <= EPSILON:
		material_id = TerrainMaterialCatalog.MAT_MARE_REGOLITH
	else:
		material_id = _material_field.material_id_at_world(
			world_point,
			_spawn_world
		)
	return {material_id: 1.0}


func _amounts_from_volume(volume_m3: float, world_point: Vector3) -> Dictionary:
	if volume_m3 <= EPSILON:
		return {}
	var yields := _material_source.yield_for_excavation(
		volume_m3,
		_material_weights_at(world_point)
	)
	return _material_source.amounts_from_yields(yields)


func _credit_ores(
	_world: SimulationWorld,
	element: SimulationElement,
	volume_m3: float,
	world_point: Vector3
) -> float:
	var amounts := _amounts_from_volume(volume_m3, world_point)
	if amounts.is_empty():
		return 0.0
	var capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
		element.archetype_id
	)
	var credited_total := 0.0
	var resource_ids: Array = amounts.keys()
	resource_ids.sort()
	for resource_id: Variant in resource_ids:
		var amount := float(amounts[resource_id])
		if amount <= EPSILON:
			continue
		var max_addable := element.industry_buffer.max_addable_amount(
			str(resource_id),
			capacity
		)
		var credited := minf(amount, max_addable)
		if credited <= EPSILON:
			continue
		element.industry_buffer.add(str(resource_id), credited, capacity)
		credited_total += credited
	return credited_total


func _buffer_has_no_room_for_carve(
	element: SimulationElement,
	volume_m3: float,
	world_point: Vector3
) -> bool:
	var amounts := _amounts_from_volume(volume_m3, world_point)
	if amounts.is_empty():
		return false
	var capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
		element.archetype_id
	)
	for resource_id: Variant in amounts.keys():
		if (
			element.industry_buffer.max_addable_amount(
				str(resource_id),
				capacity
			)
			> EPSILON
		):
			return false
	return true


func _push_drill_buffer(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement
) -> void:
	var machine_cargo := MachineCargoService.new()
	var ids := PackedStringArray()
	if element.industry_buffer != null:
		for resource_id: String in element.industry_buffer.resource_ids():
			ids.append(resource_id)
	machine_cargo.push_outputs_from_buffer(
		world,
		cargo_graph,
		transfer_service,
		element,
		ids
	)


func _is_stationary_drill(element: SimulationElement) -> bool:
	return (
		element.archetype_id == "stationary_drill"
		or element.archetype_id.begins_with("test_stationary_drill")
	)


func _command_result(reason: StringName) -> Dictionary:
	return {
		"status": &"ok" if reason == &"ok" else &"failed",
		"reason": reason,
	}
