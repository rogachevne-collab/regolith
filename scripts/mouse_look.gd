extends Camera3D

@export var sensitivity := 0.25
@export var min_pitch := -85.0
@export var max_pitch := 85.0
@export var head_height := 0.75

var _pitch := 0.0
var _pending_yaw := 0.0
var _target: Node3D
var _last_target_position := Vector3.ZERO

const SETTINGS_PATH := "user://player_settings.cfg"
const TELEPORT_SNAP_DISTANCE := 4.0


func _ready() -> void:
	_target = get_parent() as Node3D
	_load_preferences()
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	call_deferred("_snap_to_target")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var motion: Vector2 = event.relative
		_pending_yaw -= motion.x * sensitivity
		_pitch = clampf(_pitch - motion.y * sensitivity, min_pitch, max_pitch)


func _process(_delta: float) -> void:
	if _target == null:
		return
	var target_transform := _target.get_global_transform_interpolated()
	if (
		_last_target_position != Vector3.ZERO
		and target_transform.origin.distance_to(_last_target_position)
		> TELEPORT_SNAP_DISTANCE
	):
		reset_physics_interpolation()
	_last_target_position = target_transform.origin
	global_transform = _camera_transform(
		target_transform.origin,
		_target.global_transform.basis.orthonormalized()
		* Basis(Vector3.UP, deg_to_rad(_pending_yaw))
	)


func movement_basis() -> Basis:
	if _target == null:
		return Basis.IDENTITY
	return (
		_target.global_transform.basis.orthonormalized()
		* Basis(Vector3.UP, deg_to_rad(_pending_yaw))
	)


func aim_transform() -> Transform3D:
	if _target == null:
		return global_transform
	var target_transform := _target.global_transform
	var target_basis := (
		target_transform.basis.orthonormalized()
		* Basis(Vector3.UP, deg_to_rad(_pending_yaw))
	)
	return _camera_transform(target_transform.origin, target_basis)


func consume_yaw_delta() -> float:
	var result := _pending_yaw
	_pending_yaw = 0.0
	return result


func set_look_sensitivity(value: float) -> void:
	sensitivity = clampf(value, 0.02, 1.5)
	_save_preferences()


func set_camera_fov(value: float) -> void:
	fov = clampf(value, 60.0, 110.0)
	_save_preferences()


func _camera_transform(
	target_position: Vector3,
	target_basis: Basis
) -> Transform3D:
	var look_basis := (
		target_basis
		* Basis(Vector3.RIGHT, deg_to_rad(_pitch))
	)
	var camera_position := (
		target_position
		+ target_basis.y * head_height
	)
	return Transform3D(look_basis, camera_position)


func _snap_to_target() -> void:
	if _target == null:
		return
	var target_transform := _target.global_transform
	_last_target_position = target_transform.origin
	global_transform = _camera_transform(
		target_transform.origin,
		target_transform.basis.orthonormalized()
	)
	reset_physics_interpolation()


func _load_preferences() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	sensitivity = clampf(
		float(config.get_value("look", "sensitivity", sensitivity)),
		0.02,
		1.5
	)
	fov = clampf(
		float(config.get_value("camera", "fov", fov)),
		60.0,
		110.0
	)


func _save_preferences() -> void:
	var config := ConfigFile.new()
	config.set_value("look", "sensitivity", sensitivity)
	config.set_value("camera", "fov", fov)
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		push_warning("Could not save player settings: %s" % error_string(error))
