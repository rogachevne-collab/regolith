class_name MoonGeometry
extends RefCounted

## Shared moon experiment geometry — single source for scale/radius/bounds.
## Matches docs/specs/MOON-EXPERIMENT-V0.md and INDUSTRY-V1 voxel scale.

const DIAMETER_M := 1000.0
const SURFACE_RADIUS_M := DIAMETER_M * 0.5
## Same uniform node scale as main (Voxel Tools has no separate voxel_size).
const VOXEL_SCALE := 0.65
## Bounds margin over surface radius in local voxel units.
## Must stay above coarsest LodTerrain block (16 * 2^(lod_count-1)).
const BOUNDS_MARGIN := 1.25
## Sky hold offset above the surface while SDF/collider streams in.
const SPAWN_SKY_OFFSET_M := 80.0
const GROUND_PROBE_DISTANCE_M := 250.0
const SPAWN_CLEARANCE_M := 1.05
## Gravity magnitude for Field / Area3D (PHYSICAL-LANGUAGE lunar PoC).
const GRAVITY_M_S2 := 1.62
## Area shell beyond surface so near-surface bodies stay inside override.
const GRAVITY_AREA_RADIUS_FACTOR := 1.35
## Streaming budget for VoxelLodTerrain / VoxelViewer (voxels, local).
## World metres ≈ value * VOXEL_SCALE. Fixed 50k on foot over-requests mid
## LODs → half-baked cliff scraps. Floor covers the Ø1 km shell from any
## surface point; ceiling grows with altitude (bootstrap).
## Do NOT push Camera.far to orbital scales — Godot's light culler breaks
## (create_frustum_points) when near/far ratio is extreme.
const MIN_VIEW_DISTANCE_VOXELS := 2_048
const MAX_VIEW_DISTANCE_VOXELS := 50_000
## Initial / editor fallback (= surface floor).
const DEFAULT_VIEW_DISTANCE_VOXELS := MIN_VIEW_DISTANCE_VOXELS
## Extra radius so the far limb stays inside the load sphere.
const VIEW_DISTANCE_RADIUS_MARGIN := 1.15
## Coarsest mesh block = 16 * 2^(lod_count-1). For Ø1 km (bounds ~±960)
## lod_count 8 → block 2048 > bounds → cubic cuts / floating scraps.
## 6 → block 512, fits; enough for altitude before the impostor.
const DEFAULT_LOD_COUNT := 6
const DEFAULT_LOD_DISTANCE := 56.0
## Beyond this distance from planet center, show a camera-relative impostor
## (real mesh would be clipped by Camera.far ≈ 20 km).
const FAR_IMPOSTOR_START_M := 16_000.0
## Place the impostor this far in front of the camera (must be < Camera.far).
const FAR_IMPOSTOR_VISUAL_DIST_M := 8_000.0
const DIG_STREAM_DIR := "user://moon_experiment"
const WORLD_SAVE_PATH := "user://moon_experiment/world_save.json"


static func view_distance_voxels_for_camera_distance(distance_from_center_m: float) -> int:
	## Farthest crust point from the camera ≈ |cam| + R; convert to voxels.
	var reach_m: float = (
		maxf(distance_from_center_m, 0.0) + SURFACE_RADIUS_M
	) * VIEW_DISTANCE_RADIUS_MARGIN
	var needed := int(ceili(reach_m / VOXEL_SCALE))
	return clampi(needed, MIN_VIEW_DISTANCE_VOXELS, MAX_VIEW_DISTANCE_VOXELS)


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
