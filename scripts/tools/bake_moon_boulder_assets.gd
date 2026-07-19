extends SceneTree

## One-shot asset bake for moon boulder VoxelInstancer resources.
## Run: ./run.sh --headless --script res://scripts/tools/bake_moon_boulder_assets.gd

const _MeshFactory := preload("res://scripts/props/lunar_boulder_mesh_factory.gd")

const LIBRARY_PATH := "res://resources/moon_boulder_instance_library.tres"

## Stable library IDs — do not renumber after release (SQLite persistence).
const ITEM_DEFS: Array[Dictionary] = [
	{
		"id": 0, "name": "pebble_a", "mesh_kind": "small", "mesh_profile": 0,
		"tint": 0, "lod_index": 0,
		"density": 0.012, "min_slope": 4.0, "max_slope": 28.0,
		"offset": -0.10, "min_scale": 0.50, "max_scale": 0.78, "noise_seed": 404,
	},
	{
		"id": 1, "name": "pebble_b", "mesh_kind": "small", "mesh_profile": 1,
		"tint": 1, "lod_index": 0,
		"density": 0.010, "min_slope": 4.0, "max_slope": 28.0,
		"offset": -0.11, "min_scale": 0.55, "max_scale": 0.82, "noise_seed": 511,
	},
	{
		"id": 2, "name": "pebble_c", "mesh_kind": "small", "mesh_profile": 2,
		"tint": 2, "lod_index": 1,
		"density": 0.009, "min_slope": 4.0, "max_slope": 26.0,
		"offset": -0.12, "min_scale": 0.48, "max_scale": 0.74, "noise_seed": 618,
	},
	{
		"id": 3, "name": "rock_a", "mesh_kind": "small", "mesh_profile": 0,
		"tint": 1, "lod_index": 1,
		"density": 0.006, "min_slope": 3.0, "max_slope": 26.0,
		"offset": -0.13, "min_scale": 0.72, "max_scale": 1.05, "noise_seed": 722,
	},
	{
		"id": 4, "name": "rock_b", "mesh_kind": "small", "mesh_profile": 1,
		"tint": 0, "lod_index": 1,
		"density": 0.005, "min_slope": 3.0, "max_slope": 24.0,
		"offset": -0.14, "min_scale": 0.78, "max_scale": 1.12, "noise_seed": 833,
	},
	{
		"id": 5, "name": "boulder", "mesh_kind": "large", "mesh_profile": 0,
		"tint": 2, "lod_index": 1,
		"density": 0.0018, "min_slope": 2.0, "max_slope": 22.0,
		"offset": -0.16, "min_scale": 0.90, "max_scale": 1.45, "noise_seed": 504,
		"snap_sdf": true,
	},
	{
		"id": 6, "name": "boulder_flat", "mesh_kind": "large", "mesh_profile": 1,
		"tint": 0, "lod_index": 1,
		"density": 0.0012, "min_slope": 2.0, "max_slope": 20.0,
		"offset": -0.17, "min_scale": 1.0, "max_scale": 1.65, "noise_seed": 591,
		"snap_sdf": true,
	},
]


func _init() -> void:
	var err := _bake_meshes()
	if err != OK:
		push_error("bake_moon_boulder_assets: mesh bake failed err=%d" % err)
		quit(1)
		return
	err = _bake_library()
	if err != OK:
		push_error("bake_moon_boulder_assets: library bake failed err=%d" % err)
		quit(1)
		return
	print("bake_moon_boulder_assets: wrote library with %d items -> %s" % [
		ITEM_DEFS.size(), LIBRARY_PATH
	])
	quit(0)


func _bake_meshes() -> Error:
	for i in _MeshFactory.SMALL_PROFILES.size():
		var mesh := _MeshFactory.build_small_mesh(i)
		var path := "res://resources/props/lunar_boulder_mesh_small_%d.tres" % i
		var err := ResourceSaver.save(mesh, path)
		if err != OK:
			return err
	for i in _MeshFactory.LARGE_PROFILES.size():
		var mesh := _MeshFactory.build_large_mesh(i)
		var path := "res://resources/props/lunar_boulder_mesh_large_%d.tres" % i
		var err := ResourceSaver.save(mesh, path)
		if err != OK:
			return err
	## Legacy single-mesh paths for any stale refs.
	ResourceSaver.save(_MeshFactory.build_small_mesh(0), "res://resources/props/lunar_boulder_mesh_small.tres")
	ResourceSaver.save(_MeshFactory.build_large_mesh(0), "res://resources/props/lunar_boulder_mesh_large.tres")
	return OK


func _bake_library() -> Error:
	var lib := VoxelInstanceLibrary.new()
	for def: Dictionary in ITEM_DEFS:
		var mesh_kind: String = def.mesh_kind
		var profile: int = def.mesh_profile
		var mesh_path := (
			"res://resources/props/lunar_boulder_mesh_%s_%d.tres"
			% [mesh_kind, profile]
		)
		var mesh := load(mesh_path) as Mesh
		var mat := _MeshFactory.material(def.tint)
		var item := _make_item(
			def.name,
			mesh,
			mat,
			def.lod_index,
			_make_generator(def)
		)
		if def.get("snap_sdf", false):
			item.generator.snap_to_generator_sdf_enabled = true
			item.generator.snap_to_generator_sdf_search_distance = 1.4
		lib.add_item(def.id, item)
	return ResourceSaver.save(lib, LIBRARY_PATH)


func _make_item(
	item_name: String,
	mesh: Mesh,
	mat: Material,
	lod_index: int,
	generator: VoxelInstanceGenerator
) -> VoxelInstanceLibraryMultiMeshItem:
	var item := VoxelInstanceLibraryMultiMeshItem.new()
	item.name = item_name
	item.persistent = true
	item.lod_index = lod_index
	item.floating_sdf_offset_along_normal = -0.15
	item.floating_sdf_threshold = 0.0
	item.mesh = mesh
	item.material_override = mat
	item.cast_shadow = RenderingServer.SHADOW_CASTING_SETTING_OFF
	item.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	item.generator = generator
	return item


func _make_generator(def: Dictionary) -> VoxelInstanceGenerator:
	var gen := VoxelInstanceGenerator.new()
	gen.density = def.density
	gen.min_slope_degrees = def.min_slope
	gen.max_slope_degrees = def.max_slope
	gen.max_slope_falloff_degrees = 10.0
	gen.offset_along_normal = def.offset
	gen.min_scale = def.min_scale
	gen.max_scale = def.max_scale
	gen.random_rotation = true
	gen.vertical_alignment = 1.0
	gen.scale_distribution = VoxelInstanceGenerator.DISTRIBUTION_CUBIC
	gen.emit_mode = VoxelInstanceGenerator.EMIT_FROM_FACES_FAST
	gen.triangle_area_threshold = 0.18
	gen.noise_on_scale = 0.22
	var noise := FastNoiseLite.new()
	noise.seed = def.noise_seed
	noise.frequency = 0.022
	gen.noise = noise
	gen.noise_threshold = 0.48
	return gen
