class_name ConstructionCommandService
extends RefCounted

static func preview_place_element(world, 
	command: PlaceElementCommand
) -> StructuralCommandResult:
	if command == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	return ConstructionCommandService.validate_place_element(world, command)

static func place_element(world, 
	command: PlaceElementCommand
) -> StructuralCommandResult:
	if (
		PistonPlacementUtil.is_piston_archetype(command.archetype)
		or RotorPlacementUtil.is_rotor_archetype(command.archetype)
		or HingePlacementUtil.is_hinge_archetype(command.archetype)
	):
		return ConstructionCommandService.place_driven_element(world, command)
	var validation: StructuralCommandResult = ConstructionCommandService.validate_place_element(world, command)
	if not validation.is_ok():
		return validation
	var store: SimulationResourceStore = world.get_resource_store(command.store_id)
	var resource_id := str(validation.data["placement_resource_id"])
	var resource_amount := float(validation.data["placement_resource_amount"])
	if not store.remove(resource_id, resource_amount):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL
		)
	if not world._archetypes.register(command.archetype):
		store.add(resource_id, resource_amount)
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)

	var assembly: SimulationAssembly
	var new_assembly := command.assembly_id == 0
	if new_assembly:
		assembly = SimulationAssembly.new()
		assembly.assembly_id = world._allocator.allocate_assembly_id()
		assembly.grid_frame = command.new_assembly_grid_frame.duplicate_transform()
		assembly.motion = (
			command.initial_motion.duplicate_state()
			if command.initial_motion != null
			else AssemblyMotionState.from_grid_frame(assembly.grid_frame)
		)
	else:
		assembly = world.get_assembly_raw(command.assembly_id)

	var element_id: int = world._allocator.allocate_element_id()
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
		# A first block placed on terrain rests on the surface by construction
		# (continuous bottom-face contact), so it always starts anchored.
		var allocate_joint := func() -> int:
			return world._allocator.allocate_joint_id()
		for joint: SimulationJoint in (
			RuntimeConnectivity.materialize_ground_start_anchors(
				assembly.assembly_id,
				[element],
				allocate_joint
			)
		):
			world._joints[joint.joint_id] = joint
			joint_ids.append(joint.joint_id)
		element.terrain_contact = true
		world._assemblies[assembly.assembly_id] = assembly
	else:
		for connection_variant: Variant in validation.data["connections"]:
			var connection: Dictionary = connection_variant
			var joint_id: int = world._allocator.allocate_joint_id()
			var joint := SimulationJoint.rigid(
				joint_id,
				assembly.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				element_id,
				str(connection["new_port_id"])
			)
			world._joints[joint_id] = joint
			joint_ids.append(joint_id)

	world._elements[element_id] = element
	assembly.element_ids.append(element_id)
	assembly.element_ids.sort()
	# Every block placed onto the terrain must anchor immediately, otherwise the
	# whole construction hangs off the single first-block anchor and detaching it
	# frees (and physically ejects) everything else. Non-first blocks are probed
	# live at placement; the fact is stored on the block and re-verified on split.
	if not new_assembly:
		ConstructionCommandService.record_placement_terrain_contact(world, assembly, element, joint_ids)
	assembly.bump_revision()
	world._notify_topology_changed()
	joint_ids.sort()
	var event_kind := &"assembly_spawned" if new_assembly else &"assembly_changed"
	world._emit_structural_event({
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

static func validate_place_element(world, 
	command: PlaceElementCommand
) -> StructuralCommandResult:
	if (
		PistonPlacementUtil.is_piston_archetype(command.archetype)
		or RotorPlacementUtil.is_rotor_archetype(command.archetype)
		or HingePlacementUtil.is_hinge_archetype(command.archetype)
	):
		return ConstructionCommandService.validate_driven_place_element(world, command)
	if WheelPlacementUtil.is_wheel_archetype(command.archetype):
		return ConstructionCommandService.validate_wheel_place_element(world, command)
	var archetype := command.archetype
	if (
		archetype == null
		or archetype.archetype_id.is_empty()
		or archetype.resource_path.is_empty()
		or archetype.internal_archetype
		or command.orientation_index < 0
		or command.orientation_index >= OrientationUtil.ORIENTATION_COUNT
		or archetype.build_requirements.is_empty()
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var archetype_validation: StructuralCommandResult = ConstructionCommandService.validate_construction_archetype(world, 
		archetype,
		command.orientation_index
	)
	if not archetype_validation.is_ok():
		return archetype_validation
	if world._archetypes.has(archetype.archetype_id) and (
		ArchetypeRegistry.fingerprint_of(
			world._archetypes.get_archetype(archetype.archetype_id)
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
	var store: SimulationResourceStore = world.get_resource_store(command.store_id)
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
			or (
				command.initial_motion != null
				and not command.initial_motion.is_valid()
			)
		):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_TRANSFORM
			)
		if RuntimeConnectivity.ground_anchor_port_id(preview).is_empty():
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_ANCHOR_REQUIRED
			)
	else:
		var assembly: SimulationAssembly = world.get_assembly_raw(command.assembly_id)
		if assembly == null or assembly.tombstoned:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_REFERENCE
			)
		if not ConstructionCommandService.construction_attach_allowed(world, assembly.assembly_id):
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
		if world._archetype_has_anchor_port(archetype):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_ANCHOR_NOT_ALLOWED
			)
		var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(world, assembly)
		var preview_cells := preview.occupied_cells()
		for cell: Vector3i in preview_cells:
			if occupancy.has(cell):
				return StructuralCommandResult.failed(
					StructuralCommandResult.REASON_OVERLAP
				)
		# A rigid edge requires adjacent derived structural surface faces, so only
		# elements occupying a neighbour of the preview footprint can ever connect.
		var neighbour_ids: Array[int] = ConstructionOccupancyUtil.neighbour_element_ids(preview_cells, occupancy)
		for existing_id: int in neighbour_ids:
			var existing: SimulationElement = world.get_element(existing_id)
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
		var bridge_error: StructuralCommandResult = ConstructionCommandService.validate_new_rigid_connections(world, 
			assembly.assembly_id,
			preview,
			connections
		)
		if bridge_error != null:
			return bridge_error
		var moving_error: StructuralCommandResult = ConstructionCommandService.validate_driven_head_construction_target(world, 
			connections
		)
		if moving_error != null:
			return moving_error

	return StructuralCommandResult.ok({
		"placement_resource_id": first_requirement.resource_id,
		"placement_resource_amount": placement_amount,
		"connections": connections,
		"build_progress": preview.build_progress,
	})

