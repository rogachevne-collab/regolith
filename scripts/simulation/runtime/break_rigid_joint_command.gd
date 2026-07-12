class_name BreakRigidJointCommand
extends StructuralCommand

var joint_id: int = 0
var expected_assembly_revision: int = -1


func kind() -> StringName:
	return &"break_rigid_joint"


func execution_copy() -> StructuralCommand:
	var copy := BreakRigidJointCommand.new()
	copy.joint_id = joint_id
	copy.expected_assembly_revision = expected_assembly_revision
	return copy
