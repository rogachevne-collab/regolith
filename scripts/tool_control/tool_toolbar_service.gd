class_name ToolToolbarService
extends RefCounted

## Toolbar half of ToolController: the mutable runtime slot layout, page/slot
## selection, inventory sync and the runtime remap API.
##
## `tool` (the owning ToolController) is deliberately untyped: the monolith
## declares `class_name ToolController`, so naming the type here would close a
## `class_name` cycle. Owner constants and static helpers are reached through
## the instance for the same reason — `tool.TOOLBAR_PAGES`,
## `tool.TOOLBAR_SLOTS_PER_PAGE`, `tool.construction_archetype_ids()`.


static func toolbar_page_count(tool) -> int:
	var pages: Array = tool.TOOLBAR_PAGES
	return pages.size()


static func toolbar_slot_label(tool, page: int, slot: int) -> String:
	var entry := _toolbar_entry(tool, page, slot)
	return PlayerHotbarBridge.slot_label(entry, _player_inventory(tool))


static func _player_inventory(tool) -> PlayerInventoryRegistry:
	if tool._gateway == null:
		return null
	return tool._gateway.player_inventory()


static func _change_toolbar_page(tool, delta: int) -> void:
	var page_count := toolbar_page_count(tool)
	if page_count <= 0:
		return
	var current_page: int = tool.toolbar_page
	tool._toolbar_slot_by_page[current_page] = tool.toolbar_slot
	var next_page := wrapi(current_page + delta, 0, page_count)
	if next_page == current_page:
		return
	tool.toolbar_page = next_page
	var saved_slot: int = tool._toolbar_slot_by_page[next_page]
	_apply_toolbar_slot_or_first_nonempty(tool, next_page, saved_slot, false)


static func _apply_toolbar_slot(
	tool,
	page: int,
	slot: int,
	emit_tool_change: bool = true
) -> void:
	var entry := _toolbar_entry(tool, page, slot)
	if entry.is_empty():
		return
	tool.toolbar_page = page
	tool.toolbar_slot = slot
	tool._toolbar_slot_by_page[page] = slot
	var resolved := PlayerHotbarBridge.resolve_slot_entry(
		_player_inventory(tool),
		entry
	)
	if resolved.is_empty():
		return
	var previous_tool: StringName = tool.active_tool
	# Picking any slot — another tool or another build block — drops the rope
	# currently being pulled. Built ropes are untouched.
	tool._reset_connect_route()
	match StringName(resolved.get("kind", &"")):
		&"tool_instance":
			tool.active_tool = StringName(resolved.get("active_tool", &""))
		&"block":
			tool.active_tool = &"build"
			var next_archetype_id := str(resolved.get("archetype_id", "frame"))
			if next_archetype_id != tool.selected_archetype_id:
				tool.selected_orientation_index = _default_orientation_for(
					tool,
					next_archetype_id
				)
			tool.selected_archetype_id = next_archetype_id
			tool.construction_selection_changed.emit(
				tool.selected_archetype_id,
				tool.selected_orientation_index
			)
	if emit_tool_change and previous_tool != tool.active_tool:
		tool.active_tool_changed.emit(tool.active_tool)


static func _apply_toolbar_slot_or_first_nonempty(
	tool,
	page: int,
	preferred_slot: int,
	emit_tool_change: bool = true
) -> void:
	var slots_per_page: int = tool.TOOLBAR_SLOTS_PER_PAGE
	var slot := clampi(preferred_slot, 0, slots_per_page - 1)
	if not _toolbar_entry(tool, page, slot).is_empty():
		_apply_toolbar_slot(tool, page, slot, emit_tool_change)
		return
	for index: int in range(slots_per_page):
		if not _toolbar_entry(tool, page, index).is_empty():
			_apply_toolbar_slot(tool, page, index, emit_tool_change)
			return


static func _toolbar_entry(tool, page: int, slot: int) -> Dictionary:
	_ensure_runtime_state(tool)
	if page < 0 or page >= tool._toolbar_layout.size():
		return {}
	var slots: Array = tool._toolbar_layout[page]
	if slot < 0 or slot >= slots.size():
		return {}
	var entry: Variant = slots[slot]
	return entry if entry is Dictionary else {}


