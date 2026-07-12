class_name CartLocomotion
extends RefCounted

var _body: RigidBody3D
var _anchors: Array[Marker3D] = []
var _wheel_active: Callable

@export var wheel_radius := 0.4
@export var rest_length := 0.6
@export var spring_stiffness := 1600.0
@export var spring_damping := 400.0
@export var drive_torque := 65.0
@export var brake_torque := 180.0
@export var longitudinal_grip := 1.2
@export var lateral_grip := 0.9
@export var slip_stiffness := 800.0
@export var lateral_stiffness := 1000.0
@export var wheel_inertia := 0.65
@export var max_steering_angle := 0.488692
@export var steering_response := 2.5

var _wheel_speeds: Array[float] = []
var _drive_command := 0.0
var _brake_command := 0.0
var _steering_command := 0.0
var _steering_angle := 0.0
var _slipping := false
var _lateral_slipping := false


func bind(
	body: RigidBody3D,
	anchors: Array[Marker3D],
	wheel_active: Callable
) -> void:
	_body = body
	_anchors = anchors
	_wheel_active = wheel_active
	_wheel_speeds.resize(_anchors.size())


func set_drive_command(throttle: float, brake: float) -> void:
	_drive_command = clampf(throttle, -1.0, 1.0)
	_brake_command = clampf(brake, 0.0, 1.0)


func set_steering_command(steering: float) -> void:
	_steering_command = clampf(steering, -1.0, 1.0)


func is_slipping() -> bool:
	return _slipping


func is_lateral_slipping() -> bool:
	return _lateral_slipping


func physics_step(delta: float) -> void:
	if _body == null:
		return
	var space: PhysicsDirectSpaceState3D = _body.get_world_3d().direct_space_state
	var down: Vector3 = -_body.global_transform.basis.y.normalized()
	var ray_length: float = rest_length + wheel_radius
	var center_of_mass_world: Vector3 = _body.to_global(_body.center_of_mass)
	var body_forward: Vector3 = -_body.global_transform.basis.z.normalized()
	_slipping = false
	_lateral_slipping = false
	_steering_angle = move_toward(
		_steering_angle,
		_steering_command * max_steering_angle,
		steering_response * delta
	)
	_anchors[0].rotation.y = _steering_angle
	_anchors[1].rotation.y = _steering_angle

	for wheel_index: int in _anchors.size():
		var anchor: Marker3D = _anchors[wheel_index]
		var wheel: MeshInstance3D = anchor.get_node("Wheel")
		if not bool(_wheel_active.call(wheel_index)):
			wheel.visible = false
			_integrate_free_wheel(wheel_index, delta)
			continue
		wheel.visible = true
		var origin: Vector3 = anchor.global_position
		var query: PhysicsRayQueryParameters3D = (
			PhysicsRayQueryParameters3D.create(
				origin,
				origin + down * ray_length
			)
		)
		query.exclude = [_body.get_rid()]
		query.collision_mask = 3
		query.collide_with_areas = false
		query.collide_with_bodies = true

		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			wheel.position.y = -rest_length
			_integrate_free_wheel(wheel_index, delta)
			wheel.rotate_object_local(
				Vector3.UP,
				_wheel_speeds[wheel_index] * delta
			)
			continue

		var hit_point: Vector3 = hit["position"]
		var hit_normal: Vector3 = Vector3(hit["normal"]).normalized()
		var distance: float = origin.distance_to(hit_point)
		var compression: float = ray_length - distance
		var point_velocity: Vector3 = (
			_body.linear_velocity
			+ _body.angular_velocity.cross(origin - center_of_mass_world)
		)
		var velocity_along_down: float = point_velocity.dot(down)
		var force_magnitude: float = maxf(
			spring_stiffness * compression
			+ spring_damping * velocity_along_down,
			0.0
		)
		var force: Vector3 = -down * force_magnitude
		_body.apply_force(force, origin - _body.global_position)

		var wheel_steering: float = (
			_steering_angle if wheel_index < 2 else 0.0
		)
		var steered_forward: Vector3 = body_forward.rotated(
			hit_normal,
			wheel_steering
		)
		var wheel_forward: Vector3 = (
			steered_forward
			- hit_normal * steered_forward.dot(hit_normal)
		)
		if wheel_forward.length_squared() > 0.0001:
			wheel_forward = wheel_forward.normalized()
			var wheel_right: Vector3 = (
				wheel_forward.cross(hit_normal).normalized()
			)
			var ground_speed: float = point_velocity.dot(wheel_forward)
			var lateral_speed: float = point_velocity.dot(wheel_right)
			var slip_speed: float = (
				_wheel_speeds[wheel_index] * wheel_radius
				- ground_speed
			)
			var desired_traction: float = slip_speed * slip_stiffness
			var desired_lateral: float = -lateral_speed * lateral_stiffness
			var longitudinal_limit: float = (
				force_magnitude * longitudinal_grip
			)
			var lateral_limit: float = force_magnitude * lateral_grip
			var traction_force: float = desired_traction
			var lateral_force: float = desired_lateral
			if longitudinal_limit > 0.0 and lateral_limit > 0.0:
				var friction_usage: float = sqrt(
					pow(desired_traction / longitudinal_limit, 2.0)
					+ pow(desired_lateral / lateral_limit, 2.0)
				)
				if friction_usage > 1.0:
					traction_force /= friction_usage
					lateral_force /= friction_usage
					_slipping = true
					if absf(desired_lateral) > 0.01:
						_lateral_slipping = true
			else:
				traction_force = 0.0
				lateral_force = 0.0

			_body.apply_force(
				wheel_forward * traction_force
				+ wheel_right * lateral_force,
				hit_point - _body.global_position
			)
			var wheel_torque: float = (
				_drive_command * drive_torque
				- traction_force * wheel_radius
			)
			_wheel_speeds[wheel_index] += (
				wheel_torque / wheel_inertia * delta
			)
			_apply_wheel_brake(wheel_index, delta)

		wheel.position.y = -(distance - wheel_radius)
		wheel.rotate_object_local(
			Vector3.UP,
			_wheel_speeds[wheel_index] * delta
		)


func _integrate_free_wheel(wheel_index: int, delta: float) -> void:
	_wheel_speeds[wheel_index] += (
		_drive_command * drive_torque / wheel_inertia * delta
	)
	_apply_wheel_brake(wheel_index, delta)


func _apply_wheel_brake(wheel_index: int, delta: float) -> void:
	var brake_step: float = (
		_brake_command * brake_torque / wheel_inertia * delta
	)
	_wheel_speeds[wheel_index] = move_toward(
		_wheel_speeds[wheel_index],
		0.0,
		brake_step
	)
