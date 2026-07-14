class_name ResourceCatalog
extends RefCounted

## Authoritative ItemCatalog fixture for Industry v1.
## Amounts remain in item units; volume limits capacity, mass couples physics.

const EPSILON := 0.000001

const ENTRIES: Dictionary = {
	"raw_regolith": {
		"category": "ore",
		"mass_per_unit_kg": 2.0,
		"volume_per_unit_l": 2.5,
		"unit": "bulk",
	},
	"regolith_fines": {
		"category": "ore",
		"mass_per_unit_kg": 1.5,
		"volume_per_unit_l": 1.8,
		"unit": "bulk",
	},
	"sintered_basalt": {
		"category": "material",
		"mass_per_unit_kg": 3.0,
		"volume_per_unit_l": 1.5,
		"unit": "bulk",
	},
	"calcined_oxide": {
		"category": "material",
		"mass_per_unit_kg": 1.2,
		"volume_per_unit_l": 1.0,
		"unit": "bulk",
	},
	"metal_ingot": {
		"category": "ingot",
		"mass_per_unit_kg": 4.0,
		"volume_per_unit_l": 0.6,
		"unit": "bulk",
	},
	"construction_component": {
		"category": "component",
		"mass_per_unit_kg": 2.5,
		"volume_per_unit_l": 3.0,
		"unit": "discrete",
	},
	"tool_hand_drill": {
		"category": "tool",
		"mass_per_unit_kg": 3.0,
		"volume_per_unit_l": 8.0,
		"unit": "discrete",
	},
	"tool_welder": {
		"category": "tool",
		"mass_per_unit_kg": 2.5,
		"volume_per_unit_l": 6.0,
		"unit": "discrete",
	},
	"tool_grinder": {
		"category": "tool",
		"mass_per_unit_kg": 2.8,
		"volume_per_unit_l": 7.0,
		"unit": "discrete",
	},
	"tool_connector": {
		"category": "tool",
		"mass_per_unit_kg": 1.5,
		"volume_per_unit_l": 4.0,
		"unit": "discrete",
	},
}


static func has_resource(resource_id: String) -> bool:
	return ENTRIES.has(resource_id)


static func category(resource_id: String) -> String:
	return str(_entry(resource_id).get("category", ""))


static func unit(resource_id: String) -> String:
	return str(_entry(resource_id).get("unit", ""))


static func is_discrete(resource_id: String) -> bool:
	return unit(resource_id) == "discrete"


static func is_bulk(resource_id: String) -> bool:
	return unit(resource_id) == "bulk"


static func is_tool_item(resource_id: String) -> bool:
	return category(resource_id) == "tool"


static func mass_per_unit_kg(resource_id: String) -> float:
	return float(_entry(resource_id).get("mass_per_unit_kg", 0.0))


static func volume_per_unit_l(resource_id: String) -> float:
	return float(_entry(resource_id).get("volume_per_unit_l", 0.0))


static func is_whole_amount(amount: float) -> bool:
	return is_equal_approx(amount, floorf(amount + EPSILON))


static func rejects_fractional_amount(resource_id: String, amount: float) -> bool:
	if amount <= EPSILON or not is_discrete(resource_id):
		return false
	return not is_whole_amount(amount)


static func quantize_transfer_amount(resource_id: String, amount: float) -> float:
	if amount <= EPSILON:
		return 0.0
	if is_discrete(resource_id):
		return floorf(amount + EPSILON)
	return amount


static func resource_mass_kg(resource_id: String, amount: float) -> float:
	if resource_id.is_empty() or not is_finite(amount) or amount <= EPSILON:
		return 0.0
	var unit_mass := mass_per_unit_kg(resource_id)
	if unit_mass <= EPSILON:
		return 0.0
	return amount * unit_mass


static func resource_volume_l(resource_id: String, amount: float) -> float:
	if resource_id.is_empty() or not is_finite(amount) or amount <= EPSILON:
		return 0.0
	var unit_volume := volume_per_unit_l(resource_id)
	if unit_volume <= EPSILON:
		return 0.0
	return amount * unit_volume


static func store_mass_kg(store: SimulationResourceStore) -> float:
	if store == null:
		return 0.0
	var total := 0.0
	for resource_id: String in store.resource_ids():
		total += resource_mass_kg(resource_id, store.amount(resource_id))
	return total


static func store_volume_l(store: SimulationResourceStore) -> float:
	if store == null:
		return 0.0
	var total := 0.0
	for resource_id: String in store.resource_ids():
		total += resource_volume_l(resource_id, store.amount(resource_id))
	return total


static func buffer_mass_kg(buffer: ElementIndustryBuffer) -> float:
	if buffer == null:
		return 0.0
	var total := 0.0
	for resource_id: String in buffer.resource_ids():
		total += resource_mass_kg(resource_id, buffer.amount(resource_id))
	return total


static func buffer_volume_l(buffer: ElementIndustryBuffer) -> float:
	if buffer == null:
		return 0.0
	var total := 0.0
	for resource_id: String in buffer.resource_ids():
		total += resource_volume_l(resource_id, buffer.amount(resource_id))
	return total


static func max_addable_amount(
	store: SimulationResourceStore,
	resource_id: String,
	capacity_l: float,
	extra_used_l: float = 0.0
) -> float:
	if store == null or resource_id.is_empty() or capacity_l <= EPSILON:
		return 0.0
	var unit_volume := volume_per_unit_l(resource_id)
	if unit_volume <= EPSILON:
		return 0.0
	var remaining_l := capacity_l - store_volume_l(store) - maxf(extra_used_l, 0.0)
	if remaining_l <= EPSILON:
		return 0.0
	var raw := remaining_l / unit_volume
	return quantize_transfer_amount(resource_id, raw)


static func max_addable_amount_player(
	store: SimulationResourceStore,
	resource_id: String
) -> float:
	return max_addable_amount(
		store,
		resource_id,
		IndustryArchetypeProfile.player_carry_capacity_l()
	)


static func max_addable_amount_buffer(
	buffer: ElementIndustryBuffer,
	resource_id: String,
	capacity_l: float
) -> float:
	if buffer == null or resource_id.is_empty() or capacity_l <= EPSILON:
		return 0.0
	var unit_volume := volume_per_unit_l(resource_id)
	if unit_volume <= EPSILON:
		return 0.0
	var remaining_l := capacity_l - buffer_volume_l(buffer)
	if remaining_l <= EPSILON:
		return 0.0
	var raw := remaining_l / unit_volume
	return quantize_transfer_amount(resource_id, raw)


static func is_storage_full(
	store: SimulationResourceStore,
	capacity_l: float,
	extra_used_l: float = 0.0
) -> bool:
	if store == null or capacity_l <= EPSILON:
		return false
	return (
		store_volume_l(store) + maxf(extra_used_l, 0.0) + EPSILON >= capacity_l
	)


static func is_buffer_full(buffer: ElementIndustryBuffer, capacity_l: float) -> bool:
	if buffer == null or capacity_l <= EPSILON:
		return false
	return buffer_volume_l(buffer) + EPSILON >= capacity_l


static func _entry(resource_id: String) -> Dictionary:
	var entry: Variant = ENTRIES.get(resource_id, {})
	return entry if entry is Dictionary else {}
