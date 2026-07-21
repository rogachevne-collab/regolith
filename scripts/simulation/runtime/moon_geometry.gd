class_name MoonGeometry
extends RefCounted

## Shared moon experiment geometry — single source for scale/radius/bounds.
## Matches docs/specs/MOON-EXPERIMENT-V0.md and INDUSTRY-V1 voxel scale.

const DIAMETER_M := 19000.0
const SURFACE_RADIUS_M := DIAMETER_M * 0.5
## Optional test-scene override (see test_moon_5km_flat_bootstrap.gd).
static var _test_diameter_m := 0.0
## Same uniform node scale as main (Voxel Tools has no separate voxel_size).
## 1.0 = native VT unit; avoids the old 0.65 scale tax (~3.6× voxels/m³).
const VOXEL_SCALE := 1.0
## Bounds margin over surface radius in local voxel units.
## Must stay above coarsest LodTerrain block
## (mesh_block_size * 2^(lod_count-1)).
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
## World metres ≈ value * VOXEL_SCALE.
##
## Surface floor = spawn-focus (512). On Ø19 km, raw `|cam|+R` ≈ 22k voxels on
## foot — the streamer never finishes LOD0 under the viewer (only coarser LODs
## win the queue). `collision_lod_count>1` then masks the hole with LOD1/2
## colliders; dig fails because edits need LOD0. Ceiling grows with altitude
## so the far limb LODs instead of unloading.
## Do NOT push Camera.far to orbital scales — Godot's light culler breaks
## (create_frustum_points) when near/far ratio is extreme.
const MIN_VIEW_DISTANCE_VOXELS := 512
const MAX_VIEW_DISTANCE_VOXELS := 80_000
## Initial / editor fallback (= surface floor).
const DEFAULT_VIEW_DISTANCE_VOXELS := MIN_VIEW_DISTANCE_VOXELS
## Extra radius so the far limb stays inside the load sphere.
const VIEW_DISTANCE_RADIUS_MARGIN := 1.15
## Altitude (m above crust) at which view_distance reaches the full far-limb
## sphere. Below this, blend toward the surface floor so near-field LOD0 wins.
const VIEW_DISTANCE_ALTITUDE_BLEND_M := 2_000.0
## LOD0 mesh chunk size (VT: 16 or 32). VT default 16; 32 = fewer bodies.
const DEFAULT_MESH_BLOCK_SIZE := 16
## Coarsest mesh block = mesh_block_size * 2^(lod_count-1). For Ø19 km at
## scale 1.0 (bounds ~±11875): mesh 16 + lod_count 10 → block 8192 fits;
## mesh 32 + lod_count 10 → 16384 > bounds → cubic cuts / broken LOD0.
const DEFAULT_LOD_COUNT := 10
## How far LOD0 extends (and, on LEGACY_OCTREE, the step for coarser rings).
## VT default is 48. We had 88 for denser near crust, but once the surface
## view_distance fix lets LOD0 actually finish, 88³ is a heavy shell of
## full-res mesh+collider underfoot — dig only needs reach (~6 m). Stay on
## the VT default; raise only with a measured FPS budget.
const DEFAULT_LOD_DISTANCE := 48.0
## Beyond this distance from planet center, show a camera-relative impostor.
## Parked far out for Ø19 km: billboard was baked for the Ø1 km moon and
## would lie at this scale. Stay below ~5–6 km altitude until scaled-space.
const FAR_IMPOSTOR_START_M := 500_000.0
## Place the impostor this far in front of the camera (must be < Camera.far).
const FAR_IMPOSTOR_VISUAL_DIST_M := 8_000.0
const DIG_STREAM_DIR := "user://moon_experiment"
const WORLD_SAVE_PATH := "user://moon_experiment/world_save.json"


static func set_test_diameter(diameter_m: float) -> void:
	_test_diameter_m = maxf(diameter_m, 0.0)


static func clear_test_diameter() -> void:
	_test_diameter_m = 0.0


static func active_diameter_m() -> float:
	return _test_diameter_m if _test_diameter_m > 0.0 else DIAMETER_M


static func active_surface_radius_m() -> float:
	return active_diameter_m() * 0.5


static func boulder_density_scale_for_decor() -> float:
	## Density is per terrain chunk (same LOD0 mesh size at any diameter).
	## Slight cut vs the Ø1 km library — perf, still visible on foot.
	return 0.65


## Legacy: old bootstrap multiplied biome UV by R_ref/R. Shader now samples
## meter-periodic noise on dir*R; keep helper at 1.0 so callers stay harmless.
const TERRAIN_SHADER_REFERENCE_RADIUS_M := 500.0


static func terrain_shader_uv_scale() -> float:
	return 1.0


static func view_distance_voxels_for_camera_distance(distance_from_center_m: float) -> int:
	var radius_m := active_surface_radius_m()
	var cam_m := maxf(distance_from_center_m, 0.0)
	var altitude_m := maxf(cam_m - radius_m, 0.0)
	## Surface: modest near-field shell (same order as the old Ø1 km floor).
	## Climb: blend toward the far-limb sphere `|cam|+R` so distant crust LODs
	## instead of popping into cubic scraps.
	var surface_reach_m := float(MIN_VIEW_DISTANCE_VOXELS) * VOXEL_SCALE
	var far_limb_reach_m := (cam_m + radius_m) * VIEW_DISTANCE_RADIUS_MARGIN
	var blend := clampf(
		altitude_m / VIEW_DISTANCE_ALTITUDE_BLEND_M,
		0.0,
		1.0
	)
	var reach_m := lerpf(surface_reach_m, far_limb_reach_m, blend)
	var needed := int(ceili(reach_m / VOXEL_SCALE))
	return clampi(needed, MIN_VIEW_DISTANCE_VOXELS, MAX_VIEW_DISTANCE_VOXELS)


static func dig_stream_directory() -> String:
	return MoonTerrainParams.stream_directory()


static func world_save_path() -> String:
	return MoonTerrainParams.world_save_path()


static func granular_save_path() -> String:
	return MoonTerrainParams.granular_save_path()


static func radius_voxels() -> float:
	return active_surface_radius_m() / VOXEL_SCALE


static func bounds_half_extent_voxels() -> int:
	return int(ceili(radius_voxels() * BOUNDS_MARGIN))


static func voxel_bounds_aabb() -> AABB:
	var half := float(bounds_half_extent_voxels())
	var extent := half * 2.0
	return AABB(Vector3(-half, -half, -half), Vector3(extent, extent, extent))


static func gravity_area_radius_m() -> float:
	return active_surface_radius_m() * GRAVITY_AREA_RADIUS_FACTOR


static func surface_point(direction: Vector3) -> Vector3:
	var dir := direction
	if dir.length_squared() <= 0.000001:
		dir = Vector3.UP
	else:
		dir = dir.normalized()
	return dir * active_surface_radius_m()


static func spawn_hold_point(direction: Vector3) -> Vector3:
	var dir := direction
	if dir.length_squared() <= 0.000001:
		dir = Vector3.UP
	else:
		dir = dir.normalized()
	return dir * (active_surface_radius_m() + SPAWN_SKY_OFFSET_M)
