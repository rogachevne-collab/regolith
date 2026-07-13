class_name GridTransform
extends RefCounted

const _SCRIPT := preload("res://scripts/simulation/runtime/grid_transform.gd")
const _CODEC := preload("res://scripts/simulation/snapshot_codec.gd")

var translation: Vector3i = Vector3i.ZERO
var orientation_index: int = 0


static func identity() -> GridTransform:
	return _SCRIPT.new()


static func from_dict(data: Dictionary) -> GridTransform:
	var transform: GridTransform = _SCRIPT.new()
	transform.translation = _CODEC.vector3i_from_variant(
		data.get("translation", Vector3i.ZERO)
	)
	transform.orientation_index = int(data.get("orientation_index", 0))
	return transform


func duplicate_transform() -> GridTransform:
	var copy: GridTransform = _SCRIPT.new()
	copy.translation = translation
	copy.orientation_index = orientation_index
	return copy


func to_dict() -> Dictionary:
	return {
		"translation": _CODEC.vector3i_to_array(translation),
		"orientation_index": orientation_index,
	}


func is_valid() -> bool:
	return (
		orientation_index >= 0
		and orientation_index < OrientationUtil.ORIENTATION_COUNT
	)


func compose(other: GridTransform) -> GridTransform:
	var result: GridTransform = _SCRIPT.new()
	result.orientation_index = _compose_orientation(
		orientation_index,
		other.orientation_index
	)
	result.translation = map_cell(other.translation)
	return result


func inverse() -> GridTransform:
	var result: GridTransform = _SCRIPT.new()
	result.orientation_index = _invert_orientation(orientation_index)
	result.translation = OrientationUtil.rotate_cell(
		-translation,
		result.orientation_index
	)
	return result


func map_cell(cell: Vector3i) -> Vector3i:
	return (
		translation
		+ OrientationUtil.rotate_cell(cell, orientation_index)
	)


func map_direction(direction: Vector3i) -> Vector3i:
	return OrientationUtil.rotate_direction(direction, orientation_index)


func map_element_pose(
	origin_cell: Vector3i,
	element_orientation_index: int
) -> Dictionary:
	return {
		"origin_cell": map_cell(origin_cell),
		"orientation_index": _compose_orientation(
			orientation_index,
			element_orientation_index
		),
	}


func equals(other: GridTransform) -> bool:
	return (
		other != null
		and translation == other.translation
		and orientation_index == other.orientation_index
	)


static func _compose_orientation(outer_index: int, inner_index: int) -> int:
	var combined: Basis = (
		OrientationUtil.orientation_basis(outer_index)
		* OrientationUtil.orientation_basis(inner_index)
	)
	return _basis_to_orientation_index(combined)


static func _invert_orientation(index: int) -> int:
	var basis: Basis = OrientationUtil.orientation_basis(index)
	return _basis_to_orientation_index(basis.inverse())


static func _basis_to_orientation_index(basis: Basis) -> int:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.orientation_basis(index).is_equal_approx(basis):
			return index
	push_error("GridTransform could not map Basis to orientation index")
	return 0
