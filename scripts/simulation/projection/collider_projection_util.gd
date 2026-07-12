class_name ColliderProjectionUtil
extends RefCounted


static func assembly_dry_mass(
	world,
	assembly: SimulationAssembly
) -> float:
	var total := 0.0
	for element_id: int in assembly.element_ids:
		var element: SimulationElement = world.get_element(element_id)
		if element != null:
			total += element.dry_mass_kg()
	return total


static func assembly_center_of_mass_local(
	world,
	assembly: SimulationAssembly
) -> Vector3:
	var total_mass := 0.0
	var weighted := Vector3.ZERO
	for element_id: int in assembly.element_ids:
		var element: SimulationElement = world.get_element(element_id)
		if element == null:
			continue
		var mass: float = element.dry_mass_kg()
		total_mass += mass
		weighted += element_center_of_mass_local(element) * mass
	if total_mass <= 0.0:
		return Vector3.ZERO
	return weighted / total_mass


static func element_center_of_mass_local(
	element: SimulationElement
) -> Vector3:
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null or archetype.colliders.is_empty():
		return Vector3(element.origin_cell)
	var weighted := Vector3.ZERO
	var total_volume := 0.0
	for collider: ColliderDefinition in archetype.colliders:
		if collider.shape_kind != ColliderDefinition.ShapeKind.BOX:
			continue
		var volume: float = (
			collider.size.x * collider.size.y * collider.size.z
		)
		if volume <= 0.0:
			continue
		var local_transform: Transform3D = (
			GridPoseUtil.collider_local_transform(
				element.origin_cell,
				element.orientation_index,
				collider
			)
		)
		weighted += local_transform.origin * volume
		total_volume += volume
	if total_volume <= 0.0:
		return Vector3(element.origin_cell)
	return weighted / total_volume


static func assembly_center_of_mass_world(
	world,
	assembly: SimulationAssembly
) -> Vector3:
	var local_com: Vector3 = assembly_center_of_mass_local(world, assembly)
	return assembly.motion.transform * local_com


static func build_collision_shapes(
	world,
	assembly: SimulationAssembly
) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for element_id: int in assembly.element_ids:
		var element: SimulationElement = world.get_element(element_id)
		if element == null:
			continue
		var archetype: ElementArchetype = element.get_archetype()
		if archetype == null:
			continue
		for collider: ColliderDefinition in archetype.colliders:
			if collider.shape_kind != ColliderDefinition.ShapeKind.BOX:
				continue
			var shape := BoxShape3D.new()
			shape.size = collider.size
			var local_transform: Transform3D = (
				GridPoseUtil.collider_local_transform(
					element.origin_cell,
					element.orientation_index,
					collider
				)
			)
			records.append({
				"element_id": element_id,
				"shape": shape,
				"local_transform": local_transform,
			})
	return records


static func estimate_inertia_diagonal(
	mass_kg: float,
	collision_records: Array[Dictionary],
	center_of_mass_local: Vector3 = Vector3.ZERO
) -> Vector3:
	if collision_records.is_empty():
		return Vector3.ONE * maxf(mass_kg, 0.001)
	var min_point := Vector3(INF, INF, INF)
	var max_point := Vector3(-INF, -INF, -INF)
	for record: Dictionary in collision_records:
		var shape: BoxShape3D = record["shape"]
		var local_transform: Transform3D = record["local_transform"]
		var half: Vector3 = shape.size * 0.5
		for corner: Vector3 in _box_corners(local_transform, half):
			min_point = min_point.min(corner)
			max_point = max_point.max(corner)
	var size: Vector3 = max_point - min_point
	var box_center: Vector3 = (min_point + max_point) * 0.5
	var offset: Vector3 = box_center - center_of_mass_local
	var diagonal := Vector3(
		mass_kg * (size.y * size.y + size.z * size.z) / 12.0,
		mass_kg * (size.x * size.x + size.z * size.z) / 12.0,
		mass_kg * (size.x * size.x + size.y * size.y) / 12.0
	)
	diagonal += mass_kg * Vector3(
		offset.y * offset.y + offset.z * offset.z,
		offset.x * offset.x + offset.z * offset.z,
		offset.x * offset.x + offset.y * offset.y
	)
	return diagonal.max(Vector3.ONE * 0.001)


static func _box_corners(
	local_transform: Transform3D,
	half_extents: Vector3
) -> Array[Vector3]:
	var corners: Array[Vector3] = []
	for sx: int in [-1, 1]:
		for sy: int in [-1, 1]:
			for sz: int in [-1, 1]:
				corners.append(
					local_transform * Vector3(
						half_extents.x * sx,
						half_extents.y * sy,
						half_extents.z * sz
					)
				)
	return corners
