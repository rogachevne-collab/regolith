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
var _resource_stores: Dictionary = {}
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


func list_resource_stores() -> Array[SimulationResourceStore]:
	var result: Array[SimulationResourceStore] = []
	var store_ids: Array = _resource_stores.keys()
	store_ids.sort()
	for store_id: Variant in store_ids:
		result.append(_resource_stores[store_id])
	return result


func get_resource_store(store_id: String) -> SimulationResourceStore:
	return _resource_stores.get(store_id) as SimulationResourceStore


func ensure_resource_store(store_id: String) -> SimulationResourceStore:
	if store_id.is_empty():
		return null
	var existing := get_resource_store(store_id)
	if existing != null:
		return existing
	var store := SimulationResourceStore.new()
	store.store_id = store_id
	_resource_stores[store_id] = store
	return store


func set_resource_amount(
	store_id: String,
	resource_id: String,
	amount: float
) -> bool:
	if (
		store_id.is_empty()
		or resource_id.is_empty()
		or not is_finite(amount)
		or amount < 0.0
	):
		return false
	var store := get_resource_store(store_id)
	if store != null:
		return store.set_amount(resource_id, amount)
	var pending := SimulationResourceStore.new()
	pending.store_id = store_id
	if not pending.set_amount(resource_id, amount):
		return false
	_resource_stores[store_id] = pending
	return true


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
	_resource_stores = restored._resource_stores
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
	if command is PlaceElementCommand:
		return _place_element(command as PlaceElementCommand)
	if command is WeldElementCommand:
		return _weld_element(command as WeldElementCommand)
	if command is DamageElementCommand:
		return _damage_element(command as DamageElementCommand)
	if command is RepairElementCommand:
		return _repair_element(command as RepairElementCommand)
	if command is DismantleElementCommand:
		return _dismantle_element(command as DismantleElementCommand)
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


func preview_place_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	if command == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	return _validate_place_element(command)


func _place_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	var validation := _validate_place_element(command)
	if not validation.is_ok():
		return validation
	var store := get_resource_store(command.store_id)
	var resource_id := str(validation.data["placement_resource_id"])
	var resource_amount := float(validation.data["placement_resource_amount"])
	if not store.remove(resource_id, resource_amount):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL
		)
	if not _archetypes.register(command.archetype):
		store.add(resource_id, resource_amount)
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)

	var assembly: SimulationAssembly
	var new_assembly := command.assembly_id == 0
	if new_assembly:
		assembly = SimulationAssembly.new()
		assembly.assembly_id = _allocator.allocate_assembly_id()
		assembly.grid_frame = command.new_assembly_grid_frame.duplicate_transform()
		assembly.motion = AssemblyMotionState.from_grid_frame(assembly.grid_frame)
	else:
		assembly = get_assembly_raw(command.assembly_id)

	var element_id := _allocator.allocate_element_id()
	var element := SimulationElement.frame(
		element_id,
		assembly.assembly_id,
		command.archetype,
		command.origin_cell,
		command.orientation_index,
		{resource_id: resource_amount}
	)
	var joint_ids: Array[int] = []
	if new_assembly:
		var allocate_joint := func() -> int:
			return _allocator.allocate_joint_id()
		for joint: SimulationJoint in RuntimeConnectivity.materialize_anchor_joints(
			assembly.assembly_id,
			[element],
			allocate_joint
		):
			_joints[joint.joint_id] = joint
			joint_ids.append(joint.joint_id)
		_assemblies[assembly.assembly_id] = assembly
	else:
		for connection_variant: Variant in validation.data["connections"]:
			var connection: Dictionary = connection_variant
			var joint_id := _allocator.allocate_joint_id()
			var joint := SimulationJoint.rigid(
				joint_id,
				assembly.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				element_id,
				str(connection["new_port_id"])
			)
			_joints[joint_id] = joint
			joint_ids.append(joint_id)

	_elements[element_id] = element
	assembly.element_ids.append(element_id)
	assembly.element_ids.sort()
	assembly.bump_revision()
	joint_ids.sort()
	var event_kind := &"assembly_spawned" if new_assembly else &"assembly_changed"
	_emit_structural_event({
		"kind": event_kind,
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_ids": assembly.element_ids.duplicate(),
		"placed_element_id": element_id,
		"joint_ids": joint_ids,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_id": element_id,
		"state_revision": element.state_revision,
		"build_progress": element.build_progress,
		"joint_ids": joint_ids,
		"resource_id": resource_id,
		"resource_remaining": store.amount(resource_id),
	})


