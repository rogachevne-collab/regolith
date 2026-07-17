class_name MachineCargoService
extends RefCounted

const EPSILON := 0.000001
const PULL_UNIT_PER_TICK := 1.0


func pull_inputs_for_recipe(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement,
	inputs: Dictionary
) -> void:
	if (
		world == null
		or cargo_graph == null
		or transfer_service == null
		or element == null
		or inputs.is_empty()
	):
		return
	IndustryStoreService.sync_element_storage(world, element)
	for resource_id: Variant in inputs.keys():
		var needed := float(inputs[resource_id])
		if needed <= EPSILON:
			continue
		var resource := str(resource_id)
		var have := element.industry_buffer.amount(resource)
		var remaining := maxf(needed - have, 0.0)
		var store_element_ids := cargo_graph.connected_store_element_ids_with_resource(
			world,
			element.element_id,
			resource
		)
		for store_element_id: int in store_element_ids:
			if remaining <= EPSILON:
				break
			var source_store_id := IndustryStoreService.element_store_id(
				store_element_id
			)
			while remaining > EPSILON:
				var pull_amount := minf(remaining, PULL_UNIT_PER_TICK)
				var result := transfer_service.transfer_between_stores(
					world,
					source_store_id,
					IndustryStoreService.buffer_store_id(element.element_id),
					resource,
					pull_amount
				)
				if StringName(result.get("reason", &"")) != &"ok":
					break
				var transferred := float(result.get("amount", 0.0))
				if transferred <= EPSILON:
					break
				remaining -= transferred


func can_accept_outputs(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	element: SimulationElement,
	outputs: Dictionary
) -> bool:
	if element == null or outputs.is_empty():
		return false
	IndustryStoreService.sync_element_storage(world, element)
	var buffer_capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
		element.archetype_id
	)
	for resource_id: Variant in outputs.keys():
		var amount := float(outputs[resource_id])
		if amount <= EPSILON:
			continue
		var resource := str(resource_id)
		if not element.industry_buffer.can_add(resource, amount, buffer_capacity):
			var store_id := _nearest_connected_store_id(
				world,
				cargo_graph,
				element.element_id
			)
			if store_id.is_empty():
				return false
			var store := IndustryStoreService.ensure_element_keyed_store(
				world,
				world.get_element(
					IndustryStoreService.parse_element_id_from_store(store_id)
				)
			)
			if store == null:
				return false
			var capacity := IndustryStoreService.capacity_l_for_store(
				world,
				store_id
			)
			if (
				ResourceCatalog.max_addable_amount(store, resource, capacity)
				+ EPSILON
				< amount
			):
				return false
	return true


func push_outputs_from_buffer(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement,
	resource_ids: PackedStringArray
) -> void:
	if (
		world == null
		or cargo_graph == null
		or transfer_service == null
		or element == null
	):
		return
	var store_id := _nearest_connected_store_id(world, cargo_graph, element.element_id)
	if store_id.is_empty():
		return
	for resource_id: String in resource_ids:
		var transferable := minf(
			element.industry_buffer.amount(resource_id),
			PULL_UNIT_PER_TICK
		)
		if transferable <= EPSILON:
			continue
		transfer_service.transfer_between_stores(
			world,
			IndustryStoreService.buffer_store_id(element.element_id),
			store_id,
			resource_id,
			transferable
		)


func _nearest_connected_store_id(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	from_element_id: int
) -> String:
	return _connected_store_id_for_resource(
		world,
		cargo_graph,
		from_element_id,
		""
	)


func _connected_store_id_for_resource(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	from_element_id: int,
	resource_id: String = ""
) -> String:
	var target_element_id := 0
	if resource_id.is_empty():
		target_element_id = cargo_graph.nearest_cargo_store_element_id(
			world,
			from_element_id
		)
	else:
		target_element_id = (
			cargo_graph.nearest_cargo_store_element_id_with_resource(
				world,
				from_element_id,
				resource_id
			)
		)
	if target_element_id <= 0:
		return ""
	return IndustryStoreService.element_store_id(target_element_id)
