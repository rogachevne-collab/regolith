class_name SimulationWorld
extends Node

signal structural_event(event: Dictionary)
signal structural_command_completed(
	command_id: int,
	result: StructuralCommandResult
)

var _allocator := SimulationIdAllocator.new()
var _archetypes := ArchetypeRegistry.new()
var _assemblies: Dictionary = {}
var _elements: Dictionary = {}
var _joints: Dictionary = {}
var _redirects: Dictionary = {}
var _command_queue: Array[StructuralCommand] = []
var _flush_scheduled := false


func get_allocator() -> SimulationIdAllocator:
	return _allocator


func get_archetype_registry() -> ArchetypeRegistry:
	return _archetypes


func list_assemblies() -> Array[SimulationAssembly]:
	var result: Array[SimulationAssembly] = []
	for assembly_id: int in _sorted_keys(_assemblies):
		result.append(_assemblies[assembly_id])
	return result


func list_elements() -> Array[SimulationElement]:
	var result: Array[SimulationElement] = []
	for element_id: int in _sorted_keys(_elements):
		result.append(_elements[element_id])
	return result


func list_joints() -> Array[SimulationJoint]:
	var result: Array[SimulationJoint] = []
	for joint_id: int in _sorted_keys(_joints):
		result.append(_joints[joint_id])
	return result


func list_redirect_from_ids() -> Array[int]:
	return _sorted_keys(_redirects)


func get_redirect_target_raw(assembly_id: int) -> int:
	return int(_redirects.get(assembly_id, 0))


func get_assembly(assembly_id: int) -> SimulationAssembly:
	return get_assembly_raw(resolve_assembly_id(assembly_id))


func get_assembly_raw(assembly_id: int) -> SimulationAssembly:
	return _assemblies.get(assembly_id) as SimulationAssembly


func get_element(element_id: int) -> SimulationElement:
	return _elements.get(element_id) as SimulationElement


func get_joint(joint_id: int) -> SimulationJoint:
	return _joints.get(joint_id) as SimulationJoint


func resolve_assembly_id(assembly_id: int) -> int:
	var current := assembly_id
	var visited: Dictionary = {}
	while _redirects.has(current):
		if visited.has(current):
			return 0
		visited[current] = true
		current = int(_redirects[current])
	return current


func submit_structural_command(command: StructuralCommand) -> int:
	if command == null:
		return 0
	var queued := command.execution_copy()
	if queued == null:
		return 0
	queued.command_id = _allocator.allocate_command_id()
	_command_queue.append(queued)
	if not _flush_scheduled:
		_flush_scheduled = true
		call_deferred("_flush_commands")
	return queued.command_id


func apply_structural_command_now(
	command: StructuralCommand
) -> StructuralCommandResult:
	if command == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	if command.command_id != 0:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_COMMAND_ID
		)
	command.command_id = _allocator.allocate_command_id()
	return _execute_structural_command(command)


func sync_assembly_motion(
	assembly_id: int,
	motion_state: AssemblyMotionState
) -> bool:
	# Single authoritative write path for continuous kinematic truth.
	# Projection is the only live-body caller; internal seeding reuses it.
	var assembly := get_assembly_raw(assembly_id)
	if (
		assembly == null
		or assembly.tombstoned
		or motion_state == null
		or not motion_state.is_valid()
	):
		return false
	assembly.motion = motion_state.duplicate_state()
	return true


func capture_snapshot() -> Dictionary:
	return SimulationSnapshot.capture(self)


func restore_snapshot(snapshot: Dictionary) -> bool:
	var restored = SimulationSnapshot.create_from_snapshot(snapshot)
	if restored == null:
		return false
	_allocator = restored._allocator
	_archetypes = restored._archetypes
	_assemblies = restored._assemblies
	_elements = restored._elements
	_joints = restored._joints
	_redirects = restored._redirects
	_command_queue.clear()
	_flush_scheduled = false
	restored.free()
	_emit_structural_event({"kind": &"world_restored"})
	return true


func _flush_commands() -> void:
	_flush_scheduled = false
	while not _command_queue.is_empty():
		var command: StructuralCommand = _command_queue.pop_front()
		var result := _execute_structural_command(command)
		structural_command_completed.emit(command.command_id, result)


func _execute_structural_command(
	command: StructuralCommand
) -> StructuralCommandResult:
	if command is SpawnBlueprintCommand:
		return _spawn_blueprint(command as SpawnBlueprintCommand)
	if command is BreakRigidJointCommand:
		return _break_rigid_joint(command as BreakRigidJointCommand)
	if command is MergeAssembliesCommand:
		return _merge_assemblies(command as MergeAssembliesCommand)
	return StructuralCommandResult.failed(
		StructuralCommandResult.REASON_INVALID_TARGET
	)


