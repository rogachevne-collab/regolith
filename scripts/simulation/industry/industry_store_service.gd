class_name IndustryStoreService
extends RefCounted

## Player stores are `player:<uid>` — see PlayerIdentity. There is no single
## "the player" store: one per player, so peers never share a rucksack.
const ELEMENT_STORE_PREFIX := "element:"
const BUFFER_STORE_PREFIX := "buffer:"

## Fresh-world / playtest cargo — authoritative values in Game Balance v0.
static var PLAYER_STARTER_RESOURCES: Dictionary:
	get:
		var resources: Variant = GameBalance.starter().get("player_resources", {})
		return resources if resources is Dictionary else {}

static var PLAYTEST_PLAYER_CARRY_CAPACITY_L: float:
	get:
		return float(
			GameBalance.starter().get("playtest_carry_capacity_l", 2000.0)
		)

static var PLAYTEST_PLAYER_RESOURCES: Dictionary:
	get:
		var resources: Variant = GameBalance.starter().get("playtest_resources", {})
		return resources if resources is Dictionary else {}


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


static func capacity_l_for_store(world: SimulationWorld, store_id: String) -> float:
	if PlayerIdentity.is_player_store(store_id):
		return IndustryArchetypeProfile.player_carry_capacity_l()
	var element_id := parse_element_id_from_store(store_id)
	if element_id > 0:
		var element := world.get_element(element_id)
		if element == null:
			return 0.0
		return IndustryArchetypeProfile.keyed_store_capacity_l(
			element.archetype_id
		)
	element_id = parse_buffer_element_id(store_id)
	if element_id > 0:
		var element := world.get_element(element_id)
		if element == null:
			return 0.0
		return IndustryArchetypeProfile.internal_buffer_capacity_l(
			element.archetype_id
		)
	return INF


static func ensure_player_store(
	world: SimulationWorld,
	player_uid: String
) -> SimulationResourceStore:
	var store := world.ensure_resource_store(PlayerIdentity.store_id(player_uid))
	if store != null:
		store.capacity_l = IndustryArchetypeProfile.player_carry_capacity_l()
	return store


static func seed_player_starter_resources(
	world: SimulationWorld,
	player_uid: String
) -> bool:
	if world == null:
		return false
	ensure_player_store(world, player_uid)
	ensure_player_inventory(world)
	var projected := player_instance_volume_l(world)
	for resource_id: String in PLAYER_STARTER_RESOURCES.keys():
		var amount := float(PLAYER_STARTER_RESOURCES[resource_id])
		projected += ResourceCatalog.resource_volume_l(resource_id, amount)
	if projected > player_carry_capacity_l() + ResourceCatalog.EPSILON:
		push_error(
			"PLAYER_STARTER_RESOURCES exceeds player carry capacity (%.1f L > %.1f L)"
			% [projected, player_carry_capacity_l()]
		)
		return false
	for resource_id: String in PLAYER_STARTER_RESOURCES.keys():
		world.set_resource_amount(
			PlayerIdentity.store_id(player_uid),
			resource_id,
			float(PLAYER_STARTER_RESOURCES[resource_id])
		)
	return true


static func apply_playtest_cargo(
	world: SimulationWorld,
	player_uid: String
) -> bool:
	if world == null:
		return false
	var store := ensure_player_store(world, player_uid)
	if store == null:
		return false
	store.capacity_l = PLAYTEST_PLAYER_CARRY_CAPACITY_L
	ensure_player_inventory(world)
	var projected := player_instance_volume_l(world)
	for resource_id: String in PLAYTEST_PLAYER_RESOURCES.keys():
		projected += ResourceCatalog.resource_volume_l(
			resource_id,
			float(PLAYTEST_PLAYER_RESOURCES[resource_id])
		)
	if projected > PLAYTEST_PLAYER_CARRY_CAPACITY_L + ResourceCatalog.EPSILON:
		push_error(
			"PLAYTEST_PLAYER_RESOURCES exceeds playtest carry capacity (%.1f L > %.1f L)"
			% [projected, PLAYTEST_PLAYER_CARRY_CAPACITY_L]
		)
		return false
	for resource_id: String in PLAYTEST_PLAYER_RESOURCES.keys():
		world.set_resource_amount(
			PlayerIdentity.store_id(player_uid),
			resource_id,
			float(PLAYTEST_PLAYER_RESOURCES[resource_id])
		)
	return true


static func ensure_player_inventory(
	world: SimulationWorld
) -> PlayerInventoryRegistry:
	return world.ensure_player_inventory()


static func player_instance_volume_l(world: SimulationWorld) -> float:
	var registry := world.get_player_inventory()
	return registry.volume_l() if registry != null else 0.0


static func player_total_volume_l(
	world: SimulationWorld,
	player_uid: String
) -> float:
	var store := world.get_resource_store(PlayerIdentity.store_id(player_uid))
	var total := player_instance_volume_l(world)
	if store != null:
		total += store.volume_l()
	return total


static func player_carry_capacity_l() -> float:
	return IndustryArchetypeProfile.player_carry_capacity_l()


static func ensure_element_keyed_store(
	world: SimulationWorld,
	element: SimulationElement
) -> SimulationResourceStore:
	if element == null:
		return null
	var capacity := IndustryArchetypeProfile.keyed_store_capacity_l(
		element.archetype_id
	)
	if capacity <= 0.0:
		return null
	var store_id := element_store_id(element.element_id)
	var store := world.ensure_resource_store(store_id)
	if store != null:
		store.capacity_l = capacity
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
	# No player store is created here any more: a world-wide element sync has
	# no business inventing a store for one particular player. Player stores
	# come from spawn (seed_player_starter_resources) or from the snapshot.
	ensure_player_inventory(world)
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
