class_name SimulationPhysicsProjection
extends Node3D

const BODY_NAME_PREFIX := "AssemblyBody_"
const GROUP_BODY_NAME_PREFIX := "AssemblyGroupBody_"
const PISTON_JOINT_NAME_PREFIX := "PistonJoint_"
const ROTOR_JOINT_NAME_PREFIX := "RotorJoint_"
const HINGE_JOINT_NAME_PREFIX := "HingeJoint_"
const MIN_MASS := 0.001
const SUSTAINED_V_EPS := 0.05
## Physics frames a parked rover must stay below the brake eps before its
## body is frozen (~0.5s at 60Hz).
const PARK_FREEZE_SETTLE_FRAMES := 30
const WAKE_DIG_MARGIN_M := 3.0
## Rope particles allowed to run world collision per physics tick, across all
## ropes. One rope always fits; a forest of them degrades to every-other-tick
## collision instead of eating the frame.
const CABLE_ROPE_COLLISION_BUDGET := 320
## Ground-anchor upkeep: how often a world-nailed rope end checks that it still
## has ground, and how much ground has to disappear before it tears loose.
const CABLE_ANCHOR_PROBE_INTERVAL_S := 0.33
const CABLE_ANCHOR_PROBE_RADIUS := 0.3
const FragmentBodyScript := preload(
	"res://scripts/simulation/projection/projected_assembly_body.gd"
)
const BodyGroupMotionUtilScript := preload(
	"res://scripts/simulation/runtime/body_group_motion_util.gd"
)

const ASSEMBLY_BOUNCE := 0.32
const ASSEMBLY_FRICTION := 0.42
## Locomotive chassis scrapes voxel meshes on bumps; bounce + CCD thrash the
## Jolt solver (see rover bump FPS). Wheels are raycast-supported.
const LOCOMOTIVE_BOUNCE := 0.0
## Layer 1 = terrain (VoxelLodTerrain default). Layer 2 = assemblies.
## Player is layer 4 / mask 3 (hits terrain + assemblies).
const COLLISION_LAYER_TERRAIN := 1
const COLLISION_LAYER_ASSEMBLY := 2
const COLLISION_MASK_ASSEMBLY := (
	COLLISION_LAYER_TERRAIN | COLLISION_LAYER_ASSEMBLY
)
## Wheel locomotives still collide with terrain: raycast wheels alone cannot
## catch tip-over / bad seating (mask=assembly-only freefalls through crust).
## FPS: CCD off, bounce 0, wheel/suspension solid colliders disabled.
const COLLISION_MASK_WHEEL_LOCOMOTIVE := COLLISION_MASK_ASSEMBLY

var _world: SimulationWorld
var _assembly_physics_material: PhysicsMaterial
var _locomotive_physics_material: PhysicsMaterial
var _bodies: Dictionary = {}
## assembly_id -> consecutive settled physics frames under parking brake.
var _park_settle_frames: Dictionary = {}
var _element_records: Dictionary = {}
var _projected_revision: Dictionary = {}
var _mounted_bodies: Dictionary = {}
var _collision_profiles: Dictionary = {}
var _body_groups: Dictionary = {}
var _assembly_group_bodies: Dictionary = {}
var _piston_constraints: Dictionary = {}
var _rotor_constraints: Dictionary = {}
var _root_group_ids: Dictionary = {}
var _impact_service: ImpactResolverService
var _cable_anchor_probe_cooldown := 0.0
## link_id → verlet rope state (CableRopeSolver). Presentation/physics only.
var _rope_states: Dictionary = {}
var _rope_collision_cursor := 0

func bind_impact_service(service: ImpactResolverService) -> void:
	_impact_service = service

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

func get_group_physics_body(assembly_id: int, group_id: int) -> PhysicsBody3D:
	var groups: Variant = _assembly_group_bodies.get(assembly_id)
	if groups is Dictionary:
		return groups.get(group_id) as PhysicsBody3D
	return null

func list_piston_constraint_records(assembly_id: int) -> Array:
	if not _piston_constraints.has(assembly_id):
		return []
	var records: Variant = _piston_constraints[assembly_id]
	if records is Array:
		return (records as Array).duplicate()
	return []

func list_rotor_constraint_records(assembly_id: int) -> Array:
	if not _rotor_constraints.has(assembly_id):
		return []
	var records: Variant = _rotor_constraints[assembly_id]
	if records is Array:
		return (records as Array).duplicate()
	return []

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
	var reference_body := get_physics_body(reference_assembly_id) as RigidBody3D
	if target == null or reference_body == null:
		return false
	target.global_transform = reference_body.global_transform
	target.linear_velocity = reference_body.linear_velocity
	target.angular_velocity = reference_body.angular_velocity
	return sync_body_motion_now(target_assembly_id)

func _physics_process(delta: float) -> void:
	if _world == null:
		return
	_tick_rotor_actuators(delta)
	_tick_piston_actuators(delta)
	_tick_wheel_pairs(delta)
	_tick_thrusters(delta)
	_tick_cable_ropes(delta)
	_tick_cable_tension(delta)
	_tick_cable_anchors(delta)
	for assembly_id: int in _sorted_int_keys(_bodies):
		var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
		if assembly == null or assembly.tombstoned:
			continue
		var group_bodies: Variant = _assembly_group_bodies.get(assembly_id)
		if group_bodies is Dictionary and not (group_bodies as Dictionary).is_empty():
			var motions: Dictionary = {}
			for group_id_variant: Variant in (group_bodies as Dictionary).keys():
				var group_body: PhysicsBody3D = (
					(group_bodies as Dictionary).get(group_id_variant)
					as PhysicsBody3D
				)
				if group_body == null:
					continue
				motions[int(group_id_variant)] = _capture_body_motion(group_body)
			_world.sync_assembly_body_group_motions(assembly_id, motions)
			continue
		var body: PhysicsBody3D = _bodies[assembly_id] as PhysicsBody3D
		if body == null:
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
			var changed_assembly_id := int(event["assembly_id"])
			var placed_element_id := int(event.get("placed_element_id", 0))
			var removed_element_id := int(event.get("removed_element_id", 0))
			if (
				placed_element_id > 0
				and _try_append_placed_element(
					changed_assembly_id,
					placed_element_id
				)
			):
				pass
			elif (
				removed_element_id > 0
				and _try_remove_projected_element(
					changed_assembly_id,
					removed_element_id
				)
			):
				pass
			else:
				_reproject_assembly(changed_assembly_id)
		&"assembly_removed":
			_remove_body(int(event["assembly_id"]))
		&"rigid_joint_broken":
			pass
		&"assembly_split":
			_handle_split(event)
		&"assembly_merged":
			_handle_merge(event)

## Place/dismantle on a single-body assembly: mutate colliders in place instead
## of destroying the RigidBody (avoids parking-bristle + contact graph storms on
## large powered rovers). Multibody / actuator topology still full-reprojects.
func _try_append_placed_element(
	assembly_id: int,
	element_id: int
) -> bool:
	var fail_reason := &""
	if _world == null or element_id <= 0 or _element_records.has(element_id):
		fail_reason = &"already_projected_or_bad_id"
	elif _assembly_group_bodies.has(assembly_id):
		return _try_append_multibody_element(assembly_id, element_id)
	elif _mounted_bodies.has(assembly_id):
		fail_reason = &"mounted"
	var assembly: SimulationAssembly = null
	var body: PhysicsBody3D = null
	if fail_reason == &"":
		assembly = _world.get_assembly_raw(assembly_id)
		body = get_physics_body(assembly_id)
		if (
			assembly == null
			or assembly.tombstoned
			or body == null
			or not (body is RigidBody3D)
		):
			fail_reason = &"not_rigid_body"
	var compiled: Dictionary = {}
	if fail_reason == &"":
		compiled = _compile_assembly_groups(assembly)
		if not bool(compiled.get("valid", false)):
			fail_reason = &"compile_invalid"
		elif not (compiled.get("driven_specs", []) as Array).is_empty():
			fail_reason = &"driven_specs"
	var element: SimulationElement = null
	if fail_reason == &"":
		element = _world.get_element(element_id)
		if element == null or element.assembly_id != assembly_id:
			fail_reason = &"bad_element"
	var records: Array[Dictionary] = []
	if fail_reason == &"":
		records = PistonProjectionUtil.build_collision_shapes_for_elements(
			_world,
			assembly,
			[element_id] as Array[int]
		)
		if records.is_empty():
			fail_reason = &"empty_colliders"
	if fail_reason != &"":
		return false
	WheelSimulationService.invalidate_park_anchors(_world, assembly_id)
	_attach_colliders_to_body(
		body,
		records,
		assembly_id,
		[element_id] as Array[int]
	)
	_refresh_single_body_mass_com(assembly_id, body as RigidBody3D, assembly)
	_sync_wheel_loco_body_physics(assembly_id, body as RigidBody3D)
	_projected_revision[assembly_id] = assembly.topology_revision
	return true

