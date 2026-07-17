class_name GridPoseUtil
extends RefCounted


static func grid_frame_to_transform(frame: GridTransform) -> Transform3D:
	var basis: Basis = OrientationUtil.orientation_basis(
		frame.orientation_index
	)
	return Transform3D(basis, GridMetric.cell_to_meters(frame.translation))


static func b_to_a_from_grid_frames(
	frame_a: GridTransform,
	frame_b: GridTransform
) -> GridTransform:
	return frame_a.inverse().compose(frame_b)


static func b_to_a_from_motion(
	motion_a: AssemblyMotionState,
	motion_b: AssemblyMotionState
) -> GridTransform:
	var result: Dictionary = GridAlignment.nearest_alignment(
		motion_a.transform,
		motion_b.transform
	)
	return result["grid_transform"]


static func snap_transform_to_grid(relative: Transform3D) -> GridTransform:
	var result: Dictionary = GridAlignment.nearest_alignment(
		Transform3D.IDENTITY,
		relative
	)
	return result["grid_transform"]


static func element_local_transform(
	origin_cell: Vector3i,
	orientation_index: int
) -> Transform3D:
	return Transform3D(
		OrientationUtil.orientation_basis(orientation_index),
		GridMetric.cell_to_meters(origin_cell)
	)


static func collider_local_transform(
	element_origin: Vector3i,
	element_orientation_index: int,
	collider: ColliderDefinition
) -> Transform3D:
	var basis := OrientationUtil.orientation_basis(element_orientation_index)
	var cell_center := element_cell_center(
		element_origin,
		collider.local_cell,
		element_orientation_index
	)
	# Cell topology rotates around integer cells; visual geometry rotates around
	# each cell center. Rotating offset_in_cell directly around origin makes a
	# 1x1x1 element orbit a corner whenever its orientation changes.
	var local_position := (
		cell_center
		+ basis * (
			collider.offset_in_cell - GridMetric.CELL_CENTER_OFFSET_M
		)
	)
	return Transform3D(basis, local_position)


static func element_cell_center(
	element_origin: Vector3i,
	local_cell: Vector3i,
	orientation_index: int
) -> Vector3:
	return GridMetric.cell_center_meters(
		element_origin
		+ OrientationUtil.rotate_cell(local_cell, orientation_index)
	)


static func collider_world_transform(
	assembly_world_transform: Transform3D,
	origin_cell: Vector3i,
	orientation_index: int,
	collider: ColliderDefinition
) -> Transform3D:
	return (
		assembly_world_transform
		* collider_local_transform(origin_cell, orientation_index, collider)
	)


static func collider_world_aabb(
	assembly_world_transform: Transform3D,
	origin_cell: Vector3i,
	orientation_index: int,
	collider: ColliderDefinition
) -> AABB:
	var world_transform: Transform3D = collider_world_transform(
		assembly_world_transform,
		origin_cell,
		orientation_index,
		collider
	)
	var half_extents: Vector3 = collider.aabb_half_extents()
	# Seed the box at the first corner: a default AABB() sits at the world
	# origin, and expand() would silently include (0,0,0) in every footprint —
	# harmless near the flat-map origin, catastrophic on the spherical moon.
	var bounds := AABB(world_transform * (-half_extents), Vector3.ZERO)
	for sx: int in [-1, 1]:
		for sy: int in [-1, 1]:
			for sz: int in [-1, 1]:
				bounds = bounds.expand(
					world_transform * Vector3(
						half_extents.x * sx,
						half_extents.y * sy,
						half_extents.z * sz
					)
				)
	return bounds


static func projected_element_collider_transforms(
	assembly_world_transform: Transform3D,
	origin_cell: Vector3i,
	orientation_index: int,
	archetype: ElementArchetype
) -> Array[Transform3D]:
	var transforms: Array[Transform3D] = []
	if archetype == null:
		return transforms
	for collider: ColliderDefinition in archetype.colliders:
		transforms.append(
			collider_world_transform(
				assembly_world_transform,
				origin_cell,
				orientation_index,
				collider
			)
		)
	return transforms


## Geometric center of `footprint_cells` in element-local space (assembly frame).
static func footprint_pivot_local(archetype: ElementArchetype) -> Vector3:
	if archetype == null or archetype.footprint_cells.is_empty():
		return GridMetric.CELL_CENTER_OFFSET_M
	var sum := Vector3.ZERO
	for local_cell: Vector3i in archetype.footprint_cells:
		sum += GridMetric.cell_center_meters(local_cell)
	return sum / float(archetype.footprint_cells.size())


