extends CharacterBody3D

@export var speed := 5.0
@export var sprint_multiplier := 1.5
@export var jump_velocity := 2.05
@export var gravity := 1.62
@export var ground_acceleration := 20.0
@export var ground_deceleration := 25.0
@export var air_acceleration := 3.0
@export var terminal_velocity := 40.0
@export var ground_adhesion := 0.5
@export var step_height := 0.3
@export var step_probe_margin := 0.01
@export_range(0.0, 89.0, 0.1) var max_floor_angle_degrees := 45.0
@export var support_frame_path: NodePath = NodePath("SupportFrame")

var _support_frame: Node
var _last_step_height := 0.0


func _ready() -> void:
	_support_frame = get_node_or_null(support_frame_path)
	up_direction = Vector3.UP
	floor_snap_length = step_height
	floor_max_angle = deg_to_rad(max_floor_angle_degrees)
	floor_stop_on_slope = true
	floor_constant_speed = true
	safe_margin = 0.001
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
	var current_horizontal := Vector2(velocity.x, velocity.z)
	var target_horizontal := Vector2(
		desired_horizontal.x,
		desired_horizontal.z
	)

	if was_on_floor:
		if jump_requested:
			velocity.y = jump_velocity
		else:
			velocity.y = -ground_adhesion
		var acceleration: float = (
			ground_acceleration
			if not target_horizontal.is_zero_approx()
			else ground_deceleration
		)
		current_horizontal = current_horizontal.move_toward(
			target_horizontal,
			acceleration * delta
		)
	else:
		velocity.y = maxf(
			velocity.y - gravity * delta,
			-terminal_velocity
		)
		if desired_direction.length_squared() > 0.0001:
			current_horizontal = current_horizontal.move_toward(
				target_horizontal,
				air_acceleration * delta
			)

	velocity.x = current_horizontal.x
	velocity.z = current_horizontal.y
	_last_step_height = 0.0
	var stepped := false
	if was_on_floor and not jump_requested:
		stepped = _try_step(
			Vector3(velocity.x, 0.0, velocity.z) * delta
		)
	var stepped_horizontal := Vector2(velocity.x, velocity.z)
	if stepped:
		velocity.x = 0.0
		velocity.z = 0.0
	move_and_slide()
	if stepped:
		velocity.x = stepped_horizontal.x
		velocity.z = stepped_horizontal.y
	if _support_frame != null:
		_support_frame.call("update_from_character", self)


func _try_step(horizontal_motion: Vector3) -> bool:
	if horizontal_motion.length_squared() < 0.000001:
		return false
	# move_and_slide applies platform displacement separately. Combining that
	# implicit motion with a manual stair correction can double-displace the
	# character or invalidate the swept path, so moving supports do not step.
	if get_platform_velocity().length_squared() > 0.000001:
		return false

	var from := global_transform
	var blocked_result := PhysicsTestMotionResult3D.new()
	if not _body_test_motion(from, horizontal_motion, blocked_result):
		return false

	var up_motion := Vector3.UP * (step_height + step_probe_margin)
	var up_result := PhysicsTestMotionResult3D.new()
	if _body_test_motion(from, up_motion, up_result):
		return false
	var raised := Transform3D(from.basis, from.origin + up_motion)

	var forward_result := PhysicsTestMotionResult3D.new()
	if _body_test_motion(raised, horizontal_motion, forward_result):
		return false
	var advanced := Transform3D(
		raised.basis,
		raised.origin + horizontal_motion
	)

	var down_motion := Vector3.DOWN * (
		step_height + floor_snap_length + step_probe_margin
	)
	var down_result := PhysicsTestMotionResult3D.new()
	if not _body_test_motion(advanced, down_motion, down_result):
		return false
	if down_result.get_collision_count() == 0:
		return false
	var floor_normal := down_result.get_collision_normal(0)
	if floor_normal.dot(up_direction) < cos(floor_max_angle):
		return false

	var landing_origin := advanced.origin + down_result.get_travel()
	var rise := landing_origin.y - from.origin.y
	if rise <= step_probe_margin or rise > step_height + step_probe_margin:
		return false

	# Execute the same swept path through PhysicsBody3D instead of assigning
	# global_transform. This preserves collision recovery if the world changes
	# between prediction and application.
	if move_and_collide(up_motion) != null:
		return false
	if move_and_collide(horizontal_motion) != null:
		move_and_collide(-up_motion)
		return false
	var down_collision := move_and_collide(down_motion)
	if down_collision == null:
		move_and_collide(-horizontal_motion)
		move_and_collide(-up_motion)
		return false
	_last_step_height = rise
	return true


func _body_test_motion(
	from: Transform3D,
	motion: Vector3,
	result: PhysicsTestMotionResult3D
) -> bool:
	var parameters := PhysicsTestMotionParameters3D.new()
	parameters.from = from
	parameters.motion = motion
	parameters.margin = safe_margin
	parameters.recovery_as_collision = false
	parameters.max_collisions = 4
	return PhysicsServer3D.body_test_motion(
		get_rid(),
		parameters,
		result
	)


func last_step_height() -> float:
	return _last_step_height


func support_carrier() -> RigidBody3D:
	if _support_frame == null:
		return null
	return _support_frame.call("carrier")


func support_point_velocity() -> Vector3:
	if _support_frame == null:
		return Vector3.ZERO
	return _support_frame.call(
		"point_velocity",
		global_position
	)


func clear_support_frame() -> void:
	if _support_frame != null:
		_support_frame.call("clear")
