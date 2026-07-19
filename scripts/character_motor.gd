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
@export var step_forward_min := 0.12
@export_range(0.0, 89.0, 0.1) var max_floor_angle_degrees := 45.0
@export var support_frame_path: NodePath = NodePath("SupportFrame")

var _support_frame: Node
var _last_step_height := 0.0
var _passive_step_height := 0.0


func _ready() -> void:
	# Explicit player identity for impact resolution and suit lookup — see
	# ImpactResolver.is_player_partner.
	add_to_group(ImpactResolver.PLAYER_GROUP)
	if not has_meta("player_id"):
		# Remote players get their uid stamped by the join code; a body that
		# nobody claimed is this machine's player.
		set_meta("player_id", PlayerIdentity.local_uid())
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
	var up := _resolve_up()
	up_direction = up
	_align_body_to_up(up)

	var desired_direction := GravityField.project_on_tangent(move_direction, up)
	if desired_direction.length_squared() > 1.0:
		desired_direction = desired_direction.normalized()
	var move_speed: float = (
		speed * sprint_multiplier if sprint else speed
	)
	var desired_horizontal: Vector3 = desired_direction * move_speed
	var was_on_floor: bool = is_on_floor()

	var vertical := velocity.dot(up)
	var horizontal := velocity - up * vertical

	if was_on_floor:
		if jump_requested:
			vertical = jump_velocity
		else:
			vertical = -ground_adhesion
		var acceleration: float = (
			ground_acceleration
			if not desired_horizontal.is_zero_approx()
			else ground_deceleration
		)
		horizontal = horizontal.move_toward(
			desired_horizontal,
			acceleration * delta
		)
	else:
		var gravity_accel := _resolve_gravity_accel(up)
		velocity += gravity_accel * delta
		vertical = velocity.dot(up)
		horizontal = velocity - up * vertical
		var fall_speed := -vertical
		if fall_speed > terminal_velocity:
			vertical = -terminal_velocity
		if desired_direction.length_squared() > 0.0001:
			horizontal = horizontal.move_toward(
				desired_horizontal,
				air_acceleration * delta
			)

	velocity = horizontal + up * vertical
	_last_step_height = 0.0
	var move_start := global_position
	var stepped := false
	if was_on_floor and not jump_requested:
		stepped = _try_step(horizontal * delta, up)
	var stepped_horizontal := horizontal
	if stepped:
		velocity = up * velocity.dot(up)
	move_and_slide()
	if stepped:
		var new_vertical := velocity.dot(up)
		velocity = stepped_horizontal + up * new_vertical
		_passive_step_height = 0.0
	elif was_on_floor and not jump_requested:
		var passive_rise := (global_position - move_start).dot(up)
		if passive_rise > 0.0001:
			_passive_step_height = minf(
				_passive_step_height + passive_rise,
				step_height
			)
			_last_step_height = _passive_step_height
		else:
			_passive_step_height = 0.0
	if _support_frame != null:
		_support_frame.call("update_from_character", self)


func _resolve_up() -> Vector3:
	return GravityField.resolve_up(self, global_position)


func _resolve_gravity_accel(up: Vector3) -> Vector3:
	# CharacterBody ignores Area3D gravity; with SPACE_OVERRIDE_REPLACE the
	# Area can zero space gravity in total_gravity. Prefer explicit Field.
	var field := GravityField.find_in_tree(self)
	if field != null:
		return field.gravity_accel_at(global_position)
	var direct := PhysicsServer3D.body_get_direct_state(get_rid())
	if direct != null:
		var total: Vector3 = direct.total_gravity
		if total.length_squared() > 0.000001:
			return total
	return -up * gravity


func _align_body_to_up(up: Vector3) -> void:
	if up.length_squared() <= 0.000001:
		return
	var current_up := global_transform.basis.y
	if current_up.normalized().dot(up) > 0.9995:
		return
	var forward := -global_transform.basis.z
	var projected := GravityField.project_on_tangent(forward, up)
	if projected.length_squared() <= 0.000001:
		projected = GravityField.project_on_tangent(
			global_transform.basis.x,
			up
		)
	if projected.length_squared() <= 0.000001:
		projected = GravityField.project_on_tangent(Vector3.FORWARD, up)
	if projected.length_squared() <= 0.000001:
		return
	global_transform.basis = Basis.looking_at(projected.normalized(), up)


func _try_step(horizontal_motion: Vector3, up: Vector3) -> bool:
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

	var up_motion := up * (step_height + step_probe_margin)
	var up_result := PhysicsTestMotionResult3D.new()
	if _body_test_motion(from, up_motion, up_result):
		return false
	var raised := Transform3D(from.basis, from.origin + up_motion)
	var forward_motion := (
		horizontal_motion.normalized()
		* maxf(horizontal_motion.length(), step_forward_min)
	)

	var forward_result := PhysicsTestMotionResult3D.new()
	if _body_test_motion(raised, forward_motion, forward_result):
		return false
	var advanced := Transform3D(
		raised.basis,
		raised.origin + forward_motion
	)

	var down_motion := -up * (
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
	var rise := (landing_origin - from.origin).dot(up)
	if rise <= step_probe_margin or rise > step_height + step_probe_margin:
		return false

	# Execute the same swept path through PhysicsBody3D instead of assigning
	# global_transform. This preserves collision recovery if the world changes
	# between prediction and application.
	if move_and_collide(up_motion) != null:
		return false
	if move_and_collide(forward_motion) != null:
		move_and_collide(-up_motion)
		return false
	var down_collision := move_and_collide(down_motion)
	if down_collision == null:
		move_and_collide(-forward_motion)
		move_and_collide(-up_motion)
		return false
	var contact_rise := (
		down_collision.get_position()
		- (from.origin - up * _collision_half_height())
	).dot(up)
	_last_step_height = maxf(rise, contact_rise)
	return true


func _collision_half_height() -> float:
	var collider := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collider == null or collider.shape == null:
		return 0.9
	if collider.shape is CapsuleShape3D:
		return (collider.shape as CapsuleShape3D).height * 0.5
	if collider.shape is CylinderShape3D:
		return (collider.shape as CylinderShape3D).height * 0.5
	return 0.9


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
