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
	return _fingerprint_from_schema(archetype, false)


static func legacy_fingerprint_of(archetype: ElementArchetype) -> String:
	return _fingerprint_from_schema(archetype, true)


static func save_fingerprint_compatible(
	archetype: ElementArchetype,
	expected_fingerprint: String,
	expected_resource_path: String
) -> bool:
	if expected_fingerprint.is_empty():
		return false
	if fingerprint_of(archetype) == expected_fingerprint:
		return true
	if legacy_fingerprint_of(archetype) == expected_fingerprint:
		return true
	# Pre-structural saves stored a hash that included piston motor tuning.
	# Tolerate that drift when the same resource still validates structurally.
	return (
		archetype.resource_path == expected_resource_path
		and BlueprintValidator.validate_archetype(archetype).ok
	)


static func _fingerprint_from_schema(
	archetype: ElementArchetype,
	include_piston_tuning: bool
) -> String:
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
		"piston_definition": _piston_definition_row(
			archetype.piston_definition,
			include_piston_tuning
		),
		"wheel_definition": _wheel_definition_row(
			archetype.wheel_definition
		),
		"suspension_definition": _suspension_definition_row(
			archetype.suspension_definition
		),
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
			"socket_tag": pad.socket_tag,
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


static func _wheel_definition_row(
	definition: WheelDefinition
) -> Dictionary:
	if definition == null:
		return {}
	return {
		"radius_m": definition.radius_m,
		"width_m": definition.width_m,
		"drive_torque_n_m": definition.drive_torque_n_m,
		"brake_torque_n_m": definition.brake_torque_n_m,
		"longitudinal_grip": definition.longitudinal_grip,
		"lateral_grip": definition.lateral_grip,
		"slip_stiffness": definition.slip_stiffness,
		"lateral_stiffness": definition.lateral_stiffness,
		"wheel_inertia": definition.wheel_inertia,
		"angular_damping": definition.angular_damping,
		"max_angular_speed_rad_s": definition.max_angular_speed_rad_s,
		"max_steering_angle_rad": definition.max_steering_angle_rad,
		"steering_response": definition.steering_response,
		"steerable_default": definition.steerable_default,
		"forward_axis_face": definition.forward_axis_face,
		"power_draw_w": definition.power_draw_w,
		"idle_w": definition.idle_w,
		"requires_socket_tag": definition.requires_socket_tag,
	}


static func _suspension_definition_row(
	definition: SuspensionDefinition
) -> Dictionary:
	if definition == null:
		return {}
	return {
		"wheel_socket_face": definition.wheel_socket_face,
		"suspension_travel_m": definition.suspension_travel_m,
		"spring_stiffness_n_per_m": definition.spring_stiffness_n_per_m,
		"spring_damping_n_s_per_m": definition.spring_damping_n_s_per_m,
		"max_suspension_force_n": definition.max_suspension_force_n,
		"min_travel_m": definition.min_travel_m,
		"max_travel_m": definition.max_travel_m,
		"max_wheels_per_socket": definition.max_wheels_per_socket,
	}


static func _piston_definition_row(
	definition: PistonDefinition,
	include_tuning: bool
) -> Dictionary:
	if definition == null:
		return {}
	var row := {
		"head_archetype_id": definition.head_archetype_id,
		"axis_face": definition.axis_face,
		"retracted_offset_m": definition.retracted_offset_m,
		"lower_limit_m": definition.lower_limit_m,
		"upper_limit_m": definition.upper_limit_m,
		"power_draw_w": definition.power_draw_w,
		"overload_policy": definition.overload_policy,
	}
	if include_tuning:
		row["default_speed_limit_mps"] = definition.default_speed_limit_mps
		row["extend_velocity_mps"] = definition.extend_velocity_mps
		row["retract_velocity_mps"] = definition.retract_velocity_mps
		row["force_limit_n"] = definition.force_limit_n
		row["stiffness_n_per_m"] = definition.stiffness_n_per_m
		row["damping_n_s_per_m"] = definition.damping_n_s_per_m
	return row
