class_name GatewaySeatLocomotionService
extends RefCounted
## Seat / locomotion cluster extracted from `WorldCommandGateway` (wave 3 of the
## anti-god-object operation, mechanical move — behaviour unchanged).
##
## Owns enter / exit, the per-tick driver input path, the coop remote-driver
## stream and the client-side seat attach. Seat STATE stays on the gateway
## node (`_rover_seat_player` / `_rover_seat_assembly_id` /
## `_rover_seat_element_id` / `_rover_seat_passenger` / `_rover_seat_policy`),
## because the machine-command and read-model services read and write it there
## directly; this service assigns through `gateway._rover_seat_*`.
##
## `_rover_seat_policy` is a SHARED SeatControlState ref (R9 — no per-tick dup):
## never copy it into service-local state.
##
## Signal plumbing (`_bind_seat_evict_hook` / `_on_seat_occupant_evicted`) also
## stays on the node: those Callables are `call_deferred`-ed and connected, so
## their identity must not change.


## Broken / removed ControlSeat: clear locomotion and detach the driver.
## Occupancy row is already gone (world emitted after erase).
static func force_eject_seat_occupant(
	gateway,
	player_id: String,
	seat_element_id: int = 0,
	assembly_id: int = 0
) -> void:
	if (
		player_id.is_empty()
		or gateway._session == null
		or gateway._session.world == null
	):
		return
	if assembly_id <= 0 and seat_element_id > 0:
		var seat: SimulationElement = gateway._session.world.get_element(
			seat_element_id
		)
		if seat != null:
			assembly_id = seat.assembly_id
	if assembly_id > 0:
		var locomotion: AssemblyLocomotionController = (
			gateway._session.world.get_locomotion_controller(assembly_id)
		)
		locomotion.clear_driver_input()
		if locomotion.is_parking_brake():
			locomotion.set_brake_command(1.0)
	gateway._session.world.clear_player_seat_context(player_id)
	var local_uid := PlayerIdentity.local_uid()
	if player_id == local_uid:
		if gateway._rover_seat_element_id > 0 or gateway._rover_seat_assembly_id > 0:
			release_local_seat_attach(gateway)
		elif (
			gateway._rover_seat_player != null
			and gateway._rover_seat_player.has_method("is_in_vehicle")
			and bool(gateway._rover_seat_player.call("is_in_vehicle"))
		):
			release_local_seat_attach(gateway)
		return
	if gateway._seat_force_release_notify.is_valid():
		gateway._seat_force_release_notify.call(
			player_id,
			seat_element_id,
			assembly_id
		)


