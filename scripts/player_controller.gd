extends "res://scripts/character_motor.gd"

@export var head_path: NodePath = NodePath("Camera")

var _head: Camera3D
var _gateway: Node
var _voxel_viewer: VoxelViewer
var _spawn_locked := true
var _spawn_settling := false
var _settled_frames := 0
var _world_parent: Node
var _gameplay_input_enabled := true
var _current_vehicle: Node3D

const SETTLED_FRAMES_NEEDED := 12


func set_spawn_locked(locked: bool) -> void:
	_spawn_locked = locked
	_spawn_settling = false
	_settled_frames = 0
	set_physics_process(not locked)
	if locked:
		velocity = Vector3.ZERO
		clear_support_frame()


func begin_spawn_settle(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	_spawn_locked = false
	_spawn_settling = true
	_settled_frames = 0
	set_physics_process(true)


func is_spawn_settled() -> bool:
	return not _spawn_locked and not _spawn_settling


func set_spawn_ready(pos: Vector3) -> void:
	global_position = pos
	_spawn_locked = false
	_spawn_settling = false
	_settled_frames = 0
	velocity = Vector3.ZERO
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


func _ready() -> void:
	super._ready()
	_head = get_node(head_path)
	_voxel_viewer = get_node_or_null("VoxelViewer") as VoxelViewer
	_world_parent = get_parent()
	set_physics_process(false)
	call_deferred("_cache_gateway")


func _cache_gateway() -> void:
	var gateway := get_tree().get_first_node_in_group(
		&"world_command_gateway"
	)
	if gateway != null and gateway.has_method("tick_rover_locomotion_input"):
		_gateway = gateway


func _process(_delta: float) -> void:
	if _voxel_viewer != null and _current_vehicle != null:
		_voxel_viewer.global_position = global_position
	if (
		_current_vehicle != null
		and _gateway != null
		and _gateway.has_method("tick_rover_locomotion_input")
	):
		_gateway.call("tick_rover_locomotion_input")


func enter_vehicle(vehicle: Node3D, seat_position: Vector3) -> void:
	if vehicle == null or not is_instance_valid(vehicle):
		return
	_current_vehicle = vehicle
	set_physics_process(false)
	velocity = Vector3.ZERO
	clear_support_frame()
	$CollisionShape3D.set_deferred("disabled", true)
	_detach_voxel_viewer()
	reparent(vehicle, false)
	position = seat_position
	rotation = Vector3.ZERO
	$Drill.set_physics_process(false)
	$Camera/DrillVisual.visible = false
	if _voxel_viewer != null:
		_voxel_viewer.global_position = global_position


func exit_vehicle(world_position: Vector3) -> void:
	_reattach_voxel_viewer()
	reparent(_world_parent, true)
	global_position = world_position
	_current_vehicle = null
	rotation = Vector3.ZERO
	velocity = Vector3.ZERO
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

	var movement_basis: Basis = _head.call("movement_basis")
	var forward := -movement_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := movement_basis.x
	right.y = 0.0
	right = right.normalized()

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
