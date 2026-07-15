class_name WheelProjectionUtil
extends RefCounted

const RAYCAST_MASK := 3


static func mount_pad_anchor_assembly_local(
	element: SimulationElement,
	socket_tag: String
) -> Dictionary:
	if element == null:
		return {}
	var archetype := element.get_archetype()
	if archetype == null:
		return {}
	for pad: StructuralMountPad in archetype.structural_mount_pads:
		if pad == null or pad.socket_tag != socket_tag:
			continue
		var face_vec: Vector3i = OrientationUtil.rotate_direction(
			OrientationUtil.face_to_vector(pad.local_face),
			element.orientation_index
		)
		var world_cell: Vector3i = (
			element.origin_cell
			+ OrientationUtil.rotate_cell(
				pad.local_cell,
				element.orientation_index
			)
		)
		var origin := (
			GridMetric.cell_center_meters(world_cell)
			+ Vector3(face_vec) * GridMetric.HALF_CELL_SIZE_M
		)
		return {
			"origin": origin,
			"direction": Vector3(face_vec).normalized(),
		}
	return {}


static func tick_pair(
	body: RigidBody3D,
	pair: Dictionary,
	locomotion: AssemblyLocomotionController,
	delta: float,
	powered: bool
) -> Dictionary:
	var result := empty_result(pair, powered)
	if body == null or delta <= 0.0 or pair.is_empty():
		result["status"] = &"invalid_body"
		return result
	var suspension: SimulationElement = pair.get("suspension_element")
	var wheel_element: SimulationElement = pair.get("wheel_element")
	if suspension == null or wheel_element == null:
		result["status"] = &"invalid_body"
		return result

	var travel_m := float(pair.get("travel_m", 0.6))
	var radius_m := float(pair.get("radius_m", 0.4))
	var spring_stiffness := float(pair.get("spring_stiffness", 1600.0))
	var spring_damping := float(pair.get("spring_damping", 400.0))
	var max_suspension_force := maxf(
		float(pair.get("max_suspension_force_n", 5000.0)),
		0.0
	)
	var drive_torque := float(pair.get("drive_torque", 65.0))
	var brake_torque := float(pair.get("brake_torque", 180.0))
	var longitudinal_grip := float(pair.get("longitudinal_grip", 1.2))
	var lateral_grip := float(pair.get("lateral_grip", 0.9))
	var slip_stiffness := float(pair.get("slip_stiffness", 800.0))
	var lateral_stiffness := float(pair.get("lateral_stiffness", 1000.0))
	var wheel_inertia := maxf(float(pair.get("wheel_inertia", 0.65)), 0.0001)
	var angular_damping := maxf(float(pair.get("angular_damping", 0.2)), 0.0)
	var max_angular_speed := maxf(
		float(pair.get("max_angular_speed_rad_s", 150.0)),
		0.001
	)
	var max_steering_angle := float(
		pair.get("max_steering_angle_rad", 0.4887)
	)
	var steering_response := float(pair.get("steering_response", 2.5))
	var steerable := bool(pair.get("steerable", false))

	var wheel_speed := float(result["wheel_speed"])
	var steering_angle := float(result["steering_angle_rad"])
	var drive_scale := float(pair.get("drive_torque_scale", 1.0))
	if pair.has("configured_brake_torque"):
		brake_torque = float(pair["configured_brake_torque"])

	var socket_pose := mount_pad_anchor_assembly_local(
		suspension,
		"wheel_socket"
	)
	if socket_pose.is_empty():
		result["status"] = &"invalid_body"
		return result
	var ray_origin_local: Vector3 = socket_pose["origin"]
	var ray_dir_local := Vector3(socket_pose["direction"]).normalized()
	if ray_dir_local.length_squared() <= 0.0001:
		result["status"] = &"invalid_body"
		return result
	var body_transform := body.global_transform
	var ray_origin_world := body_transform * ray_origin_local
	var ray_dir_world := (
		body_transform.basis * ray_dir_local
	).normalized()
	var ray_length := travel_m + radius_m
	result["socket_body_local"] = body.to_local(ray_origin_world)
	result["suspension_length_m"] = travel_m
	result["wheel_center_body_local"] = body.to_local(
		ray_origin_world + ray_dir_world * travel_m
	)

	var target_steering := 0.0
	if steerable and locomotion != null:
		target_steering = locomotion.steering_command * max_steering_angle
	steering_angle = move_toward(
		steering_angle,
		target_steering,
		steering_response * delta
	)
	result["steering_angle_rad"] = steering_angle

	var drive_command := 0.0
	var brake_command := 0.0
	if locomotion != null:
		drive_command = locomotion.drive_command
		brake_command = locomotion.brake_command
	result["drive_command"] = drive_command
	result["brake_command"] = brake_command
	if not powered:
		drive_command = 0.0
		result["status"] = &"no_power"

	var space := body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin_world,
		ray_origin_world + ray_dir_world * ray_length
	)
	var exclude: Array[RID] = []
	for rid_variant: Variant in pair.get("exclude_rids", []):
		if rid_variant is RID:
			exclude.append(rid_variant)
	if not exclude.has(body.get_rid()):
		exclude.append(body.get_rid())
	query.exclude = exclude
	query.collision_mask = RAYCAST_MASK
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit: Dictionary = space.intersect_ray(query)

	if hit.is_empty():
		wheel_speed += (
			drive_command * drive_torque * drive_scale / wheel_inertia * delta
		)
		wheel_speed = _apply_wheel_brake(
			wheel_speed,
			brake_command,
			brake_torque,
			wheel_inertia,
			delta
		)
		result["wheel_speed"] = _stabilize_wheel_speed(
			wheel_speed,
			angular_damping,
			max_angular_speed,
			delta
		)
		result["wheel_speed_rad_s"] = result["wheel_speed"]
		return result

	result["grounded"] = true
	result["status"] = &"ok" if powered else &"no_power"
	var hit_point: Vector3 = hit["position"]
	var hit_normal := Vector3(hit["normal"]).normalized()
	var distance := ray_origin_world.distance_to(hit_point)
	var suspension_length := clampf(distance - radius_m, 0.0, travel_m)
	var compression := travel_m - suspension_length
	var wheel_center_world := (
		ray_origin_world + ray_dir_world * suspension_length
	)
	result["suspension_length_m"] = suspension_length
	result["compression_m"] = compression
	result["wheel_center_body_local"] = body.to_local(wheel_center_world)
	result["contact_world"] = hit_point
	result["contact_normal_world"] = hit_normal

	var collider: Variant = hit.get("collider")
	var ground_velocity := _collider_velocity_at_point(collider, hit_point)
	var suspension_velocity := (
		velocity_at_world_point(body, ray_origin_world) - ground_velocity
	)
	var velocity_along_ray := suspension_velocity.dot(ray_dir_world)
	var force_magnitude := clampf(
		spring_stiffness * compression + spring_damping * velocity_along_ray,
		0.0,
		max_suspension_force
	)
	var spring_force := -ray_dir_world * force_magnitude
	body.apply_force(
		spring_force,
		ray_origin_world - body_transform.origin
	)
	_apply_reaction_force(collider, -spring_force, hit_point)
	result["normal_force_n"] = force_magnitude

	var forward_axis_local: Vector3 = pair.get(
		"forward_axis_local",
		Vector3.FORWARD
	)
	var neutral_forward := (
		body_transform.basis * forward_axis_local
	).normalized()
	var steered_forward := neutral_forward.rotated(
		hit_normal,
		steering_angle
	)
	var wheel_forward := (
		steered_forward - hit_normal * steered_forward.dot(hit_normal)
	)
	if wheel_forward.length_squared() > 0.0001:
		wheel_forward = wheel_forward.normalized()
		var wheel_right := wheel_forward.cross(hit_normal).normalized()
		var contact_velocity := (
			velocity_at_world_point(body, hit_point) - ground_velocity
		)
		var ground_speed := contact_velocity.dot(wheel_forward)
		var lateral_speed := contact_velocity.dot(wheel_right)
		var slip_speed := wheel_speed * radius_m - ground_speed
		var desired_traction := slip_speed * slip_stiffness
		var desired_lateral := -lateral_speed * lateral_stiffness
		var longitudinal_limit := force_magnitude * longitudinal_grip
		var lateral_limit := force_magnitude * lateral_grip
		var traction_force := desired_traction
		var lateral_force := desired_lateral
		if longitudinal_limit > 0.0 and lateral_limit > 0.0:
			var friction_usage := sqrt(
				pow(desired_traction / longitudinal_limit, 2.0)
				+ pow(desired_lateral / lateral_limit, 2.0)
			)
			if friction_usage > 1.0:
				traction_force /= friction_usage
				lateral_force /= friction_usage
		else:
			traction_force = 0.0
			lateral_force = 0.0

		var tire_force := (
			wheel_forward * traction_force + wheel_right * lateral_force
		)
		body.apply_force(
			tire_force,
			hit_point - body_transform.origin
		)
		_apply_reaction_force(collider, -tire_force, hit_point)
		var wheel_torque := (
			drive_command * drive_torque * drive_scale
			- traction_force * radius_m
		)
		wheel_speed += wheel_torque / wheel_inertia * delta
		result["longitudinal_force_n"] = traction_force
		result["lateral_force_n"] = lateral_force
		result["slip_speed_mps"] = slip_speed
		result["lateral_speed_mps"] = lateral_speed

	wheel_speed = _apply_wheel_brake(
		wheel_speed,
		brake_command,
		brake_torque,
		wheel_inertia,
		delta
	)
	result["wheel_speed"] = _stabilize_wheel_speed(
		wheel_speed,
		angular_damping,
		max_angular_speed,
		delta
	)
	result["wheel_speed_rad_s"] = result["wheel_speed"]
	return result


