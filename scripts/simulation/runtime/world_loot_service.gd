class_name WorldLootService
extends RefCounted

static func list_world_loot_piles(world) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var pile_ids: Array = world._world_loot_piles.keys()
	pile_ids.sort()
	for pile_id_variant: Variant in pile_ids:
		var pile: WorldLootPile = world._world_loot_piles[int(pile_id_variant)]
		if pile != null:
			rows.append(pile.to_dict())
	return rows

static func add_world_loot_pile(world, 
	position: Vector3,
	resource_id: String,
	amount_kg: float,
	despawn_after_s: float = -1.0
) -> WorldLootPile:
	if resource_id.is_empty() or amount_kg <= 0.000001:
		return null
	var existing: WorldLootPile = WorldLootService.find_mergeable_loot_pile(world, 
		position,
		resource_id,
		amount_kg
	)
	if existing != null:
		var max_mass := IndustryArchetypeProfile.hand_drill_loot_pile_max_mass_kg()
		if existing.amount_kg + amount_kg <= max_mass + 0.000001:
			return WorldLootService.merge_loot_pile(world, existing, position, amount_kg)
	var despawn_at: float = world._simulation_time_s + (
		despawn_after_s
		if despawn_after_s > 0.0
		else IndustryArchetypeProfile.hand_drill_loot_despawn_s()
	)
	var pile: WorldLootPile = WorldLootPile.create(
		world._allocator.allocate_loot_pile_id(),
		position,
		resource_id,
		amount_kg,
		despawn_at
	)
	world._world_loot_piles[pile.pile_id] = pile
	return pile

static func find_mergeable_loot_pile(world, 
	position: Vector3,
	resource_id: String,
	amount_kg: float
) -> WorldLootPile:
	var best: WorldLootPile = null
	var best_dist_sq := INF
	for pile_variant: Variant in world._world_loot_piles.values():
		var pile := pile_variant as WorldLootPile
		if pile == null or pile.resource_id != resource_id:
			continue
		if not IndustryArchetypeProfile.hand_drill_loot_spheres_overlap(
			position,
			amount_kg,
			pile.position,
			pile.amount_kg
		):
			continue
		var dist_sq := position.distance_squared_to(pile.position)
		if best == null or dist_sq < best_dist_sq:
			best = pile
			best_dist_sq = dist_sq
	return best

static func merge_loot_pile(world, 
	target: WorldLootPile,
	new_position: Vector3,
	add_amount_kg: float
) -> WorldLootPile:
	var total := target.amount_kg + add_amount_kg
	if total <= 0.000001:
		return target
	var blend := add_amount_kg / total
	target.position = target.position.lerp(new_position, blend)
	target.amount_kg = total
	return target

static func sync_world_loot_position(world, pile_id: int, position: Vector3) -> bool:
	var pile: WorldLootPile = world._world_loot_piles.get(pile_id) as WorldLootPile
	if pile == null:
		return false
	pile.position = position
	return true

static func try_merge_world_loot_piles(world, pile_id_a: int, pile_id_b: int) -> bool:
	if pile_id_a == pile_id_b:
		return false
	var survivor_id := mini(pile_id_a, pile_id_b)
	var victim_id := maxi(pile_id_a, pile_id_b)
	var survivor: WorldLootPile = world._world_loot_piles.get(survivor_id)
	var victim: WorldLootPile = world._world_loot_piles.get(victim_id)
	if survivor == null or victim == null:
		return false
	if survivor.resource_id != victim.resource_id:
		return false
	if not IndustryArchetypeProfile.hand_drill_loot_spheres_overlap(
		survivor.position,
		survivor.amount_kg,
		victim.position,
		victim.amount_kg
	):
		return false
	var max_mass := IndustryArchetypeProfile.hand_drill_loot_pile_max_mass_kg()
	if survivor.amount_kg + victim.amount_kg > max_mass + 0.000001:
		return false
	WorldLootService.merge_loot_pile(world, survivor, victim.position, victim.amount_kg)
	world._world_loot_piles.erase(victim_id)
	return true

static func merge_nearby_world_loot_piles(world) -> bool:
	var pile_ids: Array = world._world_loot_piles.keys()
	pile_ids.sort()
	var changed := false
	for i: int in range(pile_ids.size()):
		var survivor_id := int(pile_ids[i])
		if not world._world_loot_piles.has(survivor_id):
			continue
		for j: int in range(i + 1, pile_ids.size()):
			var victim_id := int(pile_ids[j])
			if WorldLootService.try_merge_world_loot_piles(world, survivor_id, victim_id):
				changed = true
	return changed

static func remove_world_loot_pile(world, pile_id: int) -> bool:
	if not world._world_loot_piles.has(pile_id):
		return false
	world._world_loot_piles.erase(pile_id)
	return true

static func collect_world_loot_pile(world, 
	pile_id: int,
	to_store_id: String = IndustryStoreService.PLAYER_STORE_ID
) -> Dictionary:
	var pile: WorldLootPile = world._world_loot_piles.get(pile_id) as WorldLootPile
	var store: SimulationResourceStore = world.get_resource_store(to_store_id)
	if pile == null or store == null:
		return {"status": &"failed", "reason": &"invalid_reference", "amount": 0.0}
	var unit_mass := ResourceCatalog.mass_per_unit_kg(pile.resource_id)
	if unit_mass <= 0.000001 or pile.amount_kg <= 0.000001:
		return {"status": &"failed", "reason": &"no_input", "amount": 0.0}
	var capacity := IndustryStoreService.capacity_l_for_store(world, to_store_id)
	var available_units := pile.amount_kg / unit_mass
	var amount := minf(
		available_units,
		ResourceCatalog.max_addable_amount(
			store,
			pile.resource_id,
			capacity
		)
	)
	if amount <= 0.000001:
		return {
			"status": &"failed",
			"reason": &"storage_full",
			"amount": 0.0,
			"resource_id": pile.resource_id,
		}
	if not store.add(pile.resource_id, amount, capacity):
		return {"status": &"failed", "reason": &"storage_full", "amount": 0.0}
	pile.amount_kg = maxf(pile.amount_kg - amount * unit_mass, 0.0)
	if pile.amount_kg <= 0.000001:
		world._world_loot_piles.erase(pile_id)
	return {
		"status": &"ok",
		"reason": &"ok",
		"amount": amount,
		"resource_id": pile.resource_id,
	}

static func purge_expired_loot_piles(world) -> void:
	var stale: Array[int] = []
	for pile_id_variant: Variant in world._world_loot_piles.keys():
		var pile_id := int(pile_id_variant)
		var pile: WorldLootPile = world._world_loot_piles[pile_id]
		if pile == null:
			stale.append(pile_id)
			continue
		if pile.despawn_at_s > 0.0 and world._simulation_time_s + 0.000001 >= pile.despawn_at_s:
			stale.append(pile_id)
	for pile_id: int in stale:
		world._world_loot_piles.erase(pile_id)