func _validate_place_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	var archetype := command.archetype
	if (
		archetype == null
		or archetype.archetype_id.is_empty()
		or archetype.resource_path.is_empty()
		or command.orientation_index < 0
		or command.orientation_index >= OrientationUtil.ORIENTATION_COUNT
		or archetype.build_requirements.is_empty()
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var archetype_validation := _validate_construction_archetype(
		archetype,
		command.orientation_index
	)
	if not archetype_validation.is_ok():
		return archetype_validation
	if _archetypes.has(archetype.archetype_id) and (
		ArchetypeRegistry.fingerprint_of(
			_archetypes.get_archetype(archetype.archetype_id)
		)
		!= ArchetypeRegistry.fingerprint_of(archetype)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)
	var first_requirement: BuildRequirement = archetype.build_requirements[0]
	if (
		first_requirement == null
		or first_requirement.resource_id.is_empty()
		or not is_finite(first_requirement.amount)
		or first_requirement.amount <= 0.0
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var placement_amount := minf(first_requirement.amount, 1.0)
	var store := get_resource_store(command.store_id)
	if (
		store == null
		or not store.can_remove(first_requirement.resource_id, placement_amount)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
			{
				"resource_id": first_requirement.resource_id,
				"required": placement_amount,
				"available": (
					store.amount(first_requirement.resource_id)
					if store != null else 0.0
				),
			}
		)

	var preview := SimulationElement.frame(
		-1,
		command.assembly_id,
		archetype,
		command.origin_cell,
		command.orientation_index,
		{first_requirement.resource_id: placement_amount}
	)
	var connections: Array[Dictionary] = []
	if command.assembly_id == 0:
		if (
			command.new_assembly_grid_frame == null
			or not command.new_assembly_grid_frame.is_valid()
		):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_TRANSFORM
			)
		if not _archetype_has_anchor_port(archetype):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_ANCHOR_REQUIRED
			)
	else:
		var assembly := get_assembly_raw(command.assembly_id)
		if assembly == null or assembly.tombstoned:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_REFERENCE
			)
		if not _assembly_has_anchor(assembly.assembly_id):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_TARGET,
				{"detail": &"mobile_construction_not_supported"}
			)
		if assembly.topology_revision != command.expected_assembly_revision:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_STALE_REVISION,
				{
					"expected": command.expected_assembly_revision,
					"actual": assembly.topology_revision,
				}
			)
		if _archetype_has_anchor_port(archetype):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_ANCHOR_NOT_ALLOWED
			)
		if not _occupancy_is_unique(
			_elements_for_ids(assembly.element_ids),
			{-1: preview.occupied_cells()}
		):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_OVERLAP
			)
		for existing_id: int in assembly.element_ids:
			var existing := get_element(existing_id)
			var connection := RuntimeConnectivity.find_rigid_connection(
				existing,
				preview
			)
			if connection.is_empty():
				continue
			connections.append({
				"existing_element_id": existing_id,
				"existing_port_id": connection["left_port_id"],
				"new_port_id": connection["right_port_id"],
			})
		if connections.is_empty():
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
			)

	return StructuralCommandResult.ok({
		"placement_resource_id": first_requirement.resource_id,
		"placement_resource_amount": placement_amount,
		"connections": connections,
		"build_progress": preview.build_progress,
	})