## Non-topological place on a multibody assembly: the new element joined an
## existing rigid group, so its colliders attach to that group body in place.
## No body teardown and no joint rebuild — an extended/sagged actuator chain
## keeps its live pose and solver warm-start untouched.
func _try_append_multibody_element(
	assembly_id: int,
	element_id: int
) -> bool:
	if _mounted_bodies.has(assembly_id):
		return false
	var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return false
	var compiled := _compile_assembly_groups(assembly)
	if not bool(compiled.get("valid", false)):
		return false
	if not _multibody_topology_matches(assembly_id, compiled):
		return false
	var group_id := int(
		(compiled.get("element_to_group", {}) as Dictionary).get(element_id, 0)
	)
	var groups_map: Dictionary = _assembly_group_bodies.get(assembly_id, {})
	var body: PhysicsBody3D = groups_map.get(group_id) as PhysicsBody3D
	if group_id <= 0 or body == null or not is_instance_valid(body):
		return false
	var records: Array[Dictionary] = (
		PistonProjectionUtil.build_collision_shapes_for_elements(
			_world,
			assembly,
			[element_id] as Array[int]
		)
	)
	if records.is_empty():
		return false
	WheelSimulationService.invalidate_park_anchors(_world, assembly_id)
	_attach_colliders_to_body(
		body,
		records,
		assembly_id,
		[element_id] as Array[int]
	)
	_refresh_group_body_mass_com(
		assembly,
		body,
		(compiled.get("groups", {}) as Dictionary).get(group_id, [])
	)
	_append_element_to_carriage_records(assembly_id, body, element_id)
	_projected_revision[assembly_id] = assembly.topology_revision
	return true

## True when the compiled topology matches what is currently projected: same
## rigid group ids, same root and same driven joints — i.e. the edit stayed
## inside one existing group.
func _multibody_topology_matches(
	assembly_id: int,
	compiled: Dictionary
) -> bool:
	var groups_map: Dictionary = _assembly_group_bodies.get(assembly_id, {})
	var compiled_groups: Dictionary = compiled.get("groups", {})
	if groups_map.size() != compiled_groups.size():
		return false
	for group_id_variant: Variant in compiled_groups:
		if not groups_map.has(int(group_id_variant)):
			return false
	if int(compiled.get("root_group_id", 0)) != int(
		_root_group_ids.get(assembly_id, 0)
	):
		return false
	var projected_joint_ids: Dictionary = {}
	for record_variant: Variant in _piston_constraints.get(assembly_id, []):
		if record_variant is Dictionary:
			projected_joint_ids[
				int((record_variant as Dictionary).get("joint_id", 0))
			] = true
	for record_variant: Variant in _rotor_constraints.get(assembly_id, []):
		if record_variant is Dictionary:
			projected_joint_ids[
				int((record_variant as Dictionary).get("joint_id", 0))
			] = true
	var specs: Array = compiled.get("driven_specs", [])
	if specs.size() != projected_joint_ids.size():
		return false
	for spec_variant: Variant in specs:
		if not spec_variant is Dictionary:
			return false
		if not projected_joint_ids.has(
			int((spec_variant as Dictionary).get("joint_id", 0))
		):
			return false
	return true

func _refresh_group_body_mass_com(
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
		PistonProjectionUtil.dry_mass_for_elements(_world, element_ids),
		MIN_MASS
	)
	rigid.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	rigid.center_of_mass = (
		PistonProjectionUtil.center_of_mass_local_for_records(
			PistonProjectionUtil.build_collision_shapes_for_elements(
				_world,
				assembly,
				element_ids
			)
		)
	)

## Keep piston carriage element lists fresh so load estimates and sustained
## impact strikers see blocks welded onto the carriage after projection.
func _append_element_to_carriage_records(
	assembly_id: int,
	group_body: PhysicsBody3D,
	element_id: int
) -> void:
	for record_variant: Variant in _piston_constraints.get(assembly_id, []):
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		if record.get("head_body") != group_body:
			continue
		var carriage: Array = record.get("carriage_element_ids", [])
		if not carriage.has(element_id):
			carriage.append(element_id)
			record["carriage_element_ids"] = carriage

func _try_remove_projected_element(
	assembly_id: int,
	element_id: int
) -> bool:
	if _world == null or element_id <= 0:
		return false
	if _assembly_group_bodies.has(assembly_id) or _mounted_bodies.has(assembly_id):
		return false
	var assembly := _world.get_assembly_raw(assembly_id)
	var body := get_physics_body(assembly_id)
	if (
		assembly == null
		or assembly.tombstoned
		or body == null
		or not (body is RigidBody3D)
	):
		return false
	var compiled := _compile_assembly_groups(assembly)
	if (
		not bool(compiled.get("valid", false))
		or not (compiled.get("driven_specs", []) as Array).is_empty()
	):
		return false
	var record: Variant = _element_records.get(element_id)
	if not record is Dictionary:
		return false
	var colliders: Array = (record as Dictionary).get("colliders", [])
	for collider_variant: Variant in colliders:
		if collider_variant is CollisionShape3D and is_instance_valid(collider_variant):
			var collider := collider_variant as CollisionShape3D
			collider.disabled = true
			collider.queue_free()
	_element_records.erase(element_id)
	WheelSimulationService.invalidate_park_anchors(_world, assembly_id)
	_refresh_single_body_mass_com(assembly_id, body as RigidBody3D, assembly)
	_sync_wheel_loco_body_physics(assembly_id, body as RigidBody3D)
	_projected_revision[assembly_id] = assembly.topology_revision
	return true

func _refresh_single_body_mass_com(
	assembly_id: int,
	rigid: RigidBody3D,
	assembly: SimulationAssembly
) -> void:
	if rigid == null or assembly == null:
		return
	rigid.mass = maxf(
		ColliderProjectionUtil.assembly_dry_mass(_world, assembly),
		MIN_MASS
	)
	rigid.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	rigid.center_of_mass = ColliderProjectionUtil.assembly_center_of_mass_local(
		_world,
		assembly
	)
	rigid.inertia = Vector3.ZERO
	# Quiet residual motion after COM shift so parking bristle can re-seat.
	var locomotion := _world.get_locomotion_controller(assembly_id)
	if locomotion != null and locomotion.is_parking_brake():
		rigid.linear_velocity = Vector3.ZERO
		rigid.angular_velocity = Vector3.ZERO

func _reproject_assembly(assembly_id: int) -> void:
	# Capture per-element live poses BEFORE teardown. Multibody rebuild used to
	# call _capture_live_group_motions after _remove_body — always empty — so
	# cutting an extended piston snapped survivors to home grid pose.
	var live_capture := _capture_live_element_motions(assembly_id)
	var body := get_physics_body(assembly_id)
	var motion: AssemblyMotionState = (
		_capture_body_motion(body)
		if body != null
		else null
	)
	WheelSimulationService.invalidate_park_anchors(_world, assembly_id)
	_remove_body(assembly_id)
	_project_assembly(assembly_id, motion, live_capture)

func _handle_split(event: Dictionary) -> void:
	var survivor_id: int = int(event["survivor_assembly_id"])
	var parent_body: PhysicsBody3D = get_physics_body(survivor_id)
	var parent_motion := AssemblyMotionState.new()
	var parent_com_world := Vector3.ZERO
	var parent_body_id := 0
	var live_capture := _capture_live_element_motions(survivor_id)
	if parent_body != null:
		parent_motion = _capture_body_motion(parent_body)
		parent_com_world = _body_center_of_mass_world(parent_body)
		parent_body_id = parent_body.get_instance_id()
	var new_ids: Array[int] = []
	for mapping_variant: Variant in event.get("new_assemblies", []):
		if mapping_variant is Dictionary:
			new_ids.append(int(mapping_variant["assembly_id"]))
	_remove_body(survivor_id)
	for assembly_id: int in new_ids:
		_project_split_child(
			assembly_id,
			parent_motion,
			parent_com_world,
			parent_body_id,
			live_capture
		)
	_project_split_child(
		survivor_id,
		parent_motion,
		parent_com_world,
		parent_body_id,
		live_capture
	)

func _project_split_child(
	assembly_id: int,
	parent_motion: AssemblyMotionState,
	parent_com_world: Vector3,
	parent_body_id: int = 0,
	live_capture: Dictionary = {}
) -> void:
	var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	var motion := _seed_motion_for_split_child(
		assembly,
		parent_motion,
		parent_com_world,
		parent_body_id,
		live_capture
	)
	_project_assembly(assembly_id, motion, live_capture)