static func _toggle_control_seat(
	gateway,
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	var keys: Dictionary = gateway._target_card_keys(target)
	# control_terminal несёт роль ControlSeat (нужна для бара), но не садит —
	# ToolController перехватывает interact для него раньше toggle_control_seat
	# (CONTROL-ACTIONS-V0 «Хосты бара»). Второй слой защиты: если что-то всё же
	# дошло сюда, явно отказать, а не пытаться посадить игрока в консоль.
	if str(keys.get("archetype_id", "")) == "control_terminal":
		return gateway._result(&"invalid_target")
	var is_local_actor: bool = gateway.actor_uid == PlayerIdentity.local_uid()
	if (
		StringName(target["target_kind"])
		!= InteractionHit.KIND_CONTROL_SEAT
	):
		if (
			str(keys.get("archetype_id", "")) == "cockpit"
			and InteractionHit.element_id_from(target) > 0
		):
			var cockpit_source: Node3D = command.get("source")
			if cockpit_source == null and is_local_actor:
				return gateway._result(&"not_ready")
			if _actor_wants_seat_exit(gateway, cockpit_source, is_local_actor):
				return _exit_rover_seat(gateway, cockpit_source, is_local_actor)
			return _enter_rover_seat(
				gateway,
				cockpit_source,
				InteractionHit.element_id_from(target),
				InteractionHit.assembly_id_from(target),
				is_local_actor,
				false
			)
		return gateway._result(&"invalid_target")
	var seat_source: Node3D = command.get("source")
	if seat_source == null and is_local_actor:
		return gateway._result(&"not_ready")
	if _actor_wants_seat_exit(gateway, seat_source, is_local_actor):
		return _exit_rover_seat(gateway, seat_source, is_local_actor)
	var vehicle: Object = target.get("collider")
	var element_id := InteractionHit.element_id_from(target)
	# Remote in-seat E uses KIND_CONTROL_SEAT with the seat element_id (meta).
	# After occupancy was pruned for a broken seat, still prefer exit over enter.
	if (
		not is_local_actor
		and element_id > 0
		and StringName(target.get("target_kind", &""))
		== InteractionHit.KIND_CONTROL_SEAT
		and bool(target.get("control_seat", false))
	):
		var remote_seat: SimulationElement = (
			gateway._session.world.get_element(element_id)
			if gateway._session != null and gateway._session.world != null
			else null
		)
		if (
			remote_seat == null
			or not remote_seat.is_operational()
		):
			return _exit_remote_rover_seat(gateway)
	if element_id > 0:
		var passenger := _resolve_passenger_seat(gateway, command, element_id)
		return _enter_rover_seat(
			gateway,
			seat_source,
			element_id,
			InteractionHit.assembly_id_from(target),
			is_local_actor,
			passenger
		)
	# Legacy collider path / remote synthetic exit with no element id.
	if not is_local_actor:
		return _exit_remote_rover_seat(gateway)
	if (
		vehicle == null
		or not vehicle.has_method("handle_interact")
	):
		return gateway._result(&"not_ready")
	if not vehicle.call("handle_interact", seat_source):
		return gateway._result(&"blocked")
	return gateway._result(&"ok", {"seated": true})


static func is_rover_seated(gateway, player: Node = null) -> bool:
	if player == null:
		player = gateway._rover_seat_player
	return (
		player != null
		and gateway._rover_seat_assembly_id > 0
		and player.has_method("is_in_vehicle")
		and player.call("is_in_vehicle")
	)


static func get_local_seat_element_id(gateway) -> int:
	return gateway._rover_seat_element_id


static func is_local_seat_driver(gateway) -> bool:
	return gateway._rover_seat_element_id > 0 and not gateway._rover_seat_passenger


## Enter-vs-exit for a remote actor must use occupancy, not the avatar node:
## RemotePlayer has no is_in_vehicle, so a node check would always enter.
## Local also treats gateway seat id / live attach as seated so a pruned
## occupancy cannot turn E into a failed re-enter (broken-seat trap).
static func _actor_wants_seat_exit(
	gateway,
	player: Node3D,
	is_local_actor: bool
) -> bool:
	if is_local_actor:
		if _is_rover_seated(gateway, player) or gateway._rover_seat_element_id > 0:
			return true
		return (
			player != null
			and player.has_method("is_in_vehicle")
			and bool(player.call("is_in_vehicle"))
		)
	if gateway._session == null or gateway._session.world == null:
		return false
	if gateway._session.world.get_player_seat_element_id(gateway.actor_uid) > 0:
		return true
	# Synthetic in-seat interact carries element_id from meta; occupancy may
	# already have been pruned after the seat broke — still treat as exit.
	return false


static func tick_rover_locomotion_input(gateway) -> void:
	if gateway._session == null or gateway._rover_seat_passenger:
		return
	var assembly_id := _resolve_active_rover_assembly_id(gateway)
	if assembly_id <= 0:
		return
	var locomotion: AssemblyLocomotionController = (
		gateway._session.world.get_locomotion_controller(assembly_id)
	)
	# Occupied-seat policy cache — no lowest-seat fallback, no per-tick alloc.
	var policy: SeatControlState = gateway._rover_seat_policy
	if policy == null:
		policy = SeatControlState.defaults_ref()
	# Открытое модальное окно забирает pilot input; zero frame clears continuous
	# channels while route gates stay on so latched dampeners still apply.
	var modal_blocks: bool = (
		gateway._rover_seat_player != null
		and gateway._rover_seat_player.has_method("is_gameplay_input_enabled")
		and not bool(gateway._rover_seat_player.call("is_gameplay_input_enabled"))
	)
	if not modal_blocks:
		# Latched assembly-wide edges; effective gates decide which consumers apply.
		if Input.is_action_just_pressed(&"toggle_dampeners"):
			locomotion.set_dampeners(not locomotion.is_dampeners())
			_wake_rover_body(gateway, assembly_id)
		# PB toggle is assembly-wide safety — not gated by Control Wheels.
		if Input.is_action_just_pressed(&"toggle_parking_brake"):
			_toggle_rover_parking_brake(gateway, assembly_id, locomotion)
	var raw := collect_seat_raw_input(gateway, modal_blocks)
	var frame := SeatInputRouter.route(
		raw,
		policy,
		locomotion.is_parking_brake()
	)
	locomotion.apply_driver_frame(frame)
	# Parking settle: latched PB holds brake=1 every tick — waking on that
	# would defeat settle-freeze (ROVER-MODULES-V1). Wake on pilot motion or
	# service brake / flight / attitude only.
	if _seat_frame_should_wake(gateway, locomotion):
		_wake_rover_body(gateway, assembly_id)


static func _seat_frame_should_wake(
	_gateway,
	locomotion: AssemblyLocomotionController
) -> bool:
	if locomotion == null:
		return false
	if locomotion.has_active_flight_input():
		return true
	if (
		absf(locomotion.drive_command) > 0.001
		or absf(locomotion.steering_command) > 0.001
	):
		return true
	# Service brake (Space), not latched parking brake.
	return (
		locomotion.brake_command > 0.001
		and not locomotion.is_parking_brake()
	)


## Normalize InputMap once per tick. jump and move_up share Space in project.godot.
## Public so CoopSession can sample the same raw dict for remote drivers.
static func collect_seat_raw_input(gateway, zero_frame: bool) -> Dictionary:
	if zero_frame:
		return {"zero_frame": true}
	var space := maxf(
		Input.get_action_strength(&"jump"),
		Input.get_action_strength(&"move_up")
	)
	var look := _consume_flight_look_delta(gateway)
	# drive/steer: single-axis bake (get_axis) so coop RPC cannot drop one of
	# the paired move_* keys and leave steering at zero while drive still works.
	return {
		"zero_frame": false,
		"move_forward": Input.get_action_strength(&"move_forward"),
		"move_back": Input.get_action_strength(&"move_back"),
		"move_left": Input.get_action_strength(&"move_left"),
		"move_right": Input.get_action_strength(&"move_right"),
		"drive": Input.get_axis(&"move_back", &"move_forward"),
		"steer": Input.get_axis(&"move_right", &"move_left"),
		"space": space,
		"move_down": Input.get_action_strength(&"move_down"),
		"look_x": look.x,
		"look_y": look.y,
		"roll_left": Input.get_action_strength(&"roll_left"),
		"roll_right": Input.get_action_strength(&"roll_right"),
	}


## Host applies a guest driver's 20 Hz stream packet (not a gateway command —
## command completion would storm snapshot re-broadcasts).
static func apply_remote_driver_input(
	gateway,
	remote_uid: String,
	raw: Dictionary,
	edges: Dictionary
) -> void:
	if (
		gateway._session == null
		or gateway._session.world == null
		or remote_uid.is_empty()
	):
		return
	var seat_element_id: int = gateway._session.world.get_player_seat_element_id(
		remote_uid
	)
	if seat_element_id <= 0:
		return
	var seat: SimulationElement = gateway._session.world.get_element(
		seat_element_id
	)
	if seat == null:
		return
	if gateway.is_passenger_seat_archetype(seat.archetype_id):
		return
	var assembly_id := seat.assembly_id
	if assembly_id <= 0:
		return
	var locomotion: AssemblyLocomotionController = (
		gateway._session.world.get_locomotion_controller(assembly_id)
	)
	var policy: SeatControlState = (
		gateway._session.world.get_seat_control_state_ref(seat_element_id)
	)
	if policy == null:
		policy = SeatControlState.defaults_ref()
	if bool(edges.get("toggle_dampeners", false)):
		locomotion.set_dampeners(not locomotion.is_dampeners())
		_wake_rover_body(gateway, assembly_id)
	if bool(edges.get("toggle_parking_brake", false)):
		_toggle_rover_parking_brake(gateway, assembly_id, locomotion)
	var frame := SeatInputRouter.route(
		raw,
		policy,
		locomotion.is_parking_brake()
	)
	locomotion.apply_driver_frame(frame)
	if _seat_frame_should_wake(gateway, locomotion):
		_wake_rover_body(gateway, assembly_id)


## Zero a disconnected / timed-out remote driver's continuous channels.
static func clear_remote_driver_input(gateway, remote_uid: String) -> void:
	if (
		gateway._session == null
		or gateway._session.world == null
		or remote_uid.is_empty()
	):
		return
	var seat_element_id: int = gateway._session.world.get_player_seat_element_id(
		remote_uid
	)
	if seat_element_id <= 0:
		return
	var seat: SimulationElement = gateway._session.world.get_element(
		seat_element_id
	)
	if seat == null or seat.assembly_id <= 0:
		return
	var locomotion: AssemblyLocomotionController = (
		gateway._session.world.get_locomotion_controller(seat.assembly_id)
	)
	locomotion.clear_driver_input()
	if locomotion.is_parking_brake():
		locomotion.set_brake_command(1.0)


## Client-only: parent the local Player to the replica seat body after a host
## ok for toggle_control_seat. Bypasses _execute (replica is not authoritative).
static func apply_local_seat_attach(
	gateway,
	player: Node3D,
	element_id: int,
	assembly_id: int,
	passenger: bool = false
) -> void:
	if gateway._session == null or gateway._session.projection == null:
		return
	if element_id <= 0 or assembly_id <= 0 or player == null:
		return
	var element: SimulationElement = gateway._session.world.get_element(element_id)
	if element == null:
		return
	var body: PhysicsBody3D = (
		gateway._session.projection.get_element_projection(element_id).get("body")
		as PhysicsBody3D
	)
	if body == null or not is_instance_valid(body):
		return
	var seat_offset: Vector3 = WheelPlacementUtil.seat_offset_local(element)
	# Snapshot mid-drive recreates replica bodies; restore_evacuated_drivers
	# finds the seated Player by this meta.
	player.set_meta("control_seat_element_id", element_id)
	player.set_meta("coop_replica_seat", true)
	if player.has_method("enter_vehicle"):
		player.call("enter_vehicle", body, seat_offset)
	# Replica bodies are written in CoopSession._process; physics interpolation
	# (INHERIT by enter_vehicle for host RigidBodies) smears the camera here.
	player.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	player.reset_physics_interpolation()
	gateway._rover_seat_player = player
	gateway._rover_seat_assembly_id = assembly_id
	gateway._rover_seat_element_id = element_id
	gateway._rover_seat_passenger = passenger
	if passenger:
		gateway._rover_seat_policy = null
		if player.has_method("set_vehicle_flight_controls"):
			player.call("set_vehicle_flight_controls", false)
	else:
		gateway._rover_seat_policy = (
			gateway._session.world.get_seat_control_state_ref(element_id)
		)
		_sync_seat_mouse_attitude(gateway, player, element_id)


## Client: re-bind to the seat body if a snapshot recreate orphaned the Player
## while gateway seat id is still claimed. Cheap — only while seated.
static func ensure_local_seat_binding(gateway) -> bool:
	if gateway._rover_seat_element_id <= 0 or gateway._rover_seat_player == null:
		return false
	if (
		gateway._session == null
		or gateway._session.projection == null
		or gateway._session.world == null
	):
		return false
	var player: Node3D = gateway._rover_seat_player
	var element: SimulationElement = gateway._session.world.get_element(
		gateway._rover_seat_element_id
	)
	if element == null or not element.is_operational():
		return false
	var body: PhysicsBody3D = (
		gateway._session.projection.get_element_projection(
			gateway._rover_seat_element_id
		)
		.get("body") as PhysicsBody3D
	)
	if body == null or not is_instance_valid(body):
		return false
	var vehicle_ok: bool = (
		player.has_method("is_in_vehicle")
		and bool(player.call("is_in_vehicle"))
		and player.has_method("current_vehicle")
		and player.call("current_vehicle") == body
	)
	if vehicle_ok:
		return true
	var seat_offset: Vector3 = WheelPlacementUtil.seat_offset_local(element)
	player.set_meta("control_seat_element_id", gateway._rover_seat_element_id)
	player.set_meta("coop_replica_seat", true)
	if player.has_method("enter_vehicle"):
		player.call("enter_vehicle", body, seat_offset)
	player.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	player.reset_physics_interpolation()
	if gateway._rover_seat_passenger:
		if player.has_method("set_vehicle_flight_controls"):
			player.call("set_vehicle_flight_controls", false)
	else:
		_sync_seat_mouse_attitude(
			gateway,
			player,
			gateway._rover_seat_element_id
		)
	return (
		player.has_method("is_in_vehicle")
		and bool(player.call("is_in_vehicle"))
	)


## Client-only counterpart of apply_local_seat_attach.
static func release_local_seat_attach(gateway) -> void:
	var player: Node3D = gateway._rover_seat_player
	var assembly_id: int = gateway._rover_seat_assembly_id
	var element_id: int = gateway._rover_seat_element_id
	if player == null or assembly_id <= 0:
		gateway._rover_seat_player = null
		gateway._rover_seat_assembly_id = 0
		gateway._rover_seat_element_id = 0
		gateway._rover_seat_passenger = false
		gateway._rover_seat_policy = null
		return
	var exit_position := player.global_position
	if (
		gateway._session != null
		and gateway._session.projection != null
		and element_id > 0
	):
		var body: PhysicsBody3D = (
			gateway._session.projection.get_element_projection(element_id).get("body")
			as PhysicsBody3D
		)
		if body != null:
			var element: SimulationElement = gateway._session.world.get_element(
				element_id
			)
			if element != null:
				var seat_offset: Vector3 = (
					WheelPlacementUtil.seat_offset_local(element)
				)
				var seat_world: Vector3 = body.global_transform * seat_offset
				exit_position = (
					seat_world
					+ body.global_transform.basis.x * 1.2
					+ GravityField.resolve_up(body, seat_world) * 0.15
				)
	if player.has_method("exit_vehicle"):
		player.call("exit_vehicle", exit_position)
	if player.has_meta("control_seat_element_id"):
		player.remove_meta("control_seat_element_id")
	if player.has_meta("coop_replica_seat"):
		player.remove_meta("coop_replica_seat")
	if player.has_method("set_gameplay_input_enabled"):
		player.call("set_gameplay_input_enabled", true)
	if player.has_method("set_vehicle_flight_controls"):
		player.call("set_vehicle_flight_controls", false)
	gateway._rover_seat_player = null
	gateway._rover_seat_assembly_id = 0
	gateway._rover_seat_element_id = 0
	gateway._rover_seat_passenger = false
	gateway._rover_seat_policy = null


const FLIGHT_LOOK_SENSITIVITY := 0.035


static func _consume_flight_look_delta(gateway) -> Vector2:
	var player: Node3D = gateway._rover_seat_player
	if player == null or not player.has_method("get_node_or_null"):
		return Vector2.ZERO
	var camera: Node = player.get_node_or_null("Camera")
	if camera == null or not camera.has_method("consume_flight_look_delta"):
		return Vector2.ZERO
	var raw: Vector2 = camera.call("consume_flight_look_delta")
	return Vector2(
		clampf(raw.x * FLIGHT_LOOK_SENSITIVITY, -1.0, 1.0),
		clampf(raw.y * FLIGHT_LOOK_SENSITIVITY, -1.0, 1.0)
	)


static func _toggle_rover_parking_brake(
	gateway,
	assembly_id: int,
	locomotion: AssemblyLocomotionController
) -> void:
	if locomotion.is_parking_brake():
		locomotion.set_parking_brake(false)
		_wake_rover_body(gateway, assembly_id)
		return
	var body: PhysicsBody3D = gateway._session.projection.get_physics_body(
		assembly_id
	)
	var linear := Vector3.ZERO
	var angular := Vector3.ZERO
	if body is RigidBody3D:
		var rigid := body as RigidBody3D
		linear = rigid.linear_velocity
		angular = rigid.angular_velocity
	var eps := AssemblyLocomotionController.PARKING_BRAKE_SPEED_EPS
	if linear.length() >= eps or angular.length() >= eps:
		gateway.command_completed.emit(
			0,
			gateway._result(&"parking_brake_needs_stop")
		)
		return
	locomotion.set_parking_brake(true)
	_wake_rover_body(gateway, assembly_id)


static func _resolve_active_rover_assembly_id(gateway) -> int:
	if gateway._rover_seat_assembly_id > 0:
		return gateway._rover_seat_assembly_id
	var player: Node3D = gateway._rover_seat_player
	if player == null:
		return 0
	if (
		player.has_method("is_in_vehicle")
		and not player.call("is_in_vehicle")
	):
		return 0
	if player.has_method("current_vehicle"):
		var vehicle: Node = player.call("current_vehicle")
		if vehicle != null and vehicle.has_meta("assembly_id"):
			return int(vehicle.get_meta("assembly_id"))
	return 0


static func _is_rover_seated(gateway, player: Node3D) -> bool:
	return (
		is_rover_seated(gateway, player)
		and gateway._rover_seat_element_id > 0
	)


static func _resolve_passenger_seat(
	gateway,
	command: Dictionary,
	element_id: int
) -> bool:
	if bool(command.get("parameters", {}).get("passenger", false)):
		return true
	if element_id <= 0 or gateway._session == null or gateway._session.world == null:
		return false
	var element: SimulationElement = gateway._session.world.get_element(element_id)
	return element != null and gateway.is_passenger_seat_archetype(
		element.archetype_id
	)


static func _enter_rover_seat(
	gateway,
	player: Node3D,
	element_id: int,
	assembly_id: int,
	is_local_actor: bool = true,
	passenger: bool = false
) -> Dictionary:
	if gateway._session == null or gateway._session.projection == null:
		return gateway._result(&"not_ready")
	if element_id <= 0 or assembly_id <= 0:
		return gateway._result(&"invalid_target")
	# Pre-feature mobility gate preserved (static activation out of scope).
	# Input routing itself stays classification-free once seated.
	if not ThrusterSimulationService.is_mobile_assembly(
		gateway._session.world,
		assembly_id
	):
		return gateway._result(&"blocked", {"detail": &"not_mobile"})
	var element: SimulationElement = gateway._session.world.get_element(element_id)
	if element == null:
		return gateway._result(&"invalid_target")
	var seat_archetype := element.get_archetype()
	if (
		seat_archetype == null
		or not seat_archetype.roles.has("ControlSeat")
		or not element.is_operational()
	):
		return gateway._result(&"blocked", {"detail": &"seat_not_ready"})
	# One driver per seat, checked here rather than in the world: the occupancy
	# map is shared with the oxygen service, where several players legitimately
	# reference the same seat's assembly.
	if (
		gateway._session.world.is_seat_occupied(element_id)
		and gateway._session.world.get_player_seat_element_id(gateway.actor_uid) != element_id
	):
		return gateway._result(&"blocked", {"detail": &"occupied"})
	# Remote guest: claim occupancy; arm locomotion only for driver seats.
	if not is_local_actor:
		if not gateway._session.world.register_player_seat_context(
			gateway.actor_uid,
			element_id
		):
			return gateway._result(&"blocked", {"detail": &"seat_context_rejected"})
		if not passenger:
			_prepare_rover_for_drive(gateway, assembly_id)
		return gateway._result(&"ok", {
			"seated": true,
			"assembly_id": assembly_id,
			"element_id": element_id,
			"passenger": passenger,
		})
	var body: PhysicsBody3D = (
		gateway._session.projection.get_element_projection(element_id).get("body")
		as PhysicsBody3D
	)
	if body == null:
		return gateway._result(&"not_ready")
	var seat_offset: Vector3 = WheelPlacementUtil.seat_offset_local(element)
	if not gateway._session.world.register_player_seat_context(
		gateway.actor_uid,
		element_id
	):
		return gateway._result(&"blocked", {"detail": &"seat_context_rejected"})
	if not passenger:
		_prepare_rover_for_drive(gateway, assembly_id)
		body = (
			gateway._session.projection.get_element_projection(element_id).get("body")
			as PhysicsBody3D
		)
		if body == null or not is_instance_valid(body):
			gateway._session.world.clear_player_seat_context(gateway.actor_uid)
			return gateway._result(&"not_ready")
	# Survives chassis reproject: physics projection evacuates/restores the
	# driver by this meta when StaticBody→RigidBody frees the old body.
	player.set_meta("control_seat_element_id", element_id)
	if player.has_method("enter_vehicle"):
		player.call("enter_vehicle", body, seat_offset)
	gateway._rover_seat_player = player
	gateway._rover_seat_assembly_id = assembly_id
	gateway._rover_seat_element_id = element_id
	gateway._rover_seat_passenger = passenger
	if passenger:
		gateway._rover_seat_policy = null
		if player.has_method("set_vehicle_flight_controls"):
			player.call("set_vehicle_flight_controls", false)
	else:
		gateway._rover_seat_policy = (
			gateway._session.world.get_seat_control_state_ref(element_id)
		)
		_sync_seat_mouse_attitude(gateway, player, element_id)
	# Activate may replace StaticBody→RigidBody and free mesh children;
	# rebuild visuals onto the live body (wheels need module meshes first).
	if not passenger:
		if gateway._session.visuals != null:
			gateway._session.visuals.rebuild_assembly(assembly_id)
		if gateway._session.piston_visuals != null:
			gateway._session.piston_visuals.rebuild_assembly(assembly_id)
	# Rebind if activate/rebuild swapped the body under the driver this frame.
	body = (
		gateway._session.projection.get_element_projection(element_id).get("body")
		as PhysicsBody3D
	)
	if (
		body != null
		and is_instance_valid(body)
		and is_instance_valid(player)
		and player.get_parent() != body
		and player.has_method("enter_vehicle")
	):
		player.call("enter_vehicle", body, seat_offset)
	return gateway._result(&"ok", {
		"seated": true,
		"assembly_id": assembly_id,
		"element_id": element_id,
		"passenger": passenger,
	})


static func _prepare_rover_for_drive(gateway, assembly_id: int) -> void:
	if gateway._session == null or gateway._session.world == null or assembly_id <= 0:
		return
	var world: SimulationWorld = gateway._session.world
	world.get_locomotion_controller(assembly_id).activate()
	_ensure_rover_power_network(gateway, world, assembly_id)
	IndustryElectricBudget.apply_tick(world, 0.25)
	_wake_rover_body(gateway, assembly_id)
	if not _rover_has_powered_wheel(gateway, world, assembly_id):
		push_warning(
			"Rover %d: wheels have no distributor power — check battery wire"
			% assembly_id
		)


static func _rover_has_powered_wheel(
	_gateway,
	world: SimulationWorld,
	assembly_id: int
) -> bool:
	for pair: Dictionary in WheelSimulationService.discover_pairs(
		world,
		assembly_id
	):
		if not WheelSimulationService.is_complete_pair(pair):
			continue
		var wheel_element: SimulationElement = pair.get("wheel_element")
		if wheel_element == null:
			continue
		var runtime := world.ensure_industry_element_runtime(
			wheel_element.element_id
		)
		if runtime.machine_enabled and runtime.powered:
			return true
	return false


static func _ensure_rover_power_network(
	_gateway,
	world: SimulationWorld,
	assembly_id: int
) -> void:
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	var battery_id := 0
	var distributor_id := 0
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element == null or not element.is_operational():
			continue
		match element.archetype_id:
			"power_battery_small", "power_battery":
				battery_id = element_id
			"power_distributor_small", "power_distributor":
				distributor_id = element_id
	if battery_id <= 0 or distributor_id <= 0:
		return
	if not IndustryElectricBudget.is_element_on_supplied_network(
		world,
		distributor_id
	):
		world.connect_network(
			battery_id,
			"power_out",
			distributor_id,
			"power_in"
		)
	# Seed only once. Empty after drain must stay empty (no infinite drive).
	IndustryElectricBudget.seed_battery_if_needed(world, battery_id)


static func _wake_rover_body(gateway, assembly_id: int) -> void:
	if gateway._session == null or gateway._session.projection == null or assembly_id <= 0:
		return
	var body: PhysicsBody3D = gateway._session.projection.get_physics_body(
		assembly_id
	)
	if body is StaticBody3D:
		var assembly: SimulationAssembly = gateway._session.world.get_assembly_raw(
			assembly_id
		)
		if assembly != null:
			var motion := assembly.motion.duplicate_state()
			gateway._session.projection.project_assembly_now(assembly_id, motion)
			body = gateway._session.projection.get_physics_body(assembly_id)
	if body is RigidBody3D:
		# All bodies, not just the root: a frozen wheel body under a live
		# chassis is a statue the constraint drags around.
		gateway._session.projection.wake_assembly_bodies(assembly_id)


static func _exit_rover_seat(
	gateway,
	player: Node3D,
	is_local_actor: bool = true
) -> Dictionary:
	if gateway._session == null or gateway._session.world == null:
		return gateway._result(&"not_ready")
	# Remote guest: release occupancy + zero locomotion. Avatar detach is
	# client's job via release_local_seat_attach on the ok result.
	if not is_local_actor:
		return _exit_remote_rover_seat(gateway)
	# Allow exit when seat machine is claimed OR the player is still parented
	# (broken seat may have wiped assembly id while the avatar is stuck).
	if (
		gateway._rover_seat_assembly_id <= 0
		and gateway._rover_seat_element_id <= 0
		and (
			player == null
			or not player.has_method("is_in_vehicle")
			or not bool(player.call("is_in_vehicle"))
		)
	):
		return gateway._result(&"not_ready")
	var assembly_id: int = gateway._rover_seat_assembly_id
	var element_id: int = gateway._rover_seat_element_id
	var was_passenger: bool = gateway._rover_seat_passenger
	var body: PhysicsBody3D = null
	if element_id > 0 and gateway._session.projection != null:
		body = (
			gateway._session.projection.get_element_projection(
				element_id
			).get("body") as PhysicsBody3D
		)
	var exit_position := (
		player.global_position if player != null else Vector3.ZERO
	)
	if body != null and is_instance_valid(body):
		var element: SimulationElement = gateway._session.world.get_element(
			element_id
		)
		if element != null:
			var seat_offset: Vector3 = WheelPlacementUtil.seat_offset_local(element)
			var seat_world: Vector3 = body.global_transform * seat_offset
			exit_position = (
				seat_world
				+ body.global_transform.basis.x * 1.2
				+ GravityField.resolve_up(body, seat_world) * 0.15
			)
		else:
			exit_position = (
				body.global_position
				+ body.global_transform.basis.x * 1.2
				+ GravityField.resolve_up(body, body.global_position) * 0.15
			)
	if player != null and player.has_method("exit_vehicle"):
		player.call("exit_vehicle", exit_position)
	if player != null and player.has_meta("control_seat_element_id"):
		player.remove_meta("control_seat_element_id")
	if player != null and player.has_meta("coop_replica_seat"):
		player.remove_meta("coop_replica_seat")
	if player != null and player.has_method("set_gameplay_input_enabled"):
		player.call("set_gameplay_input_enabled", true)
	if assembly_id > 0 and not was_passenger:
		var locomotion: AssemblyLocomotionController = (
			gateway._session.world.get_locomotion_controller(assembly_id)
		)
		locomotion.clear_driver_input()
		if locomotion.is_parking_brake():
			locomotion.set_brake_command(1.0)
		# Keep activated so floating wheel/flight phys continues.
		gateway._session.projection.sync_body_motion_now(assembly_id)
	if player != null and player.has_method("set_vehicle_flight_controls"):
		player.call("set_vehicle_flight_controls", false)
	gateway._session.world.clear_player_seat_context(gateway.actor_uid)
	gateway._rover_seat_player = null
	gateway._rover_seat_assembly_id = 0
	gateway._rover_seat_element_id = 0
	gateway._rover_seat_passenger = false
	gateway._rover_seat_policy = null
	return gateway._result(&"ok", {
		"seated": false,
		"assembly_id": assembly_id,
		"element_id": element_id,
	})


static func _exit_remote_rover_seat(gateway) -> Dictionary:
	var seat_element_id: int = gateway._session.world.get_player_seat_element_id(
		gateway.actor_uid
	)
	# Idempotent: occupancy may already be gone after prune/destroy; client still
	# needs seated:false to release_local_seat_attach.
	if seat_element_id <= 0:
		return gateway._result(&"ok", {
			"seated": false,
			"assembly_id": 0,
			"element_id": 0,
		})
	var seat: SimulationElement = gateway._session.world.get_element(
		seat_element_id
	)
	var assembly_id := seat.assembly_id if seat != null else 0
	if assembly_id > 0:
		var locomotion: AssemblyLocomotionController = (
			gateway._session.world.get_locomotion_controller(assembly_id)
		)
		locomotion.clear_driver_input()
		if locomotion.is_parking_brake():
			locomotion.set_brake_command(1.0)
	gateway._session.world.clear_player_seat_context(gateway.actor_uid)
	return gateway._result(&"ok", {
		"seated": false,
		"assembly_id": assembly_id,
		"element_id": seat_element_id,
	})


## Occupied ControlSeat: only the seated player's commands may edit bar/seat
## routing. UI nodes (terminal, compact bar) submit through gateway with
## actor_uid — not command.source (spec: same occupant check as seat enter).
static func _seat_host_command_allowed(gateway, seat_element_id: int) -> bool:
	if gateway._session == null or seat_element_id <= 0:
		return true
	if not gateway._session.world.is_seat_occupied(seat_element_id):
		return true
	return (
		gateway._session.world.get_player_seat_element_id(gateway.actor_uid)
		== seat_element_id
	)


## Mouse attitude follows Control Gyros only when the assembly has gyros to
## consume look — wheel rovers keep FP freelook (CONTROL-AXES-V0).
static func _sync_seat_mouse_attitude(
	gateway,
	player: Node3D,
	seat_element_id: int
) -> void:
	if player == null or not player.has_method("set_vehicle_flight_controls"):
		return
	if gateway._session == null or seat_element_id <= 0:
		player.call("set_vehicle_flight_controls", false)
		return
	var policy: SeatControlState = (
		gateway._rover_seat_policy
		if (
			gateway._rover_seat_policy != null
			and gateway._rover_seat_element_id == seat_element_id
		)
		else gateway._session.world.get_seat_control_state_ref(seat_element_id)
	)
	var enable_flight := false
	if policy.control_gyros:
		var seat: SimulationElement = gateway._session.world.get_element(
			seat_element_id
		)
		if seat != null and seat.assembly_id > 0:
			enable_flight = (
				not ThrusterSimulationService.list_gyro_elements(
					gateway._session.world,
					seat.assembly_id
				).is_empty()
			)
	player.call("set_vehicle_flight_controls", enable_flight)