static func validate_wheel_place_element(world, 
	command: PlaceElementCommand
) -> StructuralCommandResult:
	var archetype := command.archetype
	if (
		archetype == null
		or archetype.wheel_definition == null
		or archetype.internal_archetype
		or command.orientation_index < 0
		or command.orientation_index >= OrientationUtil.ORIENTATION_COUNT
		or archetype.build_requirements.is_empty()
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var archetype_validation: StructuralCommandResult = ConstructionCommandService.validate_construction_archetype(world, 
		archetype,
		command.orientation_index
	)
	if not archetype_validation.is_ok():
		return archetype_validation
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
	var store: SimulationResourceStore = world.get_resource_store(command.store_id)
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
	var wheel_error: Variant = WheelPlacementUtil.validate_wheel_placement(
		world,
		command,
		preview
	)
	if (
		wheel_error is StructuralCommandResult
		and not (wheel_error as StructuralCommandResult).is_ok()
	):
		return wheel_error
	if command.assembly_id == 0:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION,
			{"detail": &"wheel_socket_required"}
		)
	var assembly: SimulationAssembly = world.get_assembly_raw(command.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if not ConstructionCommandService.construction_attach_allowed(world, assembly.assembly_id):
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
	var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(world, assembly)
	var preview_cells := preview.occupied_cells()
	for cell: Vector3i in preview_cells:
		if occupancy.has(cell):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_OVERLAP
			)
	var connections: Array[Dictionary] = []
	var neighbour_ids: Array[int] = ConstructionOccupancyUtil.neighbour_element_ids(preview_cells, occupancy)
	for existing_id: int in neighbour_ids:
		var existing: SimulationElement = world.get_element(existing_id)
		var connection := RuntimeConnectivity.find_rigid_connection(
			existing,
			preview
		)
		if connection.is_empty():
			continue
		if (
			existing.archetype_id == "wheel_suspension"
			and WheelPlacementUtil.wheel_attached_to_suspension(
				world,
				assembly.assembly_id,
				existing_id
			)
		):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION,
				{"detail": &"socket_occupied"}
			)
		connections.append({
			"existing_element_id": existing_id,
			"existing_port_id": connection["left_port_id"],
			"new_port_id": connection["right_port_id"],
		})
	if connections.is_empty():
		var empty_error: Variant = WheelPlacementUtil.validate_wheel_placement(
			world,
			command,
			preview
		)
		if empty_error is StructuralCommandResult:
			return empty_error
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION,
			{"detail": &"wheel_socket_required"}
		)
	var bridge_error: StructuralCommandResult = ConstructionCommandService.validate_new_rigid_connections(world, 
		assembly.assembly_id,
		preview,
		connections
	)
	if bridge_error != null:
		return bridge_error
	var moving_error: StructuralCommandResult = ConstructionCommandService.validate_driven_head_construction_target(world, connections)
	if moving_error != null:
		return moving_error
	return StructuralCommandResult.ok({
		"placement_resource_id": first_requirement.resource_id,
		"placement_resource_amount": placement_amount,
		"connections": connections,
		"build_progress": preview.build_progress,
	})

