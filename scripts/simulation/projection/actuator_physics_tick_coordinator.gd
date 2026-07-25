class_name ActuatorPhysicsTickCoordinator
extends RefCounted
## Actuator / thruster physics tick cluster extracted from
## SimulationPhysicsProjection. Owns piston/rotor/thruster/gyro ticks and
## piston constraint upkeep. Hot-path order stays in
## SimulationPhysicsProjection._physics_process.


const SUSTAINED_V_EPS := 0.05


static func tick_thrusters(projection, delta: float) -> void:
	if projection._world == null or delta <= 0.0:
		return
	for assembly_id: int in projection._sorted_int_keys(projection._bodies):
		# Activated first: avoid element walks for parked / inactive assemblies.
		# Thruster and gyro consumers are independent — gyro must tick without
		# thruster presence (CONTROL-AXES-V0 / semantic seat routing).
		var locomotion: AssemblyLocomotionController = projection._world.get_locomotion_controller(assembly_id)
		if locomotion == null or not locomotion.is_activated():
			continue
		if projection._is_assembly_frozen(assembly_id):
			continue
		var need_thrust: bool = locomotion.is_thrusters_route_enabled()
		var need_gyro: bool = locomotion.is_gyros_route_enabled()
		if not need_thrust and not need_gyro:
			continue
		var thrusters: Array[SimulationElement] = []
		var gyros: Array[SimulationElement] = []
		if need_thrust or need_gyro:
			var assembly: SimulationAssembly = projection._world.get_assembly_raw(assembly_id)
			if assembly == null:
				continue
			for element_id: int in assembly.element_ids:
				var element: SimulationElement = projection._world.get_element(element_id)
				if need_thrust and ThrusterSimulationService.is_thruster_element(
					element
				):
					thrusters.append(element)
				if need_gyro and ThrusterSimulationService.is_gyro_element(
					element
				):
					gyros.append(element)
		if need_thrust:
			for thruster: SimulationElement in thrusters:
				ActuatorPhysicsTickCoordinator.apply_thruster_force(projection, thruster, locomotion)
		var gyro_count: int = gyros.size()
		if need_gyro and gyro_count > 0:
			for gyro: SimulationElement in gyros:
				ActuatorPhysicsTickCoordinator.apply_gyro_torque(projection, gyro, locomotion, gyro_count)

static func piston_record_for_head(projection, body: PhysicsBody3D) -> Dictionary:
	if body == null:
		return {}
	var assembly_id: int = int(body.get_meta("assembly_id", 0))
	if assembly_id <= 0 or not projection._piston_constraints.has(assembly_id):
		return {}
	for record_variant: Variant in projection._piston_constraints[assembly_id]:
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		if record.get("head_body") == body:
			return record
	return {}

static func apply_thruster_force(
	projection,
	element: SimulationElement,
	locomotion: AssemblyLocomotionController
) -> void:
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null or archetype.thruster_definition == null:
		return
	var record: Dictionary = projection.get_element_projection(element.element_id)
	var body: RigidBody3D = record.get("body") as RigidBody3D
	if body == null or body.freeze:
		return
	var powered: bool = ThrusterSimulationService.is_element_powered(projection._world, element)
	var axis_local: Vector3 = ThrusterProjectionUtil.thrust_axis_local(
		archetype.thruster_definition,
		element.orientation_index
	)
	var velocity_local: Vector3 = (
		body.global_transform.basis.inverse() * body.linear_velocity
	)
	var throttle: float = ThrusterProjectionUtil.compute_thruster_throttle(
		axis_local,
		locomotion.translate_command,
		locomotion.is_dampeners(),
		velocity_local,
		powered
	)
	var thrust_n: float = ThrusterProjectionUtil.compute_thrust_n(
		archetype.thruster_definition,
		throttle,
		powered
	)
	if thrust_n <= 0.0:
		return
	var axis_world: Vector3 = (body.global_transform.basis * axis_local).normalized()
	body.sleeping = false
	# v0: central thrust keeps hop stable before nozzle torque / RCS tuning.
	body.apply_central_force(axis_world * thrust_n)

