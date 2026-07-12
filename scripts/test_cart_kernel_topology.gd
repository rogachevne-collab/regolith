extends Node3D

const CART_ROVER := preload("res://resources/blueprints/baked/cart_rover.tres")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := SimulationWorld.new()
	add_child(world)
	var spawn := _spawn(world)
	if not spawn.is_ok():
		_fail("cart_rover spawn failed")
		return
	var rover_id: int = int(spawn.data["assembly_id"])
	var mapping: Dictionary = spawn.data["local_to_element_id"]
	if int(mapping.size()) != 15:
		_fail("spawn mapping count is %d" % int(mapping.size()))
		return
	var assembly := world.get_assembly_raw(rover_id)
	if assembly.element_ids.size() != 15:
		_fail("rover element count is %d" % assembly.element_ids.size())
		return
	var dry_mass := ColliderProjectionUtil.assembly_dry_mass(world, assembly)
	if absf(dry_mass - 400.0) >= 0.02:
		_fail("rover dry mass is %.3f" % dry_mass)
		return

	var center_id: int = int(mapping["frame_0_0_0"])
	if not _detach_element(world, rover_id, center_id):
		_fail("center detach failed")
		return
	if world.get_element(center_id).assembly_id == rover_id:
		_fail("center element remained on rover")
		return
	var rover_after := world.get_assembly_raw(rover_id)
	if rover_after.element_ids.size() != 14:
		_fail("rover retained %d elements" % rover_after.element_ids.size())
		return

	var fragment_id: int = world.get_element(center_id).assembly_id
	var merge := _merge_neighbor(
		world,
		rover_id,
		fragment_id,
		center_id,
		Vector3i.ZERO
	)
	if not merge.is_ok():
		_fail("center merge failed: %s" % String(merge.reason))
		return
	if world.get_assembly_raw(rover_id).element_ids.size() != 15:
		_fail("merge did not restore rover element count")
		return

	var wheel_id: int = int(mapping["wheel_fl"])
	if not _detach_element(world, rover_id, wheel_id):
		_fail("wheel detach failed")
		return
	if world.get_element(wheel_id).assembly_id == rover_id:
		_fail("wheel remained on rover")
		return

	print("KERNEL-CART-TOPOLOGY: PASS")
	get_tree().quit(0)


func _spawn(world: SimulationWorld) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = CART_ROVER
	command.grid_frame = GridTransform.identity()
	return world.apply_structural_command_now(command)


func _detach_element(
	world: SimulationWorld,
	rover_id: int,
	element_id: int
) -> bool:
	var safety := 0
	while safety < 32:
		safety += 1
		var element := world.get_element(element_id)
		if element == null:
			return false
		if element.assembly_id != rover_id:
			return true
		var assembly := world.get_assembly_raw(rover_id)
		var joints: Array[SimulationJoint] = []
		for joint: SimulationJoint in world.list_joints():
			if joint.assembly_id != rover_id:
				continue
			if joint.kind != SimulationJoint.Kind.RIGID:
				continue
			if (
				joint.element_a_id == element_id
				or joint.element_b_id == element_id
			):
				joints.append(joint)
		if joints.is_empty():
			return false
		var command := BreakRigidJointCommand.new()
		command.joint_id = joints[0].joint_id
		command.expected_assembly_revision = assembly.topology_revision
		var result := world.apply_structural_command_now(command)
		if not result.is_ok():
			return false
	return false


func _merge_neighbor(
	world: SimulationWorld,
	rover_id: int,
	fragment_id: int,
	fragment_element_id: int,
	cell: Vector3i
) -> StructuralCommandResult:
	var fragment_element := world.get_element(fragment_element_id)
	var rover_element: SimulationElement = null
	for direction: Vector3i in [
		Vector3i.LEFT,
		Vector3i.RIGHT,
		Vector3i.FORWARD,
		Vector3i.BACK,
	]:
		for element_id: int in world.get_assembly_raw(rover_id).element_ids:
			var element := world.get_element(element_id)
			if element.origin_cell == cell + direction:
				rover_element = element
				break
		if rover_element != null:
			break
	if rover_element == null or fragment_element == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var connection: Dictionary = RuntimeConnectivity.find_rigid_connection(
		rover_element,
		fragment_element
	)
	if connection.is_empty():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
		)
	var rover := world.get_assembly_raw(rover_id)
	var fragment := world.get_assembly_raw(fragment_id)
	var command := MergeAssembliesCommand.new()
	command.assembly_a_id = rover_id
	command.assembly_b_id = fragment_id
	command.expected_revision_a = rover.topology_revision
	command.expected_revision_b = fragment.topology_revision
	command.element_a_id = rover_element.element_id
	command.port_a_id = str(connection["left_port_id"])
	command.element_b_id = fragment_element.element_id
	command.port_b_id = str(connection["right_port_id"])
	command.b_to_a_grid = GridTransform.identity()
	return world.apply_structural_command_now(command)


func _fail(reason: String) -> void:
	print("KERNEL-CART-TOPOLOGY: FAIL %s" % reason)
	get_tree().quit(1)