static func validate_driven_place_element(world, 
	command: PlaceElementCommand
) -> StructuralCommandResult:
	var base_archetype := command.archetype
	var is_rotor := RotorPlacementUtil.is_rotor_archetype(base_archetype)
	var is_hinge := HingePlacementUtil.is_hinge_archetype(base_archetype)
	if (
		base_archetype == null
		or (
			base_archetype.piston_definition == null
			and base_archetype.rotor_definition == null
			and base_archetype.hinge_definition == null
		)
		or base_archetype.internal_archetype
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var head_archetype_id: String
	if is_rotor:
		head_archetype_id = base_archetype.rotor_definition.top_archetype_id
	elif is_hinge:
		head_archetype_id = base_archetype.hinge_definition.top_archetype_id
	else:
		head_archetype_id = base_archetype.piston_definition.head_archetype_id
	var head_archetype: ElementArchetype = world._archetypes.get_archetype(head_archetype_id)
	var definition_errors: Array[String]
	if is_rotor:
		definition_errors = RotorPlacementUtil.validate_rotor_archetype(
			base_archetype,
			head_archetype,
			world._archetypes
		)
	elif is_hinge:
		definition_errors = HingePlacementUtil.validate_hinge_archetype(
			base_archetype,
			head_archetype,
			world._archetypes
		)
	else:
		definition_errors = PistonPlacementUtil.validate_piston_archetype(
			base_archetype,
			head_archetype,
			world._archetypes
		)
	for error_text: String in definition_errors:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"detail": error_text}
		)
	var archetype_validation: StructuralCommandResult = ConstructionCommandService.validate_construction_archetype(world, 
		base_archetype,
		command.orientation_index
	)
	if not archetype_validation.is_ok():
		return archetype_validation
	if head_archetype == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"detail": &"missing_head_archetype"}
		)
	if not world._archetypes.register(head_archetype):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)
	var first_requirement: BuildRequirement = base_archetype.build_requirements[0]
	if first_requirement == null or first_requirement.resource_id.is_empty():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var placement_amount := minf(first_requirement.amount, 1.0)
	var store: SimulationResourceStore = world.get_resource_store(command.store_id)
	if store == null or not store.can_remove(
		first_requirement.resource_id,
		placement_amount
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL
		)
	var previews: Dictionary
	if is_rotor:
		previews = RotorPlacementUtil.preview_elements(
			command,
			head_archetype,
			first_requirement.resource_id,
			placement_amount
		)
	elif is_hinge:
		previews = HingePlacementUtil.preview_elements(
			command,
			head_archetype,
			first_requirement.resource_id,
			placement_amount
		)
	else:
		previews = PistonPlacementUtil.preview_elements(
			command,
			head_archetype,
			first_requirement.resource_id,
			placement_amount
		)
	var base_preview: SimulationElement = previews["base"]
	var head_preview: SimulationElement = previews["head"]
	if RuntimeConnectivity.elements_have_rigid_connection(
		base_preview,
		head_preview
	):
		var home_conflict_detail := &"piston_home_rigid_conflict"
		if is_rotor:
			home_conflict_detail = &"rotor_home_rigid_conflict"
		elif is_hinge:
			home_conflict_detail = &"hinge_home_rigid_conflict"
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"detail": home_conflict_detail}
		)

	var base_connections: Array[Dictionary] = []
	var head_connections: Array[Dictionary] = []
	if command.assembly_id == 0:
		if (
			command.new_assembly_grid_frame == null
			or not command.new_assembly_grid_frame.is_valid()
		):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_TRANSFORM
			)
		if RuntimeConnectivity.ground_anchor_port_id(base_preview).is_empty():
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_ANCHOR_REQUIRED
			)
	else:
		var assembly: SimulationAssembly = world.get_assembly_raw(command.assembly_id)
		if assembly == null or assembly.tombstoned:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_REFERENCE
			)
		if not ConstructionCommandService.construction_attach_allowed(world, assembly.assembly_id):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_TARGET,
				{"detail": &"mobile_construction_not_supported"}
			)
		if assembly.topology_revision != command.expected_assembly_revision:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_STALE_REVISION
			)
		var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(world, assembly)
		for preview: SimulationElement in [base_preview, head_preview]:
			for cell: Vector3i in preview.occupied_cells():
				if occupancy.has(cell):
					return StructuralCommandResult.failed(
						StructuralCommandResult.REASON_OVERLAP
					)
		base_connections = PistonPlacementUtil.collect_rigid_connections(
			world,
			assembly.assembly_id,
			base_preview,
			[-2]
		)
		head_connections = PistonPlacementUtil.collect_rigid_connections(
			world,
			assembly.assembly_id,
			head_preview,
			[-1]
		)
		if base_connections.is_empty():
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
			)
		for connections: Array in [base_connections, head_connections]:
			var bridge_error: StructuralCommandResult = ConstructionCommandService.validate_new_rigid_connections(world, 
				assembly.assembly_id,
				base_preview,
				connections
			)
			if bridge_error != null:
				return bridge_error
		var moving_error: StructuralCommandResult = ConstructionCommandService.validate_driven_head_construction_target(world, 
			head_connections
		)
		if moving_error != null:
			return moving_error
		var chain_error: StructuralCommandResult = (
			ConstructionCommandService.validate_prospective_driven_compile(
				world,
				assembly.assembly_id,
				base_preview,
				head_preview,
				base_connections,
				head_connections,
				command.archetype,
				is_rotor,
				is_hinge
			)
		)
		if chain_error != null:
			return chain_error

	return StructuralCommandResult.ok({
		"placement_resource_id": first_requirement.resource_id,
		"placement_resource_amount": placement_amount,
		"base_connections": base_connections,
		"head_connections": head_connections,
		"head_archetype": head_archetype,
		"build_progress": base_preview.build_progress,
	})