static func apply_gyro_torque(
	projection,
	element: SimulationElement,
	locomotion: AssemblyLocomotionController,
	gyro_count: int
) -> void:
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null or archetype.gyro_definition == null:
		return
	var record: Dictionary = projection.get_element_projection(element.element_id)
	var body: RigidBody3D = record.get("body") as RigidBody3D
	if body == null or body.freeze:
		return
	var powered: bool = ThrusterSimulationService.is_element_powered(projection._world, element)
	var omega_local: Vector3 = body.global_transform.basis.inverse() * body.angular_velocity
	var torque_local: Vector3 = ThrusterProjectionUtil.compute_gyro_torque_local(
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

static func tick_rotor_actuators(projection, delta: float) -> void:
	if projection._world == null or delta <= 0.0:
		return
	for assembly_id: int in projection._sorted_int_keys(projection._rotor_constraints):
		var assembly: SimulationAssembly = projection._world.get_assembly_raw(assembly_id)
		if assembly == null or assembly.tombstoned:
			continue
		if projection._is_assembly_frozen(assembly_id):
			continue
		for record_variant: Variant in projection._rotor_constraints[assembly_id]:
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
			var observed_angle: float = float(measured.get("angle_rad", 0.0))
			var observed_velocity: float = float(
				measured.get("relative_velocity_rad_s", 0.0)
			)
			var powered: bool = PistonProjectionUtil.is_piston_powered(
				projection._world,
				sim_joint.element_a_id
			)
			var drive: Dictionary = RotorProjectionUtil.solver_angular_drive(
				sim_joint.motor,
				powered,
				observed_angle
			)
			var drive_velocity: float = float(drive.get("velocity_rad_s", 0.0))
			var drive_limit_nm: float = float(drive.get("torque_limit_nm", 0.0))
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
			var gravity: Vector3 = GravityField.resolve_gravity_accel(
				projection,
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
			var sat_time: float = (
				float(record.get("sat_time_s", 0.0)) + delta
				if bool(effort.get("saturated", false))
				else 0.0
			)
			record["sat_time_s"] = sat_time
			var saturated: bool = (
				sat_time >= PistonProjectionUtil.SATURATION_CONFIRM_S
			)
			var torque_nm: float = (
				sim_joint.motor.force_limit_n
				if saturated
				else float(effort.get("hold_nm", 0.0))
			)
			sim_joint.motor.applied_force_n = torque_nm
			sim_joint.motor.force_saturated = saturated
			projection._world.sync_actuator_observation(
				int(record.get("joint_id", 0)),
				observed_angle,
				observed_velocity,
				torque_nm,
				saturated
			)

static func tick_piston_actuators(projection, delta: float) -> void:
	if projection._world == null or delta <= 0.0:
		return
	var any_live_piston: bool = false
	for assembly_id: int in projection._sorted_int_keys(projection._piston_constraints):
		var assembly: SimulationAssembly = projection._world.get_assembly_raw(assembly_id)
		if assembly == null or assembly.tombstoned:
			continue
		if projection._is_assembly_frozen(assembly_id):
			continue
		var records: Variant = projection._piston_constraints[assembly_id]
		if records is Array and (records as Array).is_empty():
			continue
		any_live_piston = true
		for record_variant: Variant in projection._piston_constraints[assembly_id]:
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
			var extension_m: float = float(measured.get("extension_m", 0.0))
			var relative_velocity_mps: float = float(
				measured.get("relative_velocity_mps", 0.0)
			)
			var powered: bool = PistonProjectionUtil.is_piston_powered(
				projection._world,
				sim_joint.element_a_id
			)
			var base_element: SimulationElement = projection._world.get_element(sim_joint.element_a_id)
			var operational: bool = (
				base_element != null and base_element.is_operational()
			)
			var constraint: Generic6DOFJoint3D = record.get("constraint")
			if constraint != null:
				ActuatorPhysicsTickCoordinator.refresh_piston_constraint_config(projection, 
					record,
					constraint,
					sim_joint.motor,
					base_element,
					extension_m,
					operational,
					powered and operational
				)
			var drive_velocity: float = PistonProjectionUtil.drive_velocity_mps(
				sim_joint.motor,
				powered and operational
			)
			var drive_limit_n: float = (
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
			var head_mass: float = PistonProjectionUtil.carriage_mass_kg(
				projection._world,
				record.get("carriage_element_ids", [])
			)
			if head_body is RigidBody3D:
				head_mass = maxf((head_body as RigidBody3D).mass, head_mass)
			var gravity: Vector3 = GravityField.resolve_gravity_accel(
				projection,
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
			var sat_time: float = (
				float(record.get("sat_time_s", 0.0)) + delta
				if bool(effort.get("saturated", false))
				else 0.0
			)
			record["sat_time_s"] = sat_time
			var saturated: bool = (
				sat_time >= PistonProjectionUtil.SATURATION_CONFIRM_S
			)
			var force_n: float = (
				sim_joint.motor.force_limit_n
				if saturated
				else float(effort.get("hold_n", 0.0))
			)
			sim_joint.motor.applied_force_n = force_n
			sim_joint.motor.force_saturated = saturated
			projection._world.sync_actuator_observation(
				int(record.get("joint_id", 0)),
				extension_m,
				relative_velocity_mps,
				force_n,
				saturated
			)
			if operational:
				ActuatorPhysicsTickCoordinator.emit_piston_sustained_kinetic(projection, 
					record,
					head_body,
					force_n,
					saturated,
					relative_velocity_mps,
					delta
				)
	# Kernel motor integrate while any projected piston/rotor assembly is live.
	# Wheel-only yards (empty actuator maps) must not walk joints each tick.
	if any_live_piston or projection._has_live_actuator_assembly(projection._rotor_constraints):
		projection._world.tick_actuators(delta)

static func refresh_piston_constraint_config(
	projection,
	record: Dictionary,
	constraint: Generic6DOFJoint3D,
	motor: SimulationMotorState,
	base_element: SimulationElement,
	extension_m: float,
	operational: bool,
	allow_flex: bool
) -> void:
	var limits: Vector2 = Vector2(motor.lower_limit_m, motor.upper_limit_m)
	var bind_extension: float = float(record.get("bind_extension_m", 0.0))
	var state_changed: bool = (
		record.get("cfg_operational") != operational
		or record.get("cfg_flex") != allow_flex
	)
	if state_changed:
		var base_archetype: ElementArchetype = (
			base_element.get_archetype() if base_element != null else null
		)
		var compliance: Dictionary = PistonProjectionUtil.runtime_angular_compliance(
			(
				base_archetype.piston_definition
				if base_archetype != null
				else null
			),
			allow_flex
		)
		# Incomplete pistons lock at the extension they had when they lost
		# operational state (no per-tick re-lock creep).
		var lock_extension: float = extension_m if not operational else NAN
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

static func emit_piston_sustained_kinetic(
	projection,
	record: Dictionary,
	head_body: PhysicsBody3D,
	applied_force_n: float,
	saturated: bool,
	relative_velocity_mps: float,
	delta: float
) -> void:
	if (
		projection._impact_service == null
		or applied_force_n <= 0.0
		or delta <= 0.0
		or not head_body is RigidBody3D
	):
		return
	if not saturated and absf(relative_velocity_mps) >= SUSTAINED_V_EPS:
		return
	var carriage_element_ids: Array = record.get("carriage_element_ids", [])
	if not ActuatorPhysicsTickCoordinator.carriage_touches_terrain(projection, 
		head_body as RigidBody3D,
		carriage_element_ids
	):
		return
	var striker_element_id: int = ActuatorPhysicsTickCoordinator.pick_carriage_striker_element_id(projection, 
		carriage_element_ids
	)
	if striker_element_id <= 0:
		return
	var striker_shape_index: int = maxi(
		ImpactResolver.shape_index_for_element(head_body, striker_element_id),
		0
	)
	projection._impact_service.emit_actuator_sustained_entry(
		striker_element_id,
		head_body as RigidBody3D,
		null,
		applied_force_n,
		delta,
		striker_shape_index
	)

static func pick_carriage_striker_element_id(projection, carriage_element_ids: Array) -> int:
	var fallback_id: int = 0
	for element_variant: Variant in carriage_element_ids:
		var element_id: int = int(element_variant)
		var element: SimulationElement = projection._world.get_element(element_id)
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

static func carriage_touches_terrain(
	projection,
	head_body: RigidBody3D,
	carriage_element_ids: Array
) -> bool:
	if projection._world == null or head_body == null:
		return false
	var space_state: PhysicsDirectSpaceState3D = projection.get_world_3d().direct_space_state
	if space_state == null:
		return false
	var assembly_transform: Transform3D = head_body.global_transform
	for element_variant: Variant in carriage_element_ids:
		var element: SimulationElement = projection._world.get_element(int(element_variant))
		if element == null:
			continue
		if TerrainAnchorProbe.element_touches_terrain(
			assembly_transform,
			element,
			space_state
		):
			return true
	return false

static func clear_piston_constraints(projection, assembly_id: int) -> void:
	for constraints: Dictionary in [
		projection._piston_constraints,
		projection._rotor_constraints,
		projection._wheel_constraints,
	]:
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
	projection._root_group_ids.erase(assembly_id)
