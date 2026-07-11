extends CharacterBody3D

@export var speed := 8.0
@export var sprint_multiplier := 1.6
@export var jump_velocity := 8.5
@export var gravity := 22.0
@export var air_control := 12.0
@export var support_frame_path: NodePath = NodePath("SupportFrame")

var _support_frame: Node


func _ready() -> void:
	_support_frame = get_node(support_frame_path)
	up_direction = Vector3.UP
	floor_snap_length = 0.4
	floor_max_angle = deg_to_rad(60.0)
	floor_stop_on_slope = true
	platform_floor_layers = 2
	platform_on_leave = (
		CharacterBody3D.PLATFORM_ON_LEAVE_ADD_VELOCITY
	)


func move_character(
	move_direction: Vector3,
	sprint: bool,
	jump_requested: bool,
	delta: float
) -> void:
	var desired_direction: Vector3 = move_direction
	desired_direction.y = 0.0
	if desired_direction.length_squared() > 1.0:
		desired_direction = desired_direction.normalized()
	var move_speed: float = (
		speed * sprint_multiplier if sprint else speed
	)
	var desired_horizontal: Vector3 = (
		desired_direction * move_speed
	)
	var was_on_floor: bool = is_on_floor()

	if was_on_floor:
		velocity.x = desired_horizontal.x
		velocity.z = desired_horizontal.z
		if jump_requested:
			velocity.y = jump_velocity
		else:
			velocity.y = -0.1
	else:
		velocity.y = maxf(velocity.y - gravity * delta, -40.0)
		if desired_direction.length_squared() > 0.0001:
			velocity.x = move_toward(
				velocity.x,
				desired_horizontal.x,
				air_control * delta
			)
			velocity.z = move_toward(
				velocity.z,
				desired_horizontal.z,
				air_control * delta
			)

	move_and_slide()
	_support_frame.call("update_from_character", self)


func support_carrier() -> RigidBody3D:
	return _support_frame.call("carrier")


func support_point_velocity() -> Vector3:
	return _support_frame.call(
		"point_velocity",
		global_position
	)


func clear_support_frame() -> void:
	_support_frame.call("clear")
