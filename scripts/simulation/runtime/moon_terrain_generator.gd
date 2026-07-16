class_name MoonTerrainGenerator
extends VoxelGeneratorScript

## Height-based lunar SDF on a sphere (Voxel Tools official planet approach):
##   sdf = length(p) - (R0 + H(normalize(p)))
## Layers: continents, ridged mountains, plateaus, canyons, cellular craters, micro.
## See docs/specs/MOON-EXPERIMENT-V0.md and voxel-tools generators → Planet.

const CHANNEL := VoxelBuffer.CHANNEL_SDF

var _radius_voxels: float = MoonGeometry.radius_voxels()
var _continent: RefCounted
var _mountain: RefCounted
var _plateau: RefCounted
var _canyon: RefCounted
var _crater_large: RefCounted
var _crater_med: RefCounted
var _crater_small: RefCounted
var _micro: RefCounted


func _init() -> void:
	_setup_noise()


func _setup_noise() -> void:
	_continent = _make_noise(
		MoonTerrainParams.SEED + 1,
		MoonTerrainParams.CONTINENT_PERIOD_M,
		1, ## FBM-like
		5
	)
	_mountain = _make_noise(
		MoonTerrainParams.SEED + 2,
		MoonTerrainParams.MOUNTAIN_PERIOD_M,
		2, ## ridged-style
		4
	)
	_plateau = _make_noise(
		MoonTerrainParams.SEED + 3,
		MoonTerrainParams.PLATEAU_PERIOD_M,
		1,
		3
	)
	_canyon = _make_noise(
		MoonTerrainParams.SEED + 4,
		MoonTerrainParams.CANYON_PERIOD_M,
		2,
		3
	)
	_crater_large = _make_cellular(
		MoonTerrainParams.SEED + 5,
		MoonTerrainParams.CRATER_LARGE_PERIOD_M
	)
	_crater_med = _make_cellular(
		MoonTerrainParams.SEED + 6,
		MoonTerrainParams.CRATER_MED_PERIOD_M
	)
	_crater_small = _make_cellular(
		MoonTerrainParams.SEED + 7,
		MoonTerrainParams.CRATER_SMALL_PERIOD_M
	)
	_micro = _make_noise(
		MoonTerrainParams.SEED + 8,
		MoonTerrainParams.MICRO_PERIOD_M,
		1,
		2
	)


func _make_noise(seed_value: int, period_m: float, fractal_type: int, octaves: int) -> RefCounted:
	var n: RefCounted = ClassDB.instantiate(&"ZN_FastNoiseLite")
	n.seed = seed_value
	n.period = MoonTerrainParams.meters_to_voxels(period_m)
	n.fractal_type = fractal_type
	n.fractal_octaves = octaves
	n.fractal_lacunarity = 2.0
	n.fractal_gain = 0.5
	return n


func _make_cellular(seed_value: int, period_m: float) -> RefCounted:
	var n: RefCounted = ClassDB.instantiate(&"ZN_FastNoiseLite")
	n.seed = seed_value
	n.period = MoonTerrainParams.meters_to_voxels(period_m)
	n.noise_type = 2 ## cellular
	n.cellular_return_type = 1 ## distance-like return on ZN binding
	n.cellular_jitter = 0.85
	n.fractal_type = 0
	n.fractal_octaves = 1
	return n


func _crater_delta_m(domain: Vector3, noise: RefCounted, amp_m: float) -> float:
	## Cellular distance → smooth bowl + soft rim.
	var raw := float(noise.get_noise_3dv(domain))
	## Normalize observed cellular ranges into 0..1 (near 0 = cell center).
	var d := clampf(absf(raw), 0.0, 1.0)
	var bowl := 1.0 - smoothstep(0.0, 0.55, d)
	bowl *= bowl
	var rim := exp(-pow((d - 0.42) / 0.08, 2.0)) * 0.35
	return -amp_m * bowl + amp_m * 0.25 * rim


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
	var h := _height_voxels(n)
	return r - (_radius_voxels + h)


func _height_voxels(n: Vector3) -> float:
	## Sample noises in a scaled domain so period_*_m maps to arc length ≈ meters.
	var domain := n * _radius_voxels
	var h_m := 0.0

	var continent := float(_continent.get_noise_3dv(domain))
	h_m += continent * MoonTerrainParams.CONTINENT_AMP_M

	## Ridged mountains: 1 - |noise|, keep positive peaks (docs negate ridged for eroded look).
	var mountain_n := float(_mountain.get_noise_3dv(domain))
	var ridged := 1.0 - absf(mountain_n)
	ridged = ridged * ridged
	h_m += ridged * MoonTerrainParams.MOUNTAIN_AMP_M

	## Plateaus: terrace a mid-frequency field.
	var plat := float(_plateau.get_noise_3dv(domain))
	var steps := MoonTerrainParams.PLATEAU_STEPS
	var terraced := floorf((plat * 0.5 + 0.5) * steps) / steps
	terraced = terraced * 2.0 - 1.0
	h_m += terraced * MoonTerrainParams.PLATEAU_AMP_M

	## Canyons / rilles: carved where ridged noise is high.
	var canyon_n := float(_canyon.get_noise_3dv(domain))
	var canyon := maxf(0.0, absf(canyon_n) - 0.55) / 0.45
	h_m -= canyon * canyon * MoonTerrainParams.CANYON_AMP_M

	h_m += _crater_delta_m(domain, _crater_large, MoonTerrainParams.CRATER_LARGE_AMP_M)
	h_m += _crater_delta_m(domain, _crater_med, MoonTerrainParams.CRATER_MED_AMP_M)
	h_m += _crater_delta_m(domain, _crater_small, MoonTerrainParams.CRATER_SMALL_AMP_M)

	h_m += float(_micro.get_noise_3dv(domain * 1.7)) * MoonTerrainParams.MICRO_AMP_M

	h_m = clampf(
		h_m,
		-MoonTerrainParams.HEIGHT_CLAMP_M,
		MoonTerrainParams.HEIGHT_CLAMP_M
	)
	return MoonTerrainParams.meters_to_voxels(h_m)
