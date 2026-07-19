extends "res://scripts/character_motor.gd"

@export var head_path: NodePath = NodePath("Camera")
@export var fly_speed := 18.0
@export var fly_sprint_multiplier := 3.0

var _head: Camera3D
var _voxel_viewer: VoxelViewer
var _spawn_locked := true
var _spawn_settling := false
var _settled_frames := 0
var _world_parent: Node
var _gameplay_input_enabled := true
var _current_vehicle: Node3D
## When true, mouse steers the assembly (SE cockpit) instead of freelook.
var _vehicle_flight_controls := false
## Debug freefly / noclip (toggle_fly — X). No gravity, camera-relative move.
var _fly_mode := false

const SETTLED_FRAMES_NEEDED := 12


func set_spawn_locked(locked: bool) -> void:
	_spawn_locked = locked
	_spawn_settling = false
	_settled_frames = 0
	set_physics_process(not locked)
	if locked:
		set_fly_mode(false)
		velocity = Vector3.ZERO
		clear_support_frame()


func begin_spawn_settle(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	reset_physics_interpolation()
	_spawn_locked = false
	_spawn_settling = true
	_settled_frames = 0
	set_physics_process(true)


func is_spawn_settled() -> bool:
	return not _spawn_locked and not _spawn_settling


func set_spawn_ready(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	reset_physics_interpolation()
	_spawn_locked = false
	_spawn_settling = false
	_settled_frames = 0
	set_physics_process(true)


func is_spawn_ready() -> bool:
	return not _spawn_locked and not _spawn_settling


func is_grounded() -> bool:
	return is_on_floor()


func set_gameplay_input_enabled(enabled: bool) -> void:
	_gameplay_input_enabled = enabled


func is_gameplay_input_enabled() -> bool:
	return _gameplay_input_enabled


func is_in_vehicle() -> bool:
	return _current_vehicle != null


func current_vehicle() -> Node3D:
	return _current_vehicle


func set_vehicle_flight_controls(enabled: bool) -> void:
	_vehicle_flight_controls = enabled
	if not enabled and _head != null and _head.has_method("consume_flight_look_delta"):
		_head.call("consume_flight_look_delta")


func is_vehicle_flight_controls() -> bool:
	return _vehicle_flight_controls and _current_vehicle != null


func is_fly_mode() -> bool:
	return _fly_mode


func set_fly_mode(enabled: bool) -> void:
	if _fly_mode == enabled:
		return
	_fly_mode = enabled
	velocity = Vector3.ZERO
	clear_support_frame()
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null:
		col.set_deferred("disabled", enabled)
	if enabled:
		print("Player: fly mode ON (X to exit; WASD + Space/C, Shift boost)")
	else:
		print("Player: fly mode OFF")


func _ready() -> void:
	super._ready()
	_head = get_node(head_path)
	_voxel_viewer = get_node_or_null("VoxelViewer") as VoxelViewer
	_world_parent = get_parent()
	## Foot mode: interpolation OFF — yaw/basis mix on voxel ground.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	reset_physics_interpolation()
	set_physics_process(false)


func _process(_delta: float) -> void:
	if _voxel_viewer != null and _current_vehicle != null:
		_voxel_viewer.global_position = global_position


func enter_vehicle(vehicle: Node3D, seat_position: Vector3) -> void:
	if vehicle == null or not is_instance_valid(vehicle):
		return
	set_fly_mode(false)
	_current_vehicle = vehicle
	set_physics_process(false)
	velocity = Vector3.ZERO
	clear_support_frame()
	$CollisionShape3D.set_deferred("disabled", true)
	_detach_voxel_viewer()
	reparent(vehicle, false)
	position = seat_position
	rotation = Vector3.ZERO
	# Seated child of RigidBody must interpolate or the top-level camera
	# judders at physics rate while the world renders at display rate.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	reset_physics_interpolation()
	$Drill.set_physics_process(false)
	$Camera/DrillVisual.visible = false
	if _voxel_viewer != null:
		_voxel_viewer.global_position = global_position


func exit_vehicle(world_position: Vector3) -> void:
	_reattach_voxel_viewer()
	reparent(_world_parent, true)
	global_position = world_position
	_current_vehicle = null
	_vehicle_flight_controls = false
	rotation = Vector3.ZERO
	velocity = Vector3.ZERO
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	reset_physics_interpolation()
	$CollisionShape3D.set_deferred("disabled", false)
	$Drill.set_physics_process(true)
	$Camera/DrillVisual.visible = true
	set_physics_process(true)


func _detach_voxel_viewer() -> void:
	if _voxel_viewer == null or _world_parent == null:
		return
	if _voxel_viewer.get_parent() == self:
		_voxel_viewer.reparent(_world_parent, true)


func _reattach_voxel_viewer() -> void:
	if _voxel_viewer == null:
		return
	if _voxel_viewer.get_parent() != self:
		_voxel_viewer.reparent(self, true)


func _physics_process(delta: float) -> void:
	if _spawn_settling:
		move_character(Vector3.ZERO, false, false, delta)
		if is_on_floor():
			_settled_frames += 1
		else:
			_settled_frames = 0
		if _settled_frames >= SETTLED_FRAMES_NEEDED:
			_spawn_settling = false
			velocity = Vector3.ZERO
		return

	if _spawn_locked:
		return

	if (
		_gameplay_input_enabled
		and not is_in_vehicle()
		and Input.is_action_just_pressed(&"toggle_fly")
	):
		set_fly_mode(not _fly_mode)

	if _fly_mode:
		_fly_move(delta)
		return

	var movement_basis: Basis = _head.call("movement_basis")
	var up := up_direction
	var forward := GravityField.project_on_tangent(-movement_basis.z, up)
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	else:
		forward = Vector3.ZERO
	var right := GravityField.project_on_tangent(movement_basis.x, up)
	if right.length_squared() > 0.0001:
		right = right.normalized()
	else:
		right = Vector3.ZERO

	var move: Vector3 = Vector3.ZERO
	if _gameplay_input_enabled and Input.is_action_pressed("move_forward"):
		move += forward
	if _gameplay_input_enabled and Input.is_action_pressed("move_back"):
		move -= forward
	if _gameplay_input_enabled and Input.is_action_pressed("move_left"):
		move -= right
	if _gameplay_input_enabled and Input.is_action_pressed("move_right"):
		move += right

	move_character(
		move,
		_gameplay_input_enabled and Input.is_action_pressed("sprint"),
		_gameplay_input_enabled and Input.is_action_just_pressed("jump"),
		delta
	)


func _fly_move(delta: float) -> void:
	if _head == null:
		return
	var basis: Basis = _head.global_transform.basis
	var wish := Vector3.ZERO
	if _gameplay_input_enabled:
		if Input.is_action_pressed(&"move_forward"):
			wish -= basis.z
		if Input.is_action_pressed(&"move_back"):
			wish += basis.z
		if Input.is_action_pressed(&"move_left"):
			wish -= basis.x
		if Input.is_action_pressed(&"move_right"):
			wish += basis.x
		if Input.is_action_pressed(&"move_up") or Input.is_action_pressed(&"jump"):
			wish += basis.y
		if Input.is_action_pressed(&"move_down"):
			wish -= basis.y
	if wish.length_squared() > 0.0001:
		wish = wish.normalized()
	var speed := fly_speed
	if _gameplay_input_enabled and Input.is_action_pressed(&"sprint"):
		speed *= fly_sprint_multiplier
	global_position += wish * speed * delta
	velocity = wish * speed
	# Keep character upright for camera parent; look stays on Camera node.
	var up := _resolve_up()
	_align_body_to_up(up)
