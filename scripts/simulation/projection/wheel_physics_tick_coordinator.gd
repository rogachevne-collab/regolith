class_name WheelPhysicsTickCoordinator
extends RefCounted
## Wheel physics tick / loco tuning cluster extracted from
## SimulationPhysicsProjection. Owns per-tick wheel motors, parking-freeze scan
## callout, wheel joint build, and locomotive rigid tuning.
## Hot-path order stays in SimulationPhysicsProjection._physics_process.


const WHEEL_JOINT_NAME_PREFIX := "WheelJoint_"
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
## Wheel locomotives still collide with terrain (tip-over / bad seating).
## FPS: CCD off, bounce 0. Wheels are their own solid bodies (WHEEL-BODY-V1).
const COLLISION_MASK_WHEEL_LOCOMOTIVE := COLLISION_MASK_ASSEMBLY


static func configure_wheel_rigid(
	projection,
	rigid: RigidBody3D,
	wheel_group: Dictionary
) -> void:
	var definition: WheelDefinition = wheel_group.get("definition")
	var wheel_element: SimulationElement = wheel_group.get("wheel_element")
	if definition == null or wheel_element == null:
		return
	var state: WheelInstanceState = projection._world.ensure_wheel_instance_state(wheel_element.element_id)
	var material := PhysicsMaterial.new()
	material.friction = WheelBodyProjectionUtil.tire_friction(
		definition,
		state.grip_scale
	)
	material.bounce = 0.0
	rigid.physics_material_override = material
	rigid.angular_damp = definition.angular_damping
	rigid.continuous_cd = false


