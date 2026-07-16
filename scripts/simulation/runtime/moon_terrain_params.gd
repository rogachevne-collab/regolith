class_name MoonTerrainParams
extends RefCounted

const GENERATOR_VERSION := 9
const SEED := 0x4D004E

## Keep crust almost spherical — relief is craters, not tumors.
const MARIA_DEPTH_M := 5.0
const HIGHLAND_LIFT_M := 4.0
const MOUNTAIN_AMP_M := 0.0
const PLATEAU_AMP_M := 0.0

const CRATER_LARGE_AMP_M := 22.0
const CRATER_MED_AMP_M := 10.0
const CRATER_SMALL_AMP_M := 4.0

const MICRO_AMP_M := 0.0
const HEIGHT_CLAMP_M := 40.0


static func meters_to_voxels(meters: float) -> float:
	return meters / MoonGeometry.VOXEL_SCALE


static func stream_directory() -> String:
	return "%s/gen_v%d" % [MoonGeometry.DIG_STREAM_DIR, GENERATOR_VERSION]


static func stream_database_path() -> String:
	return "%s/moon.sqlite" % stream_directory()


static func world_save_path() -> String:
	return "%s/world_save.json" % stream_directory()
