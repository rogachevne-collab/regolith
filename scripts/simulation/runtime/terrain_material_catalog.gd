class_name TerrainMaterialCatalog
extends RefCounted

## Authoritative TerrainMaterialDef fixtures — docs/specs/TERRAIN-MATERIALS-V1.md.

const EPSILON := 0.000001

## Default share of excavated volume that stays on the ground as loose
## material, for anything without its own `spoil_fraction`.
const DEFAULT_SPOIL_FRACTION := 0.35

const MAT_MARE_REGOLITH := "mat_mare_regolith"
const MAT_HIGHLAND_REGOLITH := "mat_highland_regolith"
const MAT_ILMENITE := "mat_ilmenite"
const MAT_ANORTHITE := "mat_anorthite"
const MAT_OLIVINE := "mat_olivine"
const MAT_PYROXENE := "mat_pyroxene"
const MAT_ICE_LENS := "mat_ice_lens"

const ENTRIES: Dictionary = {
	MAT_MARE_REGOLITH: {
		"voxel_index": 0,
		"display_name": "Реголит морей",
		"visual_slot": 0,
		"biome_tags": ["mare"],
		"hardness": 0.45,
		"density_kg_m3": 1500.0,
		"collectible_fraction": 0.01,
		"spoil_fraction": 0.35,
		"drill_power_mul": 1.0,
		"yield_table": [
			{"item_id": "ore_mare_regolith", "mass_fraction": 1.0},
		],
	},
	MAT_HIGHLAND_REGOLITH: {
		"voxel_index": 1,
		"display_name": "Реголит высокогорий",
		"visual_slot": 1,
		"biome_tags": ["highland"],
		"hardness": 0.50,
		"density_kg_m3": 1450.0,
		"collectible_fraction": 0.01,
		"spoil_fraction": 0.35,
		"drill_power_mul": 1.0,
		"yield_table": [
			{"item_id": "ore_highland_regolith", "mass_fraction": 1.0},
		],
	},
	MAT_ILMENITE: {
		"voxel_index": 2,
		"display_name": "Ильменит",
		"visual_slot": 2,
		"biome_tags": ["mare"],
		"hardness": 0.85,
		"density_kg_m3": 2800.0,
		"collectible_fraction": 0.02,
		"spoil_fraction": 0.80,
		"drill_power_mul": 1.35,
		"yield_table": [
			{"item_id": "ore_ilmenite", "mass_fraction": 0.85},
			{"item_id": "ore_mare_regolith", "mass_fraction": 0.15},
		],
	},
	MAT_ANORTHITE: {
		"voxel_index": 3,
		"display_name": "Анортозит",
		"visual_slot": 3,
		"biome_tags": ["highland"],
		"hardness": 0.80,
		"density_kg_m3": 2700.0,
		"collectible_fraction": 0.02,
		"spoil_fraction": 0.80,
		"drill_power_mul": 1.3,
		"yield_table": [
			{"item_id": "ore_anorthite", "mass_fraction": 0.85},
			{"item_id": "ore_highland_regolith", "mass_fraction": 0.15},
		],
	},
	MAT_OLIVINE: {
		"voxel_index": 4,
		"display_name": "Оливин",
		"visual_slot": 4,
		"biome_tags": ["highland"],
		"hardness": 0.75,
		"density_kg_m3": 2600.0,
		"collectible_fraction": 0.018,
		"spoil_fraction": 0.80,
		"drill_power_mul": 1.2,
		"yield_table": [
			{"item_id": "ore_olivine", "mass_fraction": 0.80},
			{"item_id": "ore_highland_regolith", "mass_fraction": 0.20},
		],
	},
	MAT_PYROXENE: {
		"voxel_index": 5,
		"display_name": "Пироксен",
		"visual_slot": 5,
		"biome_tags": ["mare"],
		"hardness": 0.70,
		"density_kg_m3": 2500.0,
		"collectible_fraction": 0.018,
		"spoil_fraction": 0.80,
		"drill_power_mul": 1.15,
		"yield_table": [
			{"item_id": "ore_pyroxene", "mass_fraction": 0.80},
			{"item_id": "ore_mare_regolith", "mass_fraction": 0.20},
		],
	},
	MAT_ICE_LENS: {
		"voxel_index": 6,
		"display_name": "Ледяная линза",
		"visual_slot": 6,
		"biome_tags": ["cold_pocket"],
		"hardness": 0.35,
		"density_kg_m3": 950.0,
		"collectible_fraction": 0.04,
		"spoil_fraction": 1.0,
		"drill_power_mul": 0.85,
		"yield_table": [
			{"item_id": "ore_ice", "mass_fraction": 0.90},
			{"item_id": "ore_mare_regolith", "mass_fraction": 0.10},
		],
	},
}