func _validate_construction_archetype(
	archetype: ElementArchetype,
	orientation_index: int
) -> StructuralCommandResult:
	var placement := BlueprintElementPlacement.new()
	placement.local_id = "construction_preview"
	placement.archetype = archetype
	placement.orientation_index = orientation_index
	var blueprint := Blueprint.new()
	blueprint.blueprint_id = "construction_preview"
	blueprint.allow_disconnected = true
	blueprint.placements.append(placement)
	var validation := BlueprintValidator.validate(blueprint)
	if not validation.ok:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"errors": validation.errors}
		)
	return StructuralCommandResult.ok()


func _weld_element(
	command: WeldElementCommand
) -> StructuralCommandResult:
	var element := get_element(command.element_id)
	var state_error := _validate_state_command(
		element,
		command.expected_state_revision
	)
	if state_error != null:
		return state_error
	if not is_finite(command.max_material_amount) or command.max_material_amount <= 0.0:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	if element.is_complete():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ALREADY_COMPLETE
		)
	var store := get_resource_store(command.store_id)
	if store == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL
		)
	var transfers: Array[Dictionary] = []
	var remaining := command.max_material_amount
	var archetype := element.get_archetype()
	for requirement: BuildRequirement in archetype.build_requirements:
		if remaining <= 0.000001:
			break
		var missing := maxf(
			requirement.amount
			- element.installed_material_amount(requirement.resource_id),
			0.0
		)
		var amount := minf(missing, remaining)
		if amount <= 0.000001:
			continue
		transfers.append({
			"resource_id": requirement.resource_id,
			"amount": amount,
		})
		remaining -= amount
	if transfers.is_empty():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_NO_EFFECT
		)
	var totals: Dictionary = {}
	for transfer: Dictionary in transfers:
		var resource_id := str(transfer["resource_id"])
		totals[resource_id] = (
			float(totals.get(resource_id, 0.0))
			+ float(transfer["amount"])
		)
	for resource_id: Variant in totals.keys():
		if not store.can_remove(str(resource_id), float(totals[resource_id])):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
				{
					"resource_id": str(resource_id),
					"required": totals[resource_id],
					"available": store.amount(str(resource_id)),
				}
			)
	for resource_id: Variant in totals.keys():
		store.remove(str(resource_id), float(totals[resource_id]))
	for transfer: Dictionary in transfers:
		element.install_material(
			str(transfer["resource_id"]),
			float(transfer["amount"])
		)
	element.bump_state_revision()
	_emit_element_state_changed(element, command.command_id, &"weld")
	return _element_state_result(element, {
		"transfers": transfers,
		"store_id": command.store_id,
	})


func _damage_element(
	command: DamageElementCommand
) -> StructuralCommandResult:
	var element := get_element(command.element_id)
	var state_error := _validate_state_command(
		element,
		command.expected_state_revision
	)
	if state_error != null:
		return state_error
	if not is_finite(command.damage) or command.damage <= 0.0:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	if element.is_broken():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_NO_EFFECT
		)
	element.integrity = maxf(element.integrity - command.damage, 0.0)
	element.bump_state_revision()
	_emit_element_state_changed(element, command.command_id, &"damage")
	return _element_state_result(element)


func _repair_element(
	command: RepairElementCommand
) -> StructuralCommandResult:
	var element := get_element(command.element_id)
	var state_error := _validate_state_command(
		element,
		command.expected_state_revision
	)
	if state_error != null:
		return state_error
	if (
		not is_finite(command.max_material_amount)
		or command.max_material_amount <= 0.0
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var archetype := element.get_archetype()
	var deficit := maxf(archetype.max_integrity - element.integrity, 0.0)
	if deficit <= 0.000001:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_NOT_DAMAGED
		)
	var integrity_per_component := archetype.max_integrity * 0.25
	var material_amount := minf(
		command.max_material_amount,
		deficit / integrity_per_component
	)
	var store := get_resource_store(command.store_id)
	if (
		store == null
		or not store.can_remove("construction_component", material_amount)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
			{
				"resource_id": "construction_component",
				"required": material_amount,
				"available": (
					store.amount("construction_component")
					if store != null else 0.0
				),
			}
		)
	store.remove("construction_component", material_amount)
	element.integrity = minf(
		element.integrity + material_amount * integrity_per_component,
		archetype.max_integrity
	)
	element.bump_state_revision()
	_emit_element_state_changed(element, command.command_id, &"repair")
	return _element_state_result(element, {
		"resource_id": "construction_component",
		"material_used": material_amount,
		"resource_remaining": store.amount("construction_component"),
	})


