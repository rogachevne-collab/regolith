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

const START_OVERLAY_RADIUS_M := 200.0
const ICE_LATITUDE_ABS := 0.72


func material_id_at_world(world_pos: Vector3, spawn_world: Vector3 = Vector3.ZERO) -> String:
	var radius_m := MoonGeometry.SURFACE_RADIUS_M
	var radial := world_pos.length()
	if radial <= 0.001:
		return _Catalog.MAT_MARE_REGOLITH
	var dir := world_pos / radial
	var depth_m := maxf(radius_m - radial, 0.0)
	return material_id_at_dir_depth(dir, depth_m, spawn_world)


func material_id_at_dir_depth(
	dir: Vector3,
	depth_m: float,
	spawn_world: Vector3 = Vector3.ZERO
) -> String:
	var n := dir.normalized()
	if spawn_world.length() > 0.001:
		var overlay := _starting_overlay(n, depth_m, spawn_world.normalized())
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


func voxel_index_at_world(world_pos: Vector3, spawn_world: Vector3 = Vector3.ZERO) -> int:
	return _Catalog.voxel_index_of(material_id_at_world(world_pos, spawn_world))


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
		if _in_band(depth_m, _Catalog.MAT_PYROXENE) and _spot(dir, 101, 0.12):
			return _Catalog.MAT_PYROXENE
		if _in_band(depth_m, _Catalog.MAT_ILMENITE) and _spot(dir, 131, 0.10):
			return _Catalog.MAT_ILMENITE
	else:
		if _in_band(depth_m, _Catalog.MAT_ANORTHITE) and _spot(dir, 151, 0.11):
			return _Catalog.MAT_ANORTHITE
		if _in_band(depth_m, _Catalog.MAT_OLIVINE) and _spot(dir, 171, 0.09):
			return _Catalog.MAT_OLIVINE
	return ""


func _ice_at(dir: Vector3, depth_m: float) -> bool:
	if absf(dir.y) < ICE_LATITUDE_ABS:
		return false
	if not _in_band(depth_m, _Catalog.MAT_ICE_LENS):
		return false
	return _spot(dir, 191, 0.08)


func _starting_overlay(dir: Vector3, depth_m: float, spawn_dir: Vector3) -> String:
	var ang := acos(clampf(dir.dot(spawn_dir), -1.0, 1.0))
	var arc_m := ang * MoonGeometry.SURFACE_RADIUS_M
	if arc_m > START_OVERLAY_RADIUS_M:
		return ""
	## Guaranteed shallow anorthite + deeper ilmenite near spawn for first loop.
	if depth_m >= 3.0 and depth_m <= 11.0 and arc_m < 80.0:
		return _Catalog.MAT_ANORTHITE
	if depth_m >= 8.0 and depth_m <= 18.0 and arc_m < 120.0:
		return _Catalog.MAT_ILMENITE
	if depth_m >= 2.0 and depth_m <= 8.0 and arc_m < 60.0:
		return _Catalog.MAT_PYROXENE
	return ""


func _in_band(depth_m: float, material_id: String) -> bool:
	var band := _Catalog.depth_band(material_id)
	if band.is_empty():
		return false
	var start_m := float(band.get("start_m", 0.0))
	var thickness_m := float(band.get("thickness_m", 0.0))
	return depth_m >= start_m and depth_m <= start_m + thickness_m


func _spot(dir: Vector3, salt: int, threshold: float) -> bool:
	## Cell-quantized spots so neighbouring voxels share a lens.
	var cell := Vector3i(
		int(floor(dir.x * 48.0)),
		int(floor(dir.y * 48.0)),
		int(floor(dir.z * 48.0))
	)
	var u := _hash01(
		_Params.SEED + salt,
		float(cell.x) * 0.17 + float(cell.y) * 0.31 + float(cell.z) * 0.47
	)
	return u < threshold


func _hash01(seed_v: int, x: float) -> float:
	var n := sin(x * 12.9898 + float(seed_v) * 78.233) * 43758.5453
	return n - floor(n)
