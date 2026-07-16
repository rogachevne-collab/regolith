class_name MoonGeometry
extends RefCounted

## Shared moon experiment geometry — single source for scale/radius/bounds.
## Matches docs/specs/MOON-EXPERIMENT-V0.md and INDUSTRY-V1 voxel scale.

const DIAMETER_M := 1000.0
const SURFACE_RADIUS_M := DIAMETER_M * 0.5
## Same uniform node scale as main (Voxel Tools has no separate voxel_size).
const VOXEL_SCALE := 0.65
## Bounds margin over surface radius in local voxel units (spec ≈ 1.1).
const BOUNDS_MARGIN := 1.1
## Sky hold offset above the surface while SDF/collider streams in.
const SPAWN_SKY_OFFSET_M := 80.0
const GROUND_PROBE_DISTANCE_M := 250.0
const SPAWN_CLEARANCE_M := 1.05
## Gravity magnitude for Field / Area3D (PHYSICAL-LANGUAGE lunar PoC).
const GRAVITY_M_S2 := 1.62
## Area shell beyond surface so near-surface bodies stay inside override.
const GRAVITY_AREA_RADIUS_FACTOR := 1.35
## Keep short on M1 — long LodTerrain view shows half-baked distant scraps.
const DEFAULT_VIEW_DISTANCE_VOXELS := 140
const DIG_STREAM_DIR := "user://moon_experiment"
const WORLD_SAVE_PATH := "user://moon_experiment/world_save.json"


static func dig_stream_directory() -> String:
	return MoonTerrainParams.stream_directory()


static func world_save_path() -> String:
	return MoonTerrainParams.world_save_path()


static func radius_voxels() -> float:
	return SURFACE_RADIUS_M / VOXEL_SCALE


static func bounds_half_extent_voxels() -> int:
	return int(ceili(radius_voxels() * BOUNDS_MARGIN))


static func voxel_bounds_aabb() -> AABB:
	var half := float(bounds_half_extent_voxels())
	var extent := half * 2.0
	return AABB(Vector3(-half, -half, -half), Vector3(extent, extent, extent))


static func gravity_area_radius_m() -> float:
	return SURFACE_RADIUS_M * GRAVITY_AREA_RADIUS_FACTOR


static func surface_point(direction: Vector3) -> Vector3:
	var dir := direction
	if dir.length_squared() <= 0.000001:
		dir = Vector3.UP
	else:
		dir = dir.normalized()
	return dir * SURFACE_RADIUS_M


static func spawn_hold_point(direction: Vector3) -> Vector3:
	var dir := direction
	if dir.length_squared() <= 0.000001:
		dir = Vector3.UP
	else:
		dir = dir.normalized()
	return dir * (SURFACE_RADIUS_M + SPAWN_SKY_OFFSET_M)