static func place_driven_element(world, 
	command: PlaceElementCommand
) -> StructuralCommandResult:
	var is_rotor := RotorPlacementUtil.is_rotor_archetype(command.archetype)
	var is_hinge := HingePlacementUtil.is_hinge_archetype(command.archetype)
	var validation: StructuralCommandResult = ConstructionCommandService.validate_driven_place_element(world, command)
	if not validation.is_ok():
		return validation
	var store: SimulationResourceStore = world.get_resource_store(command.store_id)
	var resource_id := str(validation.data["placement_resource_id"])
	var resource_amount := float(validation.data["placement_resource_amount"])
	if not store.remove(resource_id, resource_amount):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL
		)
	if not world._archetypes.register(command.archetype):
		store.add(resource_id, resource_amount)
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)
	var head_archetype: ElementArchetype = validation.data["head_archetype"]
	if not world._archetypes.register(head_archetype):
		store.add(resource_id, resource_amount)
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)

	var assembly: SimulationAssembly
	var new_assembly := command.assembly_id == 0
	if new_assembly:
		assembly = SimulationAssembly.new()
		assembly.assembly_id = world._allocator.allocate_assembly_id()
		assembly.grid_frame = command.new_assembly_grid_frame.duplicate_transform()
		assembly.motion = (
			command.initial_motion.duplicate_state()
			if command.initial_motion != null
			else AssemblyMotionState.from_grid_frame(assembly.grid_frame)
		)
	else:
		assembly = world.get_assembly_raw(command.assembly_id)

	var base_element_id: int = world._allocator.allocate_element_id()
	var head_element_id: int = world._allocator.allocate_element_id()
	var base_element := SimulationElement.frame(
		base_element_id,
		assembly.assembly_id,
		command.archetype,
		command.origin_cell,
		command.orientation_index,
		{resource_id: resource_amount}
	)
	var head_origin: Vector3i
	if is_rotor:
		head_origin = RotorPlacementUtil.top_origin_cell(
			command.origin_cell,
			command.orientation_index,
			command.archetype.rotor_definition
		)
	elif is_hinge:
		head_origin = HingePlacementUtil.top_origin_cell(
			command.origin_cell,
			command.orientation_index,
			command.archetype.hinge_definition
		)
	else:
		head_origin = PistonPlacementUtil.head_origin_cell(
			command.origin_cell,
			command.orientation_index,
			command.archetype.piston_definition
		)
	var head_element := SimulationElement.frame(
		head_element_id,
		assembly.assembly_id,
		head_archetype,
		head_origin,
		command.orientation_index,
		{}
	)
	head_element.apply_placement_integrity()
	head_element.condition = base_element.condition

	var joint_ids: Array[int] = []
	var driven_joint_id: int = world._allocator.allocate_joint_id()
	var driven_joint: SimulationJoint
	if is_rotor:
		driven_joint = SimulationJoint.rotor(
			driven_joint_id,
			assembly.assembly_id,
			base_element_id,
			head_element_id,
			command.archetype.rotor_definition
		)
	elif is_hinge:
		driven_joint = SimulationJoint.hinge(
			driven_joint_id,
			assembly.assembly_id,
			base_element_id,
			head_element_id,
			command.archetype.hinge_definition
		)
	else:
		driven_joint = SimulationJoint.piston(
			driven_joint_id,
			assembly.assembly_id,
			base_element_id,
			head_element_id,
			command.archetype.piston_definition
		)
	world._joints[driven_joint_id] = driven_joint
	joint_ids.append(driven_joint_id)

	if new_assembly:
		var allocate_joint := func() -> int:
			return world._allocator.allocate_joint_id()
		for joint: SimulationJoint in (
			RuntimeConnectivity.materialize_ground_start_anchors(
				assembly.assembly_id,
				[base_element],
				allocate_joint
			)
		):
			world._joints[joint.joint_id] = joint
			joint_ids.append(joint.joint_id)
		base_element.terrain_contact = true
		world._assemblies[assembly.assembly_id] = assembly
	else:
		for connection_variant: Variant in validation.data["base_connections"]:
			var connection: Dictionary = connection_variant
			var joint_id: int = world._allocator.allocate_joint_id()
			world._joints[joint_id] = SimulationJoint.rigid(
				joint_id,
				assembly.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				base_element_id,
				str(connection["new_port_id"])
			)
			joint_ids.append(joint_id)
		for connection_variant: Variant in validation.data["head_connections"]:
			var connection: Dictionary = connection_variant
			var joint_id: int = world._allocator.allocate_joint_id()
			world._joints[joint_id] = SimulationJoint.rigid(
				joint_id,
				assembly.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				head_element_id,
				str(connection["new_port_id"])
			)
			joint_ids.append(joint_id)

	world._elements[base_element_id] = base_element
	world._elements[head_element_id] = head_element
	assembly.element_ids.append(base_element_id)
	assembly.element_ids.append(head_element_id)
	assembly.element_ids.sort()
	if not new_assembly:
		ConstructionCommandService.record_placement_terrain_contact(world, assembly, base_element, joint_ids)
	assembly.bump_revision()
	world._notify_topology_changed()
	joint_ids.sort()
	var event_kind := &"assembly_spawned" if new_assembly else &"assembly_changed"
	var joint_id_key := "piston_joint_id"
	if is_rotor:
		joint_id_key = "rotor_joint_id"
	elif is_hinge:
		joint_id_key = "hinge_joint_id"
	world._emit_structural_event({
		"kind": event_kind,
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_ids": assembly.element_ids.duplicate(),
		"placed_element_id": base_element_id,
		"placed_head_element_id": head_element_id,
		joint_id_key: driven_joint_id,
		"driven_joint_id": driven_joint_id,
		"joint_ids": joint_ids,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_id": base_element_id,
		"head_element_id": head_element_id,
		joint_id_key: driven_joint_id,
		"driven_joint_id": driven_joint_id,
		"state_revision": base_element.state_revision,
		"build_progress": base_element.build_progress,
		"joint_ids": joint_ids,
		"resource_id": resource_id,
		"resource_remaining": store.amount(resource_id),
	})

