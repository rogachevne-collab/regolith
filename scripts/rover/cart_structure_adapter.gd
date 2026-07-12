class_name CartStructureAdapter
extends RefCounted

signal structure_changed(change: Dictionary)

const CART_ROVER := preload("res://resources/blueprints/baked/cart_rover.tres")
const WHEEL_LOCAL_IDS: PackedStringArray = [
	"wheel_fl",
	"wheel_fr",
	"wheel_rl",
	"wheel_rr",
]
const WHEEL_SUPPORT_LOCAL_IDS: PackedStringArray = [
	"frame_n1_0_n1",
	"frame_1_0_n1",
	"frame_n1_0_1",
	"frame_1_0_1",
]
const DIRECTIONS: Array[Vector3i] = [
	Vector3i.LEFT,
	Vector3i.RIGHT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.FORWARD,
	Vector3i.BACK,
]

var _world: SimulationWorld
var _projection: SimulationPhysicsProjection
var _mount_body: RigidBody3D
var _rover_assembly_id := 0
var _local_to_element: Dictionary = {}
var _cell_to_local_id: Dictionary = {}
var _fragment_assembly_ids: Array[int] = []
var _structure_event_count := 0


func setup(
	world: SimulationWorld,
	projection: SimulationPhysicsProjection,
	mount_body: RigidBody3D
) -> bool:
	_world = world
	_projection = projection
	_mount_body = mount_body
	_build_cell_maps()
	if not _spawn_rover():
		return false
	_world.structural_event.connect(_on_structural_event)
	return true


func request_attach_frame_element(cell: Vector3i) -> bool:
	if _rover_assembly_id == 0:
		return false
	var fragment_assembly_id := _fragment_assembly_id_with_cell(cell)
	if fragment_assembly_id == 0:
		return false
	var connection := _find_merge_connection(
		_rover_assembly_id,
		fragment_assembly_id,
		cell
	)
	if connection.is_empty():
		return false
	if not _projection.align_body_motion(
		fragment_assembly_id,
		_rover_assembly_id
	):
		return false
	var command := MergeAssembliesCommand.new()
	command.assembly_a_id = _rover_assembly_id
	command.assembly_b_id = fragment_assembly_id
	var rover: SimulationAssembly = _world.get_assembly_raw(_rover_assembly_id)
	var fragment: SimulationAssembly = _world.get_assembly_raw(
		fragment_assembly_id
	)
	command.expected_revision_a = rover.topology_revision
	command.expected_revision_b = fragment.topology_revision
	command.element_a_id = int(connection["element_a_id"])
	command.port_a_id = str(connection["port_a_id"])
	command.element_b_id = int(connection["element_b_id"])
	command.port_b_id = str(connection["port_b_id"])
	command.b_to_a_grid = _projection.compute_b_to_a_grid(
		_rover_assembly_id,
		fragment_assembly_id
	)
	if command.b_to_a_grid == null:
		return false
	var result := _world.apply_structural_command_now(command)
	return result.is_ok()


func request_detach_frame_element(cell: Vector3i) -> bool:
	var local_id: String = str(_cell_to_local_id.get(cell, ""))
	if local_id.is_empty():
		return false
	return _detach_local_id(local_id)


func request_detach_wheel(wheel_index: int) -> bool:
	if wheel_index < 0 or wheel_index >= WHEEL_LOCAL_IDS.size():
		return false
	return _detach_local_id(WHEEL_LOCAL_IDS[wheel_index])


func structure_element_count() -> int:
	var assembly := _rover_assembly()
	if assembly == null:
		return 0
	return assembly.element_ids.size()


func structure_total_mass() -> float:
	var assembly := _rover_assembly()
	if assembly == null:
		return 0.0
	return ColliderProjectionUtil.assembly_dry_mass(_world, assembly)


func structure_has_element(cell: Vector3i) -> bool:
	return _element_id_for_cell(cell) != 0


func structure_event_count() -> int:
	return _structure_event_count


func spawned_fragments() -> Array[RigidBody3D]:
	var result: Array[RigidBody3D] = []
	for assembly_id: int in _fragment_assembly_ids:
		var body := _projection.get_physics_body(assembly_id) as RigidBody3D
		if body != null and is_instance_valid(body):
			result.append(body)
	return result


func active_wheel_count() -> int:
	var count := 0
	for wheel_index: int in WHEEL_LOCAL_IDS.size():
		var wheel_local: String = WHEEL_LOCAL_IDS[wheel_index]
		var support_local: String = WHEEL_SUPPORT_LOCAL_IDS[wheel_index]
		if (
			_rover_has_local_id(wheel_local)
			and _rover_has_local_id(support_local)
		):
			count += 1
	return count


