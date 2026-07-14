class_name StoreSnapshotBuilder
extends RefCounted
## Authoritative read model for terminal inventory (INDUSTRY-V1 § Terminal inventory).
## Pure logic over SimulationWorld; WorldCommandGateway delegates here.


static func build(world: SimulationWorld, store_id: String) -> Dictionary:
	if world == null:
		return failure(&"not_ready")
	if store_id.is_empty():
		return failure(&"invalid_reference")

	if store_id == IndustryStoreService.PLAYER_STORE_ID:
		return _build_player_snapshot(world)

	if store_id.begins_with(IndustryStoreService.BUFFER_STORE_PREFIX):
		return _build_buffer_snapshot(
			world,
			IndustryStoreService.parse_buffer_element_id(store_id),
			store_id
		)

	if store_id.begins_with(IndustryStoreService.ELEMENT_STORE_PREFIX):
		return _build_keyed_snapshot(
			world,
			IndustryStoreService.parse_element_id_from_store(store_id),
			store_id
		)

	var store := world.get_resource_store(store_id)
	if store == null:
		return failure(&"invalid_reference")
	return _build_resource_store_snapshot(world, store_id, store, null)


static func failure(reason: StringName = &"invalid_reference") -> Dictionary:
	return {
		"valid": false,
		"reason": reason,
	}


static func _build_player_snapshot(world: SimulationWorld) -> Dictionary:
	var store := IndustryStoreService.ensure_player_store(world)
	if store == null:
		return failure(&"invalid_reference")
	var registry := IndustryStoreService.ensure_player_inventory(world)
	var entries := _store_entries(store)
	if registry != null:
		for row: Dictionary in registry.snapshot_entries():
			entries.append(row)
	entries.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var a_key := str(a.get("item_id", ""))
			var b_key := str(b.get("item_id", ""))
			if a_key == b_key:
				return str(a.get("instance_id", "")) < str(b.get("instance_id", ""))
			return a_key < b_key
	)
	var used_l := store.volume_l()
	var mass_kg := store.mass_kg()
	if registry != null:
		used_l += registry.volume_l()
		mass_kg += registry.mass_kg()
	return _snapshot_from_amounts(
		IndustryStoreService.PLAYER_STORE_ID,
		HudTokens.store_label(IndustryStoreService.PLAYER_STORE_ID),
		entries,
		used_l,
		IndustryStoreService.player_carry_capacity_l(),
		mass_kg,
		null,
		world
	)


static func _build_buffer_snapshot(
	world: SimulationWorld,
	element_id: int,
	store_id: String
) -> Dictionary:
	if element_id <= 0:
		return failure(&"invalid_reference")
	var element := world.get_element(element_id)
	if (
		element == null
		or not IndustryArchetypeProfile.has_internal_buffer(element.archetype_id)
	):
		return failure(&"invalid_reference")
	if element.industry_buffer == null:
		element.industry_buffer = ElementIndustryBuffer.new()
	var capacity_l := IndustryStoreService.capacity_l_for_store(world, store_id)
	return _snapshot_from_amounts(
		store_id,
		_title_for_element(element),
		_buffer_entries(element.industry_buffer),
		element.industry_buffer.volume_l(),
		capacity_l,
		element.industry_buffer.mass_kg(),
		element,
		world
	)


static func _build_keyed_snapshot(
	world: SimulationWorld,
	element_id: int,
	store_id: String
) -> Dictionary:
	if element_id <= 0:
		return failure(&"invalid_reference")
	var element := world.get_element(element_id)
	if (
		element == null
		or not IndustryArchetypeProfile.has_keyed_store(element.archetype_id)
	):
		return failure(&"invalid_reference")
	var store := IndustryStoreService.ensure_element_keyed_store(world, element)
	if store == null:
		return failure(&"invalid_reference")
	return _build_resource_store_snapshot(
		world,
		store_id,
		store,
		element,
		_title_for_element(element)
	)


