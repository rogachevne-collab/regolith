class_name SimulationResourceStore
extends RefCounted

const EPSILON := 0.000001
const _SCRIPT := preload(
	"res://scripts/simulation/runtime/simulation_resource_store.gd"
)

var store_id: String = ""
## Mass limit for Industry v1; INF means uncoupled from capacity checks.
var capacity_kg: float = INF
var _amounts: Dictionary = {}


func amount(resource_id: String) -> float:
	return float(_amounts.get(resource_id, 0.0))


func can_remove(resource_id: String, requested: float) -> bool:
	return (
		not resource_id.is_empty()
		and is_finite(requested)
		and requested >= 0.0
		and amount(resource_id) + EPSILON >= requested
	)


func can_add(resource_id: String, added: float, capacity_limit_kg: float = INF) -> bool:
	if resource_id.is_empty() or not is_finite(added) or added < 0.0:
		return false
	if added <= EPSILON:
		return true
	if not is_finite(capacity_limit_kg) or capacity_limit_kg <= EPSILON:
		return true
	var max_addable := ResourceCatalog.max_addable_amount(
		self,
		resource_id,
		capacity_limit_kg
	)
	return added <= max_addable + EPSILON


func add(
	resource_id: String,
	added: float,
	capacity_limit_kg: float = INF
) -> bool:
	if not can_add(resource_id, added, capacity_limit_kg):
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
	if resource_id.is_empty() or not is_finite(value) or value < 0.0:
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


func is_storage_full(capacity_limit_kg: float = INF) -> bool:
	var limit := capacity_kg if is_finite(capacity_kg) else capacity_limit_kg
	return ResourceCatalog.is_storage_full(self, limit)


func to_dict() -> Dictionary:
	var amounts: Dictionary = {}
	for resource_id: String in resource_ids():
		amounts[resource_id] = amount(resource_id)
	var row := {
		"store_id": store_id,
		"amounts": amounts,
	}
	if is_finite(capacity_kg):
		row["capacity_kg"] = capacity_kg
	return row


static func from_dict(data: Dictionary) -> SimulationResourceStore:
	var store: SimulationResourceStore = _SCRIPT.new()
	store.store_id = str(data.get("store_id", ""))
	var capacity: Variant = data.get("capacity_kg", INF)
	if is_finite(float(capacity)) and float(capacity) > 0.0:
		store.capacity_kg = float(capacity)
	var amounts: Variant = data.get("amounts", {})
	if amounts is Dictionary:
		for resource_id: Variant in amounts.keys():
			if not store.set_amount(str(resource_id), float(amounts[resource_id])):
				return null
	return store
