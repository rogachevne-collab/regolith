class_name IndustryTransferUtil
extends RefCounted
## Presentation helpers for manual TransferResourceCommand payloads (pickup/deposit).


static func is_transfer_target(element: SimulationElement) -> bool:
	if element == null or not element.is_operational():
		return false
	if IndustryArchetypeProfile.has_keyed_store(element.archetype_id):
		return true
	return (
		IndustryArchetypeProfile.has_internal_buffer(element.archetype_id)
		and element.industry_buffer != null
	)


static func element_store_id(element: SimulationElement) -> String:
	if element == null:
		return ""
	if IndustryArchetypeProfile.has_keyed_store(element.archetype_id):
		return IndustryStoreService.element_store_id(element.element_id)
	if IndustryArchetypeProfile.has_internal_buffer(element.archetype_id):
		return IndustryStoreService.buffer_store_id(element.element_id)
	return ""


static func first_non_empty_resource_id(
	world: SimulationWorld,
	store_id: String
) -> String:
	if store_id.begins_with(IndustryStoreService.BUFFER_STORE_PREFIX):
		var element_id := IndustryStoreService.parse_buffer_element_id(store_id)
		var element := world.get_element(element_id)
		if element == null or element.industry_buffer == null:
			return ""
		for resource_id: String in element.industry_buffer.resource_ids():
			if element.industry_buffer.amount(resource_id) > 0.000001:
				return resource_id
		return ""
	var store := world.get_resource_store(store_id)
	if store == null:
		return ""
	for resource_id: String in store.resource_ids():
		if store.amount(resource_id) > 0.000001:
			return resource_id
	return ""


static func pickup_parameters(
	world: SimulationWorld,
	element: SimulationElement
) -> Dictionary:
	var from_store_id := element_store_id(element)
	if from_store_id.is_empty():
		return {}
	var resource_id := first_non_empty_resource_id(world, from_store_id)
	if resource_id.is_empty():
		return {}
	return {
		"from_store_id": from_store_id,
		"to_store_id": IndustryStoreService.PLAYER_STORE_ID,
		"resource_id": resource_id,
		"amount": 0.0,
	}


static func deposit_parameters(
	world: SimulationWorld,
	element: SimulationElement,
	resource_id: String = ""
) -> Dictionary:
	var to_store_id := element_store_id(element)
	if to_store_id.is_empty():
		return {}
	var player_store := world.get_resource_store(IndustryStoreService.PLAYER_STORE_ID)
	if player_store == null:
		return {}
	var chosen := resource_id
	if chosen.is_empty():
		for candidate: String in player_store.resource_ids():
			if player_store.amount(candidate) > 0.000001:
				chosen = candidate
				break
	if chosen.is_empty():
		return {}
	return {
		"from_store_id": IndustryStoreService.PLAYER_STORE_ID,
		"to_store_id": to_store_id,
		"resource_id": chosen,
		"amount": 0.0,
	}
