class_name CargoConnectivity
extends RefCounted

## Face-adjacent cargo port pairing within one assembly (undirected).


static func find_adjacent_cargo_edges(
	elements: Array[SimulationElement]
) -> Array[Dictionary]:
	var edges: Array[Dictionary] = []
	var sorted_elements: Array[SimulationElement] = elements.duplicate()
	sorted_elements.sort_custom(
		func(left: SimulationElement, right: SimulationElement) -> bool:
			return left.element_id < right.element_id
	)
	for left_index: int in range(sorted_elements.size()):
		for right_index: int in range(
			left_index + 1,
			sorted_elements.size()
		):
			var left: SimulationElement = sorted_elements[left_index]
			var right: SimulationElement = sorted_elements[right_index]
			if not left.is_operational() or not right.is_operational():
				continue
			var connection := _cargo_connection(left, right)
			if connection.is_empty():
				continue
			edges.append({
				"element_a": left.element_id,
				"port_a": connection["left_port_id"],
				"element_b": right.element_id,
				"port_b": connection["right_port_id"],
			})
	return edges


static func _cargo_connection(
	left: SimulationElement,
	right: SimulationElement
) -> Dictionary:
	var left_archetype: ElementArchetype = left.get_archetype()
	var right_archetype: ElementArchetype = right.get_archetype()
	if left_archetype == null or right_archetype == null:
		return {}
	for left_port: PortDefinition in left_archetype.ports:
		if not _is_cargo_port(left_port):
			continue
		for right_port: PortDefinition in right_archetype.ports:
			if not _is_cargo_port(right_port):
				continue
			if _ports_form_cargo_edge(left, left_port, right, right_port):
				return {
					"left_port_id": left_port.port_id,
					"right_port_id": right_port.port_id,
				}
	return {}


static func _ports_form_cargo_edge(
	left: SimulationElement,
	left_port: PortDefinition,
	right: SimulationElement,
	right_port: PortDefinition
) -> bool:
	if left_port.face_slot != right_port.face_slot:
		return false
	if not _cargo_tags_compatible(
		left_port.compatibility_tags,
		right_port.compatibility_tags
	):
		return false
	var left_cell: Vector3i = _element_port_cell(left, left_port)
	var left_direction: Vector3i = _element_port_direction(left, left_port)
	var right_cell: Vector3i = _element_port_cell(right, right_port)
	var right_direction: Vector3i = _element_port_direction(right, right_port)
	return (
		right_cell == left_cell + left_direction
		and right_direction == -left_direction
	)


static func _element_port_cell(
	element: SimulationElement,
	port: PortDefinition
) -> Vector3i:
	return (
		element.origin_cell
		+ OrientationUtil.rotate_cell(
			port.local_cell,
			element.orientation_index
		)
	)


static func _element_port_direction(
	element: SimulationElement,
	port: PortDefinition
) -> Vector3i:
	return OrientationUtil.rotate_direction(
		OrientationUtil.face_to_vector(port.local_face),
		element.orientation_index
	)


static func _is_cargo_port(port: PortDefinition) -> bool:
	return port != null and port.kind == PortDefinition.Kind.CARGO


static func _cargo_tags_compatible(
	left_tags: PackedStringArray,
	right_tags: PackedStringArray
) -> bool:
	if left_tags.is_empty() or right_tags.is_empty():
		return true
	for left_tag: String in left_tags:
		if right_tags.has(left_tag):
			return true
	return false
