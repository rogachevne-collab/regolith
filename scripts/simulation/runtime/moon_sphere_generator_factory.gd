class_name MoonSphereGeneratorFactory
extends RefCounted

## Official Voxel Tools planet generator (Generators → Planet):
## VoxelGeneratorGraph = SdfSphere + height noise on sphere-projected coords.
## https://voxel-tools.readthedocs.io/en/latest/generators/
##
## Tune in editor: res://resources/moon_planet_generator.tres (graph UI),
## or pass settings Dictionary into create_planet_graph().

const _HQ := preload("res://scripts/simulation/runtime/moon_terrain_generator.gd")
const _PLAIN := preload("res://scripts/simulation/runtime/moon_sphere_plain_generator.gd")
const _Params := preload("res://scripts/simulation/runtime/moon_terrain_params.gd")

## Defaults match resources/moon_planet_generator.tres
const DEFAULT_HEIGHT_AMP_M := 22.0
const DEFAULT_NOISE_PERIOD_M := 95.0


static func create(radius_voxels: float = MoonGeometry.radius_voxels()) -> VoxelGenerator:
	return create_play(radius_voxels)


static func create_hq(radius_voxels: float = MoonGeometry.radius_voxels()) -> VoxelGenerator:
	## Legacy GDScript crater sampler (space shot / offline only).
	var generator = _HQ.new()
	generator._radius_voxels = radius_voxels
	generator._setup_noise()
	return generator


static func create_play_fallback(
	radius_voxels: float = MoonGeometry.radius_voxels()
) -> VoxelGenerator:
	var generator = _PLAIN.new()
	generator._radius_voxels = radius_voxels
	return generator


static func create_play(
	radius_voxels: float = MoonGeometry.radius_voxels(),
	settings: Dictionary = {}
) -> VoxelGenerator:
	return create_planet_graph(radius_voxels, settings)


static func create_play_heightmap(
	radius_voxels: float = MoonGeometry.radius_voxels(),
	height_image: Image = null,
	height_factor: float = 1.0
) -> VoxelGenerator:
	## Native C++ spherical heightmap: sd = (|p| - radius) - factor * image(dir).
	## Image red is height in local voxel units baked by MoonHeightmapUtil
	## (its bake uses the node's own panorama projection, so play == bake).
	if height_image == null or height_image.get_width() <= 0:
		push_error("create_play_heightmap: missing height image; using plain sphere")
		return create_play_fallback(radius_voxels)

	var generator := VoxelGeneratorGraph.new()
	var graph: VoxelGraphFunction = generator.get_main_function()
	graph.clear()

	var in_x := graph.create_node(VoxelGraphFunction.NODE_INPUT_X, Vector2(0, 0))
	var in_y := graph.create_node(VoxelGraphFunction.NODE_INPUT_Y, Vector2(0, 40))
	var in_z := graph.create_node(VoxelGraphFunction.NODE_INPUT_Z, Vector2(0, 80))

	var hm := graph.create_node(
		VoxelGraphFunction.NODE_SDF_SPHERE_HEIGHTMAP, Vector2(240, 40)
	)
	graph.set_node_name(hm, &"sdf_sphere_heightmap")
	graph.add_connection(in_x, 0, hm, 0)
	graph.add_connection(in_y, 0, hm, 1)
	graph.add_connection(in_z, 0, hm, 2)
	## Params (Voxel Tools 1.6 image.h): 0=image, 1=radius, 2=factor.
	graph.set_node_param(hm, 0, height_image)
	graph.set_node_param(hm, 1, radius_voxels)
	graph.set_node_param(hm, 2, height_factor)

	var out_sdf := graph.create_node(VoxelGraphFunction.NODE_OUTPUT_SDF, Vector2(480, 40))
	graph.add_connection(hm, 0, out_sdf, 0)

	var compile_result: Dictionary = generator.compile()
	if not bool(compile_result.get("success", false)):
		push_error("Moon heightmap graph compile failed: %s" % str(compile_result))
		return create_play_fallback(radius_voxels)

	generator.use_subdivision = true
	generator.subdivision_size = 8
	generator.use_optimized_execution_map = true
	print(
		"MoonSphereGeneratorFactory: heightmap graph R=%.1f img=%dx%d factor=%.2f"
		% [
			radius_voxels,
			height_image.get_width(),
			height_image.get_height(),
			height_factor,
		]
	)
	return generator


