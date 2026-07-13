class_name TerrainImpactCarver
extends RefCounted

const MIN_RADIUS := 0.08
const MAX_RADIUS := 1.6


static func sphere_volume(radius: float) -> float:
	return (4.0 / 3.0) * PI * radius * radius * radius


static func base_radius_from_collider(collider: CollisionShape3D) -> float:
	if collider == null or collider.shape == null:
		return 0.35
	if collider.shape is BoxShape3D:
		var half: Vector3 = (collider.shape as BoxShape3D).size * 0.5
		var scaled := half * collider.global_transform.basis.get_scale().abs()
		return maxf(scaled.x, maxf(scaled.y, scaled.z))
	return 0.35


static func build_sphere_op(
	contact_world: Vector3,
	collider: CollisionShape3D,
	strength: float
) -> Dictionary:
	var clamped_strength := clampf(strength, 0.05, 1.0)
	var radius := clampf(
		base_radius_from_collider(collider) * (0.35 + 0.65 * clamped_strength),
		MIN_RADIUS,
		MAX_RADIUS
	)
	return {
		"stamp_kind": &"sphere",
		"center": contact_world,
		"radius": radius,
		"strength": clamped_strength,
	}


static func build_path_op(
	points: PackedVector3Array,
	radii: PackedFloat32Array,
	strength: float
) -> Dictionary:
	return {
		"stamp_kind": &"path",
		"points": points,
		"radii": radii,
		"strength": clampf(strength, 0.05, 1.0),
	}


static func apply(
	voxel_tool: VoxelTool,
	op: Dictionary,
	volume_budget_m3: float = INF
) -> float:
	if voxel_tool == null or op.is_empty():
		return 0.0
	voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
	voxel_tool.mode = VoxelTool.MODE_REMOVE
	voxel_tool.sdf_strength = float(op.get("strength", 1.0))
	var used_volume := 0.0
	match StringName(op.get("stamp_kind", &"")):
		&"sphere":
			var radius := float(op.get("radius", MIN_RADIUS))
			var volume := sphere_volume(radius)
			if used_volume + volume > volume_budget_m3:
				return 0.0
			voxel_tool.do_sphere(Vector3(op.get("center", Vector3.ZERO)), radius)
			return volume
		&"path":
			var points: PackedVector3Array = op.get("points", PackedVector3Array())
			var radii: PackedFloat32Array = op.get("radii", PackedFloat32Array())
			if points.is_empty() or radii.is_empty():
				return 0.0
			for index: int in range(points.size()):
				used_volume += sphere_volume(float(radii[index]))
			if used_volume > volume_budget_m3:
				return 0.0
			voxel_tool.do_path(points, radii)
			return used_volume
		_:
			return 0.0
