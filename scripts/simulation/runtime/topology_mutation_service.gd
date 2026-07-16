class_name TopologyMutationService
extends RefCounted

static func remove_element_from_topology(world, 
	element: SimulationElement,
	command_id: int,
	refund_fraction: float,
	store: SimulationResourceStore
) -> StructuralCommandResult:
	var assembly: SimulationAssembly = world.get_assembly_raw(element.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)

	var removed_joint_ids: Array[int] = []
	var remaining_joints: Array[SimulationJoint] = []
	for joint: SimulationJoint in world._joints_for_assembly(assembly.assembly_id):
		if joint.involves_element(element.element_id):
			removed_joint_ids.append(joint.joint_id)
		else:
			remaining_joints.append(joint)
	var remaining_elements: Array[int] = assembly.element_ids.duplicate()
	remaining_elements.erase(element.element_id)
	var components: Array[Array] = []
	var survivor_index := 0
	if not remaining_elements.is_empty():
		components = RuntimeConnectivity.mechanical_connected_components(
			remaining_elements,
			world._elements,
			remaining_joints
		)
		if components.size() > 1:
			var scores: Array[Dictionary] = []
			for component: Array in components:
				scores.append(SurvivorPolicy.component_score(
					component,
					world._elements,
					remaining_joints
				))
			survivor_index = SurvivorPolicy.pick_survivor_index(scores)

	var refunds: Dictionary = {}
	if refund_fraction > 0.000001 and store != null:
		for resource_id: Variant in element.installed_materials.keys():
			var amount := float(element.installed_materials[resource_id]) * refund_fraction
			if amount > 0.000001:
				refunds[str(resource_id)] = amount

	for joint_id: int in removed_joint_ids:
		world._joints.erase(joint_id)
	world._elements.erase(element.element_id)
	world.clear_wheel_element_state(element.element_id)
	world._notify_topology_changed()
	for resource_id: Variant in refunds.keys():
		store.add(str(resource_id), float(refunds[resource_id]))
	removed_joint_ids.sort()

	if remaining_elements.is_empty():
		world._assemblies.erase(assembly.assembly_id)
		world.clear_assembly_locomotion(assembly.assembly_id)
		world._emit_structural_event({
			"kind": &"assembly_removed",
			"command_id": command_id,
			"assembly_id": assembly.assembly_id,
			"removed_element_id": element.element_id,
		})
		return StructuralCommandResult.ok({
			"assembly_removed": true,
			"assembly_id": assembly.assembly_id,
			"removed_element_id": element.element_id,
			"removed_joint_ids": removed_joint_ids,
			"refunds": refunds,
		})

	if components.size() <= 1:
		assembly.element_ids.assign(remaining_elements)
		assembly.element_ids.sort()
		var reconcile_ids: Array[int] = [assembly.assembly_id]
		world._reconcile_terrain_anchors_for_assemblies(reconcile_ids)
		assembly.bump_revision()
		world._notify_topology_changed()
		world._emit_structural_event({
			"kind": &"assembly_changed",
			"command_id": command_id,
			"assembly_id": assembly.assembly_id,
			"topology_revision": assembly.topology_revision,
			"removed_element_id": element.element_id,
			"removed_joint_ids": removed_joint_ids,
		})
		return StructuralCommandResult.ok({
			"assembly_removed": false,
			"split": false,
			"assembly_id": assembly.assembly_id,
			"topology_revision": assembly.topology_revision,
			"removed_element_id": element.element_id,
			"removed_joint_ids": removed_joint_ids,
			"refunds": refunds,
		})

	var survivor_component: Array = components[survivor_index]
	var mappings: Array[Dictionary] = []
	var new_ids: Array[int] = []
	for index: int in range(components.size()):
		if index == survivor_index:
			continue
		var component: Array = components[index]
		var new_id: int = world._allocator.allocate_assembly_id()
		var split_assembly := SimulationAssembly.new()
		split_assembly.assembly_id = new_id
		split_assembly.grid_frame = assembly.grid_frame.duplicate_transform()
		split_assembly.motion = assembly.motion.duplicate_state()
		split_assembly.element_ids.assign(component)
		split_assembly.bump_revision()
		world._assemblies[new_id] = split_assembly
		new_ids.append(new_id)
		for element_id: int in component:
			(world.get_element(element_id) as SimulationElement).assembly_id = new_id
		for candidate: SimulationJoint in remaining_joints:
			if ConstructionOccupancyUtil.joint_belongs_to_component(candidate, component):
				candidate.assembly_id = new_id
		mappings.append({
			"assembly_id": new_id,
			"element_ids": component.duplicate(),
			"topology_revision": split_assembly.topology_revision,
		})
	assembly.element_ids.assign(survivor_component)
	var affected_assembly_ids: Array[int] = [assembly.assembly_id]
	affected_assembly_ids.append_array(new_ids)
	world._reconcile_terrain_anchors_for_assemblies(affected_assembly_ids)
	assembly.bump_revision()
	world._notify_topology_changed()
	world._emit_structural_event({
		"kind": &"assembly_split",
		"command_id": command_id,
		"removed_element_id": element.element_id,
		"survivor_assembly_id": assembly.assembly_id,
		"survivor_topology_revision": assembly.topology_revision,
		"new_assemblies": mappings,
	})
	return StructuralCommandResult.ok({
		"assembly_removed": false,
		"split": true,
		"removed_element_id": element.element_id,
		"survivor_assembly_id": assembly.assembly_id,
		"survivor_topology_revision": assembly.topology_revision,
		"new_assembly_ids": new_ids,
		"removed_joint_ids": removed_joint_ids,
		"refunds": refunds,
	})

