class_name AssemblyProjectionCoordinator
extends RefCounted
## Assembly single/multibody projection extracted from SimulationPhysicsProjection.

const MIN_MASS := 0.001
const PISTON_JOINT_NAME_PREFIX := "PistonJoint_"
const ROTOR_JOINT_NAME_PREFIX := "RotorJoint_"
const HINGE_JOINT_NAME_PREFIX := "HingeJoint_"
const BodyGroupMotionUtilScript := preload(
	"res://scripts/simulation/runtime/body_group_motion_util.gd"
)

static func compile_assembly_groups(
	projection,
	assembly: SimulationAssembly
) -> Dictionary:
	return projection._world.compile_body_groups(assembly.assembly_id)


static func is_locomotive_assembly(projection, assembly_id: int) -> bool:
	if projection._world == null:
		return false
	return ThrusterSimulationService.is_mobile_assembly(projection._world, assembly_id)


static func is_active_locomotive(projection, assembly_id: int) -> bool:
	return (
		AssemblyProjectionCoordinator.is_locomotive_assembly(projection, assembly_id)
		and projection._world.get_locomotion_controller(assembly_id).is_activated()
	)


static func project_assembly(
	projection,
	assembly_id: int,
	motion_override: AssemblyMotionState,
	live_capture: Dictionary = {}
) -> void:
	var assembly: SimulationAssembly = projection._world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		AssemblyTeardownCoordinator.remove_body(projection, assembly_id)
		return
	if (
		motion_override == null
		and live_capture.is_empty()
		and projection._projected_revision.get(assembly_id, -1)
		== assembly.topology_revision
		and projection.get_physics_body(assembly_id) != null
	):
		return
	var compiled := AssemblyProjectionCoordinator.compile_assembly_groups(projection, assembly)
	var driven_specs: Array = compiled.get("driven_specs", [])
	var wheel_specs: Array = compiled.get("wheel_specs", [])
	if (
		bool(compiled.get("valid", false))
		and not (driven_specs.is_empty() and wheel_specs.is_empty())
		and not projection._mounted_bodies.has(assembly_id)
	):
		AssemblyProjectionCoordinator.project_assembly_multibody(projection, 
			assembly_id,
			motion_override,
			compiled,
			live_capture
		)
		return
	AssemblyProjectionCoordinator.project_assembly_single(projection, assembly_id, motion_override)


