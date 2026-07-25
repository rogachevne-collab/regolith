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
@export var shake_max_offset := 0.01
@export var shake_max_forward := 0.016
@export var shake_max_roll_deg := 0.25

## Look yaw in the local gravity tangent frame (radians). Applied to the body
## only inside `_physics_process` so physics interpolation stays valid; the
## camera uses it immediately for FP look.
var _yaw_rad := 0.0
var _pitch := 0.0
var _target: Node3D
var _last_target_position := Vector3.ZERO
var _orbit_mode := false
var _orbit_yaw := 0.0
var _orbit_pitch := 15.0
## Accumulated mouse delta for SE-like ship pitch/yaw (consumed by gateway).
var _flight_look_delta := Vector2.ZERO
var _shake_hold := 0.0

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
	# toggle_vehicle_camera is polled in _process — HUD/_unhandled ordering while
	# seated can swallow V before it reaches this camera node.
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var motion: Vector2 = event.relative
		if _orbit_mode and _is_in_vehicle():
			_orbit_yaw -= deg_to_rad(motion.x * sensitivity)
			_orbit_pitch = clampf(
				_orbit_pitch - motion.y * sensitivity,
				orbit_min_pitch,
				orbit_max_pitch
			)
		elif _is_flight_controls_active():
			# SE cockpit: mouse steers the grid; camera stays seat-forward.
			_flight_look_delta.x += motion.x * sensitivity
			_flight_look_delta.y += motion.y * sensitivity
			_pitch = 0.0
		elif _target != null:
			# Do NOT rotate the interpolated body here — that breaks Godot
			# physics interpolation and locks the camera to the physics tick.
			_yaw_rad += deg_to_rad(-motion.x * sensitivity)
			_pitch = clampf(_pitch - motion.y * sensitivity, min_pitch, max_pitch)


func set_camera_shake_hold(intensity: float) -> void:
	_shake_hold = clampf(intensity, 0.0, 1.0)


func _process(_delta: float) -> void:
	if _target == null:
		return
	# Poll: when seated under a replica body, HUD/_unhandled_input ordering can
	# swallow V the same way bootstrap polls spawn_debug_rover.
	if Input.is_action_just_pressed(&"toggle_vehicle_camera"):
		_toggle_orbit_mode()
	if _orbit_mode and not _is_in_vehicle():
		_set_orbit_mode(false)
	# FP: interpolated origin (smooth locomotion) + immediate look yaw/pitch.
	# Writing body yaw in input used to invalidate interpolation; mixing
	# interpolated origin with raw body basis caused rotation jitter on
	# uneven voxel ground — look basis is owned by camera yaw/pitch instead.
	if _orbit_mode:
		global_transform = _orbit_camera_transform()
		return
	var follow := _follow_origin()
	if (
		_last_target_position != Vector3.ZERO
		and follow.distance_to(_last_target_position) > TELEPORT_SNAP_DISTANCE
	):
		reset_physics_interpolation()
	_last_target_position = follow
	var camera_xf := _camera_transform(follow)
	if _shake_hold > 0.001:
		camera_xf = _apply_camera_shake(camera_xf, _shake_hold)
	global_transform = camera_xf


func view_angles() -> Vector2:
	return Vector2(_yaw_rad, _pitch)


func apply_view_angles(yaw_rad: float, pitch_deg: float) -> void:
	_yaw_rad = yaw_rad
	_pitch = clampf(pitch_deg, min_pitch, max_pitch)
	sync_body_yaw()
	if _target == null:
		return
	if _orbit_mode:
		global_transform = _orbit_camera_transform()
		reset_physics_interpolation()
		return
	var follow := _follow_origin()
	_last_target_position = follow
	global_transform = _camera_transform(follow)
	reset_physics_interpolation()


## Push look yaw onto the body during the physics tick (gameplay / capsule).
func sync_body_yaw() -> void:
	if _target == null:
		return
	if _orbit_mode or _is_flight_controls_active():
		return
	_target.global_transform.basis = _yaw_basis_at(_target.global_position)


func movement_basis() -> Basis:
	if _target == null:
		return Basis.IDENTITY
	# Gameplay reads physics-tick pose; yaw state is authoritative for facing.
	return _yaw_basis_at(_target.global_position)


func aim_transform() -> Transform3D:
	## Stable aim without shake so dig raycasts do not jitter.
	if _orbit_mode:
		return global_transform
	if _target == null:
		return global_transform
	return _camera_transform(_follow_origin())


