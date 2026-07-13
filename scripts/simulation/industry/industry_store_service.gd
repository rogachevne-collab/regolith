class_name IndustryStoreService
extends RefCounted

const PLAYER_STORE_ID := "player"
const ELEMENT_STORE_PREFIX := "element:"
const BUFFER_STORE_PREFIX := "buffer:"


static func element_store_id(element_id: int) -> String:
	return "%s%d" % [ELEMENT_STORE_PREFIX, element_id]


static func buffer_store_id(element_id: int) -> String:
	return "%s%d" % [BUFFER_STORE_PREFIX, element_id]


static func parse_element_id_from_store(store_id: String) -> int:
	if not store_id.begins_with(ELEMENT_STORE_PREFIX):
		return 0
	return int(store_id.substr(ELEMENT_STORE_PREFIX.length()))


static func parse_buffer_element_id(store_id: String) -> int:
	if not store_id.begins_with(BUFFER_STORE_PREFIX):
		return 0
	return int(store_id.substr(BUFFER_STORE_PREFIX.length()))


static func capacity_kg_for_store(world: SimulationWorld, store_id: String) -> float:
	if store_id == PLAYER_STORE_ID:
		return IndustryArchetypeProfile.player_carry_capacity_kg()
	var element_id := parse_element_id_from_store(store_id)
	if element_id > 0:
		var element := world.get_element(element_id)
		if element == null:
			return 0.0
		return IndustryArchetypeProfile.keyed_store_capacity_kg(
			element.archetype_id
		)
	element_id = parse_buffer_element_id(store_id)
	if element_id > 0:
		var element := world.get_element(element_id)
		if element == null:
			return 0.0
		return IndustryArchetypeProfile.internal_buffer_capacity_kg(
			element.archetype_id
		)
	return INF


static func ensure_player_store(world: SimulationWorld) -> SimulationResourceStore:
	var store := world.ensure_resource_store(PLAYER_STORE_ID)
	if store != null:
		store.capacity_kg = IndustryArchetypeProfile.player_carry_capacity_kg()
	return store


static func ensure_element_keyed_store(
	world: SimulationWorld,
	element: SimulationElement
) -> SimulationResourceStore:
	if element == null:
		return null
	var capacity := IndustryArchetypeProfile.keyed_store_capacity_kg(
		element.archetype_id
	)
	if capacity <= 0.0:
		return null
	var store_id := element_store_id(element.element_id)
	var store := world.ensure_resource_store(store_id)
	if store != null:
		store.capacity_kg = capacity
	return store


static func sync_element_storage(world: SimulationWorld, element: SimulationElement) -> void:
	if element == null:
		return
	if (
		element.is_operational()
		and IndustryArchetypeProfile.has_keyed_store(element.archetype_id)
	):
		ensure_element_keyed_store(world, element)
	if IndustryArchetypeProfile.has_internal_buffer(element.archetype_id):
		if element.industry_buffer == null:
			element.industry_buffer = ElementIndustryBuffer.new()


static func sync_all_elements(world: SimulationWorld) -> void:
	ensure_player_store(world)
	for element: SimulationElement in world.list_elements():
		sync_element_storage(world, element)


static func content_mass_kg(world: SimulationWorld, element: SimulationElement) -> float:
	if element == null:
		return 0.0
	var total := 0.0
	if element.industry_buffer != null:
		total += element.industry_buffer.mass_kg()
	if IndustryArchetypeProfile.has_keyed_store(element.archetype_id):
		var store := world.get_resource_store(
			element_store_id(element.element_id)
		)
		if store != null:
			total += ResourceCatalog.store_mass_kg(store)
	return total


static func total_mass_kg(world: SimulationWorld, element: SimulationElement) -> float:
	if element == null:
		return 0.0
	return element.dry_mass_kg() + content_mass_kg(world, element)
