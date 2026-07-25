class_name GatewayMachineCommandService
extends RefCounted

const INTERACTION_RANGE_M := 4.5

const INTERACTION_SOURCE_MARGIN_M := 1.5

## Aim can sit slightly outside the authored collider AABB (mesh bevel / float).
const _OXYGEN_MODULE_HIT_MARGIN_M := 0.2

## Authoritative hold-interact path. Identity and cadence are server-owned:
## callers provide only the normal current-hit snapshot and source node.
static func _oxygen_refill(gateway, command_data: Dictionary, target: Dictionary) -> Dictionary:
	if gateway._session == null or gateway.actor_uid.is_empty():
		return gateway._result(&"not_ready")
	if (
		StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return gateway._result(&"invalid_target")
	var source := command_data.get("source") as Node3D
	var point: Vector3 = target.get("point", Vector3(INF, INF, INF))
	var hit_distance := float(target.get("distance", INF))
	if (
		source == null
		or not is_instance_valid(source)
		or not point.is_finite()
		or not is_finite(hit_distance)
		or hit_distance < 0.0
		or hit_distance > INTERACTION_RANGE_M
		or source.global_position.distance_to(point)
		> INTERACTION_RANGE_M + INTERACTION_SOURCE_MARGIN_M
	):
		return gateway._result(&"out_of_range")
	var module_element_id := InteractionHit.element_id_from(target)
	var module: SimulationElement = gateway._session.world.get_element(module_element_id)
	if module == null or not IndustryStoreService.is_oxygen_module(module):
		return gateway._result(&"invalid_target")
	# Bind the claimed id to the aimed world point as well as the snapshot kind;
	# a peer cannot pair a nearby hit with a known remote module id.
	# Reach uses collider AABB (not origin→max-footprint-cell): multi-cell tanks
	# have far corners beyond that old radius while still being valid hits.
	if not _oxygen_module_hit_in_reach(gateway, module, point):
		return gateway._result(&"invalid_target")
	var command := OxygenRefillCommand.new()
	command.player_id = gateway.actor_uid
	command.module_element_id = module_element_id
	var result: Dictionary = gateway._session.apply_oxygen_refill(command)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		result
	)
## True when `point` lies on/near any authored collider of the module.
static func _oxygen_module_hit_in_reach(gateway, 
	module: SimulationElement,
	point: Vector3
) -> bool:
	if module == null or not point.is_finite():
		return false
	var archetype := module.get_archetype()
	if archetype == null:
		return false
	var group_tf: Transform3D = gateway._session.world.element_group_transform(module.element_id)
	if archetype.colliders.is_empty():
		var origin: Vector3 = gateway._session.world.element_world_transform(
			module.element_id
		).origin
		return origin.distance_to(point) <= (
			GridMetric.CELL_SIZE_M + _OXYGEN_MODULE_HIT_MARGIN_M
		)
	for collider: ColliderDefinition in archetype.colliders:
		if collider == null:
			continue
		var bounds := GridPoseUtil.collider_world_aabb(
			group_tf,
			module.origin_cell,
			module.orientation_index,
			collider
		).grow(_OXYGEN_MODULE_HIT_MARGIN_M)
		if bounds.has_point(point):
			return true
	return false

