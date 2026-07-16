class_name MoonSphereGeneratorFactory
extends RefCounted

## Builds a VoxelGeneratorGraph planet SDF via the official VoxelGraphFunction API.
## Radius is in local voxel units (terrain node scale applied by the node transform).
## Changelog: SdfSphere.radius is a default input (index 3), not a param.


static func create(radius_voxels: float = MoonGeometry.radius_voxels()) -> VoxelGeneratorGraph:
	var generator := VoxelGeneratorGraph.new()
	var graph: VoxelGraphFunction = generator.get_main_function()
	graph.clear()

	var input_x := graph.create_node(
		VoxelGraphFunction.NODE_INPUT_X,
		Vector2(0.0, 0.0)
	)
	var input_y := graph.create_node(
		VoxelGraphFunction.NODE_INPUT_Y,
		Vector2(0.0, 80.0)
	)
	var input_z := graph.create_node(
		VoxelGraphFunction.NODE_INPUT_Z,
		Vector2(0.0, 160.0)
	)
	var sphere := graph.create_node(
		VoxelGraphFunction.NODE_SDF_SPHERE,
		Vector2(240.0, 80.0)
	)
	var output_sdf := graph.create_node(
		VoxelGraphFunction.NODE_OUTPUT_SDF,
		Vector2(480.0, 80.0)
	)

	graph.set_node_name(sphere, &"moon_sphere")
	graph.set_node_default_input(sphere, 3, radius_voxels)
	graph.add_connection(input_x, 0, sphere, 0)
	graph.add_connection(input_y, 0, sphere, 1)
	graph.add_connection(input_z, 0, sphere, 2)
	graph.add_connection(sphere, 0, output_sdf, 0)

	var compile_result: Dictionary = generator.compile()
	if not bool(compile_result.get("success", false)):
		push_error(
			"MoonSphereGeneratorFactory: compile failed: %s"
			% str(compile_result)
		)
	return generator
