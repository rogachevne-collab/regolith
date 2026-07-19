class_name MoonNativeSdfGenerator
extends VoxelGeneratorScript

## Analytic lunar SDF, no heightmap: sdf = |p| - (R + H(p/|p|)).
## H(n) lives in native C++ (MoonHeightmapBake / MoonTerrainSampler) — the
## same relief the panorama bake used, sampled directly per block. No
## equirectangular projection → no pole pinch, no longitude seam.
##
## Per block this script makes 2 native calls (classify + fill); voxels are
## written in one set_channel_from_byte_array when the startup calibration
## proves our encoder matches VoxelBuffer's 16-bit SDF quantizer, otherwise
## a per-voxel set_voxel_f fallback keeps correctness.

const CHANNEL := VoxelBuffer.CHANNEL_SDF
## Uniform fill for blocks fully off the crust shell (sign is what matters).
const AIR_SDF := 100.0
const SOLID_SDF := -100.0
## voxel tools constants.h QUANTIZED_SDF_16_BITS_SCALE — preferred when the
## calibrated estimate agrees, so encode matches the plugin bit-for-bit.
const KNOWN_SDF16_SCALE := 0.002
## classify_block results (mirrors MoonHeightmapBake.BlockClass).
const BLOCK_MIXED := 0
const BLOCK_AIR := 1
const BLOCK_SOLID := 2

var _baker: Object
var _radius_voxels: float
var _bytes_16_ok := false
var _order_ok := false
var _encode_scale := KNOWN_SDF16_SCALE


func _init(radius_voxels: float = MoonGeometry.radius_voxels()) -> void:
	_radius_voxels = radius_voxels
	if not ClassDB.class_exists(&"MoonHeightmapBake"):
		push_warning("MoonNativeSdfGenerator: MoonHeightmapBake class missing")
		return
	_baker = ClassDB.instantiate(&"MoonHeightmapBake")
	_baker.call("setup", _radius_voxels)
	_calibrate()


func is_native_ready() -> bool:
	return _baker != null


## Equirect albedo-brightness map (maria + crater rays); null if unavailable.
func bake_brightness_map(width: int, height: int) -> Image:
	if _baker == null or not _baker.has_method("bake_brightness_panorama"):
		return null
	var bytes: PackedByteArray = _baker.call("bake_brightness_panorama", width, height)
	if bytes.size() != width * height:
		return null
	return Image.create_from_data(width, height, false, Image.FORMAT_L8, bytes)


## World-space (moon-centered) skylight centers of generated caves.
func cave_entrances() -> PackedVector3Array:
	if _baker == null or not _baker.has_method("cave_entrances"):
		return PackedVector3Array()
	return _baker.call("cave_entrances")


func describe() -> String:
	if _baker == null:
		return "native sampler unavailable"
	var path := "per-voxel fallback"
	if _bytes_16_ok:
		path = "byte-array fast path (scale %.6f)" % _encode_scale
	elif _order_ok:
		path = "float32 byte path"
	return "R=%.1f vox, %s" % [_radius_voxels, path]


func _get_used_channels_mask() -> int:
	return 1 << CHANNEL


func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	var size: Vector3i = out_buffer.get_size()
	var stride := 1 << lod
	match int(_baker.call("classify_block", origin_in_voxels, size, stride)):
		BLOCK_AIR:
			out_buffer.fill_f(AIR_SDF, CHANNEL)
			return
		BLOCK_SOLID:
			out_buffer.fill_f(SOLID_SDF, CHANNEL)
			return

	var depth: int = out_buffer.get_channel_depth(CHANNEL)
	if _bytes_16_ok and depth == VoxelBuffer.DEPTH_16_BIT:
		var bytes: PackedByteArray = _baker.call(
			"sample_block_sdf16", origin_in_voxels, size, stride, _encode_scale
		)
		if bytes.size() == size.x * size.y * size.z * 2:
			out_buffer.set_channel_from_byte_array(CHANNEL, bytes)
			return

	var values: PackedFloat32Array = _baker.call(
		"sample_block_sdf_f", origin_in_voxels, size, stride
	)
	if values.size() != size.x * size.y * size.z:
		push_error("MoonNativeSdfGenerator: bad native block size")
		out_buffer.fill_f(AIR_SDF, CHANNEL)
		return

	if _order_ok and depth == VoxelBuffer.DEPTH_32_BIT:
		out_buffer.set_channel_from_byte_array(CHANNEL, values.to_byte_array())
		return

	## Correct-but-slow path: same memory order as native fill (y innermost).
	var i := 0
	for z in size.z:
		for x in size.x:
			for y in size.y:
				out_buffer.set_voxel_f(values[i], x, y, z, CHANNEL)
				i += 1