static func validate_prospective_driven_compile(
	world,
	assembly_id: int,
	base_preview: SimulationElement,
	head_preview: SimulationElement,
	base_connections: Array[Dictionary],
	head_connections: Array[Dictionary],
	base_archetype: ElementArchetype,
	is_rotor: bool,
	is_hinge: bool
) -> StructuralCommandResult:
	var assembly: SimulationAssembly = world.get_assembly_raw(assembly_id)
	if assembly == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var elements_by_id: Dictionary = {}
	for element_id: int in assembly.element_ids:
		elements_by_id[element_id] = world.get_element(element_id)
	var driven_joint: SimulationJoint
	if is_rotor:
		driven_joint = SimulationJoint.rotor(
			-1,
			assembly_id,
			base_preview.element_id,
			head_preview.element_id,
			base_archetype.rotor_definition
		)
	elif is_hinge:
		driven_joint = SimulationJoint.hinge(
			-1,
			assembly_id,
			base_preview.element_id,
			head_preview.element_id,
			base_archetype.hinge_definition
		)
	else:
		driven_joint = SimulationJoint.piston(
			-1,
			assembly_id,
			base_preview.element_id,
			head_preview.element_id,
			base_archetype.piston_definition
		)
	var compiled := BodyGroupCompiler.compile_prospective_driven_place(
		assembly.element_ids,
		elements_by_id,
		world._joints_for_assembly(assembly_id),
		base_preview,
		head_preview,
		base_connections,
		head_connections,
		driven_joint
	)
	if bool(compiled.get("valid", false)):
		return null
	var reason := StringName(compiled.get("reason", &"invalid_body_groups"))
	if reason == &"driven_joint_chain_too_long":
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_DRIVEN_JOINT_CHAIN_TOO_LONG
		)
	if reason == &"driven_joint_cycle":
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_DRIVEN_JOINT_CYCLE
		)
	return StructuralCommandResult.failed(
		StructuralCommandResult.REASON_INVALID_TARGET,
		{"detail": reason}
	)

static func validate_new_rigid_connections(world,
	assembly_id: int,
	_preview: SimulationElement,
	connections: Array[Dictionary]
) -> StructuralCommandResult:
	if connections.is_empty():
		return null
	var assembly: SimulationAssembly = world.get_assembly_raw(assembly_id)
	if assembly == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var compiled: Dictionary = world.compile_body_groups(assembly_id)
	if not bool(compiled.get("valid", false)):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"detail": compiled.get("reason", &"invalid_body_groups")}
		)
	var touched_groups: Dictionary = {}
	for connection_variant: Variant in connections:
		var connection: Dictionary = connection_variant
		var existing_id := int(connection["existing_element_id"])
		var group_id := int(
			(compiled["element_to_group"] as Dictionary).get(existing_id, 0)
		)
		if group_id <= 0:
			continue
		touched_groups[group_id] = true
	if touched_groups.size() <= 1:
		return null
	for spec_variant: Variant in compiled["driven_specs"]:
		var spec: Dictionary = spec_variant
		var left := int(spec["base_group_id"])
		var right := int(spec["head_group_id"])
		if touched_groups.has(left) and touched_groups.has(right):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_DRIVEN_JOINT_CYCLE
			)
	return null

static func validate_driven_head_construction_target(world, 
	head_connections: Array[Dictionary]
) -> StructuralCommandResult:
	if head_connections.is_empty():
		return null
	for connection_variant: Variant in head_connections:
		var connection: Dictionary = connection_variant
		var existing: SimulationElement = world.get_element(int(connection["existing_element_id"]))
		if existing == null:
			continue
		var path_error := _validate_driven_path_home_for_element(
			world,
			existing
		)
		if path_error != null:
			return path_error
	return null


