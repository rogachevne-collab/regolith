class_name SimulationJoint
extends RefCounted

const _SCRIPT := preload("res://scripts/simulation/runtime/simulation_joint.gd")

enum Kind {
	RIGID,
	ANCHOR,
	PISTON,
	ROTOR,
	HINGE,
}

const DRIVEN_KINDS: Array[Kind] = [Kind.PISTON, Kind.ROTOR, Kind.HINGE]

var joint_id: int = 0
var assembly_id: int = 0
var kind: Kind = Kind.RIGID
var element_a_id: int = 0
var port_a_id: String = ""
var element_b_id: int = 0
var port_b_id: String = ""
var motor: SimulationMotorState


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


static func piston(
	joint_id: int,
	assembly_id: int,
	base_element_id: int,
	head_element_id: int,
	definition: PistonDefinition
) -> SimulationJoint:
	var joint: SimulationJoint = _SCRIPT.new()
	joint.joint_id = joint_id
	joint.assembly_id = assembly_id
	joint.kind = Kind.PISTON
	joint.element_a_id = base_element_id
	joint.port_a_id = SimulationMotorState.PISTON_DRIVE_PORT
	joint.element_b_id = head_element_id
	joint.port_b_id = SimulationMotorState.PISTON_CARRIAGE_PORT
	joint.motor = SimulationMotorState.from_piston_definition(definition)
	return joint


static func rotor(
	joint_id: int,
	assembly_id: int,
	base_element_id: int,
	top_element_id: int,
	definition: RotorDefinition
) -> SimulationJoint:
	var joint: SimulationJoint = _SCRIPT.new()
	joint.joint_id = joint_id
	joint.assembly_id = assembly_id
	joint.kind = Kind.ROTOR
	joint.element_a_id = base_element_id
	joint.port_a_id = SimulationMotorState.ROTOR_DRIVE_PORT
	joint.element_b_id = top_element_id
	joint.port_b_id = SimulationMotorState.ROTOR_TOP_PORT
	joint.motor = SimulationMotorState.from_rotor_definition(definition)
	return joint


static func hinge(
	joint_id: int,
	assembly_id: int,
	base_element_id: int,
	top_element_id: int,
	definition: HingeDefinition
) -> SimulationJoint:
	var joint: SimulationJoint = _SCRIPT.new()
	joint.joint_id = joint_id
	joint.assembly_id = assembly_id
	joint.kind = Kind.HINGE
	joint.element_a_id = base_element_id
	joint.port_a_id = SimulationMotorState.HINGE_DRIVE_PORT
	joint.element_b_id = top_element_id
	joint.port_b_id = SimulationMotorState.HINGE_TOP_PORT
	joint.motor = SimulationMotorState.from_hinge_definition(definition)
	return joint


func is_driven() -> bool:
	return kind in DRIVEN_KINDS


func endpoint_ids() -> Array[int]:
	if kind == Kind.ANCHOR:
		return [element_a_id]
	return [element_a_id, element_b_id]


func involves_element(element_id: int) -> bool:
	return element_a_id == element_id or element_b_id == element_id


func canonical_key() -> String:
	if is_driven():
		return "%d|%s|%d|%s" % [
			element_a_id,
			port_a_id,
			element_b_id,
			port_b_id,
		]
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
	var row := {
		"joint_id": joint_id,
		"assembly_id": assembly_id,
		"kind": kind,
		"element_a_id": element_a_id,
		"port_a_id": port_a_id,
		"element_b_id": element_b_id,
		"port_b_id": port_b_id,
	}
	if is_driven() and motor != null:
		row["motor"] = motor.to_dict()
	return row


static func from_dict(data: Dictionary) -> SimulationJoint:
	var joint: SimulationJoint = _SCRIPT.new()
	joint.joint_id = int(data.get("joint_id", 0))
	joint.assembly_id = int(data.get("assembly_id", 0))
	joint.kind = int(data.get("kind", Kind.RIGID)) as Kind
	joint.element_a_id = int(data.get("element_a_id", 0))
	joint.port_a_id = str(data.get("port_a_id", ""))
	joint.element_b_id = int(data.get("element_b_id", 0))
	joint.port_b_id = str(data.get("port_b_id", ""))
	if joint.is_driven():
		var motor_data: Variant = data.get("motor", {})
		if motor_data is Dictionary:
			joint.motor = SimulationMotorState.from_dict(motor_data)
	return joint
