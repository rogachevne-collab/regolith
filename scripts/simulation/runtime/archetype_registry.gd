class_name ArchetypeRegistry
extends RefCounted

var _definitions: Dictionary = {}
var _fingerprints: Dictionary = {}


func register(archetype: ElementArchetype) -> bool:
	if archetype == null or archetype.archetype_id.is_empty():
		return false
	var archetype_id := archetype.archetype_id
	var fingerprint := fingerprint_of(archetype)
	if _definitions.has(archetype_id):
		return _fingerprints[archetype_id] == fingerprint
	_definitions[archetype_id] = archetype
	_fingerprints[archetype_id] = fingerprint
	return true


func get_archetype(archetype_id: String) -> ElementArchetype:
	return _definitions.get(archetype_id) as ElementArchetype


func has(archetype_id: String) -> bool:
	return _definitions.has(archetype_id)


func ids() -> PackedStringArray:
	var result := PackedStringArray()
	for key: Variant in _definitions.keys():
		result.append(str(key))
	result.sort()
	return result


func definition_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for archetype_id: String in ids():
		var archetype: ElementArchetype = _definitions[archetype_id]
		rows.append({
			"archetype_id": archetype_id,
			"resource_path": archetype.resource_path,
			"fingerprint": str(_fingerprints[archetype_id]),
		})
	return rows


static func fingerprint_of(archetype: ElementArchetype) -> String:
	var ports: Array[Dictionary] = []
	for port: PortDefinition in archetype.ports:
		ports.append({
			"id": port.port_id,
			"kind": port.kind,
			"cell": port.local_cell,
			"face": port.local_face,
			"slot": port.face_slot,
			"tags": Array(port.compatibility_tags),
		})
	var colliders: Array[Dictionary] = []
	for collider: ColliderDefinition in archetype.colliders:
		colliders.append({
			"cell": collider.local_cell,
			"shape": collider.shape_kind,
			"size": collider.size,
			"offset": collider.offset_in_cell,
		})
	var requirements: Array[Dictionary] = []
	for requirement: BuildRequirement in archetype.build_requirements:
		requirements.append({
			"resource_id": requirement.resource_id,
			"amount": requirement.amount,
		})
	var schema := {
		"archetype_id": archetype.archetype_id,
		"display_name": archetype.display_name,
		"roles": Array(archetype.roles),
		"mass_kg": archetype.mass_kg,
		"footprint_cells": archetype.footprint_cells,
		"max_integrity": archetype.max_integrity,
		"structural_surface_policy": archetype.structural_surface_policy,
		"structural_mount_pads": _mount_pad_rows(archetype.structural_mount_pads),
		"piston_definition": _piston_definition_row(archetype.piston_definition),
		"internal_archetype": archetype.internal_archetype,
		"ports": ports,
		"colliders": colliders,
		"build_requirements": requirements,
	}
	return str(hash(JSON.stringify(schema)))


static func _mount_pad_rows(
	mount_pads: Array[StructuralMountPad]
) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for pad: StructuralMountPad in mount_pads:
		if pad == null:
			continue
		rows.append({
			"cell": pad.local_cell,
			"face": pad.local_face,
		})
	rows.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			var left_cell: Vector3i = left["cell"]
			var right_cell: Vector3i = right["cell"]
			if left_cell != right_cell:
				return left_cell < right_cell
			return int(left["face"]) < int(right["face"])
	)
	return rows


static func _piston_definition_row(
	definition: PistonDefinition
) -> Dictionary:
	if definition == null:
		return {}
	return {
		"head_archetype_id": definition.head_archetype_id,
		"axis_face": definition.axis_face,
		"retracted_offset_m": definition.retracted_offset_m,
		"lower_limit_m": definition.lower_limit_m,
		"upper_limit_m": definition.upper_limit_m,
		"default_speed_limit_mps": definition.default_speed_limit_mps,
		"force_limit_n": definition.force_limit_n,
		"stiffness_n_per_m": definition.stiffness_n_per_m,
		"damping_n_s_per_m": definition.damping_n_s_per_m,
		"power_draw_w": definition.power_draw_w,
		"overload_policy": definition.overload_policy,
	}
