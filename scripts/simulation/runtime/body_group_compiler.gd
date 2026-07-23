class_name BodyGroupCompiler
extends RefCounted

const MAX_DRIVEN_JOINTS_ON_PATH := 16

static func compile(
	element_ids: Array[int],
	elements_by_id: Dictionary,
	joints: Array[SimulationJoint]
) -> Dictionary:
	# Suspension↔wheel RIGID joints do not glue rigid groups: the wheel is a
	# real body on a 6DOF constraint (WHEEL-BODY-V1). The sim joint stays RIGID
	# (snapshots, composer, placement untouched); only the partition changes.
	var wheel_joints: Array[SimulationJoint] = []
	var glue_joints: Array[SimulationJoint] = []
	for joint: SimulationJoint in joints:
		if _is_wheel_pair_joint(joint, elements_by_id):
			wheel_joints.append(joint)
		else:
			glue_joints.append(joint)
	var rigid_components := RuntimeConnectivity.rigid_connected_components(
		element_ids,
		elements_by_id,
		glue_joints
	)
	var groups: Dictionary = {}
	var element_to_group: Dictionary = {}
	for component: Array in rigid_components:
		var group_id := _component_group_id(component)
		groups[group_id] = component.duplicate()
		for element_id: int in component:
			element_to_group[element_id] = group_id

	var wheel_specs: Array[Dictionary] = []
	for joint: SimulationJoint in wheel_joints:
		var suspension_id := joint.element_a_id
		var wheel_id := joint.element_b_id
		var suspension: SimulationElement = elements_by_id.get(suspension_id)
		if suspension == null or not _is_suspension(suspension):
			suspension_id = joint.element_b_id
			wheel_id = joint.element_a_id
		var suspension_group := int(element_to_group.get(suspension_id, 0))
		var wheel_group := int(element_to_group.get(wheel_id, 0))
		if (
			suspension_group <= 0
			or wheel_group <= 0
			or suspension_group == wheel_group
		):
			return {"valid": false, "reason": &"invalid_wheel_groups"}
		wheel_specs.append({
			"joint_id": joint.joint_id,
			"suspension_element_id": suspension_id,
			"wheel_element_id": wheel_id,
			"suspension_group_id": suspension_group,
			"wheel_group_id": wheel_group,
		})

	var driven_specs: Array[Dictionary] = []
	for joint: SimulationJoint in joints:
		if not joint.is_driven():
			continue
		var base_group := int(element_to_group.get(joint.element_a_id, 0))
		var head_group := int(element_to_group.get(joint.element_b_id, 0))
		if base_group <= 0 or head_group <= 0 or base_group == head_group:
			return {"valid": false, "reason": &"invalid_piston_groups"}
		driven_specs.append({
			"joint_id": joint.joint_id,
			"joint_kind": joint.kind,
			"base_element_id": joint.element_a_id,
			"head_element_id": joint.element_b_id,
			"base_group_id": base_group,
			"head_group_id": head_group,
		})

	var wheel_group_ids: Dictionary = {}
	for spec: Dictionary in wheel_specs:
		wheel_group_ids[int(spec["wheel_group_id"])] = true
	var root_group_id := _pick_root_group_id(
		groups,
		element_ids,
		elements_by_id,
		joints,
		wheel_group_ids
	)
	if groups.size() > 1 and root_group_id <= 0:
		return {"valid": false, "reason": &"ambiguous_root_group"}

	var cycle := _validate_acyclic_piston_graph(driven_specs)
	if not bool(cycle.get("valid", false)):
		return cycle
	var chain := _validate_driven_chain_length(driven_specs, root_group_id)
	if not bool(chain.get("valid", false)):
		return chain

	return {
		"valid": true,
		"groups": groups,
		"element_to_group": element_to_group,
		"root_group_id": root_group_id,
		"driven_specs": driven_specs,
		"wheel_specs": wheel_specs,
	}


static func _is_wheel_pair_joint(
	joint: SimulationJoint,
	elements_by_id: Dictionary
) -> bool:
	if joint.kind != SimulationJoint.Kind.RIGID:
		return false
	var left: SimulationElement = elements_by_id.get(joint.element_a_id)
	var right: SimulationElement = elements_by_id.get(joint.element_b_id)
	if left == null or right == null:
		return false
	return (
		(_is_suspension(left) and _is_wheel(right))
		or (_is_wheel(left) and _is_suspension(right))
	)


static func _is_suspension(element: SimulationElement) -> bool:
	var archetype := element.get_archetype()
	return archetype != null and archetype.is_suspension()