static func _damage_element(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if (
		gateway._session == null
		or StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return gateway._result(&"invalid_target")
	var element_id := InteractionHit.element_id_from(target)
	var parameters: Dictionary = command.get("parameters", {})
	var amount := float(parameters.get("damage", 0.0))
	var refund_fraction := float(parameters.get("refund_fraction_on_destroy", 0.0))
	# Empty store = no refund at all (plain drill damage). Only a command that
	# asks for a refund gets one, and it always goes to the actor.
	var store_id := ""
	if bool(parameters.get("refund_to_actor", false)):
		store_id = PlayerIdentity.store_id(gateway.actor_uid)
	return apply_damage(gateway, element_id, amount, refund_fraction, store_id)

static func apply_damage(gateway, 
	element_id: int,
	amount: float,
	refund_fraction_on_destroy: float = 0.0,
	store_id: String = ""
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var element: SimulationElement = gateway._session.world.get_element(element_id)
	if element == null:
		return gateway._result(&"invalid_target")
	var command := DamageElementCommand.new()
	command.element_id = element_id
	command.expected_state_revision = element.state_revision
	command.damage = amount
	command.refund_fraction_on_destroy = refund_fraction_on_destroy
	command.store_id = store_id
	return gateway._structural_result(
		gateway._session.world.apply_structural_command_now(command)
	)

static func apply_transfer_resource(gateway, command: TransferResourceCommand) -> Dictionary:
	if gateway._session == null or command == null:
		return gateway._result(&"not_ready")
	var result: Dictionary = gateway._session.apply_transfer_resource(command)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"amount": float(result.get("amount", 0.0)),
			"from_store_id": command.from_store_id,
			"to_store_id": command.to_store_id,
			"resource_id": command.resource_id,
		}
	)

static func apply_connect_network(gateway, 
	element_a_id: int,
	element_b_id: int,
	port_a_id: String = "",
	port_b_id: String = "",
	waypoints: PackedVector3Array = PackedVector3Array(),
	waypoint_anchors: PackedInt32Array = PackedInt32Array()
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var diagnosis := IndustryElectricPortUtil.diagnose_electric_pair(
		gateway._session.world,
		element_a_id,
		element_b_id,
		port_a_id,
		port_b_id,
		waypoints
	)
	var pair: Dictionary = diagnosis.get("pair", {})
	if pair.is_empty():
		var reason: StringName = diagnosis.get("reason", &"incompatible_connection")
		if reason == &"ok":
			reason = &"incompatible_connection"
		return gateway._result(reason)
	var resolved_a := int(pair.get("element_a_id", element_a_id))
	var resolved_b := int(pair.get("element_b_id", element_b_id))
	var resolved_port_a := (
		port_a_id if not port_a_id.is_empty() else str(pair["port_a_id"])
	)
	var resolved_port_b := (
		port_b_id if not port_b_id.is_empty() else str(pair["port_b_id"])
	)
	var element_a: SimulationElement = gateway._session.world.get_element(resolved_a)
	var element_b: SimulationElement = gateway._session.world.get_element(resolved_b)
	if element_a == null or element_b == null:
		return gateway._result(&"invalid_target")
	var assembly_a: SimulationAssembly = gateway._session.world.get_assembly(element_a.assembly_id)
	var assembly_b: SimulationAssembly = gateway._session.world.get_assembly(element_b.assembly_id)
	var command := ConnectNetworkCommand.new()
	command.element_a_id = resolved_a
	command.port_a_id = resolved_port_a
	command.element_b_id = resolved_b
	command.port_b_id = resolved_port_b
	command.waypoints = waypoints
	command.waypoint_anchors = waypoint_anchors
	if assembly_a != null:
		command.expected_revision_a = assembly_a.topology_revision
	if assembly_b != null:
		command.expected_revision_b = assembly_b.topology_revision
	var result: StructuralCommandResult = gateway._session.world.apply_structural_command_now(command)
	if result == null:
		return gateway._result(&"not_ready")
	if result.is_ok():
		return gateway._result(&"ok", result.data)
	return gateway._result(gateway._connect_failure_reason(result.reason), result.data)
## Rope form: both ends are free attach points in world space. An end with
## element id 0 landed on bare terrain and gets a stake driven for it — see
## [CableStakeUtil]. [param stake_up] is local up at the click: gravity lives
## on a scene node, and the command that runs on the world cannot go looking
## for one. [param link_kind] is ELECTRIC (the `connect` tool's slack cable,
## current behaviour) or MECHANICAL (the `rope` tool, ROPE-CHAIN-V0): a
## physical rope/chain that mass-couples instead of conducting.
static func apply_connect_rope(gateway, 
	element_a_id: int,
	attach_a: Vector3,
	element_b_id: int,
	attach_b: Vector3,
	slack: float = CableAnchorUtil.DEFAULT_SLACK,
	routed_m: float = 0.0,
	stake_up: Vector3 = Vector3.UP,
	link_kind: int = IndustryElectricLink.Kind.ELECTRIC
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var command := ConnectNetworkCommand.new()
	command.element_a_id = element_a_id
	command.element_b_id = element_b_id
	command.port_a_id = ""
	command.port_b_id = ""
	command.attach_a = attach_a
	command.attach_b = attach_b
	command.slack = slack
	command.routed_m = maxf(routed_m, 0.0) if is_finite(routed_m) else 0.0
	command.stake_up = stake_up
	command.link_kind = link_kind
	var result: StructuralCommandResult = gateway._session.world.apply_structural_command_now(command)
	if result == null:
		return gateway._result(&"not_ready")
	if result.is_ok():
		return gateway._result(&"ok", result.data)
	return gateway._result(gateway._connect_failure_reason(result.reason), result.data)

static func _connect_network(gateway, 
	command: Dictionary,
	_target: Dictionary
) -> Dictionary:
	var parameters: Dictionary = command.get("parameters", {})
	if bool(parameters.get("rope", false)):
		return apply_connect_rope(gateway, 
			int(parameters.get("element_a_id", 0)),
			parameters.get("attach_a", Vector3.ZERO),
			int(parameters.get("element_b_id", 0)),
			parameters.get("attach_b", Vector3.ZERO),
			float(parameters.get("slack", CableAnchorUtil.DEFAULT_SLACK)),
			float(parameters.get("routed_m", 0.0)),
			parameters.get("stake_up", Vector3.UP),
			(
				IndustryElectricLink.Kind.MECHANICAL
				if bool(parameters.get("mechanical", false))
				else IndustryElectricLink.Kind.ELECTRIC
			)
		)
	return apply_connect_network(gateway, 
		int(parameters.get("element_a_id", 0)),
		int(parameters.get("element_b_id", 0)),
		str(parameters.get("port_a_id", "")),
		str(parameters.get("port_b_id", "")),
		PackedVector3Array(parameters.get("waypoints", PackedVector3Array())),
		PackedInt32Array(parameters.get("waypoint_anchors", PackedInt32Array()))
	)

static func _disconnect_network(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var link_id := int(
		parameters.get(
			"link_id",
			InteractionHit.electric_link_id_from(target)
		)
	)
	if link_id <= 0:
		return gateway._result(&"invalid_target")
	return gateway._structural_result(
		gateway._session.world.disconnect_network(0, "", 0, "", link_id)
	)

static func _transfer_resource(gateway, 
	command: Dictionary,
	_target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var transfer := TransferResourceCommand.new()
	transfer.from_store_id = str(parameters.get("from_store_id", ""))
	transfer.to_store_id = str(parameters.get("to_store_id", ""))
	transfer.resource_id = str(parameters.get("resource_id", ""))
	transfer.amount = float(parameters.get("amount", 0.0))
	transfer.instance_id = str(parameters.get("instance_id", ""))
	return apply_transfer_resource(gateway, transfer)
## Host-authoritative hotbar rebind for the current actor_uid (COOP-HOST-V0).
## Empty instance_id clears the slot; non-empty must be owned by that player.
static func _assign_hotbar_instance(gateway, 
	command: Dictionary,
	_target: Dictionary
) -> Dictionary:
	if gateway._session == null or gateway._session.world == null or gateway.actor_uid.is_empty():
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var page := int(parameters.get("page", -1))
	var slot := int(parameters.get("slot", -1))
	var instance_id := str(parameters.get("instance_id", ""))
	if page < 0 or slot < 0:
		return gateway._result(&"invalid_target")
	if not instance_id.is_empty():
		var registry: PlayerInventoryRegistry = gateway.player_inventory()
		if registry == null or not registry.has_instance(instance_id):
			return gateway._result(&"invalid_target")
	if not gateway._session.world.assign_player_hotbar_instance(
		gateway.actor_uid,
		page,
		slot,
		instance_id
	):
		return gateway._result(&"invalid_target")
	return gateway._result(&"ok", {
		"page": page,
		"slot": slot,
		"instance_id": instance_id,
	})
## Переименование узла из терминала управления. Надёжная команда, но не
## структурная: меняет `state_revision` элемента, не топологию (CONTROL-ACTIONS-V0).
static func _set_element_name(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var rename := SetElementNameCommand.new()
	rename.element_id = int(
		parameters.get(
			"element_id",
			InteractionHit.element_id_from(target)
		)
	)
	rename.element_name = str(parameters.get("element_name", ""))
	var result: Dictionary = gateway._session.apply_set_element_name(rename)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"element_id": rename.element_id,
			"custom_name": result.get("custom_name", ""),
		}
	)
## Право бить по слотам бара — только текущий occupant хоста (CONTROL-ACTIONS-V0
## «Persistence и кооп»). Занят кем-то другим сейчас проверяется только для
## кокпита (`_rover_seat_*` — эксклюзивная посадка); у control_terminal нет
## персистентного occupant'а («occupied_by ... interaction range (пульт)» —
## окно и так не откроется без interaction-range, дальше проверять нечего).
static func _configure_action_slot(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var configure := ConfigureActionSlotCommand.new()
	configure.host_element_id = int(
		parameters.get(
			"host_element_id",
			InteractionHit.element_id_from(target)
		)
	)
	configure.page = int(parameters.get("page", 0))
	configure.index = int(parameters.get("index", 0))
	var payload_variant: Variant = parameters.get("payload", {})
	configure.payload = payload_variant if payload_variant is Dictionary else {}
	if not gateway._seat_host_command_allowed(configure.host_element_id):
		return gateway._result(&"blocked")
	var result: Dictionary = gateway._session.apply_configure_action_slot(configure)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"host_element_id": configure.host_element_id,
			"page": configure.page,
			"index": configure.index,
		}
	)

static func _configure_seat_controls(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var configure := ConfigureSeatControlsCommand.new()
	configure.seat_element_id = int(
		parameters.get(
			"seat_element_id",
			InteractionHit.element_id_from(target)
		)
	)
	if parameters.has("control_wheels"):
		configure.control_wheels = bool(parameters.get("control_wheels"))
	if parameters.has("control_thrusters"):
		configure.control_thrusters = bool(parameters.get("control_thrusters"))
	if parameters.has("control_gyros"):
		configure.control_gyros = bool(parameters.get("control_gyros"))
	if not gateway._seat_host_command_allowed(configure.seat_element_id):
		return gateway._result(&"blocked")
	var result: Dictionary = gateway._session.apply_configure_seat_controls(configure)
	if StringName(result.get("reason", &"")) == &"ok":
		# ensure_ created/updated the row — refresh occupied-seat cache.
		if gateway._rover_seat_element_id == configure.seat_element_id:
			gateway._rover_seat_policy = gateway._session.world.get_seat_control_state_ref(
				configure.seat_element_id
			)
		if (
			gateway._rover_seat_element_id == configure.seat_element_id
			and gateway._rover_seat_player != null
		):
			gateway._sync_seat_mouse_attitude(
				gateway._rover_seat_player,
				configure.seat_element_id
			)
			# Apply updated frame immediately so toggle OFF clears stale channels.
			gateway.tick_rover_locomotion_input()
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"seat_element_id": int(result.get("seat_element_id", configure.seat_element_id)),
			"control_wheels": bool(result.get("control_wheels", true)),
			"control_thrusters": bool(result.get("control_thrusters", false)),
			"control_gyros": bool(result.get("control_gyros", true)),
		}
	)

static func _set_machine_enabled(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var machine := SetMachineEnabledCommand.new()
	machine.element_id = int(
		parameters.get(
			"element_id",
			InteractionHit.element_id_from(target)
		)
	)
	machine.enabled = bool(parameters.get("enabled", true))
	var result: Dictionary = gateway._session.apply_set_machine_enabled(machine)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{"element_id": machine.element_id, "enabled": machine.enabled}
	)

static func _enqueue_recipe(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var recipe := EnqueueRecipeCommand.new()
	recipe.element_id = int(
		parameters.get(
			"element_id",
			InteractionHit.element_id_from(target)
		)
	)
	recipe.recipe_id = str(parameters.get("recipe_id", ""))
	recipe.count = maxi(1, int(parameters.get("count", 1)))
	var result: Dictionary = gateway._session.apply_enqueue_recipe(recipe)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{"element_id": recipe.element_id, "recipe_id": recipe.recipe_id}
	)

static func _dequeue_recipe(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var dequeue := DequeueRecipeCommand.new()
	dequeue.element_id = int(
		parameters.get(
			"element_id",
			InteractionHit.element_id_from(target)
		)
	)
	dequeue.index = maxi(0, int(parameters.get("index", 0)))
	dequeue.count = maxi(1, int(parameters.get("count", 1)))
	var result: Dictionary = gateway._session.apply_dequeue_recipe(dequeue)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{"element_id": dequeue.element_id}
	)

static func _set_actuator_target(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var keys: Dictionary = gateway._target_card_keys(target)
	var actuator := SetActuatorTargetCommand.new()
	actuator.joint_id = int(
		parameters.get(
			"joint_id",
			HudActuatorTuneUtil.joint_id(keys)
		)
	)
	actuator.mode = int(
		parameters.get(
			"mode",
			SimulationMotorState.ControlMode.STOP
		)
	) as SimulationMotorState.ControlMode
	actuator.target_position_m = float(
		parameters.get("target_position_m", 0.0)
	)
	actuator.target_velocity_mps = float(
		parameters.get("target_velocity_mps", 0.0)
	)
	actuator.speed_limit_mps = float(
		parameters.get("speed_limit_mps", -1.0)
	)
	actuator.enabled = bool(parameters.get("enabled", true))
	var result: Dictionary = gateway._session.apply_set_actuator_target(actuator)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"joint_id": actuator.joint_id,
			"status_name": result.get("status_name", &""),
		}
	)

static func _configure_actuator(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var keys: Dictionary = gateway._target_card_keys(target)
	var configure := ConfigureActuatorCommand.new()
	configure.joint_id = int(
		parameters.get(
			"joint_id",
			HudActuatorTuneUtil.joint_id(keys)
		)
	)
	configure.extend_velocity_mps = float(
		parameters.get("extend_velocity_mps", -1.0)
	)
	configure.retract_velocity_mps = float(
		parameters.get("retract_velocity_mps", -1.0)
	)
	configure.force_limit_n = float(parameters.get("force_limit_n", -1.0))
	configure.lower_limit_m = float(parameters.get("lower_limit_m", -1.0))
	configure.upper_limit_m = float(parameters.get("upper_limit_m", -1.0))
	configure.lower_limit_set = parameters.has("lower_limit_m")
	configure.upper_limit_set = parameters.has("upper_limit_m")
	var result: Dictionary = gateway._session.apply_configure_actuator(configure)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"joint_id": configure.joint_id,
			"status_name": result.get("status_name", &""),
		}
	)

