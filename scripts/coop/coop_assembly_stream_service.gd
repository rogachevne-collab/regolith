class_name CoopAssemblyStreamService
extends RefCounted


## Guest driver → ghost on host; host driver → clear any guest claim on that assembly.
static func host_update_physics_ownership_from_seat(
	session,
	result: Dictionary,
	seat_peer: int,
	seat_uid: String
) -> void:
	if session._mode != session.Mode.HOST:
		return
	if StringName(result.get("command_kind", &"")) != &"toggle_control_seat":
		return
	if StringName(result.get("status", &"")) != &"ok":
		return
	var data: Dictionary = result.get("data", {})
	var assembly_id := int(data.get("assembly_id", 0))
	var passenger := bool(data.get("passenger", false))
	var seated := bool(data.get("seated", false))
	if seat_peer > 1 and not seat_uid.is_empty():
		# Remote peer (ENet host peer id is 1).
		if seated and not passenger and assembly_id > 0:
			set_remote_physics_owner(session, assembly_id, seat_uid)
		else:
			clear_remote_physics_owner_for_uid(session, seat_uid)
		return
	# Host-local seat command (no pending peer): reclaim physics if host drives.
	if seated and not passenger and assembly_id > 0:
		clear_remote_physics_owner_assembly(session, assembly_id)


static func set_remote_physics_owner(session, assembly_id: int, uid: String) -> void:
	if assembly_id <= 0 or uid.is_empty():
		return
	# One owner per assembly; drop a previous claim on this assembly or uid.
	clear_remote_physics_owner_assembly(session, assembly_id)
	clear_remote_physics_owner_for_uid(session, uid)
	session._remote_physics_owners[assembly_id] = uid
	if session._session != null and session._session.projection != null:
		session._session.projection.set_assembly_network_ghost(assembly_id, true)


static func clear_remote_physics_owner_for_uid(session, uid: String) -> void:
	if uid.is_empty():
		return
	var drop: Array[int] = []
	for assembly_id_variant: Variant in session._remote_physics_owners.keys():
		if str(session._remote_physics_owners[assembly_id_variant]) == uid:
			drop.append(int(assembly_id_variant))
	for assembly_id: int in drop:
		clear_remote_physics_owner_assembly(session, assembly_id)


static func clear_remote_physics_owner_assembly(session, assembly_id: int) -> void:
	if assembly_id <= 0 or not session._remote_physics_owners.has(assembly_id):
		return
	# Persist last streamed pose into the kernel before unghost reprojects —
	# otherwise exit/reclaim snaps the assembly back to the sit/spawn pose.
	commit_streamed_assembly_pose(session, assembly_id)
	var world: SimulationWorld = session._world()
	if world != null:
		var loco: AssemblyLocomotionController = (
			world.get_locomotion_controller(assembly_id)
		)
		if loco != null:
			# Mirrored throttle was for electric demand only; clear so host
			# parking-freeze can settle after live physics returns.
			loco.drive_command = 0.0
	session._remote_physics_owners.erase(assembly_id)
	if session._session != null and session._session.projection != null:
		session._session.projection.set_assembly_network_ghost(assembly_id, false)
	forget_observer_assembly(session, assembly_id)
	session._assembly_streams.erase(assembly_id)


## Host: write newest buffer sample into assembly.motion so unghost / snapshot
## / seat-exit see the driven pose, not the pre-sit spawn.
static func commit_streamed_assembly_pose(session, assembly_id: int) -> void:
	var stream: Variant = session._assembly_streams.get(assembly_id)
	if stream == null or not stream is Dictionary:
		return
	var samples: Array = (stream as Dictionary).get("samples", [])
	if samples.is_empty():
		return
	var newest: Dictionary = samples[samples.size() - 1]
	var motions: Variant = newest.get("motions", {})
	if not motions is Dictionary or (motions as Dictionary).is_empty():
		return
	var world: SimulationWorld = session._world()
	if world == null or world.get_assembly_raw(assembly_id) == null:
		return
	world.sync_assembly_body_group_motions(assembly_id, motions)
	var wheels: Variant = newest.get("wheels", {})
	if wheels is Dictionary:
		for wheel_id_variant: Variant in wheels:
			var scalars: Variant = wheels[wheel_id_variant]
			if not scalars is Dictionary:
				continue
			world.store_wheel_runtime(
				int(wheel_id_variant),
				0,
				{
					"compression_m": float(scalars.get("c", 0.0)),
					"steering_angle_rad": float(scalars.get("s", 0.0)),
					"wheel_speed": float(scalars.get("v", 0.0)),
					"wheel_speed_rad_s": float(scalars.get("v", 0.0)),
				}
			)