func _spawn_blueprint(
	command: SpawnBlueprintCommand
) -> StructuralCommandResult:
	var blueprint := command.blueprint
	if blueprint == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_BLUEPRINT
		)
	var validation := BlueprintValidator.validate(blueprint)
	if not validation.ok:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_BLUEPRINT,
			{"errors": validation.errors}
		)
	if command.grid_frame == null or not command.grid_frame.is_valid():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TRANSFORM
		)
	if not _can_register_blueprint_archetypes(blueprint):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)
	# Blueprint validation has already checked occupancy and placement identity.
	# No topology ID is consumed before all rejection paths above complete.
	for placement: BlueprintElementPlacement in blueprint.placements:
		_archetypes.register(placement.archetype)

	var assembly_id := _allocator.allocate_assembly_id()
	var assembly := SimulationAssembly.new()
	assembly.assembly_id = assembly_id
	assembly.grid_frame = command.grid_frame.duplicate_transform()
	assembly.motion = AssemblyMotionState.from_grid_frame(assembly.grid_frame)
	var local_to_element: Dictionary = {}
	var spawned: Array[SimulationElement] = []
	for placement: BlueprintElementPlacement in blueprint.placements:
		var element_id := _allocator.allocate_element_id()
		var element := SimulationElement.from_placement(
			element_id,
			assembly_id,
			placement
		)
		spawned.append(element)
		assembly.element_ids.append(element_id)
		local_to_element[placement.local_id] = element_id
	assembly.element_ids.sort()

	var allocate_joint := func() -> int:
		return _allocator.allocate_joint_id()
	var new_joints := RuntimeConnectivity.materialize_rigid_joints(
		assembly_id,
		spawned,
		allocate_joint
	)
	new_joints.append_array(
		RuntimeConnectivity.materialize_anchor_joints(
			assembly_id,
			spawned,
			allocate_joint
		)
	)
	for element: SimulationElement in spawned:
		_elements[element.element_id] = element
	for joint: SimulationJoint in new_joints:
		_joints[joint.joint_id] = joint
	_assemblies[assembly_id] = assembly
	assembly.bump_revision()

	var joint_ids := _joint_ids_for_assembly(assembly_id)
	_emit_structural_event({
		"kind": &"assembly_spawned",
		"command_id": command.command_id,
		"assembly_id": assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_ids": assembly.element_ids.duplicate(),
		"joint_ids": joint_ids,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": assembly_id,
		"topology_revision": assembly.topology_revision,
		"local_to_element_id": local_to_element,
		"element_ids": assembly.element_ids.duplicate(),
		"joint_ids": joint_ids,
	})


