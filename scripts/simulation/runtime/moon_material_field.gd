class_name MoonMaterialField
extends RefCounted

## Deterministic material index field for lunar voxels.
## Same function drives yield sampling and (later) CHANNEL_INDICES writes.
## Spec: docs/specs/TERRAIN-MATERIALS-V1.md § Распределение.

const _Catalog := preload(
	"res://scripts/simulation/runtime/terrain_material_catalog.gd"
)
const _Params := preload(
	"res://scripts/simulation/runtime/moon_terrain_params.gd"
)

## Search radius for guaranteed starter lenses (not a solid ore disk).
const START_OVERLAY_RADIUS_M := 200.0
const ICE_LATITUDE_ABS := 0.72
## Target hosting-cell arc on the surface (TERRAIN-MATERIALS-V1: 60–80 m).
## Direction-space scale = R / arc so Ø1 km and Ø19 km keep the same meters.
const LENS_CELL_ARC_M := 70.0
## Soft blob radius inside a hosting cell (cell units).
const LENS_RADIUS_MIN := 0.28
const LENS_RADIUS_MAX := 0.48

## Where the player landed, in world space. The starting lenses are placed
## relative to it, so every consumer — hand drill yield, stationary drill, map
## overlay — has to agree on one value or the map marks ore where digging finds
## none. Held here rather than passed down each call chain because it is a
## property of the world, and the per-call argument was in practice never
## supplied: `WorldCommandGateway.set_hand_drill_spawn_world` had no callers, so
## the dig path resolved the starting lenses as nonexistent while the map drew
## them around wherever the player happened to be standing.
##
## An explicit non-zero argument still wins, for tests and for any caller that
## genuinely means a different origin.
static var _spawn_world := Vector3.ZERO


static func set_spawn_world(world_pos: Vector3) -> void:
	_spawn_world = world_pos


static func spawn_world() -> Vector3:
	return _spawn_world


func lens_cell_scale() -> float:
	return MoonGeometry.active_surface_radius_m() / LENS_CELL_ARC_M


func material_id_at_world(world_pos: Vector3, spawn_world_override: Vector3 = Vector3.ZERO) -> String:
	# Note: depth comes from the fixed constant while `lens_cell_scale` uses
	# `active_surface_radius_m()`. In a scene that calls `set_test_diameter`
	# the two disagree — depth bands and lens geometry then describe different
	# planets. Harmless on the real moon; fix before trusting a shrunk one.
	var radius_m := MoonGeometry.SURFACE_RADIUS_M
	var radial := world_pos.length()
	if radial <= 0.001:
		return _Catalog.MAT_MARE_REGOLITH
	var dir := world_pos / radial
	var depth_m := maxf(radius_m - radial, 0.0)
	return material_id_at_dir_depth(dir, depth_m, spawn_world_override)


func material_id_at_dir_depth(
	dir: Vector3,
	depth_m: float,
	spawn_world_override: Vector3 = Vector3.ZERO
) -> String:
	var n := dir.normalized()
	var origin := spawn_world_override if spawn_world_override.length() > 0.001 else _spawn_world
	if origin.length() > 0.001:
		var overlay := _starting_overlay(n, depth_m, origin.normalized())
		if not overlay.is_empty():
			return overlay

	var biome := _biome_at(n)
	var lens := _deposit_at(n, depth_m, biome)
	if not lens.is_empty():
		return lens
	return (
		_Catalog.MAT_MARE_REGOLITH
		if biome == "mare"
		else _Catalog.MAT_HIGHLAND_REGOLITH
	)


func voxel_index_at_world(world_pos: Vector3, spawn_world_override: Vector3 = Vector3.ZERO) -> int:
	return _Catalog.voxel_index_of(material_id_at_world(world_pos, spawn_world_override))


func _biome_at(dir: Vector3) -> String:
	## Low-frequency mare basins — matches toy-moon dichotomy intent.
	var n := dir.normalized()
	var field := _hash01(
		_Params.SEED + 11,
		n.x * 3.1 + n.y * 1.7 + n.z * 2.3
	)
	## Prefer mare on near-side-ish +X hemisphere for readable play.
	var side_bias := clampf(n.x * 0.35 + 0.5, 0.0, 1.0)
	var mare_score := field * 0.65 + side_bias * 0.35
	return "mare" if mare_score > 0.48 else "highland"