static func begin_local_driver_physics(session, assembly_id: int) -> void:
	if session._mode != session.Mode.CLIENT or assembly_id <= 0:
		return
	if session._local_physics_assembly_id == assembly_id:
		return
	end_local_driver_physics(session)
	session._local_physics_assembly_id = assembly_id
	var world: SimulationWorld = session._world()
	if world != null:
		world.get_locomotion_controller(assembly_id).activate()
	if session._session != null and session._session.projection != null:
		session._session.projection.begin_local_assembly_sim(assembly_id)
	# Re-seat onto the new simulated body after reproject.
	if session._gateway != null:
		session._gateway.ensure_local_seat_binding()


static func end_local_driver_physics(session) -> void:
	if session._local_physics_assembly_id <= 0:
		return
	var assembly_id: int = session._local_physics_assembly_id
	session._local_physics_assembly_id = 0
	if session._session != null and session._session.projection != null:
		session._session.projection.end_local_assembly_sim(assembly_id)


## Host: stream root + child body-group motions of every assembly that is
## actually moving (unreliable_ordered, like poses — a lost frame is replaced
## 66 ms later). Parked/sleeping assemblies cost nothing; clients keep them
## where the last snapshot put them. The host's Jolt read-back refreshes
## assembly.motion / body_group_motions every physics tick, so the world state
## read here is current.
##
## Packet shape per assembly: `{ "m": {group_id: motion_dict}, "w": {wheel_id: scalars} }`.
## `"m"` is root + non-wheel groups only. Wheels are observer-reconstructed from
## `"w"` scalars (compression / steer / spin rate) glued to the strut.
## Legacy flat `{group_id: motion}` still parses via `_unpack_assembly_stream_entry`.
static func broadcast_assembly_motion(session) -> void:
	var registry: CoopPeerRegistry = session._registry
	if registry.peer_ids().is_empty():
		return
	var world: SimulationWorld = session._world()
	if world == null:
		return
	var batch: Dictionary = {}
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly.tombstoned or assembly.motion == null:
			continue
		# Guest-owned assemblies: host is a ghost — owner uploads via
		# `_srv_assembly_motion` and we rebroadcast that path separately.
		if session._remote_physics_owners.has(assembly.assembly_id):
			continue
		var packed: Dictionary = session._pack_assembly_motion_entry(
			assembly.assembly_id, true
		)
		if not packed.is_empty():
			batch[assembly.assembly_id] = packed
	if not batch.is_empty():
		session.rpc("_cli_assembly_motion", batch)


static func cli_assembly_motion(session, batch: Dictionary) -> void:
	# Clients always; host also when rebroadcasting guest-owned ghosts to self
	# is not needed — host applies guest uploads in `_srv_assembly_motion`.
	if session._mode == session.Mode.OFFLINE:
		return
	if session._mode == session.Mode.HOST:
		return
	# Join in progress: snapshot/terrain not finished — blending here crashed
	# guests after bulk applied (stale streams on half-rebuilt projection).
	if not session._replica_ready:
		return
	# Local driver already simulates this assembly — ignore host echo.
	if session._local_physics_assembly_id > 0 and batch.has(session._local_physics_assembly_id):
		batch = batch.duplicate()
		batch.erase(session._local_physics_assembly_id)
		if batch.is_empty():
			return
	ingest_assembly_motion_batch(session, batch)


static func srv_assembly_motion(
	session,
	assembly_id: int,
	entry: Dictionary
) -> void:
	if session._mode != session.Mode.HOST:
		return
	var peer: int = session.multiplayer.get_remote_sender_id()
	var uid: String = session._registry.uid_of(peer)
	if uid.is_empty():
		return
	if str(session._remote_physics_owners.get(assembly_id, "")) != uid:
		return
	var world: SimulationWorld = session._world()
	if world == null or world.get_assembly_raw(assembly_id) == null:
		return
	# Mirror driver throttle onto host loco for IndustryElectricBudget demand
	# (ghost assembly does not run wheel ticks).
	var loco: AssemblyLocomotionController = (
		world.get_locomotion_controller(assembly_id)
	)
	if loco != null:
		if not loco.is_activated():
			loco.activate()
		loco.drive_command = float(entry.get("d", 0.0))
	ingest_assembly_motion_batch(session, {assembly_id: entry}, true)
	# Relay to other clients (not the owner — they simulate locally).
	# Strip drive channel — observers only need poses/scalars.
	var relay: Dictionary = entry.duplicate(true)
	relay.erase("d")
	session.rpc("_cli_assembly_motion", {assembly_id: relay})