static func _is_wheel(element: SimulationElement) -> bool:
	var archetype := element.get_archetype()
	return archetype != null and archetype.is_wheel()

## Prospective compile after placing a driven base+head with rigid snaps.
## Preview elements often use negative placeholder ids (-1/-2); body-group ids
## are min(element_id) and the compiler rejects group_id <= 0, so remap to
## large positive temps that cannot collide with live allocators.
const PROSPECTIVE_BASE_ELEMENT_ID := 900000001
const PROSPECTIVE_HEAD_ELEMENT_ID := 900000002
const PROSPECTIVE_JOINT_ID_BASE := 900001000


## `driven_joint` is a throwaway built for this call; its endpoints are
## rewritten onto the prospective temp elements.
static func compile_prospective_driven_place(
	assembly_element_ids: Array[int],
	elements_by_id: Dictionary,
	existing_joints: Array[SimulationJoint],
	base_preview: SimulationElement,
	head_preview: SimulationElement,
	base_connections: Array[Dictionary],
	head_connections: Array[Dictionary],
	driven_joint: SimulationJoint
) -> Dictionary:
	var element_ids: Array[int] = assembly_element_ids.duplicate()
	var elements: Dictionary = elements_by_id.duplicate()
	var temp_base := SimulationElement.frame(
		PROSPECTIVE_BASE_ELEMENT_ID,
		base_preview.assembly_id,
		base_preview.get_archetype(),
		base_preview.origin_cell,
		base_preview.orientation_index,
		{}
	)
	var temp_head := SimulationElement.frame(
		PROSPECTIVE_HEAD_ELEMENT_ID,
		head_preview.assembly_id,
		head_preview.get_archetype(),
		head_preview.origin_cell,
		head_preview.orientation_index,
		{}
	)
	elements[temp_base.element_id] = temp_base
	elements[temp_head.element_id] = temp_head
	element_ids.append(temp_base.element_id)
	element_ids.append(temp_head.element_id)
	var joints: Array[SimulationJoint] = existing_joints.duplicate()
	driven_joint.joint_id = PROSPECTIVE_JOINT_ID_BASE
	driven_joint.element_a_id = temp_base.element_id
	driven_joint.element_b_id = temp_head.element_id
	joints.append(driven_joint)
	var next_joint_id := PROSPECTIVE_JOINT_ID_BASE + 1
	for connection_variant: Variant in base_connections:
		var connection: Dictionary = connection_variant
		joints.append(
			SimulationJoint.rigid(
				next_joint_id,
				driven_joint.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				temp_base.element_id,
				str(connection["new_port_id"])
			)
		)
		next_joint_id += 1
	for connection_variant: Variant in head_connections:
		var connection: Dictionary = connection_variant
		joints.append(
			SimulationJoint.rigid(
				next_joint_id,
				driven_joint.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				temp_head.element_id,
				str(connection["new_port_id"])
			)
		)
		next_joint_id += 1
	return compile(element_ids, elements, joints)


static func would_rigid_bridge_piston_groups(
	element_a_id: int,
	element_b_id: int,
	element_ids: Array[int],
	elements_by_id: Dictionary,
	joints: Array[SimulationJoint]
) -> bool:
	var compiled := compile(element_ids, elements_by_id, joints)
	if not bool(compiled.get("valid", false)):
		return true
	var element_to_group: Dictionary = compiled["element_to_group"]
	var group_a := int(element_to_group.get(element_a_id, 0))
	var group_b := int(element_to_group.get(element_b_id, 0))
	if group_a <= 0 or group_b <= 0 or group_a == group_b:
		return false
	for spec: Dictionary in compiled["driven_specs"]:
		var left := int(spec["base_group_id"])
		var right := int(spec["head_group_id"])
		if (
			(group_a == left and group_b == right)
			or (group_a == right and group_b == left)
		):
			return true
	return false

