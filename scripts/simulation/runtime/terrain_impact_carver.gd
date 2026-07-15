class_name TerrainImpactCarver
extends RefCounted

const MIN_RADIUS := 0.08
const MAX_RADIUS := 1.6
## Impulse craters stay local; sustained actuator drag may use larger stamps.
const IMPACT_MAX_RADIUS := 0.72
## Smallest stamp that still overlaps solid voxels on the terrain grid.
const MIN_RADIUS_VOXEL_FRACTION := 0.45


static func minimum_measurable_radius_m(terrain: Node3D) -> float:
	var voxel_size := VoxelSpaceUtil.voxel_size_m(terrain)
	return maxf(
		voxel_size * MIN_RADIUS_VOXEL_FRACTION,
		MIN_RADIUS
	)


static func maximum_inward_offset_m(radius: float) -> float:
	# Sphere top must reach the contact (surface kiss). When inward >= radius the
	# stamp sits entirely below the contact and only nicks boundary voxels.
	return radius * 0.92


static func minimum_inward_offset_m(terrain: Node3D, radius: float) -> float:
	var voxel_size := VoxelSpaceUtil.voxel_size_m(terrain)
	return minf(
		maxf(
			radius - bite_depth_for_radius(radius),
			voxel_size * 0.5
		),
		maximum_inward_offset_m(radius)
	)


static func bite_depth_for_radius(radius: float) -> float:
	var reference := IndustryArchetypeProfile.hand_drill_carve_radius_m()
	var depth := IndustryArchetypeProfile.hand_drill_bite_depth_m() * (
		radius / reference
	)
	return clampf(depth, 0.05, radius * 0.72)


static func bite_center(
	contact_world: Vector3,
	radius: float,
	carve_direction: Vector3,
	terrain: Node3D = null
) -> Vector3:
	var direction := carve_direction
	if direction.length_squared() <= VoxelSpaceUtil.EPSILON:
		direction = Vector3.DOWN
	else:
		direction = direction.normalized()
	var inward := radius - bite_depth_for_radius(radius)
	if terrain != null:
		inward = maxf(inward, minimum_inward_offset_m(terrain, radius))
	inward = minf(inward, maximum_inward_offset_m(radius))
	return contact_world + direction * inward


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
	strength: float,
	terrain: Node3D = null,
	carve_direction: Vector3 = Vector3.DOWN,
	max_radius: float = MAX_RADIUS
) -> Dictionary:
	var clamped_strength := clampf(strength, 0.05, 1.0)
	var collider_base := base_radius_from_collider(collider)
	var scaled := collider_base * (0.35 + 0.65 * clamped_strength)
	var radius := clampf(
		scaled,
		MIN_RADIUS,
		minf(max_radius, MAX_RADIUS)
	)
	if terrain != null:
		var floor_radius := minimum_measurable_radius_m(terrain)
		var ceiling := minf(max_radius, MAX_RADIUS)
		radius = clampf(
			maxf(radius, lerpf(floor_radius, ceiling, clamped_strength)),
			floor_radius,
			ceiling
		)
	return {
		"stamp_kind": &"sphere",
		"center": bite_center(
			contact_world,
			radius,
			carve_direction,
			terrain
		),
		"radius": radius,
		"strength": clamped_strength,
	}


static func build_path_op(
	points: PackedVector3Array,
	radii: PackedFloat32Array,
	strength: float,
	terrain: Node3D = null,
	carve_direction: Vector3 = Vector3.DOWN
) -> Dictionary:
	var min_radius := MIN_RADIUS
	if terrain != null:
		min_radius = minimum_measurable_radius_m(terrain)
	var adjusted_points := PackedVector3Array()
	var adjusted_radii := PackedFloat32Array()
	for index: int in range(points.size()):
		var radius := maxf(float(radii[index]), min_radius)
		adjusted_points.append(
			bite_center(points[index], radius, carve_direction, terrain)
		)
		adjusted_radii.append(radius)
	return {
		"stamp_kind": &"path",
		"points": adjusted_points,
		"radii": adjusted_radii,
		"strength": clampf(strength, 0.05, 1.0),
	}
