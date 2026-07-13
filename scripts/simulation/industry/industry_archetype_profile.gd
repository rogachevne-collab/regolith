class_name IndustryArchetypeProfile
extends RefCounted

## Runtime storage capacities until archetype fixtures expose storage_capacity_kg.

const PLAYER_CARRY_CAPACITY_KG := 80.0

const KEYED_STORE_CAPACITY_KG: Dictionary = {
	"cargo_store": 2000.0,
}

const INTERNAL_BUFFER_CAPACITY_KG: Dictionary = {
	"stationary_drill": 200.0,
	"processor": 100.0,
	"fabricator": 100.0,
}

const INTERNAL_BUFFER_ARCHETYPES: PackedStringArray = [
	"stationary_drill",
	"processor",
	"fabricator",
]

const RECIPE_MACHINE_ARCHETYPES: PackedStringArray = [
	"processor",
	"fabricator",
]

const KEYED_STORE_ARCHETYPES: PackedStringArray = [
	"cargo_store",
]

const QUEUE_MAX_DEPTH := 4

const DEFAULT_RECIPES: Dictionary = {
	"processor": "crush_regolith",
	"fabricator": "reduce_oxide",
}

const DRILL_KG_PER_M3 := 1500.0
const DRILL_CARVE_RADIUS_M := 0.31
const DRILL_HEAD_OFFSET_M := 0.92
const DRILL_CONTACT_REACH_M := 0.72
const DRILL_REQUIRES_POWER := true

const HAND_DRILL_LOOT_DESPAWN_S := 600.0
const HAND_DRILL_LOOT_KG_PER_M3 := 1500.0


static func has_internal_buffer(archetype_id: String) -> bool:
	return INTERNAL_BUFFER_ARCHETYPES.has(archetype_id)


static func has_keyed_store(archetype_id: String) -> bool:
	return KEYED_STORE_ARCHETYPES.has(archetype_id)


static func keyed_store_capacity_kg(archetype_id: String) -> float:
	return float(KEYED_STORE_CAPACITY_KG.get(archetype_id, 0.0))


static func internal_buffer_capacity_kg(archetype_id: String) -> float:
	return float(INTERNAL_BUFFER_CAPACITY_KG.get(archetype_id, 0.0))


static func player_carry_capacity_kg() -> float:
	return PLAYER_CARRY_CAPACITY_KG


static func is_recipe_machine(archetype_id: String) -> bool:
	return RECIPE_MACHINE_ARCHETYPES.has(archetype_id)


static func queue_max_depth() -> int:
	return QUEUE_MAX_DEPTH


static func drill_kg_per_m3() -> float:
	return DRILL_KG_PER_M3


static func drill_carve_radius_m() -> float:
	return DRILL_CARVE_RADIUS_M


static func drill_carve_volume_budget_m3() -> float:
	return TerrainImpactCarver.sphere_volume(DRILL_CARVE_RADIUS_M)


static func drill_head_offset_m() -> float:
	return DRILL_HEAD_OFFSET_M


static func drill_contact_reach_m() -> float:
	return DRILL_CONTACT_REACH_M


static func drill_requires_power() -> bool:
	return DRILL_REQUIRES_POWER


static func hand_drill_loot_despawn_s() -> float:
	return HAND_DRILL_LOOT_DESPAWN_S


static func hand_drill_loot_kg_per_m3() -> float:
	return HAND_DRILL_LOOT_KG_PER_M3
