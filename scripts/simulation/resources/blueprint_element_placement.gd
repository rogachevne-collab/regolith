class_name BlueprintElementPlacement
extends Resource

@export var local_id: String = ""
@export var archetype: ElementArchetype
@export var origin_cell: Vector3i = Vector3i.ZERO
@export var orientation_index: int = 0


func compare_sort_key(other: BlueprintElementPlacement) -> bool:
	if origin_cell.x != other.origin_cell.x:
		return origin_cell.x < other.origin_cell.x
	if origin_cell.y != other.origin_cell.y:
		return origin_cell.y < other.origin_cell.y
	if origin_cell.z != other.origin_cell.z:
		return origin_cell.z < other.origin_cell.z
	return local_id < other.local_id
