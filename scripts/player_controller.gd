extends "res://scripts/character_motor.gd"

@export var head_path: NodePath = NodePath("Camera")

var _head: Camera3D
var _spawn_locked := true
var _spawn_settling := false
var _settled_frames := 0
var _world_parent: Node

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


func _ready() -> void:
	super._ready()
	_head = get_node(head_path)
	_world_parent = get_parent()
	set_physics_process(false)


func enter_vehicle(vehicle: Node3D, seat_position: Vector3) -> void:
	set_physics_process(false)
	velocity = Vector3.ZERO
	clear_support_frame()
	$CollisionShape3D.set_deferred("disabled", true)
	reparent(vehicle, false)
	position = seat_position
	rotation = Vector3.ZERO
	$Drill.set_physics_process(false)
	$BlockPlacer.set_physics_process(false)
	$Camera/DrillVisual.visible = false


func exit_vehicle(world_position: Vector3) -> void:
	reparent(_world_parent, true)
	global_position = world_position
	rotation = Vector3.ZERO
	velocity = Vector3.ZERO
	$CollisionShape3D.set_deferred("disabled", false)
	$Drill.set_physics_process(true)
	$BlockPlacer.set_physics_process(true)
	$Camera/DrillVisual.visible = true
	set_physics_process(true)


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

	var forward := -_head.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := _head.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()

	var move: Vector3 = Vector3.ZERO
	if Input.is_action_pressed("move_forward"):
		move += forward
	if Input.is_action_pressed("move_back"):
		move -= forward
	if Input.is_action_pressed("move_left"):
		move -= right
	if Input.is_action_pressed("move_right"):
		move += right

	move_character(
		move,
		Input.is_key_pressed(KEY_SHIFT),
		Input.is_action_just_pressed("jump"),
		delta
	)
