class_name MoonTerrainGenerator
extends VoxelGeneratorScript

## Nearly spherical toy Moon: mare/highland dichotomy + spatial-hashed craters.
## Single relief source for heightmap bake and from-space preview.

const CHANNEL := VoxelBuffer.CHANNEL_SDF

const HUGE_CRATER_COUNT := 5
const LARGE_CRATER_COUNT := 95
const MED_CRATER_COUNT := 280
const SMALL_CRATER_COUNT := 520
## Unit-sphere grid for crater lookup (O(k) neighbors, not O(all)).
const CRATER_GRID := 24
## Handful of large mare basins (angular coords on unit sphere).
const MARE_COUNT := 5

## Crater size class ids stored in each crater dict.
const CLASS_HUGE := 0
const CLASS_LARGE := 1
const CLASS_MED := 2
const CLASS_SMALL := 3

var _radius_voxels: float = MoonGeometry.radius_voxels()
var _mare_field: RefCounted
var _highland_rough: RefCounted
var _surface: RefCounted
var _regolith: RefCounted
## Seeded mare basin centers / angular radii (radians on unit sphere).
var _mare_centers: Array = []
var _mare_radii: Array = []
## Each entry: Dictionary center/rad/depth/rim_frac/class
var _craters: Array = []
## cell key "x,y,z" -> Array of crater indices
var _crater_cells: Dictionary = {}


func _init() -> void:
	_setup_noise()


func _setup_noise() -> void:
	## Low-frequency field for mare vs highland (a few large smooth basins).
	_mare_field = ClassDB.instantiate(&"ZN_FastNoiseLite")
	_mare_field.seed = MoonTerrainParams.SEED + 11
	_mare_field.period = MoonTerrainParams.meters_to_voxels(480.0)
	_mare_field.set("noise_type", 0)
	_mare_field.set("fractal_type", 1)
	_mare_field.fractal_octaves = 2
	_mare_field.fractal_lacunarity = 2.0
	_mare_field.fractal_gain = 0.32

	## Meso roughness on highlands only (not ridged mountains).
	_highland_rough = ClassDB.instantiate(&"ZN_FastNoiseLite")
	_highland_rough.seed = MoonTerrainParams.SEED + 41
	_highland_rough.period = MoonTerrainParams.meters_to_voxels(55.0)
	_highland_rough.set("noise_type", 0)
	_highland_rough.set("fractal_type", 1)
	_highland_rough.fractal_octaves = 3
	_highland_rough.fractal_gain = 0.42

	## Mid-scale surface texture (~13 m) — resolvable variety, no aliasing.
	_surface = ClassDB.instantiate(&"ZN_FastNoiseLite")
	_surface.seed = MoonTerrainParams.SEED + 73
	_surface.period = MoonTerrainParams.meters_to_voxels(20.0)
	_surface.set("noise_type", 0)
	_surface.set("fractal_type", 1)
	_surface.fractal_octaves = 2
	_surface.fractal_lacunarity = 2.0
	_surface.fractal_gain = 0.45

	## Fine crunch — kept at a RESOLVABLE period (~4.5 m), not sub-voxel.
	_regolith = ClassDB.instantiate(&"ZN_FastNoiseLite")
	_regolith.seed = MoonTerrainParams.SEED + 67
	_regolith.period = MoonTerrainParams.meters_to_voxels(4.5)
	_regolith.set("noise_type", 0)
	_regolith.set("fractal_type", 1)
	_regolith.fractal_octaves = 2
	_regolith.fractal_gain = 0.5

	_build_mare_regions()
	_rebuild_crater_index()


func _build_mare_regions() -> void:
	_mare_centers.clear()
	_mare_radii.clear()
	for i in MARE_COUNT:
		_mare_centers.append(_seed_dir(MoonTerrainParams.SEED + 801 + i * 53))
		_mare_radii.append(lerpf(0.30, 0.44, _hash01(MoonTerrainParams.SEED + 802 + i * 71)))


func _rebuild_crater_index() -> void:
	_craters.clear()
	_crater_cells.clear()
	_register_class(
		HUGE_CRATER_COUNT, MoonTerrainParams.SEED + 50, CLASS_HUGE,
		0.11, 0.20, MoonTerrainParams.CRATER_HUGE_AMP_M, 0.18
	)
	_register_class(
		LARGE_CRATER_COUNT, MoonTerrainParams.SEED + 100, CLASS_LARGE,
		0.040, 0.095, MoonTerrainParams.CRATER_LARGE_AMP_M, 0.16
	)
	_register_class(
		MED_CRATER_COUNT, MoonTerrainParams.SEED + 200, CLASS_MED,
		0.015, 0.044, MoonTerrainParams.CRATER_MED_AMP_M, 0.14
	)
	_register_class(
		SMALL_CRATER_COUNT, MoonTerrainParams.SEED + 300, CLASS_SMALL,
		0.005, 0.015, MoonTerrainParams.CRATER_SMALL_AMP_M, 0.12
	)