func _deposit_at(dir: Vector3, depth_m: float, biome: String) -> String:
	if _ice_at(dir, depth_m):
		return _Catalog.MAT_ICE_LENS

	if biome == "mare":
		## Shallow pyroxene over deeper ilmenite — sparse regional lenses.
		if _in_band(depth_m, _Catalog.MAT_PYROXENE) and _lens_blob(dir, 101, 0.045):
			return _Catalog.MAT_PYROXENE
		if _in_band(depth_m, _Catalog.MAT_ILMENITE) and _lens_blob(dir, 131, 0.032):
			return _Catalog.MAT_ILMENITE
	else:
		if _in_band(depth_m, _Catalog.MAT_ANORTHITE) and _lens_blob(dir, 151, 0.040):
			return _Catalog.MAT_ANORTHITE
		if _in_band(depth_m, _Catalog.MAT_OLIVINE) and _lens_blob(dir, 171, 0.028):
			return _Catalog.MAT_OLIVINE
	return ""


func _ice_at(dir: Vector3, depth_m: float) -> bool:
	if absf(dir.y) < ICE_LATITUDE_ABS:
		return false
	if not _in_band(depth_m, _Catalog.MAT_ICE_LENS):
		return false
	return _lens_blob(dir, 191, 0.055)


func _starting_overlay(dir: Vector3, depth_m: float, spawn_dir: Vector3) -> String:
	## Discrete guaranteed lenses near spawn — not a solid ore flood disk.
	var arc_m := (
		acos(clampf(dir.dot(spawn_dir), -1.0, 1.0)) * MoonGeometry.SURFACE_RADIUS_M
	)
	if arc_m > START_OVERLAY_RADIUS_M:
		return ""

	## ~45 m NE — shallow anorthite pocket for early Al/Si loop.
	if (
		_near_surface_point(dir, spawn_dir, 32.0, 28.0, 26.0)
		and _in_band(depth_m, _Catalog.MAT_ANORTHITE)
	):
		return _Catalog.MAT_ANORTHITE
	## ~95 m NW — deeper ilmenite for Fe/Ti / O₂ path.
	if (
		_near_surface_point(dir, spawn_dir, -70.0, 55.0, 32.0)
		and _in_band(depth_m, _Catalog.MAT_ILMENITE)
	):
		return _Catalog.MAT_ILMENITE
	## ~55 m S — shallow pyroxene.
	if (
		_near_surface_point(dir, spawn_dir, 8.0, -52.0, 22.0)
		and _in_band(depth_m, _Catalog.MAT_PYROXENE)
	):
		return _Catalog.MAT_PYROXENE
	return ""


func _near_surface_point(
	dir: Vector3,
	spawn_dir: Vector3,
	east_m: float,
	north_m: float,
	radius_m: float
) -> bool:
	var center := _offset_dir(spawn_dir, east_m, north_m)
	var ang := acos(clampf(dir.dot(center), -1.0, 1.0))
	return ang * MoonGeometry.SURFACE_RADIUS_M <= radius_m


func _offset_dir(spawn_dir: Vector3, east_m: float, north_m: float) -> Vector3:
	var up := spawn_dir.normalized()
	var east := up.cross(Vector3.UP)
	if east.length_squared() < 0.0001:
		east = up.cross(Vector3.RIGHT)
	east = east.normalized()
	var north := east.cross(up).normalized()
	var tangent := east * east_m + north * north_m
	return (up * MoonGeometry.SURFACE_RADIUS_M + tangent).normalized()


func _in_band(depth_m: float, material_id: String) -> bool:
	var band := _Catalog.depth_band(material_id)
	if band.is_empty():
		return false
	var start_m := float(band.get("start_m", 0.0))
	var thickness_m := float(band.get("thickness_m", 0.0))
	return depth_m >= start_m and depth_m <= start_m + thickness_m


func _lens_blob(dir: Vector3, salt: int, coverage: float) -> bool:
	## Rare hosting cells + soft radial blob → readable ore patches, not grit.
	var n := dir.normalized()
	var scaled := n * lens_cell_scale()
	var cell := Vector3i(
		int(floor(scaled.x)),
		int(floor(scaled.y)),
		int(floor(scaled.z))
	)
	var cell_key := (
		float(cell.x) * 0.17 + float(cell.y) * 0.31 + float(cell.z) * 0.47
	)
	var host := _hash01(_Params.SEED + salt, cell_key)
	if host >= coverage:
		return false

	var local := scaled - Vector3(cell)
	var jx := 0.22 + 0.56 * _hash01(_Params.SEED + salt + 3, cell_key + 1.1)
	var jy := 0.22 + 0.56 * _hash01(_Params.SEED + salt + 5, cell_key + 2.3)
	var jz := 0.22 + 0.56 * _hash01(_Params.SEED + salt + 7, cell_key + 3.7)
	var radius := lerpf(
		LENS_RADIUS_MIN,
		LENS_RADIUS_MAX,
		_hash01(_Params.SEED + salt + 9, cell_key + 4.9)
	)
	return local.distance_to(Vector3(jx, jy, jz)) <= radius


func _hash01(seed_v: int, x: float) -> float:
	var n := sin(x * 12.9898 + float(seed_v) * 78.233) * 43758.5453
	return n - floor(n)
