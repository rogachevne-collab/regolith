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
	return ResourceCatalog.buffer_mass_kg(self)


func volume_l() -> float:
	return ResourceCatalog.buffer_volume_l(self)


func is_full(capacity_l: float) -> bool:
	return ResourceCatalog.is_buffer_full(self, capacity_l)


func can_add(resource_id: String, requested: float, capacity_l: float) -> bool:
	if (
		resource_id.is_empty()
		or not is_finite(requested)
		or requested < 0.0
		or capacity_l <= EPSILON
		or ResourceCatalog.rejects_fractional_amount(resource_id, requested)
	):
		return false
	if requested <= EPSILON:
		return true
	var max_addable := max_addable_amount(resource_id, capacity_l)
	return requested <= max_addable + EPSILON


func add(
	resource_id: String,
	added: float,
	capacity_l: float
) -> bool:
	if not can_add(resource_id, added, capacity_l):
		return false
	if added <= EPSILON:
		return true
	_amounts[resource_id] = amount(resource_id) + added
	return true


func can_remove(resource_id: String, requested: float) -> bool:
	if (
		resource_id.is_empty()
		or not is_finite(requested)
		or requested < 0.0
		or ResourceCatalog.rejects_fractional_amount(resource_id, requested)
	):
		return false
	return amount(resource_id) + EPSILON >= requested


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


func max_addable_amount(resource_id: String, capacity_l: float) -> float:
	return ResourceCatalog.max_addable_amount_buffer(
		self,
		resource_id,
		capacity_l
	)


func to_dict(capacity_l: float = INF) -> Dictionary:
	var amounts: Dictionary = {}
	for resource_id: String in resource_ids():
		amounts[resource_id] = amount(resource_id)
	var row := {"amounts": amounts}
	if is_finite(capacity_l) and capacity_l > EPSILON:
		row["capacity_l"] = capacity_l
	return row


static func from_dict(data: Dictionary) -> ElementIndustryBuffer:
	var buffer: ElementIndustryBuffer = _SCRIPT.new()
	var amounts: Variant = data.get("amounts", {})
	if amounts is Dictionary:
		for resource_id: Variant in amounts.keys():
			var value := float(amounts[resource_id])
			if value > EPSILON:
				if ResourceCatalog.rejects_fractional_amount(
					str(resource_id),
					value
				):
					return null
				buffer._amounts[str(resource_id)] = value
	return buffer