## One 6DOF per wheel: strut group body ↔ wheel body. The wheel body's
## rotation is snapped to the strut frame first (spin/steer are cosmetic on a
## cylinder; a clean bind pose keeps Jolt's angular limits absolute), the
## compression offset keeps the travel range absolute (droop = 0).
static func build_wheel_constraints(
	projection,
	assembly_id: int,
	wheel_groups: Dictionary,
	groups_map: Dictionary
) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for group_id: int in projection._sorted_int_keys(wheel_groups):
		var wheel_group: Dictionary = wheel_groups[group_id]
		var spec: Dictionary = wheel_group["spec"]
		var frame: Dictionary = wheel_group["frame"]
		var definition: WheelDefinition = wheel_group["definition"]
		var strut_body: PhysicsBody3D = groups_map.get(
			int(spec.get("suspension_group_id", 0))
		) as PhysicsBody3D
		var wheel_body: RigidBody3D = groups_map.get(group_id) as RigidBody3D
		if strut_body == null or wheel_body == null or definition == null:
			continue
		var suspension_element_id: int = int(spec.get("suspension_element_id", 0))
		var wheel_element_id: int = int(spec.get("wheel_element_id", 0))
		var suspension: SimulationElement = projection._world.get_element(
			suspension_element_id
		)
		var suspension_def: SuspensionDefinition = (
			suspension.get_archetype().suspension_definition
			if suspension != null and suspension.get_archetype() != null
			else null
		)
		if suspension_def == null:
			continue
		var suspension_state: SuspensionInstanceState = projection._world.ensure_suspension_instance_state(
			suspension_element_id
		)
		var wheel_state: WheelInstanceState = projection._world.ensure_wheel_instance_state(wheel_element_id)
		var hub_local: Vector3 = frame["hub"]
		var up_local: Vector3 = frame["up"]
		var wheel_element: SimulationElement = wheel_group["wheel_element"]
		# Seat the MATE tip (wheel_plug) on the suspension socket. The spin
		# hub is a different point on the same axle (Wizard tire cylinder);
		# putting the hub on the socket shoved the tire into the strut.
		var socket: Dictionary = WheelBodyProjectionUtil.mount_pad_anchor_assembly_local(
			suspension,
			"wheel_socket"
		)
		var plug_local: Vector3 = (
			WheelBodyProjectionUtil.plug_point_assembly_local(wheel_element)
		)
		var socket_local: Vector3 = (
			socket["origin"] if not socket.is_empty() else plug_local
		)
		wheel_body.global_transform = Transform3D(
			strut_body.global_transform.basis,
			strut_body.global_transform * socket_local
				- strut_body.global_transform.basis * plug_local
		)
		# COM at the tire centre in body-local (= assembly − body origin).
		if wheel_body is RigidBody3D:
			(wheel_body as RigidBody3D).center_of_mass = (
				hub_local - socket_local + plug_local
			)
		var up_world: Vector3 = (
			strut_body.global_transform.basis * up_local
		).normalized()
		var travel_m: float = (
			suspension_state.travel_m
			if suspension_state.travel_m > 0.0
			else suspension_def.suspension_travel_m
		)
		# Tip on socket → droop; compression is hub rise along up.
		var bind_compression: float = clampf(
			(
				wheel_body.to_global(hub_local)
				- strut_body.to_global(socket_local)
			).dot(up_world),
			0.0,
			travel_m
		)
		var joint := Generic6DOFJoint3D.new()
		joint.name = "%s%d_%d" % [
			WHEEL_JOINT_NAME_PREFIX,
			assembly_id,
			int(spec.get("joint_id", 0)),
		]
		projection.add_child(joint)
		joint.global_transform = Transform3D(
			strut_body.global_transform.basis
				* WheelBodyProjectionUtil.joint_basis(frame),
			strut_body.global_transform * socket_local
		)
		joint.node_a = joint.get_path_to(strut_body)
		joint.node_b = joint.get_path_to(wheel_body)
		var spring_stiffness: float = (
			suspension_state.spring_stiffness_n_per_m
			if suspension_state.spring_stiffness_n_per_m >= 0.0
			else suspension_def.spring_stiffness_n_per_m
		)
		var spring_damping: float = (
			suspension_state.spring_damping_n_s_per_m
			if suspension_state.spring_damping_n_s_per_m >= 0.0
			else suspension_def.spring_damping_n_s_per_m
		)
		var max_steer_rad: float = (
			wheel_state.max_steering_angle_rad
			if wheel_state.max_steering_angle_rad >= 0.0
			else definition.max_steering_angle_rad
		)
		WheelBodyProjectionUtil.configure_wheel_joint(
			joint,
			travel_m,
			spring_stiffness,
			spring_damping,
			suspension_def.max_suspension_force_n,
			wheel_state.steerable,
			max_steer_rad,
			bind_compression
		)
		# SE-style own-grid filter: the wheel is solid for the world but never
		# for its own assembly (tire overlaps the strut by construction).
		for other_variant: Variant in groups_map.values():
			var other: PhysicsBody3D = other_variant as PhysicsBody3D
			if other == null or other == wheel_body:
				continue
			wheel_body.add_collision_exception_with(other)
			other.add_collision_exception_with(wheel_body)
		records.append({
			"joint_id": int(spec.get("joint_id", 0)),
			"wheel_element_id": wheel_element_id,
			"suspension_element_id": suspension_element_id,
			"constraint": joint,
			"strut_body": strut_body,
			"wheel_body": wheel_body,
			"hub_local": hub_local,
			"socket_local": socket_local,
			"plug_local": plug_local,
			"up_local": up_local,
			"axle_local": Vector3(frame["axle"]),
			"forward_local": Vector3(frame["forward"]),
			"bind_compression_m": bind_compression,
			"cfg_travel_m": travel_m,
			"cfg_stiffness": spring_stiffness,
			"cfg_damping": spring_damping,
			"cfg_max_force": suspension_def.max_suspension_force_n,
			"cfg_steerable": wheel_state.steerable,
			"cfg_friction": (
				wheel_body.physics_material_override.friction
				if wheel_body.physics_material_override != null
				else 1.0
			),
			"motor_target_v": 0.0,
			"motor_limit_n": 0.0,
			"steer_target_rad": 0.0,
			"steer_written_rad": 0.0,
		})
	return records

