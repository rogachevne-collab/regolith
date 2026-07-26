class_name StructuralEventCoordinator
extends RefCounted
## Structural-event cluster extracted from SimulationPhysicsProjection: kernel
## structural_event dispatch, incremental collider append/remove, full
## reproject, split and merge. Bodies, joints, records, cables and the tick
## hot path stay in SimulationPhysicsProjection.
##
## The signal handler itself stays a non-static node method on the projection
## (same Callable for connect/is_connected/disconnect) and calls in here.


## Mirrors SimulationPhysicsProjection.MIN_MASS — same floor, kept local so the
## service does not reference the monolith's class_name (cycle).
const MIN_MASS := 0.001


static func on_structural_event(projection, event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"world_restored":
			projection.rebuild_all()
		&"assembly_spawned":
			AssemblyProjectionCoordinator.project_assembly(
				projection,
				int(event["assembly_id"]),
				null
			)
		&"assembly_changed":
			var changed_assembly_id := int(event["assembly_id"])
			var placed_element_id := int(event.get("placed_element_id", 0))
			var removed_element_id := int(event.get("removed_element_id", 0))
			if (
				placed_element_id > 0
				and StructuralEventCoordinator.try_append_placed_element(
					projection,
					changed_assembly_id,
					placed_element_id
				)
			):
				pass
			elif (
				removed_element_id > 0
				and StructuralEventCoordinator.try_remove_projected_element(
					projection,
					changed_assembly_id,
					removed_element_id
				)
			):
				pass
			else:
				StructuralEventCoordinator.reproject_assembly(
					projection,
					changed_assembly_id
				)
		&"assembly_removed":
			AssemblyTeardownCoordinator.remove_body(projection, int(event["assembly_id"]))
		&"rigid_joint_broken":
			pass
		&"assembly_split":
			StructuralEventCoordinator.handle_split(projection, event)
		&"assembly_merged":
			StructuralEventCoordinator.handle_merge(projection, event)

## Place/dismantle on a single-body assembly: mutate colliders in place instead
## of destroying the RigidBody (avoids parking-bristle + contact graph storms on
## large powered rovers). Multibody / actuator topology still full-reprojects.
static func try_append_placed_element(
	projection,
	assembly_id: int,
	element_id: int
) -> bool:
	var fail_reason := &""
	if (
		projection._world == null
		or element_id <= 0
		or projection._element_records.has(element_id)
	):
		fail_reason = &"already_projected_or_bad_id"
	elif projection._assembly_group_bodies.has(assembly_id):
		return StructuralEventCoordinator.try_append_multibody_element(
			projection,
			assembly_id,
			element_id
		)
	elif projection._mounted_bodies.has(assembly_id):
		fail_reason = &"mounted"
	var assembly: SimulationAssembly = null
	var body: PhysicsBody3D = null
	if fail_reason == &"":
		assembly = projection._world.get_assembly_raw(assembly_id)
		body = projection.get_physics_body(assembly_id)
		if (
			assembly == null
			or assembly.tombstoned
			or body == null
			or not (body is RigidBody3D)
		):
			fail_reason = &"not_rigid_body"
	var compiled: Dictionary = {}
	if fail_reason == &"":
		compiled = AssemblyProjectionCoordinator.compile_assembly_groups(projection, assembly)
		if not bool(compiled.get("valid", false)):
			fail_reason = &"compile_invalid"
		elif not (compiled.get("driven_specs", []) as Array).is_empty():
			fail_reason = &"driven_specs"
		elif not (compiled.get("wheel_specs", []) as Array).is_empty():
			# Колесо обязано стать своим телом на своём констрейнте. Прилепить
			# его к единому телу «на месте» — значит молча оставить ровер без
			# колёсной физики до следующей полной пересборки.
			fail_reason = &"wheel_specs"
	var element: SimulationElement = null
	if fail_reason == &"":
		element = projection._world.get_element(element_id)
		if element == null or element.assembly_id != assembly_id:
			fail_reason = &"bad_element"
	var records: Array[Dictionary] = []
	if fail_reason == &"":
		records = PistonProjectionUtil.build_collision_shapes_for_elements(
			projection._world,
			assembly,
			[element_id] as Array[int]
		)
		if records.is_empty():
			fail_reason = &"empty_colliders"
	if fail_reason != &"":
		return false
	AssemblyBodyBuildCoordinator.attach_colliders_to_body(
		projection,
		body,
		records,
		assembly_id,
		[element_id] as Array[int]
	)
	StructuralEventCoordinator.refresh_single_body_mass_com(
		projection,
		assembly_id,
		body as RigidBody3D,
		assembly
	)
	WheelPhysicsTickCoordinator.sync_wheel_loco_body_physics(
		projection,
		assembly_id,
		body as RigidBody3D
	)
	projection._projected_revision[assembly_id] = assembly.topology_revision
	return true

## Non-topological place on a multibody assembly: the new element joined an
## existing rigid group, so its colliders attach to that group body in place.
## No body teardown and no joint rebuild — an extended/sagged actuator chain
## keeps its live pose and solver warm-start untouched.
static func try_append_multibody_element(
	projection,
	assembly_id: int,
	element_id: int
) -> bool:
	if projection._mounted_bodies.has(assembly_id):
		return false
	var assembly: SimulationAssembly = (
		projection._world.get_assembly_raw(assembly_id)
	)
	if assembly == null or assembly.tombstoned:
		return false
	var compiled: Dictionary = AssemblyProjectionCoordinator.compile_assembly_groups(
		projection,
		assembly
	)
	if not bool(compiled.get("valid", false)):
		return false
	if not StructuralEventCoordinator.multibody_topology_matches(
		projection,
		assembly_id,
		compiled
	):
		return false
	var group_id := int(
		(compiled.get("element_to_group", {}) as Dictionary).get(element_id, 0)
	)
	var groups_map: Dictionary = (
		projection._assembly_group_bodies.get(assembly_id, {})
	)
	var body: PhysicsBody3D = groups_map.get(group_id) as PhysicsBody3D
	if group_id <= 0 or body == null or not is_instance_valid(body):
		return false
	var records: Array[Dictionary] = (
		PistonProjectionUtil.build_collision_shapes_for_elements(
			projection._world,
			assembly,
			[element_id] as Array[int]
		)
	)
	if records.is_empty():
		return false
	AssemblyBodyBuildCoordinator.attach_colliders_to_body(
		projection,
		body,
		records,
		assembly_id,
		[element_id] as Array[int]
	)
	StructuralEventCoordinator.refresh_group_body_mass_com(
		projection,
		assembly,
		body,
		(compiled.get("groups", {}) as Dictionary).get(group_id, [])
	)
	StructuralEventCoordinator.append_element_to_carriage_records(
		projection,
		assembly_id,
		body,
		element_id
	)
	projection._projected_revision[assembly_id] = assembly.topology_revision
	return true

## True when the compiled topology matches what is currently projected: same
## rigid group ids, same root and same driven joints — i.e. the edit stayed
## inside one existing group.
static func multibody_topology_matches(
	projection,
	assembly_id: int,
	compiled: Dictionary
) -> bool:
	var groups_map: Dictionary = (
		projection._assembly_group_bodies.get(assembly_id, {})
	)
	var compiled_groups: Dictionary = compiled.get("groups", {})
	if groups_map.size() != compiled_groups.size():
		return false
	for group_id_variant: Variant in compiled_groups:
		if not groups_map.has(int(group_id_variant)):
			return false
	if int(compiled.get("root_group_id", 0)) != int(
		projection._root_group_ids.get(assembly_id, 0)
	):
		return false
	var projected_joint_ids: Dictionary = {}
	for record_variant: Variant in projection._piston_constraints.get(
		assembly_id, []
	):
		if record_variant is Dictionary:
			projected_joint_ids[
				int((record_variant as Dictionary).get("joint_id", 0))
			] = true
	for record_variant: Variant in projection._rotor_constraints.get(
		assembly_id, []
	):
		if record_variant is Dictionary:
			projected_joint_ids[
				int((record_variant as Dictionary).get("joint_id", 0))
			] = true
	for record_variant: Variant in projection._wheel_constraints.get(
		assembly_id, []
	):
		if record_variant is Dictionary:
			projected_joint_ids[
				int((record_variant as Dictionary).get("joint_id", 0))
			] = true
	var specs: Array = compiled.get("driven_specs", [])
	var all_specs: Array = specs.duplicate()
	all_specs.append_array(compiled.get("wheel_specs", []))
	if all_specs.size() != projected_joint_ids.size():
		return false
	for spec_variant: Variant in all_specs:
		if not spec_variant is Dictionary:
			return false
		if not projected_joint_ids.has(
			int((spec_variant as Dictionary).get("joint_id", 0))
		):
			return false
	return true

static func refresh_group_body_mass_com(
	projection,
	assembly: SimulationAssembly,
	body: PhysicsBody3D,
	member_ids: Array
) -> void:
	if not body is RigidBody3D:
		return
	var element_ids: Array[int] = []
	for member_variant: Variant in member_ids:
		element_ids.append(int(member_variant))
	var rigid := body as RigidBody3D
	rigid.mass = maxf(
		PistonProjectionUtil.dry_mass_for_elements(
			projection._world,
			element_ids
		),
		MIN_MASS
	)
	rigid.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	rigid.center_of_mass = (
		PistonProjectionUtil.center_of_mass_local_for_records(
			PistonProjectionUtil.build_collision_shapes_for_elements(
				projection._world,
				assembly,
				element_ids
			)
		)
	)

## Keep piston carriage element lists fresh so load estimates and sustained
## impact strikers see blocks welded onto the carriage after projection.
static func append_element_to_carriage_records(
	projection,
	assembly_id: int,
	group_body: PhysicsBody3D,
	element_id: int
) -> void:
	for record_variant: Variant in projection._piston_constraints.get(
		assembly_id, []
	):
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		if record.get("head_body") != group_body:
			continue
		var carriage: Array = record.get("carriage_element_ids", [])
		if not carriage.has(element_id):
			carriage.append(element_id)
			record["carriage_element_ids"] = carriage


static func remove_element_from_carriage_records(
	projection,
	assembly_id: int,
	element_id: int
) -> void:
	for record_variant: Variant in projection._piston_constraints.get(
		assembly_id, []
	):
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		var carriage: Array = record.get("carriage_element_ids", [])
		if carriage.has(element_id):
			carriage.erase(element_id)
			record["carriage_element_ids"] = carriage


static func try_remove_projected_element(
	projection,
	assembly_id: int,
	element_id: int
) -> bool:
	if projection._world == null or element_id <= 0:
		return false
	if projection._mounted_bodies.has(assembly_id):
		return false
	if projection._assembly_group_bodies.has(assembly_id):
		return StructuralEventCoordinator.try_remove_multibody_element(
			projection,
			assembly_id,
			element_id
		)
	var assembly: SimulationAssembly = (
		projection._world.get_assembly_raw(assembly_id)
	)
	var body: PhysicsBody3D = projection.get_physics_body(assembly_id)
	if (
		assembly == null
		or assembly.tombstoned
		or body == null
		or not (body is RigidBody3D)
	):
		return false
	var compiled: Dictionary = AssemblyProjectionCoordinator.compile_assembly_groups(
		projection,
		assembly
	)
	if (
		not bool(compiled.get("valid", false))
		or not (compiled.get("driven_specs", []) as Array).is_empty()
		or not (compiled.get("wheel_specs", []) as Array).is_empty()
	):
		return false
	var record: Variant = projection._element_records.get(element_id)
	if not record is Dictionary:
		return false
	StructuralEventCoordinator.free_element_colliders(record as Dictionary)
	projection._element_records.erase(element_id)
	StructuralEventCoordinator.refresh_single_body_mass_com(
		projection,
		assembly_id,
		body as RigidBody3D,
		assembly
	)
	WheelPhysicsTickCoordinator.sync_wheel_loco_body_physics(
		projection,
		assembly_id,
		body as RigidBody3D
	)
	projection._projected_revision[assembly_id] = assembly.topology_revision
	return true


## Inverse of try_append_multibody_element: drop colliders from one group body
## when group/joint topology is otherwise unchanged (typical frame dismantle on
## a parked wheeled rover). Wheel/actuator endpoint removes fail the topology
## match and fall back to full reproject.
static func try_remove_multibody_element(
	projection,
	assembly_id: int,
	element_id: int
) -> bool:
	var assembly: SimulationAssembly = (
		projection._world.get_assembly_raw(assembly_id)
	)
	if assembly == null or assembly.tombstoned:
		return false
	var record_variant: Variant = projection._element_records.get(element_id)
	if not record_variant is Dictionary:
		return false
	var record: Dictionary = record_variant
	var body: PhysicsBody3D = record.get("body") as PhysicsBody3D
	if body == null or not is_instance_valid(body):
		return false
	var compiled: Dictionary = AssemblyProjectionCoordinator.compile_assembly_groups(
		projection,
		assembly
	)
	if not bool(compiled.get("valid", false)):
		return false
	if not StructuralEventCoordinator.multibody_topology_matches(
		projection,
		assembly_id,
		compiled
	):
		return false
	var groups_map: Dictionary = (
		projection._assembly_group_bodies.get(assembly_id, {})
	)
	var group_id := 0
	for group_id_variant: Variant in groups_map.keys():
		if groups_map[group_id_variant] == body:
			group_id = int(group_id_variant)
			break
	if group_id <= 0:
		return false
	StructuralEventCoordinator.free_element_colliders(record)
	projection._element_records.erase(element_id)
	StructuralEventCoordinator.refresh_group_body_mass_com(
		projection,
		assembly,
		body,
		(compiled.get("groups", {}) as Dictionary).get(group_id, [])
	)
	StructuralEventCoordinator.remove_element_from_carriage_records(
		projection,
		assembly_id,
		element_id
	)
	projection._projected_revision[assembly_id] = assembly.topology_revision
	return true


static func free_element_colliders(record: Dictionary) -> void:
	var colliders: Array = record.get("colliders", [])
	for collider_variant: Variant in colliders:
		if collider_variant is CollisionShape3D and is_instance_valid(collider_variant):
			var collider := collider_variant as CollisionShape3D
			collider.disabled = true
			collider.queue_free()

static func refresh_single_body_mass_com(
	projection,
	assembly_id: int,
	rigid: RigidBody3D,
	assembly: SimulationAssembly
) -> void:
	if rigid == null or assembly == null:
		return
	rigid.mass = maxf(
		ColliderProjectionUtil.assembly_dry_mass(projection._world, assembly),
		MIN_MASS
	)
	rigid.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	rigid.center_of_mass = ColliderProjectionUtil.assembly_center_of_mass_local(
		projection._world,
		assembly
	)
	rigid.inertia = Vector3.ZERO
	# Quiet residual motion after COM shift so parking bristle can re-seat.
	var locomotion: AssemblyLocomotionController = (
		projection._world.get_locomotion_controller(assembly_id)
	)
	if locomotion != null and locomotion.is_parking_brake():
		rigid.linear_velocity = Vector3.ZERO
		rigid.angular_velocity = Vector3.ZERO

static func reproject_assembly(projection, assembly_id: int) -> void:
	# Capture per-element live poses BEFORE teardown. Multibody rebuild used to
	# call _capture_live_group_motions after _remove_body — always empty — so
	# cutting an extended piston snapped survivors to home grid pose.
	var live_capture: Dictionary = (
		PhysicsMotionSyncCoordinator.capture_live_element_motions(
			projection,
			assembly_id
		)
	)
	var body: PhysicsBody3D = projection.get_physics_body(assembly_id)
	var motion: AssemblyMotionState = (
		PhysicsMotionSyncCoordinator.capture_body_motion(projection, body)
		if body != null
		else null
	)
	AssemblyTeardownCoordinator.remove_body(projection, assembly_id)
	AssemblyProjectionCoordinator.project_assembly(
		projection,
		assembly_id,
		motion,
		live_capture
	)
	AssemblyTeardownCoordinator.restore_evacuated_drivers(projection)

static func handle_split(projection, event: Dictionary) -> void:
	var survivor_id: int = int(event["survivor_assembly_id"])
	var parent_body: PhysicsBody3D = projection.get_physics_body(survivor_id)
	var parent_motion := AssemblyMotionState.new()
	var parent_com_world := Vector3.ZERO
	var parent_body_id := 0
	var live_capture: Dictionary = (
		PhysicsMotionSyncCoordinator.capture_live_element_motions(
			projection,
			survivor_id
		)
	)
	if parent_body != null:
		parent_motion = PhysicsMotionSyncCoordinator.capture_body_motion(
			projection,
			parent_body
		)
		parent_com_world = AssemblyBodyBuildCoordinator.body_center_of_mass_world(
			projection,
			parent_body
		)
		parent_body_id = parent_body.get_instance_id()
	var new_ids: Array[int] = []
	for mapping_variant: Variant in event.get("new_assemblies", []):
		if mapping_variant is Dictionary:
			new_ids.append(int(mapping_variant["assembly_id"]))
	AssemblyTeardownCoordinator.remove_body(projection, survivor_id)
	for assembly_id: int in new_ids:
		StructuralEventCoordinator.project_split_child(
			projection,
			assembly_id,
			parent_motion,
			parent_com_world,
			parent_body_id,
			live_capture
		)
	StructuralEventCoordinator.project_split_child(
		projection,
		survivor_id,
		parent_motion,
		parent_com_world,
		parent_body_id,
		live_capture
	)
	AssemblyTeardownCoordinator.restore_evacuated_drivers(projection)

static func project_split_child(
	projection,
	assembly_id: int,
	parent_motion: AssemblyMotionState,
	parent_com_world: Vector3,
	parent_body_id: int = 0,
	live_capture: Dictionary = {}
) -> void:
	var assembly: SimulationAssembly = (
		projection._world.get_assembly_raw(assembly_id)
	)
	if assembly == null:
		return
	var motion: AssemblyMotionState = (
		StructuralEventCoordinator.seed_motion_for_split_child(
			projection,
			assembly,
			parent_motion,
			parent_com_world,
			parent_body_id,
			live_capture
		)
	)
	AssemblyProjectionCoordinator.project_assembly(
		projection,
		assembly_id,
		motion,
		live_capture
	)


## Prefer the live pose of any element that still belongs to this child.
## Same rigid body as the pre-split root → COM velocity inheritance.
## Distinct body (extended carriage) → keep that body's transform and velocity.
static func seed_motion_for_split_child(
	projection,
	assembly: SimulationAssembly,
	parent_motion: AssemblyMotionState,
	parent_com_world: Vector3,
	parent_body_id: int,
	live_capture: Dictionary
) -> AssemblyMotionState:
	var motions: Dictionary = live_capture.get("motions", {})
	var body_ids: Dictionary = live_capture.get("body_ids", {})
	var live_seed: AssemblyMotionState = null
	var seed_body_id := 0
	for element_id: int in assembly.element_ids:
		if not motions.has(element_id):
			continue
		var candidate: Variant = motions[element_id]
		if candidate is AssemblyMotionState:
			live_seed = candidate as AssemblyMotionState
			seed_body_id = int(body_ids.get(element_id, 0))
			break
	var motion: AssemblyMotionState = (
		live_seed.duplicate_state()
		if live_seed != null
		else parent_motion.duplicate_state()
	)
	if projection._world.assembly_has_anchor(assembly.assembly_id):
		motion.linear_velocity = Vector3.ZERO
		motion.angular_velocity = Vector3.ZERO
		motion.sleeping = true
		motion.frozen = true
		return motion
	var same_parent_body := (
		live_seed == null
		or parent_body_id == 0
		or seed_body_id == 0
		or seed_body_id == parent_body_id
	)
	if same_parent_body:
		var child_com_world: Vector3 = parent_motion.transform * (
			ColliderProjectionUtil.assembly_center_of_mass_local(
				projection._world,
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
	return motion

static func handle_merge(projection, event: Dictionary) -> void:
	var survivor_id: int = int(event["survivor_assembly_id"])
	var loser_id: int = int(event["loser_assembly_id"])
	var survivor_body: PhysicsBody3D = projection.get_physics_body(survivor_id)
	var loser_body: PhysicsBody3D = projection.get_physics_body(loser_id)
	var merged_motion: AssemblyMotionState = (
		StructuralEventCoordinator.compute_merged_motion(
			projection,
			survivor_id,
			survivor_body,
			loser_body
		)
	)
	AssemblyTeardownCoordinator.remove_body(projection, loser_id)
	AssemblyTeardownCoordinator.remove_body(projection, survivor_id)
	AssemblyProjectionCoordinator.project_assembly(
		projection,
		survivor_id,
		merged_motion
	)
	AssemblyTeardownCoordinator.restore_evacuated_drivers(projection)

## _merged_motion in the monolith; renamed so the `merged_motion` local in
## handle_merge does not shadow it.
static func compute_merged_motion(
	projection,
	survivor_id: int,
	survivor_body: PhysicsBody3D,
	loser_body: PhysicsBody3D
) -> AssemblyMotionState:
	var survivor: SimulationAssembly = (
		projection._world.get_assembly_raw(survivor_id)
	)
	if survivor == null:
		return AssemblyMotionState.new()
	var survivor_motion: AssemblyMotionState = (
		PhysicsMotionSyncCoordinator.capture_body_motion(projection, survivor_body)
		if survivor_body != null
		else survivor.motion.duplicate_state()
	)
	if projection._world.assembly_has_anchor(survivor_id):
		survivor_motion.linear_velocity = Vector3.ZERO
		survivor_motion.angular_velocity = Vector3.ZERO
		survivor_motion.sleeping = true
		survivor_motion.frozen = true
		return survivor_motion
	if projection._mounted_bodies.has(survivor_id) and survivor_body != null:
		survivor_motion = PhysicsMotionSyncCoordinator.capture_body_motion(
			projection,
			survivor_body
		)
		survivor_motion.frozen = false
		return survivor_motion
	if survivor_body == null or loser_body == null:
		survivor_motion.frozen = false
		return survivor_motion
	var loser_motion: AssemblyMotionState = (
		PhysicsMotionSyncCoordinator.capture_body_motion(projection, loser_body)
	)
	if (
		survivor_motion.linear_velocity.is_equal_approx(
			loser_motion.linear_velocity
		)
		and survivor_motion.angular_velocity.is_equal_approx(
			loser_motion.angular_velocity
		)
	):
		survivor_motion.frozen = false
		return survivor_motion
	var mass_a: float = AssemblyBodyBuildCoordinator.body_mass(projection, survivor_body)
	var mass_b: float = AssemblyBodyBuildCoordinator.body_mass(projection, loser_body)
	var com_a: Vector3 = AssemblyBodyBuildCoordinator.body_center_of_mass_world(
		projection,
		survivor_body
	)
	var com_b: Vector3 = AssemblyBodyBuildCoordinator.body_center_of_mass_world(
		projection,
		loser_body
	)
	var inertia_a: Vector3 = AssemblyBodyBuildCoordinator.estimate_body_inertia(
		projection,
		survivor_body
	)
	var inertia_b: Vector3 = AssemblyBodyBuildCoordinator.estimate_body_inertia(
		projection,
		loser_body
	)
	var merged_mass: float = mass_a + mass_b
	var merged_records: Array[Dictionary] = (
		ColliderProjectionUtil.build_collision_shapes(
			projection._world,
			survivor
		)
	)
	var merged_com_local: Vector3 = (
		ColliderProjectionUtil.assembly_center_of_mass_local(
			projection._world,
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
		inertia_a,
		survivor_motion.transform.basis,
		mass_b,
		com_b,
		loser_motion.linear_velocity,
		loser_motion.angular_velocity,
		inertia_b,
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
