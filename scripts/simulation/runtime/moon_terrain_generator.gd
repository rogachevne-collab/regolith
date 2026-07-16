class_name MoonTerrainGenerator
extends VoxelGeneratorScript

## Lunar H(n): smooth maria/highland base + many overlapping sharp craters.
## sdf = length(p) - (R0 + H(normalize(p)))

const CHANNEL := VoxelBuffer.CHANNEL_SDF

const LARGE_CRATER_COUNT := 55
const MED_CRATER_COUNT := 120
const SMALL_CRATER_COUNT := 180

var _radius_voxels: float = MoonGeometry.radius_voxels()
var _continent: RefCounted


func _init() -> void:
	_setup_noise()


func _setup_noise() -> void:
	_continent = ClassDB.instantiate(&"ZN_FastNoiseLite")
	_continent.seed = MoonTerrainParams.SEED + 11
	_continent.period = MoonTerrainParams.meters_to_voxels(380.0)
	_continent.noise_type = 0
	_continent.fractal_type = 1
	_continent.fractal_octaves = 2
	_continent.fractal_lacunarity = 2.0
	_continent.fractal_gain = 0.4


func _get_used_channels_mask() -> int:
	return 1 << CHANNEL


func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	var size: Vector3i = out_buffer.get_size()
	var stride := 1 << lod
	var origin := Vector3(origin_in_voxels)
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var p := origin + Vector3(x * stride, y * stride, z * stride)
				out_buffer.set_voxel_f(_sample_sdf(p), x, y, z, CHANNEL)


func _sample_sdf(p: Vector3) -> float:
	var r := p.length()
	if r <= 0.000001:
		return -_radius_voxels
	var n := p / r
	return r - (_radius_voxels + _height_voxels(n))


func _height_voxels(n: Vector3) -> float:
	var h_m := _height_meters(n)
	h_m = clampf(
		h_m,
		-MoonTerrainParams.HEIGHT_CLAMP_M,
		MoonTerrainParams.HEIGHT_CLAMP_M
	)
	return MoonTerrainParams.meters_to_voxels(h_m)


func _height_meters(n: Vector3) -> float:
	var domain := n * _radius_voxels
	var c := float(_continent.get_noise_3dv(domain))
	var highland := smoothstep(0.0, 0.4, c)
	## Gentle two-tone crust — features come from craters, not noise spikes.
	var h := lerpf(
		-MoonTerrainParams.MARIA_DEPTH_M,
		MoonTerrainParams.HIGHLAND_LIFT_M,
		highland
	)
	h += _crater_field(n)
	return h


func _crater_field(n: Vector3) -> float:
	var h := 0.0
	## Angular radii chosen so from orbit you see many round scars, not 3 giant blobs.
	h += _craters_of_class(
		n, LARGE_CRATER_COUNT, MoonTerrainParams.SEED + 100,
		0.05, 0.11, MoonTerrainParams.CRATER_LARGE_AMP_M, 0.45
	)
	h += _craters_of_class(
		n, MED_CRATER_COUNT, MoonTerrainParams.SEED + 200,
		0.022, 0.05, MoonTerrainParams.CRATER_MED_AMP_M, 0.4
	)
	h += _craters_of_class(
		n, SMALL_CRATER_COUNT, MoonTerrainParams.SEED + 300,
		0.01, 0.022, MoonTerrainParams.CRATER_SMALL_AMP_M, 0.35
	)
	return h


func _craters_of_class(
	n: Vector3,
	count: int,
	seed_base: int,
	rad_min: float,
	rad_max: float,
	depth_m: float,
	rim_frac: float
) -> float:
	var carve := 0.0
	var rim := 0.0
	for i in count:
		var center := _seed_dir(seed_base + i * 17)
		var cos_a := clampf(n.dot(center), -1.0, 1.0)
		var ang := acos(cos_a)
		var u := _hash01(seed_base + i * 31)
		var rad := lerpf(rad_min, rad_max, u)
		if ang >= rad * 1.05:
			continue
		var t := ang / rad
		## Steep walls, flat-ish floor.
		var bowl := pow(maxf(0.0, 1.0 - t), 1.6)
		var local_carve := (
			-depth_m
			* bowl
			* lerpf(0.75, 1.0, _hash01(seed_base + i * 47))
		)
		## Crisp rim ring.
		var rim_w := exp(-pow((t - 0.92) / 0.07, 2.0))
		var local_rim := depth_m * rim_frac * rim_w
		carve = minf(carve, local_carve)
		rim = maxf(rim, local_rim)
	return carve + rim


func _seed_dir(seed_value: int) -> Vector3:
	var z := _hash01(seed_value) * 2.0 - 1.0
	var a := _hash01(seed_value + 913) * TAU
	var r := sqrt(maxf(0.0, 1.0 - z * z))
	return Vector3(cos(a) * r, z, sin(a) * r).normalized()


func _hash01(x: int) -> float:
	var v := x * 747796405 + 2891336453
	v = ((v >> ((v >> 28) + 4)) ^ v) * 277803737
	v = (v >> 22) ^ v
	return float(v & 0xFFFFFF) / float(0x1000000)
