class_name PhysicsMotionSyncCoordinator
extends RefCounted
## Motion capture / sync cluster extracted from SimulationPhysicsProjection.
## Owns live pose read-back (Jolt → kernel) and pre-teardown motion snapshots.
## Hot-path order stays in SimulationPhysicsProjection._physics_process.


static func sync_body_motion_now(projection, assembly_id: int) -> bool:
	if projection._world == null:
		return false
	var body: PhysicsBody3D = projection.get_physics_body(assembly_id)
	if body == null:
		return false
	return projection._world.sync_assembly_motion(
		assembly_id,
		PhysicsMotionSyncCoordinator.capture_body_motion(projection, body)
	)


static func align_body_motion(
	projection,
	target_assembly_id: int,
	reference_assembly_id: int
) -> bool:
	var target: RigidBody3D = (
		projection.get_physics_body(target_assembly_id) as RigidBody3D
	)
	var reference_body: RigidBody3D = (
		projection.get_physics_body(reference_assembly_id) as RigidBody3D
	)
	if target == null or reference_body == null:
		return false
	target.global_transform = reference_body.global_transform
	target.linear_velocity = reference_body.linear_velocity
	target.angular_velocity = reference_body.angular_velocity
	return PhysicsMotionSyncCoordinator.sync_body_motion_now(
		projection,
		target_assembly_id
	)


## Per-tick Jolt → kernel motion read-back for every live (non-frozen) body.
## Called from SimulationPhysicsProjection._physics_process after actuators /
## wheels / cables; order of that outer tick is frozen.
static func sync_live_assembly_motions(projection) -> void:
	for assembly_id: int in projection._bodies_keys_cache:
		var assembly: SimulationAssembly = (
			projection._world.get_assembly_raw(assembly_id)
		)
		if assembly == null or assembly.tombstoned:
			continue
		# Parked settle-freeze: pose is static — skip per-frame motion capture.
		if projection._is_assembly_frozen(assembly_id):
			continue
		var group_bodies: Variant = (
			projection._assembly_group_bodies.get(assembly_id)
		)
		if (
			group_bodies is Dictionary
			and not (group_bodies as Dictionary).is_empty()
		):
			var motions: Dictionary = {}
			for group_id_variant: Variant in (
				(group_bodies as Dictionary).keys()
			):
				var group_body: PhysicsBody3D = (
					(group_bodies as Dictionary).get(group_id_variant)
					as PhysicsBody3D
				)
				if group_body == null:
					continue
				motions[int(group_id_variant)] = (
					PhysicsMotionSyncCoordinator.capture_body_motion(
						projection,
						group_body
					)
				)
			projection._world.sync_assembly_body_group_motions(
				assembly_id,
				motions
			)
			continue
		var body: PhysicsBody3D = (
			projection._bodies[assembly_id] as PhysicsBody3D
		)
		if body == null:
			continue
		projection._world.sync_assembly_motion(
			assembly_id,
			PhysicsMotionSyncCoordinator.capture_body_motion(projection, body)
		)


## Snapshot live per-group body motions (group_id -> AssemblyMotionState)
## before a multibody teardown so the rebuild can reseed surviving groups.
static func capture_live_group_motions(projection, assembly_id: int) -> Dictionary:
	var captured: Dictionary = {}
	var groups_map: Variant = projection._assembly_group_bodies.get(assembly_id)
	if not groups_map is Dictionary:
		return captured
	for group_id_variant: Variant in (groups_map as Dictionary):
		var body: PhysicsBody3D = (
			(groups_map as Dictionary)[group_id_variant] as PhysicsBody3D
		)
		if body != null and is_instance_valid(body):
			captured[int(group_id_variant)] = (
				PhysicsMotionSyncCoordinator.capture_body_motion(
					projection,
					body
				)
			)
	return captured


## Snapshot live body motion per element_id before teardown/split.
## Group ids are min(element_id) and change when members are removed; element
## keys stay stable across topology mutation so split children can reseed.
static func capture_live_element_motions(
	projection,
	assembly_id: int
) -> Dictionary:
	var motions: Dictionary = {}
	var body_ids: Dictionary = {}
	var groups_map: Variant = projection._assembly_group_bodies.get(assembly_id)
	if not groups_map is Dictionary:
		return {"motions": motions, "body_ids": body_ids}
	var body_motion_cache: Dictionary = {}
	for group_id_variant: Variant in (groups_map as Dictionary):
		var body: PhysicsBody3D = (
			(groups_map as Dictionary)[group_id_variant] as PhysicsBody3D
		)
		if body == null or not is_instance_valid(body):
			continue
		var body_id: int = body.get_instance_id()
		if not body_motion_cache.has(body_id):
			body_motion_cache[body_id] = (
				PhysicsMotionSyncCoordinator.capture_body_motion(
					projection,
					body
				)
			)
		var motion: AssemblyMotionState = body_motion_cache[body_id]
		for element_id_variant: Variant in projection._element_records.keys():
			var element_id: int = int(element_id_variant)
			var record: Variant = projection._element_records[element_id_variant]
			if not record is Dictionary:
				continue
			if int(record.get("assembly_id", 0)) != assembly_id:
				continue
			if record.get("body") != body:
				continue
			motions[element_id] = motion
			body_ids[element_id] = body_id
	return {"motions": motions, "body_ids": body_ids}


## Map pre-teardown element motions onto the assembly's current group ids.
static func remap_element_motions_to_groups(
	projection,
	assembly_id: int,
	live_capture: Dictionary
) -> Dictionary:
	var overrides: Dictionary = {}
	var motions: Dictionary = live_capture.get("motions", {})
	if motions.is_empty() or projection._world == null:
		return overrides
	var compiled: Dictionary = projection._world.compile_body_groups(assembly_id)
	if not bool(compiled.get("valid", false)):
		return overrides
	var groups: Dictionary = compiled.get("groups", {})
	var root_group_id: int = int(compiled.get("root_group_id", 0))
	for group_id_variant: Variant in groups.keys():
		var group_id: int = int(group_id_variant)
		if group_id == root_group_id:
			continue
		for member_variant: Variant in groups[group_id_variant]:
			var element_id: int = int(member_variant)
			if not motions.has(element_id):
				continue
			var motion_variant: Variant = motions[element_id]
			if motion_variant is AssemblyMotionState:
				overrides[group_id] = motion_variant
				break
	return overrides


static func capture_body_motion(
	_projection,
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