static func _canonical_toolbar_entry(tool, page: int, slot: int) -> Dictionary:
	var pages: Array = tool.TOOLBAR_PAGES
	if page < 0 or page >= pages.size():
		return {}
	var slots: Array = pages[page]
	if slot < 0 or slot >= slots.size():
		return {}
	var entry: Variant = slots[slot]
	return entry if entry is Dictionary else {}


## Lazily builds the mutable runtime layout (a deep copy of TOOLBAR_PAGES) and
## the per-page selected-slot memory. Safe to call repeatedly; idempotent.
static func _ensure_runtime_state(tool) -> void:
	if tool._toolbar_layout.is_empty():
		for page: Array in tool.TOOLBAR_PAGES:
			var page_copy: Array = []
			for entry: Variant in page:
				page_copy.append(
					(entry as Dictionary).duplicate(true)
					if entry is Dictionary
					else {}
				)
			tool._toolbar_layout.append(page_copy)
		_resolve_rover_pair_slots(tool)
		_sync_toolbar_from_inventory(tool)
	if tool._toolbar_slot_by_page.size() != tool._toolbar_layout.size():
		tool._toolbar_slot_by_page.resize(tool._toolbar_layout.size())
		for page_index: int in range(tool._toolbar_slot_by_page.size()):
			tool._toolbar_slot_by_page[page_index] = 0


## Подставить в слоты-заглушки пару, испечённую визардом. Пары нет — слоты
## остаются пустыми: лучше дырка в палитре, чем ссылка на несуществующую деталь.
static func _resolve_rover_pair_slots(tool) -> void:
	var pair := Slice01Archetypes.authored_wheel_pair()
	var resolved := {
		tool.SUSPENSION_SLOT: str(pair.get("suspension", "")),
		tool.WHEEL_SLOT: str(pair.get("wheel", "")),
	}
	for page: Array in tool._toolbar_layout:
		for slot_index: int in range(page.size()):
			var entry: Variant = page[slot_index]
			if not entry is Dictionary:
				continue
			var archetype_id := str((entry as Dictionary).get("archetype_id", ""))
			if not resolved.has(archetype_id):
				continue
			var replacement := str(resolved[archetype_id])
			if replacement.is_empty():
				page[slot_index] = {}
			else:
				(entry as Dictionary)["archetype_id"] = replacement


## Latin/archetype id shown by a slot: "drill" / "weld" / archetype_id / "" for
## empty. Reads the runtime layout so presentation reflects live remaps.
static func toolbar_slot_archetype_id(tool, page: int, slot: int) -> String:
	var entry := _toolbar_entry(tool, page, slot)
	return PlayerHotbarBridge.slot_archetype_id(entry, _player_inventory(tool))


## Whether a slot may be reassigned to a construction archetype. Empty and
## block slots accept a remap; the drill/weld/grinder tool slots stay fixed.
static func toolbar_slot_accepts_block(tool, page: int, slot: int) -> bool:
	var slots_per_page: int = tool.TOOLBAR_SLOTS_PER_PAGE
	if page < 0 or slot < 0 or slot >= slots_per_page:
		return false
	var canonical := _canonical_toolbar_entry(tool, page, slot)
	if canonical.is_empty():
		return true
	return StringName(canonical.get("type", &"")) == &"block"


## Fixed tool slots accept only an instance of their original tool type. This
## retains the existing toolbar roles while binding each slot to an owned item.
static func toolbar_slot_accepts_tool_instance(
	tool,
	page: int,
	slot: int,
	instance_id: String
) -> bool:
	var registry: PlayerInventoryRegistry = _player_inventory(tool)
	if registry == null or not registry.has_instance(instance_id):
		return false
	var canonical := _canonical_toolbar_entry(tool, page, slot)
	var expected_type := StringName(canonical.get("type", &""))
	if not PlayerHotbarBridge.LEGACY_TOOL_TYPES.has(expected_type):
		return false
	return (
		PlayerHotbarBridge.active_tool_for_instance(registry, instance_id)
		== expected_type
	)


