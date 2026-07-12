class_name SimulationAssembly
extends RefCounted

const _SCRIPT := preload("res://scripts/simulation/runtime/simulation_assembly.gd")

var assembly_id: int = 0
var topology_revision: int = 0
var grid_frame: GridTransform
var motion: AssemblyMotionState
var element_ids: Array[int] = []
var tombstoned: bool = false
var redirect_to: int = 0


func _init() -> void:
	grid_frame = GridTransform.identity()
	motion = AssemblyMotionState.new()


func bump_revision() -> void:
	topology_revision += 1


func to_dict() -> Dictionary:
	return {
		"assembly_id": assembly_id,
		"topology_revision": topology_revision,
		"grid_frame": grid_frame.to_dict(),
		"motion": motion.to_dict() if motion != null else {},
		"element_ids": element_ids.duplicate(),
		"tombstoned": tombstoned,
		"redirect_to": redirect_to,
	}


static func from_dict(data: Dictionary) -> SimulationAssembly:
	var assembly: SimulationAssembly = _SCRIPT.new()
	assembly.assembly_id = int(data.get("assembly_id", 0))
	assembly.topology_revision = int(data.get("topology_revision", 0))
	assembly.grid_frame = GridTransform.from_dict(
		data.get("grid_frame", {})
	)
	if data.has("motion") and data["motion"] is Dictionary:
		assembly.motion = AssemblyMotionState.from_dict(data["motion"])
	else:
		assembly.motion = AssemblyMotionState.from_grid_frame(
			assembly.grid_frame
		)
	assembly.element_ids = _sorted_int_array(data.get("element_ids", []))
	assembly.tombstoned = bool(data.get("tombstoned", false))
	assembly.redirect_to = int(data.get("redirect_to", 0))
	return assembly


static func _sorted_int_array(values: Variant) -> Array[int]:
	var result: Array[int] = []
	if values is Array:
		for value: Variant in values:
			result.append(int(value))
	result.sort()
	return result
