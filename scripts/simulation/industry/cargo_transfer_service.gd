class_name CargoTransferService
extends RefCounted

const EPSILON := 0.000001
const AUTO_TRANSFER_UNIT_PER_TICK := 1.0


func transfer_between_stores(
	world: SimulationWorld,
	from_store_id: String,
	to_store_id: String,
	resource_id: String,
	requested_amount: float
) -> Dictionary:
	if (
		world == null
		or from_store_id.is_empty()
		or to_store_id.is_empty()
		or from_store_id == to_store_id
		or resource_id.is_empty()
		or not ResourceCatalog.has_resource(resource_id)
	):
		return _failed(&"invalid_target")
	if not is_finite(requested_amount) or requested_amount < 0.0:
		return _failed(&"invalid_target")

	var from_store = _resolve_store(world, from_store_id)
	var to_store = _resolve_store(world, to_store_id)
	if from_store == null or to_store == null:
		return _failed(&"invalid_reference")

	var available: float = _store_amount(from_store, resource_id)
	var amount: float = requested_amount if requested_amount > EPSILON else available
	amount = minf(amount, available)
	if amount <= EPSILON:
		return _failed(&"no_input")

	var dest_capacity := IndustryStoreService.capacity_kg_for_store(
		world,
		to_store_id
	)
	var max_addable := _max_addable_amount(
		to_store,
		resource_id,
		dest_capacity
	)
	amount = minf(amount, max_addable)
	if amount <= EPSILON:
		return _failed(&"storage_full")

	if not _store_can_remove(from_store, resource_id, amount):
		return _failed(&"no_input")
	if not _store_can_add(to_store, resource_id, amount, dest_capacity):
		return _failed(&"storage_full")

	_store_remove(from_store, resource_id, amount)
	_store_add(to_store, resource_id, amount, dest_capacity)
	return _ok(amount)


func transfer_resource_command(
	world: SimulationWorld,
	command: TransferResourceCommand
) -> Dictionary:
	if command == null:
		return _failed(&"invalid_target")
	return transfer_between_stores(
		world,
		command.from_store_id,
		command.to_store_id,
		command.resource_id,
		command.amount
	)


func auto_transfer_tick(
	world: SimulationWorld,
	cargo_graph: CargoGraph
) -> void:
	if world == null or cargo_graph == null:
		return
	for element: SimulationElement in world.list_elements():
		if (
			not element.is_operational()
			or element.archetype_id != "stationary_drill"
			or element.industry_buffer == null
		):
			continue
		var target_store_id := _nearest_connected_store_id(
			world,
			cargo_graph,
			element.element_id
		)
		if target_store_id.is_empty():
			continue
		for resource_id: String in element.industry_buffer.resource_ids():
			var transferable := minf(
				element.industry_buffer.amount(resource_id),
				AUTO_TRANSFER_UNIT_PER_TICK
			)
			if transferable <= EPSILON:
				continue
			var result := transfer_between_stores(
				world,
				IndustryStoreService.buffer_store_id(element.element_id),
				target_store_id,
				resource_id,
				transferable
			)
			if StringName(result.get("reason", &"")) != &"ok":
				continue


func machine_cargo_tick(world: SimulationWorld, cargo_graph: CargoGraph) -> void:
	if world == null or cargo_graph == null:
		return
	var machine_cargo := MachineCargoService.new()
	for element: SimulationElement in world.list_elements():
		if (
			not element.is_operational()
			or not IndustryArchetypeProfile.is_recipe_machine(
				element.archetype_id
			)
		):
			continue
		var runtime := world.get_industry_element_runtime(element.element_id)
		if runtime == null:
			continue
		var machine := runtime.ensure_machine_state()
		if machine.active_recipe_id.is_empty():
			continue
		machine_cargo.pull_inputs_for_recipe(
			world,
			cargo_graph,
			self,
			element,
			RecipeCatalog.inputs(machine.active_recipe_id)
		)


func _nearest_connected_store_id(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	from_element_id: int
) -> String:
	var target_element_id := cargo_graph.nearest_cargo_store_element_id(
		world,
		from_element_id
	)
	if target_element_id <= 0:
		return ""
	return IndustryStoreService.element_store_id(target_element_id)


func _resolve_store(
	world: SimulationWorld,
	store_id: String
) -> Variant:
	if store_id.begins_with(IndustryStoreService.BUFFER_STORE_PREFIX):
		var element_id := IndustryStoreService.parse_buffer_element_id(store_id)
		var element := world.get_element(element_id)
		if (
			element == null
			or element.industry_buffer == null
			or not IndustryArchetypeProfile.has_internal_buffer(
				element.archetype_id
			)
		):
			return null
		return element
	if store_id.begins_with(IndustryStoreService.ELEMENT_STORE_PREFIX):
		var element_id := IndustryStoreService.parse_element_id_from_store(store_id)
		var element := world.get_element(element_id)
		if element == null:
			return null
		return IndustryStoreService.ensure_element_keyed_store(world, element)
	return world.get_resource_store(store_id)


func _store_amount(target: Variant, resource_id: String) -> float:
	if target is SimulationElement:
		return (target as SimulationElement).industry_buffer.amount(resource_id)
	if target is SimulationResourceStore:
		return (target as SimulationResourceStore).amount(resource_id)
	return 0.0


func _max_addable_amount(
	target: Variant,
	resource_id: String,
	capacity_kg: float
) -> float:
	if target is SimulationElement:
		return (target as SimulationElement).industry_buffer.max_addable_amount(
			resource_id,
			capacity_kg
		)
	if target is SimulationResourceStore:
		return ResourceCatalog.max_addable_amount(
			target as SimulationResourceStore,
			resource_id,
			capacity_kg
		)
	return 0.0


func _store_can_remove(
	target: Variant,
	resource_id: String,
	amount: float
) -> bool:
	if target is SimulationElement:
		return (target as SimulationElement).industry_buffer.can_remove(
			resource_id,
			amount
		)
	if target is SimulationResourceStore:
		return (target as SimulationResourceStore).can_remove(resource_id, amount)
	return false


func _store_can_add(
	target: Variant,
	resource_id: String,
	amount: float,
	capacity_kg: float
) -> bool:
	if target is SimulationElement:
		return (target as SimulationElement).industry_buffer.can_add(
			resource_id,
			amount,
			capacity_kg
		)
	if target is SimulationResourceStore:
		return (target as SimulationResourceStore).can_add(
			resource_id,
			amount,
			capacity_kg
		)
	return false


func _store_add(
	target: Variant,
	resource_id: String,
	amount: float,
	capacity_kg: float
) -> void:
	if target is SimulationElement:
		(target as SimulationElement).industry_buffer.add(
			resource_id,
			amount,
			capacity_kg
		)
	elif target is SimulationResourceStore:
		(target as SimulationResourceStore).add(
			resource_id,
			amount,
			capacity_kg
		)


func _store_remove(
	target: Variant,
	resource_id: String,
	amount: float
) -> void:
	if target is SimulationElement:
		(target as SimulationElement).industry_buffer.remove(resource_id, amount)
	elif target is SimulationResourceStore:
		(target as SimulationResourceStore).remove(resource_id, amount)


func _ok(amount: float) -> Dictionary:
	return {
		"status": &"ok",
		"reason": &"ok",
		"amount": amount,
	}


func _failed(reason: StringName) -> Dictionary:
	return {
		"status": &"failed",
		"reason": reason,
		"amount": 0.0,
	}
