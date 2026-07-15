extends Camera3D

@export var sensitivity := 0.25
@export var min_pitch := -85.0
@export var max_pitch := 85.0
@export var head_height := 0.75
@export var orbit_distance := 7.0
@export var orbit_height := 1.5
@export var orbit_min_pitch := -20.0
@export var orbit_max_pitch := 70.0
@export var orbit_collision_mask := 3

var _pitch := 0.0
var _target: Node3D
var _last_target_position := Vector3.ZERO
var _orbit_mode := false
var _orbit_yaw := 0.0
var _orbit_pitch := 15.0

const SETTINGS_PATH := "user://player_settings.cfg"
const TELEPORT_SNAP_DISTANCE := 4.0
const ORBIT_COLLISION_MARGIN := 0.35


func _ready() -> void:
	_target = get_parent() as Node3D
	_load_preferences()
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	call_deferred("_snap_to_target")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_vehicle_camera"):
		_toggle_orbit_mode()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var motion: Vector2 = event.relative
		if _orbit_mode and _is_in_vehicle():
			_orbit_yaw -= deg_to_rad(motion.x * sensitivity)
			_orbit_pitch = clampf(
				_orbit_pitch - motion.y * sensitivity,
				orbit_min_pitch,
				orbit_max_pitch
			)
		elif _target != null:
			_target.rotate_y(deg_to_rad(-motion.x * sensitivity))
			_pitch = clampf(_pitch - motion.y * sensitivity, min_pitch, max_pitch)


func _process(_delta: float) -> void:
	if _target == null:
		return
	if _orbit_mode and not _is_in_vehicle():
		_set_orbit_mode(false)
	# Yaw is applied immediately in _unhandled_input; use one transform source
	# so camera position and heading stay in sync (mixed interpolated/raw
	# sources caused visible rotation jitter on uneven voxel ground).
	# In a vehicle the target rides a RigidBody — follow the interpolated
	# pose so render frames are not locked to the physics tick.
	if _orbit_mode:
		global_transform = _orbit_camera_transform()
		return
	var target_transform := _target_follow_transform()
	if (
		_last_target_position != Vector3.ZERO
		and target_transform.origin.distance_to(_last_target_position)
		> TELEPORT_SNAP_DISTANCE
	):
		reset_physics_interpolation()
	_last_target_position = target_transform.origin
	var target_basis := target_transform.basis.orthonormalized()
	global_transform = _camera_transform(
		target_transform.origin,
		target_basis
	)


func view_angles() -> Vector2:
	var yaw := _target.rotation.y if _target != null else 0.0
	return Vector2(yaw, _pitch)


func apply_view_angles(yaw_rad: float, pitch_deg: float) -> void:
	if _target != null:
		_target.rotation.y = yaw_rad
	_pitch = clampf(pitch_deg, min_pitch, max_pitch)
	if _target == null:
		return
	if _orbit_mode:
		global_transform = _orbit_camera_transform()
		reset_physics_interpolation()
		return
	var target_transform := _target_follow_transform()
	_last_target_position = target_transform.origin
	global_transform = _camera_transform(
		target_transform.origin,
		target_transform.basis.orthonormalized()
	)
	reset_physics_interpolation()


func movement_basis() -> Basis:
	if _target == null:
		return Basis.IDENTITY
	return _target_follow_transform().basis.orthonormalized()


func aim_transform() -> Transform3D:
	if _orbit_mode:
		return global_transform
	if _target == null:
		return global_transform
	var target_transform := _target_follow_transform()
	return _camera_transform(
		target_transform.origin,
		target_transform.basis.orthonormalized()
	)


func consume_yaw_delta() -> float:
	# Yaw is applied immediately in _unhandled_input; kept for callers.
	return 0.0


func snap_after_teleport() -> void:
	_snap_to_target()


func set_look_sensitivity(value: float) -> void:
	sensitivity = clampf(value, 0.02, 1.5)
	_save_preferences()


func set_camera_fov(value: float) -> void:
	fov = clampf(value, 60.0, 110.0)
	_save_preferences()


func is_vehicle_orbit_camera() -> bool:
	return _orbit_mode and _is_in_vehicle()


func _toggle_orbit_mode() -> void:
	if not _is_in_vehicle():
		_set_orbit_mode(false)
		return
	_set_orbit_mode(not _orbit_mode)


