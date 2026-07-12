class_name SurvivorPolicy
extends RefCounted


static func pick_survivor_index(components: Array[Dictionary]) -> int:
	if components.is_empty():
		return -1
	var best_index := 0
	for index: int in range(1, components.size()):
		if _compare_components(components[index], components[best_index]) > 0:
			best_index = index
	return best_index


static func pick_survivor_assembly(
	assemblies: Array[Dictionary]
) -> int:
	if assemblies.is_empty():
		return -1
	var best_index := 0
	for index: int in range(1, assemblies.size()):
		if _compare_assembly_scores(
			assemblies[index],
			assemblies[best_index]
		) > 0:
			best_index = index
	return int(assemblies[best_index]["assembly_id"])


static func component_score(
	element_ids: Array[int],
	elements_by_id: Dictionary,
	joints: Array[SimulationJoint]
) -> Dictionary:
	var has_anchor := false
	var dry_mass := 0.0
	for element_id: int in element_ids:
		var element: SimulationElement = elements_by_id[element_id]
		dry_mass += element.dry_mass_kg()
	for joint: SimulationJoint in joints:
		if joint.kind != SimulationJoint.Kind.ANCHOR:
			continue
		if element_ids.has(joint.element_a_id):
			has_anchor = true
			break
	return {
		"has_anchor": has_anchor,
		"element_count": element_ids.size(),
		"dry_mass_kg": dry_mass,
		"lowest_element_id": element_ids.min() if not element_ids.is_empty() else 0,
	}


static func assembly_score(
	assembly_id: int,
	element_ids: Array[int],
	elements_by_id: Dictionary,
	joints: Array[SimulationJoint]
) -> Dictionary:
	var score: Dictionary = component_score(
		element_ids,
		elements_by_id,
		joints
	)
	score["assembly_id"] = assembly_id
	return score


static func _compare_components(left: Dictionary, right: Dictionary) -> int:
	var common := _compare_common_scores(left, right)
	if common != 0:
		return common
	var left_id := int(left.get("lowest_element_id", 0))
	var right_id := int(right.get("lowest_element_id", 0))
	if left_id == right_id:
		return 0
	return 1 if left_id < right_id else -1


static func _compare_assembly_scores(left: Dictionary, right: Dictionary) -> int:
	var common := _compare_common_scores(left, right)
	if common != 0:
		return common
	var left_id := int(left.get("assembly_id", 0))
	var right_id := int(right.get("assembly_id", 0))
	if left_id == right_id:
		return 0
	return 1 if left_id < right_id else -1


static func _compare_common_scores(left: Dictionary, right: Dictionary) -> int:
	if bool(left.get("has_anchor", false)) != bool(right.get("has_anchor", false)):
		return 1 if left.get("has_anchor", false) else -1
	if int(left.get("element_count", 0)) != int(right.get("element_count", 0)):
		return (
			1
			if int(left.get("element_count", 0))
			> int(right.get("element_count", 0))
			else -1
		)
	var left_mass: float = float(left.get("dry_mass_kg", 0.0))
	var right_mass: float = float(right.get("dry_mass_kg", 0.0))
	if not is_equal_approx(left_mass, right_mass):
		return 1 if left_mass > right_mass else -1
	return 0
