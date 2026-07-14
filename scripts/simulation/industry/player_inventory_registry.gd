class_name PlayerInventoryRegistry
extends RefCounted
## Authoritative discrete item instances owned by the player (INDUSTRY-V1 § Player
## tool instances). Bulk/discrete stacks remain in SimulationResourceStore; tools
## are unique instances with stable ids referenced by hotbar slots.

const _SCRIPT := preload(
	"res://scripts/simulation/industry/player_inventory_registry.gd"
)

const STARTER_INSTANCES: Dictionary = {
	"starter_tool_drill": "tool_hand_drill",
	"starter_tool_welder": "tool_welder",
	"starter_tool_grinder": "tool_grinder",
	"starter_tool_connector": "tool_connector",
}

const DEFAULT_HOTBAR_REFS: Dictionary = {
	"0:0": "starter_tool_drill",
	"0:1": "starter_tool_welder",
	"0:2": "starter_tool_grinder",
	"0:8": "starter_tool_connector",
}

var _instances: Dictionary = {}
var _hotbar_refs: Dictionary = {}
var _next_instance_seq := 1


func has_instance(instance_id: String) -> bool:
	return _instances.has(instance_id)


func item_id_for_instance(instance_id: String) -> String:
	if not _instances.has(instance_id):
		return ""
	var row: Variant = _instances[instance_id]
	return str(row.get("item_id", "")) if row is Dictionary else ""


func list_instance_ids() -> PackedStringArray:
	var ids: Array = _instances.keys()
	ids.sort()
	var result := PackedStringArray()
	for id: Variant in ids:
		result.append(str(id))
	return result


func hotbar_instance_id(page: int, slot: int) -> String:
	return str(_hotbar_refs.get(_hotbar_key(page, slot), ""))


func set_hotbar_ref(page: int, slot: int, instance_id: String) -> bool:
	if instance_id.is_empty():
		_hotbar_refs.erase(_hotbar_key(page, slot))
		return true
	if not has_instance(instance_id):
		return false
	clear_hotbar_refs_for_instance(instance_id)
	_hotbar_refs[_hotbar_key(page, slot)] = instance_id
	return true


func clear_hotbar_refs_for_instance(instance_id: String) -> void:
	if instance_id.is_empty():
		return
	for key: Variant in _hotbar_refs.keys():
		if str(_hotbar_refs[key]) == instance_id:
			_hotbar_refs.erase(key)


func validate_hotbar_refs() -> void:
	var keys: Array = _hotbar_refs.keys()
	keys.sort()
	var claimed_instances: Dictionary = {}
	for key: Variant in keys:
		var instance_id := str(_hotbar_refs[key])
		if (
			instance_id.is_empty()
			or not has_instance(instance_id)
			or claimed_instances.has(instance_id)
		):
			_hotbar_refs.erase(key)
			continue
		claimed_instances[instance_id] = true


func add_instance(instance_id: String, item_id: String) -> bool:
	if (
		instance_id.is_empty()
		or not ResourceCatalog.has_resource(item_id)
		or not ResourceCatalog.is_tool_item(item_id)
	):
		return false
	if has_instance(instance_id):
		return false
	_instances[instance_id] = {"item_id": item_id}
	return true


func remove_instance(instance_id: String) -> bool:
	if not has_instance(instance_id):
		return false
	_instances.erase(instance_id)
	clear_hotbar_refs_for_instance(instance_id)
	return true


func allocate_instance_id(prefix: String = "pi") -> String:
	var candidate := "%s_%d" % [prefix, _next_instance_seq]
	while has_instance(candidate):
		_next_instance_seq += 1
		candidate = "%s_%d" % [prefix, _next_instance_seq]
	_next_instance_seq += 1
	return candidate


func create_instance(item_id: String, prefix: String = "pi") -> String:
	var instance_id := allocate_instance_id(prefix)
	if not add_instance(instance_id, item_id):
		return ""
	return instance_id


func seed_starter_tools(force := false) -> void:
	if force or _instances.is_empty():
		_instances.clear()
		for instance_id: String in STARTER_INSTANCES.keys():
			add_instance(instance_id, str(STARTER_INSTANCES[instance_id]))
	if _hotbar_refs.is_empty():
		for key: String in DEFAULT_HOTBAR_REFS.keys():
			_hotbar_refs[key] = str(DEFAULT_HOTBAR_REFS[key])
	validate_hotbar_refs()


func migrate_legacy_save() -> void:
	if _instances.is_empty():
		seed_starter_tools(false)
		return
	validate_hotbar_refs()
	if _hotbar_refs.is_empty():
		for key: String in DEFAULT_HOTBAR_REFS.keys():
			var instance_id := str(DEFAULT_HOTBAR_REFS[key])
			if has_instance(instance_id):
				_hotbar_refs[key] = instance_id


func volume_l() -> float:
	var total := 0.0
	for instance_id: String in list_instance_ids():
		total += ResourceCatalog.resource_volume_l(
			item_id_for_instance(instance_id),
			1.0
		)
	return total


func mass_kg() -> float:
	var total := 0.0
	for instance_id: String in list_instance_ids():
		total += ResourceCatalog.resource_mass_kg(
			item_id_for_instance(instance_id),
			1.0
		)
	return total


func snapshot_entries() -> Array:
	var rows: Array = []
	for instance_id: String in list_instance_ids():
		var item_id := item_id_for_instance(instance_id)
		rows.append({
			"item_id": item_id,
			"amount": 1.0,
			"category": ResourceCatalog.category(item_id),
			"discrete": true,
			"instance_id": instance_id,
		})
	return rows


func to_dict() -> Dictionary:
	var instances: Dictionary = {}
	for instance_id: String in list_instance_ids():
		instances[instance_id] = {
			"item_id": item_id_for_instance(instance_id),
		}
	return {
		"instances": instances,
		"hotbar_refs": _hotbar_refs.duplicate(true),
		"next_instance_seq": _next_instance_seq,
	}


static func from_dict(data: Dictionary) -> PlayerInventoryRegistry:
	var registry: PlayerInventoryRegistry = _SCRIPT.new()
	var instances: Variant = data.get("instances", {})
	if instances is Dictionary:
		for instance_id: Variant in instances.keys():
			var row: Variant = instances[instance_id]
			if row is Dictionary:
				registry.add_instance(
					str(instance_id),
					str(row.get("item_id", ""))
				)
	var hotbar_refs: Variant = data.get("hotbar_refs", {})
	if hotbar_refs is Dictionary:
		registry._hotbar_refs = hotbar_refs.duplicate(true)
	registry._next_instance_seq = maxi(
		int(data.get("next_instance_seq", 1)),
		1
	)
	registry.migrate_legacy_save()
	return registry


static func _hotbar_key(page: int, slot: int) -> String:
	return "%d:%d" % [page, slot]
