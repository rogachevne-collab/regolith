class_name ConstructionElementLifecycleService
extends RefCounted

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
		if ResourceCatalog.is_discrete("plate_metal"):
			material_amount = ceilf(material_amount - 0.000001)
		if material_amount <= 0.000001:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
				{
					"resource_id": "plate_metal",
					"required": material_amount,
					"available": store.amount("plate_metal"),
				}
			)
		if not store.can_remove("plate_metal", material_amount):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
				{
					"resource_id": "plate_metal",
					"required": material_amount,
					"available": store.amount("plate_metal"),
				}
			)
		store.remove("plate_metal", material_amount)
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
				"resource_id": "plate_metal",
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
	if ResourceCatalog.is_discrete("plate_metal"):
		material_amount = ceilf(material_amount - 0.000001)
	if material_amount <= 0.000001:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
			{
				"resource_id": "plate_metal",
				"required": material_amount,
				"available": 0.0,
			}
		)
	var store: SimulationResourceStore = world.get_resource_store(command.store_id)
	if (
		store == null
		or not store.can_remove("plate_metal", material_amount)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
			{
				"resource_id": "plate_metal",
				"required": material_amount,
				"available": (
					store.amount("plate_metal")
					if store != null else 0.0
				),
			}
		)
	store.remove("plate_metal", material_amount)
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
		"resource_id": "plate_metal",
		"material_used": material_amount,
		"resource_remaining": store.amount("plate_metal"),
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