static func empty_result(
	pair: Dictionary,
	powered: bool,
	status: StringName = &"airborne"
) -> Dictionary:
	return {
		"status": status,
		"powered": powered,
		"grounded": false,
		"compression_m": 0.0,
		"suspension_length_m": float(pair.get("travel_m", 0.6)),
		"wheel_speed": float(pair.get("wheel_speed", 0.0)),
		"wheel_speed_rad_s": float(pair.get("wheel_speed", 0.0)),
		"steering_angle_rad": float(pair.get("steering_angle_rad", 0.0)),
		"socket_body_local": Vector3.ZERO,
		"wheel_center_body_local": Vector3.ZERO,
		"contact_world": Vector3.ZERO,
		"contact_normal_world": Vector3.ZERO,
		"normal_force_n": 0.0,
		"longitudinal_force_n": 0.0,
		"lateral_force_n": 0.0,
		"slip_speed_mps": 0.0,
		"lateral_speed_mps": 0.0,
		"drive_command": 0.0,
		"brake_command": 0.0,
		"body_group_id": 0,
	}


static func velocity_at_world_point(
	body: RigidBody3D,
	world_point: Vector3
) -> Vector3:
	if body == null:
		return Vector3.ZERO
	var center_of_mass_world := body.to_global(body.center_of_mass)
	return (
		body.linear_velocity
		+ body.angular_velocity.cross(world_point - center_of_mass_world)
	)


static func _collider_velocity_at_point(
	collider: Variant,
	world_point: Vector3
) -> Vector3:
	if collider is RigidBody3D:
		return velocity_at_world_point(collider as RigidBody3D, world_point)
	return Vector3.ZERO


static func _apply_reaction_force(
	collider: Variant,
	force: Vector3,
	world_point: Vector3
) -> void:
	if not collider is RigidBody3D:
		return
	var rigid := collider as RigidBody3D
	rigid.apply_force(force, world_point - rigid.global_position)


static func _stabilize_wheel_speed(
	wheel_speed: float,
	angular_damping: float,
	max_angular_speed: float,
	delta: float
) -> float:
	var damping_factor := exp(-angular_damping * delta)
	return clampf(
		wheel_speed * damping_factor,
		-max_angular_speed,
		max_angular_speed
	)


static func _apply_wheel_brake(
	wheel_speed: float,
	brake_command: float,
	brake_torque: float,
	wheel_inertia: float,
	delta: float
) -> float:
	var brake_step := brake_command * brake_torque / wheel_inertia * delta
	return move_toward(wheel_speed, 0.0, brake_step)
