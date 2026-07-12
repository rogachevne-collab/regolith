class_name SimulationPhysicsProjection
extends Node3D

const BODY_NAME_PREFIX := "AssemblyBody_"
const MIN_MASS := 0.001
const FragmentBodyScript := preload(
	"res://scripts/simulation/projection/projected_assembly_body.gd"
)

var _world: SimulationWorld
var _bodies: Dictionary = {}
var _element_records: Dictionary = {}
var _projected_revision: Dictionary = {}
var _mounted_bodies: Dictionary = {}
var _collision_profiles: Dictionary = {}
var _body_groups: Dictionary = {}


func bind_world(world: SimulationWorld) -> void:
	if _world == world:
		return
	unbind_world()
	_world = world
	if _world != null:
		_world.structural_event.connect(_on_structural_event)
		rebuild_all()


func unbind_world() -> void:
	if (
		_world != null
		and _world.structural_event.is_connected(_on_structural_event)
	):
		_world.structural_event.disconnect(_on_structural_event)
	_world = null


func rebuild_all() -> void:
	_clear_all_bodies()
	if _world == null:
		return
	for assembly: SimulationAssembly in _world.list_assemblies():
		if not assembly.tombstoned:
			_project_assembly(assembly.assembly_id, null)


func get_physics_body(assembly_id: int) -> PhysicsBody3D:
	return _bodies.get(assembly_id) as PhysicsBody3D


func get_element_projection(element_id: int) -> Dictionary:
	var record: Variant = _element_records.get(element_id)
	if record is Dictionary:
		return record
	return {}


func get_element_colliders(
	element_id: int
) -> Array[CollisionShape3D]:
	var result: Array[CollisionShape3D] = []
	var record: Dictionary = get_element_projection(element_id)
	for collider: CollisionShape3D in record.get("colliders", []):
		result.append(collider)
	return result


func compute_b_to_a_grid(
	assembly_a_id: int,
	assembly_b_id: int
) -> GridTransform:
	return SimulationMergeGateway.compute_b_to_a_grid(
		_world,
		assembly_a_id,
		assembly_b_id
	)


func register_mounted_body(
	assembly_id: int,
	body: RigidBody3D
) -> void:
	if body == null:
		return
	var projected := get_physics_body(assembly_id)
	if projected != null and projected != body:
		_remove_body(assembly_id)
	_mounted_bodies[assembly_id] = body
	body.set_meta("assembly_id", assembly_id)


func mount_assembly_body_now(
	assembly_id: int,
	body: RigidBody3D
) -> bool:
	register_mounted_body(assembly_id, body)
	if _world == null or _world.get_assembly_raw(assembly_id) == null:
		return false
	_project_assembly(assembly_id, _capture_body_motion(body))
	return get_physics_body(assembly_id) == body


func unregister_mounted_body(assembly_id: int) -> void:
	_mounted_bodies.erase(assembly_id)


func set_collision_profile(
	assembly_id: int,
	layer: int,
	mask: int
) -> void:
	_collision_profiles[assembly_id] = {
		"layer": layer,
		"mask": mask,
	}
	var body := get_physics_body(assembly_id)
	if body != null:
		_apply_collision_profile(assembly_id, body)


func add_body_group(assembly_id: int, group_name: String) -> void:
	if group_name.is_empty():
		return
	var groups: Array = _body_groups.get(assembly_id, [])
	if not groups.has(group_name):
		groups.append(group_name)
	_body_groups[assembly_id] = groups
	var body: PhysicsBody3D = get_physics_body(assembly_id)
	if body != null and body is RigidBody3D:
		(body as RigidBody3D).add_to_group(group_name)


func project_assembly_now(
	assembly_id: int,
	motion_override: AssemblyMotionState = null
) -> void:
	if get_physics_body(assembly_id) != null:
		_remove_body(assembly_id)
	_project_assembly(assembly_id, motion_override)


func sync_body_motion_now(assembly_id: int) -> bool:
	if _world == null:
		return false
	var body := get_physics_body(assembly_id)
	if body == null:
		return false
	return _world.sync_assembly_motion(
		assembly_id,
		_capture_body_motion(body)
	)


func align_body_motion(
	target_assembly_id: int,
	reference_assembly_id: int
) -> bool:
	var target := get_physics_body(target_assembly_id) as RigidBody3D
	var reference := get_physics_body(reference_assembly_id) as RigidBody3D
	if target == null or reference == null:
		return false
	target.global_transform = reference.global_transform
	target.linear_velocity = reference.linear_velocity
	target.angular_velocity = reference.angular_velocity
	return sync_body_motion_now(target_assembly_id)


