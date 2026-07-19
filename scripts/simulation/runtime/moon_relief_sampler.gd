class_name MoonReliefSampler
extends RefCounted

## Analytic lunar relief H(n) in meters — same source as MoonNativeSdfGenerator.
## Profile.MAP = macro-only for map preview (no meter-scale pepper).

enum Profile { FULL, MAP }

const _Params := preload("res://scripts/simulation/runtime/moon_terrain_params.gd")
const _Gen := preload("res://scripts/simulation/runtime/moon_terrain_generator.gd")

const PREVIEW_W := 256
const PREVIEW_H := 128

static var _preview_tex: ImageTexture
static var _preview_key := ""

static var _native: Object
static var _native_radius := -1.0
static var _gd: RefCounted


static func sample_height_meters(dir: Vector3, profile: int = Profile.FULL) -> float:
	var n := dir
	if n.length_squared() <= 0.000001:
		n = Vector3.UP
	else:
		n = n.normalized()
	if profile == Profile.MAP:
		if _ensure_native() and _native.has_method("sample_height_meters_map"):
			return float(_native.call("sample_height_meters_map", n))
		return _gdscript_height(n, true)
	if _ensure_native():
		return float(_native.call("sample_height_meters", n))
	return _gdscript_height(n, false)


static func _gdscript_height(n: Vector3, map_profile: bool) -> float:
	if _gd == null:
		_gd = _Gen.new()
		_gd._radius_voxels = MoonGeometry.radius_voxels()
		_gd._setup_noise()
	if map_profile and _gd.has_method("_height_meters_map"):
		return _gd._height_meters_map(n)
	return _gd._height_meters(n)


static func equirect_preview_texture() -> ImageTexture:
	var key := "%.0f_v%d" % [
		MoonGeometry.active_surface_radius_m(),
		_Params.GENERATOR_VERSION,
	]
	if _preview_tex != null and _preview_key == key:
		return _preview_tex
	_preview_key = key
	var heights := PackedFloat32Array()
	heights.resize(PREVIEW_W * PREVIEW_H)
	var min_h := INF
	var max_h := -INF
	for y in PREVIEW_H:
		var v := (float(y) + 0.5) / float(PREVIEW_H)
		for x in PREVIEW_W:
			var u := (float(x) + 0.5) / float(PREVIEW_W)
			var dir := MoonHeightmapUtil.direction_from_node_uv(u, v)
			var h_m := sample_height_meters(dir, Profile.MAP)
			heights[y * PREVIEW_W + x] = h_m
			min_h = minf(min_h, h_m)
			max_h = maxf(max_h, h_m)
	var span := maxf(max_h - min_h, 0.001)
	var img := Image.create(PREVIEW_W, PREVIEW_H, false, Image.FORMAT_RGB8)
	for y in PREVIEW_H:
		for x in PREVIEW_W:
			var t := (heights[y * PREVIEW_W + x] - min_h) / span
			img.set_pixel(
				x,
				y,
				Color(
					lerpf(0.08, 0.55, t),
					lerpf(0.07, 0.48, t),
					lerpf(0.06, 0.40, t)
				)
			)
	_preview_tex = ImageTexture.create_from_image(img)
	return _preview_tex


static func _ensure_native() -> bool:
	if not ClassDB.class_exists("MoonHeightmapBake"):
		return false
	var rv := MoonGeometry.radius_voxels()
	if _native == null or absf(_native_radius - rv) > 0.001:
		_native = ClassDB.instantiate("MoonHeightmapBake")
		_native.call("setup", rv)
		_native_radius = rv
	return _native.has_method("sample_height_meters")