func _apply_camera_shake(xf: Transform3D, intensity: float) -> Transform3D:
	var amp := clampf(intensity, 0.0, 1.0)
	var t := Time.get_ticks_msec() * 0.001
	var ox := sin(t * 118.0) * shake_max_offset * amp
	var oy := cos(t * 97.0) * shake_max_offset * amp
	var oz := sin(t * 149.0) * shake_max_forward * amp
	var roll := sin(t * 131.0) * deg_to_rad(shake_max_roll_deg) * amp
	var origin := (
		xf.origin
		+ xf.basis.x * ox
		+ xf.basis.y * oy
		- xf.basis.z * oz
	)
	var basis := (xf.basis * Basis(Vector3.FORWARD, roll)).orthonormalized()
	return Transform3D(basis, origin)


func consume_yaw_delta() -> float:
	# Yaw is owned by `_yaw_rad`; kept for callers.
	return 0.0


func snap_after_teleport() -> void:
	_snap_to_target()


func capture_yaw_from_body() -> void:
	_capture_yaw_from_body()


func set_look_sensitivity(value: float) -> void:
	sensitivity = clampf(value, 0.02, 1.5)
	_save_preferences()


func set_camera_fov(value: float) -> void:
	fov = clampf(value, 60.0, 110.0)
	_save_preferences()


func is_vehicle_orbit_camera() -> bool:
	return _orbit_mode and _is_in_vehicle()


func consume_flight_look_delta() -> Vector2:
	var delta := _flight_look_delta
	_flight_look_delta = Vector2.ZERO
	return delta


func _is_flight_controls_active() -> bool:
	return (
		_is_in_vehicle()
		and not _orbit_mode
		and _target != null
		and _target.has_method("is_vehicle_flight_controls")
		and bool(_target.call("is_vehicle_flight_controls"))
	)


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
	else:
		_capture_yaw_from_body()
	reset_physics_interpolation()


func _init_orbit_from_vehicle() -> void:
	var vehicle := _current_vehicle()
	if vehicle == null:
		_orbit_yaw = 0.0
		_orbit_pitch = 15.0
		return
	var up := GravityField.resolve_up(vehicle, vehicle.global_position)
	var forward := GravityField.project_on_tangent(
		-vehicle.global_transform.basis.z,
		up
	)
	if forward.length_squared() < 0.0001:
		forward = GravityField.project_on_tangent(
			-_yaw_basis_at(vehicle.global_position).z,
			up
		)
	if forward.length_squared() < 0.0001:
		forward = GravityField.project_on_tangent(Vector3.FORWARD, up)
	if forward.length_squared() < 0.0001:
		_orbit_yaw = 0.0
	else:
		forward = forward.normalized()
		var forward_ref := GravityField.project_on_tangent(Vector3.FORWARD, up)
		if forward_ref.length_squared() < 0.0001:
			forward_ref = GravityField.project_on_tangent(Vector3.RIGHT, up)
		forward_ref = forward_ref.normalized()
		_orbit_yaw = atan2(
			forward_ref.cross(forward).dot(up),
			forward_ref.dot(forward)
		) + PI
	_orbit_pitch = clampf(15.0, orbit_min_pitch, orbit_max_pitch)


func _is_in_vehicle() -> bool:
	if _target == null:
		return false
	if (
		_target.has_method("is_in_vehicle")
		and bool(_target.call("is_in_vehicle"))
	):
		return true
	# Coop replica seat: body may have been recreated mid-drive while the
	# gateway seat id (meta) is still claimed — treat as seated for camera.
	return (
		_target.has_meta("control_seat_element_id")
		and int(_target.get_meta("control_seat_element_id")) > 0
	)


func _current_vehicle() -> Node3D:
	if _target == null or not _target.has_method("current_vehicle"):
		return null
	var vehicle := _target.call("current_vehicle") as Node3D
	if vehicle != null and is_instance_valid(vehicle):
		return vehicle
	# Fallback: parent is the seat body after enter_vehicle reparent.
	var parent := _target.get_parent() as Node3D
	if parent is PhysicsBody3D and is_instance_valid(parent):
		return parent
	return null


func _vehicle_follow_transform() -> Transform3D:
	var vehicle := _current_vehicle()
	if vehicle == null:
		return _target_physics_transform()
	if vehicle.is_inside_tree():
		return vehicle.get_global_transform_interpolated()
	return vehicle.global_transform


func _target_physics_transform() -> Transform3D:
	if _target == null:
		return Transform3D.IDENTITY
	return _target.global_transform


func _follow_origin() -> Vector3:
	if _target == null:
		return Vector3.ZERO
	# Seated: compose from the seat RigidBody's FTI pose + local seat offset.
	# CharacterBody3D child FTI can lag the parent; orbit already used this path.
	if _is_in_vehicle():
		var vehicle := _current_vehicle()
		if vehicle != null and vehicle.is_inside_tree():
			return (
				vehicle.get_global_transform_interpolated() * _target.transform
			).origin
	if _target.is_inside_tree():
		return _target.get_global_transform_interpolated().origin
	return _target.global_position


