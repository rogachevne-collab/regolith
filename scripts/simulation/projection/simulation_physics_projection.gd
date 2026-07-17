class_name SimulationPhysicsProjection
extends Node3D

const BODY_NAME_PREFIX := "AssemblyBody_"
const GROUP_BODY_NAME_PREFIX := "AssemblyGroupBody_"
const PISTON_JOINT_NAME_PREFIX := "PistonJoint_"
const ROTOR_JOINT_NAME_PREFIX := "RotorJoint_"
const HINGE_JOINT_NAME_PREFIX := "HingeJoint_"
const MIN_MASS := 0.001
const SUSTAINED_V_EPS := 0.05
const FragmentBodyScript := preload(
	"res://scripts/simulation/projection/projected_assembly_body.gd"
)
const BodyGroupMotionUtilScript := preload(
	"res://scripts/simulation/runtime/body_group_motion_util.gd"
)

const ASSEMBLY_BOUNCE := 0.32
const ASSEMBLY_FRICTION := 0.42

var _world: SimulationWorld
var _assembly_physics_material: PhysicsMaterial
var _bodies: Dictionary = {}
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
			compiled
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
		if (
			_impact_service != null
			and mounted == null
			and not anchored
		):
			_impact_service.configure_impact_body(
				rigid,
				ImpactResolverService.ImpactBodyMode.FULL
			)
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
	compiled: Dictionary
) -> void:
	var assembly: SimulationAssembly = _world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	_remove_body(assembly_id)
	var groups: Dictionary = compiled["groups"]
	var root_group_id := int(compiled.get("root_group_id", 0))
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
		BodyGroupMotionUtilScript.reconstruct_all_group_motions(_world, assembly_id)
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
		PistonProjectionUtil.configure_slider_joint(
			joint_node,
			sim_joint.motor
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
	var elements_by_id: Dictionary = {}
	for element_id: int in assembly.element_ids:
		var element: SimulationElement = _world.get_element(element_id)
		if element != null:
			elements_by_id[element_id] = element
	var joints: Array[SimulationJoint] = []
	for joint: SimulationJoint in _world.list_joints():
		if joint.assembly_id == assembly.assembly_id:
			joints.append(joint)
	return BodyGroupCompiler.compile(
		assembly.element_ids,
		elements_by_id,
		joints
	)


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
	body.collision_layer = 1
	body.collision_mask = 1
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


func _should_tick_wheels(assembly_id: int) -> bool:
	if (
		_world == null
		or not WheelSimulationService.is_locomotive_assembly(_world, assembly_id)
	):
		return false
	var body := get_physics_body(assembly_id)
	if body is RigidBody3D:
		return not (body as RigidBody3D).freeze
	var groups: Variant = _assembly_group_bodies.get(assembly_id)
	if groups is Dictionary:
		for body_variant: Variant in (groups as Dictionary).values():
			if body_variant is RigidBody3D:
				return not (body_variant as RigidBody3D).freeze
	return false


func _tick_wheel_pairs(delta: float) -> void:
	if _world == null or delta <= 0.0:
		return
	for assembly_id: int in _sorted_int_keys(_bodies):
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
			var observed_velocity := float(
				measured.get("relative_velocity_rad_s", 0.0)
			)
			_world.sync_actuator_observation(
				int(record.get("joint_id", 0)),
				float(measured.get("angle_rad", 0.0)),
				observed_velocity,
				sim_joint.motor.applied_force_n,
				sim_joint.motor.force_saturated
			)
			var powered: bool = PistonProjectionUtil.is_piston_powered(
				_world,
				sim_joint.element_a_id
			)
			var effective_inertia := (
				RotorProjectionUtil.reduced_inertia_about_axis(
					head_body,
					base_body,
					axis_world
				)
			)
			var torque_result: Dictionary = (
				RotorProjectionUtil.compute_motor_torque_scalar(
					sim_joint.motor,
					observed_velocity,
					powered,
					effective_inertia
				)
			)
			var torque_nm := float(torque_result.get("torque_nm", 0.0))
			var saturated := bool(torque_result.get("saturated", false))
			sim_joint.motor.applied_force_n = absf(torque_nm)
			sim_joint.motor.force_saturated = saturated
			if head_body is RigidBody3D:
				(head_body as RigidBody3D).apply_torque(axis_world * torque_nm)
			if RotorProjectionUtil.is_dynamic_rigid(base_body):
				(base_body as RigidBody3D).apply_torque(-axis_world * torque_nm)
			_world.sync_actuator_observation(
				int(record.get("joint_id", 0)),
				float(measured.get("angle_rad", 0.0)),
				observed_velocity,
				absf(torque_nm),
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
			_world.sync_actuator_observation(
				int(record.get("joint_id", 0)),
				float(measured.get("extension_m", 0.0)),
				float(measured.get("relative_velocity_mps", 0.0)),
				sim_joint.motor.applied_force_n,
				sim_joint.motor.force_saturated
			)
			var powered: bool = PistonProjectionUtil.is_piston_powered(
				_world,
				sim_joint.element_a_id
			)
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
			var force_result: Dictionary = (
				PistonProjectionUtil.compute_motor_force_scalar(
					sim_joint.motor,
					float(measured.get("relative_velocity_mps", 0.0)),
					powered,
					head_mass,
					axis_world,
					gravity
				)
			)
			var force_n := float(force_result.get("force_n", 0.0))
			var saturated := bool(force_result.get("saturated", false))
			var constraint: Generic6DOFJoint3D = record.get("constraint")
			if constraint != null:
				PistonProjectionUtil.configure_slider_joint(
					constraint,
					sim_joint.motor
				)
			sim_joint.motor.applied_force_n = absf(force_n)
			sim_joint.motor.force_saturated = saturated
			var axis_dir := axis_world.normalized()
			if head_body is RigidBody3D:
				(head_body as RigidBody3D).apply_central_force(
					axis_dir * force_n
				)
			if base_body is RigidBody3D and not base_body is StaticBody3D:
				(base_body as RigidBody3D).apply_central_force(
					-axis_dir * force_n
				)
			_world.sync_actuator_observation(
				int(record.get("joint_id", 0)),
				float(measured.get("extension_m", 0.0)),
				float(measured.get("relative_velocity_mps", 0.0)),
				absf(force_n),
				saturated
			)
			_emit_piston_sustained_kinetic(
				record,
				head_body,
				absf(force_n),
				saturated,
				float(measured.get("relative_velocity_mps", 0.0)),
				delta
			)
	_world.tick_actuators(delta)


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


func _get_assembly_physics_material() -> PhysicsMaterial:
	if _assembly_physics_material == null:
		_assembly_physics_material = PhysicsMaterial.new()
		_assembly_physics_material.friction = ASSEMBLY_FRICTION
		_assembly_physics_material.bounce = ASSEMBLY_BOUNCE
	return _assembly_physics_material


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