static func _configure_wheel(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var keys: Dictionary = gateway._target_card_keys(target)
	var configure := ConfigureWheelCommand.new()
	configure.wheel_element_id = int(
		parameters.get(
			"wheel_element_id",
			keys.get("wheel_element_id", InteractionHit.element_id_from(target))
		)
	)
	if parameters.has("steerable"):
		configure.steerable_set = true
		configure.steerable = bool(parameters["steerable"])
	if parameters.has("invert_drive"):
		configure.invert_drive_set = true
		configure.invert_drive = bool(parameters["invert_drive"])
	if parameters.has("drive_torque_scale"):
		configure.drive_torque_scale = float(
			parameters["drive_torque_scale"]
		)
	if parameters.has("brake_torque_n_m"):
		configure.brake_torque_n_m = float(parameters["brake_torque_n_m"])
	if parameters.has("max_steering_angle_rad"):
		configure.max_steering_angle_rad = float(
			parameters["max_steering_angle_rad"]
		)
	if parameters.has("grip_scale"):
		configure.grip_scale = float(parameters["grip_scale"])
	var result: Dictionary = gateway._session.apply_configure_wheel(configure)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"wheel_element_id": configure.wheel_element_id,
		}
	)

static func _configure_suspension(gateway, 
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var keys: Dictionary = gateway._target_card_keys(target)
	var configure := ConfigureSuspensionCommand.new()
	configure.suspension_element_id = int(
		parameters.get(
			"suspension_element_id",
			keys.get(
				"suspension_element_id",
				InteractionHit.element_id_from(target)
			)
		)
	)
	if parameters.has("travel_m"):
		configure.travel_m = float(parameters["travel_m"])
	if parameters.has("spring_stiffness_n_per_m"):
		configure.spring_stiffness_n_per_m = float(
			parameters["spring_stiffness_n_per_m"]
		)
	if parameters.has("spring_damping_n_s_per_m"):
		configure.spring_damping_n_s_per_m = float(
			parameters["spring_damping_n_s_per_m"]
		)
	var result: Dictionary = gateway._session.apply_configure_suspension(configure)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"suspension_element_id": configure.suspension_element_id,
		}
	)

static func _collect_world_loot(gateway, command: Dictionary) -> Dictionary:
	if gateway._session == null:
		return gateway._result(&"not_ready")
	var parameters: Dictionary = command.get("parameters", {})
	var pile_id := int(parameters.get("pile_id", 0))
	var to_store_id := str(
		parameters.get(
			"to_store_id",
			PlayerIdentity.store_id(gateway.actor_uid)
		)
	)
	var result: Dictionary = gateway._session.world.collect_world_loot_pile(
		pile_id,
		to_store_id
	)
	return gateway._result(
		StringName(result.get("reason", &"invalid_target")),
		{
			"pile_id": pile_id,
			"to_store_id": to_store_id,
			"resource_id": str(result.get("resource_id", "")),
			"amount": float(result.get("amount", 0.0)),
		}
	)
