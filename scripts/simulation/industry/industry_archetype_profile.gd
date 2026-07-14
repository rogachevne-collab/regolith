class_name IndustryArchetypeProfile
extends RefCounted

## Runtime storage capacities until archetype fixtures expose storage_capacity_l.

const PLAYER_CARRY_CAPACITY_L := 100.0

const KEYED_STORE_CAPACITY_L: Dictionary = {
	"cargo_store": 2000.0,
}

const INTERNAL_BUFFER_CAPACITY_L: Dictionary = {
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

## Stationary drill main body edge (2×2×2 footprint cells × 0.5 m cell; collider
## size 1×1×1 m in `stationary_drill.tres`). Working radius and contact reach are
## at least this large so the bite zone matches the housing scale.
const DRILL_BODY_SIZE_M := 1.0
const DRILL_CARVE_RADIUS_M := 1.25
## Working-tip offset along oriented local +X from footprint pivot. Must match
## `WorkingTip` in `scenes/presentation/stationary_drill_visual.tscn`
## (OperationalRotor 0.55 + tip 0.9).
const DRILL_HEAD_OFFSET_M := 1.45
const DRILL_CONTACT_REACH_M := 1.4
## Carve sphere center offset from contact point along the working face (+X).
## Lower values keep the bite at the tip instead of carving ahead of it.
const DRILL_CARVE_CENTER_OFFSET_FACTOR := 0.2
const DRILL_REQUIRES_POWER := true

const HAND_DRILL_CARVE_RADIUS_M := 0.65
const HAND_DRILL_BITE_DEPTH_M := 0.18
const HAND_DRILL_SDF_SCALE := 0.8
## Hand drill aim reach. The aim ray starts at the eye (~1.65 m above the feet),
## so the ground directly beneath the player already sits ~1.66 m away and the
## ground near the feet under a natural downward look is farther still. Reach
## must clear eye-to-floor plus a working depth so looking down reliably carves
## under the player and keeps reaching as a pit deepens.
const HAND_DRILL_REACH_M := 3.2
## Fraction of measured removed mass that becomes collectible resource; the rest
## is dust. Tuned for edge-bite carving at ~1–2 kg/s hand drill tempo.
const TERRAIN_COLLECTIBLE_FRACTION := 0.01
const HAND_DRILL_LOOT_PILE_MAX_MASS_KG := 32.0
const HAND_DRILL_LOOT_BASE_RADIUS_M := 0.16
const HAND_DRILL_LOOT_MASS_REFERENCE_KG := 12.0
const HAND_DRILL_LOOT_SCALE_MIN := 0.75
const HAND_DRILL_LOOT_SCALE_MAX := 1.35
## Small tolerance so resting sphere contacts count as merge-eligible.
const HAND_DRILL_LOOT_MERGE_CONTACT_EPSILON_M := 0.02
const HAND_DRILL_INTERVAL_S := 0.08
const HAND_DRILL_LOOT_DESPAWN_S := 600.0


static func has_internal_buffer(archetype_id: String) -> bool:
	return INTERNAL_BUFFER_ARCHETYPES.has(archetype_id)


static func has_keyed_store(archetype_id: String) -> bool:
	return KEYED_STORE_ARCHETYPES.has(archetype_id)


static func keyed_store_capacity_l(archetype_id: String) -> float:
	return float(KEYED_STORE_CAPACITY_L.get(archetype_id, 0.0))


static func internal_buffer_capacity_l(archetype_id: String) -> float:
	return float(INTERNAL_BUFFER_CAPACITY_L.get(archetype_id, 0.0))


static func player_carry_capacity_l() -> float:
	return PLAYER_CARRY_CAPACITY_L


static func is_recipe_machine(archetype_id: String) -> bool:
	return RECIPE_MACHINE_ARCHETYPES.has(archetype_id)


static func queue_max_depth() -> int:
	return QUEUE_MAX_DEPTH


static func drill_carve_radius_m() -> float:
	return DRILL_CARVE_RADIUS_M


static func drill_body_size_m() -> float:
	return DRILL_BODY_SIZE_M


static func drill_max_request_volume_m3() -> float:
	return TerrainExcavationService.sphere_volume_m3(
		DRILL_CARVE_RADIUS_M
	)


static func drill_head_offset_m() -> float:
	return DRILL_HEAD_OFFSET_M


static func drill_contact_reach_m() -> float:
	return DRILL_CONTACT_REACH_M


static func drill_carve_center_offset_factor() -> float:
	return DRILL_CARVE_CENTER_OFFSET_FACTOR


static func drill_requires_power() -> bool:
	return DRILL_REQUIRES_POWER


static func hand_drill_carve_radius_m() -> float:
	return HAND_DRILL_CARVE_RADIUS_M


static func hand_drill_bite_depth_m() -> float:
	return HAND_DRILL_BITE_DEPTH_M


static func hand_drill_reach_m() -> float:
	return HAND_DRILL_REACH_M


static func hand_drill_sdf_scale() -> float:
	return HAND_DRILL_SDF_SCALE


static func terrain_collectible_fraction() -> float:
	return TERRAIN_COLLECTIBLE_FRACTION


static func hand_drill_loot_pile_max_mass_kg() -> float:
	return HAND_DRILL_LOOT_PILE_MAX_MASS_KG


static func hand_drill_interval_s() -> float:
	return HAND_DRILL_INTERVAL_S


static func hand_drill_loot_merge_radius_m() -> float:
	return HAND_DRILL_LOOT_BASE_RADIUS_M * HAND_DRILL_LOOT_SCALE_MAX * 2.0


static func hand_drill_loot_collision_radius_m(amount_kg: float) -> float:
	var ratio := maxf(amount_kg / HAND_DRILL_LOOT_MASS_REFERENCE_KG, 0.2)
	var scale := clampf(
		pow(ratio, 1.0 / 3.0),
		HAND_DRILL_LOOT_SCALE_MIN,
		HAND_DRILL_LOOT_SCALE_MAX
	)
	return HAND_DRILL_LOOT_BASE_RADIUS_M * scale


static func hand_drill_loot_spheres_overlap(
	position_a: Vector3,
	amount_kg_a: float,
	position_b: Vector3,
	amount_kg_b: float
) -> bool:
	var reach := (
		hand_drill_loot_collision_radius_m(amount_kg_a)
		+ hand_drill_loot_collision_radius_m(amount_kg_b)
		+ HAND_DRILL_LOOT_MERGE_CONTACT_EPSILON_M
	)
	return position_a.distance_to(position_b) <= reach


static func hand_drill_loot_despawn_s() -> float:
	return HAND_DRILL_LOOT_DESPAWN_S
