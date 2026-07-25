class_name ConstructionCommandService
extends RefCounted

static func preview_place_element(world, 
	command: PlaceElementCommand
) -> StructuralCommandResult:
	if command == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	return ConstructionPlaceValidationService.validate_place_element(world, command)

static func place_element(world, 
	command: PlaceElementCommand
) -> StructuralCommandResult:
	if (
		PistonPlacementUtil.is_piston_archetype(command.archetype)
		or RotorPlacementUtil.is_rotor_archetype(command.archetype)
		or HingePlacementUtil.is_hinge_archetype(command.archetype)
	):
		return ConstructionCommandService.place_driven_element(world, command)
	var validation: StructuralCommandResult = ConstructionPlaceValidationService.validate_place_element(world, command)
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
	element.pose_offset = command.pose_offset
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
			world._register_joint(joint)
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
			world._register_joint(joint)
			joint_ids.append(joint_id)

	world._elements[element_id] = element
	assembly.element_ids.append(element_id)
	assembly.element_ids.sort()
	# Every block placed onto the terrain must anchor immediately, otherwise the
	# whole construction hangs off the single first-block anchor and detaching it
	# frees (and physically ejects) everything else. Non-first blocks are probed
	# live at placement; the fact is stored on the block and re-verified on split.
	if not new_assembly:
		ConstructionTerrainAnchorService.record_placement_terrain_contact(world, assembly, element, joint_ids)
	IndustryStoreService.sync_element_storage(world, element, true)
	assembly.bump_revision()
	world._notify_topology_changed(assembly.assembly_id)
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

static func place_driven_element(world, 
	command: PlaceElementCommand
) -> StructuralCommandResult:
	var is_rotor := RotorPlacementUtil.is_rotor_archetype(command.archetype)
	var is_hinge := HingePlacementUtil.is_hinge_archetype(command.archetype)
	var validation: StructuralCommandResult = ConstructionPlaceValidationService.validate_driven_place_element(world, command)
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
	base_element.pose_offset = command.pose_offset
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
	world._register_joint(driven_joint)
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
			world._register_joint(joint)
			joint_ids.append(joint.joint_id)
		base_element.terrain_contact = true
		world._assemblies[assembly.assembly_id] = assembly
	else:
		for connection_variant: Variant in validation.data["base_connections"]:
			var connection: Dictionary = connection_variant
			var joint_id: int = world._allocator.allocate_joint_id()
			world._register_joint(SimulationJoint.rigid(
				joint_id,
				assembly.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				base_element_id,
				str(connection["new_port_id"])
			))
			joint_ids.append(joint_id)
		for connection_variant: Variant in validation.data["head_connections"]:
			var connection: Dictionary = connection_variant
			var joint_id: int = world._allocator.allocate_joint_id()
			world._register_joint(SimulationJoint.rigid(
				joint_id,
				assembly.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				head_element_id,
				str(connection["new_port_id"])
			))
			joint_ids.append(joint_id)

	world._elements[base_element_id] = base_element
	world._elements[head_element_id] = head_element
	assembly.element_ids.append(base_element_id)
	assembly.element_ids.append(head_element_id)
	assembly.element_ids.sort()
	if not new_assembly:
		ConstructionTerrainAnchorService.record_placement_terrain_contact(world, assembly, base_element, joint_ids)
	IndustryStoreService.sync_element_storage(world, base_element, true)
	IndustryStoreService.sync_element_storage(world, head_element, true)
	assembly.bump_revision()
	world._notify_topology_changed(assembly.assembly_id)
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

# --- Place validation → ConstructionPlaceValidationService -------------------

static func validate_place_element(world,
	command: PlaceElementCommand
) -> StructuralCommandResult:
	return ConstructionPlaceValidationService.validate_place_element(world, command)

static func validate_wheel_place_element(world,
	command: PlaceElementCommand
) -> StructuralCommandResult:
	return ConstructionPlaceValidationService.validate_wheel_place_element(world, command)