func is_wheel_active(wheel_index: int) -> bool:
	if wheel_index < 0 or wheel_index >= WHEEL_LOCAL_IDS.size():
		return false
	return (
		_rover_has_local_id(WHEEL_LOCAL_IDS[wheel_index])
		and _rover_has_local_id(WHEEL_SUPPORT_LOCAL_IDS[wheel_index])
	)


func rover_assembly_id() -> int:
	return _rover_assembly_id


func _spawn_rover() -> bool:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = CART_ROVER
	command.grid_frame = GridTransform.identity()
	var result := _world.apply_structural_command_now(command)
	if not result.is_ok():
		return false
	_rover_assembly_id = int(result.data["assembly_id"])
	_local_to_element = Dictionary(result.data["local_to_element_id"]).duplicate(
		true
	)
	_projection.set_collision_profile(_rover_assembly_id, 2, 3)
	if not _projection.mount_assembly_body_now(
		_rover_assembly_id,
		_mount_body
	):
		return false
	_mount_body.can_sleep = false
	_mount_body.continuous_cd = true
	_emit_structure_event(&"initialize")
	return true


func _detach_local_id(local_id: String) -> bool:
	var element_id := int(_local_to_element.get(local_id, 0))
	if element_id == 0:
		return false
	return _detach_element(element_id)


func _detach_element(element_id: int) -> bool:
	var safety := 0
	while safety < 32:
		safety += 1
		var element := _world.get_element(element_id)
		if element == null:
			return false
		if element.assembly_id != _rover_assembly_id:
			return true
		var assembly := _world.get_assembly_raw(_rover_assembly_id)
		if assembly == null:
			return false
		var joints := _incident_rigid_joints(assembly.assembly_id, element_id)
		if joints.is_empty():
			return false
		var command := BreakRigidJointCommand.new()
		command.joint_id = joints[0].joint_id
		command.expected_assembly_revision = assembly.topology_revision
		var result := _world.apply_structural_command_now(command)
		if not result.is_ok():
			return false
	return false


func _incident_rigid_joints(
	assembly_id: int,
	element_id: int
) -> Array[SimulationJoint]:
	var result: Array[SimulationJoint] = []
	for joint: SimulationJoint in _world.list_joints():
		if joint.assembly_id != assembly_id:
			continue
		if joint.kind != SimulationJoint.Kind.RIGID:
			continue
		if joint.element_a_id == element_id or joint.element_b_id == element_id:
			result.append(joint)
	result.sort_custom(
		func(left: SimulationJoint, right: SimulationJoint) -> bool:
			return left.joint_id < right.joint_id
	)
	return result


func _find_merge_connection(
	rover_assembly_id: int,
	fragment_assembly_id: int,
	cell: Vector3i
) -> Dictionary:
	var fragment_element := _element_in_assembly_at_cell(
		fragment_assembly_id,
		cell
	)
	if fragment_element == null:
		return {}
	for direction: Vector3i in DIRECTIONS:
		var neighbor_cell: Vector3i = cell + direction
		var rover_element := _element_in_assembly_at_cell(
			rover_assembly_id,
			neighbor_cell
		)
		if rover_element == null:
			continue
		var connection: Dictionary = RuntimeConnectivity.find_rigid_connection(
			rover_element,
			fragment_element
		)
		if connection.is_empty():
			continue
		return {
			"element_a_id": rover_element.element_id,
			"port_a_id": connection["left_port_id"],
			"element_b_id": fragment_element.element_id,
			"port_b_id": connection["right_port_id"],
		}
	return {}


func _element_in_assembly_at_cell(
	assembly_id: int,
	cell: Vector3i
) -> SimulationElement:
	var assembly := _world.get_assembly_raw(assembly_id)
	if assembly == null:
		return null
	for element_id: int in assembly.element_ids:
		var element := _world.get_element(element_id)
		if element != null and element.origin_cell == cell:
			return element
	return null


func _fragment_assembly_id_with_cell(cell: Vector3i) -> int:
	for assembly_id: int in _fragment_assembly_ids:
		if _element_in_assembly_at_cell(assembly_id, cell) != null:
			return assembly_id
	return 0


