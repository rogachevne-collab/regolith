class_name TerrainImpactCarver
extends RefCounted

const MIN_RADIUS := 0.08
const MAX_RADIUS := 1.6
## Unit-cube SDF resolution; the stamp is scaled per collider, so a modest
## grid keeps the one-time bake cheap without visible faceting.
const MESH_STAMP_CELL_COUNT := 24
## Slight inflation so the stamp overlaps boundary voxels at scale 0.65.
const MESH_STAMP_INFLATE := 1.05

## Impulse craters stay local; sustained actuator drag may use larger stamps.
const IMPACT_MAX_RADIUS := 0.72
## Smallest stamp that still overlaps solid voxels on the terrain grid.
const MIN_RADIUS_VOXEL_FRACTION := 0.45

static var _unit_box_sdf: VoxelMeshSDF


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
	var reference_radius_m := IndustryArchetypeProfile.hand_drill_carve_radius_m()
	var depth := IndustryArchetypeProfile.hand_drill_bite_depth_m() * (
		radius / reference_radius_m
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


## Baked SDF of a unit cube, shared by every box-collider stamp; do_mesh
## orients and scales it through the stamp transform.
static func unit_box_mesh_sdf() -> VoxelMeshSDF:
	if _unit_box_sdf != null and _unit_box_sdf.is_baked():
		return _unit_box_sdf
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var mesh_sdf := VoxelMeshSDF.new()
	mesh_sdf.mesh = box
	mesh_sdf.cell_count = MESH_STAMP_CELL_COUNT
	mesh_sdf.margin_ratio = 0.25
	mesh_sdf.bake_mode = VoxelMeshSDF.BAKE_MODE_ACCURATE_PARTITIONED
	mesh_sdf.bake()
	if not mesh_sdf.is_baked():
		return null
	_unit_box_sdf = mesh_sdf
	return _unit_box_sdf


## Oriented bite: stamp the striker's box collider into the terrain with its
## world orientation, sunk past the contact along the carve direction. Falls
## back to empty when the collider is not a box or baking failed — caller
## uses the sphere op instead.
##
## Collider boxes are often smaller than one voxel (frame = 0.5 m, terrain
## scale 0.65). Like build_sphere_op, the stamp is floored to a measurable
## half-extent so MODE_REMOVE actually clears cells.
static func build_mesh_op(
	contact_world: Vector3,
	collider: CollisionShape3D,
	strength: float,
	carve_direction: Vector3 = Vector3.DOWN,
	terrain: Node3D = null,
	max_half_extent: float = IMPACT_MAX_RADIUS
) -> Dictionary:
	if collider == null or not collider.shape is BoxShape3D:
		return {}
	var mesh_sdf := unit_box_mesh_sdf()
	if mesh_sdf == null:
		return {}
	var clamped_strength := clampf(strength, 0.05, 1.0)
	var direction := carve_direction
	if direction.length_squared() <= VoxelSpaceUtil.EPSILON:
		direction = Vector3.DOWN
	else:
		direction = direction.normalized()
	var shape_scale := collider.global_transform.basis.get_scale().abs()
	var box_size: Vector3 = (
		(collider.shape as BoxShape3D).size * shape_scale * MESH_STAMP_INFLATE
	)
	if terrain != null:
		var floor_half := minimum_measurable_radius_m(terrain)
		var ceiling_half := minf(max_half_extent, MAX_RADIUS)
		var target_half := lerpf(floor_half, ceiling_half, clamped_strength)
		var min_axis := target_half * 2.0
		box_size = Vector3(
			maxf(box_size.x, min_axis),
			maxf(box_size.y, min_axis),
			maxf(box_size.z, min_axis)
		)
	var collider_basis := collider.global_transform.basis.orthonormalized()
	# Dig-side face half-extent: distance from box center to the face that
	# hits the surface along carve_direction.
	var dir_local := (collider_basis.inverse() * direction).abs()
	var support := 0.5 * (
		dir_local.x * box_size.x
		+ dir_local.y * box_size.y
		+ dir_local.z * box_size.z
	)
	var bite := bite_depth_for_radius(maxf(box_size.x, maxf(box_size.y, box_size.z)) * 0.5) * (
		0.4 + 0.6 * clamped_strength
	)
	if terrain != null:
		bite = maxf(bite, minimum_measurable_radius_m(terrain))
	# Keep the approach face near the contact while most of the oriented
	# volume goes below it — otherwise MODE_REMOVE only softens SDF and the
	# isosurface never opens a visible crater at scale 0.65.
	bite = clampf(bite, support * 0.85, support * 0.95)
	# Dig-side face at contact + bite*dir; approach face stays near contact.
	var center := contact_world - direction * (support - bite)
	var isolevel := 0.0
	if terrain != null:
		# Inflate the brush by ~half a voxel so the isosurface actually opens.
		isolevel = VoxelSpaceUtil.world_distance_to_local(
			terrain,
			minimum_measurable_radius_m(terrain) * 0.5
		)
	return {
		"stamp_kind": &"mesh",
		"mesh_sdf": mesh_sdf,
		"transform": Transform3D(
			collider_basis * Basis.from_scale(box_size),
			center
		),
		"isolevel": isolevel,
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
