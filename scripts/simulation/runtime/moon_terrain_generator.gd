class_name MoonTerrainGenerator
extends VoxelGeneratorScript

## Lunar height field with readable impact morphology.
## sdf = length(p) - (R0 + H(normalize(p)))

const CHANNEL := VoxelBuffer.CHANNEL_SDF

const LARGE_CRATER_COUNT := 48
const MED_CRATER_COUNT := 140
const SMALL_CRATER_COUNT := 320

var _radius_voxels: float = MoonGeometry.radius_voxels()
var _continent: RefCounted
var _rough: RefCounted


func _init() -> void:
	_setup_noise()


func _setup_noise() -> void:
	_continent = _make_noise(MoonTerrainParams.SEED + 11, 420.0, 2)
	## Low-amp crust roughness — only after large forms, never the hero.
	_rough = _make_noise(MoonTerrainParams.SEED + 77, 55.0, 3)


func _make_noise(seed_value: int, period_m: float, octaves: int) -> RefCounted:
	var n: RefCounted = ClassDB.instantiate(&"ZN_FastNoiseLite")
	n.seed = seed_value
	n.period = MoonTerrainParams.meters_to_voxels(period_m)
	n.noise_type = 0
	n.fractal_type = 1
	n.fractal_octaves = octaves
	n.fractal_lacunarity = 2.1
	n.fractal_gain = 0.45
	return n


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
	return r - (_radius_voxels + _height_voxels(p / r))


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
	## Broad maria (low) vs highland crust (high).
	var highland := smoothstep(-0.1, 0.35, c)
	var h := lerpf(
		-MoonTerrainParams.MARIA_DEPTH_M,
		MoonTerrainParams.HIGHLAND_LIFT_M,
		highland
	)
	## Soft highland swell — not spiky FBM mountains.
	h += highland * c * 6.0
	## Impacts are the visual hero.
	h += _crater_field(n)
	## Micro roughness after forms (tiny).
	h += float(_rough.get_noise_3dv(domain * 2.2)) * 1.1
	return h


func _crater_field(n: Vector3) -> float:
	var h := 0.0
	h += _craters_of_class(
		n, LARGE_CRATER_COUNT, MoonTerrainParams.SEED + 100,
		0.055, 0.125, MoonTerrainParams.CRATER_LARGE_AMP_M, 0.55, 1.75
	)
	h += _craters_of_class(
		n, MED_CRATER_COUNT, MoonTerrainParams.SEED + 200,
		0.02, 0.055, MoonTerrainParams.CRATER_MED_AMP_M, 0.5, 1.85
	)
	h += _craters_of_class(
		n, SMALL_CRATER_COUNT, MoonTerrainParams.SEED + 300,
		0.008, 0.02, MoonTerrainParams.CRATER_SMALL_AMP_M, 0.45, 2.0
	)
	return h


func _craters_of_class(
	n: Vector3,
	count: int,
	seed_base: int,
	rad_min: float,
	rad_max: float,
	depth_m: float,
	rim_frac: float,
	wall_power: float
) -> float:
	var carve := 0.0
	var rim := 0.0
	for i in count:
		var center := _seed_dir(seed_base + i * 17)
		var cos_a := clampf(n.dot(center), -1.0, 1.0)
		var u := _hash01(seed_base + i * 31)
		var rad := lerpf(rad_min, rad_max, u)
		var cos_rad := cos(rad * 1.08)
		if cos_a < cos_rad:
			continue
		var ang := acos(cos_a)
		## Slight ellipticity via stretched metric.
		var bitangent := center.cross(Vector3.UP)
		if bitangent.length_squared() < 0.001:
			bitangent = center.cross(Vector3.RIGHT)
		bitangent = bitangent.normalized()
		var tangent := bitangent.cross(center).normalized()
		var local := n - center * cos_a
		var x := local.dot(tangent)
		var y := local.dot(bitangent)
		var stretch := lerpf(0.85, 1.15, _hash01(seed_base + i * 59))
		var ang_ell := sqrt(x * x * stretch + y * y / stretch)
		## Convert chord-ish to angle-ish near surface.
		ang_ell = asin(clampf(ang_ell, 0.0, 1.0))
		if ang_ell >= rad * 1.08:
			continue
		var t := ang_ell / rad
		var depth_scale := lerpf(0.7, 1.15, _hash01(seed_base + i * 47))
		## Floor flattening in the inner 35%.
		var floor_t := smoothstep(0.0, 0.35, t)
		var bowl := pow(maxf(0.0, 1.0 - t), wall_power)
		bowl = lerpf(bowl * 0.55, bowl, floor_t)
		var local_carve := -depth_m * depth_scale * bowl
		## Sharp raised rim + soft ejecta apron outside.
		var rim_w := exp(-pow((t - 0.93) / 0.055, 2.0))
		var ejecta := exp(-pow((t - 1.05) / 0.18, 2.0)) * 0.18
		var local_rim := depth_m * depth_scale * (rim_frac * rim_w + ejecta)
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