static func ingest_assembly_motion_batch(
	session,
	batch: Dictionary,
	host_ghost: bool = false
) -> void:
	var world: SimulationWorld = session._world()
	if world == null:
		return
	for assembly_id_variant: Variant in batch:
		var assembly_id := int(assembly_id_variant)
		if world.get_assembly_raw(assembly_id) == null:
			continue
		var unpacked: Dictionary = session._unpack_assembly_stream_entry(
			batch[assembly_id_variant] as Dictionary
		)
		var motions_raw: Dictionary = unpacked["motions_raw"]
		var wheels: Dictionary = unpacked["wheels"]
		var motions: Dictionary = {}
		for group_id_variant: Variant in motions_raw:
			var motion: AssemblyMotionState = AssemblyMotionState.from_dict(
				motions_raw[group_id_variant]
			)
			if motion.is_valid():
				motions[int(group_id_variant)] = motion
		if motions.is_empty():
			continue
		world.sync_assembly_body_group_motions(assembly_id, motions)
		for wheel_id_variant: Variant in wheels:
			var scalars: Dictionary = wheels[wheel_id_variant]
			if not scalars is Dictionary:
				continue
			world.store_wheel_runtime(
				int(wheel_id_variant),
				0,
				{
					"compression_m": float(scalars.get("c", 0.0)),
					"steering_angle_rad": float(scalars.get("s", 0.0)),
					"wheel_speed": float(scalars.get("v", 0.0)),
					"wheel_speed_rad_s": float(scalars.get("v", 0.0)),
				}
			)
		# Host ghost: wheel poses no longer ride in `"m"`. Without rewriting
		# wheel body_group_motions here they stay at the sit pose while the
		# chassis streams away — IndustryElectricBudget then sees wheels
		# outside distributor radius → powered=false → guest loses drive.
		if host_ghost:
			sync_ghost_wheel_kernel_motions(session, assembly_id, motions, wheels)
		var stream: Dictionary = session._assembly_streams.get_or_add(
			assembly_id,
			{"root_id": 0, "samples": []}
		)
		stream["root_id"] = world.root_body_group_id(assembly_id)
		var samples: Array = stream["samples"]
		samples.append({
			"t": Time.get_ticks_msec(),
			"motions": motions,
			"wheels": wheels,
		})
		while samples.size() > session.ASSEMBLY_BUFFER_LIMIT:
			samples.pop_front()


## Host: derive wheel group kernel poses from strut + scalars so electric
## radius / element_world_transform stay on the driven vehicle.
static func sync_ghost_wheel_kernel_motions(
	session,
	assembly_id: int,
	chassis_motions: Dictionary,
	wheels: Dictionary
) -> void:
	var world: SimulationWorld = session._world()
	if world == null:
		return
	var root_id: int = world.root_body_group_id(assembly_id)
	var compiled: Dictionary = world.compile_body_groups(assembly_id)
	var wheel_motions: Dictionary = {}
	for spec_variant: Variant in compiled.get("wheel_specs", []):
		if not spec_variant is Dictionary:
			continue
		var spec: Dictionary = spec_variant
		var wheel_gid := int(spec.get("wheel_group_id", 0))
		var strut_gid := int(spec.get("suspension_group_id", 0))
		var wheel_id := int(spec.get("wheel_element_id", 0))
		if wheel_gid <= 0 or wheel_id <= 0:
			continue
		var strut_motion: AssemblyMotionState = chassis_motions.get(
			strut_gid,
			chassis_motions.get(root_id)
		)
		if strut_motion == null:
			continue
		var mount: Dictionary = (
			WheelBodyProjectionUtil.resolve_observer_wheel_mount(
				world,
				int(spec.get("suspension_element_id", 0)),
				wheel_id
			)
		)
		if mount.is_empty():
			continue
		var scalars: Variant = wheels.get(wheel_id)
		if not scalars is Dictionary:
			scalars = wheels.get(str(wheel_id), {})
		if not scalars is Dictionary:
			scalars = {}
		var wheel_xf: Transform3D = WheelBodyProjectionUtil.observer_wheel_global_transform(
			strut_motion.transform,
			mount,
			float(scalars.get("c", 0.0)),
			float(scalars.get("s", 0.0)),
			0.0
		)
		var wheel_motion := AssemblyMotionState.new()
		wheel_motion.transform = wheel_xf
		wheel_motion.linear_velocity = strut_motion.linear_velocity
		wheel_motion.angular_velocity = Vector3.ZERO
		wheel_motion.sleeping = false
		wheel_motion.frozen = false
		wheel_motions[wheel_gid] = wheel_motion
	if not wheel_motions.is_empty():
		world.sync_assembly_body_group_motions(assembly_id, wheel_motions)


