class_name BlueprintValidator
extends RefCounted

static func validate(blueprint: Blueprint) -> BlueprintValidationResult:
	var result := BlueprintValidationResult.new()
	if blueprint == null:
		result.add_error("blueprint is null")
		return result
	if blueprint.blueprint_id.is_empty():
		result.add_error("blueprint_id is empty")
	if blueprint.placements.is_empty():
		result.add_error("placements is empty")

	var seen_ids: Dictionary = {}
	var occupancy: Dictionary = {}
	var validated_archetypes: Dictionary = {}

	for placement: BlueprintElementPlacement in blueprint.placements:
		_validate_placement(
			placement,
			result,
			seen_ids,
			occupancy,
			validated_archetypes
		)

	if result.ok and not blueprint.allow_disconnected:
		var components: Array[Array] = (
			BlueprintConnectivity.connected_components(blueprint)
		)
		if components.size() > 1:
			result.add_error(
				"blueprint is disconnected into %d rigid components: %s"
				% [components.size(), components]
			)

	return result


static func validate_archetype(
	archetype: ElementArchetype
) -> BlueprintValidationResult:
	var result := BlueprintValidationResult.new()
	if archetype == null:
		result.add_error("archetype is null")
		return result
	_validate_archetype(archetype, result)
	return result


static func _validate_placement(
	placement: BlueprintElementPlacement,
	result: BlueprintValidationResult,
	seen_ids: Dictionary,
	occupancy: Dictionary,
	validated_archetypes: Dictionary
) -> void:
	if placement == null:
		result.add_error("placement is null")
		return
	if placement.local_id.is_empty():
		result.add_error("placement has empty local_id")
	elif seen_ids.has(placement.local_id):
		result.add_error(
			"duplicate local_id '%s'" % placement.local_id
		)
	else:
		seen_ids[placement.local_id] = true

	if placement.archetype == null:
		result.add_error(
			"placement '%s' has no archetype" % placement.local_id
		)
		return
	if placement.archetype.archetype_id.is_empty():
		result.add_error(
			"placement '%s' archetype_id is empty" % placement.local_id
		)
	var archetype_key: int = placement.archetype.get_instance_id()
	if not validated_archetypes.has(archetype_key):
		validated_archetypes[archetype_key] = true
		_validate_archetype(placement.archetype, result)

	if (
		placement.orientation_index < 0
		or placement.orientation_index >= OrientationUtil.ORIENTATION_COUNT
	):
		result.add_error(
			"placement '%s' has invalid orientation_index %d"
			% [placement.local_id, placement.orientation_index]
		)
		return

	if placement.archetype.footprint_cells.is_empty():
		result.add_error(
			"archetype '%s' has empty footprint"
			% placement.archetype.archetype_id
		)
		return

	for cell: Vector3i in placement.archetype.get_occupied_cells(
		placement.origin_cell,
		placement.orientation_index
	):
		var key: String = _cell_key(cell)
		if occupancy.has(key):
			result.add_error(
				"cell overlap at %s between '%s' and '%s'"
				% [
					key,
					placement.local_id,
					str(occupancy[key]),
				]
			)
		else:
			occupancy[key] = placement.local_id


