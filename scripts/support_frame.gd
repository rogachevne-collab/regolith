extends Node

var _carrier: RigidBody3D


func update_from_character(character: CharacterBody3D) -> void:
	if not character.is_on_floor():
		_carrier = null
		return

	var found_carrier: RigidBody3D
	for collision_index: int in character.get_slide_collision_count():
		var collision: KinematicCollision3D = (
			character.get_slide_collision(collision_index)
		)
		if collision.get_normal().dot(Vector3.UP) < 0.4:
			continue
		var collider: Object = collision.get_collider()
		if collider is RigidBody3D:
			found_carrier = collider
			break

	if found_carrier == null:
		found_carrier = _probe_floor_carrier(character)
	_carrier = found_carrier


func clear() -> void:
	_carrier = null


func carrier() -> RigidBody3D:
	if not is_instance_valid(_carrier):
		return null
	return _carrier


func point_velocity(world_point: Vector3) -> Vector3:
	var body: RigidBody3D = carrier()
	if body == null:
		return Vector3.ZERO
	var center_of_mass_world: Vector3 = body.to_global(
		body.center_of_mass
	)
	return (
		body.linear_velocity
		+ body.angular_velocity.cross(
			world_point - center_of_mass_world
		)
	)


func _probe_floor_carrier(
	character: CharacterBody3D
) -> RigidBody3D:
	var space: PhysicsDirectSpaceState3D = (
		character.get_world_3d().direct_space_state
	)
	var origin: Vector3 = character.global_position
	var query: PhysicsRayQueryParameters3D = (
		PhysicsRayQueryParameters3D.create(
			origin,
			origin + Vector3.DOWN * 1.15
		)
	)
	query.exclude = [character.get_rid()]
	query.collision_mask = 3
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	var collider: Object = hit["collider"]
	if collider is RigidBody3D:
		return collider
	return null
