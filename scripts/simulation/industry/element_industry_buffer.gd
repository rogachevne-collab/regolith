class_name ElementIndustryBuffer
extends RefCounted

const EPSILON := 0.000001
const _SCRIPT := preload(
	"res://scripts/simulation/industry/element_industry_buffer.gd"
)

var _amounts: Dictionary = {}


func amount(resource_id: String) -> float:
	return float(_amounts.get(resource_id, 0.0))


func resource_ids() -> PackedStringArray:
	var result := PackedStringArray()
	for resource_id: Variant in _amounts.keys():
		result.append(str(resource_id))
	result.sort()
	return result


func mass_kg() -> float:
	var total := 0.0
	for resource_id: String in resource_ids():
		total += ResourceCatalog.resource_mass_kg(
			resource_id,
			amount(resource_id)
		)
	return total


func is_full(capacity_kg: float) -> bool:
	if capacity_kg <= EPSILON:
		return false
	return mass_kg() + EPSILON >= capacity_kg


func can_add(resource_id: String, requested: float, capacity_kg: float) -> bool:
	if (
		resource_id.is_empty()
		or not is_finite(requested)
		or requested < 0.0
		or capacity_kg <= EPSILON
	):
		return false
	if requested <= EPSILON:
		return true
	var unit_mass := ResourceCatalog.mass_per_unit_kg(resource_id)
	if unit_mass <= EPSILON:
		return false
	return mass_kg() + requested * unit_mass <= capacity_kg + EPSILON


func add(
	resource_id: String,
	added: float,
	capacity_kg: float
) -> bool:
	if not can_add(resource_id, added, capacity_kg):
		return false
	if added <= EPSILON:
		return true
	_amounts[resource_id] = amount(resource_id) + added
	return true


func can_remove(resource_id: String, requested: float) -> bool:
	return (
		not resource_id.is_empty()
		and is_finite(requested)
		and requested >= 0.0
		and amount(resource_id) + EPSILON >= requested
	)


func remove(resource_id: String, requested: float) -> bool:
	if not can_remove(resource_id, requested):
		return false
	if requested <= EPSILON:
		return true
	var remaining := maxf(amount(resource_id) - requested, 0.0)
	if remaining <= EPSILON:
		_amounts.erase(resource_id)
	else:
		_amounts[resource_id] = remaining
	return true


func max_addable_amount(resource_id: String, capacity_kg: float) -> float:
	if resource_id.is_empty() or capacity_kg <= EPSILON:
		return 0.0
	var unit_mass := ResourceCatalog.mass_per_unit_kg(resource_id)
	if unit_mass <= EPSILON:
		return 0.0
	var remaining_kg := capacity_kg - mass_kg()
	if remaining_kg <= EPSILON:
		return 0.0
	return remaining_kg / unit_mass


func to_dict() -> Dictionary:
	var amounts: Dictionary = {}
	for resource_id: String in resource_ids():
		amounts[resource_id] = amount(resource_id)
	return {"amounts": amounts}


static func from_dict(data: Dictionary) -> ElementIndustryBuffer:
	var buffer: ElementIndustryBuffer = _SCRIPT.new()
	var amounts: Variant = data.get("amounts", {})
	if amounts is Dictionary:
		for resource_id: Variant in amounts.keys():
			var value := float(amounts[resource_id])
			if value > EPSILON:
				buffer._amounts[str(resource_id)] = value
	return buffer