static func break_rigid_joint(world, 
	command: BreakRigidJointCommand
) -> StructuralCommandResult:
	var joint: SimulationJoint = world.get_joint(command.joint_id)
	if joint == null or joint.kind != SimulationJoint.Kind.RIGID:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var assembly: SimulationAssembly = world.get_assembly_raw(joint.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if assembly.topology_revision != command.expected_assembly_revision:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"expected": command.expected_assembly_revision,
				"actual": assembly.topology_revision,
			}
		)

	var remaining_joints: Array[SimulationJoint] = world._joints_for_assembly(assembly.assembly_id)
	remaining_joints.erase(joint)
	var components := RuntimeConnectivity.mechanical_connected_components(
		assembly.element_ids.duplicate(),
		world._elements,
		remaining_joints
	)
	var survivor_index := 0
	if components.size() > 1:
		var scores: Array[Dictionary] = []
		for component: Array in components:
			scores.append(SurvivorPolicy.component_score(
				component,
				world._elements,
				remaining_joints
			))
		survivor_index = SurvivorPolicy.pick_survivor_index(scores)

	# Apply only after all validation and component planning succeeds.
	world._joints.erase(command.joint_id)
	if components.size() <= 1:
		var reconcile_ids: Array[int] = [assembly.assembly_id]
		world._reconcile_terrain_anchors_for_assemblies(reconcile_ids)
		assembly.bump_revision()
		world._notify_topology_changed()
		world._emit_structural_event({
			"kind": &"rigid_joint_broken",
			"command_id": command.command_id,
			"joint_id": command.joint_id,
			"assembly_id": assembly.assembly_id,
			"topology_revision": assembly.topology_revision,
			"split": false,
		})
		return StructuralCommandResult.ok({
			"joint_id": command.joint_id,
			"assembly_id": assembly.assembly_id,
			"topology_revision": assembly.topology_revision,
			"split": false,
		})

	var survivor_component: Array = components[survivor_index]
	var mappings: Array[Dictionary] = []
	var new_ids: Array[int] = []
	for index: int in range(components.size()):
		if index == survivor_index:
			continue
		var component: Array = components[index]
		var new_id: int = world._allocator.allocate_assembly_id()
		var split_assembly := SimulationAssembly.new()
		split_assembly.assembly_id = new_id
		split_assembly.grid_frame = assembly.grid_frame.duplicate_transform()
		split_assembly.motion = assembly.motion.duplicate_state()
		split_assembly.element_ids.assign(component)
		split_assembly.bump_revision()
		world._assemblies[new_id] = split_assembly
		new_ids.append(new_id)
		for element_id: int in component:
			(world._elements[element_id] as SimulationElement).assembly_id = new_id
		for candidate: SimulationJoint in remaining_joints:
			if ConstructionOccupancyUtil.joint_belongs_to_component(candidate, component):
				candidate.assembly_id = new_id
		mappings.append({
			"assembly_id": new_id,
			"element_ids": component.duplicate(),
			"topology_revision": split_assembly.topology_revision,
		})
	assembly.element_ids.assign(survivor_component)
	var split_assembly_ids: Array[int] = [assembly.assembly_id]
	split_assembly_ids.append_array(new_ids)
	world._reconcile_terrain_anchors_for_assemblies(split_assembly_ids)
	assembly.bump_revision()
	world._notify_topology_changed()
	world._emit_structural_event({
		"kind": &"assembly_split",
		"command_id": command.command_id,
		"broken_joint_id": command.joint_id,
		"survivor_assembly_id": assembly.assembly_id,
		"survivor_topology_revision": assembly.topology_revision,
		"new_assemblies": mappings,
	})
	return StructuralCommandResult.ok({
		"joint_id": command.joint_id,
		"split": true,
		"survivor_assembly_id": assembly.assembly_id,
		"survivor_topology_revision": assembly.topology_revision,
		"new_assembly_ids": new_ids,
		"split_mappings": mappings,
	})

