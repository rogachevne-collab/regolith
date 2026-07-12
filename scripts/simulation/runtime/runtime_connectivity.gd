class_name RuntimeConnectivity
extends RefCounted


static func materialize_rigid_joints(
	assembly_id: int,
	elements: Array[SimulationElement],
	allocate_joint_id: Callable
) -> Array[SimulationJoint]:
	var joints: Array[SimulationJoint] = []
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
			var connection: Dictionary = _rigid_connection(left, right)
			if connection.is_empty():
				continue
			joints.append(
				SimulationJoint.rigid(
					int(allocate_joint_id.call()),
					assembly_id,
					left.element_id,
					str(connection["left_port_id"]),
					right.element_id,
					str(connection["right_port_id"])
				)
			)
	joints.sort_custom(_sort_joint)
	return joints


static func materialize_anchor_joints(
	assembly_id: int,
	elements: Array[SimulationElement],
	allocate_joint_id: Callable
) -> Array[SimulationJoint]:
	var joints: Array[SimulationJoint] = []
	for element: SimulationElement in elements:
		var archetype: ElementArchetype = element.get_archetype()
		if archetype == null:
			continue
		for port: PortDefinition in archetype.ports:
			if not _is_anchor_port(port):
				continue
			joints.append(
				SimulationJoint.anchor(
					int(allocate_joint_id.call()),
					assembly_id,
					element.element_id,
					port.port_id
				)
			)
	joints.sort_custom(_sort_joint)
	return joints


static func connected_components(
	element_ids: Array[int],
	elements_by_id: Dictionary,
	joints: Array[SimulationJoint]
) -> Array[Array]:
	var adjacency: Dictionary = {}
	for element_id: int in element_ids:
		adjacency[element_id] = {}

	for joint: SimulationJoint in joints:
		if joint.kind != SimulationJoint.Kind.RIGID:
			continue
		if (
			not adjacency.has(joint.element_a_id)
			or not adjacency.has(joint.element_b_id)
		):
			continue
		adjacency[joint.element_a_id][joint.element_b_id] = true
		adjacency[joint.element_b_id][joint.element_a_id] = true

	var sorted_starts: Array[int] = element_ids.duplicate()
	sorted_starts.sort()
	var components: Array[Array] = []
	var visited: Dictionary = {}
	for start_id: int in sorted_starts:
		if visited.has(start_id):
			continue
		var component: Array[int] = []
		var pending: Array[int] = [start_id]
		visited[start_id] = true
		while not pending.is_empty():
			var current: int = pending.pop_back()
			component.append(current)
			var neighbors: Array = adjacency[current].keys()
			neighbors.sort()
			for neighbor_variant: Variant in neighbors:
				var neighbor_id: int = int(neighbor_variant)
				if not visited.has(neighbor_id):
					visited[neighbor_id] = true
					pending.append(neighbor_id)
		component.sort()
		components.append(component)
	return components


static func elements_have_rigid_connection(
	left: SimulationElement,
	right: SimulationElement
) -> bool:
	return not _rigid_connection(left, right).is_empty()


static func validate_merge_connection(
	left: SimulationElement,
	left_port_id: String,
	right: SimulationElement,
	right_port_id: String
) -> bool:
	var left_port: PortDefinition = _find_port(left, left_port_id)
	var right_port: PortDefinition = _find_port(right, right_port_id)
	if left_port == null or right_port == null:
		return false
	return _ports_form_rigid_edge(left, left_port, right, right_port)


static func find_rigid_connection(
	left: SimulationElement,
	right: SimulationElement
) -> Dictionary:
	return _rigid_connection(left, right)


static func _rigid_connection(
	left: SimulationElement,
	right: SimulationElement
) -> Dictionary:
	var left_archetype: ElementArchetype = left.get_archetype()
	var right_archetype: ElementArchetype = right.get_archetype()
	if left_archetype == null or right_archetype == null:
		return {}

	for left_port: PortDefinition in left_archetype.ports:
		if not _is_structural_port(left_port):
			continue
		for right_port: PortDefinition in right_archetype.ports:
			if not _is_structural_port(right_port):
				continue
			if _ports_form_rigid_edge(left, left_port, right, right_port):
				return {
					"left_port_id": left_port.port_id,
					"right_port_id": right_port.port_id,
				}
	return {}


static func _ports_form_rigid_edge(
	left: SimulationElement,
	left_port: PortDefinition,
	right: SimulationElement,
	right_port: PortDefinition
) -> bool:
	if left_port.face_slot != right_port.face_slot:
		return false
	if not _tags_are_compatible(
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


static func _find_port(
	element: SimulationElement,
	port_id: String
) -> PortDefinition:
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null:
		return null
	for port: PortDefinition in archetype.ports:
		if port.port_id == port_id:
			return port
	return null


static func _is_structural_port(port: PortDefinition) -> bool:
	return (
		port != null
		and port.kind == PortDefinition.Kind.MECHANICAL
		and port.compatibility_tags.has("structural")
	)


static func _is_anchor_port(port: PortDefinition) -> bool:
	return (
		port != null
		and port.kind == PortDefinition.Kind.MECHANICAL
		and port.compatibility_tags.has("anchor")
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


static func _sort_joint(left: SimulationJoint, right: SimulationJoint) -> bool:
	if left.joint_id != right.joint_id:
		return left.joint_id < right.joint_id
	return left.canonical_key() < right.canonical_key()
