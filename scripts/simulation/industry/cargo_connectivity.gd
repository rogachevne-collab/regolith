class_name CargoConnectivity
extends RefCounted

## Face-adjacent cargo port pairing across operational elements (undirected).
## Edges are found by asking each cargo port "who occupies the cell in front of
## me?" — O(ports), not O(elements²).


static func find_adjacent_cargo_edges(
	elements: Array[SimulationElement]
) -> Array[Dictionary]:
	var by_id: Dictionary = {}
	var cell_owner: Dictionary = {}
	for element_variant: Variant in elements:
		var element: SimulationElement = element_variant
		if element == null or not element.is_operational():
			continue
		if not element_has_cargo_port(element):
			continue
		by_id[element.element_id] = element
		for cell: Vector3i in element.occupied_cells():
			cell_owner[cell] = element.element_id

	var edges: Array[Dictionary] = []
	var seen: Dictionary = {}
	for element_id_variant: Variant in by_id.keys():
		var element: SimulationElement = by_id[element_id_variant]
		var archetype: ElementArchetype = element.get_archetype()
		if archetype == null:
			continue
		for port: PortDefinition in archetype.ports:
			if not _is_cargo_port(port):
				continue
			var port_cell := _element_port_cell(element, port)
			var port_dir := _element_port_direction(element, port)
			var neighbor_id := int(cell_owner.get(port_cell + port_dir, 0))
			if neighbor_id <= 0 or neighbor_id == element.element_id:
				continue
			# Undirected: emit once per pair from the lower element id.
			if neighbor_id < element.element_id:
				continue
			var neighbor: SimulationElement = by_id.get(neighbor_id)
			if neighbor == null or not neighbor.is_operational():
				continue
			var neighbor_archetype: ElementArchetype = neighbor.get_archetype()
			if neighbor_archetype == null:
				continue
			for neighbor_port: PortDefinition in neighbor_archetype.ports:
				if not _is_cargo_port(neighbor_port):
					continue
				if not _ports_form_cargo_edge(
					element,
					port,
					neighbor,
					neighbor_port
				):
					continue
				var key := "%d|%s|%d|%s" % [
					element.element_id,
					port.port_id,
					neighbor_id,
					neighbor_port.port_id,
				]
				if seen.has(key):
					break
				seen[key] = true
				edges.append({
					"element_a": element.element_id,
					"port_a": port.port_id,
					"element_b": neighbor_id,
					"port_b": neighbor_port.port_id,
				})
				break
	return edges


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


static func element_has_cargo_port(element: SimulationElement) -> bool:
	if element == null:
		return false
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null:
		return false
	for port: PortDefinition in archetype.ports:
		if _is_cargo_port(port):
			return true
	return false


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
