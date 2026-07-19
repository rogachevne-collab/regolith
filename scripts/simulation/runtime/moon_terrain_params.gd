class_name MoonTerrainParams
extends RefCounted

## 26: Ø19 km geometry experiment (MoonGeometry.DIAMETER_M) — fresh dig/save
## catalog; prior caches assume Ø1 km bounds/stream paths.
## 25: play switched from panorama NODE_SDF_SPHERE_HEIGHTMAP to the analytic
## native SDF (MoonNativeSdfGenerator) — same H(n), but exact at poles/seam,
## so cached digs from the panorama crust don't line up anymore.
## 27: area-scaled crater density + tiny class (native sampler) — relief
## changed everywhere, prior digs don't line up.
## 28: crater depth ∝ diameter (lunar depth/diameter ratios), relief clamp
## 240 m — meter-deep km-wide bowls read as flat noise on Ø19 km.
## 29: LOD detail fade removed (ring-boundary gap lines) — cached v28 blocks
## in SQLite carry faded far-LOD data and must not mix with unfaded.
## 30: material lens cells scale with surface radius (arc ≈ 70 m) — Ø19 km
## no longer stretches ore patches to ~1.4 km.
const GENERATOR_VERSION := 32
const SEED := 0x4D004E
## Optional isolated stream for test scenes (no gen_v bump).
static var _test_stream_label := ""


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


static func set_test_stream_label(label: String) -> void:
	_test_stream_label = label.strip_edges()


static func clear_test_stream_label() -> void:
	_test_stream_label = ""


static func stream_directory() -> String:
	if not _test_stream_label.is_empty():
		return "%s/%s" % [MoonGeometry.DIG_STREAM_DIR, _test_stream_label]
	return "%s/gen_v%d" % [MoonGeometry.DIG_STREAM_DIR, GENERATOR_VERSION]


static func stream_database_path() -> String:
	return "%s/moon.sqlite" % stream_directory()


static func world_save_path() -> String:
	return "%s/world_save.json" % stream_directory()
