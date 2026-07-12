class_name SimulationJoint
extends RefCounted

const _SCRIPT := preload("res://scripts/simulation/runtime/simulation_joint.gd")

enum Kind {
	RIGID,
	ANCHOR,
}

var joint_id: int = 0
var assembly_id: int = 0
var kind: Kind = Kind.RIGID
var element_a_id: int = 0
var port_a_id: String = ""
var element_b_id: int = 0
var port_b_id: String = ""


static func rigid(
	joint_id: int,
	assembly_id: int,
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String
) -> SimulationJoint:
	var joint: SimulationJoint = _SCRIPT.new()
	joint.joint_id = joint_id
	joint.assembly_id = assembly_id
	joint.kind = Kind.RIGID
	joint.element_a_id = element_a_id
	joint.port_a_id = port_a_id
	joint.element_b_id = element_b_id
	joint.port_b_id = port_b_id
	return joint


static func anchor(
	joint_id: int,
	assembly_id: int,
	element_id: int,
	port_id: String
) -> SimulationJoint:
	var joint: SimulationJoint = _SCRIPT.new()
	joint.joint_id = joint_id
	joint.assembly_id = assembly_id
	joint.kind = Kind.ANCHOR
	joint.element_a_id = element_id
	joint.port_a_id = port_id
	joint.element_b_id = 0
	joint.port_b_id = ""
	return joint


func endpoint_ids() -> Array[int]:
	if kind == Kind.ANCHOR:
		return [element_a_id]
	return [element_a_id, element_b_id]


func involves_element(element_id: int) -> bool:
	return element_a_id == element_id or element_b_id == element_id


func canonical_key() -> String:
	var left_element := mini(element_a_id, element_b_id)
	var right_element := maxi(element_a_id, element_b_id)
	var left_port := port_a_id
	var right_port := port_b_id
	if element_a_id > element_b_id:
		left_port = port_b_id
		right_port = port_a_id
	return "%d|%s|%d|%s" % [
		left_element,
		left_port,
		right_element,
		right_port,
	]


func to_dict() -> Dictionary:
	return {
		"joint_id": joint_id,
		"assembly_id": assembly_id,
		"kind": kind,
		"element_a_id": element_a_id,
		"port_a_id": port_a_id,
		"element_b_id": element_b_id,
		"port_b_id": port_b_id,
	}


static func from_dict(data: Dictionary) -> SimulationJoint:
	var joint: SimulationJoint = _SCRIPT.new()
	joint.joint_id = int(data.get("joint_id", 0))
	joint.assembly_id = int(data.get("assembly_id", 0))
	joint.kind = int(data.get("kind", Kind.RIGID))
	joint.element_a_id = int(data.get("element_a_id", 0))
	joint.port_a_id = str(data.get("port_a_id", ""))
	joint.element_b_id = int(data.get("element_b_id", 0))
	joint.port_b_id = str(data.get("port_b_id", ""))
	return joint
