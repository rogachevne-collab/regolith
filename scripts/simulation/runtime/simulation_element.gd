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
	element.build_progress = 1.0
	element.integrity = placement.archetype.max_integrity
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
	return element