func _set_orbit_mode(enabled: bool) -> void:
	if enabled == _orbit_mode:
		return
	_orbit_mode = enabled
	if _orbit_mode:
		_init_orbit_from_vehicle()
	reset_physics_interpolation()


func _init_orbit_from_vehicle() -> void:
	var vehicle := _current_vehicle()
	if vehicle == null:
		_orbit_yaw = _target.rotation.y if _target != null else 0.0
		_orbit_pitch = 15.0
		return
	var forward := -vehicle.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = -_target_follow_transform().basis.z
		forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	_orbit_yaw = atan2(forward.x, forward.z) + PI
	_orbit_pitch = clampf(15.0, orbit_min_pitch, orbit_max_pitch)


func _is_in_vehicle() -> bool:
	return (
		_target != null
		and _target.has_method("is_in_vehicle")
		and bool(_target.call("is_in_vehicle"))
	)


func _current_vehicle() -> Node3D:
	if _target == null or not _target.has_method("current_vehicle"):
		return null
	return _target.call("current_vehicle") as Node3D


func _vehicle_follow_transform() -> Transform3D:
	var vehicle := _current_vehicle()
	if vehicle == null:
		return _target_follow_transform()
	if vehicle.is_inside_tree():
		return vehicle.get_global_transform_interpolated()
	return vehicle.global_transform


func _target_follow_transform() -> Transform3D:
	if _target == null:
		return Transform3D.IDENTITY
	if _is_in_vehicle():
		return _target.get_global_transform_interpolated()
	return _target.global_transform


func _camera_transform(
	target_position: Vector3,
	target_basis: Basis
) -> Transform3D:
	var look_basis := (
		target_basis
		* Basis(Vector3.RIGHT, deg_to_rad(_pitch))
	)
	# Tip past ~70°: body-up head offset buries the camera in terrain.
	# Upright drive keeps body-up so suspension bounce matches look.
	var head_offset := target_basis.y
	if (
		_is_in_vehicle()
		and head_offset.normalized().dot(Vector3.UP) < 0.35
	):
		head_offset = Vector3.UP
	var camera_position := target_position + head_offset * head_height
	return Transform3D(look_basis, camera_position)


func _orbit_camera_transform() -> Transform3D:
	var vehicle_xf := _vehicle_follow_transform()
	var pivot := vehicle_xf.origin + Vector3.UP * orbit_height
	var yaw_basis := Basis(Vector3.UP, _orbit_yaw)
	# Positive orbit pitch raises the camera (look down at the vehicle).
	var pitch_basis := Basis(Vector3.RIGHT, -deg_to_rad(_orbit_pitch))
	var orbit_basis := yaw_basis * pitch_basis
	var desired := pivot + orbit_basis * Vector3(0.0, 0.0, orbit_distance)
	var camera_position := _spring_orbit_position(pivot, desired)
	var look_dir := pivot - camera_position
	if look_dir.length_squared() < 0.0001:
		return Transform3D(Basis.IDENTITY, camera_position)
	var up := Vector3.UP
	if absf(look_dir.normalized().dot(up)) > 0.99:
		up = Vector3.RIGHT
	return Transform3D(Basis.looking_at(look_dir, up), camera_position)


func _spring_orbit_position(pivot: Vector3, desired: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	if space == null:
		return desired
	var to_cam := desired - pivot
	var distance := to_cam.length()
	if distance <= 0.001:
		return desired
	var query := PhysicsRayQueryParameters3D.create(pivot, desired)
	query.collision_mask = orbit_collision_mask
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var exclude: Array[RID] = []
	var vehicle := _current_vehicle()
	if vehicle is CollisionObject3D:
		exclude.append((vehicle as CollisionObject3D).get_rid())
	if _target is CollisionObject3D:
		exclude.append((_target as CollisionObject3D).get_rid())
	query.exclude = exclude
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return desired
	var hit_point: Vector3 = hit["position"]
	var safe_distance := maxf(
		pivot.distance_to(hit_point) - ORBIT_COLLISION_MARGIN,
		0.5
	)
	return pivot + to_cam.normalized() * safe_distance


func _snap_to_target() -> void:
	if _target == null:
		return
	if _orbit_mode:
		global_transform = _orbit_camera_transform()
		reset_physics_interpolation()
		return
	var target_transform := _target_follow_transform()
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
