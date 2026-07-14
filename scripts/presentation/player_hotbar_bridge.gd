class_name PlayerHotbarBridge
extends RefCounted
## Pure logic for inventory instance ↔ toolbar slot resolution (INDUSTRY-V1 §
## Player tool instances). Headless-testable; no UI nodes.

const LEGACY_TOOL_TYPES: Dictionary = {
	&"drill": "tool_hand_drill",
	&"weld": "tool_welder",
	&"grinder": "tool_grinder",
	&"connect": "tool_connector",
}

const ITEM_TO_ACTIVE_TOOL: Dictionary = {
	"tool_hand_drill": &"drill",
	"tool_welder": &"weld",
	"tool_grinder": &"grinder",
	"tool_connector": &"connect",
}


static func active_tool_for_item(item_id: String) -> StringName:
	return StringName(ITEM_TO_ACTIVE_TOOL.get(item_id, &""))


static func active_tool_for_instance(
	registry: PlayerInventoryRegistry,
	instance_id: String
) -> StringName:
	if registry == null or instance_id.is_empty():
		return &""
	return active_tool_for_item(registry.item_id_for_instance(instance_id))


static func slot_owns_instance(
	registry: PlayerInventoryRegistry,
	page: int,
	slot: int,
	instance_id: String
) -> bool:
	if registry == null or instance_id.is_empty():
		return false
	return (
		registry.has_instance(instance_id)
		and registry.hotbar_instance_id(page, slot) == instance_id
	)


static func resolve_slot_entry(
	registry: PlayerInventoryRegistry,
	entry: Dictionary
) -> Dictionary:
	if entry.is_empty():
		return {}
	if entry.has("instance_id"):
		var instance_id := str(entry.get("instance_id", ""))
		if registry == null or not registry.has_instance(instance_id):
			return {}
		var item_id := registry.item_id_for_instance(instance_id)
		var tool := active_tool_for_item(item_id)
		if tool.is_empty():
			return {}
		return {
			"kind": &"tool_instance",
			"instance_id": instance_id,
			"item_id": item_id,
			"active_tool": tool,
		}
	var legacy_type := StringName(entry.get("type", &""))
	if LEGACY_TOOL_TYPES.has(legacy_type):
		return {
			"kind": &"tool_instance",
			"item_id": str(LEGACY_TOOL_TYPES[legacy_type]),
			"active_tool": StringName(legacy_type),
			"legacy": true,
		}
	if legacy_type == &"block":
		return {
			"kind": &"block",
			"archetype_id": str(entry.get("archetype_id", "frame")),
		}
	return {}


static func apply_registry_to_layout(
	registry: PlayerInventoryRegistry,
	layout: Array,
	canonical_layout: Array
) -> void:
	if registry == null or layout.is_empty() or canonical_layout.is_empty():
		return
	for page: int in layout.size():
		var slots: Array = layout[page]
		for slot: int in slots.size():
			if page >= canonical_layout.size():
				continue
			var canonical_page: Array = canonical_layout[page]
			if slot >= canonical_page.size():
				continue
			var canonical_entry: Variant = canonical_page[slot]
			if not canonical_entry is Dictionary:
				continue
			var canonical_type := StringName(
				(canonical_entry as Dictionary).get("type", &"")
			)
			if not LEGACY_TOOL_TYPES.has(canonical_type):
				continue
			var instance_id := registry.hotbar_instance_id(page, slot)
			if instance_id.is_empty():
				slots[slot] = {}
				continue
			slots[slot] = {
				"kind": &"tool_instance",
				"instance_id": instance_id,
			}


static func slot_label(entry: Dictionary, registry: PlayerInventoryRegistry) -> String:
	var resolved := resolve_slot_entry(registry, entry)
	if resolved.is_empty():
		return "—"
	match StringName(resolved.get("kind", &"")):
		&"tool_instance":
			match StringName(resolved.get("active_tool", &"")):
				&"drill":
					return "бур"
				&"weld":
					return "сварка"
				&"grinder":
					return "болгарка"
				&"connect":
					return "соединение"
				_:
					return "—"
		&"block":
			return str(resolved.get("archetype_id", ""))
		_:
			return "—"


static func slot_archetype_id(
	entry: Dictionary,
	registry: PlayerInventoryRegistry
) -> String:
	var resolved := resolve_slot_entry(registry, entry)
	if resolved.is_empty():
		return ""
	match StringName(resolved.get("kind", &"")):
		&"tool_instance":
			return String(resolved.get("active_tool", ""))
		&"block":
			return str(resolved.get("archetype_id", ""))
		_:
			return ""
