class_name MoonSphereGeneratorFactory
extends RefCounted

## Builds the moon voxel generator.
## v2+: height-based lunar SDF via MoonTerrainGenerator (VoxelGeneratorScript).
## Official planet approach: sdf = length(p) - (R + H(normalize(p))).
## See Voxel Tools Generators → Planet; docs/specs/MOON-EXPERIMENT-V0.md.


static func create(radius_voxels: float = MoonGeometry.radius_voxels()) -> VoxelGenerator:
	var generator := MoonTerrainGenerator.new()
	generator._radius_voxels = radius_voxels
	generator._setup_noise()
	return generator