static func tick_assembly_stream_blend(session, delta: float) -> void:
	var now: int = Time.get_ticks_msec()
	var render_t: int = now - session.ASSEMBLY_INTERP_DELAY_MS
	for assembly_id_variant: Variant in session._assembly_streams.keys():
		var assembly_id := int(assembly_id_variant)
		# Don't overwrite the assembly we simulate locally.
		if assembly_id == session._local_physics_assembly_id:
			continue
		var stream: Dictionary = session._assembly_streams[assembly_id_variant]
		var samples: Array = stream["samples"]
		if samples.is_empty():
			forget_observer_assembly(session, assembly_id)
			session._assembly_streams.erase(assembly_id_variant)
			continue
		var newest: Dictionary = samples[samples.size() - 1]
		if now - int(newest["t"]) > session.ASSEMBLY_STALE_MS:
			forget_observer_assembly(session, assembly_id)
			session._assembly_streams.erase(assembly_id_variant)
			continue
		var previous: Dictionary = newest
		var factor := 1.0
		for index in range(samples.size() - 1):
			var a: Dictionary = samples[index]
			var b: Dictionary = samples[index + 1]
			if render_t < int(a["t"]) or render_t > int(b["t"]):
				continue
			previous = a
			newest = b
			var span := maxf(float(int(b["t"]) - int(a["t"])), 1.0)
			factor = clampf(float(render_t - int(a["t"])) / span, 0.0, 1.0)
			break
		apply_assembly_blend(
			session,
			assembly_id,
			int(stream["root_id"]),
			previous["motions"],
			newest["motions"],
			previous.get("wheels", {}),
			newest.get("wheels", {}),
			factor,
			delta
		)


## Write blended group poses onto frozen kinematic bodies. Chassis groups
## lerp in world space; wheels are reconstructed from streamed scalars on the
## already-blended strut (no body-transform slerp — that jittered spin/air).
static func apply_assembly_blend(
	session,
	assembly_id: int,
	root_id: int,
	from_motions: Dictionary,
	to_motions: Dictionary,
	from_wheels: Dictionary,
	to_wheels: Dictionary,
	factor: float,
	delta: float
) -> void:
	var projection = session._session.projection
	var world: SimulationWorld = session._world()
	var wheel_specs: Array = []
	if world != null:
		var compiled: Dictionary = world.compile_body_groups(assembly_id)
		wheel_specs = compiled.get("wheel_specs", []) as Array
	var wheel_gids: Dictionary = {}
	for spec_variant: Variant in wheel_specs:
		if spec_variant is Dictionary:
			wheel_gids[int(spec_variant.get("wheel_group_id", 0))] = true
	# Pass 1 — root + non-wheel groups (world-space blend).
	for group_id_variant: Variant in to_motions:
		var group_id := int(group_id_variant)
		if wheel_gids.has(group_id):
			continue
		write_blended_body_pose(
			session,
			projection,
			assembly_id,
			root_id,
			group_id,
			from_motions,
			to_motions,
			factor
		)
	# Pass 2 — scalar reconstruct per wheel onto blended strut.
	apply_observer_wheel_scalars(
		session,
		assembly_id,
		root_id,
		wheel_specs,
		from_wheels,
		to_wheels,
		factor,
		delta
	)