static func validate_driven_place_element(world,
	command: PlaceElementCommand
) -> StructuralCommandResult:
	return ConstructionPlaceValidationService.validate_driven_place_element(world, command)

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
	return ConstructionPlaceValidationService.validate_prospective_driven_compile(
		world,
		assembly_id,
		base_preview,
		head_preview,
		base_connections,
		head_connections,
		base_archetype,
		is_rotor,
		is_hinge
	)

static func validate_new_rigid_connections(world,
	assembly_id: int,
	preview: SimulationElement,
	connections: Array[Dictionary]
) -> StructuralCommandResult:
	return ConstructionPlaceValidationService.validate_new_rigid_connections(
		world,
		assembly_id,
		preview,
		connections
	)

static func validate_driven_head_construction_target(world,
	head_connections: Array[Dictionary]
) -> StructuralCommandResult:
	return ConstructionPlaceValidationService.validate_driven_head_construction_target(
		world,
		head_connections
	)

## True when every driven joint on the path from element → root is idle.
## Used by magnetic snap / construction — pose may be extended or bent; live
## group frames keep attach geometry correct (see POC-ACTUATORS-V1).
static func is_driven_path_at_home(
	world,
	element_id: int
) -> bool:
	return ConstructionPlaceValidationService.is_driven_path_at_home(world, element_id)

static func validate_construction_archetype(world,
	archetype: ElementArchetype,
	orientation_index: int
) -> StructuralCommandResult:
	return ConstructionPlaceValidationService.validate_construction_archetype(
		world,
		archetype,
		orientation_index
	)

# --- Element lifecycle → ConstructionElementLifecycleService -----------------

static func weld_element(world,
	command: WeldElementCommand
) -> StructuralCommandResult:
	return ConstructionElementLifecycleService.weld_element(world, command)

static func damage_element(world,
	command: DamageElementCommand
) -> StructuralCommandResult:
	return ConstructionElementLifecycleService.damage_element(world, command)

static func repair_element(world,
	command: RepairElementCommand
) -> StructuralCommandResult:
	return ConstructionElementLifecycleService.repair_element(world, command)

static func dismantle_element(world,
	command: DismantleElementCommand
) -> StructuralCommandResult:
	return ConstructionElementLifecycleService.dismantle_element(world, command)

# --- Terrain anchors → ConstructionTerrainAnchorService ----------------------

static func should_reconcile_assembly(world, assembly_id: int) -> bool:
	return ConstructionTerrainAnchorService.should_reconcile_assembly(world, assembly_id)

static func reconcile_terrain_anchors_for_assemblies(world,
	assembly_ids: Array[int]
) -> void:
	ConstructionTerrainAnchorService.reconcile_terrain_anchors_for_assemblies(
		world,
		assembly_ids
	)

static func record_placement_terrain_contact(world,
	assembly: SimulationAssembly,
	element: SimulationElement,
	joint_ids: Array[int]
) -> void:
	ConstructionTerrainAnchorService.record_placement_terrain_contact(
		world,
		assembly,
		element,
		joint_ids
	)

static func probe_touching_ids(world,
	assembly: SimulationAssembly,
	elements: Array[SimulationElement]
) -> Array[int]:
	return ConstructionTerrainAnchorService.probe_touching_ids(world, assembly, elements)

static func element_anchor_joint_id(world, assembly_id: int, element_id: int) -> int:
	return ConstructionTerrainAnchorService.element_anchor_joint_id(
		world,
		assembly_id,
		element_id
	)

static func assembly_has_anchor(world, assembly_id: int) -> bool:
	return ConstructionTerrainAnchorService.assembly_has_anchor(world, assembly_id)

## Terrain-anchored builds always attach. Floating locomotives may expand only
## while nearly stopped (parking brake or coast-to-stop).
static func construction_attach_allowed(world, assembly_id: int) -> bool:
	return ConstructionTerrainAnchorService.construction_attach_allowed(world, assembly_id)
