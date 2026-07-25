class_name ConstructionPlaceValidationService
extends RefCounted

static func validate_place_element(world,
	command: PlaceElementCommand
) -> StructuralCommandResult:
	if (
		PistonPlacementUtil.is_piston_archetype(command.archetype)
		or RotorPlacementUtil.is_rotor_archetype(command.archetype)
		or HingePlacementUtil.is_hinge_archetype(command.archetype)
	):
		return ConstructionPlaceValidationService.validate_driven_place_element(world, command)
	if WheelPlacementUtil.is_wheel_archetype(command.archetype):
		return ConstructionPlaceValidationService.validate_wheel_place_element(world, command)
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
	var archetype_validation: StructuralCommandResult = ConstructionPlaceValidationService.validate_construction_archetype(world,
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
		if not ConstructionTerrainAnchorService.construction_attach_allowed(world, assembly.assembly_id):
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
		var native_attach: Dictionary = ConstructionPreviewKernelAccess.validate_attach_preview(
			world,
			assembly,
			archetype,
			command.origin_cell,
			command.orientation_index
		)
		var bridge_done := false
		if not native_attach.is_empty():
			var native_reason := StringName(native_attach.get("reason", &"invalid_target"))
			if not bool(native_attach.get("ok", false)):
				return StructuralCommandResult.failed(native_reason)
			var existing_ids: PackedInt32Array = native_attach.get(
				"existing_element_ids",
				PackedInt32Array()
			)
			var existing_ports: PackedStringArray = native_attach.get(
				"existing_port_ids",
				PackedStringArray()
			)
			var new_ports: PackedStringArray = native_attach.get(
				"new_port_ids",
				PackedStringArray()
			)
			for index: int in range(existing_ids.size()):
				connections.append({
					"existing_element_id": int(existing_ids[index]),
					"existing_port_id": (
						str(existing_ports[index])
						if index < existing_ports.size()
						else ""
					),
					"new_port_id": (
						str(new_ports[index]) if index < new_ports.size() else ""
					),
				})
			# Native applies bridge cycle check only when body-group tables were packed.
			bridge_done = bool(native_attach.get("bridge_checked", false))
		else:
			var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(
				world,
				assembly
			)
			var preview_cells := preview.occupied_cells()
			if ConstructionOccupancyUtil.preview_overlaps_occupancy(
				preview_cells,
				occupancy
			):
				return StructuralCommandResult.failed(
					StructuralCommandResult.REASON_OVERLAP
				)
			# A rigid edge requires adjacent derived structural surface faces, so only
			# elements occupying a neighbour of the preview footprint can ever connect.
			var neighbour_ids: Array[int] = ConstructionOccupancyUtil.neighbour_element_ids(
				preview_cells,
				occupancy
			)
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
		if not bridge_done:
			var bridge_error: StructuralCommandResult = (
				ConstructionPlaceValidationService.validate_new_rigid_connections(
					world,
					assembly.assembly_id,
					preview,
					connections
				)
			)
			if bridge_error != null:
				return bridge_error
		var moving_error: StructuralCommandResult = ConstructionPlaceValidationService.validate_driven_head_construction_target(world,
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
	var archetype_validation: StructuralCommandResult = ConstructionPlaceValidationService.validate_construction_archetype(world,
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
	if not ConstructionTerrainAnchorService.construction_attach_allowed(world, assembly.assembly_id):
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
	if ConstructionOccupancyUtil.preview_overlaps_occupancy(preview_cells, occupancy):
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
			WheelPlacementUtil.is_suspension_archetype(existing.get_archetype())
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
	var bridge_error: StructuralCommandResult = ConstructionPlaceValidationService.validate_new_rigid_connections(world,
		assembly.assembly_id,
		preview,
		connections
	)
	if bridge_error != null:
		return bridge_error
	var moving_error: StructuralCommandResult = ConstructionPlaceValidationService.validate_driven_head_construction_target(world, connections)
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
	var archetype_validation: StructuralCommandResult = ConstructionPlaceValidationService.validate_construction_archetype(world,
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
		if not ConstructionTerrainAnchorService.construction_attach_allowed(world, assembly.assembly_id):
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
			var bridge_error: StructuralCommandResult = ConstructionPlaceValidationService.validate_new_rigid_connections(world,
				assembly.assembly_id,
				base_preview,
				connections
			)
			if bridge_error != null:
				return bridge_error
		var moving_error: StructuralCommandResult = ConstructionPlaceValidationService.validate_driven_head_construction_target(world,
			head_connections
		)
		if moving_error != null:
			return moving_error
		var chain_error: StructuralCommandResult = (
			ConstructionPlaceValidationService.validate_prospective_driven_compile(
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


## True when every driven joint on the path from element → root is idle.
## Used by magnetic snap / construction — pose may be extended or bent; live
## group frames keep attach geometry correct (see POC-ACTUATORS-V1).
static func is_driven_path_at_home(
	world,
	element_id: int
) -> bool:
	if world == null or element_id <= 0:
		return true
	var element: SimulationElement = world.get_element(element_id)
	if element == null:
		return true
	return _validate_driven_path_home_for_element(world, element) == null


## Every driven joint on the path from the target element group to root must
## be idle — not only when the snap face is a hub endpoint. Extension / bend
## is allowed; moving joints are not.
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
		var idle_error := _driven_joint_not_idle_result(joint)
		if idle_error != null:
			return idle_error
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


static func _driven_joint_not_idle_result(
	joint: SimulationJoint
) -> StructuralCommandResult:
	var motor := joint.motor
	# Live body-group frames make attach on extended/rotated branches correct;
	# reject only while the joint is still moving (POC-ACTUATORS idle band).
	if absf(motor.observed_velocity_mps) > SimulationMotorState.CONSTRUCTION_IDLE_VELOCITY:
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