static func apply_observer_wheel_scalars(
	session,
	assembly_id: int,
	root_id: int,
	wheel_specs: Array,
	from_wheels: Dictionary,
	to_wheels: Dictionary,
	factor: float,
	delta: float
) -> void:
	if wheel_specs.is_empty() or to_wheels.is_empty():
		return
	var projection = session._session.projection
	var world: SimulationWorld = session._world()
	if projection == null or world == null:
		return
	var mounts: Dictionary = session._observer_wheel_mounts.get_or_add(assembly_id, {})
	for spec_variant: Variant in wheel_specs:
		if not spec_variant is Dictionary:
			continue
		var spec: Dictionary = spec_variant
		var wheel_id := int(spec.get("wheel_element_id", 0))
		var wheel_gid := int(spec.get("wheel_group_id", 0))
		var strut_gid := int(spec.get("suspension_group_id", 0))
		if wheel_id <= 0 or wheel_gid <= 0:
			continue
		var to_s: Variant = to_wheels.get(wheel_id)
		if not to_s is Dictionary:
			# Packet may key wheels as String after RPC.
			to_s = to_wheels.get(str(wheel_id))
		if not to_s is Dictionary:
			continue
		var from_s: Variant = from_wheels.get(wheel_id, to_s)
		if not from_s is Dictionary:
			from_s = from_wheels.get(str(wheel_id), to_s)
		var from_dict: Dictionary = from_s
		var to_dict: Dictionary = to_s
		var compression := lerpf(
			float(from_dict.get("c", 0.0)),
			float(to_dict.get("c", 0.0)),
			factor
		)
		var steer := lerpf(
			float(from_dict.get("s", 0.0)),
			float(to_dict.get("s", 0.0)),
			factor
		)
		var speed := lerpf(
			float(from_dict.get("v", 0.0)),
			float(to_dict.get("v", 0.0)),
			factor
		)
		var spin := float(session._observer_wheel_spin.get(wheel_id, 0.0))
		spin += speed * maxf(delta, 0.0)
		# Keep angle bounded so the float doesn't grow without limit.
		spin = fposmod(spin, TAU)
		session._observer_wheel_spin[wheel_id] = spin
		var mount: Variant = mounts.get(wheel_id)
		if not mount is Dictionary or (mount as Dictionary).is_empty():
			mount = WheelBodyProjectionUtil.resolve_observer_wheel_mount(
				world,
				int(spec.get("suspension_element_id", 0)),
				wheel_id
			)
			if mount is Dictionary and not (mount as Dictionary).is_empty():
				mounts[wheel_id] = mount
		if not mount is Dictionary or (mount as Dictionary).is_empty():
			continue
		var strut_body: PhysicsBody3D = (
			projection.get_physics_body(assembly_id)
			if strut_gid == root_id or strut_gid <= 0
			else projection.get_group_physics_body(assembly_id, strut_gid)
		)
		var wheel_body: PhysicsBody3D = projection.get_group_physics_body(
			assembly_id,
			wheel_gid
		)
		if (
			strut_body == null
			or not is_instance_valid(strut_body)
			or wheel_body == null
			or not is_instance_valid(wheel_body)
		):
			continue
		wheel_body.global_transform = (
			WheelBodyProjectionUtil.observer_wheel_global_transform(
				strut_body.global_transform,
				mount,
				compression,
				steer,
				spin
			)
		)


static func forget_observer_assembly(session, assembly_id: int) -> void:
	var mounts: Variant = session._observer_wheel_mounts.get(assembly_id)
	if mounts is Dictionary:
		for wheel_id_variant: Variant in mounts:
			session._observer_wheel_spin.erase(int(wheel_id_variant))
	session._observer_wheel_mounts.erase(assembly_id)


static func write_blended_body_pose(
	session,
	projection,
	assembly_id: int,
	root_id: int,
	group_id: int,
	from_motions: Dictionary,
	to_motions: Dictionary,
	factor: float
) -> void:
	var to_motion: AssemblyMotionState = to_motions.get(group_id)
	if to_motion == null:
		return
	var from_motion: AssemblyMotionState = from_motions.get(group_id, to_motion)
	var body: PhysicsBody3D = (
		projection.get_physics_body(assembly_id)
		if group_id == root_id
		else projection.get_group_physics_body(assembly_id, group_id)
	)
	if body == null or not is_instance_valid(body):
		return
	var from_q := Quaternion(from_motion.transform.basis)
	var to_q := Quaternion(to_motion.transform.basis)
	body.global_transform = Transform3D(
		Basis(from_q.slerp(to_q, factor)),
		from_motion.transform.origin.lerp(to_motion.transform.origin, factor)
	)


static func tick_local_owner_motion_upload(session, delta: float) -> void:
	if session._mode != session.Mode.CLIENT or session._local_physics_assembly_id <= 0:
		return
	session._owner_motion_accum += delta
	if session._owner_motion_accum < session.ASSEMBLY_INTERVAL:
		return
	session._owner_motion_accum = 0.0
	var assembly_id: int = session._local_physics_assembly_id
	# Always pack while seated — parked speed gate would freeze the host ghost
	# at crawl / between airborne velocity dips.
	var packed: Dictionary = session._pack_assembly_motion_entry(assembly_id, false)
	if packed.is_empty():
		return
	var drive_cmd := 0.0
	var world: SimulationWorld = session._world()
	if world != null:
		var loco: AssemblyLocomotionController = (
			world.get_locomotion_controller(assembly_id)
		)
		if loco != null:
			drive_cmd = loco.drive_command
	packed["d"] = drive_cmd
	session.rpc_id(1, "_srv_assembly_motion", assembly_id, packed)