func _on_structural_event(event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"assembly_split":
			_handle_split(event)
		&"assembly_merged":
			_handle_merge(event)


func _handle_split(event: Dictionary) -> void:
	var survivor_id: int = int(event["survivor_assembly_id"])
	var rover_involved := survivor_id == _rover_assembly_id
	for mapping_variant: Variant in event.get("new_assemblies", []):
		var mapping: Dictionary = mapping_variant
		var assembly_id: int = int(mapping["assembly_id"])
		if assembly_id == _rover_assembly_id:
			rover_involved = true
		_register_fragment(assembly_id)
	if not rover_involved:
		return
	if survivor_id != _rover_assembly_id:
		_retarget_rover_mount(survivor_id)
	_emit_structure_event(&"detach")


func _handle_merge(event: Dictionary) -> void:
	var survivor_id: int = int(event["survivor_assembly_id"])
	var loser_id: int = int(event["loser_assembly_id"])
	_fragment_assembly_ids.erase(loser_id)
	_fragment_assembly_ids.erase(survivor_id)
	if survivor_id != _rover_assembly_id and loser_id != _rover_assembly_id:
		return
	if survivor_id != _rover_assembly_id:
		_retarget_rover_mount(survivor_id)
	_emit_structure_event(&"attach")


func _retarget_rover_mount(assembly_id: int) -> void:
	var previous_id := _rover_assembly_id
	if previous_id != assembly_id:
		_projection.unregister_mounted_body(previous_id)
	_rover_assembly_id = assembly_id
	_projection.set_collision_profile(assembly_id, 2, 3)
	_projection.mount_assembly_body_now(assembly_id, _mount_body)


func _register_fragment(assembly_id: int) -> void:
	if assembly_id == _rover_assembly_id:
		return
	if _fragment_assembly_ids.has(assembly_id):
		return
	_fragment_assembly_ids.append(assembly_id)
	_projection.set_collision_profile(assembly_id, 2, 3)
	if _assembly_is_wheel_only(assembly_id):
		_projection.add_body_group(assembly_id, "detached_wheels")


func _assembly_is_wheel_only(assembly_id: int) -> bool:
	var assembly := _world.get_assembly_raw(assembly_id)
	if assembly == null:
		return false
	for element_id: int in assembly.element_ids:
		var element := _world.get_element(element_id)
		if element == null:
			continue
		if element.archetype_id != "rover_wheel":
			return false
	return not assembly.element_ids.is_empty()


func _emit_structure_event(kind: StringName) -> void:
	_structure_event_count += 1
	structure_changed.emit({
		"kind": String(kind),
		"elements": _structure_snapshot(),
		"fragments": [],
	})


func _structure_snapshot() -> Dictionary:
	var snapshot: Dictionary = {}
	var assembly := _rover_assembly()
	if assembly == null:
		return snapshot
	for element_id: int in assembly.element_ids:
		var element := _world.get_element(element_id)
		if element == null:
			continue
		var local_id := _local_id_for_element(element_id)
		var cell: Vector3i = element.origin_cell
		if local_id.begins_with("wheel_"):
			snapshot[cell] = {
				"kind": "wheel",
				"mass": element.dry_mass_kg(),
				"wheel_index": WHEEL_LOCAL_IDS.find(local_id),
			}
		else:
			snapshot[cell] = {
				"kind": "frame",
				"mass": element.dry_mass_kg(),
			}
	return snapshot


func _build_cell_maps() -> void:
	_cell_to_local_id.clear()
	for placement_variant: Variant in CART_ROVER.placements:
		var placement := placement_variant as BlueprintElementPlacement
		if placement == null:
			continue
		_cell_to_local_id[placement.origin_cell] = placement.local_id


func _rover_assembly() -> SimulationAssembly:
	if _rover_assembly_id == 0:
		return null
	return _world.get_assembly_raw(_rover_assembly_id)


func _element_id_for_cell(cell: Vector3i) -> int:
	var assembly := _rover_assembly()
	if assembly == null:
		return 0
	var local_id: String = str(_cell_to_local_id.get(cell, ""))
	if local_id.is_empty():
		return 0
	var element_id := int(_local_to_element.get(local_id, 0))
	var element := _world.get_element(element_id)
	if element == null or element.assembly_id != _rover_assembly_id:
		return 0
	return element_id


func _local_id_for_element(element_id: int) -> String:
	for local_id: String in _local_to_element:
		if int(_local_to_element[local_id]) == element_id:
			return local_id
	return ""


func _rover_has_local_id(local_id: String) -> bool:
	var element_id := int(_local_to_element.get(local_id, 0))
	if element_id == 0:
		return false
	var element := _world.get_element(element_id)
	if element == null:
		return false
	return element.assembly_id == _rover_assembly_id
