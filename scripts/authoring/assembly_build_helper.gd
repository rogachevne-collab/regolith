class_name AssemblyBuildHelper
extends RefCounted

## Thin Place/Weld/Connect helper for agent/compose paths.
## Tracks topology_revision; callers never invent revision by hand.

var world: SimulationWorld
var store_id: String = "player"
var assembly_id: int = 0
var revision: int = 0
var last_error: String = ""
var element_ids: Dictionary = {}


func _init(p_world: SimulationWorld, p_store_id: String = "player") -> void:
	world = p_world
	store_id = p_store_id


func ensure_materials(amount: float = 500.0) -> void:
	if world == null:
		return
	world.ensure_resource_store(store_id)
	world.set_resource_amount(store_id, "construction_component", amount)


func spawn_anchor(
	archetype: ElementArchetype,
	grid_frame: GridTransform = GridTransform.identity()
) -> bool:
	last_error = ""
	if world == null or archetype == null:
		last_error = "no_world_or_archetype"
		return false
	var place := PlaceElementCommand.new()
	place.assembly_id = 0
	place.origin_cell = Vector3i.ZERO
	place.orientation_index = 0
	place.archetype = archetype
	place.new_assembly_grid_frame = grid_frame
	place.initial_motion = AssemblyMotionState.from_grid_frame(grid_frame)
	place.store_id = store_id
	var result := world.apply_structural_command_now(place)
	if not result.is_ok():
		last_error = "anchor:%s" % result.reason
		return false
	assembly_id = int(result.data.get("assembly_id", 0))
	revision = int(result.data.get("topology_revision", 0))
	element_ids["anchor"] = int(result.data.get("element_id", 0))
	return assembly_id > 0


func place(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int = 0,
	key: String = ""
) -> bool:
	last_error = ""
	if world == null or archetype == null or assembly_id <= 0:
		last_error = "not_ready"
		return false
	var place_cmd := PlaceElementCommand.new()
	place_cmd.assembly_id = assembly_id
	place_cmd.expected_assembly_revision = revision
	place_cmd.archetype = archetype
	place_cmd.origin_cell = origin_cell
	place_cmd.orientation_index = orientation_index
	place_cmd.store_id = store_id
	var result := world.apply_structural_command_now(place_cmd)
	if not result.is_ok():
		last_error = "%s@%s:%s" % [archetype.archetype_id, origin_cell, result.reason]
		return false
	revision = int(result.data.get("topology_revision", revision))
	var element_id := int(result.data.get("element_id", 0))
	if not key.is_empty():
		element_ids[key] = element_id
	return true


func weld_all() -> void:
	if world == null or assembly_id <= 0:
		return
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element == null:
			continue
		var weld := WeldElementCommand.new()
		weld.element_id = element_id
		weld.expected_state_revision = element.state_revision
		weld.max_material_amount = 100.0
		weld.store_id = store_id
		world.apply_structural_command_now(weld)


func connect_ports(
	from_key: String,
	from_port: String,
	to_key: String,
	to_port: String
) -> bool:
	last_error = ""
	var from_id := int(element_ids.get(from_key, 0))
	var to_id := int(element_ids.get(to_key, 0))
	if from_id <= 0 or to_id <= 0:
		last_error = "missing_port_elements"
		return false
	var result := world.connect_network(from_id, from_port, to_id, to_port)
	if not result.is_ok():
		last_error = "wire:%s" % result.reason
		return false
	return true


static func orientation_with_local_face(
	local_face: Vector3i,
	world_direction: Vector3i
) -> int:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if (
			OrientationUtil.rotate_direction(local_face, index)
			== world_direction
		):
			return index
	return 0