func _calibrate() -> void:
	## Prove, against a real VoxelBuffer, that (a) channel memory order is
	## y-innermost as the native fill assumes and (b) our snorm16 quantizer
	## matches set_voxel_f. Any mismatch downgrades to the per-voxel path.
	var probe := VoxelBuffer.new()
	if not (
		probe.has_method("get_channel_as_byte_array")
		and probe.has_method("set_channel_from_byte_array")
	):
		push_warning("MoonNativeSdfGenerator: VoxelBuffer byte-array API missing")
		return

	## Distinct dims catch axis-order mistakes; values span most of the
	## representable ±1/scale range without touching the clamp.
	var size := Vector3i(2, 3, 5)
	probe.create(size.x, size.y, size.z)
	probe.set_channel_depth(CHANNEL, VoxelBuffer.DEPTH_16_BIT)

	var values := PackedFloat32Array()
	values.resize(size.x * size.y * size.z)
	var i := 0
	for z in size.z:
		for x in size.x:
			for y in size.y:
				var v := -420.0 + float(x + y * 2 + z * 6) * 29.5
				values[i] = v
				probe.set_voxel_f(v, x, y, z, CHANNEL)
				i += 1

	var reference: PackedByteArray = probe.get_channel_as_byte_array(CHANNEL)
	if reference.size() != values.size() * 2:
		push_warning(
			"MoonNativeSdfGenerator: unexpected channel byte size %d" % reference.size()
		)
		return

	var scale := _estimate_scale()
	if scale <= 0.0:
		push_warning("MoonNativeSdfGenerator: could not estimate SDF16 scale")
		return
	if absf(scale - KNOWN_SDF16_SCALE) < KNOWN_SDF16_SCALE * 0.01:
		scale = KNOWN_SDF16_SCALE

	var encoded: PackedByteArray = _baker.call("encode_values_s16", values, scale)
	var max_err := _max_s16_error(reference, encoded)
	if max_err < 0:
		push_warning("MoonNativeSdfGenerator: calibration size mismatch")
		return
	if max_err > 1:
		push_warning(
			"MoonNativeSdfGenerator: SDF16 encode mismatch (max %d lsb) — slow path"
			% max_err
		)
		return

	## Round-trip the setter as well: it must accept our byte layout.
	var echo := VoxelBuffer.new()
	echo.create(size.x, size.y, size.z)
	echo.set_channel_depth(CHANNEL, VoxelBuffer.DEPTH_16_BIT)
	echo.set_channel_from_byte_array(CHANNEL, encoded)
	i = 0
	var lsb := 1.0 / (32767.0 * scale)
	for z in size.z:
		for x in size.x:
			for y in size.y:
				if absf(echo.get_voxel_f(x, y, z, CHANNEL) - values[i]) > lsb * 4.0:
					push_warning("MoonNativeSdfGenerator: setter round-trip mismatch")
					return
				i += 1

	_encode_scale = scale
	_order_ok = true
	_bytes_16_ok = true
	print("MoonNativeSdfGenerator: calibrated (%s)" % describe())


func _estimate_scale() -> float:
	var probe := VoxelBuffer.new()
	probe.create(1, 1, 1)
	probe.set_channel_depth(CHANNEL, VoxelBuffer.DEPTH_16_BIT)
	probe.set_voxel_f(400.0, 0, 0, 0, CHANNEL)
	var raw := probe.get_channel_as_byte_array(CHANNEL)
	if raw.size() != 2:
		return -1.0
	var s := raw.decode_s16(0)
	if s <= 0:
		return -1.0
	return (float(s) / 32767.0) / 400.0


func _max_s16_error(a: PackedByteArray, b: PackedByteArray) -> int:
	if a.size() != b.size():
		return -1
	var max_err := 0
	var count := a.size() / 2
	for i in count:
		var err := absi(a.decode_s16(i * 2) - b.decode_s16(i * 2))
		if err > max_err:
			max_err = err
	return max_err
