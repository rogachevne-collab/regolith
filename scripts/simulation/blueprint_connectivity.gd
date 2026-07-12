class_name BlueprintConnectivity
extends RefCounted


static func connected_components(
	blueprint: Blueprint
) -> Array[Array]:
	var adjacency: Array[Dictionary] = []
	for _placement: BlueprintElementPlacement in blueprint.placements:
		adjacency.append({})

	for left_index: int in range(blueprint.placements.size()):
		for right_index: int in range(
			left_index + 1,
			blueprint.placements.size()
		):
			if placements_have_rigid_connection(
				blueprint.placements[left_index],
				blueprint.placements[right_index]
			):
				adjacency[left_index][right_index] = true
				adjacency[right_index][left_index] = true

	var components: Array[Array] = []
	var visited: Dictionary = {}
	for start_index: int in range(blueprint.placements.size()):
		if visited.has(start_index):
			continue
		var component: Array = []
		var pending: Array[int] = [start_index]
		visited[start_index] = true
		while not pending.is_empty():
			var current: int = pending.pop_back()
			component.append(blueprint.placements[current].local_id)
			for neighbor: Variant in adjacency[current].keys():
				var neighbor_index: int = int(neighbor)
				if not visited.has(neighbor_index):
					visited[neighbor_index] = true
					pending.append(neighbor_index)
		component.sort()
		components.append(component)
	return components


static func placements_have_rigid_connection(
	left: BlueprintElementPlacement,
	right: BlueprintElementPlacement
) -> bool:
	if left == null or right == null:
		return false
	if left.archetype == null or right.archetype == null:
		return false
	if not _orientation_is_valid(left.orientation_index):
		return false
	if not _orientation_is_valid(right.orientation_index):
		return false

	for left_port: PortDefinition in left.archetype.ports:
		if not _is_structural_port(left_port):
			continue
		var left_cell: Vector3i = _world_port_cell(left, left_port)
		var left_direction: Vector3i = OrientationUtil.rotate_direction(
			OrientationUtil.face_to_vector(left_port.local_face),
			left.orientation_index
		)
		for right_port: PortDefinition in right.archetype.ports:
			if not _is_structural_port(right_port):
				continue
			if left_port.face_slot != right_port.face_slot:
				continue
			if not _tags_are_compatible(
				left_port.compatibility_tags,
				right_port.compatibility_tags
			):
				continue
			var right_cell: Vector3i = _world_port_cell(right, right_port)
			var right_direction: Vector3i = OrientationUtil.rotate_direction(
				OrientationUtil.face_to_vector(right_port.local_face),
				right.orientation_index
			)
			if (
				right_cell == left_cell + left_direction
				and right_direction == -left_direction
			):
				return true
	return false


static func _world_port_cell(
	placement: BlueprintElementPlacement,
	port: PortDefinition
) -> Vector3i:
	return (
		placement.origin_cell
		+ OrientationUtil.rotate_cell(
			port.local_cell,
			placement.orientation_index
		)
	)


static func _is_structural_port(port: PortDefinition) -> bool:
	return (
		port != null
		and port.kind == PortDefinition.Kind.MECHANICAL
		and port.compatibility_tags.has("structural")
	)


static func _tags_are_compatible(
	left_tags: PackedStringArray,
	right_tags: PackedStringArray
) -> bool:
	for tag: String in left_tags:
		if tag != "structural" and right_tags.has(tag):
			return true
	return (
		left_tags.has("structural")
		and right_tags.has("structural")
		and left_tags.size() == 1
		and right_tags.size() == 1
	)


static func _orientation_is_valid(index: int) -> bool:
	return index >= 0 and index < OrientationUtil.ORIENTATION_COUNT
