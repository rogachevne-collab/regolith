class_name IndustryArchetypeProfile
extends RefCounted

## Industry capacities and drill tuning. Authoritative values live in
## `res://resources/balance/game_balance.json` (Game Balance v0).

const RECIPE_MACHINE_ARCHETYPES: PackedStringArray = [
	"processor",
	"fabricator",
	"electrolyzer",
]

## Compatibility alias for callers that still read `DEFAULT_RECIPES`.
static var DEFAULT_RECIPES: Dictionary:
	get:
		return default_recipes()


static func has_internal_buffer(archetype_id: String) -> bool:
	return _capacity_map("internal_buffer_capacity_l").has(archetype_id)


static func has_keyed_store(archetype_id: String) -> bool:
	return _capacity_map("keyed_store_capacity_l").has(archetype_id)


static func keyed_store_capacity_l(archetype_id: String) -> float:
	return float(_capacity_map("keyed_store_capacity_l").get(archetype_id, 0.0))


static func internal_buffer_capacity_l(archetype_id: String) -> float:
	return float(
		_capacity_map("internal_buffer_capacity_l").get(archetype_id, 0.0)
	)


static func player_carry_capacity_l() -> float:
	return float(GameBalance.industry().get("player_carry_capacity_l", 100.0))


static func is_recipe_machine(archetype_id: String) -> bool:
	return RECIPE_MACHINE_ARCHETYPES.has(archetype_id)


static func queue_max_depth() -> int:
	return int(GameBalance.industry().get("queue_max_depth", 4))


static func default_recipes() -> Dictionary:
	var defaults: Variant = GameBalance.industry().get("default_recipes", {})
	return defaults if defaults is Dictionary else {}


static func drill_carve_radius_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["stationary_drill", "carve_radius_m"]),
		1.25
	)


static func drill_body_size_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["stationary_drill", "body_size_m"]),
		1.0
	)


static func drill_max_request_volume_m3() -> float:
	return TerrainExcavationService.sphere_volume_m3(drill_carve_radius_m())


static func drill_head_offset_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["stationary_drill", "head_offset_m"]),
		1.45
	)


static func drill_contact_reach_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["stationary_drill", "contact_reach_m"]),
		1.4
	)


static func drill_carve_center_offset_factor() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["stationary_drill", "carve_center_offset_factor"]),
		0.2
	)


static func drill_requires_power() -> bool:
	return GameBalance.industry_bool(
		PackedStringArray(["stationary_drill", "requires_power"]),
		true
	)


## Radius the mounted dozer blade sweeps loose material over, for both the scoop
## it loads and the shove-aside it does when full.
static func dozer_blade_push_radius_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["dozer_blade", "push_radius_m"]),
		1.5
	)


## Fraction of the material under the blade a plow-aside pass moves per tick when
## the buffer is full (the rest stays put). Passed straight to `push_at`.
static func dozer_blade_push_share() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["dozer_blade", "push_share"]),
		0.5
	)


## How far in front of the blade's working face loose material still counts as
## in contact.
static func dozer_blade_contact_reach_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["dozer_blade", "contact_reach_m"]),
		1.6
	)


## Offset from the blade footprint pivot to its working edge, along local +X.
static func dozer_blade_head_offset_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["dozer_blade", "head_offset_m"]),
		0.35
	)


## How far below the footprint pivot the contact probe starts, along local -Y.
## The pivot sits at mid-height of the blade; the material a blade actually works
## is at its cutting edge, so probing from the pivot only found heaps taller than
## half the blade and lost them the moment the rover pitched.
static func dozer_blade_edge_drop_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["dozer_blade", "edge_drop_m"]),
		0.35
	)


## Downward tilt of the contact probe from the working direction. A horizontal
## ray leaves the ground the instant the blade rides up on the heap it is
## cutting; angling it down keeps the probe on the material under the edge.
static func dozer_blade_probe_pitch_deg() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["dozer_blade", "probe_pitch_deg"]),
		25.0
	)


## Ceiling on how much loose material one tick may load into the buffer. Keeps
## the blade a bulk mover that never out-collects a drill per unit time.
static func dozer_blade_tick_volume_budget_m3() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["dozer_blade", "tick_volume_budget_m3"]),
		0.05
	)


static func dozer_blade_requires_power() -> bool:
	return GameBalance.industry_bool(
		PackedStringArray(["dozer_blade", "requires_power"]),
		true
	)


static func hand_drill_carve_radius_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "carve_radius_m"]),
		1.0
	)


static func hand_drill_bite_depth_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "bite_depth_m"]),
		0.18
	)


static func hand_drill_reach_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "reach_m"]),
		2.25
	)


