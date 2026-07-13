class_name PlaceElementCommand
extends StructuralCommand

var assembly_id: int = 0
var expected_assembly_revision: int = -1
var archetype: ElementArchetype
var origin_cell: Vector3i = Vector3i.ZERO
var orientation_index: int = 0
var new_assembly_grid_frame: GridTransform = GridTransform.identity()
## Exact root pose for a new assembly. Topology remains in grid_frame; this is
## the continuous pose shared by preview, physics and presentation.
var initial_motion: AssemblyMotionState
var store_id: String = "player"


func kind() -> StringName:
	return &"place_element"


func execution_copy() -> StructuralCommand:
	var copy := PlaceElementCommand.new()
	copy.assembly_id = assembly_id
	copy.expected_assembly_revision = expected_assembly_revision
	copy.archetype = archetype
	copy.origin_cell = origin_cell
	copy.orientation_index = orientation_index
	copy.new_assembly_grid_frame = (
		new_assembly_grid_frame.duplicate_transform()
		if new_assembly_grid_frame != null
		else null
	)
	copy.initial_motion = (
		initial_motion.duplicate_state()
		if initial_motion != null
		else null
	)
	copy.store_id = store_id
	return copy
