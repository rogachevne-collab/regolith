class_name MoonTerrainParams
extends RefCounted

## Tunables for procedural lunar height field H(n) on the sphere.
## Heights are in world meters; convert with meters_to_voxels().
## Docs: Voxel Tools Generators → Planet (height-based sphere).

## Bump when relief formula changes — invalidates dig stream layout.
const GENERATOR_VERSION := 2

const SEED := 0x4D004E # "MOON"

## Continents / maria vs highlands.
const CONTINENT_AMP_M := 7.0
const CONTINENT_PERIOD_M := 180.0

## Ridged massifs (docs: ridged + negate → eroded look).
const MOUNTAIN_AMP_M := 16.0
const MOUNTAIN_PERIOD_M := 90.0

## Terraced shelves.
const PLATEAU_AMP_M := 6.0
const PLATEAU_PERIOD_M := 120.0
const PLATEAU_STEPS := 4.0

## Valley / rille cuts.
const CANYON_AMP_M := 10.0
const CANYON_PERIOD_M := 70.0

## Multi-scale craters (cellular distance bowls).
const CRATER_LARGE_AMP_M := 12.0
const CRATER_LARGE_PERIOD_M := 95.0
const CRATER_MED_AMP_M := 5.0
const CRATER_MED_PERIOD_M := 40.0
const CRATER_SMALL_AMP_M := 2.0
const CRATER_SMALL_PERIOD_M := 18.0

## Fine regolith.
const MICRO_AMP_M := 0.9
const MICRO_PERIOD_M := 8.0

## Soft clamp on |H| so spawn probes stay valid.
const HEIGHT_CLAMP_M := 36.0


static func meters_to_voxels(meters: float) -> float:
	return meters / MoonGeometry.VOXEL_SCALE


static func stream_directory() -> String:
	return "%s/gen_v%d" % [MoonGeometry.DIG_STREAM_DIR, GENERATOR_VERSION]


static func stream_database_path() -> String:
	return "%s/moon.sqlite" % stream_directory()


static func world_save_path() -> String:
	return "%s/world_save.json" % stream_directory()
