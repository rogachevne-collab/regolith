class_name ResourceCatalog
extends RefCounted

## Authoritative mass-per-unit fixture for Industry v1 capacity coupling.
## Amounts remain in resource units; mass is derived for limits and projection.

const EPSILON := 0.000001

const ENTRIES: Dictionary = {
	"raw_regolith": 2.0,
	"regolith_fines": 1.5,
	"sintered_basalt": 3.0,
	"calcined_oxide": 1.2,
	"metal_ingot": 4.0,
	"construction_component": 2.5,
}


static func has_resource(resource_id: String) -> bool:
	return ENTRIES.has(resource_id)


static func mass_per_unit_kg(resource_id: String) -> float:
	return float(ENTRIES.get(resource_id, 0.0))


static func resource_mass_kg(resource_id: String, amount: float) -> float:
	if resource_id.is_empty() or not is_finite(amount) or amount <= EPSILON:
		return 0.0
	var unit_mass := mass_per_unit_kg(resource_id)
	if unit_mass <= EPSILON:
		return 0.0
	return amount * unit_mass


static func store_mass_kg(store: SimulationResourceStore) -> float:
	if store == null:
		return 0.0
	var total := 0.0
	for resource_id: String in store.resource_ids():
		total += resource_mass_kg(resource_id, store.amount(resource_id))
	return total


static func max_addable_amount(
	store: SimulationResourceStore,
	resource_id: String,
	capacity_kg: float
) -> float:
	if store == null or resource_id.is_empty() or capacity_kg <= EPSILON:
		return 0.0
	var unit_mass := mass_per_unit_kg(resource_id)
	if unit_mass <= EPSILON:
		return 0.0
	var remaining_kg := capacity_kg - store_mass_kg(store)
	if remaining_kg <= EPSILON:
		return 0.0
	return remaining_kg / unit_mass


static func is_storage_full(store: SimulationResourceStore, capacity_kg: float) -> bool:
	if store == null or capacity_kg <= EPSILON:
		return false
	return store_mass_kg(store) + EPSILON >= capacity_kg