## Prefer the live pose of any element that still belongs to this child.
## Same rigid body as the pre-split root → COM velocity inheritance.
## Distinct body (extended carriage) → keep that body's transform and velocity.
func _seed_motion_for_split_child(
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
	if _world.assembly_has_anchor(assembly.assembly_id):
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
	return motion

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
	if _mounted_bodies.has(survivor_id) and survivor_body != null:
		survivor_motion = _capture_body_motion(survivor_body)
		survivor_motion.frozen = false
		return survivor_motion
	if survivor_body == null or loser_body == null:
		survivor_motion.frozen = false
		return survivor_motion
	var loser_motion: AssemblyMotionState = _capture_body_motion(loser_body)
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
	motion_override: AssemblyMotionState,
	live_capture: Dictionary = {}
) -> void:
	var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		_remove_body(assembly_id)
		return
	if (
		motion_override == null
		and live_capture.is_empty()
		and _projected_revision.get(assembly_id, -1)
		== assembly.topology_revision
		and get_physics_body(assembly_id) != null
	):
		return
	var compiled := _compile_assembly_groups(assembly)
	var driven_specs: Array = compiled.get("driven_specs", [])
	if (
		bool(compiled.get("valid", false))
		and not driven_specs.is_empty()
		and not _mounted_bodies.has(assembly_id)
	):
		_project_assembly_multibody(
			assembly_id,
			motion_override,
			compiled,
			live_capture
		)
		return
	_project_assembly_single(assembly_id, motion_override)

func _project_assembly_single(
	assembly_id: int,
	motion_override: AssemblyMotionState
) -> void:
	var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		_remove_body(assembly_id)
		return
	var seed_motion: AssemblyMotionState = (
		motion_override
		if motion_override != null
		else assembly.motion
	)
	var active_locomotive := _is_active_locomotive(assembly_id)
	var locomotion := _world.get_locomotion_controller(assembly_id)
	var release_from_anchor := (
		active_locomotive
		and seed_motion.frozen
		and _world.assembly_has_anchor(assembly_id)
		and not _mounted_bodies.has(assembly_id)
		and not locomotion.has_released_from_anchor()
	)
	var anchored: bool = (
		_world.assembly_has_anchor(assembly_id)
		and not active_locomotive
		and not locomotion.has_released_from_anchor()
	)
	var mounted: RigidBody3D = _mounted_bodies.get(assembly_id) as RigidBody3D
	var mounted_motion: AssemblyMotionState = null
	var body: PhysicsBody3D
	if mounted != null:
		mounted_motion = _capture_body_motion(mounted)
		if motion_override == null:
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
		if _should_disable_wheel_module_collider(assembly_id, element_id):
			collider.disabled = true
		body.add_child(collider)
		if not colliders_by_element.has(element_id):
			colliders_by_element[element_id] = []
		colliders_by_element[element_id].append(collider)
	var motion: AssemblyMotionState = seed_motion.duplicate_state()
	if release_from_anchor:
		motion.transform.origin += (
			motion.transform.basis.y.normalized()
			* ThrusterSimulationService.activation_clearance_m(
				_world,
				assembly_id
			)
		)
		locomotion.mark_released_from_anchor()
	if active_locomotive:
		motion.frozen = false
		motion.sleeping = false
	elif anchored:
		motion.frozen = true
		motion.linear_velocity = Vector3.ZERO
		motion.angular_velocity = Vector3.ZERO
		motion.sleeping = true
	elif _is_locomotive_assembly(assembly_id):
		# Floating mobile: dynamic; wheels use parking_brake, flight uses thrust.
		if not locomotion.has_released_from_anchor():
			motion.transform.origin += (
				motion.transform.basis.y.normalized()
				* ThrusterSimulationService.activation_clearance_m(
					_world,
					assembly_id
				)
			)
			locomotion.mark_released_from_anchor()
		motion.frozen = false
		motion.sleeping = false
	else:
		motion.frozen = seed_motion.frozen
		if motion_override != null:
			motion.sleeping = seed_motion.sleeping
	if mounted == null:
		add_child(body)
		body.global_transform = motion.transform
	else:
		if motion_override == null:
			motion = mounted_motion
		else:
			motion.transform = mounted_motion.transform
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
			rigid.freeze = false if motion_override != null else motion.frozen
		else:
			rigid.freeze = motion.frozen
		if (
			_impact_service != null
			and mounted == null
			and not anchored
		):
			_impact_service.configure_impact_body(
				rigid,
				ImpactResolverService.ImpactBodyMode.FULL
			)
		_apply_locomotive_rigid_tuning(assembly_id, rigid)
	_bodies[assembly_id] = body
	for element_id: int in colliders_by_element:
		_element_records[element_id] = {
			"assembly_id": assembly_id,
			"body": body,
			"colliders": colliders_by_element[element_id],
		}
	_world.sync_assembly_motion(assembly_id, motion)
	_projected_revision[assembly_id] = assembly.topology_revision

