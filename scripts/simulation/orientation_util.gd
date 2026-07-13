class_name OrientationUtil
extends RefCounted

const ORIENTATION_COUNT := 24

enum Face {
	POS_X,
	NEG_X,
	POS_Y,
	NEG_Y,
	POS_Z,
	NEG_Z,
}

const _X_AXES: Array[Vector3i] = [
	Vector3i.RIGHT,
	Vector3i.LEFT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.BACK,
	Vector3i.FORWARD,
]
const _Y_AXES: Array[Vector3i] = [
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.RIGHT,
	Vector3i.LEFT,
	Vector3i.BACK,
	Vector3i.FORWARD,
]

static var _orientations: Array[Basis] = []
static var _initialized := false


static func orientation_basis(orientation_index: int) -> Basis:
	_ensure_initialized()
	assert(orientation_index >= 0 and orientation_index < ORIENTATION_COUNT)
	return _orientations[orientation_index]


static func rotate_cell(cell: Vector3i, orientation_index: int) -> Vector3i:
	var rotated: Vector3 = orientation_basis(orientation_index) * Vector3(cell)
	return Vector3i(
		int(round(rotated.x)),
		int(round(rotated.y)),
		int(round(rotated.z))
	)


static func rotate_direction(direction: Vector3i, orientation_index: int) -> Vector3i:
	return rotate_cell(direction, orientation_index)


static func rotate_face(face: Face, orientation_index: int) -> Face:
	var direction: Vector3i = rotate_direction(
		face_to_vector(face),
		orientation_index
	)
	return vector_to_face(direction)


static func face_to_vector(face: Face) -> Vector3i:
	match face:
		Face.POS_X:
			return Vector3i(1, 0, 0)
		Face.NEG_X:
			return Vector3i(-1, 0, 0)
		Face.POS_Y:
			return Vector3i(0, 1, 0)
		Face.NEG_Y:
			return Vector3i(0, -1, 0)
		Face.POS_Z:
			return Vector3i(0, 0, 1)
		Face.NEG_Z:
			return Vector3i(0, 0, -1)
	return Vector3i.ZERO


static func vector_to_face(direction: Vector3i) -> Face:
	if direction == Vector3i(1, 0, 0):
		return Face.POS_X
	if direction == Vector3i(-1, 0, 0):
		return Face.NEG_X
	if direction == Vector3i(0, 1, 0):
		return Face.POS_Y
	if direction == Vector3i(0, -1, 0):
		return Face.NEG_Y
	if direction == Vector3i(0, 0, 1):
		return Face.POS_Z
	if direction == Vector3i(0, 0, -1):
		return Face.NEG_Z
	return Face.POS_X


static func orientation_label(orientation_index: int) -> String:
	return "%02d" % orientation_index


static func _ensure_initialized() -> void:
	if _initialized:
		return
	_initialized = true
	_orientations = _build_orientations()


static func _build_orientations() -> Array[Basis]:
	var results: Array[Basis] = []
	for x_axis: Vector3i in _X_AXES:
		for y_axis: Vector3i in _Y_AXES:
			if _dot_i(x_axis, y_axis) != 0:
				continue
			var z_axis: Vector3i = _cross_i(x_axis, y_axis)
			results.append(
				Basis(
					Vector3(x_axis),
					Vector3(y_axis),
					Vector3(z_axis)
				)
			)
	if results.size() != ORIENTATION_COUNT:
		push_error(
			"OrientationUtil expected %d orientations, got %d"
			% [ORIENTATION_COUNT, results.size()]
		)
	return results


static func _dot_i(left: Vector3i, right: Vector3i) -> int:
	return left.x * right.x + left.y * right.y + left.z * right.z


static func _cross_i(left: Vector3i, right: Vector3i) -> Vector3i:
	return Vector3i(
		left.y * right.z - left.z * right.y,
		left.z * right.x - left.x * right.z,
		left.x * right.y - left.y * right.x
	)