func _break_rigid_joint(
	command: BreakRigidJointCommand
) -> StructuralCommandResult:
	var joint := get_joint(command.joint_id)
	if joint == null or joint.kind != SimulationJoint.Kind.RIGID:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var assembly := get_assembly_raw(joint.assembly_id)
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

	var remaining_joints := _joints_for_assembly(assembly.assembly_id)
	remaining_joints.erase(joint)
	var components := RuntimeConnectivity.connected_components(
		assembly.element_ids.duplicate(),
		_elements,
		remaining_joints
	)
	var survivor_index := 0
	if components.size() > 1:
		var scores: Array[Dictionary] = []
		for component: Array in components:
			scores.append(SurvivorPolicy.component_score(
				component,
				_elements,
				remaining_joints
			))
		survivor_index = SurvivorPolicy.pick_survivor_index(scores)

	# Apply only after all validation and component planning succeeds.
	_joints.erase(command.joint_id)
	if components.size() <= 1:
		assembly.bump_revision()
		_emit_structural_event({
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
		var new_id := _allocator.allocate_assembly_id()
		var split_assembly := SimulationAssembly.new()
		split_assembly.assembly_id = new_id
		split_assembly.grid_frame = assembly.grid_frame.duplicate_transform()
		split_assembly.motion = assembly.motion.duplicate_state()
		split_assembly.element_ids.assign(component)
		split_assembly.bump_revision()
		_assemblies[new_id] = split_assembly
		new_ids.append(new_id)
		for element_id: int in component:
			(_elements[element_id] as SimulationElement).assembly_id = new_id
		for candidate: SimulationJoint in remaining_joints:
			if _joint_belongs_to_component(candidate, component):
				candidate.assembly_id = new_id
		mappings.append({
			"assembly_id": new_id,
			"element_ids": component.duplicate(),
			"topology_revision": split_assembly.topology_revision,
		})
	assembly.element_ids.assign(survivor_component)
	assembly.bump_revision()
	_emit_structural_event({
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


func _merge_assemblies(
	command: MergeAssembliesCommand
) -> StructuralCommandResult:
	var assembly_a := get_assembly_raw(command.assembly_a_id)
	var assembly_b := get_assembly_raw(command.assembly_b_id)
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
	var element_a := get_element(command.element_a_id)
	var element_b := get_element(command.element_b_id)
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
		_elements,
		_joints_for_assembly(assembly_a.assembly_id)
	)
	var score_b := SurvivorPolicy.assembly_score(
		assembly_b.assembly_id,
		assembly_b.element_ids,
		_elements,
		_joints_for_assembly(assembly_b.assembly_id)
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
		var element := get_element(element_id)
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
	if not _occupancy_is_unique(
		_elements_for_ids(survivor.element_ids),
		_cells_by_element_id(preview_elements)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_OVERLAP
		)

	var connection_a := element_a
	var connection_b := element_b
	if loser == assembly_a:
		connection_a = _preview_for_id(preview_elements, element_a.element_id)
	else:
		connection_b = _preview_for_id(preview_elements, element_b.element_id)
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
	if _assembly_has_anchor(survivor.assembly_id) and _assembly_has_anchor(loser.assembly_id):
		for joint: SimulationJoint in _joints_for_assembly(loser.assembly_id):
			if joint.kind == SimulationJoint.Kind.ANCHOR:
				removed_anchors.append(joint.joint_id)
	for joint_id: int in removed_anchors:
		_joints.erase(joint_id)
	for element_id: int in loser.element_ids:
		var element := get_element(element_id)
		var pose: Dictionary = planned_poses[element_id]
		element.origin_cell = pose["origin_cell"]
		element.orientation_index = int(pose["orientation_index"])
		element.assembly_id = survivor.assembly_id
		survivor.element_ids.append(element_id)
	for joint: SimulationJoint in _joints_for_assembly(loser.assembly_id):
		joint.assembly_id = survivor.assembly_id
	var bridge_id := _allocator.allocate_joint_id()
	_joints[bridge_id] = SimulationJoint.rigid(
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
	_redirects[loser.assembly_id] = survivor.assembly_id
	survivor.bump_revision()
	loser.bump_revision()
	removed_anchors.sort()
	_emit_structural_event({
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


func _can_register_blueprint_archetypes(blueprint: Blueprint) -> bool:
	var pending: Dictionary = {}
	for placement: BlueprintElementPlacement in blueprint.placements:
		var archetype := placement.archetype
		if archetype == null or archetype.resource_path.is_empty():
			return false
		var fingerprint := ArchetypeRegistry.fingerprint_of(archetype)
		if pending.has(archetype.archetype_id):
			if pending[archetype.archetype_id] != fingerprint:
				return false
		elif _archetypes.has(archetype.archetype_id):
			if (
				ArchetypeRegistry.fingerprint_of(
					_archetypes.get_archetype(archetype.archetype_id)
				)
				!= fingerprint
			):
				return false
		else:
			pending[archetype.archetype_id] = fingerprint
	return true


func _preview_for_id(
	previews: Array[SimulationElement],
	element_id: int
) -> SimulationElement:
	for preview: SimulationElement in previews:
		if preview.element_id == element_id:
			return preview
	return null


func _register_assembly(assembly: SimulationAssembly) -> void:
	_assemblies[assembly.assembly_id] = assembly


func _register_element(element: SimulationElement) -> void:
	_elements[element.element_id] = element


func _register_joint(joint: SimulationJoint) -> void:
	_joints[joint.joint_id] = joint


func _register_redirect(from_id: int, to_id: int) -> void:
	_redirects[from_id] = to_id


func _joints_for_assembly(assembly_id: int) -> Array[SimulationJoint]:
	var result: Array[SimulationJoint] = []
	for joint: SimulationJoint in list_joints():
		if joint.assembly_id == assembly_id:
			result.append(joint)
	return result


func _joint_ids_for_assembly(assembly_id: int) -> Array[int]:
	var ids: Array[int] = []
	for joint: SimulationJoint in _joints_for_assembly(assembly_id):
		ids.append(joint.joint_id)
	ids.sort()
	return ids


func _elements_for_ids(ids: Array[int]) -> Array[SimulationElement]:
	var result: Array[SimulationElement] = []
	for element_id: int in ids:
		result.append(_elements[element_id])
	return result


func _cells_by_element_id(
	elements: Array[SimulationElement]
) -> Dictionary:
	var result: Dictionary = {}
	for element: SimulationElement in elements:
		result[element.element_id] = element.occupied_cells()
	return result


func _occupancy_is_unique(
	base: Array[SimulationElement],
	extra: Dictionary
) -> bool:
	var seen: Dictionary = {}
	for element: SimulationElement in base:
		for cell: Vector3i in element.occupied_cells():
			var key := _cell_key(cell)
			if seen.has(key):
				return false
			seen[key] = element.element_id
	for element_id: int in _sorted_keys(extra):
		for cell: Vector3i in extra[element_id]:
			var key := _cell_key(cell)
			if seen.has(key):
				return false
			seen[key] = element_id
	return true


func _cell_key(cell: Vector3i) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]


func _joint_belongs_to_component(
	joint: SimulationJoint,
	component: Array
) -> bool:
	if joint.kind == SimulationJoint.Kind.ANCHOR:
		return component.has(joint.element_a_id)
	return (
		component.has(joint.element_a_id)
		and component.has(joint.element_b_id)
	)


func assembly_has_anchor(assembly_id: int) -> bool:
	return _assembly_has_anchor(assembly_id)


func _assembly_has_anchor(assembly_id: int) -> bool:
	for joint: SimulationJoint in _joints_for_assembly(assembly_id):
		if joint.kind == SimulationJoint.Kind.ANCHOR:
			return true
	return false


func _sorted_keys(dictionary: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key: Variant in dictionary.keys():
		result.append(int(key))
	result.sort()
	return result


func _emit_structural_event(event: Dictionary) -> void:
	structural_event.emit(event)
