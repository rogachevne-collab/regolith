class_name StructuralMountPad
extends Resource

## An attach point on a part.
##
## `local_cell` + `local_face` are the COARSE placement: which cell face this
## pad lives on. That is what decides whether two parts mate (faces meet and
## tags are compatible) and is all a grid block ever needs.
##
## `local_position` is the EXACT point, in part-local metres. Blocks leave it
## alone and the point is just the centre of the face. Precise parts (a wheel,
## a suspension hub) set it so the point sits exactly where the model wants it
## — in the hub slot, or dead centre of the wheel — and the joint is anchored
## there instead of at the face centre.

@export var local_cell: Vector3i = Vector3i.ZERO
@export var local_face: OrientationUtil.Face = OrientationUtil.Face.POS_X
@export var socket_tag: String = ""

## When false (default) the point is the centre of (local_cell, local_face),
## which is exactly how every existing part behaves.
@export var exact_point: bool = false
## Exact attach point in part-local metres. Only used when exact_point is true.
@export var local_position: Vector3 = Vector3.ZERO


## The attach point in part-local metres, whichever mode this pad is in.
func point_local() -> Vector3:
	if exact_point:
		return local_position
	return face_center_local()


func face_center_local() -> Vector3:
	return (
		GridMetric.cell_center_meters(local_cell)
		+ Vector3(OrientationUtil.face_to_vector(local_face))
		* GridMetric.HALF_CELL_SIZE_M
	)


## How far the exact point sits from the face centre (0 for plain grid pads).
func offset_from_face_center() -> Vector3:
	return point_local() - face_center_local()
