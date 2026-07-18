class_name TerrainMaterialSource
extends RefCounted

## Converts removed voxel volume + material weights into item mass yields.
## Spec: docs/specs/TERRAIN-MATERIALS-V1.md § Добыча и yield.

const _Catalog := preload(
	"res://scripts/simulation/runtime/terrain_material_catalog.gd"
)
const EPSILON := 0.000001


func yield_for_removed_volume(
	removed_volume_m3: float,
	collectible_fraction: float = 1.0
) -> Array[Dictionary]:
	## Legacy single-material path: default mare regolith background.
	return yield_for_excavation(
		removed_volume_m3,
		{_Catalog.MAT_MARE_REGOLITH: 1.0},
		collectible_fraction
	)


func yield_for_excavation(
	removed_volume_m3: float,
	material_weights: Dictionary,
	fallback_collectible_fraction: float = -1.0
) -> Array[Dictionary]:
	if removed_volume_m3 <= EPSILON or material_weights.is_empty():
		return []
	var normalized := _normalize_weights(material_weights)
	if normalized.is_empty():
		return []

	var mass_by_item: Dictionary = {}
	for material_id: String in normalized.keys():
		var weight := float(normalized[material_id])
		if weight <= EPSILON:
			continue
		var density := _Catalog.density_kg_m3(material_id)
		var fraction := _Catalog.collectible_fraction(material_id)
		if fallback_collectible_fraction >= 0.0:
			fraction = clampf(fallback_collectible_fraction, 0.0, 1.0)
		var mass_kg := removed_volume_m3 * density * fraction * weight
		if mass_kg <= EPSILON:
			continue
		for row: Variant in _Catalog.yield_table(material_id):
			if not (row is Dictionary):
				continue
			var item_id := str(row.get("item_id", ""))
			var mass_fraction := float(row.get("mass_fraction", 0.0))
			if item_id.is_empty() or mass_fraction <= EPSILON:
				continue
			var add := mass_kg * mass_fraction
			mass_by_item[item_id] = float(mass_by_item.get(item_id, 0.0)) + add

	var result: Array[Dictionary] = []
	var item_ids: Array = mass_by_item.keys()
	item_ids.sort()
	for item_id: Variant in item_ids:
		var mass_kg := float(mass_by_item[item_id])
		if mass_kg <= EPSILON:
			continue
		result.append({
			"resource_id": str(item_id),
			"mass_kg": mass_kg,
		})
	return result


func amounts_from_yields(yields: Array[Dictionary]) -> Dictionary:
	## resource_id → amount in item units.
	var amounts: Dictionary = {}
	for entry: Dictionary in yields:
		var resource_id := str(entry.get("resource_id", ""))
		var mass_kg := float(entry.get("mass_kg", 0.0))
		if resource_id.is_empty() or mass_kg <= EPSILON:
			continue
		var unit_mass := ResourceCatalog.mass_per_unit_kg(resource_id)
		if unit_mass <= EPSILON:
			continue
		amounts[resource_id] = (
			float(amounts.get(resource_id, 0.0)) + mass_kg / unit_mass
		)
	return amounts


func dominant_resource_id(yields: Array[Dictionary]) -> String:
	var best_id := ""
	var best_mass := 0.0
	for entry: Dictionary in yields:
		var resource_id := str(entry.get("resource_id", ""))
		var mass_kg := float(entry.get("mass_kg", 0.0))
		if resource_id.is_empty() or mass_kg <= best_mass:
			continue
		best_mass = mass_kg
		best_id = resource_id
	return best_id


func _normalize_weights(material_weights: Dictionary) -> Dictionary:
	var total := 0.0
	var cleaned: Dictionary = {}
	for key: Variant in material_weights.keys():
		var material_id := str(key)
		if not _Catalog.has_material(material_id):
			continue
		var weight := float(material_weights[key])
		if weight <= EPSILON:
			continue
		cleaned[material_id] = weight
		total += weight
	if total <= EPSILON:
		return {}
	var normalized: Dictionary = {}
	for material_id: String in cleaned.keys():
		normalized[material_id] = float(cleaned[material_id]) / total
	return normalized
