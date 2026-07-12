class_name GridAlignment
extends RefCounted

const MAX_POSITION_ERROR_M := 0.125
const MAX_ANGLE_ERROR_RAD := deg_to_rad(7.5)


static func nearest_alignment(
	transform_a: Transform3D,
	transform_b: Transform3D
) -> Dictionary:
	var relative: Transform3D = transform_a.inverse() * transform_b
	var grid := GridTransform.new()
	grid.translation = Vector3i(
		int(round(relative.origin.x)),
		int(round(relative.origin.y)),
		int(round(relative.origin.z))
	)
	var best_index := 0
	var best_score := -INF
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		var candidate: Basis = OrientationUtil.orientation_basis(index)
		var score: float = (
			candidate.x.dot(relative.basis.x)
			+ candidate.y.dot(relative.basis.y)
			+ candidate.z.dot(relative.basis.z)
		)
		if score > best_score:
			best_score = score
			best_index = index
	grid.orientation_index = best_index
	var snapped_transform := Transform3D(
		OrientationUtil.orientation_basis(best_index),
		Vector3(grid.translation)
	)
	var position_error: float = (
		relative.origin - snapped_transform.origin
	).length()
	var error_basis: Basis = (
		snapped_transform.basis.inverse() * relative.basis
	)
	var cosine: float = clampf(
		(
			error_basis.x.x
			+ error_basis.y.y
			+ error_basis.z.z
			- 1.0
		) * 0.5,
		-1.0,
		1.0
	)
	var angle_error: float = acos(cosine)
	return {
		"grid_transform": grid,
		"position_error_m": position_error,
		"angle_error_rad": angle_error,
		"aligned": (
			position_error <= MAX_POSITION_ERROR_M
			and angle_error <= MAX_ANGLE_ERROR_RAD
		),
	}


static func validate_supplied(
	transform_a: Transform3D,
	transform_b: Transform3D,
	supplied_b_to_a: GridTransform
) -> Dictionary:
	var result: Dictionary = nearest_alignment(transform_a, transform_b)
	var nearest: GridTransform = result["grid_transform"]
	result["matches_supplied"] = (
		supplied_b_to_a != null
		and supplied_b_to_a.is_valid()
		and nearest.equals(supplied_b_to_a)
	)
	result["valid"] = (
		bool(result["aligned"])
		and bool(result["matches_supplied"])
	)
	return result