static func hand_drill_sdf_scale() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "sdf_scale"]),
		0.8
	)


static func terrain_collectible_fraction() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "terrain_collectible_fraction"]),
		0.01
	)


## How much the drill has to free before it drops a chunk you can pick up.
## In litres rather than kilograms so a dropped chunk is the same size whatever
## it is made of: 20 L of ilmenite outweighs 20 L of regolith by two thirds but
## looks identical lying on the ground.
static func hand_drill_loot_emit_volume_l() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "loot_emit_volume_l"]),
		20.0
	)


static func hand_drill_loot_pile_max_mass_kg() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "loot_pile_max_mass_kg"]),
		32.0
	)


static func hand_drill_interval_s() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "interval_s"]),
		0.15
	)


## Excavation-mode cadence (ПКМ). Faster than the mining tick — this mode is
## about clearing rock, not collecting it, so the bites come more often.
static func hand_drill_extract_interval_s() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "extract_interval_s"]),
		0.09
	)


## Excavation-mode carve radius (ПКМ). A touch wider than the mining bite so
## clearing overburden feels more active than picking at ore.
static func hand_drill_extract_carve_radius_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "extract_carve_radius_m"]),
		1.35
	)


static func hand_drill_path_max_span_m() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "path_max_span_m"]),
		1.4
	)


static func hand_drill_path_max_gap_ms() -> int:
	return GameBalance.industry_int(
		PackedStringArray(["hand_drill", "path_max_gap_ms"]),
		250
	)


static func hand_drill_loot_merge_radius_m() -> float:
	return (
		GameBalance.industry_float(
			PackedStringArray(["hand_drill", "loot_base_radius_m"]),
			0.16
		)
		* GameBalance.industry_float(
			PackedStringArray(["hand_drill", "loot_scale_max"]),
			1.35
		)
		* 2.0
	)


static func hand_drill_loot_collision_radius_m(amount_kg: float) -> float:
	var base_radius := GameBalance.industry_float(
		PackedStringArray(["hand_drill", "loot_base_radius_m"]),
		0.16
	)
	var mass_reference := GameBalance.industry_float(
		PackedStringArray(["hand_drill", "loot_mass_reference_kg"]),
		12.0
	)
	var scale_min := GameBalance.industry_float(
		PackedStringArray(["hand_drill", "loot_scale_min"]),
		0.75
	)
	var scale_max := GameBalance.industry_float(
		PackedStringArray(["hand_drill", "loot_scale_max"]),
		1.35
	)
	var ratio := maxf(amount_kg / mass_reference, 0.2)
	var scale := clampf(pow(ratio, 1.0 / 3.0), scale_min, scale_max)
	return base_radius * scale


static func hand_drill_loot_spheres_overlap(
	position_a: Vector3,
	amount_kg_a: float,
	position_b: Vector3,
	amount_kg_b: float
) -> bool:
	var epsilon := GameBalance.industry_float(
		PackedStringArray(["hand_drill", "loot_merge_contact_epsilon_m"]),
		0.02
	)
	var reach := (
		hand_drill_loot_collision_radius_m(amount_kg_a)
		+ hand_drill_loot_collision_radius_m(amount_kg_b)
		+ epsilon
	)
	return position_a.distance_to(position_b) <= reach


static func hand_drill_loot_despawn_s() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["hand_drill", "loot_despawn_s"]),
		600.0
	)


static func floating_chunks_enabled() -> bool:
	return GameBalance.industry_bool(
		PackedStringArray(["floating_chunks", "enabled"]),
		true
	)


static func floating_chunks_box_size_voxels() -> int:
	return GameBalance.industry_int(
		PackedStringArray(["floating_chunks", "box_size_voxels"]),
		30
	)


static func floating_chunks_min_removed_m3() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["floating_chunks", "min_removed_m3"]),
		0.08
	)


static func floating_chunks_cooldown_ms() -> int:
	return GameBalance.industry_int(
		PackedStringArray(["floating_chunks", "cooldown_ms"]),
		250
	)


static func floating_chunks_max_bodies() -> int:
	return GameBalance.industry_int(
		PackedStringArray(["floating_chunks", "max_bodies"]),
		24
	)


static func floating_chunks_despawn_s() -> float:
	return GameBalance.industry_float(
		PackedStringArray(["floating_chunks", "despawn_s"]),
		25.0
	)


static func floating_chunks_collision_layer() -> int:
	return GameBalance.industry_int(
		PackedStringArray(["floating_chunks", "collision_layer"]),
		2
	)


static func _capacity_map(key: String) -> Dictionary:
	var raw: Variant = GameBalance.industry().get(key, {})
	return raw if raw is Dictionary else {}
