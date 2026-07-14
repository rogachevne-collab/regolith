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


static func materialize_ground_start_anchors(
	assembly_id: int,
	elements: Array[SimulationElement],
	allocate_joint_id: Callable
) -> Array[SimulationJoint]:
	var joints := materialize_anchor_joints(
		assembly_id,
		elements,
		allocate_joint_id
	)
	if not joints.is_empty():
		return joints
	for element: SimulationElement in elements:
		var port_id := ground_anchor_port_id(element)
		if port_id.is_empty():
			continue
		joints.append(
			SimulationJoint.anchor(
				int(allocate_joint_id.call()),
				assembly_id,
				element.element_id,
				port_id
			)
		)
	joints.sort_custom(_sort_joint)
	return joints


static func reconcile_terrain_anchors(
	assembly_id: int,
	elements: Array[SimulationElement],
	assembly_joints: Array[SimulationJoint],
	touching_element_ids: Array[int],
	allocate_joint_id: Callable
) -> Dictionary:
	var touching: Dictionary = {}
	for element_id: int in touching_element_ids:
		touching[element_id] = true
	var removed_joint_ids: Array[int] = []
	var added_joints: Array[SimulationJoint] = []
	var retained_anchor_elements: Dictionary = {}
	for joint: SimulationJoint in assembly_joints:
		if joint.kind != SimulationJoint.Kind.ANCHOR:
			continue
		if touching.has(joint.element_a_id):
			retained_anchor_elements[joint.element_a_id] = joint
			continue
		if not TerrainAnchorProbe.is_construction_archetype(
			_elements_archetype_id(elements, joint.element_a_id)
		):
			retained_anchor_elements[joint.element_a_id] = joint
			continue
		removed_joint_ids.append(joint.joint_id)
	for element: SimulationElement in elements:
		if not touching.has(element.element_id):
			continue
		if retained_anchor_elements.has(element.element_id):
			continue
		var port_id := ground_anchor_port_id(element)
		if port_id.is_empty():
			continue
		added_joints.append(
			SimulationJoint.anchor(
				int(allocate_joint_id.call()),
				assembly_id,
				element.element_id,
				port_id
			)
		)
	removed_joint_ids.sort()
	added_joints.sort_custom(_sort_joint)
	return {
		"removed_joint_ids": removed_joint_ids,
		"added_joints": added_joints,
	}


static func _elements_archetype_id(
	elements: Array[SimulationElement],
	element_id: int
) -> String:
	for element: SimulationElement in elements:
		if element.element_id == element_id:
			return element.archetype_id
	return ""


static func ground_anchor_port_id(element: SimulationElement) -> String:
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null:
		return ""
	for port: PortDefinition in archetype.ports:
		if _is_anchor_port(port):
			return port.port_id
	var derived_id := GridSurfaceUtil.ground_anchor_structural_id(element)
	if not derived_id.is_empty():
		return derived_id
	for port: PortDefinition in archetype.ports:
		if (
			port != null
			and port.kind == PortDefinition.Kind.MECHANICAL
			and port.compatibility_tags.has("structural")
			and port.local_face == OrientationUtil.Face.NEG_Y
		):
			return port.port_id
	return ""


static func connected_components(
	element_ids: Array[int],
	elements_by_id: Dictionary,
	joints: Array[SimulationJoint]
) -> Array[Array]:
	return rigid_connected_components(element_ids, elements_by_id, joints)


static func rigid_connected_components(
	element_ids: Array[int],
	elements_by_id: Dictionary,
	joints: Array[SimulationJoint]
) -> Array[Array]:
	return _connected_components(element_ids, joints, [SimulationJoint.Kind.RIGID])


static func mechanical_connected_components(
	element_ids: Array[int],
	elements_by_id: Dictionary,
	joints: Array[SimulationJoint]
) -> Array[Array]:
	return _connected_components(
		element_ids,
		joints,
		[SimulationJoint.Kind.RIGID, SimulationJoint.Kind.PISTON]
	)


static func _connected_components(
	element_ids: Array[int],
	joints: Array[SimulationJoint],
	kinds: Array
) -> Array[Array]:
	var adjacency: Dictionary = {}
	for element_id: int in element_ids:
		adjacency[element_id] = {}

	for joint: SimulationJoint in joints:
		if not kinds.has(joint.kind):
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
	return GridSurfaceUtil.validate_rigid_connection(
		left,
		left_port_id,
		right,
		right_port_id
	)


static func find_rigid_connection(
	left: SimulationElement,
	right: SimulationElement
) -> Dictionary:
	return _rigid_connection(left, right)


static func _rigid_connection(
	left: SimulationElement,
	right: SimulationElement
) -> Dictionary:
	return GridSurfaceUtil.find_rigid_connection(left, right)


static func _is_anchor_port(port: PortDefinition) -> bool:
	return (
		port != null
		and port.kind == PortDefinition.Kind.MECHANICAL
		and port.compatibility_tags.has("anchor")
	)


static func _sort_joint(left: SimulationJoint, right: SimulationJoint) -> bool:
	if left.joint_id != right.joint_id:
		return left.joint_id < right.joint_id
	return left.canonical_key() < right.canonical_key()