func _register_class(
	count: int,
	seed_base: int,
	class_id: int,
	rad_min: float,
	rad_max: float,
	depth_m: float,
	rim_frac: float
) -> void:
	for i in count:
		var center := _seed_dir(seed_base + i * 17)
		var u := _hash01(seed_base + i * 31)
		var rad := lerpf(rad_min, rad_max, u)
		var depth := depth_m * lerpf(0.82, 1.0, _hash01(seed_base + i * 47))
		var idx := _craters.size()
		_craters.append({
			"center": center,
			"rad": rad,
			"depth": depth,
			"rim_frac": rim_frac,
			"class": class_id,
			"seed": seed_base + i * 17,
		})
		var half := ceili(float(CRATER_GRID) * rad * 1.35) + 1
		var c0 := _dir_to_cell(center)
		for dz in range(-half, half + 1):
			for dy in range(-half, half + 1):
				for dx in range(-half, half + 1):
					var key := _cell_key(
						Vector3i(
							clampi(c0.x + dx, 0, CRATER_GRID - 1),
							clampi(c0.y + dy, 0, CRATER_GRID - 1),
							clampi(c0.z + dz, 0, CRATER_GRID - 1)
						)
					)
					if not _crater_cells.has(key):
						_crater_cells[key] = []
					(_crater_cells[key] as Array).append(idx)


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
	var mare := _mare_factor(domain)
	var highland := 1.0 - mare

	var h := lerpf(
		-MoonTerrainParams.MARIA_DEPTH_M,
		MoonTerrainParams.HIGHLAND_LIFT_M,
		highland
	)
	h += _highland_meso_roughness(domain, highland)
	h += _crater_field(n, mare, highland)
	h += _surface_texture(domain, mare, highland)
	return h


func _height_meters_map(n: Vector3) -> float:
	var domain := n * _radius_voxels
	var mare := _mare_factor(domain)
	var highland := 1.0 - mare
	var h := lerpf(
		-MoonTerrainParams.MARIA_DEPTH_M,
		MoonTerrainParams.HIGHLAND_LIFT_M,
		highland
	)
	h += _highland_meso_roughness(domain, highland) * 0.35
	h += _crater_field(n, mare, highland, CLASS_MED)
	return h


func _mare_factor(domain: Vector3) -> float:
	var n := domain / _radius_voxels
	var mare := 0.0
	for i in MARE_COUNT:
		var ang := acos(clampf(n.dot(_mare_centers[i] as Vector3), -1.0, 1.0))
		var rad: float = _mare_radii[i]
		var blob := 1.0 - smoothstep(rad * 0.62, rad * 0.94, ang)
		mare = maxf(mare, blob)
	if mare > 0.04:
		var warp := float(_mare_field.get_noise_3dv(domain * 0.85))
		mare = clampf(mare + warp * 0.12 * mare * (1.0 - mare), 0.0, 1.0)
	return pow(clampf(mare, 0.0, 1.0), 1.28)


func _highland_meso_roughness(domain: Vector3, highland: float) -> float:
	if highland < 0.08 or MoonTerrainParams.HIGHLAND_ROUGH_AMP_M <= 0.001:
		return 0.0
	var r := float(_highland_rough.get_noise_3dv(domain))
	return highland * r * MoonTerrainParams.HIGHLAND_ROUGH_AMP_M


func _surface_texture(domain: Vector3, _mare: float, highland: float) -> float:
	## Mid-band + fine crunch applied everywhere (gentler on maria) so the
	## surface reads as regolith terrain, not a smooth soap sphere. Periods are
	## kept above voxel/texel size so this adds variety without ribbing.
	var mid := float(_surface.get_noise_3dv(domain))
	var fine := float(_regolith.get_noise_3dv(domain))
	var mid_amp := lerpf(
		MoonTerrainParams.PLAINS_TEXTURE_M,
		MoonTerrainParams.SURFACE_TEXTURE_M,
		highland
	)
	var fine_amp := lerpf(
		MoonTerrainParams.MICRO_AMP_M * 0.45,
		MoonTerrainParams.MICRO_AMP_M,
		highland
	)
	return mid * mid_amp + fine * fine_amp


