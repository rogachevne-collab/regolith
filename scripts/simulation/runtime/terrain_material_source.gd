class_name TerrainMaterialSource
extends RefCounted

const REGOLITH_RESOURCE_ID := &"raw_regolith"
const REGOLITH_DENSITY_KG_PER_M3 := 1500.0
const EPSILON := 0.000001


func yield_for_removed_volume(
	removed_volume_m3: float,
	collectible_fraction: float = 1.0
) -> Array[Dictionary]:
	if removed_volume_m3 <= EPSILON:
		return []
	var fraction := clampf(collectible_fraction, 0.0, 1.0)
	if fraction <= EPSILON:
		return []
	return [{
		"resource_id": REGOLITH_RESOURCE_ID,
		"mass_kg": (
			removed_volume_m3
			* REGOLITH_DENSITY_KG_PER_M3
			* fraction
		),
	}]

