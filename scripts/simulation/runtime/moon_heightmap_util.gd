class_name MoonHeightmapUtil
extends RefCounted

## Panoramic crust heightmap for VoxelGeneratorGraph SdfSphereHeightmap.
## SE-like: bake heights once, play samples the image (native C++), not per-voxel GDScript.

const _Params := preload("res://scripts/simulation/runtime/moon_terrain_params.gd")
const _HQ := preload("res://scripts/simulation/runtime/moon_terrain_generator.gd")


static func _native_bake_available() -> bool:
	return ClassDB.class_exists("MoonHeightmapBake")


static func _bake_pixels_native(
	width: int,
	height: int,
	radius_voxels: float
) -> PackedFloat32Array:
	var baker: Object = ClassDB.instantiate("MoonHeightmapBake")
	return baker.call(
		"bake_panorama",
		width,
		height,
		radius_voxels
	)


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

	var worker_count := clampi(OS.get_processor_count(), 1, height)
	var t0 := Time.get_ticks_msec()
	var pixels := PackedFloat32Array()

	if _native_bake_available():
		print(
			(
				"MoonHeightmap: native bake %dx%d "
				+ "(local FNL + C++ craters, one-time)..."
			)
			% [width, height]
		)
		pixels = _bake_pixels_native(width, height, MoonGeometry.radius_voxels())
	else:
		print(
			(
				"MoonHeightmap: baking panoramic crust %dx%d "
				+ "(%d threads GDScript, one-time)..."
			)
			% [width, height, worker_count]
		)
		pixels = _bake_pixels_gdscript(width, height, worker_count)

	if pixels.is_empty() or pixels.size() != width * height:
		push_error("MoonHeightmap: bake returned invalid pixel buffer")
		return Image.create(width, height, false, Image.FORMAT_RF)

	var t_merge := Time.get_ticks_msec()
	var img := Image.create_from_data(
		width,
		height,
		false,
		Image.FORMAT_RF,
		pixels.to_byte_array()
	)
	if img == null or img.get_width() <= 0:
		push_error("MoonHeightmap: create_from_data failed; falling back to set_pixel")
		img = Image.create(width, height, false, Image.FORMAT_RF)
		for y in height:
			var row := y * width
			for x in width:
				img.set_pixel(x, y, Color(pixels[row + x], 0.0, 0.0))
	var merge_ms := Time.get_ticks_msec() - t_merge

	var err := img.save_exr(abs_path, false)
	if err != OK:
		push_error("MoonHeightmap: save_exr failed (%s) → %s" % [str(err), abs_path])
	else:
		print(
			(
				"MoonHeightmap: saved %s in %d ms "
				+ "(merge %d ms, %d threads)"
			)
			% [abs_path, Time.get_ticks_msec() - t0, merge_ms, worker_count]
		)
	var vf := FileAccess.open(
		"%s/generator_version.txt" % dir, FileAccess.WRITE
	)
	if vf != null:
		vf.store_string(str(_Params.GENERATOR_VERSION))
		vf.close()
	return img


static func _bake_pixels_gdscript(
	width: int,
	height: int,
	worker_count: int
) -> PackedFloat32Array:
	var band_size := ceili(float(height) / float(worker_count))
	var results: Array = []
	results.resize(worker_count)
	var progress_mutex := Mutex.new()
	var generators: Array = []
	generators.resize(worker_count)
	for band_index in worker_count:
		var gen = _HQ.new()
		gen._radius_voxels = MoonGeometry.radius_voxels()
		gen._setup_noise()
		generators[band_index] = gen

	var task_ids: Array[int] = []
	for band_index in worker_count:
		var y0 := band_index * band_size
		var y1 := mini(y0 + band_size, height)
		if y0 >= height:
			break
		var task_id := WorkerThreadPool.add_task(
			_bake_heightmap_band.bind(
				y0,
				y1,
				width,
				height,
				generators[band_index],
				results,
				band_index,
				progress_mutex
			),
			false,
			"MoonHeightmap band %d" % band_index
		)
		task_ids.append(task_id)

	for task_id in task_ids:
		WorkerThreadPool.wait_for_task_completion(task_id)

	var pixels := PackedFloat32Array()
	pixels.resize(width * height)
	for band_index in results.size():
		var band: Variant = results[band_index]
		if band == null:
			push_error("MoonHeightmap: missing band %d" % band_index)
			continue
		var y0: int = band["y0"]
		var buffer: PackedFloat32Array = band["buffer"]
		var offset := y0 * width
		for i in buffer.size():
			pixels[offset + i] = buffer[i]
	return pixels


static func _bake_heightmap_band(
	y0: int,
	y1: int,
	width: int,
	height: int,
	gen: RefCounted,
	results: Array,
	band_index: int,
	progress_mutex: Mutex
) -> void:
	var band_h := y1 - y0
	var buffer := PackedFloat32Array()
	buffer.resize(band_h * width)

	for local_y in band_h:
		var y := y0 + local_y
		var v := (float(y) + 0.5) / float(height)
		var row_offset := local_y * width
		for x in width:
			var u := (float(x) + 0.5) / float(width)
			## Must match how NODE_SDF_SPHERE_HEIGHTMAP reads the panorama
			## back at play time, or relief gets skewed near poles / mirrored.
			var n := direction_from_node_uv(u, v)
			## Height in local voxel units (SdfSphereHeightmap factor=1).
			buffer[row_offset + x] = gen._height_voxels(n)
		if y % 64 == 0:
			progress_mutex.lock()
			print("MoonHeightmap: row %d/%d" % [y, height])
			progress_mutex.unlock()

	progress_mutex.lock()
	results[band_index] = {"y0": y0, "buffer": buffer}
	progress_mutex.unlock()


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