## Depth bands (metres below local surface) — SE-style Start/Depth.
const DEPTH_BANDS: Dictionary = {
	MAT_PYROXENE: {"start_m": 2.0, "thickness_m": 6.0},
	MAT_ILMENITE: {"start_m": 8.0, "thickness_m": 10.0},
	MAT_ANORTHITE: {"start_m": 3.0, "thickness_m": 8.0},
	MAT_OLIVINE: {"start_m": 10.0, "thickness_m": 8.0},
	MAT_ICE_LENS: {"start_m": 1.0, "thickness_m": 5.0},
}


static func has_material(material_id: String) -> bool:
	return ENTRIES.has(material_id)


static func material_ids() -> PackedStringArray:
	var ids: Array = ENTRIES.keys()
	ids.sort()
	var result := PackedStringArray()
	for material_id: Variant in ids:
		result.append(str(material_id))
	return result


static func entry(material_id: String) -> Dictionary:
	var raw: Variant = ENTRIES.get(material_id, {})
	return raw if raw is Dictionary else {}


static func id_for_voxel_index(voxel_index: int) -> String:
	for material_id: String in material_ids():
		if voxel_index_of(material_id) == voxel_index:
			return material_id
	return MAT_MARE_REGOLITH


static func voxel_index_of(material_id: String) -> int:
	return int(entry(material_id).get("voxel_index", 0))


static func density_kg_m3(material_id: String) -> float:
	return float(entry(material_id).get("density_kg_m3", 1500.0))


static func collectible_fraction(material_id: String) -> float:
	var owned: Variant = entry(material_id).get("collectible_fraction", null)
	if owned == null:
		return IndustryArchetypeProfile.terrain_collectible_fraction()
	return clampf(float(owned), 0.0, 1.0)


## Share of excavated volume that stays put as loose material instead of being
## carried off. Rock leaves a thin apron; an ore or ice lens is soft enough that
## nearly all of it stays and flows — which is what makes a lens worth finding
## and worth loading with a bucket.
##
## This multiplies the volume a *cut* actually removed, never a lens as a whole.
## A lens is tens of metres across intersected with a depth band, so it holds
## thousands of cubic metres, and one granular region is a 16 m box. Converting
## a lens ahead of time cannot fit and must never be attempted: material becomes
## loose only at the working face, only as fast as it is dug.
static func spoil_fraction(material_id: String) -> float:
	var owned: Variant = entry(material_id).get("spoil_fraction", null)
	if owned == null:
		return DEFAULT_SPOIL_FRACTION
	return clampf(float(owned), 0.0, 1.0)


static func hardness(material_id: String) -> float:
	return float(entry(material_id).get("hardness", 0.5))


static func drill_power_mul(material_id: String) -> float:
	return maxf(float(entry(material_id).get("drill_power_mul", 1.0)), 0.01)


static func yield_table(material_id: String) -> Array:
	var raw: Variant = entry(material_id).get("yield_table", [])
	return raw if raw is Array else []


static func display_name(material_id: String) -> String:
	return str(entry(material_id).get("display_name", material_id))


static func visual_slot(material_id: String) -> int:
	return int(entry(material_id).get("visual_slot", 0))


static func depth_band(material_id: String) -> Dictionary:
	var raw: Variant = DEPTH_BANDS.get(material_id, {})
	return raw if raw is Dictionary else {}
