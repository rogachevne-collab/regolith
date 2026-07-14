class_name SimulationResourceStore
extends RefCounted

const EPSILON := 0.000001
const _SCRIPT := preload(
	"res://scripts/simulation/runtime/simulation_resource_store.gd"
)

var store_id: String = ""
## Volume limit for Industry v1; INF means uncoupled from capacity checks.
var capacity_l: float = INF
var _amounts: Dictionary = {}


func amount(resource_id: String) -> float:
	return float(_amounts.get(resource_id, 0.0))


func can_remove(resource_id: String, requested: float) -> bool:
	if (
		resource_id.is_empty()
		or not is_finite(requested)
		or requested < 0.0
		or ResourceCatalog.rejects_fractional_amount(resource_id, requested)
	):
		return false
	return amount(resource_id) + EPSILON >= requested


func can_add(
	resource_id: String,
	added: float,
	capacity_limit_l: float = INF
) -> bool:
	if (
		resource_id.is_empty()
		or not is_finite(added)
		or added < 0.0
		or ResourceCatalog.rejects_fractional_amount(resource_id, added)
	):
		return false
	if added <= EPSILON:
		return true
	var limit_l := _effective_capacity_l(capacity_limit_l)
	if not is_finite(limit_l) or limit_l <= EPSILON:
		return true
	var max_addable := ResourceCatalog.max_addable_amount(
		self,
		resource_id,
		limit_l
	)
	return added <= max_addable + EPSILON


func add(
	resource_id: String,
	added: float,
	capacity_limit_l: float = INF
) -> bool:
	if not can_add(resource_id, added, capacity_limit_l):
		return false
	if added <= EPSILON:
		return true
	_amounts[resource_id] = amount(resource_id) + added
	return true


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


func set_amount(resource_id: String, value: float) -> bool:
	if (
		resource_id.is_empty()
		or not is_finite(value)
		or value < 0.0
		or ResourceCatalog.rejects_fractional_amount(resource_id, value)
	):
		return false
	if value <= EPSILON:
		_amounts.erase(resource_id)
	else:
		_amounts[resource_id] = value
	return true


func resource_ids() -> PackedStringArray:
	var result := PackedStringArray()
	for resource_id: Variant in _amounts.keys():
		result.append(str(resource_id))
	result.sort()
	return result


func mass_kg() -> float:
	return ResourceCatalog.store_mass_kg(self)


func volume_l() -> float:
	return ResourceCatalog.store_volume_l(self)


func is_storage_full(capacity_limit_l: float = INF) -> bool:
	var limit_l := _effective_capacity_l(capacity_limit_l)
	return ResourceCatalog.is_storage_full(self, limit_l)


func to_dict() -> Dictionary:
	var amounts: Dictionary = {}
	for resource_id: String in resource_ids():
		amounts[resource_id] = amount(resource_id)
	var row := {
		"store_id": store_id,
		"amounts": amounts,
	}
	if is_finite(capacity_l):
		row["capacity_l"] = capacity_l
	return row


static func from_dict(data: Dictionary) -> SimulationResourceStore:
	var store: SimulationResourceStore = _SCRIPT.new()
	store.store_id = str(data.get("store_id", ""))
	var capacity_l_value: Variant = data.get("capacity_l", INF)
	if is_finite(float(capacity_l_value)) and float(capacity_l_value) > 0.0:
		store.capacity_l = float(capacity_l_value)
	var amounts: Variant = data.get("amounts", {})
	if amounts is Dictionary:
		for resource_id: Variant in amounts.keys():
			if not store.set_amount(str(resource_id), float(amounts[resource_id])):
				return null
	return store


func _effective_capacity_l(capacity_limit_l: float) -> float:
	if is_finite(capacity_l):
		return capacity_l
	return capacity_limit_l