static func _build_resource_store_snapshot(
	world: SimulationWorld,
	store_id: String,
	store: SimulationResourceStore,
	element: SimulationElement,
	title: String = ""
) -> Dictionary:
	if store == null:
		return failure(&"invalid_reference")
	var resolved_title := title
	if resolved_title.is_empty():
		resolved_title = HudTokens.store_label(store_id)
	var capacity_l := IndustryStoreService.capacity_l_for_store(world, store_id)
	return _snapshot_from_amounts(
		store_id,
		resolved_title,
		_store_entries(store),
		store.volume_l(),
		capacity_l,
		store.mass_kg(),
		element,
		world
	)


static func _snapshot_from_amounts(
	store_id: String,
	title: String,
	entries: Array,
	used_l: float,
	capacity_l: float,
	mass_kg: float,
	element: SimulationElement,
	world: SimulationWorld
) -> Dictionary:
	var machine_element := element
	if machine_element == null and store_id.begins_with(
		IndustryStoreService.BUFFER_STORE_PREFIX
	):
		machine_element = world.get_element(
			IndustryStoreService.parse_buffer_element_id(store_id)
		)
	elif machine_element == null and store_id.begins_with(
		IndustryStoreService.ELEMENT_STORE_PREFIX
	):
		machine_element = world.get_element(
			IndustryStoreService.parse_element_id_from_store(store_id)
		)
	var is_machine := _is_machine_element(machine_element)
	var machine: Variant = null
	if is_machine:
		machine = _machine_snapshot(world, machine_element)
	return {
		"valid": true,
		"store_id": store_id,
		"title": title,
		"entries": entries,
		"used_l": used_l,
		"capacity_l": capacity_l,
		"mass_kg": mass_kg,
		"is_machine": is_machine,
		"machine": machine,
	}


static func _store_entries(store: SimulationResourceStore) -> Array:
	var entries: Array = []
	for item_id: String in store.resource_ids():
		var amount := store.amount(item_id)
		if amount <= ResourceCatalog.EPSILON:
			continue
		entries.append(_entry_row(item_id, amount))
	return entries


static func _buffer_entries(buffer: ElementIndustryBuffer) -> Array:
	var entries: Array = []
	for item_id: String in buffer.resource_ids():
		var amount := buffer.amount(item_id)
		if amount <= ResourceCatalog.EPSILON:
			continue
		entries.append(_entry_row(item_id, amount))
	return entries


static func _entry_row(item_id: String, amount: float) -> Dictionary:
	return {
		"item_id": item_id,
		"amount": amount,
		"category": ResourceCatalog.category(item_id),
		"discrete": ResourceCatalog.is_discrete(item_id),
	}


static func _title_for_element(element: SimulationElement) -> String:
	if element == null:
		return "—"
	return HudTokens.archetype_label(element.archetype_id)


static func _is_machine_element(element: SimulationElement) -> bool:
	if element == null or not element.is_operational():
		return false
	if IndustryArchetypeProfile.is_recipe_machine(element.archetype_id):
		return true
	return element.archetype_id == "stationary_drill"


static func _machine_snapshot(
	world: SimulationWorld,
	element: SimulationElement
) -> Dictionary:
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	var status := IndustryStatusUtil.resolve_display_reason(world, element)
	var row := {
		"enabled": runtime.machine_enabled,
		"recipe_id": "",
		"recipes": [],
		"queue": [],
		"progress": 0.0,
		"status": status,
	}
	if IndustryArchetypeProfile.is_recipe_machine(element.archetype_id):
		var machine := runtime.ensure_machine_state()
		row["recipe_id"] = machine.active_recipe_id
		row["recipes"] = RecipeCatalog.recipe_ids_for_machine(
			element.archetype_id
		)
		row["queue"] = machine.queue.duplicate()
		if not machine.active_recipe_id.is_empty():
			var duration_s := maxf(
				RecipeCatalog.duration_s(machine.active_recipe_id),
				0.000001
			)
			row["progress"] = clampf(machine.progress_s / duration_s, 0.0, 1.0)
	return row
