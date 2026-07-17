class_name MoonHeightmapUtil
extends RefCounted

## Panoramic crust heightmap for VoxelGeneratorGraph SdfSphereHeightmap.
## SE-like: bake heights once, play samples the image (native C++), not per-voxel GDScript.

const _Params := preload("res://scripts/simulation/runtime/moon_terrain_params.gd")
const _HQ := preload("res://scripts/simulation/runtime/moon_terrain_generator.gd")


static func heightmap_path() -> String:
	return "%s/crust_heightmap.exr" % _Params.stream_directory()


static func absolute_heightmap_path() -> String:
	return ProjectSettings.globalize_path(heightmap_path())


static func ensure_heightmap(
	width: int = 2048,
	height: int = 1024
) -> Image:
	var abs_path := absolute_heightmap_path()
	var dir := abs_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var version_path := "%s/generator_version.txt" % abs_path.get_base_dir()
	var version_ok := false
	if FileAccess.file_exists(version_path):
		var vf := FileAccess.open(version_path, FileAccess.READ)
		if vf != null:
			version_ok = vf.get_as_text().strip_edges() == str(_Params.GENERATOR_VERSION)
			vf.close()
	if version_ok and FileAccess.file_exists(abs_path):
		var existing := Image.new()
		var err := existing.load(abs_path)
		if err == OK and existing.get_width() > 0:
			print(
				"MoonHeightmap: loaded %s (%dx%d)"
				% [heightmap_path(), existing.get_width(), existing.get_height()]
			)
			return existing
	return bake_heightmap(width, height, abs_path)


static func bake_heightmap(
	width: int,
	height: int,
	abs_path: String = ""
) -> Image:
	if abs_path.is_empty():
		abs_path = absolute_heightmap_path()
	var dir := abs_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	print(
		"MoonHeightmap: baking panoramic crust %dx%d (one-time)..."
		% [width, height]
	)
	var gen = _HQ.new()
	gen._radius_voxels = MoonGeometry.radius_voxels()
	gen._setup_noise()

	var img := Image.create(width, height, false, Image.FORMAT_RF)
	var t0 := Time.get_ticks_msec()
	for y in height:
		var v := (float(y) + 0.5) / float(height)
		for x in width:
			var u := (float(x) + 0.5) / float(width)
			## Must match how NODE_SDF_SPHERE_HEIGHTMAP reads the panorama
			## back at play time, or relief gets skewed near poles / mirrored.
			var n := direction_from_node_uv(u, v)
			## Height in local voxel units (SdfSphereHeightmap factor=1).
			var h_voxels: float = gen._height_voxels(n)
			img.set_pixel(x, y, Color(h_voxels, 0.0, 0.0))
		if y % 64 == 0:
			print("MoonHeightmap: row %d/%d" % [y, height])
	var err := img.save_exr(abs_path, false)
	if err != OK:
		push_error("MoonHeightmap: save_exr failed (%s) → %s" % [str(err), abs_path])
	else:
		print(
			"MoonHeightmap: saved %s in %d ms"
			% [abs_path, Time.get_ticks_msec() - t0]
		)
	var vf := FileAccess.open(
		"%s/generator_version.txt" % dir, FileAccess.WRITE
	)
	if vf != null:
		vf.store_string(str(_Params.GENERATOR_VERSION))
		vf.close()
	return img


static func direction_from_panorama_uv(u: float, v: float) -> Vector3:
	## Equirectangular: u=[0,1] longitude, v=[0,1] top→bottom latitude.
	var lon := u * TAU
	var lat := (0.5 - v) * PI
	var cl := cos(lat)
	return Vector3(cl * cos(lon), sin(lat), cl * sin(lon)).normalized()


static func direction_from_node_uv(u: float, v: float) -> Vector3:
	## Inverse of Voxel Tools' NODE_SDF_SPHERE_HEIGHTMAP sampling (image.h):
	##   uvx = -atan2(nz, nx)/TAU + 0.5   →  atan2(nz,nx) = (0.5 - uvx)*TAU
	##   uvy = -0.5*skew3(ny) + 0.5       →  skew3(ny) = 1 - 2*uvy
	## where skew3(x) = (x^3 + x)/2 approximates asin latitude.
	var lon := (0.5 - u) * TAU
	var ny := _inv_skew3(clampf(1.0 - 2.0 * v, -1.0, 1.0))
	var r := sqrt(maxf(0.0, 1.0 - ny * ny))
	return Vector3(r * cos(lon), ny, r * sin(lon)).normalized()


static func _inv_skew3(s: float) -> float:
	## Solve x^3 + x - 2s = 0 (single real root, Cardano); s,x in [-1,1].
	var d := sqrt(s * s + 1.0 / 27.0)
	var x := _cbrt(s + d) + _cbrt(s - d)
	return clampf(x, -1.0, 1.0)


static func _cbrt(a: float) -> float:
	return signf(a) * pow(absf(a), 1.0 / 3.0)