static func merge_assemblies(world, 
	command: MergeAssembliesCommand
) -> StructuralCommandResult:
	var assembly_a: SimulationAssembly = world.get_assembly_raw(command.assembly_a_id)
	var assembly_b: SimulationAssembly = world.get_assembly_raw(command.assembly_b_id)
	if (
		assembly_a == null
		or assembly_b == null
		or assembly_a.tombstoned
		or assembly_b.tombstoned
		or assembly_a == assembly_b
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if (
		assembly_a.topology_revision != command.expected_revision_a
		or assembly_b.topology_revision != command.expected_revision_b
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION
		)
	if not assembly_a.grid_frame.is_valid() or not assembly_b.grid_frame.is_valid():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TRANSFORM
		)
	if command.b_to_a_grid == null or not command.b_to_a_grid.is_valid():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TRANSFORM
		)
	if (
		assembly_a.motion == null
		or assembly_b.motion == null
		or not assembly_a.motion.is_valid()
		or not assembly_b.motion.is_valid()
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TRANSFORM
		)
	var alignment: Dictionary = GridAlignment.validate_supplied(
		assembly_a.motion.transform,
		assembly_b.motion.transform,
		command.b_to_a_grid
	)
	if not bool(alignment["valid"]):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_MISALIGNED_CONNECTION,
			{
				"position_error_m": alignment["position_error_m"],
				"angle_error_rad": alignment["angle_error_rad"],
				"matches_supplied": alignment["matches_supplied"],
			}
		)
	var element_a: SimulationElement = world.get_element(command.element_a_id)
	var element_b: SimulationElement = world.get_element(command.element_b_id)
	if element_a == null or element_b == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if (
		element_a.assembly_id != assembly_a.assembly_id
		or element_b.assembly_id != assembly_b.assembly_id
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)

	var score_a := SurvivorPolicy.assembly_score(
		assembly_a.assembly_id,
		assembly_a.element_ids,
		world._elements,
		world._joints_for_assembly(assembly_a.assembly_id)
	)
	var score_b := SurvivorPolicy.assembly_score(
		assembly_b.assembly_id,
		assembly_b.element_ids,
		world._elements,
		world._joints_for_assembly(assembly_b.assembly_id)
	)
	var survivor_id := SurvivorPolicy.pick_survivor_assembly([score_a, score_b])
	var survivor: SimulationAssembly
	var loser: SimulationAssembly
	var b_to_a: GridTransform = command.b_to_a_grid.duplicate_transform()
	var loser_to_survivor: GridTransform
	if survivor_id == assembly_a.assembly_id:
		survivor = assembly_a
		loser = assembly_b
		loser_to_survivor = b_to_a
	else:
		survivor = assembly_b
		loser = assembly_a
		loser_to_survivor = b_to_a.inverse()

	var planned_poses: Dictionary = {}
	var preview_elements: Array[SimulationElement] = []
	for element_id: int in loser.element_ids:
		var element: SimulationElement = world.get_element(element_id)
		var pose := loser_to_survivor.map_element_pose(
			element.origin_cell,
			element.orientation_index
		)
		planned_poses[element_id] = pose
		var preview := SimulationElement.new()
		preview.element_id = element.element_id
		preview.assembly_id = survivor.assembly_id
		preview.archetype_id = element.archetype_id
		preview.bind_archetype(element.get_archetype())
		preview.origin_cell = pose["origin_cell"]
		preview.orientation_index = int(pose["orientation_index"])
		preview_elements.append(preview)
	if not ConstructionOccupancyUtil.occupancy_is_unique(world, 
		world._elements_for_ids(survivor.element_ids),
		ConstructionOccupancyUtil.cells_by_element_id(preview_elements)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_OVERLAP
		)

	var connection_a: SimulationElement = element_a
	var connection_b: SimulationElement = element_b
	if loser == assembly_a:
		connection_a = world._preview_for_id(preview_elements, element_a.element_id)
	else:
		connection_b = world._preview_for_id(preview_elements, element_b.element_id)

	if not RuntimeConnectivity.validate_merge_connection(
		connection_a,
		command.port_a_id,
		connection_b,
		command.port_b_id
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
		)

	# All checks complete. Preserve existing element objects and mutate atomically.
	var removed_anchors: Array[int] = []
	if world._assembly_has_anchor(survivor.assembly_id) and world._assembly_has_anchor(loser.assembly_id):
		for joint: SimulationJoint in world._joints_for_assembly(loser.assembly_id):
			if joint.kind == SimulationJoint.Kind.ANCHOR:
				removed_anchors.append(joint.joint_id)
	for joint_id: int in removed_anchors:
		world._joints.erase(joint_id)
	for element_id: int in loser.element_ids:
		var element: SimulationElement = world.get_element(element_id)
		var pose: Dictionary = planned_poses[element_id]
		element.origin_cell = pose["origin_cell"]
		element.orientation_index = int(pose["orientation_index"])
		element.assembly_id = survivor.assembly_id
		survivor.element_ids.append(element_id)
	for joint: SimulationJoint in world._joints_for_assembly(loser.assembly_id):
		joint.assembly_id = survivor.assembly_id
	var bridge_id: int = world._allocator.allocate_joint_id()
	world._joints[bridge_id] = SimulationJoint.rigid(
		bridge_id,
		survivor.assembly_id,
		command.element_a_id,
		command.port_a_id,
		command.element_b_id,
		command.port_b_id
	)
	survivor.element_ids.sort()
	loser.element_ids.clear()
	loser.tombstoned = true
	loser.redirect_to = survivor.assembly_id
	world._redirects[loser.assembly_id] = survivor.assembly_id
	survivor.bump_revision()
	loser.bump_revision()
	world._notify_topology_changed()
	removed_anchors.sort()
	world._emit_structural_event({
		"kind": &"assembly_merged",
		"command_id": command.command_id,
		"survivor_assembly_id": survivor.assembly_id,
		"loser_assembly_id": loser.assembly_id,
		"survivor_topology_revision": survivor.topology_revision,
		"loser_topology_revision": loser.topology_revision,
		"removed_anchor_joint_ids": removed_anchors,
		"bridge_joint_id": bridge_id,
	})
	return StructuralCommandResult.ok({
		"survivor_assembly_id": survivor.assembly_id,
		"loser_assembly_id": loser.assembly_id,
		"survivor_topology_revision": survivor.topology_revision,
		"loser_topology_revision": loser.topology_revision,
		"bridge_joint_id": bridge_id,
		"redirect_to": survivor.assembly_id,
		"removed_anchor_joint_ids": removed_anchors,
	})
