class_name ConstructionOccupancyUtil
extends RefCounted

static func cells_by_element_id(
	elements: Array[SimulationElement]
) -> Dictionary:
	var result: Dictionary = {}
	for element: SimulationElement in elements:
		result[element.element_id] = element.occupied_cells()
	return result

static func occupancy_is_unique(world, 
	base: Array[SimulationElement],
	extra: Dictionary
) -> bool:
	var seen: Dictionary = {}
	for element: SimulationElement in base:
		for cell: Vector3i in element.occupied_cells():
			var key := ConstructionOccupancyUtil.cell_key(cell)
			if seen.has(key):
				return false
			seen[key] = element.element_id
	for element_id: int in world._sorted_keys(extra):
		for cell: Vector3i in extra[element_id]:
			var key := ConstructionOccupancyUtil.cell_key(cell)
			if seen.has(key):
				return false
			seen[key] = element_id
	return true

static func cell_key(cell: Vector3i) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]

const CELL_NEIGHBOURS: Array[Vector3i] = [
	Vector3i.RIGHT,
	Vector3i.LEFT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.BACK,
	Vector3i.FORWARD,
]

static func assembly_occupancy_index(world, assembly: SimulationAssembly) -> Dictionary:
	var cached: Dictionary = world._occupancy_index_cache.get(
		assembly.assembly_id,
		{}
	)
	if int(cached.get("revision", -1)) == assembly.topology_revision:
		return cached["cells"]
	var cells: Dictionary = {}
	for element_id: int in assembly.element_ids:
		var element: SimulationElement = world.get_element(element_id)
		if element == null:
			continue
		for cell: Vector3i in element.occupied_cells():
			cells[cell] = element_id
	world._occupancy_index_cache[assembly.assembly_id] = {
		"revision": assembly.topology_revision,
		"cells": cells,
	}
	return cells

static func neighbour_element_ids(
	preview_cells: Array[Vector3i],
	occupancy: Dictionary
) -> Array[int]:
	var seen: Dictionary = {}
	for cell: Vector3i in preview_cells:
		for offset: Vector3i in CELL_NEIGHBOURS:
			var neighbour: Variant = occupancy.get(cell + offset)
			if neighbour != null:
				seen[int(neighbour)] = true
	var ids: Array[int] = []
	for element_id: Variant in seen.keys():
		ids.append(int(element_id))
	ids.sort()
	return ids

static func joint_belongs_to_component(
	joint: SimulationJoint,
	component: Array
) -> bool:
	if joint.kind == SimulationJoint.Kind.ANCHOR:
		return component.has(joint.element_a_id)
	return (
		component.has(joint.element_a_id)
		and component.has(joint.element_b_id)
	)