func _physics_process(_delta: float) -> void:
	if _world == null:
		return
	for assembly_id: int in _sorted_int_keys(_bodies):
		var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
		var body: PhysicsBody3D = _bodies[assembly_id] as PhysicsBody3D
		if assembly == null or assembly.tombstoned or body == null:
			continue
		_world.sync_assembly_motion(assembly_id, _capture_body_motion(body))


func _exit_tree() -> void:
	unbind_world()
	_clear_all_bodies()


func _on_structural_event(event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"world_restored":
			rebuild_all()
		&"assembly_spawned":
			_project_assembly(int(event["assembly_id"]), null)
		&"assembly_changed":
			_reproject_assembly(int(event["assembly_id"]))
		&"assembly_removed":
			_remove_body(int(event["assembly_id"]))
		&"rigid_joint_broken":
			pass
		&"assembly_split":
			_handle_split(event)
		&"assembly_merged":
			_handle_merge(event)


func _reproject_assembly(assembly_id: int) -> void:
	var body := get_physics_body(assembly_id)
	var motion: AssemblyMotionState = (
		_capture_body_motion(body)
		if body != null
		else null
	)
	_remove_body(assembly_id)
	_project_assembly(assembly_id, motion)


func _handle_split(event: Dictionary) -> void:
	var survivor_id: int = int(event["survivor_assembly_id"])
	var parent_body: PhysicsBody3D = get_physics_body(survivor_id)
	var parent_motion := AssemblyMotionState.new()
	var parent_com_world := Vector3.ZERO
	if parent_body != null:
		parent_motion = _capture_body_motion(parent_body)
		parent_com_world = _body_center_of_mass_world(parent_body)
	var new_ids: Array[int] = []
	for mapping_variant: Variant in event.get("new_assemblies", []):
		if mapping_variant is Dictionary:
			new_ids.append(int(mapping_variant["assembly_id"]))
	_remove_body(survivor_id)
	for assembly_id: int in new_ids:
		_project_split_child(
			assembly_id,
			parent_motion,
			parent_com_world
		)
	_project_split_child(
		survivor_id,
		parent_motion,
		parent_com_world
	)


func _project_split_child(
	assembly_id: int,
	parent_motion: AssemblyMotionState,
	parent_com_world: Vector3
) -> void:
	var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	var motion: AssemblyMotionState = parent_motion.duplicate_state()
	if _world.assembly_has_anchor(assembly_id):
		motion.linear_velocity = Vector3.ZERO
		motion.angular_velocity = Vector3.ZERO
		motion.sleeping = true
		motion.frozen = true
	else:
		var child_com_world: Vector3 = parent_motion.transform * (
			ColliderProjectionUtil.assembly_center_of_mass_local(
				_world,
				assembly
			)
		)
		var inherited: Dictionary = (
			AssemblyPhysicsMath.inherit_split_motion(
				parent_motion.linear_velocity,
				parent_motion.angular_velocity,
				parent_com_world,
				child_com_world
			)
		)
		motion.linear_velocity = inherited["linear_velocity"]
		motion.angular_velocity = inherited["angular_velocity"]
		motion.sleeping = false
		motion.frozen = false
	_project_assembly(assembly_id, motion)


func _handle_merge(event: Dictionary) -> void:
	var survivor_id: int = int(event["survivor_assembly_id"])
	var loser_id: int = int(event["loser_assembly_id"])
	var survivor_body: PhysicsBody3D = get_physics_body(survivor_id)
	var loser_body: PhysicsBody3D = get_physics_body(loser_id)
	var merged_motion: AssemblyMotionState = _merged_motion(
		survivor_id,
		survivor_body,
		loser_body
	)
	_remove_body(loser_id)
	_remove_body(survivor_id)
	_project_assembly(survivor_id, merged_motion)


func _merged_motion(
	survivor_id: int,
	survivor_body: PhysicsBody3D,
	loser_body: PhysicsBody3D
) -> AssemblyMotionState:
	var survivor: SimulationAssembly = _world.get_assembly_raw(survivor_id)
	if survivor == null:
		return AssemblyMotionState.new()
	var survivor_motion: AssemblyMotionState = (
		_capture_body_motion(survivor_body)
		if survivor_body != null
		else survivor.motion.duplicate_state()
	)
	if _world.assembly_has_anchor(survivor_id):
		survivor_motion.linear_velocity = Vector3.ZERO
		survivor_motion.angular_velocity = Vector3.ZERO
		survivor_motion.sleeping = true
		survivor_motion.frozen = true
		return survivor_motion
	if survivor_body == null or loser_body == null:
		survivor_motion.frozen = false
		return survivor_motion
	var loser_motion: AssemblyMotionState = _capture_body_motion(loser_body)
	var mass_a: float = _body_mass(survivor_body)
	var mass_b: float = _body_mass(loser_body)
	var com_a: Vector3 = _body_center_of_mass_world(survivor_body)
	var com_b: Vector3 = _body_center_of_mass_world(loser_body)
	var merged_mass: float = mass_a + mass_b
	var merged_records: Array[Dictionary] = (
		ColliderProjectionUtil.build_collision_shapes(_world, survivor)
	)
	var merged_com_local: Vector3 = (
		ColliderProjectionUtil.assembly_center_of_mass_local(
			_world,
			survivor
		)
	)
	var actual_merged_com_world: Vector3 = (
		survivor_motion.transform * merged_com_local
	)
	var merged_inertia: Vector3 = (
		ColliderProjectionUtil.estimate_inertia_diagonal(
			merged_mass,
			merged_records,
			merged_com_local
		)
	)
	var merged: Dictionary = AssemblyPhysicsMath.merge_dynamic_momentum(
		mass_a,
		com_a,
		survivor_motion.linear_velocity,
		survivor_motion.angular_velocity,
		_estimate_body_inertia(survivor_body),
		survivor_motion.transform.basis,
		mass_b,
		com_b,
		loser_motion.linear_velocity,
		loser_motion.angular_velocity,
		_estimate_body_inertia(loser_body),
		loser_motion.transform.basis,
		actual_merged_com_world,
		merged_mass,
		merged_inertia,
		survivor_motion.transform.basis
	)
	survivor_motion.linear_velocity = merged["linear_velocity"]
	survivor_motion.angular_velocity = merged["angular_velocity"]
	survivor_motion.sleeping = false
	survivor_motion.frozen = false
	return survivor_motion


func _project_assembly(
	assembly_id: int,
	motion_override: AssemblyMotionState
) -> void:
	var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		_remove_body(assembly_id)
		return
	if (
		motion_override == null
		and _projected_revision.get(assembly_id, -1)
		== assembly.topology_revision
		and get_physics_body(assembly_id) != null
	):
		return
	var seed_motion: AssemblyMotionState = (
		motion_override
		if motion_override != null
		else assembly.motion
	)
	var anchored: bool = _world.assembly_has_anchor(assembly_id)
	var mounted: RigidBody3D = _mounted_bodies.get(assembly_id) as RigidBody3D
	var mounted_motion: AssemblyMotionState = null
	var body: PhysicsBody3D
	if mounted != null:
		mounted_motion = _capture_body_motion(mounted)
		mounted.freeze = true
		_clear_body_colliders(mounted)
		body = mounted
	else:
		body = _create_body(assembly_id, anchored)
	var records: Array[Dictionary] = (
		ColliderProjectionUtil.build_collision_shapes(_world, assembly)
	)
	var colliders_by_element: Dictionary = {}
	for record: Dictionary in records:
		var element_id: int = int(record["element_id"])
		var existing_colliders: Array = colliders_by_element.get(
			element_id,
			[]
		)
		var collider := CollisionShape3D.new()
		collider.name = "ElementCollider_%d_%d" % [
			element_id,
			existing_colliders.size(),
		]
		collider.shape = record["shape"]
		collider.transform = record["local_transform"]
		collider.set_meta("element_id", element_id)
		collider.set_meta("collider_index", int(record["collider_index"]))
		collider.set_meta(
			"collider_local_cell",
			record["collider_local_cell"]
		)
		body.add_child(collider)
		if not colliders_by_element.has(element_id):
			colliders_by_element[element_id] = []
		colliders_by_element[element_id].append(collider)
	var motion: AssemblyMotionState = seed_motion.duplicate_state()
	motion.frozen = anchored
	if anchored:
		motion.linear_velocity = Vector3.ZERO
		motion.angular_velocity = Vector3.ZERO
		motion.sleeping = true
	if mounted == null:
		add_child(body)
		body.global_transform = motion.transform
	else:
		if motion_override == null:
			motion = mounted_motion
		else:
			motion.transform = mounted_motion.transform
			motion.frozen = mounted_motion.frozen
	_apply_collision_profile(assembly_id, body)
	_apply_body_groups(assembly_id, body)
	if body is RigidBody3D:
		var rigid: RigidBody3D = body as RigidBody3D
		rigid.mass = maxf(
			ColliderProjectionUtil.assembly_dry_mass(_world, assembly),
			MIN_MASS
		)
		rigid.center_of_mass_mode = (
			RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		)
		rigid.center_of_mass = (
			ColliderProjectionUtil.assembly_center_of_mass_local(
				_world,
				assembly
			)
		)
		rigid.inertia = Vector3.ZERO
		rigid.linear_velocity = motion.linear_velocity
		rigid.angular_velocity = motion.angular_velocity
		rigid.sleeping = motion.sleeping
		if mounted != null:
			rigid.freeze = motion.frozen
	_bodies[assembly_id] = body
	for element_id: int in colliders_by_element:
		_element_records[element_id] = {
			"assembly_id": assembly_id,
			"body": body,
			"colliders": colliders_by_element[element_id],
		}
	_world.sync_assembly_motion(assembly_id, motion)
	_projected_revision[assembly_id] = assembly.topology_revision


func _create_body(
	assembly_id: int,
	anchored: bool
) -> PhysicsBody3D:
	var body: PhysicsBody3D
	if anchored:
		body = StaticBody3D.new()
	else:
		var rigid: RigidBody3D
		if _mounted_bodies.has(assembly_id):
			rigid = RigidBody3D.new()
		else:
			rigid = FragmentBodyScript.new() as RigidBody3D
		rigid.freeze = false
		body = rigid
	body.name = "%s%d" % [BODY_NAME_PREFIX, assembly_id]
	body.collision_layer = 1
	body.collision_mask = 1
	body.set_meta("assembly_id", assembly_id)
	_apply_collision_profile(assembly_id, body)
	return body


func _apply_collision_profile(
	assembly_id: int,
	body: PhysicsBody3D
) -> void:
	var profile: Variant = _collision_profiles.get(assembly_id)
	if profile is Dictionary:
		body.collision_layer = int(profile.get("layer", body.collision_layer))
		body.collision_mask = int(profile.get("mask", body.collision_mask))


func _apply_body_groups(
	assembly_id: int,
	body: PhysicsBody3D
) -> void:
	for group_name: Variant in _body_groups.get(assembly_id, []):
		if body is RigidBody3D:
			(body as RigidBody3D).add_to_group(str(group_name))


func _clear_body_colliders(body: PhysicsBody3D) -> void:
	var stale: Array[CollisionShape3D] = []
	for child: Node in body.get_children():
		if child is CollisionShape3D:
			stale.append(child as CollisionShape3D)
	for collider: CollisionShape3D in stale:
		collider.disabled = true
		collider.queue_free()


func _capture_body_motion(
	body: PhysicsBody3D
) -> AssemblyMotionState:
	var motion := AssemblyMotionState.new()
	motion.transform = body.global_transform
	if body is RigidBody3D:
		var rigid: RigidBody3D = body as RigidBody3D
		motion.linear_velocity = rigid.linear_velocity
		motion.angular_velocity = rigid.angular_velocity
		motion.sleeping = rigid.sleeping
		motion.frozen = rigid.freeze
	else:
		motion.sleeping = true
		motion.frozen = true
	return motion


func _body_mass(body: PhysicsBody3D) -> float:
	if body is RigidBody3D:
		return maxf((body as RigidBody3D).mass, MIN_MASS)
	var assembly_id: int = int(body.get_meta("assembly_id", 0))
	var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
	return maxf(
		ColliderProjectionUtil.assembly_dry_mass(_world, assembly),
		MIN_MASS
	)


func _body_center_of_mass_world(
	body: PhysicsBody3D
) -> Vector3:
	if body is RigidBody3D:
		return body.to_global((body as RigidBody3D).center_of_mass)
	return body.global_position


func _estimate_body_inertia(body: PhysicsBody3D) -> Vector3:
	var records: Array[Dictionary] = []
	for child: Node in body.get_children():
		if child is CollisionShape3D:
			var collider: CollisionShape3D = child as CollisionShape3D
			if collider.shape is BoxShape3D:
				records.append({
					"shape": collider.shape,
					"local_transform": collider.transform,
				})
	var local_com := Vector3.ZERO
	if body is RigidBody3D:
		local_com = (body as RigidBody3D).center_of_mass
	return ColliderProjectionUtil.estimate_inertia_diagonal(
		_body_mass(body),
		records,
		local_com
	)


func _remove_body(assembly_id: int) -> void:
	_remove_element_records_for_assembly(assembly_id)
	var body: PhysicsBody3D = get_physics_body(assembly_id)
	if body != null:
		if _mounted_bodies.get(assembly_id) == body:
			_clear_body_colliders(body)
		else:
			body.collision_layer = 0
			body.collision_mask = 0
			body.process_mode = Node.PROCESS_MODE_DISABLED
			body.queue_free()
	_bodies.erase(assembly_id)
	_projected_revision.erase(assembly_id)


func _remove_element_records_for_assembly(
	assembly_id: int
) -> void:
	var stale: Array[int] = []
	for element_id: int in _element_records:
		var record: Dictionary = _element_records[element_id]
		if int(record.get("assembly_id", 0)) == assembly_id:
			stale.append(element_id)
	for element_id: int in stale:
		_element_records.erase(element_id)


func _clear_all_bodies() -> void:
	for assembly_id: int in _sorted_int_keys(_bodies):
		_remove_body(assembly_id)
	_bodies.clear()
	_element_records.clear()
	_projected_revision.clear()


func _sorted_int_keys(dictionary: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key: Variant in dictionary:
		result.append(int(key))
	result.sort()
	return result