func _dismantle_element(
	command: DismantleElementCommand
) -> StructuralCommandResult:
	var element := get_element(command.element_id)
	if element == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var assembly := get_assembly_raw(element.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if assembly.topology_revision != command.expected_assembly_revision:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION
		)
	var store := get_resource_store(command.store_id)
	if store == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)

	var removed_joint_ids: Array[int] = []
	var remaining_joints: Array[SimulationJoint] = []
	for joint: SimulationJoint in _joints_for_assembly(assembly.assembly_id):
		if joint.involves_element(element.element_id):
			removed_joint_ids.append(joint.joint_id)
		else:
			remaining_joints.append(joint)
	var remaining_elements: Array[int] = assembly.element_ids.duplicate()
	remaining_elements.erase(element.element_id)
	var components: Array[Array] = []
	var survivor_index := 0
	if not remaining_elements.is_empty():
		components = RuntimeConnectivity.connected_components(
			remaining_elements,
			_elements,
			remaining_joints
		)
		if components.size() > 1:
			var scores: Array[Dictionary] = []
			for component: Array in components:
				scores.append(SurvivorPolicy.component_score(
					component,
					_elements,
					remaining_joints
				))
			survivor_index = SurvivorPolicy.pick_survivor_index(scores)

	var refunds: Dictionary = {}
	for resource_id: Variant in element.installed_materials.keys():
		var amount := float(element.installed_materials[resource_id]) * 0.5
		if amount > 0.000001:
			refunds[str(resource_id)] = amount

	for joint_id: int in removed_joint_ids:
		_joints.erase(joint_id)
	_elements.erase(element.element_id)
	for resource_id: Variant in refunds.keys():
		store.add(str(resource_id), float(refunds[resource_id]))
	removed_joint_ids.sort()

	if remaining_elements.is_empty():
		_assemblies.erase(assembly.assembly_id)
		_emit_structural_event({
			"kind": &"assembly_removed",
			"command_id": command.command_id,
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
		assembly.bump_revision()
		_emit_structural_event({
			"kind": &"assembly_changed",
			"command_id": command.command_id,
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
			(get_element(element_id) as SimulationElement).assembly_id = new_id
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


func _archetype_has_anchor_port(archetype: ElementArchetype) -> bool:
	if archetype == null:
		return false
	for port: PortDefinition in archetype.ports:
		if (
			port != null
			and port.kind == PortDefinition.Kind.MECHANICAL
			and port.compatibility_tags.has("anchor")
		):
			return true
	return false


func _validate_state_command(
	element: SimulationElement,
	expected_state_revision: int
) -> StructuralCommandResult:
	if element == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if element.state_revision != expected_state_revision:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"expected": expected_state_revision,
				"actual": element.state_revision,
			}
		)
	return null


func _emit_element_state_changed(
	element: SimulationElement,
	command_id: int,
	change_kind: StringName
) -> void:
	_emit_structural_event({
		"kind": &"element_state_changed",
		"change_kind": change_kind,
		"command_id": command_id,
		"assembly_id": element.assembly_id,
		"element_id": element.element_id,
		"state_revision": element.state_revision,
		"build_progress": element.build_progress,
		"integrity": element.integrity,
		"status_reason": element.status_reason(),
	})


func _element_state_result(
	element: SimulationElement,
	extra: Dictionary = {}
) -> StructuralCommandResult:
	var data := {
		"assembly_id": element.assembly_id,
		"element_id": element.element_id,
		"state_revision": element.state_revision,
		"build_progress": element.build_progress,
		"integrity": element.integrity,
		"status_reason": element.status_reason(),
	}
	data.merge(extra, true)
	return StructuralCommandResult.ok(data)


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


func _register_resource_store(store: SimulationResourceStore) -> void:
	_resource_stores[store.store_id] = store


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
