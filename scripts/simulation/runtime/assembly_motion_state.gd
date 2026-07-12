class_name AssemblyMotionState
extends RefCounted

const _SCRIPT := preload(
	"res://scripts/simulation/runtime/assembly_motion_state.gd"
)
const RIGID_BASIS_EPSILON := 0.0001

var transform: Transform3D = Transform3D.IDENTITY
var linear_velocity: Vector3 = Vector3.ZERO
var angular_velocity: Vector3 = Vector3.ZERO
var sleeping: bool = false
var frozen: bool = false


func duplicate_state() -> AssemblyMotionState:
	var copy: AssemblyMotionState = _SCRIPT.new()
	copy.transform = transform
	copy.linear_velocity = linear_velocity
	copy.angular_velocity = angular_velocity
	copy.sleeping = sleeping
	copy.frozen = frozen
	return copy


func to_dict() -> Dictionary:
	return {
		"transform": {
			"origin": transform.origin,
			"basis": [
				transform.basis.x,
				transform.basis.y,
				transform.basis.z,
			],
		},
		"linear_velocity": linear_velocity,
		"angular_velocity": angular_velocity,
		"sleeping": sleeping,
		"frozen": frozen,
	}


static func from_dict(data: Dictionary) -> AssemblyMotionState:
	var state: AssemblyMotionState = _SCRIPT.new()
	var transform_data: Dictionary = data.get("transform", {})
	var basis_rows: Variant = transform_data.get("basis", [])
	if basis_rows is Array and basis_rows.size() == 3:
		state.transform = Transform3D(
			Basis(
				basis_rows[0],
				basis_rows[1],
				basis_rows[2]
			),
			transform_data.get("origin", Vector3.ZERO)
		)
	state.linear_velocity = data.get("linear_velocity", Vector3.ZERO)
	state.angular_velocity = data.get("angular_velocity", Vector3.ZERO)
	state.sleeping = bool(data.get("sleeping", false))
	state.frozen = bool(data.get("frozen", false))
	return state


static func from_grid_frame(frame: GridTransform) -> AssemblyMotionState:
	var state: AssemblyMotionState = _SCRIPT.new()
	state.transform = Transform3D(
		OrientationUtil.orientation_basis(frame.orientation_index),
		Vector3(frame.translation)
	)
	return state


func equals(other: AssemblyMotionState) -> bool:
	return (
		other != null
		and transform.is_equal_approx(other.transform)
		and linear_velocity.is_equal_approx(other.linear_velocity)
		and angular_velocity.is_equal_approx(other.angular_velocity)
		and sleeping == other.sleeping
		and frozen == other.frozen
	)


func is_valid() -> bool:
	var basis: Basis = transform.basis
	return (
		transform.origin.is_finite()
		and basis.x.is_finite()
		and basis.y.is_finite()
		and basis.z.is_finite()
		and absf(basis.x.length_squared() - 1.0) <= RIGID_BASIS_EPSILON
		and absf(basis.y.length_squared() - 1.0) <= RIGID_BASIS_EPSILON
		and absf(basis.z.length_squared() - 1.0) <= RIGID_BASIS_EPSILON
		and absf(basis.x.dot(basis.y)) <= RIGID_BASIS_EPSILON
		and absf(basis.x.dot(basis.z)) <= RIGID_BASIS_EPSILON
		and absf(basis.y.dot(basis.z)) <= RIGID_BASIS_EPSILON
		and absf(basis.determinant() - 1.0) <= RIGID_BASIS_EPSILON
		and linear_velocity.is_finite()
		and angular_velocity.is_finite()
	)