## World footprint center for a placement plan root + element pose.
static func world_footprint_pivot(
	assembly_world_transform: Transform3D,
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> Vector3:
	return assembly_world_transform * oriented_footprint_pivot(
		archetype,
		origin_cell,
		orientation_index
	)


static func oriented_footprint_pivot(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> Vector3:
	if archetype == null or archetype.footprint_cells.is_empty():
		return element_cell_center(origin_cell, Vector3i.ZERO, orientation_index)
	var sum := Vector3.ZERO
	for local_cell: Vector3i in archetype.footprint_cells:
		sum += element_cell_center(origin_cell, local_cell, orientation_index)
	return sum / float(archetype.footprint_cells.size())


## Ground root that keeps `held_world_pivot` fixed while changing orientation.
static func ground_assembly_transform_pivot_hold(
	archetype: ElementArchetype,
	orientation_index: int,
	upright_basis: Basis,
	held_world_pivot: Vector3
) -> Transform3D:
	var pivot_offset := oriented_footprint_pivot(
		archetype,
		Vector3i.ZERO,
		orientation_index
	)
	return Transform3D(
		upright_basis,
		held_world_pivot - upright_basis * pivot_offset
	)


## Candidate integer origins for attach snap: pivot, snap, then neighborhood.
static func attach_origin_candidates(
	archetype: ElementArchetype,
	target_port_cell: Vector3i,
	snap_dir: Vector3i,
	orientation_index: int
) -> Array[Vector3i]:
	var primary := pivot_compensated_origin(
		archetype,
		target_port_cell,
		snap_dir,
		orientation_index
	)
	var snap := snap_origin_without_pivot(
		archetype,
		target_port_cell,
		snap_dir,
		orientation_index
	)
	var candidates: Array[Vector3i] = [primary, snap]
	if orientation_index == 0:
		return candidates
	var pivot_local := footprint_pivot_local(archetype)
	var ref_origin := snap_origin_without_pivot(
		archetype,
		target_port_cell,
		snap_dir,
		0
	)
	var ref_pivot := (
		GridMetric.cell_to_meters(ref_origin)
		+ OrientationUtil.orientation_basis(0) * pivot_local
	)
	var basis := OrientationUtil.orientation_basis(orientation_index)
	var corrected := ref_pivot - basis * pivot_local
	var pivot_origin := GridMetric.meters_to_cell_round(corrected)
	var seen: Dictionary = {primary: true, snap: true}
	for dx: int in range(-1, 2):
		for dy: int in range(-1, 2):
			for dz: int in range(-1, 2):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var neighbor := Vector3i(
					pivot_origin.x + dx,
					pivot_origin.y + dy,
					pivot_origin.z + dz
				)
				if seen.has(neighbor):
					continue
				seen[neighbor] = true
				candidates.append(neighbor)
	return candidates


## Lowest contact point on the gravity-up (+Y) face for ground seating.
static func ground_contact_local(
	archetype: ElementArchetype,
	orientation_index: int
) -> Vector3:
	if archetype == null or archetype.colliders.is_empty():
		return Vector3(
			GridMetric.HALF_CELL_SIZE_M,
			0.0,
			GridMetric.HALF_CELL_SIZE_M
		)
	var min_y := INF
	var bottom_points: Array[Vector3] = []
	for collider: ColliderDefinition in archetype.colliders:
		var local_transform: Transform3D = collider_local_transform(
			Vector3i.ZERO,
			orientation_index,
			collider
		)
		var half_extents: Vector3 = collider.aabb_half_extents()
		for sx: int in [-1, 1]:
			for sy: int in [-1, 1]:
				for sz: int in [-1, 1]:
					var corner: Vector3 = local_transform * Vector3(
						half_extents.x * sx,
						half_extents.y * sy,
						half_extents.z * sz
					)
					if corner.y < min_y - 0.0001:
						min_y = corner.y
						bottom_points.clear()
						bottom_points.append(corner)
					elif absf(corner.y - min_y) <= 0.0001:
						bottom_points.append(corner)
	if bottom_points.is_empty():
		return Vector3(
			GridMetric.HALF_CELL_SIZE_M,
			0.0,
			GridMetric.HALF_CELL_SIZE_M
		)
	var average := Vector3.ZERO
	for point: Vector3 in bottom_points:
		average += point
	return average / float(bottom_points.size())


## Integer origin aligned to the contacting structural port for this orientation.
static func snap_origin_without_pivot(
	archetype: ElementArchetype,
	target_port_cell: Vector3i,
	snap_dir: Vector3i,
	orientation_index: int
) -> Vector3i:
	return snap_origin_for_target_cell(
		archetype,
		target_port_cell,
		snap_dir,
		orientation_index
	)


## Single deterministic origin for the ray-selected target surface cell.
## One O(F) pass over placing-block faces; no candidate enumeration.
static func snap_origin_for_target_cell(
	archetype: ElementArchetype,
	target_port_cell: Vector3i,
	snap_dir: Vector3i,
	orientation_index: int
) -> Vector3i:
	if archetype == null:
		return target_port_cell + snap_dir
	var contact_cell := target_port_cell + snap_dir
	var required_dir: Vector3i = -snap_dir
	var best_origin := contact_cell
	var has_origin := false
	for descriptor: GridSurfaceUtil.SurfaceFaceDescriptor in (
		GridSurfaceUtil.get_surface_descriptors(archetype, orientation_index)
	):
		var world_dir: Vector3i = OrientationUtil.rotate_direction(
			OrientationUtil.face_to_vector(descriptor.local_face),
			orientation_index
		)
		if world_dir != required_dir:
			continue
		var origin := (
			contact_cell
			- OrientationUtil.rotate_cell(
				descriptor.local_cell,
				orientation_index
			)
		)
		if not has_origin or origin < best_origin:
			best_origin = origin
			has_origin = true
	if has_origin:
		return best_origin
	return contact_cell


## Origin that keeps the orientation-0 footprint pivot fixed while rotating.
static func pivot_compensated_origin(
	archetype: ElementArchetype,
	target_port_cell: Vector3i,
	snap_dir: Vector3i,
	orientation_index: int
) -> Vector3i:
	if orientation_index == 0:
		return snap_origin_without_pivot(
			archetype,
			target_port_cell,
			snap_dir,
			0
		)
	var pivot_local := footprint_pivot_local(archetype)
	var ref_origin := snap_origin_without_pivot(
		archetype,
		target_port_cell,
		snap_dir,
		0
	)
	var ref_pivot := (
		GridMetric.cell_to_meters(ref_origin)
		+ OrientationUtil.orientation_basis(0) * pivot_local
	)
	var basis := OrientationUtil.orientation_basis(orientation_index)
	var corrected := ref_pivot - basis * pivot_local
	return GridMetric.meters_to_cell_round(corrected)


## Snap origin with pivot compensation when the rotated pose still validates.
static func origin_cell_for_adjacent_snap(
	archetype: ElementArchetype,
	target_port_cell: Vector3i,
	snap_dir: Vector3i,
	orientation_index: int
) -> Vector3i:
	return pivot_compensated_origin(
		archetype,
		target_port_cell,
		snap_dir,
		orientation_index
	)


static func snap_origin_candidates(
	archetype: ElementArchetype,
	target_port_cell: Vector3i,
	snap_dir: Vector3i,
	orientation_index: int
) -> Array[Vector3i]:
	if archetype == null:
		return [target_port_cell + snap_dir]
	var required_dir: Vector3i = -snap_dir
	var origins: Array[Vector3i] = []
	var seen: Dictionary = {}
	for descriptor: GridSurfaceUtil.SurfaceFaceDescriptor in (
		GridSurfaceUtil.get_surface_descriptors(archetype, orientation_index)
	):
		var world_dir: Vector3i = OrientationUtil.rotate_direction(
			OrientationUtil.face_to_vector(descriptor.local_face),
			orientation_index
		)
		if world_dir != required_dir:
			continue
		var origin := (
			target_port_cell
			+ snap_dir
			- OrientationUtil.rotate_cell(
				descriptor.local_cell,
				orientation_index
			)
		)
		if seen.has(origin):
			continue
		seen[origin] = true
		origins.append(origin)
	if origins.is_empty():
		return [target_port_cell + snap_dir]
	origins.sort_custom(
		func(left: Vector3i, right: Vector3i) -> bool:
			if left != right:
				return left < right
			return false
	)
	return origins


static func target_face_center_local(
	target_port_cell: Vector3i,
	snap_dir: Vector3i
) -> Vector3:
	return (
		GridMetric.cell_center_meters(target_port_cell)
		+ Vector3(snap_dir) * GridMetric.HALF_CELL_SIZE_M
	)


static func contact_face_center_for_origin(
	origin_cell: Vector3i,
	archetype: ElementArchetype,
	snap_dir: Vector3i,
	orientation_index: int
) -> Vector3:
	var required_dir: Vector3i = -snap_dir
	var best_center := Vector3.ZERO
	var best_cell_length := 999999
	var best_descriptor_id := ""
	var found := false
	for descriptor: GridSurfaceUtil.SurfaceFaceDescriptor in (
		GridSurfaceUtil.get_surface_descriptors(archetype, orientation_index)
	):
		var world_dir: Vector3i = OrientationUtil.rotate_direction(
			OrientationUtil.face_to_vector(descriptor.local_face),
			orientation_index
		)
		if world_dir != required_dir:
			continue
		var world_cell := (
			origin_cell
			+ OrientationUtil.rotate_cell(
				descriptor.local_cell,
				orientation_index
			)
		)
		var center := (
			GridMetric.cell_center_meters(world_cell)
			+ Vector3(required_dir) * GridMetric.HALF_CELL_SIZE_M
		)
		var cell_length: int = descriptor.local_cell.length_squared()
		if (
			not found
			or cell_length < best_cell_length
			or (
				cell_length == best_cell_length
				and (
					best_descriptor_id.is_empty()
					or descriptor.structural_id < best_descriptor_id
				)
			)
		):
			found = true
			best_cell_length = cell_length
			best_descriptor_id = descriptor.structural_id
			best_center = center
	if found:
		return best_center
	return GridMetric.cell_center_meters(origin_cell)