func _yaw_basis_at(origin: Vector3) -> Basis:
	var up := GravityField.resolve_up(_target, origin)
	var gravity_field := GravityField.find_in_tree(_target)
	var frame: Basis
	if gravity_field != null:
		frame = gravity_field.tangent_basis_at(origin)
	else:
		frame = Basis.looking_at(Vector3.FORWARD, Vector3.UP)
	return (Basis(up, _yaw_rad) * frame).orthonormalized()


func _look_basis_at(origin: Vector3) -> Basis:
	return (
		_yaw_basis_at(origin) * Basis(Vector3.RIGHT, deg_to_rad(_pitch))
	).orthonormalized()


func _camera_transform(target_position: Vector3) -> Transform3D:
	var look_basis := _look_basis_at(target_position)
	var field_up := GravityField.resolve_up(self, target_position)
	# Foot: field up for head offset so look yaw is not mixed into the
	# interpolated body basis (that mix was the old voxel-ground jitter).
	# Seat: keep body-up when upright so suspension bounce matches look.
	var head_offset := field_up
	if _is_in_vehicle():
		var vehicle := _current_vehicle()
		var seat_xf: Transform3D
		if vehicle != null and vehicle.is_inside_tree():
			seat_xf = vehicle.get_global_transform_interpolated()
		elif _target != null and _target.is_inside_tree():
			seat_xf = _target.get_global_transform_interpolated()
		else:
			seat_xf = Transform3D.IDENTITY
		var body_up := seat_xf.basis.y.normalized()
		if body_up.dot(field_up) >= 0.35:
			head_offset = body_up
	var camera_position := target_position + head_offset * head_height
	return Transform3D(look_basis, camera_position)


func _orbit_camera_transform() -> Transform3D:
	var vehicle_xf := _vehicle_follow_transform()
	var up := GravityField.resolve_up(self, vehicle_xf.origin)
	var pivot := vehicle_xf.origin + up * orbit_height
	var yaw_basis := Basis(up, _orbit_yaw)
	# Positive orbit pitch raises the camera (look down at the vehicle).
	var pitch_basis := Basis(Vector3.RIGHT, -deg_to_rad(_orbit_pitch))
	var orbit_basis := yaw_basis * pitch_basis
	var desired := pivot + orbit_basis * Vector3(0.0, 0.0, orbit_distance)
	var camera_position := _spring_orbit_position(pivot, desired)
	var look_dir := pivot - camera_position
	if look_dir.length_squared() < 0.0001:
		return Transform3D(Basis.IDENTITY, camera_position)
	var look_up := up
	if absf(look_dir.normalized().dot(look_up)) > 0.99:
		look_up = GravityField.project_on_tangent(Vector3.RIGHT, up)
		if look_up.length_squared() < 0.0001:
			look_up = Vector3.RIGHT
		else:
			look_up = look_up.normalized()
	return Transform3D(Basis.looking_at(look_dir, look_up), camera_position)


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
	_capture_yaw_from_body()
	if _orbit_mode:
		global_transform = _orbit_camera_transform()
		reset_physics_interpolation()
		return
	var follow := _follow_origin()
	_last_target_position = follow
	global_transform = _camera_transform(follow)
	reset_physics_interpolation()


func _capture_yaw_from_body() -> void:
	if _target == null:
		return
	var up := GravityField.resolve_up(_target, _target.global_position)
	var forward := GravityField.project_on_tangent(
		-_target.global_transform.basis.z,
		up
	)
	if forward.length_squared() <= 0.0001:
		return
	var tangent := GravityField.find_in_tree(_target)
	var forward_ref := Vector3.FORWARD
	if tangent != null and tangent.mode == GravityField.Mode.RADIAL:
		forward_ref = GravityField.project_on_tangent(Vector3.FORWARD, up)
		if forward_ref.length_squared() <= 0.0001:
			forward_ref = GravityField.project_on_tangent(Vector3.RIGHT, up)
	else:
		forward_ref = Vector3.FORWARD
	if forward_ref.length_squared() <= 0.0001:
		return
	forward_ref = forward_ref.normalized()
	forward = forward.normalized()
	_yaw_rad = atan2(
		forward_ref.cross(forward).dot(up),
		forward_ref.dot(forward)
	)


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
	config.load(SETTINGS_PATH) # keep graphics / other sections
	config.set_value("look", "sensitivity", sensitivity)
	config.set_value("camera", "fov", fov)
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		push_warning("Could not save player settings: %s" % error_string(error))