func _project_assembly_multibody(
	assembly_id: int,
	motion_override: AssemblyMotionState,
	compiled: Dictionary,
	live_capture: Dictionary = {}
) -> void:
	var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	# Live poses/velocities of surviving groups must ride across the rebuild:
	# reconstruction from motor state snaps sagged/flexed joints to their
	# idealized pose and kicks the whole chain on every placed block.
	# Prefer caller-captured element motions (reproject/split tear down bodies
	# first); fall back to an in-place group capture when bodies still exist.
	var live_group_motions: Dictionary = (
		_remap_element_motions_to_groups(assembly_id, live_capture)
		if not live_capture.is_empty()
		else _capture_live_group_motions(assembly_id)
	)
	_remove_body(assembly_id)
	var groups: Dictionary = compiled["groups"]
	var root_group_id := int(compiled.get("root_group_id", 0))
	live_group_motions.erase(root_group_id)
	var source_motion: AssemblyMotionState = (
		motion_override
		if motion_override != null
		else assembly.motion
	)
	var seed_motion := source_motion.duplicate_state()
	var active_locomotive := _is_active_locomotive(assembly_id)
	var locomotion := _world.get_locomotion_controller(assembly_id)
	if (
		active_locomotive
		and seed_motion.frozen
		and _world.assembly_has_anchor(assembly_id)
		and not locomotion.has_released_from_anchor()
	):
		seed_motion.transform.origin += (
			seed_motion.transform.basis.y.normalized()
			* ThrusterSimulationService.activation_clearance_m(
				_world,
				assembly_id
			)
		)
		seed_motion.frozen = false
		seed_motion.sleeping = false
		locomotion.mark_released_from_anchor()
	_world.sync_assembly_motion(assembly_id, seed_motion)
	assembly.clear_body_group_motions()
	var group_motions: Dictionary = (
		BodyGroupMotionUtilScript.reconstruct_all_group_motions(
			_world,
			assembly_id,
			live_group_motions
		)
	)
	var groups_map: Dictionary = {}
	var carriage_group_ids: Dictionary = {}
	for spec_variant: Variant in compiled.get("driven_specs", []):
		if spec_variant is Dictionary:
			carriage_group_ids[int(spec_variant.get("head_group_id", 0))] = true
	for group_id: int in _sorted_int_keys(groups):
		var members: Array = groups[group_id]
		var element_ids: Array[int] = []
		for member_variant: Variant in members:
			element_ids.append(int(member_variant))
		var is_root := group_id == root_group_id
		var is_static := (
			is_root
			and _world.assembly_has_anchor(assembly_id)
			and not active_locomotive
		)
		var is_carriage := carriage_group_ids.has(group_id)
		var body := _create_group_body(assembly_id, group_id, is_static)
		var records: Array[Dictionary] = (
			PistonProjectionUtil.build_collision_shapes_for_elements(
				_world,
				assembly,
				element_ids
			)
		)
		_attach_colliders_to_body(
			body,
			records,
			assembly_id,
			element_ids
		)
		var group_motion: AssemblyMotionState = group_motions.get(group_id)
		if group_motion == null:
			group_motion = seed_motion
		body.global_transform = group_motion.transform
		if body is RigidBody3D:
			var rigid: RigidBody3D = body as RigidBody3D
			rigid.mass = maxf(
				PistonProjectionUtil.dry_mass_for_elements(
					_world,
					element_ids
				),
				MIN_MASS
			)
			rigid.center_of_mass_mode = (
				RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
			)
			rigid.center_of_mass = (
				PistonProjectionUtil.center_of_mass_local_for_records(
					records
				)
			)
			if is_static:
				rigid.linear_velocity = Vector3.ZERO
				rigid.angular_velocity = Vector3.ZERO
				rigid.sleeping = true
				rigid.freeze = true
			else:
				rigid.linear_velocity = group_motion.linear_velocity
				rigid.angular_velocity = group_motion.angular_velocity
				rigid.sleeping = group_motion.sleeping
				rigid.freeze = false
				# Impact bodies never enable custom_integrator (Jolt would
				# drop piston forces); carriage keeps the signal-based mode.
				if _impact_service != null:
					var impact_mode := (
						ImpactResolverService.ImpactBodyMode.MONITOR_ONLY
						if is_carriage
						else ImpactResolverService.ImpactBodyMode.FULL
					)
					_impact_service.configure_impact_body(rigid, impact_mode)
				_apply_locomotive_rigid_tuning(assembly_id, rigid)
		add_child(body)
		_apply_collision_profile(assembly_id, body)
		_apply_body_groups(assembly_id, body)
		groups_map[group_id] = body
		_world.sync_assembly_body_group_motion(
			assembly_id,
			group_id,
			group_motion
		)

	_assembly_group_bodies[assembly_id] = groups_map
	_root_group_ids[assembly_id] = root_group_id
	if root_group_id > 0 and groups_map.has(root_group_id):
		_bodies[assembly_id] = groups_map[root_group_id]

	var piston_records: Array[Dictionary] = []
	var rotor_records: Array[Dictionary] = []
	for spec_variant: Variant in compiled.get("driven_specs", []):
		if not spec_variant is Dictionary:
			continue
		var spec: Dictionary = spec_variant
		var sim_joint: SimulationJoint = _world.get_joint(
			int(spec.get("joint_id", 0))
		)
		if sim_joint == null or sim_joint.motor == null:
			continue
		var base_body: PhysicsBody3D = (
			groups_map.get(int(spec.get("base_group_id", 0))) as PhysicsBody3D
		)
		var head_body: PhysicsBody3D = (
			groups_map.get(int(spec.get("head_group_id", 0))) as PhysicsBody3D
		)
		if base_body == null or head_body == null:
			continue
		var base_element: SimulationElement = _world.get_element(
			int(spec.get("base_element_id", 0))
		)
		var head_element: SimulationElement = _world.get_element(
			int(spec.get("head_element_id", 0))
		)
		if base_element == null or head_element == null:
			continue
		if sim_joint.kind == SimulationJoint.Kind.HINGE:
			var hinge_definition: HingeDefinition = (
				base_element.get_archetype().hinge_definition
			)
			if hinge_definition == null:
				continue
			var hinge_axis_local: Vector3 = (
				HingePlacementUtil.bend_axis_assembly_local(
					base_element,
					hinge_definition
				)
			)
			var hinge_axis_world: Vector3 = (
				base_body.global_transform.basis * hinge_axis_local
			).normalized()
			var hinge_pivot: Vector3 = (
				HingePlacementUtil.pivot_assembly_local(
					base_element,
					hinge_definition
				)
			)
			var hinge_joint_node := Generic6DOFJoint3D.new()
			hinge_joint_node.name = "%s%d_%d" % [
				HINGE_JOINT_NAME_PREFIX,
				assembly_id,
				sim_joint.joint_id,
			]
			add_child(hinge_joint_node)
			hinge_joint_node.global_transform = Transform3D(
				HingeProjectionUtil.basis_with_x_axis(hinge_axis_world),
				base_body.global_transform * hinge_pivot
			)
			hinge_joint_node.node_a = hinge_joint_node.get_path_to(base_body)
			hinge_joint_node.node_b = hinge_joint_node.get_path_to(head_body)
			# Jolt rest angle is the create pose; motor angle is home-relative.
			var hinge_create_measured: Dictionary = (
				RotorProjectionUtil.measure_angular_state(
					base_body,
					head_body,
					hinge_axis_world
				)
			)
			var hinge_angle_offset := float(
				hinge_create_measured.get("angle_rad", 0.0)
			)
			HingeProjectionUtil.configure_hinge_limit_joint(
				hinge_joint_node,
				sim_joint.motor,
				hinge_angle_offset
			)
			# Hinge shares the rotor's angular record shape and tick loop.
			rotor_records.append({
				"joint_id": sim_joint.joint_id,
				"sim_joint": sim_joint,
				"constraint": hinge_joint_node,
				"base_body": base_body,
				"head_body": head_body,
				"axis_local": hinge_axis_local,
				"angle_offset_rad": hinge_angle_offset,
				"top_element_ids": groups.get(
					int(spec.get("head_group_id", 0)),
					[]
				),
			})
			continue
		if sim_joint.kind == SimulationJoint.Kind.ROTOR:
			var rotor_definition: RotorDefinition = (
				base_element.get_archetype().rotor_definition
			)
			if rotor_definition == null:
				continue
			var rotor_axis_local: Vector3 = (
				RotorProjectionUtil.rotor_axis_assembly_local(
					base_element,
					rotor_definition
				)
			)
			var rotor_axis_world: Vector3 = (
				base_body.global_transform.basis * rotor_axis_local
			).normalized()
			var rotor_anchor: Vector3 = (
				PistonProjectionUtil.port_anchor_assembly_local(
					base_element,
					SimulationMotorState.ROTOR_DRIVE_PORT
				)
			)
			var rotor_joint_node := Generic6DOFJoint3D.new()
			rotor_joint_node.name = "%s%d_%d" % [
				ROTOR_JOINT_NAME_PREFIX,
				assembly_id,
				sim_joint.joint_id,
			]
			add_child(rotor_joint_node)
			rotor_joint_node.global_transform = Transform3D(
				PistonProjectionUtil.basis_from_axis(rotor_axis_world),
				base_body.global_transform * rotor_anchor
			)
			rotor_joint_node.node_a = rotor_joint_node.get_path_to(base_body)
			rotor_joint_node.node_b = rotor_joint_node.get_path_to(head_body)
			RotorProjectionUtil.configure_hinge_joint(rotor_joint_node)
			rotor_records.append({
				"joint_id": sim_joint.joint_id,
				"sim_joint": sim_joint,
				"constraint": rotor_joint_node,
				"base_body": base_body,
				"head_body": head_body,
				"axis_local": rotor_axis_local,
				"top_element_ids": groups.get(
					int(spec.get("head_group_id", 0)),
					[]
				),
			})
			continue
		var definition: PistonDefinition = (
			base_element.get_archetype().piston_definition
		)
		if definition == null:
			continue
		var axis_local: Vector3 = (
			PistonProjectionUtil.piston_axis_assembly_local(
				base_element,
				definition
			)
		)
		var axis_world: Vector3 = (
			base_body.global_transform.basis * axis_local
		).normalized()
		var base_anchor: Vector3 = (
			PistonProjectionUtil.port_anchor_assembly_local(
				base_element,
				SimulationMotorState.PISTON_DRIVE_PORT
			)
		)
		var head_anchor: Vector3 = (
			PistonProjectionUtil.port_anchor_assembly_local(
				head_element,
				SimulationMotorState.PISTON_CARRIAGE_PORT
			)
		)
		var joint_node := Generic6DOFJoint3D.new()
		joint_node.name = "%s%d_%d" % [
			PISTON_JOINT_NAME_PREFIX,
			assembly_id,
			sim_joint.joint_id,
		]
		add_child(joint_node)
		joint_node.global_transform = Transform3D(
			PistonProjectionUtil.basis_from_axis(axis_world),
			base_body.global_transform * base_anchor
		)
		joint_node.node_a = joint_node.get_path_to(base_body)
		joint_node.node_b = joint_node.get_path_to(head_body)
		var base_archetype: ElementArchetype = (
			base_element.get_archetype() if base_element != null else null
		)
		var spawn_operational := (
			base_element != null and base_element.is_operational()
		)
		var compliance := PistonProjectionUtil.runtime_angular_compliance(
			(
				base_archetype.piston_definition
				if base_archetype != null
				else null
			),
			spawn_operational
		)
		# Absolute travel at bind (= reconstruct pose). Limits are offset so a
		# reproject while extended cannot stack another full upper_limit_m.
		var bind_extension := sim_joint.motor.clamp_observed_position()
		# Incomplete pistons park at current extension (usually home).
		var spawn_lock := bind_extension if not spawn_operational else NAN
		PistonProjectionUtil.configure_slider_joint(
			joint_node,
			sim_joint.motor,
			compliance,
			spawn_lock,
			bind_extension
		)
		piston_records.append({
			"joint_id": sim_joint.joint_id,
			"sim_joint": sim_joint,
			"constraint": joint_node,
			"base_body": base_body,
			"head_body": head_body,
			"base_anchor_local": base_anchor,
			"head_anchor_local": head_anchor,
			"axis_local": axis_local,
			"bind_extension_m": bind_extension,
			"angular_compliance": compliance,
			"cfg_operational": spawn_operational,
			"cfg_flex": spawn_operational,
			"cfg_limits": Vector2(
				sim_joint.motor.lower_limit_m,
				sim_joint.motor.upper_limit_m
			),
			"motor_target_v": 0.0,
			"motor_limit_n": sim_joint.motor.force_limit_n,
			"carriage_element_ids": groups.get(
				int(spec.get("head_group_id", 0)),
				[]
			),
		})
	_piston_constraints[assembly_id] = piston_records
	_rotor_constraints[assembly_id] = rotor_records
	var motion: AssemblyMotionState = seed_motion.duplicate_state()
	if _world.assembly_has_anchor(assembly_id):
		if not active_locomotive:
			motion.frozen = true
			motion.linear_velocity = Vector3.ZERO
			motion.angular_velocity = Vector3.ZERO
			motion.sleeping = true
	_world.sync_assembly_motion(assembly_id, motion)
	_projected_revision[assembly_id] = assembly.topology_revision

func _compile_assembly_groups(
	assembly: SimulationAssembly
) -> Dictionary:
	return _world.compile_body_groups(assembly.assembly_id)

