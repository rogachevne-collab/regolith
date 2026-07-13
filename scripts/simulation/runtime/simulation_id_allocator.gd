class_name SimulationIdAllocator
extends RefCounted

var next_element_id: int = 1
var next_assembly_id: int = 1
var next_joint_id: int = 1
var next_command_id: int = 1
var next_link_id: int = 1
var next_loot_pile_id: int = 1


func allocate_loot_pile_id() -> int:
	var id := next_loot_pile_id
	next_loot_pile_id += 1
	return id


func allocate_element_id() -> int:
	var id := next_element_id
	next_element_id += 1
	return id


func allocate_assembly_id() -> int:
	var id := next_assembly_id
	next_assembly_id += 1
	return id


func allocate_joint_id() -> int:
	var id := next_joint_id
	next_joint_id += 1
	return id


func allocate_command_id() -> int:
	var id := next_command_id
	next_command_id += 1
	return id


func allocate_link_id() -> int:
	var id := next_link_id
	next_link_id += 1
	return id


func to_dict() -> Dictionary:
	return {
		"next_element_id": next_element_id,
		"next_assembly_id": next_assembly_id,
		"next_joint_id": next_joint_id,
		"next_command_id": next_command_id,
		"next_link_id": next_link_id,
		"next_loot_pile_id": next_loot_pile_id,
	}


func load_from_dict(data: Dictionary) -> void:
	next_element_id = int(data.get("next_element_id", 1))
	next_assembly_id = int(data.get("next_assembly_id", 1))
	next_joint_id = int(data.get("next_joint_id", 1))
	next_command_id = int(data.get("next_command_id", 1))
	next_link_id = int(data.get("next_link_id", 1))
	next_loot_pile_id = int(data.get("next_loot_pile_id", 1))
