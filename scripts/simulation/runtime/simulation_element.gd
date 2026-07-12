class_name SimulationElement
extends RefCounted

const _SCRIPT := preload("res://scripts/simulation/runtime/simulation_element.gd")

var element_id: int = 0
var assembly_id: int = 0
var archetype_id: String = ""
var origin_cell: Vector3i = Vector3i.ZERO
var orientation_index: int = 0
var build_progress: float = 1.0
var integrity: float = 0.0
var condition: float = 1.0
var state_revision: int = 0
var installed_materials: Dictionary = {}
# Persistent record of whether this block was found resting on / embedded in the
# voxel terrain. Set at placement and re-verified on structural split/dismantle
# (terrain is destructible). Drives ground anchoring so a construction keeps every
# ground-touching block anchored, not just the first-placed one.
var terrain_contact: bool = false

var _archetype: ElementArchetype


static func from_placement(
	element_id: int,
	assembly_id: int,
	placement: BlueprintElementPlacement
) -> SimulationElement:
	var element: SimulationElement = _SCRIPT.new()
	element.element_id = element_id
	element.assembly_id = assembly_id
	element.archetype_id = placement.archetype.archetype_id
	element.origin_cell = placement.origin_cell
	element.orientation_index = placement.orientation_index
	element._archetype = placement.archetype
	element.install_all_required_materials()
	element.integrity = placement.archetype.max_integrity
	element.condition = 1.0
	return element


static func frame(
	new_element_id: int,
	new_assembly_id: int,
	archetype: ElementArchetype,
	new_origin_cell: Vector3i,
	new_orientation_index: int,
	initial_materials: Dictionary
) -> SimulationElement:
	var element: SimulationElement = _SCRIPT.new()
	element.element_id = new_element_id
	element.assembly_id = new_assembly_id
	element.archetype_id = archetype.archetype_id
	element.origin_cell = new_origin_cell
	element.orientation_index = new_orientation_index
	element._archetype = archetype
	element.installed_materials = initial_materials.duplicate(true)
	element.recalculate_build_progress()
	element.integrity = archetype.max_integrity
	element.condition = 1.0
	return element


func get_archetype() -> ElementArchetype:
	return _archetype


func bind_archetype(archetype: ElementArchetype) -> bool:
	if archetype == null or archetype.archetype_id != archetype_id:
		return false
	_archetype = archetype
	return true


func dry_mass_kg() -> float:
	var archetype: ElementArchetype = get_archetype()
	if archetype == null:
		return 0.0
	return archetype.mass_kg


func bump_state_revision() -> void:
	state_revision += 1


func required_material_amount(resource_id: String) -> float:
	var archetype := get_archetype()
	if archetype == null:
		return 0.0
	var total := 0.0
	for requirement: BuildRequirement in archetype.build_requirements:
		if requirement.resource_id == resource_id:
			total += requirement.amount
	return total


func installed_material_amount(resource_id: String) -> float:
	return float(installed_materials.get(resource_id, 0.0))


func total_required_material_amount() -> float:
	var archetype := get_archetype()
	if archetype == null:
		return 0.0
	var total := 0.0
	for requirement: BuildRequirement in archetype.build_requirements:
		total += requirement.amount
	return total


func total_installed_material_amount() -> float:
	var total := 0.0
	for resource_id: Variant in installed_materials.keys():
		total += float(installed_materials[resource_id])
	return total


func install_material(resource_id: String, amount: float) -> bool:
	var missing := maxf(
		required_material_amount(resource_id)
		- installed_material_amount(resource_id),
		0.0
	)
	if resource_id.is_empty() or amount <= 0.0 or amount > missing + 0.000001:
		return false
	installed_materials[resource_id] = (
		installed_material_amount(resource_id) + amount
	)
	recalculate_build_progress()
	return true


func install_all_required_materials() -> void:
	installed_materials.clear()
	var archetype := get_archetype()
	if archetype == null:
		build_progress = 0.0
		return
	for requirement: BuildRequirement in archetype.build_requirements:
		installed_materials[requirement.resource_id] = (
			installed_material_amount(requirement.resource_id)
			+ requirement.amount
		)
	recalculate_build_progress()


func recalculate_build_progress() -> void:
	var required := total_required_material_amount()
	build_progress = (
		1.0
		if required <= 0.0
		else clampf(total_installed_material_amount() / required, 0.0, 1.0)
	)


func is_complete() -> bool:
	return build_progress >= 1.0 - 0.000001


func is_broken() -> bool:
	return integrity <= 0.000001


func is_operational() -> bool:
	return is_complete() and not is_broken()


func status_reason() -> StringName:
	if is_broken():
		return &"element_broken"
	if not is_complete():
		return &"element_incomplete"
	if get_archetype() != null and integrity < get_archetype().max_integrity:
		return &"damaged"
	return &"ok"


func occupied_cells() -> Array[Vector3i]:
	var archetype: ElementArchetype = get_archetype()
	if archetype == null:
		return []
	return archetype.get_occupied_cells(origin_cell, orientation_index)


func to_dict() -> Dictionary:
	return {
		"element_id": element_id,
		"assembly_id": assembly_id,
		"archetype_id": archetype_id,
		"origin_cell": origin_cell,
		"orientation_index": orientation_index,
		"build_progress": build_progress,
		"integrity": integrity,
		"condition": condition,
		"state_revision": state_revision,
		"terrain_contact": terrain_contact,
		"installed_materials": installed_materials.duplicate(true),
	}


static func from_dict(data: Dictionary) -> SimulationElement:
	var element: SimulationElement = _SCRIPT.new()
	element.element_id = int(data.get("element_id", 0))
	element.assembly_id = int(data.get("assembly_id", 0))
	element.archetype_id = str(data.get("archetype_id", ""))
	element.origin_cell = data.get("origin_cell", Vector3i.ZERO)
	element.orientation_index = int(data.get("orientation_index", 0))
	element.build_progress = float(data.get("build_progress", 1.0))
	element.integrity = float(data.get("integrity", 0.0))
	element.condition = float(data.get("condition", 1.0))
	element.state_revision = int(data.get("state_revision", 0))
	element.terrain_contact = bool(data.get("terrain_contact", false))
	var materials: Variant = data.get("installed_materials", {})
	if materials is Dictionary:
		element.installed_materials = materials.duplicate(true)
	return element