func _create_group_body(
	assembly_id: int,
	group_id: int,
	is_static: bool
) -> PhysicsBody3D:
	var body: PhysicsBody3D
	if is_static:
		body = StaticBody3D.new()
	else:
		var rigid := FragmentBodyScript.new() as RigidBody3D
		rigid.physics_material_override = _get_assembly_physics_material()
		body = rigid
	body.name = "%s%d_%d" % [
		GROUP_BODY_NAME_PREFIX,
		assembly_id,
		group_id,
	]
	body.collision_layer = COLLISION_LAYER_ASSEMBLY
	body.collision_mask = COLLISION_MASK_ASSEMBLY
	body.set_meta("assembly_id", assembly_id)
	body.set_meta("body_group_id", group_id)
	return body

func _attach_colliders_to_body(
	body: PhysicsBody3D,
	records: Array[Dictionary],
	assembly_id: int,
	element_ids: Array[int]
) -> void:
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
		if _should_disable_wheel_module_collider(assembly_id, element_id):
			collider.disabled = true
		body.add_child(collider)
		if not colliders_by_element.has(element_id):
			colliders_by_element[element_id] = []
		colliders_by_element[element_id].append(collider)
	for element_id: int in element_ids:
		if not colliders_by_element.has(element_id):
			continue
		_element_records[element_id] = {
			"assembly_id": assembly_id,
			"body": body,
			"colliders": colliders_by_element[element_id],
		}

func _is_locomotive_assembly(assembly_id: int) -> bool:
	if _world == null:
		return false
	return ThrusterSimulationService.is_mobile_assembly(_world, assembly_id)

func _is_active_locomotive(assembly_id: int) -> bool:
	return (
		_is_locomotive_assembly(assembly_id)
		and _world.get_locomotion_controller(assembly_id).is_activated()
	)

## A parked rover held only by per-frame bristle/suspension forces never
## sleeps: wheel raycasts, spring forces and terrain contacts grind every
## physics frame forever. Once it has settled under the parking brake, freeze
## the body (static pose, zero per-frame cost) and stop ticking wheels.
## Wake paths: driver input / brake release (here), seat entry
## (gateway._wake_rover_body), terrain digs nearby (wake_frozen_near).
func _update_parking_freeze(assembly_id: int) -> void:
	if (
		_world == null
		or not WheelSimulationService.is_locomotive_assembly(_world, assembly_id)
	):
		return
	var body := get_physics_body(assembly_id)
	if body is not RigidBody3D:
		return
	var rigid := body as RigidBody3D
	var locomotion := _world.get_locomotion_controller(assembly_id)
	if locomotion == null:
		return
	# Brake command does not block freezing: the seat-exit flow keeps
	# brake_command at 1.0 while parked, and "braking while already still"
	# is exactly the state we want to freeze.
	var parked := (
		locomotion.is_parking_brake()
		and absf(locomotion.drive_command) <= 0.001
		and absf(locomotion.steering_command) <= 0.001
		and locomotion.translate_magnitude() <= 0.001
		and absf(locomotion.pitch_command) <= 0.001
		and absf(locomotion.yaw_command) <= 0.001
		and absf(locomotion.roll_command) <= 0.001
	)
	if rigid.freeze:
		if not parked:
			rigid.freeze = false
			rigid.sleeping = false
			_park_settle_frames[assembly_id] = 0
		return
	if not parked:
		_park_settle_frames[assembly_id] = 0
		return
	var eps := AssemblyLocomotionController.PARKING_BRAKE_SPEED_EPS
	if (
		rigid.linear_velocity.length() >= eps
		or rigid.angular_velocity.length() >= eps
	):
		_park_settle_frames[assembly_id] = 0
		return
	var settled := int(_park_settle_frames.get(assembly_id, 0)) + 1
	_park_settle_frames[assembly_id] = settled
	if settled < PARK_FREEZE_SETTLE_FRAMES:
		return
	rigid.linear_velocity = Vector3.ZERO
	rigid.angular_velocity = Vector3.ZERO
	rigid.freeze = true


## Frozen parked vehicles must not keep floating when the ground under them
## is dug away — unfreeze anything frozen near a terrain edit and let physics
## re-settle it.
func wake_frozen_near(center: Vector3, radius: float) -> void:
	for assembly_id: int in _sorted_int_keys(_bodies):
		var body := get_physics_body(assembly_id)
		if body is not RigidBody3D:
			continue
		var rigid := body as RigidBody3D
		if not rigid.freeze:
			continue
		if not WheelSimulationService.is_locomotive_assembly(_world, assembly_id):
			continue
		if rigid.global_position.distance_to(center) > radius + WAKE_DIG_MARGIN_M:
			continue
		rigid.freeze = false
		rigid.sleeping = false
		_park_settle_frames[assembly_id] = 0


func _should_tick_wheels(assembly_id: int) -> bool:
	if (
		_world == null
		or not WheelSimulationService.is_locomotive_assembly(_world, assembly_id)
	):
		return false
	var rigid: RigidBody3D = null
	var body := get_physics_body(assembly_id)
	if body is RigidBody3D:
		rigid = body as RigidBody3D
	else:
		var groups: Variant = _assembly_group_bodies.get(assembly_id)
		if groups is Dictionary:
			for body_variant: Variant in (groups as Dictionary).values():
				if body_variant is RigidBody3D:
					rigid = body_variant as RigidBody3D
					break
	# Wheel/suspension solid colliders are disabled — raycast springs are the
	# only support until park-freeze. Never skip the tick for a free body.
	return rigid != null and not rigid.freeze

func _tick_wheel_pairs(delta: float) -> void:
	if _world == null or delta <= 0.0:
		return
	for assembly_id: int in _sorted_int_keys(_bodies):
		_update_parking_freeze(assembly_id)
		if not _should_tick_wheels(assembly_id):
			continue
		WheelSimulationService.tick_assembly(
			_world,
			assembly_id,
			delta,
			Callable(self, "_wheel_body_for_suspension"),
			_wheel_exclude_rids(assembly_id)
		)

func _tick_thrusters(delta: float) -> void:
	if _world == null or delta <= 0.0:
		return
	for assembly_id: int in _sorted_int_keys(_bodies):
		if not ThrusterSimulationService.is_flight_assembly(_world, assembly_id):
			continue
		var locomotion := _world.get_locomotion_controller(assembly_id)
		if not locomotion.is_activated():
			continue
		var thrusters := ThrusterSimulationService.list_thruster_elements(
			_world,
			assembly_id
		)
		for thruster: SimulationElement in thrusters:
			_apply_thruster_force(thruster, locomotion)
		var gyros := ThrusterSimulationService.list_gyro_elements(
			_world,
			assembly_id
		)
		var gyro_count := gyros.size()
		if gyro_count <= 0:
			continue
		for gyro: SimulationElement in gyros:
			_apply_gyro_torque(gyro, locomotion, gyro_count)

## Rope shape: one verlet step per rope, so cables drape over the world instead
## of passing through it. Runs before tension — the pull direction comes from
## the solved rope, not from the straight line between the anchors.
func _tick_cable_ropes(delta: float) -> void:
	if _world == null or delta <= 0.0:
		return
	var ropes: Array[IndustryElectricLink] = []
	for link: IndustryElectricLink in _world.get_industry_network().list_links():
		if link.is_rope():
			ropes.append(link)
	if ropes.is_empty():
		_rope_states = {}
		return
	var space_state := get_world_3d().direct_space_state
	# Collision is one shape query per particle per tick, so it runs on a
	# budget. A rope past the budget still integrates and holds its length this
	# tick; the rotating start makes sure it is a different rope every time and
	# not always the last one in the list that goes without.
	var collision_budget := CABLE_ROPE_COLLISION_BUDGET
	_rope_collision_cursor = (_rope_collision_cursor + 1) % ropes.size()
	var live: Dictionary = {}
	for offset: int in range(ropes.size()):
		var link: IndustryElectricLink = ropes[
			(offset + _rope_collision_cursor) % ropes.size()
		]
		var anchor_a := CableAnchorUtil.endpoint_world_position(
			_world,
			link.element_a,
			link.port_a,
			link.attach_a
		)
		var anchor_b := CableAnchorUtil.endpoint_world_position(
			_world,
			link.element_b,
			link.port_b,
			link.attach_b
		)
		var gravity := GravityField.resolve_gravity_accel(
			self,
			(anchor_a + anchor_b) * 0.5
		)
		var state: Variant = _rope_states.get(link.link_id)
		if not state is Dictionary:
			state = CableRopeSolver.create_state(
				anchor_a,
				anchor_b,
				link.rest_length_m,
				-gravity.normalized() if gravity.length_squared() > 0.0 else Vector3.UP,
				space_state
			)
		var particles := CableRopeSolver.path(state).size()
		var collides := space_state != null and collision_budget >= particles
		if collides:
			collision_budget -= particles
		CableRopeSolver.step(
			state,
			anchor_a,
			anchor_b,
			link.rest_length_m,
			gravity,
			delta,
			space_state if collides else null
		)
		live[link.link_id] = state
	_rope_states = live

## Solved rope path in world space for presentation. Empty when the rope has
## not been stepped yet — the caller falls back to the analytic curve.
func rope_path(link_id: int) -> PackedVector3Array:
	var state: Variant = _rope_states.get(link_id)
	if state is Dictionary:
		return CableRopeSolver.path(state)
	return PackedVector3Array()

