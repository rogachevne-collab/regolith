class_name DozerBladeService
extends RefCounted
## Rover-mounted blade that works loose (granular) material only. It scoops the
## spoil under its working edge into an internal buffer — credited like a drill's
## yield and pushed out the cargo port — and, once that buffer is full, plows the
## rest aside instead of stalling. It never carves solid rock and never credits
## rock: moving and levelling loose material is its whole job, so it cannot stand
## in for a drill. See docs/specs/GRANULAR-V0.md and the stationary drill it
## mirrors (stationary_drill_service.gd).

const EPSILON := 0.000001
const _Field := preload(
	"res://scripts/simulation/runtime/moon_material_field.gd"
)

## (element_id) -> bool: is there loose material under the blade's edge.
var _contact_probe: Callable = Callable()
## (element_id, budget_m3) -> float: take up to `budget_m3` of loose material
## into the blade, returning the volume actually removed from the world.
var _load: Callable = Callable()
## (element_id) -> float: shove loose material aside (buffer full), returning the
## volume moved. Stays in the world.
var _plow: Callable = Callable()
## (element_id) -> Vector3: world point the blade last worked, for material
## sampling.
var _contact_point: Callable = Callable()
var _material_source := TerrainMaterialSource.new()
var _material_field: MoonMaterialField = _Field.new()
var _spawn_world: Vector3 = Vector3.ZERO
## element_id -> reason last written, so the trace below prints on transition
## rather than every tick.
var _last_reported_reason: Dictionary = {}


func set_spawn_world(spawn_world: Vector3) -> void:
	_spawn_world = spawn_world


func set_dozer_blade_load_stub(stub: Callable) -> void:
	# Deterministic headless fixtures: a load stub also implies contact and a
	# no-op plow unless the test installs explicit hooks.
	_load = stub
	_contact_probe = func(_element_id: int) -> bool: return true
	_plow = func(_element_id: int) -> float: return 0.0
	_contact_point = Callable()


func set_dozer_blade_hooks(
	contact_probe: Callable,
	load_hook: Callable,
	plow_hook: Callable,
	contact_point: Callable = Callable()
) -> void:
	_contact_probe = contact_probe
	_load = load_hook
	_plow = plow_hook
	_contact_point = contact_point


func apply_set_machine_enabled(
	world: SimulationWorld,
	command: SetMachineEnabledCommand
) -> Dictionary:
	if command == null or command.element_id <= 0:
		return _command_result(&"invalid_target")
	var element := world.get_element(command.element_id)
	if element == null or not _is_dozer_blade(element):
		return _command_result(&"invalid_target")
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	runtime.machine_enabled = command.enabled
	element.industry_functional_reason = (
		&"disabled" if not command.enabled else &"ok"
	)
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
		if not _is_dozer_blade(element):
			continue
		_tick_blade(world, cargo_graph, transfer_service, element)


func _tick_blade(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement
) -> void:
	IndustryStoreService.sync_element_storage(world, element)
	var runtime := world.ensure_industry_element_runtime(element.element_id)

	if not element.is_operational():
		_set_reason(element, element.status_reason())
		return
	if not runtime.machine_enabled:
		_set_reason(element, &"disabled")
		return
	if (
		IndustryArchetypeProfile.dozer_blade_requires_power()
		and not runtime.powered
	):
		_set_reason(element, runtime.power_reason)
		return

	# Free the staging buffer before deciding whether there is room to load more.
	_push_blade_buffer(world, cargo_graph, transfer_service, element)
	if not _has_contact(element.element_id):
		_set_reason(element, &"no_terrain_contact")
		return

	var contact_point := _contact_world_point(element.element_id)
	var budget := IndustryArchetypeProfile.dozer_blade_tick_volume_budget_m3()
	# Only load when a full budget's worth of the resource fits — the blade
	# removes material from the world before crediting, so scooping into a buffer
	# that cannot hold it would lose volume. When it does not fit, plow instead:
	# the material stays in the world, just moved.
	if _buffer_has_room_for(element, budget, contact_point):
		# Room was reserved for a full `budget`; clamp to it so a load hook that
		# ever returned more than it was asked for could not have its excess
		# clamped away at credit time — i.e. removed from the world but not stored.
		var loaded := minf(_load_material(element.element_id, budget), budget)
		if loaded <= EPSILON:
			_set_reason(element, &"no_terrain_contact")
			return
		_credit_loose(world, element, loaded, contact_point)
		_push_blade_buffer(world, cargo_graph, transfer_service, element)
		# A blade parts the heap it drives into, and what it keeps is skimmed off
		# the top of that. Loading alone moved one tick budget out of a 1.5 m
		# ball — nothing against a real heap, so the tool read as inert no matter
		# how much it was actually collecting. Plowed material stays in the
		# world, only relocated, so doing this on every working tick costs no
		# volume and cannot be farmed.
		_plow_material(element.element_id)
		_set_reason(element, &"ok")
	else:
		_plow_material(element.element_id)
		_set_reason(element, &"storage_full")
	element.bump_state_revision()


## Why a pass collected nothing is only readable by aiming at the blade, which
## is exactly what the driver cannot do while driving into a heap. Trace every
## transition so the answer survives in the log instead of the moment.
func _set_reason(element: SimulationElement, reason: StringName) -> void:
	element.industry_functional_reason = reason
	if StringName(_last_reported_reason.get(element.element_id, &"")) == reason:
		return
	_last_reported_reason[element.element_id] = reason
	print("[dozer_blade %d] %s" % [element.element_id, reason])


func _has_contact(element_id: int) -> bool:
	if not _contact_probe.is_valid():
		return false
	return bool(_contact_probe.call(element_id))


func _load_material(element_id: int, budget_m3: float) -> float:
	if not _load.is_valid():
		return 0.0
	return maxf(float(_load.call(element_id, budget_m3)), 0.0)


func _plow_material(element_id: int) -> float:
	if not _plow.is_valid():
		return 0.0
	return maxf(float(_plow.call(element_id)), 0.0)


func _contact_world_point(element_id: int) -> Vector3:
	if _contact_point.is_valid():
		return Vector3(_contact_point.call(element_id))
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


func _credit_loose(
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


## Whether the resource `volume_m3` of loose material would produce fully fits in
## the buffer. Guards the load path so material is never removed from the world
## without a home in the buffer.
func _buffer_has_room_for(
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
		var need := float(amounts[resource_id])
		var max_addable := element.industry_buffer.max_addable_amount(
			str(resource_id),
			capacity
		)
		if max_addable + EPSILON < need:
			return false
	return true


func _push_blade_buffer(
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


func _is_dozer_blade(element: SimulationElement) -> bool:
	return (
		element.archetype_id == "dozer_blade"
		or element.archetype_id.begins_with("test_dozer_blade")
	)


func _command_result(reason: StringName) -> Dictionary:
	return {
		"status": &"ok" if reason == &"ok" else &"failed",
		"reason": reason,
	}