## Binds an owned tool instance to its matching fixed toolbar slot. Submits a
## host-authoritative command; toolbar layout refreshes when inventory revision
## advances (local flush or coop store/inventory sync).
static func assign_slot_tool_instance(
	tool,
	page: int,
	slot: int,
	instance_id: String
) -> bool:
	if (
		tool._gateway == null
		or not toolbar_slot_accepts_tool_instance(tool, page, slot, instance_id)
	):
		return false
	tool._gateway.assign_player_hotbar_instance(page, slot, instance_id)
	return true


## Runtime slot remap (BlockPalette drag-drop target). Reassigns page/slot to a
## construction archetype in the mutable layout copy. Refuses to overwrite the
## fixed tool slots and unknown archetypes, so paging and the three tool slots
## stay intact. Emits toolbar_layout_changed and, when the reassigned slot
## is the currently selected one, re-drives selection through the SAME path used
## by keyboard slot selection — the construction command path is unchanged.
static func assign_slot_archetype(
	tool,
	page: int,
	slot: int,
	archetype_id: String
) -> bool:
	_ensure_runtime_state(tool)
	if page < 0 or page >= tool._toolbar_layout.size():
		return false
	var slots: Array = tool._toolbar_layout[page]
	if slot < 0 or slot >= slots.size():
		return false
	if not tool.construction_archetype_ids().has(archetype_id):
		return false
	if not toolbar_slot_accepts_block(tool, page, slot):
		return false
	slots[slot] = {"type": &"block", "archetype_id": archetype_id}
	tool.toolbar_layout_revision += 1
	tool.toolbar_layout_changed.emit(page, slot, archetype_id)
	if page == tool.toolbar_page and slot == tool.toolbar_slot:
		_apply_toolbar_slot(tool, page, slot, true)
	return true


static func _default_orientation_for(tool, archetype_id: String) -> int:
	if tool._gateway == null:
		return 0
	var archetype: ElementArchetype = tool._gateway.construction_archetype(
		archetype_id
	)
	if archetype == null:
		return 0
	return clampi(
		archetype.default_orientation_index,
		0,
		OrientationUtil.ORIENTATION_COUNT - 1
	)


static func _sync_inventory_toolbar_if_needed(tool) -> void:
	if tool._gateway == null:
		return
	var revision: int = tool._gateway.player_inventory_revision()
	if revision == tool._inventory_revision:
		return
	tool._inventory_revision = revision
	_sync_toolbar_from_inventory(tool)
	tool.toolbar_layout_revision += 1
	_apply_toolbar_slot_or_first_nonempty(
		tool,
		tool.toolbar_page,
		tool.toolbar_slot,
		true
	)


static func _sync_toolbar_from_inventory(tool) -> void:
	_ensure_runtime_state(tool)
	var registry: PlayerInventoryRegistry = _player_inventory(tool)
	if registry == null:
		return
	PlayerHotbarBridge.apply_registry_to_layout(
		registry,
		tool._toolbar_layout,
		tool.TOOLBAR_PAGES
	)


static func _active_slot_resolved(tool) -> Dictionary:
	return PlayerHotbarBridge.resolve_slot_entry(
		_player_inventory(tool),
		_toolbar_entry(tool, tool.toolbar_page, tool.toolbar_slot)
	)


static func _active_tool_is_equipped(tool) -> bool:
	match tool.active_tool:
		&"drill", &"weld", &"grinder", &"connect", &"rope":
			var resolved := _active_slot_resolved(tool)
			if StringName(resolved.get("kind", &"")) != &"tool_instance":
				return false
			var instance_id := str(resolved.get("instance_id", ""))
			if instance_id.is_empty():
				return bool(resolved.get("legacy", false))
			var registry: PlayerInventoryRegistry = _player_inventory(tool)
			return (
				registry != null
				and registry.has_instance(instance_id)
				and PlayerHotbarBridge.slot_owns_instance(
					registry,
					tool.toolbar_page,
					tool.toolbar_slot,
					instance_id
				)
			)
		_:
			return true