static func create_planet_graph(
	radius_voxels: float = MoonGeometry.radius_voxels(),
	settings: Dictionary = {}
) -> VoxelGenerator:
	## Docs: SdfSphere, then height-based noise on projected sphere coords.
	## sdf = SdfSphere(p, R) - height(normalize(p))
	var amp_m: float = float(settings.get("height_amp_m", DEFAULT_HEIGHT_AMP_M))
	var period_m: float = float(settings.get("noise_period_m", DEFAULT_NOISE_PERIOD_M))
	var noise_seed: int = int(settings.get("noise_seed", _Params.SEED + 17))
	var fractal_type: int = int(settings.get("fractal_type", 2))
	var octaves: int = int(settings.get("octaves", 4))
	var carve_eroded: bool = bool(settings.get("carve_eroded", true))
	var signed_amp := _Params.meters_to_voxels(amp_m)
	if carve_eroded:
		signed_amp = -signed_amp

	var generator := VoxelGeneratorGraph.new()
	var graph: VoxelGraphFunction = generator.get_main_function()
	graph.clear()

	var in_x := graph.create_node(VoxelGraphFunction.NODE_INPUT_X, Vector2(0, 0))
	var in_y := graph.create_node(VoxelGraphFunction.NODE_INPUT_Y, Vector2(0, 40))
	var in_z := graph.create_node(VoxelGraphFunction.NODE_INPUT_Z, Vector2(0, 80))

	var radius_c := graph.create_node(VoxelGraphFunction.NODE_CONSTANT, Vector2(0, 140))
	graph.set_node_param(radius_c, 0, radius_voxels)

	var sphere := graph.create_node(VoxelGraphFunction.NODE_SDF_SPHERE, Vector2(220, 40))
	graph.set_node_name(sphere, &"sdf_sphere")
	graph.add_connection(in_x, 0, sphere, 0)
	graph.add_connection(in_y, 0, sphere, 1)
	graph.add_connection(in_z, 0, sphere, 2)
	graph.add_connection(radius_c, 0, sphere, 3)

	var norm := graph.create_node(VoxelGraphFunction.NODE_NORMALIZE_3D, Vector2(220, 160))
	graph.add_connection(in_x, 0, norm, 0)
	graph.add_connection(in_y, 0, norm, 1)
	graph.add_connection(in_z, 0, norm, 2)

	var dom_x := graph.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(400, 120))
	var dom_y := graph.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(400, 180))
	var dom_z := graph.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(400, 240))
	graph.add_connection(norm, 0, dom_x, 0)
	graph.add_connection(radius_c, 0, dom_x, 1)
	graph.add_connection(norm, 1, dom_y, 0)
	graph.add_connection(radius_c, 0, dom_y, 1)
	graph.add_connection(norm, 2, dom_z, 0)
	graph.add_connection(radius_c, 0, dom_z, 1)

	var noise_n := graph.create_node(VoxelGraphFunction.NODE_FAST_NOISE_3D, Vector2(580, 160))
	var noise: RefCounted = ClassDB.instantiate(&"ZN_FastNoiseLite")
	noise.set("seed", noise_seed)
	noise.set("period", _Params.meters_to_voxels(period_m))
	noise.set("noise_type", 0)
	noise.set("fractal_type", fractal_type)
	noise.set("fractal_octaves", octaves)
	noise.set("fractal_lacunarity", 2.0)
	noise.set("fractal_gain", 0.5)
	graph.set_node_param(noise_n, 0, noise)
	graph.add_connection(dom_x, 0, noise_n, 0)
	graph.add_connection(dom_y, 0, noise_n, 1)
	graph.add_connection(dom_z, 0, noise_n, 2)

	var amp_c := graph.create_node(VoxelGraphFunction.NODE_CONSTANT, Vector2(580, 280))
	graph.set_node_param(amp_c, 0, signed_amp)

	var height := graph.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(760, 200))
	graph.add_connection(noise_n, 0, height, 0)
	graph.add_connection(amp_c, 0, height, 1)

	var sub := graph.create_node(VoxelGraphFunction.NODE_SUBTRACT, Vector2(940, 80))
	graph.add_connection(sphere, 0, sub, 0)
	graph.add_connection(height, 0, sub, 1)

	var out_sdf := graph.create_node(VoxelGraphFunction.NODE_OUTPUT_SDF, Vector2(1120, 80))
	graph.add_connection(sub, 0, out_sdf, 0)

	var compile_result: Dictionary = generator.compile()
	if not bool(compile_result.get("success", false)):
		push_error("Moon planet graph compile failed: %s" % str(compile_result))
		return create_play_fallback(radius_voxels)

	generator.use_subdivision = true
	generator.subdivision_size = 8
	generator.use_optimized_execution_map = true
	print(
		(
			"MoonSphereGeneratorFactory: planet graph R=%.1f amp=%.1fm period=%.0fm "
			+ "fractal=%d oct=%d eroded=%s"
		)
		% [radius_voxels, amp_m, period_m, fractal_type, octaves, str(carve_eroded)]
	)
	return generator