static func project_assembly_single(
	projection,
	assembly_id: int,
	motion_override: AssemblyMotionState
) -> void:
	var assembly: SimulationAssembly = projection._world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		AssemblyTeardownCoordinator.remove_body(projection, assembly_id)
		return
	var seed_motion: AssemblyMotionState = (
		motion_override
		if motion_override != null
		else assembly.motion
	)
	var active_locomotive: bool = AssemblyProjectionCoordinator.is_active_locomotive(projection, assembly_id)
	var locomotion: AssemblyLocomotionController = projection._world.get_locomotion_controller(assembly_id)
	var release_from_anchor: bool = (
		active_locomotive
		and seed_motion.frozen
		and projection._world.assembly_has_anchor(assembly_id)
		and not projection._mounted_bodies.has(assembly_id)
		and not locomotion.has_released_from_anchor()
	)
	var anchored: bool = (
		projection._world.assembly_has_anchor(assembly_id)
		and not active_locomotive
		and not locomotion.has_released_from_anchor()
	)
	var mounted: RigidBody3D = projection._mounted_bodies.get(assembly_id) as RigidBody3D
	var mounted_motion: AssemblyMotionState = null
	var body: PhysicsBody3D
	if mounted != null:
		mounted_motion = PhysicsMotionSyncCoordinator.capture_body_motion(projection, mounted)
		if motion_override == null:
			mounted.freeze = true
		AssemblyBodyBuildCoordinator.clear_body_colliders(projection, mounted)
		body = mounted
	else:
		body = AssemblyBodyBuildCoordinator.create_body(projection, assembly_id, anchored)
	var records: Array[Dictionary] = (
		ColliderProjectionUtil.build_collision_shapes(projection._world, assembly)
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
	# Replica worlds skip the whole motion policy: snapshot motion is the truth
	# verbatim, and mark_released_from_anchor would mutate serialized state.
	if projection._world.authoritative:
		if release_from_anchor:
			motion.transform.origin += (
				motion.transform.basis.y.normalized()
				* ThrusterSimulationService.activation_clearance_m(
					projection._world,
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
		elif AssemblyProjectionCoordinator.is_locomotive_assembly(projection, assembly_id):
			# Floating mobile: dynamic; wheels use parking_brake, flight uses thrust.
			if not locomotion.has_released_from_anchor():
				motion.transform.origin += (
					motion.transform.basis.y.normalized()
					* ThrusterSimulationService.activation_clearance_m(
						projection._world,
						assembly_id
					)
				)
				locomotion.mark_released_from_anchor()
			motion.frozen = false
			motion.sleeping = false
		else:
			# By construction: not anchored (that is the branch above), and nothing
			# aboard can move it — _is_locomotive_assembly, wheels or thrusters, just
			# failed. Every thaw path in the game is gated on exactly that
			# capability: driver input (_update_parking_freeze), seat entry
			# (gateway._wake_rover_body), a dig nearby (wake_frozen_near). Carrying
			# `frozen` forward here therefore parks a body with nobody holding the
			# key — not a StaticBody, so the rest of the game reads it as loose, yet
			# deaf to every force there is. That is how an anchored assembly already
			# marked released_from_anchor ended up a permanent statue: rigid,
			# immovable, impossible to so much as tug with a rope. Let Jolt sleep it
			# instead; sleeping costs the same and it wakes on contact.
			motion.frozen = false
			if motion_override != null:
				motion.sleeping = seed_motion.sleeping
			if seed_motion.frozen:
				# Thawed out of a park: left asleep, it would hang where it was.
				motion.sleeping = false
	if mounted == null:
		projection.add_child(body)
		body.global_transform = motion.transform
	else:
		if motion_override == null:
			motion = mounted_motion
		else:
			motion.transform = mounted_motion.transform
	AssemblyBodyBuildCoordinator.apply_collision_profile(projection, assembly_id, body)
	AssemblyBodyBuildCoordinator.apply_body_groups(projection, assembly_id, body)
	if body is RigidBody3D:
		var rigid: RigidBody3D = body as RigidBody3D
		rigid.mass = maxf(
			ColliderProjectionUtil.assembly_dry_mass(projection._world, assembly),
			AssemblyBodyBuildCoordinator.MIN_MASS
		)
		rigid.center_of_mass_mode = (
			RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		)
		rigid.center_of_mass = (
			ColliderProjectionUtil.assembly_center_of_mass_local(
				projection._world,
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
		if not projection.simulates_assembly_physics(assembly_id):
			# Observer / ghost: network sets poses (no local Jolt).
			rigid.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			rigid.freeze = true
		if (
			projection._impact_service != null
			and mounted == null
			and not anchored
			and projection._world.authoritative
		):
			projection._impact_service.configure_impact_body(
				rigid,
				ImpactResolverService.ImpactBodyMode.FULL
			)
		AssemblyBodyBuildCoordinator.apply_locomotive_rigid_tuning(projection, assembly_id, rigid)
	projection._bodies[assembly_id] = body
	projection._tick_key_structure_rev += 1
	for element_id: int in colliders_by_element:
		projection._element_records[element_id] = {
			"assembly_id": assembly_id,
			"body": body,
			"colliders": colliders_by_element[element_id],
		}
	projection._world.sync_assembly_motion(assembly_id, motion)
	projection._projected_revision[assembly_id] = assembly.topology_revision


static func project_assembly_multibody(
	projection,
	assembly_id: int,
	motion_override: AssemblyMotionState,
	compiled: Dictionary,
	live_capture: Dictionary = {}
) -> void:
	var assembly: SimulationAssembly = projection._world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	# Live poses/velocities of surviving groups must ride across the rebuild:
	# reconstruction from motor state snaps sagged/flexed joints to their
	# idealized pose and kicks the whole chain on every placed block.
	# Prefer caller-captured element motions (reproject/split tear down bodies
	# first); fall back to an in-place group capture when bodies still exist.
	var live_group_motions: Dictionary = (
		PhysicsMotionSyncCoordinator.remap_element_motions_to_groups(
			projection,
			assembly_id,
			live_capture
		)
		if not live_capture.is_empty()
		else PhysicsMotionSyncCoordinator.capture_live_group_motions(
			projection,
			assembly_id
		)
	)
	AssemblyTeardownCoordinator.remove_body(projection, assembly_id)
	var groups: Dictionary = compiled["groups"]
	var root_group_id := int(compiled.get("root_group_id", 0))
	live_group_motions.erase(root_group_id)
	var source_motion: AssemblyMotionState = (
		motion_override
		if motion_override != null
		else assembly.motion
	)
	var seed_motion := source_motion.duplicate_state()
	var active_locomotive: bool = AssemblyProjectionCoordinator.is_active_locomotive(projection, assembly_id)
	var locomotion: AssemblyLocomotionController = projection._world.get_locomotion_controller(assembly_id)
	if (
		# Replica: snapshot motion verbatim, no serialized-state mutation.
		projection._world.authoritative
		and active_locomotive
		and seed_motion.frozen
		and projection._world.assembly_has_anchor(assembly_id)
		and not locomotion.has_released_from_anchor()
	):
		seed_motion.transform.origin += (
			seed_motion.transform.basis.y.normalized()
			* ThrusterSimulationService.activation_clearance_m(
				projection._world,
				assembly_id
			)
		)
		seed_motion.frozen = false
		seed_motion.sleeping = false
		locomotion.mark_released_from_anchor()
	projection._world.sync_assembly_motion(assembly_id, seed_motion)
	assembly.clear_body_group_motions()
	var group_motions: Dictionary = (
		AssemblyProjectionCoordinator.BodyGroupMotionUtilScript.reconstruct_all_group_motions(
			projection._world,
			assembly_id,
			live_group_motions
		)
	)
	var groups_map: Dictionary = {}
	var carriage_group_ids: Dictionary = {}
	for spec_variant: Variant in compiled.get("driven_specs", []):
		if spec_variant is Dictionary:
			carriage_group_ids[int(spec_variant.get("head_group_id", 0))] = true
	# Wheel groups (WHEEL-BODY-V1): group_id -> {spec, frame, wheel_element,
	# definition}. A wheel group whose frame cannot be resolved degrades to a
	# plain rigid group (visible in the warning, not a silent fall-through).
	var wheel_groups: Dictionary = {}
	for spec_variant: Variant in compiled.get("wheel_specs", []):
		if not spec_variant is Dictionary:
			continue
		var wheel_spec: Dictionary = spec_variant
		var spec_wheel: SimulationElement = projection._world.get_element(
			int(wheel_spec.get("wheel_element_id", 0))
		)
		var frame := WheelBodyProjectionUtil.wheel_frame_assembly_local(
			spec_wheel
		)
		if frame.is_empty():
			push_warning(
				"wheel spec %d has no resolvable frame; wheel stays a plain body"
				% int(wheel_spec.get("joint_id", 0))
			)
			continue
		wheel_groups[int(wheel_spec.get("wheel_group_id", 0))] = {
			"spec": wheel_spec,
			"frame": frame,
			"wheel_element": spec_wheel,
			"definition": spec_wheel.get_archetype().wheel_definition,
		}
	for group_id: int in AssemblyTeardownCoordinator.sorted_int_keys(groups):
		var members: Array = groups[group_id]
		var element_ids: Array[int] = []
		for member_variant: Variant in members:
			element_ids.append(int(member_variant))
		var is_root := group_id == root_group_id
		# Mirrors the single-body `anchored` gate: a rover that has already
		# released from its build anchor must stay dynamic (rovers are always
		# multibody now, so this path sees them).
		var is_static: bool = (
			is_root
			and projection._world.assembly_has_anchor(assembly_id)
			and not active_locomotive
			and not locomotion.has_released_from_anchor()
		)
		var is_carriage := carriage_group_ids.has(group_id)
		var wheel_group: Dictionary = wheel_groups.get(group_id, {})
		var is_wheel_group := not wheel_group.is_empty()
		var body: PhysicsBody3D = AssemblyBodyBuildCoordinator.create_group_body(projection, assembly_id, group_id, is_static)
		var records: Array[Dictionary]
		if is_wheel_group:
			# The tire is one smooth cylinder sized from WheelDefinition; the
			# authored micro-colliders stay off the physics wheel.
			records = [
				WheelBodyProjectionUtil.build_wheel_collider_record(
					wheel_group["wheel_element"],
					wheel_group["frame"]
				)
			]
		else:
			records = (
				PistonProjectionUtil.build_collision_shapes_for_elements(
					projection._world,
					assembly,
					element_ids
				)
			)
		AssemblyBodyBuildCoordinator.attach_colliders_to_body(projection, 
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
					projection._world,
					element_ids
				),
				AssemblyBodyBuildCoordinator.MIN_MASS
			)
			rigid.center_of_mass_mode = (
				RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
			)
			if is_wheel_group:
				rigid.center_of_mass = Vector3(wheel_group["frame"]["hub"])
				WheelPhysicsTickCoordinator.configure_wheel_rigid(projection, rigid, wheel_group)
			else:
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
				# Wheel bodies are never impact bodies: rolling contact must
				# not feed the damage pipeline.
				if (
					projection._impact_service != null
					and not is_wheel_group
					and projection._world.authoritative
				):
					var impact_mode := (
						ImpactResolverService.ImpactBodyMode.MONITOR_ONLY
						if is_carriage
						else ImpactResolverService.ImpactBodyMode.FULL
					)
					projection._impact_service.configure_impact_body(rigid, impact_mode)
				if not is_wheel_group:
					AssemblyBodyBuildCoordinator.apply_locomotive_rigid_tuning(projection, assembly_id, rigid)
			if not projection.simulates_assembly_physics(assembly_id):
				# Observer / ghost: network sets poses (no local Jolt).
				rigid.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
				rigid.freeze = true
		projection.add_child(body)
		AssemblyBodyBuildCoordinator.apply_collision_profile(projection, assembly_id, body)
		AssemblyBodyBuildCoordinator.apply_body_groups(projection, assembly_id, body)
		groups_map[group_id] = body
		projection._world.sync_assembly_body_group_motion(
			assembly_id,
			group_id,
			group_motion
		)

	projection._assembly_group_bodies[assembly_id] = groups_map
	projection._root_group_ids[assembly_id] = root_group_id
	if root_group_id > 0 and groups_map.has(root_group_id):
		projection._bodies[assembly_id] = groups_map[root_group_id]
	projection._tick_key_structure_rev += 1

	var piston_records: Array[Dictionary] = []
	var rotor_records: Array[Dictionary] = []
	# Observer/ghost: no Jolt constraints — network sets every group pose.
	var driven_specs: Array = (
		compiled.get("driven_specs", [])
		if projection.simulates_assembly_physics(assembly_id)
		else []
	)
	for spec_variant: Variant in driven_specs:
		if not spec_variant is Dictionary:
			continue
		var spec: Dictionary = spec_variant
		var sim_joint: SimulationJoint = projection._world.get_joint(
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
		var base_element: SimulationElement = projection._world.get_element(
			int(spec.get("base_element_id", 0))
		)
		var head_element: SimulationElement = projection._world.get_element(
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
				AssemblyProjectionCoordinator.HINGE_JOINT_NAME_PREFIX,
				assembly_id,
				sim_joint.joint_id,
			]
			projection.add_child(hinge_joint_node)
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
				AssemblyProjectionCoordinator.ROTOR_JOINT_NAME_PREFIX,
				assembly_id,
				sim_joint.joint_id,
			]
			projection.add_child(rotor_joint_node)
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
			AssemblyProjectionCoordinator.PISTON_JOINT_NAME_PREFIX,
			assembly_id,
			sim_joint.joint_id,
		]
		projection.add_child(joint_node)
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
	# Only keep assemblies that actually have driven constraints — empty keys
	# made parked wheel rovers look like "piston_asms == loco_total".
	if piston_records.is_empty():
		projection._piston_constraints.erase(assembly_id)
	else:
		projection._piston_constraints[assembly_id] = piston_records
	if rotor_records.is_empty():
		projection._rotor_constraints.erase(assembly_id)
	else:
		projection._rotor_constraints[assembly_id] = rotor_records
	if projection.simulates_assembly_physics(assembly_id):
		projection._wheel_constraints[assembly_id] = WheelPhysicsTickCoordinator.build_wheel_constraints(
			projection,
			assembly_id,
			wheel_groups,
			groups_map
		)
	else:
		projection._wheel_constraints.erase(assembly_id)
	projection._tick_key_structure_rev += 1
	var motion: AssemblyMotionState = seed_motion.duplicate_state()
	if projection._world.authoritative and projection._world.assembly_has_anchor(assembly_id):
		if not active_locomotive:
			motion.frozen = true
			motion.linear_velocity = Vector3.ZERO
			motion.angular_velocity = Vector3.ZERO
			motion.sleeping = true
	projection._world.sync_assembly_motion(assembly_id, motion)
	projection._projected_revision[assembly_id] = assembly.topology_revision