## Ropes pull once they run out of slack, and snap when the pull is too hard.
## Runs after the actuators so a rope reacts to the same tick's motion.
func _tick_cable_tension(delta: float) -> void:
	if _world == null or delta <= 0.0:
		return
	var snapped: Array[int] = []
	for link: IndustryElectricLink in _world.get_industry_network().list_links():
		if not link.is_rope():
			continue
		var body_a := _rope_endpoint_body(link.element_a)
		var body_b := _rope_endpoint_body(link.element_b)
		if body_a == null and body_b == null:
			continue
		var anchor_a := CableAnchorUtil.endpoint_world_position(
			_world,
			link.element_a,
			link.port_a,
			link.attach_a
		)
		var anchor_b := CableAnchorUtil.endpoint_world_position(
			_world,
			link.element_b,
			link.port_b,
			link.attach_b
		)
		var tension_n := 0.0
		var state: Variant = _rope_states.get(link.link_id)
		if state is Dictionary:
			# Draped over a rock the rope runs longer than the straight span and
			# hits its limit sooner, and it pulls along its own first segment —
			# toward what it is draped over, not through it.
			tension_n = CableTensionUtil.solve_routed(
				anchor_a,
				body_a,
				CableRopeSolver.pull_direction(state, true),
				anchor_b,
				body_b,
				CableRopeSolver.pull_direction(state, false),
				CableRopeSolver.routed_length_m(state),
				link.rest_length_m,
				delta
			)
		else:
			tension_n = CableTensionUtil.solve(
				anchor_a,
				body_a,
				anchor_b,
				body_b,
				link.rest_length_m,
				delta
			)
		if tension_n > CableTensionUtil.break_force_n(link.break_force_n):
			snapped.append(link.link_id)
	for link_id: int in snapped:
		_world.disconnect_network(0, "", 0, "", link_id)

## A rope end hammered into the ground holds on to the ground, not to a point
## in space: dig it out and the anchor tears loose. Probed a few times a second
## — it is a shape query per anchored rope, and terrain never vanishes mid-tick.
func _tick_cable_anchors(delta: float) -> void:
	if _world == null:
		return
	_cable_anchor_probe_cooldown -= delta
	if _cable_anchor_probe_cooldown > 0.0:
		return
	_cable_anchor_probe_cooldown = CABLE_ANCHOR_PROBE_INTERVAL_S
	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return
	var torn: Array[int] = []
	for link: IndustryElectricLink in _world.get_industry_network().list_links():
		if not link.is_rope() or not link.has_world_endpoint():
			continue
		# Judge the anchor only while the machine end is live physics. Frozen or
		# unprojected means the player is elsewhere, and terrain collision that
		# far out is simply not streamed in — an unloaded chunk is not a hole.
		var machine_element_id := (
			link.element_a if link.element_a > 0 else link.element_b
		)
		var machine_body := _rope_endpoint_body(machine_element_id)
		if machine_body == null or machine_body.freeze:
			continue
		var anchor := (
			link.attach_b if link.element_b <= 0 else link.attach_a
		)
		if TerrainAnchorProbe.point_has_ground_support(
			space_state,
			anchor,
			CABLE_ANCHOR_PROBE_RADIUS
		):
			continue
		torn.append(link.link_id)
	for link_id: int in torn:
		_world.disconnect_network(0, "", 0, "", link_id)

func _rope_endpoint_body(element_id: int) -> RigidBody3D:
	if element_id <= 0:
		return null
	return get_element_projection(element_id).get("body") as RigidBody3D

func _apply_thruster_force(
	element: SimulationElement,
	locomotion: AssemblyLocomotionController
) -> void:
	var archetype := element.get_archetype()
	if archetype == null or archetype.thruster_definition == null:
		return
	var record := get_element_projection(element.element_id)
	var body := record.get("body") as RigidBody3D
	if body == null or body.freeze:
		return
	var powered := ThrusterSimulationService.is_element_powered(_world, element)
	var axis_local := ThrusterProjectionUtil.thrust_axis_local(
		archetype.thruster_definition,
		element.orientation_index
	)
	var velocity_local := (
		body.global_transform.basis.inverse() * body.linear_velocity
	)
	var throttle := ThrusterProjectionUtil.compute_thruster_throttle(
		axis_local,
		locomotion.translate_command,
		locomotion.is_dampeners(),
		velocity_local,
		powered
	)
	var thrust_n := ThrusterProjectionUtil.compute_thrust_n(
		archetype.thruster_definition,
		throttle,
		powered
	)
	if thrust_n <= 0.0:
		return
	var axis_world := (body.global_transform.basis * axis_local).normalized()
	body.sleeping = false
	# v0: central thrust keeps hop stable before nozzle torque / RCS tuning.
	body.apply_central_force(axis_world * thrust_n)

func _apply_gyro_torque(
	element: SimulationElement,
	locomotion: AssemblyLocomotionController,
	gyro_count: int
) -> void:
	var archetype := element.get_archetype()
	if archetype == null or archetype.gyro_definition == null:
		return
	var record := get_element_projection(element.element_id)
	var body := record.get("body") as RigidBody3D
	if body == null or body.freeze:
		return
	var powered := ThrusterSimulationService.is_element_powered(_world, element)
	var omega_local := body.global_transform.basis.inverse() * body.angular_velocity
	var torque_local := ThrusterProjectionUtil.compute_gyro_torque_local(
		archetype.gyro_definition,
		locomotion.pitch_command,
		locomotion.yaw_command,
		locomotion.roll_command,
		locomotion.is_dampeners(),
		omega_local,
		gyro_count,
		powered
	)
	if torque_local.length_squared() <= 0.0001:
		return
	body.sleeping = false
	body.apply_torque(body.global_transform.basis * torque_local)

func _wheel_body_for_suspension(
	suspension_element_id: int
) -> RigidBody3D:
	var record := get_element_projection(suspension_element_id)
	return record.get("body") as RigidBody3D

func _wheel_exclude_rids(assembly_id: int) -> Array[RID]:
	var result: Array[RID] = []
	var groups: Variant = _assembly_group_bodies.get(assembly_id)
	if groups is Dictionary:
		for body_variant: Variant in (groups as Dictionary).values():
			if body_variant is PhysicsBody3D:
				result.append((body_variant as PhysicsBody3D).get_rid())
		return result
	var body := get_physics_body(assembly_id)
	if body != null:
		result.append(body.get_rid())
	return result

func _tick_rotor_actuators(delta: float) -> void:
	if _world == null or delta <= 0.0:
		return
	for assembly_id: int in _sorted_int_keys(_rotor_constraints):
		var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
		if assembly == null or assembly.tombstoned:
			continue
		for record_variant: Variant in _rotor_constraints[assembly_id]:
			if not record_variant is Dictionary:
				continue
			var record: Dictionary = record_variant
			var sim_joint: SimulationJoint = record.get("sim_joint")
			if sim_joint == null or sim_joint.motor == null:
				continue
			var base_body: PhysicsBody3D = record.get("base_body")
			var head_body: PhysicsBody3D = record.get("head_body")
			if base_body == null or head_body == null:
				continue
			if sim_joint.kind == SimulationJoint.Kind.HINGE:
				# configure_actuator can retune angle limits on a live joint.
				# Only rewrite twist stops — full DOF reset every tick fights
				# Jolt warm-starting and amplifies stop explosions.
				var hinge_constraint: Generic6DOFJoint3D = (
					record.get("constraint") as Generic6DOFJoint3D
				)
				if hinge_constraint != null:
					HingeProjectionUtil.update_hinge_angle_limits(
						hinge_constraint,
						sim_joint.motor,
						float(record.get("angle_offset_rad", 0.0))
					)
			var axis_world: Vector3 = (
				base_body.global_transform.basis
				* record.get("axis_local", Vector3.UP)
			).normalized()
			var measured: Dictionary = RotorProjectionUtil.measure_angular_state(
				base_body,
				head_body,
				axis_world
			)
			var observed_angle := float(measured.get("angle_rad", 0.0))
			var observed_velocity := float(
				measured.get("relative_velocity_rad_s", 0.0)
			)
			var powered: bool = PistonProjectionUtil.is_piston_powered(
				_world,
				sim_joint.element_a_id
			)
			var drive: Dictionary = RotorProjectionUtil.solver_angular_drive(
				sim_joint.motor,
				powered,
				observed_angle
			)
			var drive_velocity := float(drive.get("velocity_rad_s", 0.0))
			var drive_limit_nm := float(drive.get("torque_limit_nm", 0.0))
			var constraint: Generic6DOFJoint3D = (
				record.get("constraint") as Generic6DOFJoint3D
			)
			var motor_axis: String = (
				"x" if sim_joint.kind == SimulationJoint.Kind.HINGE else "y"
			)
			if constraint != null and (
				drive_velocity != float(record.get("motor_target_v", NAN))
				or drive_limit_nm != float(record.get("motor_limit_n", NAN))
			):
				RotorProjectionUtil.update_angular_motor(
					constraint,
					motor_axis,
					drive_velocity,
					drive_limit_nm
				)
				record["motor_target_v"] = drive_velocity
				record["motor_limit_n"] = drive_limit_nm
			var gravity := GravityField.resolve_gravity_accel(
				self,
				(
					(head_body as Node3D).global_position
					if head_body is Node3D
					else Vector3.ZERO
				)
			)
			var anchor_world: Vector3 = (
				constraint.global_position
				if constraint != null
				else Vector3.ZERO
			)
			var effort: Dictionary = (
				RotorProjectionUtil.estimate_angular_drive_effort(
					sim_joint.motor,
					drive_velocity,
					observed_velocity,
					head_body,
					anchor_world,
					axis_world,
					gravity
				)
			)
			var sat_time := (
				float(record.get("sat_time_s", 0.0)) + delta
				if bool(effort.get("saturated", false))
				else 0.0
			)
			record["sat_time_s"] = sat_time
			var saturated := (
				sat_time >= PistonProjectionUtil.SATURATION_CONFIRM_S
			)
			var torque_nm := (
				sim_joint.motor.force_limit_n
				if saturated
				else float(effort.get("hold_nm", 0.0))
			)
			sim_joint.motor.applied_force_n = torque_nm
			sim_joint.motor.force_saturated = saturated
			_world.sync_actuator_observation(
				int(record.get("joint_id", 0)),
				observed_angle,
				observed_velocity,
				torque_nm,
				saturated
			)

