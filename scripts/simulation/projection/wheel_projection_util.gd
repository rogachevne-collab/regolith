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
	var result := {
		"grounded": false,
		"compression_m": 0.0,
		"wheel_speed": float(pair.get("wheel_speed", 0.0)),
		"steering_angle_rad": float(pair.get("steering_angle_rad", 0.0)),
	}
	if body == null or delta <= 0.0 or pair.is_empty():
		return result
	var suspension: SimulationElement = pair.get("suspension_element")
	var wheel_element: SimulationElement = pair.get("wheel_element")
	if suspension == null or wheel_element == null:
		return result

	var travel_m := float(pair.get("travel_m", 0.6))
	var radius_m := float(pair.get("radius_m", 0.4))
	var spring_stiffness := float(pair.get("spring_stiffness", 1600.0))
	var spring_damping := float(pair.get("spring_damping", 400.0))
	var drive_torque := float(pair.get("drive_torque", 65.0))
	var brake_torque := float(pair.get("brake_torque", 180.0))
	var longitudinal_grip := float(pair.get("longitudinal_grip", 1.2))
	var lateral_grip := float(pair.get("lateral_grip", 0.9))
	var slip_stiffness := float(pair.get("slip_stiffness", 800.0))
	var lateral_stiffness := float(pair.get("lateral_stiffness", 1000.0))
	var wheel_inertia := float(pair.get("wheel_inertia", 0.65))
	var max_steering_angle := float(pair.get("max_steering_angle_rad", 0.4887))
	var steering_response := float(pair.get("steering_response", 2.5))
	var steerable := bool(pair.get("steerable", false))

	var wheel_speed := float(pair.get("wheel_speed", 0.0))
	var steering_angle := float(pair.get("steering_angle_rad", 0.0))
	var drive_scale := float(pair.get("drive_torque_scale", 1.0))
	if pair.has("configured_brake_torque"):
		brake_torque = float(pair["configured_brake_torque"])

	var socket_pose := mount_pad_anchor_assembly_local(
		suspension,
		"wheel_socket"
	)
	if socket_pose.is_empty():
		return result
	var ray_origin_local: Vector3 = socket_pose["origin"]
	var ray_dir_local: Vector3 = socket_pose["direction"]
	var assembly_transform := body.global_transform
	var ray_origin_world := assembly_transform * ray_origin_local
	var ray_dir_world := assembly_transform.basis * ray_dir_local
	var ray_length := travel_m + radius_m

	var space := body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin_world,
		ray_origin_world + ray_dir_world * ray_length
	)
	query.exclude = [body.get_rid()]
	query.collision_mask = RAYCAST_MASK
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var hit: Dictionary = space.intersect_ray(query)
	var body_forward := -assembly_transform.basis.z.normalized()

	var target_steering := 0.0
	if steerable and locomotion != null:
		target_steering = locomotion.steering_command * max_steering_angle
	steering_angle = move_toward(
		steering_angle,
		target_steering,
		steering_response * delta
	)

	var drive_command := 0.0
	var brake_command := 0.0
	if locomotion != null:
		drive_command = locomotion.drive_command
		brake_command = locomotion.brake_command
	if not powered:
		drive_command = 0.0

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
		result["wheel_speed"] = wheel_speed
		result["steering_angle_rad"] = steering_angle
		return result

	result["grounded"] = true
	var hit_point: Vector3 = hit["position"]
	var hit_normal: Vector3 = Vector3(hit["normal"]).normalized()
	var distance := ray_origin_world.distance_to(hit_point)
	var compression := ray_length - distance
	result["compression_m"] = maxf(compression, 0.0)

	var suspension_offset_world := ray_origin_world - assembly_transform.origin
	var point_velocity := (
		body.linear_velocity
		+ body.angular_velocity.cross(suspension_offset_world)
	)
	var velocity_along_ray := point_velocity.dot(ray_dir_world)
	var force_magnitude := maxf(
		spring_stiffness * compression + spring_damping * velocity_along_ray,
		0.0
	)
	var spring_force := -ray_dir_world * force_magnitude
	body.apply_force(spring_force, suspension_offset_world)

	var steered_forward := body_forward.rotated(hit_normal, steering_angle)
	var wheel_forward := (
		steered_forward - hit_normal * steered_forward.dot(hit_normal)
	)
	if wheel_forward.length_squared() > 0.0001:
		wheel_forward = wheel_forward.normalized()
		var wheel_right := wheel_forward.cross(hit_normal).normalized()
		var ground_speed := point_velocity.dot(wheel_forward)
		var lateral_speed := point_velocity.dot(wheel_right)
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

		var contact_offset_world := hit_point - assembly_transform.origin
		body.apply_force(
			wheel_forward * traction_force + wheel_right * lateral_force,
			contact_offset_world
		)
		var wheel_torque := (
			drive_command * drive_torque * drive_scale
			- traction_force * radius_m
		)
		wheel_speed += wheel_torque / wheel_inertia * delta
		wheel_speed = _apply_wheel_brake(
			wheel_speed,
			brake_command,
			brake_torque,
			wheel_inertia,
			delta
		)

	result["wheel_speed"] = wheel_speed
	result["steering_angle_rad"] = steering_angle
	return result


static func _apply_wheel_brake(
	wheel_speed: float,
	brake_command: float,
	brake_torque: float,
	wheel_inertia: float,
	delta: float
) -> float:
	var brake_step := brake_command * brake_torque / wheel_inertia * delta
	return move_toward(wheel_speed, 0.0, brake_step)