## Every driven joint on the path from the target element group to root must
## be at home / idle — not only when the snap face is a hub endpoint.
static func _validate_driven_path_home_for_element(
	world,
	existing: SimulationElement
) -> StructuralCommandResult:
	if world == null or existing == null:
		return null
	var compiled: Dictionary = world.compile_body_groups(existing.assembly_id)
	if not bool(compiled.get("valid", false)):
		return null
	var element_to_group: Dictionary = compiled.get("element_to_group", {})
	var group_id := int(element_to_group.get(existing.element_id, 0))
	if group_id <= 0:
		return null
	var head_to_joint: Dictionary = {}
	for spec_variant: Variant in compiled.get("driven_specs", []):
		if not spec_variant is Dictionary:
			continue
		var spec: Dictionary = spec_variant
		head_to_joint[int(spec.get("head_group_id", 0))] = int(
			spec.get("joint_id", 0)
		)
	var guard := 0
	while group_id > 0 and guard < 16:
		guard += 1
		if not head_to_joint.has(group_id):
			break
		var joint: SimulationJoint = world.get_joint(
			int(head_to_joint[group_id])
		)
		if joint == null or joint.motor == null:
			break
		var home_error := _driven_joint_not_home_result(joint)
		if home_error != null:
			return home_error
		var base_group := 0
		for spec_variant: Variant in compiled.get("driven_specs", []):
			if not spec_variant is Dictionary:
				continue
			var spec: Dictionary = spec_variant
			if int(spec.get("joint_id", 0)) == joint.joint_id:
				base_group = int(spec.get("base_group_id", 0))
				break
		if base_group <= 0 or base_group == group_id:
			break
		group_id = base_group
	return null


static func _driven_joint_not_home_result(
	joint: SimulationJoint
) -> StructuralCommandResult:
	var motor := joint.motor
	var at_home := true
	if joint.kind in [
		SimulationJoint.Kind.ROTOR,
		SimulationJoint.Kind.HINGE,
	]:
		# Angular home is 0 rad for both; wrap is a no-op inside
		# hinge limits and required for the continuous rotor.
		at_home = (
			absf(SimulationMotorState.wrap_angle(motor.observed_position_m))
			<= SimulationMotorState.OVERLOAD_ERROR_M
		)
	else:
		at_home = is_equal_approx(
			motor.observed_position_m,
			motor.lower_limit_m
		)
	if not at_home:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_MOVING_TARGET_NOT_SUPPORTED
		)
	if absf(motor.observed_velocity_mps) > SimulationMotorState.OVERLOAD_VELOCITY_MPS:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_MOVING_TARGET_NOT_SUPPORTED
		)
	return null

static func validate_construction_archetype(world, 
	archetype: ElementArchetype,
	orientation_index: int
) -> StructuralCommandResult:
	if (
		orientation_index < 0
		or orientation_index >= OrientationUtil.ORIENTATION_COUNT
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	# Archetype world-validation depends only on the archetype definition, not on
	# where or how it is placed, so cache it by identity + fingerprint instead of
	# rebuilding a throwaway Blueprint on every preview/plan call.
	var cache_key := archetype.get_instance_id()
	var fingerprint := ArchetypeRegistry.fingerprint_of(archetype)
	var cached: Dictionary = world._archetype_validation_cache.get(cache_key, {})
	if str(cached.get("fingerprint", "")) != fingerprint:
		var validation := BlueprintValidator.validate_archetype(archetype)
		cached = {
			"fingerprint": fingerprint,
			"ok": validation.ok,
			"errors": validation.errors.duplicate(),
			"footprint_empty": archetype.footprint_cells.is_empty(),
		}
		world._archetype_validation_cache[cache_key] = cached
	if not bool(cached.get("ok", false)) or bool(cached.get("footprint_empty", true)):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"errors": cached.get("errors", [])}
		)
	return StructuralCommandResult.ok()