func _tick_piston_actuators(delta: float) -> void:
	if _world == null or delta <= 0.0:
		return
	for assembly_id: int in _sorted_int_keys(_piston_constraints):
		var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
		if assembly == null or assembly.tombstoned:
			continue
		for record_variant: Variant in _piston_constraints[assembly_id]:
			if not record_variant is Dictionary:
				continue
			var record: Dictionary = record_variant
			var sim_joint: SimulationJoint = record.get("sim_joint")
			if sim_joint == null or sim_joint.motor == null:
				continue
			var base_body: PhysicsBody3D = record.get("base_body")
			var head_body: PhysicsBody3D = record.get("head_body")
			if base_body == null or head_body == null:
				continue
			# Axis must follow the piston base body group (hinge/rotor parent
			# may have rotated away from the assembly root basis).
			var axis_world: Vector3 = (
				base_body.global_transform.basis
				* record.get("axis_local", Vector3.UP)
			).normalized()
			var measured: Dictionary = PistonProjectionUtil.measure_axial_state(
				base_body,
				head_body,
				record.get("base_anchor_local", Vector3.ZERO),
				record.get("head_anchor_local", Vector3.ZERO),
				axis_world
			)
			var extension_m := float(measured.get("extension_m", 0.0))
			var relative_velocity_mps := float(
				measured.get("relative_velocity_mps", 0.0)
			)
			var powered: bool = PistonProjectionUtil.is_piston_powered(
				_world,
				sim_joint.element_a_id
			)
			var base_element := _world.get_element(sim_joint.element_a_id)
			var operational := (
				base_element != null and base_element.is_operational()
			)
			var constraint: Generic6DOFJoint3D = record.get("constraint")
			if constraint != null:
				_refresh_piston_constraint_config(
					record,
					constraint,
					sim_joint.motor,
					base_element,
					extension_m,
					operational,
					powered and operational
				)
			var drive_velocity := PistonProjectionUtil.drive_velocity_mps(
				sim_joint.motor,
				powered and operational
			)
			var drive_limit_n := (
				sim_joint.motor.force_limit_n
				if powered and operational
				else 0.0
			)
			if constraint != null and (
				drive_velocity != float(record.get("motor_target_v", NAN))
				or drive_limit_n != float(record.get("motor_limit_n", NAN))
			):
				PistonProjectionUtil.update_slider_motor(
					constraint,
					drive_velocity,
					drive_limit_n
				)
				record["motor_target_v"] = drive_velocity
				record["motor_limit_n"] = drive_limit_n
			var head_mass := PistonProjectionUtil.carriage_mass_kg(
				_world,
				record.get("carriage_element_ids", [])
			)
			if head_body is RigidBody3D:
				head_mass = maxf((head_body as RigidBody3D).mass, head_mass)
			var gravity := GravityField.resolve_gravity_accel(
				self,
				(
					(head_body as Node3D).global_position
					if head_body is Node3D
					else Vector3.ZERO
				)
			)
			var effort: Dictionary = PistonProjectionUtil.estimate_drive_effort(
				sim_joint.motor,
				drive_velocity,
				relative_velocity_mps,
				head_mass,
				axis_world,
				gravity
			)
			var sat_time := (
				float(record.get("sat_time_s", 0.0)) + delta
				if bool(effort.get("saturated", false))
				else 0.0
			)
			record["sat_time_s"] = sat_time
			var saturated := (
				sat_time >= PistonProjectionUtil.SATURATION_CONFIRM_S
			)
			var force_n := (
				sim_joint.motor.force_limit_n
				if saturated
				else float(effort.get("hold_n", 0.0))
			)
			sim_joint.motor.applied_force_n = force_n
			sim_joint.motor.force_saturated = saturated
			_world.sync_actuator_observation(
				int(record.get("joint_id", 0)),
				extension_m,
				relative_velocity_mps,
				force_n,
				saturated
			)
			if operational:
				_emit_piston_sustained_kinetic(
					record,
					head_body,
					force_n,
					saturated,
					relative_velocity_mps,
					delta
				)
	_world.tick_actuators(delta)


## Full joint reconfiguration only on state transitions (operational / flex /
## retuned limits) — rewriting limits and springs every tick fights Jolt
## warm-starting and is what used to make chains explode.
func _refresh_piston_constraint_config(
	record: Dictionary,
	constraint: Generic6DOFJoint3D,
	motor: SimulationMotorState,
	base_element: SimulationElement,
	extension_m: float,
	operational: bool,
	allow_flex: bool
) -> void:
	var limits := Vector2(motor.lower_limit_m, motor.upper_limit_m)
	var bind_extension := float(record.get("bind_extension_m", 0.0))
	var state_changed: bool = (
		record.get("cfg_operational") != operational
		or record.get("cfg_flex") != allow_flex
	)
	if state_changed:
		var base_archetype: ElementArchetype = (
			base_element.get_archetype() if base_element != null else null
		)
		var compliance := PistonProjectionUtil.runtime_angular_compliance(
			(
				base_archetype.piston_definition
				if base_archetype != null
				else null
			),
			allow_flex
		)
		# Incomplete pistons lock at the extension they had when they lost
		# operational state (no per-tick re-lock creep).
		var lock_extension := extension_m if not operational else NAN
		PistonProjectionUtil.configure_slider_joint(
			constraint,
			motor,
			compliance,
			lock_extension,
			bind_extension
		)
		record["cfg_operational"] = operational
		record["cfg_flex"] = allow_flex
		record["cfg_limits"] = limits
		record["motor_target_v"] = 0.0
		record["motor_limit_n"] = motor.force_limit_n
	elif operational and record.get("cfg_limits") != limits:
		PistonProjectionUtil.update_slider_limits(
			constraint,
			motor,
			bind_extension
		)
		record["cfg_limits"] = limits

func _emit_piston_sustained_kinetic(
	record: Dictionary,
	head_body: PhysicsBody3D,
	applied_force_n: float,
	saturated: bool,
	relative_velocity_mps: float,
	delta: float
) -> void:
	if (
		_impact_service == null
		or applied_force_n <= 0.0
		or delta <= 0.0
		or not head_body is RigidBody3D
	):
		return
	if not saturated and absf(relative_velocity_mps) >= SUSTAINED_V_EPS:
		return
	var carriage_element_ids: Array = record.get("carriage_element_ids", [])
	if not _carriage_touches_terrain(
		head_body as RigidBody3D,
		carriage_element_ids
	):
		return
	var striker_element_id := _pick_carriage_striker_element_id(
		carriage_element_ids
	)
	if striker_element_id <= 0:
		return
	var striker_shape_index := maxi(
		ImpactResolver.shape_index_for_element(head_body, striker_element_id),
		0
	)
	_impact_service.emit_actuator_sustained_entry(
		striker_element_id,
		head_body as RigidBody3D,
		null,
		applied_force_n,
		delta,
		striker_shape_index
	)

func _pick_carriage_striker_element_id(carriage_element_ids: Array) -> int:
	var fallback_id := 0
	for element_variant: Variant in carriage_element_ids:
		var element_id := int(element_variant)
		var element := _world.get_element(element_id)
		if element == null:
			continue
		if element.archetype_id == "stationary_drill":
			return element_id
		if (
			fallback_id <= 0
			and TerrainAnchorProbe.is_construction_archetype(
				element.archetype_id
			)
		):
			fallback_id = element_id
	return fallback_id

func _carriage_touches_terrain(
	head_body: RigidBody3D,
	carriage_element_ids: Array
) -> bool:
	if _world == null or head_body == null:
		return false
	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return false
	var assembly_transform := head_body.global_transform
	for element_variant: Variant in carriage_element_ids:
		var element := _world.get_element(int(element_variant))
		if element == null:
			continue
		if TerrainAnchorProbe.element_touches_terrain(
			assembly_transform,
			element,
			space_state
		):
			return true
	return false

