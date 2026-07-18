class_name MoonTerrainParams
extends RefCounted

const GENERATOR_VERSION := 24
const SEED := 0x4D004E


static func bake_is_present() -> bool:
	## Play uses live VoxelGeneratorGraph planet (no crust bake required).
	## Terrain material yield uses MoonMaterialField (TERRAIN-MATERIALS-V1);
	## CHANNEL_INDICES visual zones are a follow-up on top of this seed bump.
	return true


## Mare / highland dichotomy — the defining large-scale lunar feature.
const MARIA_DEPTH_M := 18.0
const HIGHLAND_LIFT_M := 6.5
## Subtle highland meso-roughness (craters carry most of the texture).
const HIGHLAND_ROUGH_AMP_M := 1.15
## Legacy — mountain ridges removed; kept at zero.
const MOUNTAIN_AMP_M := 0.0
const PLATEAU_AMP_M := 0.0

const CRATER_LARGE_AMP_M := 18.0
const CRATER_MED_AMP_M := 9.0
const CRATER_SMALL_AMP_M := 3.5
## Basin-scale impacts with flat floors and central peaks.
## Slightly shallower than before → less steep walls, fewer Transvoxel facets.
const CRATER_HUGE_AMP_M := 30.0

## Resolvable surface texture (period >= ~4 m) so the moon is not a bland
## "soap" surface. Sub-voxel grain stays in the material, not the geometry.
## Mid band (~13 m) breaks up monotony and masks cubic-upsample ringing on maria.
const SURFACE_TEXTURE_M := 0.9
const PLAINS_TEXTURE_M := 0.3
## Fine but still resolvable crunch (~4.5 m period).
const MICRO_AMP_M := 0.3
const HEIGHT_CLAMP_M := 45.0


static func meters_to_voxels(meters: float) -> float:
	return meters / MoonGeometry.VOXEL_SCALE


static func stream_directory() -> String:
	return "%s/gen_v%d" % [MoonGeometry.DIG_STREAM_DIR, GENERATOR_VERSION]


static func stream_database_path() -> String:
	return "%s/moon.sqlite" % stream_directory()


static func world_save_path() -> String:
	return "%s/world_save.json" % stream_directory()