static func weld_element(world, 
	command: WeldElementCommand
) -> StructuralCommandResult:
	var element: SimulationElement = world.get_element(command.element_id)
	var state_error: StructuralCommandResult = world._validate_state_command(
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
	var was_operational := element.is_operational()
	var store: SimulationResourceStore = world.get_resource_store(command.store_id)
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
		var deficit := maxf(archetype.max_integrity - element.integrity, 0.0)
		if deficit <= 0.000001:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_ALREADY_COMPLETE
			)
		var integrity_per_component := (
			archetype.max_integrity
			* SimulationElement.weld_repair_integrity_fraction()
		)
		var material_amount := minf(
			command.max_material_amount,
			deficit / integrity_per_component
		)
		if ResourceCatalog.is_discrete("construction_component"):
			material_amount = ceilf(material_amount - 0.000001)
		if material_amount <= 0.000001:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
				{
					"resource_id": "construction_component",
					"required": material_amount,
					"available": store.amount("construction_component"),
				}
			)
		if not store.can_remove("construction_component", material_amount):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
				{
					"resource_id": "construction_component",
					"required": material_amount,
					"available": store.amount("construction_component"),
				}
			)
		store.remove("construction_component", material_amount)
		element.integrity = minf(
			element.integrity + material_amount * integrity_per_component,
			archetype.max_integrity
		)
		element.sync_build_progress_from_integrity()
		element.bump_state_revision()
		world._emit_element_state_changed(
			element,
			command.command_id,
			&"weld",
			was_operational != element.is_operational()
		)
		return world._element_state_result(element, {
			"transfers": [{
				"resource_id": "construction_component",
				"amount": material_amount,
			}],
			"store_id": command.store_id,
		})
	var totals: Dictionary = {}
	for transfer: Dictionary in transfers:
		var resource_id := str(transfer["resource_id"])
		totals[resource_id] = (
			float(totals.get(resource_id, 0.0))
			+ float(transfer["amount"])
		)
	for resource_id: Variant in totals.keys():
		var amount := float(totals[resource_id])
		if ResourceCatalog.is_discrete(str(resource_id)):
			amount = floorf(amount + 0.000001)
		if amount <= 0.000001:
			continue
		if not store.can_remove(str(resource_id), amount):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
				{
					"resource_id": str(resource_id),
					"required": totals[resource_id],
					"available": store.amount(str(resource_id)),
				}
			)
	for resource_id: Variant in totals.keys():
		var amount := float(totals[resource_id])
		if ResourceCatalog.is_discrete(str(resource_id)):
			amount = floorf(amount + 0.000001)
		if amount <= 0.000001:
			continue
		store.remove(str(resource_id), amount)
	for transfer: Dictionary in transfers:
		element.install_material(
			str(transfer["resource_id"]),
			float(transfer["amount"])
		)
	element.bump_state_revision()
	world._emit_element_state_changed(
		element,
		command.command_id,
		&"weld",
		was_operational != element.is_operational()
	)
	return world._element_state_result(element, {
		"transfers": transfers,
		"store_id": command.store_id,
	})