static func tick_wheel_bodies(projection, delta: float) -> void:
	if projection._world == null or delta <= 0.0:
		return
	var t0: int = Time.get_ticks_usec()
	projection._ensure_tick_key_caches()
	for assembly_id: int in projection._bodies_keys_cache:
		projection._update_parking_freeze(assembly_id)
	var t_freeze: int = Time.get_ticks_usec()
	var wheel_records_ticked: int = 0
	for assembly_id: int in projection._wheel_constraints_keys_cache:
		var assembly: SimulationAssembly = projection._world.get_assembly_raw(assembly_id)
		if assembly == null or assembly.tombstoned:
			continue
		var root_body: PhysicsBody3D = projection.get_physics_body(assembly_id)
		if root_body is RigidBody3D and (root_body as RigidBody3D).freeze:
			continue
		var locomotion: AssemblyLocomotionController = projection._world.get_locomotion_controller(assembly_id)
		var active_input: bool = locomotion != null and locomotion.has_active_input()
		for record_variant: Variant in projection._wheel_constraints[assembly_id]:
			if record_variant is Dictionary:
				WheelPhysicsTickCoordinator.tick_wheel_record(projection, 
					record_variant,
					locomotion,
					root_body,
					active_input,
					delta
				)
				wheel_records_ticked += 1
	var t_end: int = Time.get_ticks_usec()
	projection._last_tick_breakdown_us["wheel_bodies_parking_freeze"] = t_freeze - t0
	projection._last_tick_breakdown_us["wheel_bodies_per_wheel"] = t_end - t_freeze
	projection._last_tick_breakdown_us["wheel_bodies_records_ticked"] = wheel_records_ticked