func _crater_field(
	n: Vector3, mare: float, highland: float, max_class: int = CLASS_SMALL
) -> float:
	var carve := 0.0
	var rim := 0.0
	var cell := _dir_to_cell(n)
	var seen: Dictionary = {}
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var key := _cell_key(
					Vector3i(
						clampi(cell.x + dx, 0, CRATER_GRID - 1),
						clampi(cell.y + dy, 0, CRATER_GRID - 1),
						clampi(cell.z + dz, 0, CRATER_GRID - 1)
					)
				)
				if not _crater_cells.has(key):
					continue
				for idx in _crater_cells[key] as Array:
					var ii := int(idx)
					if seen.has(ii):
						continue
					seen[ii] = true
					var crater: Dictionary = _craters[ii]
					var cclass: int = crater["class"]
					if cclass > max_class:
						continue
					var center: Vector3 = crater["center"]
					var rad: float = crater["rad"]
					var cos_a := clampf(n.dot(center), -1.0, 1.0)
					if cos_a < cos(rad * 1.35):
						continue
					var t := acos(cos_a) / rad
					var visibility := _crater_visibility(cclass, highland)
					visibility *= lerpf(1.0, 0.03, mare)
					if visibility <= 0.001:
						continue
					var d: float = crater["depth"] * visibility
					var rim_frac: float = crater["rim_frac"]
					var contrib := _crater_contribution(
						t, d, rim_frac, cclass, int(crater["seed"])
					)
					carve = minf(carve, contrib.x)
					rim = maxf(rim, contrib.y)
	return carve + rim


func _crater_visibility(cclass: int, highland: float) -> float:
	var base := lerpf(0.05, 1.0, highland)
	if cclass >= CLASS_MED:
		base *= lerpf(0.03, 1.0, highland)
	if cclass == CLASS_SMALL:
		base *= lerpf(0.08, 1.0, highland)
	return base


func _crater_contribution(
	t: float, d: float, rim_frac: float, cclass: int, crater_seed: int
) -> Vector2:
	var carve := 0.0
	var rim := 0.0

	# Interior bowl (flat floor + central peak on basin-scale impacts).
	if t < 1.0:
		if cclass <= CLASS_LARGE:
			var floor_depth := -d * 0.86
			if t < 0.38:
				if cclass == CLASS_HUGE and t < 0.26:
					## Broad, gentle central mound (not a narrow spike that aliases).
					var peak := exp(-pow(t / 0.19, 2.0))
					carve = floor_depth + d * 0.14 * peak
				else:
					carve = floor_depth
			else:
				var wall_t := (t - 0.38) / 0.62
				var bowl := 0.5 + 0.5 * cos(PI * wall_t)
				bowl = bowl * bowl
				carve = lerpf(floor_depth, 0.0, 1.0 - bowl)
		else:
			var bowl := 0.5 + 0.5 * cos(PI * t)
			bowl = bowl * bowl
			carve = -d * bowl

	# Raised rim — subtle jittered terraces on huge basins (fade toward floor & lip).
	if cclass == CLASS_HUGE:
		var terrace_env := smoothstep(0.42, 0.68, t) * smoothstep(1.06, 0.94, t)
		if terrace_env > 0.001:
			var step_count := 2
			for tier in step_count:
				var u0 := _hash01(crater_seed + tier * 113)
				var u1 := _hash01(crater_seed + tier * 197 + 3)
				var tc := lerpf(0.78, 0.98, u0) + (u1 - 0.5) * 0.04
				var tw := lerpf(0.028, 0.048, _hash01(crater_seed + tier * 311))
				var terr := exp(-pow((t - tc) / tw, 2.0))
				var amp := d * rim_frac * lerpf(0.06, 0.11, u1) * terrace_env
				rim = maxf(rim, amp * terr)
	else:
		var rim_w := lerpf(0.20, 0.15, float(cclass) / 3.0)
		var rim_bump := exp(-pow((t - 1.0) / rim_w, 2.0))
		rim = maxf(rim, d * rim_frac * rim_bump)

	# Ejecta blanket beyond the rim.
	if t > 0.88:
		var falloff := smoothstep(1.85, 0.92, t)
		falloff *= exp(-maxf(0.0, t - 1.0) * 1.6)
		var ej_amp := d * rim_frac * lerpf(0.42, 0.26, float(cclass) / 3.0)
		rim = maxf(rim, ej_amp * falloff)

	return Vector2(carve, rim)


func _dir_to_cell(n: Vector3) -> Vector3i:
	return Vector3i(
		clampi(floori((n.x * 0.5 + 0.5) * float(CRATER_GRID)), 0, CRATER_GRID - 1),
		clampi(floori((n.y * 0.5 + 0.5) * float(CRATER_GRID)), 0, CRATER_GRID - 1),
		clampi(floori((n.z * 0.5 + 0.5) * float(CRATER_GRID)), 0, CRATER_GRID - 1)
	)


func _cell_key(c: Vector3i) -> StringName:
	return StringName("%d,%d,%d" % [c.x, c.y, c.z])


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