static func _pick_root_group_id(
	groups: Dictionary,
	_element_ids: Array[int],
	_elements_by_id: Dictionary,
	joints: Array[SimulationJoint],
	wheel_group_ids: Dictionary = {}
) -> int:
	var anchored_groups: Dictionary = {}
	for joint: SimulationJoint in joints:
		if joint.kind != SimulationJoint.Kind.ANCHOR:
			continue
		var group_id := _group_for_element(
			joint.element_a_id,
			groups
		)
		if group_id > 0:
			anchored_groups[group_id] = true
	var anchored_ids: Array[int] = _sorted_int_keys(anchored_groups)
	if anchored_ids.is_empty():
		if groups.is_empty():
			return 0
		# Wheel groups can never be the motion root: assembly.motion follows the
		# root body, and a root that spins with the tire would corkscrew the
		# whole assembly frame.
		for group_id: int in _sorted_int_keys(groups):
			if not wheel_group_ids.has(group_id):
				return group_id
		return int(_sorted_int_keys(groups).min())
	if anchored_ids.size() == 1:
		return anchored_ids[0]
	# Carriage groups can pick up terrain anchors while the base group is also
	# anchored. Prefer the driven-base rigid group as the motion root.
	for joint: SimulationJoint in joints:
		if not joint.is_driven():
			continue
		var base_group := _group_for_element(joint.element_a_id, groups)
		if base_group > 0 and anchored_groups.has(base_group):
			return base_group
	return anchored_ids[0]

static func _group_for_element(element_id: int, groups: Dictionary) -> int:
	for group_id_variant: Variant in groups.keys():
		var group_id := int(group_id_variant)
		var members: Array = groups[group_id]
		if members.has(element_id):
			return group_id
	return 0

static func _component_group_id(component: Array) -> int:
	var ids: Array[int] = []
	for element_id_variant: Variant in component:
		ids.append(int(element_id_variant))
	ids.sort()
	return ids[0] if not ids.is_empty() else 0

static func _validate_acyclic_piston_graph(
	driven_specs: Array[Dictionary]
) -> Dictionary:
	if driven_specs.is_empty():
		return {"valid": true}
	var adjacency: Dictionary = {}
	for spec: Dictionary in driven_specs:
		var left := int(spec["base_group_id"])
		var right := int(spec["head_group_id"])
		if not adjacency.has(left):
			adjacency[left] = {}
		if not adjacency.has(right):
			adjacency[right] = {}
		adjacency[left][right] = true
		adjacency[right][left] = true

	var visited: Dictionary = {}
	for start_id: int in _sorted_int_keys(adjacency):
		if visited.has(start_id):
			continue
		if not _dfs_piston_graph_acyclic(start_id, -1, adjacency, visited):
			return {"valid": false, "reason": &"driven_joint_cycle"}
	return {"valid": true}

## Longest directed driven path (joint count) from root must be ≤ 4.
static func _validate_driven_chain_length(
	driven_specs: Array[Dictionary],
	root_group_id: int
) -> Dictionary:
	if driven_specs.is_empty():
		return {"valid": true}
	var children_of: Dictionary = {}
	for spec: Dictionary in driven_specs:
		var base_id := int(spec["base_group_id"])
		if not children_of.has(base_id):
			children_of[base_id] = []
		(children_of[base_id] as Array).append(int(spec["head_group_id"]))
	var start_ids: Array[int] = []
	if root_group_id > 0:
		start_ids.append(root_group_id)
	else:
		for base_id: int in _sorted_int_keys(children_of):
			start_ids.append(base_id)
	var longest := 0
	for start_id: int in start_ids:
		longest = maxi(
			longest,
			_longest_driven_path_from(start_id, children_of, {})
		)
	if longest > MAX_DRIVEN_JOINTS_ON_PATH:
		return {"valid": false, "reason": &"driven_joint_chain_too_long"}
	return {"valid": true}

static func _longest_driven_path_from(
	group_id: int,
	children_of: Dictionary,
	stack: Dictionary
) -> int:
	if stack.has(group_id):
		return 0
	stack[group_id] = true
	var best := 0
	for child_variant: Variant in children_of.get(group_id, []):
		var child_id := int(child_variant)
		best = maxi(
			best,
			1 + _longest_driven_path_from(child_id, children_of, stack)
		)
	stack.erase(group_id)
	return best

static func _dfs_piston_graph_acyclic(
	node_id: int,
	parent_id: int,
	adjacency: Dictionary,
	visited: Dictionary
) -> bool:
	visited[node_id] = true
	var neighbors: Array = adjacency.get(node_id, {}).keys()
	neighbors.sort()
	for neighbor_variant: Variant in neighbors:
		var neighbor_id := int(neighbor_variant)
		if neighbor_id == parent_id:
			continue
		if visited.has(neighbor_id):
			return false
		if not _dfs_piston_graph_acyclic(
			neighbor_id,
			node_id,
			adjacency,
			visited
		):
			return false
	return true

static func _sorted_int_keys(values: Dictionary) -> Array[int]:
	var keys: Array[int] = []
	for key: Variant in values.keys():
		keys.append(int(key))
	keys.sort()
	return keys
