class_name MoonTerrainGenerator
extends VoxelGeneratorScript

## Nearly spherical crust + clean overlapping impact craters.
## No soft highland "tumors"; rims are low and wide (C1-smooth).

const CHANNEL := VoxelBuffer.CHANNEL_SDF

const HUGE_CRATER_COUNT := 5
const LARGE_CRATER_COUNT := 60
const MED_CRATER_COUNT := 160
const SMALL_CRATER_COUNT := 340

var _radius_voxels: float = MoonGeometry.radius_voxels()
var _continent: RefCounted
var _massif_mask: RefCounted
var _ridge: RefCounted
var _ridge_detail: RefCounted


func _init() -> void:
	_setup_noise()


func _setup_noise() -> void:
	_continent = ClassDB.instantiate(&"ZN_FastNoiseLite")
	_continent.seed = MoonTerrainParams.SEED + 11
	_continent.period = MoonTerrainParams.meters_to_voxels(520.0)
	_continent.noise_type = 0
	_continent.fractal_type = 1
	_continent.fractal_octaves = 2
	_continent.fractal_lacunarity = 2.0
	_continent.fractal_gain = 0.35

	## Sparse massif patches (rare highland ranges).
	_massif_mask = ClassDB.instantiate(&"ZN_FastNoiseLite")
	_massif_mask.seed = MoonTerrainParams.SEED + 41
	_massif_mask.period = MoonTerrainParams.meters_to_voxels(280.0)
	_massif_mask.noise_type = 0
	_massif_mask.fractal_type = 1
	_massif_mask.fractal_octaves = 2
	_massif_mask.fractal_gain = 0.4

	## Angular ridged mountains (not soft blobs).
	_ridge = ClassDB.instantiate(&"ZN_FastNoiseLite")
	_ridge.seed = MoonTerrainParams.SEED + 42
	_ridge.period = MoonTerrainParams.meters_to_voxels(70.0)
	_ridge.noise_type = 0
	_ridge.fractal_type = 2 ## ridged-style fractal on ZN
	_ridge.fractal_octaves = 3
	_ridge.fractal_lacunarity = 2.2
	_ridge.fractal_gain = 0.5

	_ridge_detail = ClassDB.instantiate(&"ZN_FastNoiseLite")
	_ridge_detail.seed = MoonTerrainParams.SEED + 43
	_ridge_detail.period = MoonTerrainParams.meters_to_voxels(28.0)
	_ridge_detail.noise_type = 0
	_ridge_detail.fractal_type = 2
	_ridge_detail.fractal_octaves = 2
	_ridge_detail.fractal_gain = 0.45


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
	return MoonTerrainParams.meters_to_voxels(
		clampf(h_m, -MoonTerrainParams.HEIGHT_CLAMP_M, MoonTerrainParams.HEIGHT_CLAMP_M)
	)


func _height_meters(n: Vector3) -> float:
	var domain := n * _radius_voxels
	var c := float(_continent.get_noise_3dv(domain))
	## Very subtle maria/highland (± few meters) — sphere stays spherical.
	var highland := smoothstep(0.0, 0.5, c)
	var h := lerpf(
		-MoonTerrainParams.MARIA_DEPTH_M,
		MoonTerrainParams.HIGHLAND_LIFT_M,
		highland
	)
	## Sparse angular highland ranges (kept modest — craters stay the hero).
	h += _mountain_ranges(domain, highland)
	h += _crater_field(n)
	return h


func _mountain_ranges(domain: Vector3, highland: float) -> float:
	if highland < 0.05 or MoonTerrainParams.MOUNTAIN_AMP_M <= 0.001:
		return 0.0
	## Rare patches — denser than before so ranges read as "dirt clumps" no more.
	var patch := float(_massif_mask.get_noise_3dv(domain * 0.55))
	var mask := smoothstep(0.22, 0.58, patch)
	if mask <= 0.001:
		return 0.0
	## Ridged peaks → sharper / more "mountainous" than soft FBM blobs.
	var r0 := float(_ridge.get_noise_3dv(domain))
	var ridged := 1.0 - absf(r0)
	ridged = pow(ridged, 2.15)
	var r1 := float(_ridge_detail.get_noise_3dv(domain * 1.55))
	var detail := pow(1.0 - absf(r1), 2.35)
	## Keep only the sharp upper part of the ridge (cuts soft shoulders).
	var shape := smoothstep(0.28, 0.92, ridged * 0.7 + detail * 0.3)
	return highland * mask * shape * MoonTerrainParams.MOUNTAIN_AMP_M


func _crater_field(n: Vector3) -> float:
	var h := 0.0
	## A few oversized basins first (hero impacts).
	h += _craters_of_class(
		n, HUGE_CRATER_COUNT, MoonTerrainParams.SEED + 50,
		0.12, 0.20, MoonTerrainParams.CRATER_HUGE_AMP_M, 0.14
	)
	h += _craters_of_class(
		n, LARGE_CRATER_COUNT, MoonTerrainParams.SEED + 100,
		0.045, 0.095, MoonTerrainParams.CRATER_LARGE_AMP_M, 0.12
	)
	h += _craters_of_class(
		n, MED_CRATER_COUNT, MoonTerrainParams.SEED + 200,
		0.018, 0.045, MoonTerrainParams.CRATER_MED_AMP_M, 0.11
	)
	h += _craters_of_class(
		n, SMALL_CRATER_COUNT, MoonTerrainParams.SEED + 300,
		0.007, 0.018, MoonTerrainParams.CRATER_SMALL_AMP_M, 0.1
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
		var u := _hash01(seed_base + i * 31)
		var rad := lerpf(rad_min, rad_max, u)
		if cos_a < cos(rad * 1.2):
			continue
		var t := acos(cos_a) / rad
		var d := depth_m * lerpf(0.85, 1.0, _hash01(seed_base + i * 47))

		if t < 1.0:
			## Cosine bowl: C1 at rim (derivative → 0), no lip spike from the bowl itself.
			var bowl := 0.5 + 0.5 * cos(PI * t)
			bowl = bowl * bowl
			carve = minf(carve, -d * bowl)

		## Low wide rim only (prevents silhouette teeth).
		var rim_w := exp(-pow((t - 1.0) / 0.20, 2.0))
		rim = maxf(rim, d * rim_frac * rim_w)
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
