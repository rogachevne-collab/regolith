class_name ElementArchetype
extends Resource

@export var archetype_id: String = ""
@export var display_name: String = ""
@export var roles: PackedStringArray = PackedStringArray()
@export var mass_kg: float = 1.0
@export var footprint_cells: Array[Vector3i] = [Vector3i.ZERO]
@export var colliders: Array[ColliderDefinition] = []
@export var max_integrity: float = 100.0
@export var ports: Array[PortDefinition] = []
@export var build_requirements: Array[BuildRequirement] = []


func get_occupied_cells(
	origin_cell: Vector3i,
	orientation_index: int
) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for local_cell: Vector3i in footprint_cells:
		var rotated: Vector3i = OrientationUtil.rotate_cell(
			local_cell,
			orientation_index
		)
		result.append(origin_cell + rotated)
	return result
