class_name MoonSpherePlainGenerator
extends VoxelGeneratorScript

## Cheap play fallback: plain SDF sphere (no crater loops).
## Surface detail must come from baked RegionFiles; this only fills gaps.

const CHANNEL := VoxelBuffer.CHANNEL_SDF

var _radius_voxels: float = MoonGeometry.radius_voxels()


func _get_used_channels_mask() -> int:
	return 1 << CHANNEL


func _generate_block(
	out_buffer: VoxelBuffer,
	origin_in_voxels: Vector3i,
	lod: int
) -> void:
	var size: Vector3i = out_buffer.get_size()
	var stride := 1 << lod
	var origin := Vector3(origin_in_voxels)
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var p := origin + Vector3(x * stride, y * stride, z * stride)
				out_buffer.set_voxel_f(p.length() - _radius_voxels, x, y, z, CHANNEL)
