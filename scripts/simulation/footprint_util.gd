class_name FootprintUtil
extends RefCounted

## The single home of footprint face enumeration.
##
## Face data dictionaries use the keys "local_cell" (Vector3i) and
## "local_face" (OrientationUtil.Face), matching the matching layer.

const STRUCTURAL_ID_PREFIX := "structural_"

const FACE_SUFFIXES: PackedStringArray = [
	"px",
	"nx",
	"py",
	"ny",
	"pz",
	"nz",
]

const FACE_ORDER: Array[OrientationUtil.Face] = [
	OrientationUtil.Face.POS_X,
	OrientationUtil.Face.NEG_X,
	OrientationUtil.Face.POS_Y,
	OrientationUtil.Face.NEG_Y,
	OrientationUtil.Face.POS_Z,
	OrientationUtil.Face.NEG_Z,
]


## Canonical id of a cell-face attach point. Persisted in joint records —
## the format must stay stable.
static func structural_id_for(
	local_cell: Vector3i,
	local_face: OrientationUtil.Face
) -> String:
	return "%s%d_%d_%d_%s" % [
		STRUCTURAL_ID_PREFIX,
		local_cell.x,
		local_cell.y,
		local_cell.z,
		FACE_SUFFIXES[int(local_face)],
	]


## Every cell face of the footprint that is not shared with another
## footprint cell, in deterministic (cell, face) order.
static func external_faces(
	footprint_cells: Array[Vector3i]
) -> Array[Dictionary]:
	var occupied: Dictionary = {}
	for cell: Vector3i in footprint_cells:
		occupied[cell] = true
	var faces: Array[Dictionary] = []
	for cell: Vector3i in footprint_cells:
		for face: OrientationUtil.Face in FACE_ORDER:
			var neighbor: Vector3i = cell + OrientationUtil.face_to_vector(face)
			if occupied.has(neighbor):
				continue
			faces.append({
				"local_cell": cell,
				"local_face": face,
			})
	return faces


static func is_external_face(
	footprint_cells: Array[Vector3i],
	local_cell: Vector3i,
	local_face: OrientationUtil.Face
) -> bool:
	var occupied: Dictionary = {}
	for cell: Vector3i in footprint_cells:
		occupied[cell] = true
	if not occupied.has(local_cell):
		return false
	var neighbor: Vector3i = local_cell + OrientationUtil.face_to_vector(local_face)
	return not occupied.has(neighbor)


## Centre of a cell face in part-local metres.
static func face_center_local(
	local_cell: Vector3i,
	local_face: OrientationUtil.Face
) -> Vector3:
	return (
		GridMetric.cell_center_meters(local_cell)
		+ Vector3(OrientationUtil.face_to_vector(local_face))
		* GridMetric.HALF_CELL_SIZE_M
	)