func _clear_piston_constraints(assembly_id: int) -> void:
	for constraints: Dictionary in [_piston_constraints, _rotor_constraints]:
		var records: Variant = constraints.get(assembly_id, [])
		if records is Array:
			for record_variant: Variant in records:
				if not record_variant is Dictionary:
					continue
				var constraint: Generic6DOFJoint3D = (
					record_variant.get("constraint") as Generic6DOFJoint3D
				)
				if constraint != null and is_instance_valid(constraint):
					constraint.queue_free()
		constraints.erase(assembly_id)
	_root_group_ids.erase(assembly_id)

func _remove_group_bodies(assembly_id: int) -> void:
	var groups: Variant = _assembly_group_bodies.get(assembly_id)
	if not groups is Dictionary:
		return
	for group_id_variant: Variant in groups.keys():
		var body: PhysicsBody3D = groups[group_id_variant] as PhysicsBody3D
		if body == null:
			continue
		if _mounted_bodies.get(assembly_id) == body:
			_clear_body_colliders(body)
		else:
			body.collision_layer = 0
			body.collision_mask = 0
			body.process_mode = Node.PROCESS_MODE_DISABLED
			body.queue_free()
	_assembly_group_bodies.erase(assembly_id)

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
			# Locomotive bodies also carry the fragment script: precise
			# contact impulses come from _integrate_forces, and the script
			# no longer conflicts with wheel forces (no custom integrator).
			rigid = FragmentBodyScript.new() as RigidBody3D
		rigid.freeze = false
		rigid.physics_material_override = _get_assembly_physics_material()
		body = rigid
	body.name = "%s%d" % [BODY_NAME_PREFIX, assembly_id]
	body.collision_layer = COLLISION_LAYER_ASSEMBLY
	body.collision_mask = COLLISION_MASK_ASSEMBLY
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

func _get_assembly_physics_material() -> PhysicsMaterial:
	if _assembly_physics_material == null:
		_assembly_physics_material = PhysicsMaterial.new()
		_assembly_physics_material.friction = ASSEMBLY_FRICTION
		_assembly_physics_material.bounce = ASSEMBLY_BOUNCE
	return _assembly_physics_material


func _get_locomotive_physics_material() -> PhysicsMaterial:
	if _locomotive_physics_material == null:
		_locomotive_physics_material = PhysicsMaterial.new()
		_locomotive_physics_material.friction = ASSEMBLY_FRICTION
		_locomotive_physics_material.bounce = LOCOMOTIVE_BOUNCE
	return _locomotive_physics_material


## Soften locomotive↔terrain contact cost without removing the safety net:
## no CCD, no bounce; wheel/suspension boxes disabled separately.
func _apply_locomotive_rigid_tuning(
	assembly_id: int,
	rigid: RigidBody3D
) -> void:
	if (
		rigid == null
		or _world == null
		or not WheelSimulationService.is_locomotive_assembly(
			_world,
			assembly_id
		)
	):
		return
	rigid.continuous_cd = false
	rigid.physics_material_override = _get_locomotive_physics_material()
	rigid.collision_layer = COLLISION_LAYER_ASSEMBLY
	rigid.collision_mask = COLLISION_MASK_WHEEL_LOCOMOTIVE
	rigid.set_meta("wheel_loco_terrain_exempt", true)


func _should_disable_wheel_module_collider(
	assembly_id: int,
	element_id: int
) -> bool:
	if (
		_world == null
		or not WheelSimulationService.is_locomotive_assembly(
			_world,
			assembly_id
		)
	):
		return false
	var element := _world.get_element(element_id)
	if element == null:
		return false
	var archetype := element.get_archetype()
	return archetype != null and (archetype.is_wheel() or archetype.is_suspension())


func _sync_wheel_loco_body_physics(
	assembly_id: int,
	rigid: RigidBody3D
) -> void:
	if rigid == null:
		return
	if WheelSimulationService.is_locomotive_assembly(_world, assembly_id):
		_apply_locomotive_rigid_tuning(assembly_id, rigid)
		return
	if not rigid.has_meta("wheel_loco_terrain_exempt"):
		return
	rigid.collision_layer = COLLISION_LAYER_ASSEMBLY
	rigid.collision_mask = COLLISION_MASK_ASSEMBLY
	rigid.physics_material_override = _get_assembly_physics_material()
	rigid.remove_meta("wheel_loco_terrain_exempt")

func _apply_body_groups(
	assembly_id: int,
	body: PhysicsBody3D
) -> void:
	for group_name: Variant in _body_groups.get(assembly_id, []):
		if body is RigidBody3D:
			(body as RigidBody3D).add_to_group(str(group_name))

func _clear_body_colliders(body: PhysicsBody3D) -> void:
	var stale: Array[CollisionShape3D] = []
	for child_node: Node in body.get_children():
		if child_node is CollisionShape3D:
			stale.append(child_node as CollisionShape3D)
	for collider: CollisionShape3D in stale:
		collider.disabled = true
		collider.queue_free()

## Snapshot live per-group body motions (group_id -> AssemblyMotionState)
## before a multibody teardown so the rebuild can reseed surviving groups.
func _capture_live_group_motions(assembly_id: int) -> Dictionary:
	var captured: Dictionary = {}
	var groups_map: Variant = _assembly_group_bodies.get(assembly_id)
	if not groups_map is Dictionary:
		return captured
	for group_id_variant: Variant in (groups_map as Dictionary):
		var body: PhysicsBody3D = (
			(groups_map as Dictionary)[group_id_variant] as PhysicsBody3D
		)
		if body != null and is_instance_valid(body):
			captured[int(group_id_variant)] = _capture_body_motion(body)
	return captured


## Snapshot live body motion per element_id before teardown/split.
## Group ids are min(element_id) and change when members are removed; element
## keys stay stable across topology mutation so split children can reseed.
func _capture_live_element_motions(assembly_id: int) -> Dictionary:
	var motions: Dictionary = {}
	var body_ids: Dictionary = {}
	var groups_map: Variant = _assembly_group_bodies.get(assembly_id)
	if not groups_map is Dictionary:
		return {"motions": motions, "body_ids": body_ids}
	var body_motion_cache: Dictionary = {}
	for group_id_variant: Variant in (groups_map as Dictionary):
		var body: PhysicsBody3D = (
			(groups_map as Dictionary)[group_id_variant] as PhysicsBody3D
		)
		if body == null or not is_instance_valid(body):
			continue
		var body_id := body.get_instance_id()
		if not body_motion_cache.has(body_id):
			body_motion_cache[body_id] = _capture_body_motion(body)
		var motion: AssemblyMotionState = body_motion_cache[body_id]
		for element_id_variant: Variant in _element_records.keys():
			var element_id := int(element_id_variant)
			var record: Variant = _element_records[element_id_variant]
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
func _remap_element_motions_to_groups(
	assembly_id: int,
	live_capture: Dictionary
) -> Dictionary:
	var overrides: Dictionary = {}
	var motions: Dictionary = live_capture.get("motions", {})
	if motions.is_empty() or _world == null:
		return overrides
	var compiled: Dictionary = _world.compile_body_groups(assembly_id)
	if not bool(compiled.get("valid", false)):
		return overrides
	var groups: Dictionary = compiled.get("groups", {})
	var root_group_id := int(compiled.get("root_group_id", 0))
	for group_id_variant: Variant in groups.keys():
		var group_id := int(group_id_variant)
		if group_id == root_group_id:
			continue
		for member_variant: Variant in groups[group_id_variant]:
			var element_id := int(member_variant)
			if not motions.has(element_id):
				continue
			var motion_variant: Variant = motions[element_id]
			if motion_variant is AssemblyMotionState:
				overrides[group_id] = motion_variant
				break
	return overrides

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
	for child_node: Node in body.get_children():
		if child_node is CollisionShape3D:
			var collider: CollisionShape3D = child_node as CollisionShape3D
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
	_clear_piston_constraints(assembly_id)
	_remove_group_bodies(assembly_id)
	_remove_element_records_for_assembly(assembly_id)
	var body: PhysicsBody3D = get_physics_body(assembly_id)
	if body != null and not _assembly_group_bodies.has(assembly_id):
		if body is RigidBody3D and _impact_service != null:
			_impact_service.unregister_tracked_body(body as RigidBody3D)
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
	for assembly_id: int in _sorted_int_keys(_piston_constraints):
		_clear_piston_constraints(assembly_id)
	for assembly_id: int in _sorted_int_keys(_rotor_constraints):
		_clear_piston_constraints(assembly_id)
	for assembly_id: int in _sorted_int_keys(_bodies):
		_remove_body(assembly_id)
	_bodies.clear()
	_element_records.clear()
	_projected_revision.clear()
	_assembly_group_bodies.clear()
	_root_group_ids.clear()
	_piston_constraints.clear()
	_rotor_constraints.clear()

func _sorted_int_keys(dictionary: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key: Variant in dictionary:
		result.append(int(key))
	result.sort()
	return result