static func damage_element(world, 
	command: DamageElementCommand
) -> StructuralCommandResult:
	var element: SimulationElement = world.get_element(command.element_id)
	var state_error: StructuralCommandResult = world._validate_state_command(
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
	element.sync_build_progress_from_integrity()
	if element.integrity <= 0.000001:
		var refund_store: SimulationResourceStore = null
		if command.refund_fraction_on_destroy > 0.000001:
			refund_store = world.get_resource_store(command.store_id)
		return world._remove_element_from_topology(
			element,
			command.command_id,
			command.refund_fraction_on_destroy,
			refund_store
		)
	element.bump_state_revision()
	world._emit_element_state_changed(element, command.command_id, &"damage")
	return world._element_state_result(element)

static func repair_element(world, 
	command: RepairElementCommand
) -> StructuralCommandResult:
	var element: SimulationElement = world.get_element(command.element_id)
	var state_error: StructuralCommandResult = world._validate_state_command(
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
	var was_operational := element.is_operational()
	var integrity_per_component := archetype.max_integrity * 0.25
	var material_amount := minf(
		command.max_material_amount,
		deficit / integrity_per_component
	)
	if ResourceCatalog.is_discrete("construction_component"):
		material_amount = ceilf(material_amount - 0.000001)
	if material_amount <= 0.000001:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
			{
				"resource_id": "construction_component",
				"required": material_amount,
				"available": 0.0,
			}
		)
	var store: SimulationResourceStore = world.get_resource_store(command.store_id)
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
	world._emit_element_state_changed(
		element,
		command.command_id,
		&"repair",
		was_operational != element.is_operational()
	)
	return world._element_state_result(element, {
		"resource_id": "construction_component",
		"material_used": material_amount,
		"resource_remaining": store.amount("construction_component"),
	})

static func dismantle_element(world, 
	command: DismantleElementCommand
) -> StructuralCommandResult:
	var element: SimulationElement = world.get_element(command.element_id)
	if element == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var assembly: SimulationAssembly = world.get_assembly_raw(element.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if assembly.topology_revision != command.expected_assembly_revision:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION
		)
	var store: SimulationResourceStore = world.get_resource_store(command.store_id)
	if store == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	return world._remove_element_from_topology(
		element,
		command.command_id,
		GameBalance.construction_float("dismantle_refund_fraction", 0.5),
		store
	)

static func should_reconcile_assembly(world, assembly_id: int) -> bool:
	var assembly: SimulationAssembly = world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return false
	# Vehicles never terrain-anchor: a construction block bolted onto a rover
	# must not weld the rover to the ground (or churn anchor reconciles with
	# revision bumps every terrain edit).
	if ThrusterSimulationService.is_mobile_assembly(world, assembly_id):
		return false
	for element_id: int in assembly.element_ids:
		var element: SimulationElement = world.get_element(element_id)
		if (
			element != null
			and TerrainAnchorProbe.is_construction_archetype(
				element.archetype_id
			)
		):
			return true
	return false

static func reconcile_terrain_anchors_for_assemblies(world, 
	assembly_ids: Array[int]
) -> void:
	if not world._terrain_contact_probe.is_valid():
		return
	var unique_ids: Dictionary = {}
	for assembly_id_variant: Variant in assembly_ids:
		var assembly_id := int(assembly_id_variant)
		if assembly_id <= 0 or unique_ids.has(assembly_id):
			continue
		if not ConstructionCommandService.should_reconcile_assembly(world, assembly_id):
			continue
		unique_ids[assembly_id] = true
		var assembly: SimulationAssembly = world.get_assembly_raw(assembly_id)
		if assembly == null or assembly.tombstoned:
			continue
		var elements: Array[SimulationElement] = []
		for element_id: int in assembly.element_ids:
			var element: SimulationElement = world.get_element(element_id)
			if (
				element != null
				and TerrainAnchorProbe.is_construction_archetype(
					element.archetype_id
				)
			):
				elements.append(element)
		if elements.is_empty():
			continue
		var touching_variant: Variant = world._terrain_contact_probe.call(
			assembly,
			elements
		)
		if touching_variant is not Array:
			continue
		var touching: Array[int] = []
		for entry: Variant in touching_variant:
			touching.append(int(entry))
		# Probe can miss (collider on terrain child, etc.). Never mass-strip anchors
		# when we already know some blocks were grounded.
		if touching.is_empty():
			for joint: SimulationJoint in world._joints_for_assembly(assembly_id):
				if joint.kind != SimulationJoint.Kind.ANCHOR:
					continue
				for element: SimulationElement in elements:
					if element.element_id == joint.element_a_id:
						touching.append(joint.element_a_id)
						break
			touching.sort()
		# Re-verify and persist the terrain-contact fact per block: the terrain is
		# destructible, so a block that used to sit on ground may now float (and
		# vice versa) after a split/dismantle.
		var touching_lookup: Dictionary = {}
		for touching_id: int in touching:
			touching_lookup[touching_id] = true
		for element: SimulationElement in elements:
			element.terrain_contact = touching_lookup.has(element.element_id)
		var result: Dictionary = RuntimeConnectivity.reconcile_terrain_anchors(
			assembly_id,
			elements,
			world._joints_for_assembly(assembly_id),
			touching,
			func() -> int:
				return world._allocator.allocate_joint_id()
		)
		var changed := false
		for removed_id: int in result["removed_joint_ids"]:
			if world._joints.erase(removed_id):
				changed = true
		for added_joint: SimulationJoint in result["added_joints"]:
			world._joints[added_joint.joint_id] = added_joint
			changed = true
		if changed:
			assembly.bump_revision()
			world._notify_topology_changed()

static func record_placement_terrain_contact(world, 
	assembly: SimulationAssembly,
	element: SimulationElement,
	joint_ids: Array[int]
) -> void:
	if not TerrainAnchorProbe.is_construction_archetype(element.archetype_id):
		return
	# See should_reconcile_assembly: blocks placed on vehicles never anchor.
	if ThrusterSimulationService.is_mobile_assembly(world, assembly.assembly_id):
		return
	if not world._terrain_contact_probe.is_valid():
		return
	var touching: Array[int] = ConstructionCommandService.probe_touching_ids(world, assembly, [element])
	element.terrain_contact = touching.has(element.element_id)
	if not element.terrain_contact:
		return
	if ConstructionCommandService.element_anchor_joint_id(world, assembly.assembly_id, element.element_id) != 0:
		return
	var port_id := RuntimeConnectivity.ground_anchor_port_id(element)
	if port_id.is_empty():
		return
	var joint_id: int = world._allocator.allocate_joint_id()
	world._joints[joint_id] = SimulationJoint.anchor(
		joint_id,
		assembly.assembly_id,
		element.element_id,
		port_id
	)
	joint_ids.append(joint_id)

static func probe_touching_ids(world, 
	assembly: SimulationAssembly,
	elements: Array[SimulationElement]
) -> Array[int]:
	var out: Array[int] = []
	if not world._terrain_contact_probe.is_valid():
		return out
	var touching_variant: Variant = world._terrain_contact_probe.call(
		assembly,
		elements
	)
	if touching_variant is Array:
		for entry: Variant in touching_variant:
			out.append(int(entry))
	return out

static func element_anchor_joint_id(world, assembly_id: int, element_id: int) -> int:
	for joint_variant: Variant in world._joints.values():
		var joint: SimulationJoint = joint_variant
		if (
			joint.assembly_id == assembly_id
			and joint.kind == SimulationJoint.Kind.ANCHOR
			and joint.element_a_id == element_id
		):
			return joint.joint_id
	return 0

static func assembly_has_anchor(world, assembly_id: int) -> bool:
	for joint_variant: Variant in world._joints.values():
		var joint: SimulationJoint = joint_variant
		if (
			joint.assembly_id == assembly_id
			and joint.kind == SimulationJoint.Kind.ANCHOR
		):
			return true
	return false

## Terrain-anchored builds always attach. Floating locomotives may expand only
## while nearly stopped (parking brake or coast-to-stop).
static func construction_attach_allowed(world, assembly_id: int) -> bool:
	if ConstructionCommandService.assembly_has_anchor(world, assembly_id):
		return true
	if not ThrusterSimulationService.is_mobile_assembly(world, assembly_id):
		return false
	var assembly: SimulationAssembly = world.get_assembly_raw(assembly_id)
	if assembly == null:
		return false
	var eps := AssemblyLocomotionController.PARKING_BRAKE_SPEED_EPS
	return (
		assembly.motion.linear_velocity.length() < eps
		and assembly.motion.angular_velocity.length() < eps
	)