static func tick_wheel_record(
	projection,
	record: Dictionary,
	locomotion: AssemblyLocomotionController,
	root_body: PhysicsBody3D,
	active_input: bool,
	delta: float
) -> void:
	var constraint: Generic6DOFJoint3D = (
		record.get("constraint") as Generic6DOFJoint3D
	)
	var strut_body: PhysicsBody3D = record.get("strut_body")
	var wheel_body: RigidBody3D = record.get("wheel_body")
	var wheel_element_id: int = int(record.get("wheel_element_id", 0))
	var suspension_element_id: int = int(record.get("suspension_element_id", 0))
	if (
		constraint == null
		or not is_instance_valid(constraint)
		or strut_body == null
		or not is_instance_valid(strut_body)
		or wheel_body == null
		or not is_instance_valid(wheel_body)
	):
		projection._world.store_wheel_runtime(
			wheel_element_id,
			suspension_element_id,
			{"status": &"invalid_body", "powered": false, "grounded": false}
		)
		return
	var wheel_element: SimulationElement = projection._world.get_element(wheel_element_id)
	var suspension: SimulationElement = projection._world.get_element(suspension_element_id)
	var wheel_def: WheelDefinition = (
		wheel_element.get_archetype().wheel_definition
		if wheel_element != null and wheel_element.get_archetype() != null
		else null
	)
	var suspension_def: SuspensionDefinition = (
		suspension.get_archetype().suspension_definition
		if suspension != null and suspension.get_archetype() != null
		else null
	)
	if wheel_def == null or suspension_def == null:
		return
	var wheel_state: WheelInstanceState = projection._world.ensure_wheel_instance_state(wheel_element_id)
	var suspension_state: SuspensionInstanceState = projection._world.ensure_suspension_instance_state(
		suspension_element_id
	)

	# --- Slider drift → live joint retune (rare; guarded by cached values) ---
	var bind_compression: float = float(record.get("bind_compression_m", 0.0))
	var travel_m: float = (
		suspension_state.travel_m
		if suspension_state.travel_m > 0.0
		else suspension_def.suspension_travel_m
	)
	if travel_m != float(record.get("cfg_travel_m", NAN)):
		WheelBodyProjectionUtil.update_travel_limit(
			constraint,
			travel_m,
			bind_compression
		)
		record["cfg_travel_m"] = travel_m
	var spring_stiffness: float = (
		suspension_state.spring_stiffness_n_per_m
		if suspension_state.spring_stiffness_n_per_m >= 0.0
		else suspension_def.spring_stiffness_n_per_m
	)
	var spring_damping: float = (
		suspension_state.spring_damping_n_s_per_m
		if suspension_state.spring_damping_n_s_per_m >= 0.0
		else suspension_def.spring_damping_n_s_per_m
	)
	if (
		spring_stiffness != float(record.get("cfg_stiffness", NAN))
		or spring_damping != float(record.get("cfg_damping", NAN))
	):
		WheelBodyProjectionUtil.update_suspension_spring(
			constraint,
			spring_stiffness,
			spring_damping,
			suspension_def.max_suspension_force_n,
			bind_compression
		)
		record["cfg_stiffness"] = spring_stiffness
		record["cfg_damping"] = spring_damping
	var max_steer_rad: float = (
		wheel_state.max_steering_angle_rad
		if wheel_state.max_steering_angle_rad >= 0.0
		else wheel_def.max_steering_angle_rad
	)
	if (
		wheel_state.steerable != bool(record.get("cfg_steerable", false))
		or not is_equal_approx(
			max_steer_rad,
			float(record.get("cfg_max_steer_rad", NAN))
		)
	):
		WheelBodyProjectionUtil.update_steer_limit(
			constraint,
			wheel_state.steerable,
			max_steer_rad
		)
		record["cfg_steerable"] = wheel_state.steerable
		record["cfg_max_steer_rad"] = max_steer_rad
	var friction: float = WheelBodyProjectionUtil.tire_friction(
		wheel_def,
		wheel_state.grip_scale
	)
	if (
		absf(friction - float(record.get("cfg_friction", -1.0))) > 0.0005
		and wheel_body.physics_material_override != null
	):
		wheel_body.physics_material_override.friction = friction
		record["cfg_friction"] = friction

	# --- Commands ---
	var operational: bool = (
		wheel_element != null and wheel_element.is_operational()
		and suspension != null and suspension.is_operational()
	)
	var powered: bool = operational and WheelPhysicsTickCoordinator.is_wheel_powered(projection, wheel_element_id)
	var drive_command: float = 0.0
	var brake_command: float = 0.0
	var steering_command: float = 0.0
	# Assembly-wide PB latch always holds (SE safety), even when Control Wheels
	# is OFF. Pilot drive/steer/service-brake only when wheels_route_enabled.
	var parking_hold: bool = locomotion != null and locomotion.is_parking_brake()
	var wheels_route: bool = (
		locomotion != null and locomotion.is_wheels_route_enabled()
	)
	if locomotion != null and wheels_route:
		drive_command = locomotion.drive_command
		brake_command = locomotion.brake_command
		steering_command = locomotion.steering_command
	if wheel_state.drive_inverted:
		drive_command = -drive_command
	if parking_hold:
		drive_command = 0.0
		brake_command = 1.0
	var telemetry_drive: float = drive_command
	if not powered:
		drive_command = 0.0

	var measured: Dictionary = WheelBodyProjectionUtil.measure_wheel_state(
		strut_body,
		wheel_body,
		record.get("hub_local", Vector3.ZERO),
		record.get("up_local", Vector3.UP),
		record.get("axle_local", Vector3.RIGHT),
		wheel_def.radius_m,
		travel_m,
		record.get("socket_local", Vector3(INF, INF, INF))
	)
	if measured.is_empty():
		return

	# --- Steering servo target (rate-limited, like the raycast model) ---
	var steer_goal: float = 0.0
	if wheel_state.steerable:
		steer_goal = steering_command * max_steer_rad
	var steer_target: float = move_toward(
		float(record.get("steer_target_rad", 0.0)),
		steer_goal,
		wheel_def.steering_response * delta
	)
	record["steer_target_rad"] = steer_target
	var grounded_now: bool = (
		float(measured.get("compression_m", 0.0))
		> WheelBodyProjectionUtil.GROUNDED_COMPRESSION_EPS_M
	)
	if wheel_state.steerable:
		var up_world: Vector3 = measured.get("up_world", Vector3.UP)
		var steer_rate: float = (
			wheel_body.angular_velocity
			- (
				(strut_body as RigidBody3D).angular_velocity
				if strut_body is RigidBody3D
				else Vector3.ZERO
			)
		).dot(up_world)
		var steer_torque: float = WheelBodyProjectionUtil.steering_torque_nm(
			wheel_body,
			up_world,
			steer_target,
			float(measured.get("steering_angle_rad", 0.0)),
			steer_rate
		)
		# В воздухе жёсткий PD + раскрутка = гироскопический «ходун».
		if not grounded_now:
			steer_torque *= (
				WheelBodyProjectionUtil.AIRBORNE_STEER_TORQUE_SCALE
			)
		wheel_body.apply_torque(up_world * steer_torque)
		if strut_body is RigidBody3D:
			(strut_body as RigidBody3D).apply_torque(-up_world * steer_torque)

	# --- Drive/brake motor (solver-side; write only on change) ---
	var brake_torque: float = (
		wheel_state.brake_torque_n_m
		if wheel_state.brake_torque_n_m >= 0.0
		else wheel_def.brake_torque_n_m
	)
	var target_forward_rad_s: float = 0.0
	var torque_limit: float = 0.0
	if parking_hold:
		torque_limit = brake_torque
	elif absf(drive_command) > 0.0001:
		var commanded_rad_s: float = clampf(
			drive_command * wheel_def.max_angular_speed_rad_s,
			-wheel_def.max_angular_speed_rad_s,
			wheel_def.max_angular_speed_rad_s
		)
		var grounded_drive: bool = (
			float(measured.get("compression_m", 0.0))
			> WheelBodyProjectionUtil.GROUNDED_COMPRESSION_EPS_M
		)
		# Grounded: slip-limited near the friction peak (traction control).
		# Airborne: soft free-spin — full slam shook the strut (reaction +
		# gyro vs steer PD).
		if grounded_drive:
			target_forward_rad_s = (
				WheelBodyProjectionUtil.slip_limited_target_rad_s(
					commanded_rad_s,
					float(measured.get("ground_speed_mps", 0.0)),
					wheel_def.radius_m
				)
			)
		else:
			var prev_target: float = float(record.get("motor_target_v", 0.0))
			if not is_finite(prev_target):
				prev_target = float(measured.get("wheel_speed_rad_s", 0.0))
			target_forward_rad_s = move_toward(
				prev_target,
				commanded_rad_s,
				WheelBodyProjectionUtil.AIRBORNE_SPIN_ACCEL_RAD_S2 * delta
			)
		torque_limit = (
			wheel_def.drive_torque_n_m
			* clampf(wheel_state.drive_torque_scale, 0.0, 1.0)
		)
		if not grounded_drive:
			torque_limit *= WheelBodyProjectionUtil.AIRBORNE_DRIVE_TORQUE_SCALE
	elif absf(brake_command) > 0.0001:
		torque_limit = absf(brake_command) * brake_torque
		# Grounded service brake used target=0 at full torque — unlimited
		# longitudinal slip, tire saw, reaction into the strut. Same class of
		# bug as pre-TC drive slam (WHEEL-BODY-V1). Guest ~120 ms assembly
		# blend hides it; host feels raw Jolt. Slip-limit toward stop like
		# drive; airborne / parking keep hard lock (target stays 0).
		var grounded_brake: bool = (
			float(measured.get("compression_m", 0.0))
			> WheelBodyProjectionUtil.GROUNDED_COMPRESSION_EPS_M
		)
		if grounded_brake:
			target_forward_rad_s = (
				WheelBodyProjectionUtil.slip_limited_target_rad_s(
					0.0,
					float(measured.get("ground_speed_mps", 0.0)),
					wheel_def.radius_m
				)
			)
	if (
		target_forward_rad_s != float(record.get("motor_target_v", NAN))
		or torque_limit != float(record.get("motor_limit_n", NAN))
	):
		WheelBodyProjectionUtil.update_drive_motor(
			constraint,
			target_forward_rad_s,
			torque_limit
		)
		record["motor_target_v"] = target_forward_rad_s
		record["motor_limit_n"] = torque_limit
	if active_input:
		# Только на смене состояния: этот тик идёт на каждое колесо каждый кадр,
		# безусловная запись sleeping будила уже-разбуженные тела 12×/тик.
		if wheel_body.sleeping:
			wheel_body.sleeping = false
		if root_body is RigidBody3D and (root_body as RigidBody3D).sleeping:
			(root_body as RigidBody3D).sleeping = false

	# --- Telemetry (same keys the raycast model published) ---
	var compression: float = float(measured.get("compression_m", 0.0))
	var grounded: bool = compression > (
		WheelBodyProjectionUtil.GROUNDED_COMPRESSION_EPS_M
	)
	var status: StringName = &"ok"
	if not powered:
		status = &"no_power"
	elif not grounded:
		status = &"airborne"
	var normal_force: float = clampf(
		spring_stiffness * compression
		+ spring_damping * float(measured.get("compression_rate_mps", 0.0)),
		0.0,
		suspension_def.max_suspension_force_n
	)
	WheelBodyProjectionUtil.maybe_print_drive_probe(delta, {
		"wheel_id": wheel_element_id,
		"grounded": grounded,
		"compression_m": compression,
		"ground_speed_mps": float(measured.get("ground_speed_mps", 0.0)),
		"motor_target_v": target_forward_rad_s,
		"motor_limit_n": torque_limit,
		"brake_command": brake_command,
		"drive_command": drive_command,
		"normal_force_n": normal_force,
	})
	var reference_body: PhysicsBody3D = (
		root_body if root_body != null else strut_body
	)
	projection._world.store_wheel_runtime(wheel_element_id, suspension_element_id, {
		"status": status,
		"powered": powered,
		"grounded": grounded,
		"compression_m": compression,
		"suspension_length_m": maxf(travel_m - compression, 0.0),
		"wheel_speed": float(measured.get("wheel_speed_rad_s", 0.0)),
		"wheel_speed_rad_s": float(measured.get("wheel_speed_rad_s", 0.0)),
		"steering_angle_rad": float(measured.get("steering_angle_rad", 0.0)),
		# Цель серво руля: без неё «руль не туда/не вернулся» неотличимо от
		# «команда не доехала» — стенд ловил ровно эту неоднозначность.
		"steering_target_rad": steer_target,
		"socket_body_local": reference_body.to_local(
			Vector3(measured.get("socket_world", Vector3.ZERO))
		),
		"wheel_center_body_local": reference_body.to_local(
			Vector3(measured.get("hub_world", Vector3.ZERO))
		),
		"contact_world": Vector3(measured.get("contact_world", Vector3.ZERO)),
		"contact_normal_world": Vector3(measured.get("up_world", Vector3.UP)),
		"normal_force_n": normal_force if grounded else 0.0,
		"longitudinal_force_n": 0.0,
		"lateral_force_n": 0.0,
		"slip_speed_mps": float(measured.get("slip_speed_mps", 0.0)),
		"lateral_speed_mps": 0.0,
		"drive_command": telemetry_drive,
		"brake_command": brake_command,
		"body_group_id": int(wheel_body.get_meta("body_group_id", 0)),
	})