static func _validate_archetype(
	archetype: ElementArchetype,
	result: BlueprintValidationResult
) -> void:
	if not is_finite(archetype.mass_kg) or archetype.mass_kg <= 0.0:
		result.add_error(
			"archetype '%s' mass_kg must be finite and positive"
			% archetype.archetype_id
		)
	if (
		not is_finite(archetype.max_integrity)
		or archetype.max_integrity <= 0.0
	):
		result.add_error(
			"archetype '%s' max_integrity must be finite and positive"
			% archetype.archetype_id
		)
	var footprint: Dictionary = {}
	for cell: Vector3i in archetype.footprint_cells:
		var key: String = _cell_key(cell)
		if footprint.has(key):
			result.add_error(
				"archetype '%s' has duplicate footprint cell %s"
				% [archetype.archetype_id, key]
			)
		footprint[key] = cell

	if archetype.colliders.is_empty():
		result.add_error(
			"archetype '%s' has no collider pieces"
			% archetype.archetype_id
		)
	var collider_coverage: Dictionary = {}
	for collider: ColliderDefinition in archetype.colliders:
		if collider == null:
			result.add_error(
				"archetype '%s' has null collider piece"
				% archetype.archetype_id
			)
			continue
		var collider_key: String = _cell_key(collider.local_cell)
		if not footprint.has(collider_key):
			result.add_error(
				"archetype '%s' collider cell %s is outside footprint"
				% [archetype.archetype_id, collider_key]
			)
		if (
			not collider.size.is_finite()
			or not collider.offset_in_cell.is_finite()
			or collider.size.x <= 0.0
			or collider.size.y <= 0.0
			or collider.size.z <= 0.0
		):
			result.add_error(
				"archetype '%s' collider at %s has non-positive size"
				% [archetype.archetype_id, collider_key]
			)
		if (
			collider.size.is_finite()
			and collider.offset_in_cell.is_finite()
			and collider.size.x > 0.0
			and collider.size.y > 0.0
			and collider.size.z > 0.0
		):
			var collider_center := (
				GridMetric.cell_to_meters(collider.local_cell)
				+ collider.offset_in_cell
			)
			var collider_half_extents := collider.size * 0.5
			for footprint_key: String in footprint:
				var footprint_cell: Vector3i = footprint[footprint_key]
				var cell_center := GridMetric.cell_center_meters(
					footprint_cell
				)
				var delta := (cell_center - collider_center).abs()
				if (
					delta.x <= collider_half_extents.x + 0.0001
					and delta.y <= collider_half_extents.y + 0.0001
					and delta.z <= collider_half_extents.z + 0.0001
				):
					collider_coverage[footprint_key] = true
	for footprint_key: String in footprint:
		if not collider_coverage.has(footprint_key):
			result.add_error(
				"archetype '%s' footprint cell %s has no collider coverage"
				% [archetype.archetype_id, footprint_key]
			)

	var port_ids: Dictionary = {}
	for port: PortDefinition in archetype.ports:
		if port == null:
			result.add_error(
				"archetype '%s' has null port" % archetype.archetype_id
			)
			continue
		if port.port_id.is_empty():
			result.add_error(
				"archetype '%s' has port with empty port_id"
				% archetype.archetype_id
			)
		elif port_ids.has(port.port_id):
			result.add_error(
				"archetype '%s' has duplicate port_id '%s'"
				% [archetype.archetype_id, port.port_id]
			)
		port_ids[port.port_id] = true
		if not footprint.has(_cell_key(port.local_cell)):
			result.add_error(
				"archetype '%s' port '%s' cell is outside footprint"
				% [archetype.archetype_id, port.port_id]
			)
		if port.face_slot < 0:
			result.add_error(
				"archetype '%s' port '%s' has negative face_slot"
				% [archetype.archetype_id, port.port_id]
			)
		if (
			int(port.local_face) < int(OrientationUtil.Face.POS_X)
			or int(port.local_face) > int(OrientationUtil.Face.NEG_Z)
		):
			result.add_error(
				"archetype '%s' port '%s' has invalid local_face"
				% [archetype.archetype_id, port.port_id]
			)
		if port.compatibility_tags.is_empty():
			result.add_error(
				"archetype '%s' port '%s' has no compatibility tags"
				% [archetype.archetype_id, port.port_id]
			)
		var unique_tags: Dictionary = {}
		for tag: String in port.compatibility_tags:
			if tag.is_empty():
				result.add_error(
					"archetype '%s' port '%s' has empty compatibility tag"
					% [archetype.archetype_id, port.port_id]
				)
			elif unique_tags.has(tag):
				result.add_error(
					"archetype '%s' port '%s' repeats tag '%s'"
					% [archetype.archetype_id, port.port_id, tag]
				)
			unique_tags[tag] = true

	if archetype.piston_definition != null:
		for error_text: String in archetype.piston_definition.validate_base_archetype(
			archetype
		):
			result.add_error(error_text)

	if archetype.rotor_definition != null:
		for error_text: String in archetype.rotor_definition.validate_base_archetype(
			archetype
		):
			result.add_error(error_text)

	var requirement_ids: Dictionary = {}
	for requirement: BuildRequirement in archetype.build_requirements:
		if requirement == null:
			result.add_error(
				"archetype '%s' has null build requirement"
				% archetype.archetype_id
			)
			continue
		if requirement.resource_id.is_empty():
			result.add_error(
				"archetype '%s' has build requirement with empty resource_id"
				% archetype.archetype_id
			)
		elif requirement_ids.has(requirement.resource_id):
			result.add_error(
				"archetype '%s' repeats build requirement '%s'"
				% [archetype.archetype_id, requirement.resource_id]
			)
		requirement_ids[requirement.resource_id] = true
		if not is_finite(requirement.amount) or requirement.amount <= 0.0:
			result.add_error(
				"archetype '%s' requirement '%s' amount must be positive"
				% [archetype.archetype_id, requirement.resource_id]
			)


static func _cell_key(cell: Vector3i) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]
