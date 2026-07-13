class_name GridMetric
extends RefCounted


const CELL_SIZE_M := 0.5
const HALF_CELL_SIZE_M := CELL_SIZE_M * 0.5
const CELL_CENTER_OFFSET_M := Vector3.ONE * HALF_CELL_SIZE_M


static func cell_to_meters(cell: Vector3i) -> Vector3:
	return Vector3(cell) * CELL_SIZE_M


static func cell_vector_to_meters(cell: Vector3) -> Vector3:
	return cell * CELL_SIZE_M


static func cell_center_meters(cell: Vector3i) -> Vector3:
	return cell_to_meters(cell) + CELL_CENTER_OFFSET_M


static func meters_to_cell_floor(position_m: Vector3) -> Vector3i:
	return Vector3i(
		floori(position_m.x / CELL_SIZE_M),
		floori(position_m.y / CELL_SIZE_M),
		floori(position_m.z / CELL_SIZE_M)
	)


static func meters_to_cell_round(position_m: Vector3) -> Vector3i:
	return Vector3i(
		roundi(position_m.x / CELL_SIZE_M),
		roundi(position_m.y / CELL_SIZE_M),
		roundi(position_m.z / CELL_SIZE_M)
	)
