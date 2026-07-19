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
