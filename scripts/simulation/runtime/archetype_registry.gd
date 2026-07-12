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
		"ports": ports,
		"colliders": colliders,
		"build_requirements": requirements,
	}
	return str(hash(JSON.stringify(schema)))