static func is_wheel_powered(projection, wheel_element_id: int) -> bool:
	var runtime: IndustryElementRuntime = projection._world.ensure_industry_element_runtime(wheel_element_id)
	return runtime.machine_enabled and runtime.powered

## Soften locomotive↔terrain contact cost without removing the safety net:
## no CCD, no bounce. Applies to chassis/carriage bodies only — wheel bodies
## carry their own tire material (see configure_wheel_rigid).
static func apply_locomotive_rigid_tuning(
	projection,
	assembly_id: int,
	rigid: RigidBody3D
) -> void:
	if (
		rigid == null
		or projection._world == null
		or not WheelSimulationService.is_locomotive_assembly(
			projection._world,
			assembly_id
		)
	):
		return
	rigid.continuous_cd = false
	rigid.physics_material_override = projection._get_locomotive_physics_material()
	rigid.collision_layer = COLLISION_LAYER_ASSEMBLY
	rigid.collision_mask = COLLISION_MASK_WHEEL_LOCOMOTIVE
	rigid.set_meta("wheel_loco_terrain_exempt", true)


static func sync_wheel_loco_body_physics(
	projection,
	assembly_id: int,
	rigid: RigidBody3D
) -> void:
	if rigid == null:
		return
	if WheelSimulationService.is_locomotive_assembly(projection._world, assembly_id):
		WheelPhysicsTickCoordinator.apply_locomotive_rigid_tuning(
			projection,
			assembly_id,
			rigid
		)
		return
	if not rigid.has_meta("wheel_loco_terrain_exempt"):
		return
	rigid.collision_layer = COLLISION_LAYER_ASSEMBLY
	rigid.collision_mask = COLLISION_MASK_ASSEMBLY
	rigid.physics_material_override = projection._get_assembly_physics_material()
	rigid.remove_meta("wheel_loco_terrain_exempt")
