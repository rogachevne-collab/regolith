class_name WorldCommandGateway
extends Node

const _TerrainFloatingDebrisService := preload(
	"res://scripts/simulation/runtime/terrain_floating_debris_service.gd"
)

signal command_completed(command_id: int, result: Dictionary)
## Same moment as command_completed, but carries the executed command itself —
## coop needs the original kind/target/parameters to re-broadcast dig operations
## (COOP spike stage B), which command_completed's result does not include.
signal command_executed(command: Dictionary, result: Dictionary)

@export var terrain_path: NodePath = NodePath("../VoxelTerrain")
@export var placed_blocks_path: NodePath = NodePath("../PlacedBlocks")
@export var simulation_session_path: NodePath = NodePath("../SimulationSession")

## `dig_direction` is the way the tool was pushing, unit length, or zero when
## whatever made the cut has no direction (an impact, a separation pass).
## Loose material uses it to throw cuttings back out of the hole.
signal terrain_modified(
	removed_volume_m3: float,
	dig_center: Vector3,
	dig_radius_m: float,
	dig_direction: Vector3
)
## Material was *added* to the rock SDF — sintered loose material becoming
## ground. Deliberately separate from `terrain_modified`, which the granular
## worlds turn into fresh spoil: routing a sinter through that signal would turn
## the deposited rock straight back into dust, forever. Only the dig-persistence
## listener (`bootstrap.gd`) needs this, so the new solid is saved to SQLite.
signal terrain_deposited(deposit_center: Vector3, deposit_radius_m: float)

var _terrain: Node3D
var _placed_blocks: Node
var _voxel_tool: VoxelTool
var _session: SimulationSession
var _queue: Array[Dictionary] = []
var _flush_scheduled := false
var _next_command_id := 1
var _archetype_cache: Dictionary = {}
var _snap_resolver := ConstructionSnapResolver.new()
var _excavation := TerrainExcavationService.new()
var _floating_debris = _TerrainFloatingDebrisService.new()
var _material_source := TerrainMaterialSource.new()
var _material_field := MoonMaterialField.new()
var _hand_drill_spawn_world := Vector3.ZERO
var _hand_drill_last_bite_center: Variant = null
var _hand_drill_last_bite_msec := 0
## resource_id → kilograms the drill has freed but not yet dropped as a pile.
## See `_route_hand_drill_yield`. Deliberately not persisted: a quit forfeits
## less than one chunk, which is noise against what a minute of drilling moves,
## and it is not worth the save-state to carry across.
var _hand_drill_yield_buffer: Dictionary = {}
## element_id → world-space centre of that stationary drill's last carve, so the
## drill service can sample the material it actually cut (see
## `stationary_drill_carve_point`).
var _stationary_drill_carve_points: Dictionary = {}
## element_id → world-space point a dozer blade last worked loose material at, so
## the blade service can sample the material it collected.
var _dozer_blade_contact_points: Dictionary = {}
## Whose commands this gateway executes. One local player today; under coop
## the host stamps the sending peer's uid instead.
var actor_uid := PlayerIdentity.local_uid()
var _rover_seat_player: Node3D
var _rover_seat_assembly_id := 0
var _rover_seat_element_id := 0
## True while the local player is in a passenger (non-driver) ControlSeat.
var _rover_seat_passenger := false
## Shared SeatControlState ref for the occupied seat (R9 — no per-tick dup).
## Updated on enter / configure; cleared on exit. Do not free.
var _rover_seat_policy: SeatControlState = null
var _floating_debris_parent: Node3D


func set_hand_drill_spawn_world(spawn_world: Vector3) -> void:
	_hand_drill_spawn_world = spawn_world


func _ready() -> void:
	_terrain = get_node(terrain_path)
	_placed_blocks = get_node(placed_blocks_path)
	_session = get_node_or_null(simulation_session_path) as SimulationSession
	_voxel_tool = TerrainCompat.get_voxel_tool(_terrain)
	_voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
	add_to_group(&"world_command_gateway")
	for archetype_id: String in ToolController.construction_archetype_ids():
		_get_archetype(archetype_id)
	var piston_head := Slice01Archetypes.piston_head()
	if piston_head != null:
		_archetype_cache["piston_head"] = piston_head
	call_deferred("_bind_terrain_contact_probe")
	call_deferred("_bind_seat_evict_hook")


func _bind_terrain_contact_probe() -> void:
	if _session == null or _session.world == null:
		return
	_session.world.set_terrain_contact_probe(
		_probe_assembly_terrain_contact
	)


func _bind_seat_evict_hook() -> void:
	if _session == null or _session.world == null or _seat_evict_hook_connected:
		return
	_session.world.seat_occupant_evicted.connect(_on_seat_occupant_evicted)
	_seat_evict_hook_connected = true


## Broken / removed ControlSeat: clear locomotion and detach the driver.
## Occupancy row is already gone (world emitted after erase).
func _on_seat_occupant_evicted(
	player_id: String,
	seat_element_id: int,
	assembly_id: int
) -> void:
	force_eject_seat_occupant(player_id, seat_element_id, assembly_id)


func force_eject_seat_occupant(
	player_id: String,
	seat_element_id: int = 0,
	assembly_id: int = 0
) -> void:
	GatewaySeatLocomotionService.force_eject_seat_occupant(self, player_id, seat_element_id, assembly_id)


func _probe_assembly_terrain_contact(
	assembly: SimulationAssembly,
	elements: Array[SimulationElement]
) -> Array[int]:
	return GatewayTerrainDigService._probe_assembly_terrain_contact(self, assembly, elements)


## Installed by CoopSession on a client (COOP-HOST-V0). When valid, submit()
## routes commands to the host instead of executing locally (invariant C1).
var _network_submit: Callable = Callable()
## Host: CoopSession notifies a remote peer to release_local_seat_attach.
var _seat_force_release_notify: Callable = Callable()
var _seat_evict_hook_connected := false


func set_network_submit(hook: Callable) -> void:
	_network_submit = hook


func set_seat_force_release_notify(hook: Callable) -> void:
	_seat_force_release_notify = hook


func submit(command: Dictionary) -> int:
	var queued := command.duplicate(true)
	var command_id := _next_command_id
	_next_command_id += 1
	queued["id"] = command_id
	# On a client, hand the command to the transport and stop — nothing executes
	# locally (the client world is a replica). The host stamps identity and runs
	# it; the result comes back through complete_remote().
	if _network_submit.is_valid():
		_network_submit.call(command_id, queued)
		return command_id
	# The gateway decides whose resources a command spends — not the caller.
	# Today that is always the local player; under coop this is the one line
	# that becomes "the peer that sent it" (COOP-HOST-V0 "Транспорт команд"),
	# which is why no caller is allowed to name a store itself.
	queued["actor_uid"] = actor_uid
	queued["store_id"] = PlayerIdentity.store_id(actor_uid)
	_queue.append(queued)
	if not _flush_scheduled:
		_flush_scheduled = true
		call_deferred("_flush")
	return command_id


## Host-side network entry: run a command on behalf of a connected peer. The
## peer's uid/store are stamped here (never trusted from the wire) and `source`
## is the peer's remote-avatar node, so range checks (e.g. oxygen_refill) work.
func submit_as(peer_uid: String, command: Dictionary, source_node: Node) -> int:
	var queued := command.duplicate(true)
	var command_id := _next_command_id
	_next_command_id += 1
	queued["id"] = command_id
	queued["actor_uid"] = peer_uid
	queued["store_id"] = PlayerIdentity.store_id(peer_uid)
	queued["source"] = source_node
	_queue.append(queued)
	if not _flush_scheduled:
		_flush_scheduled = true
		call_deferred("_flush")
	return command_id


## Client-side: deliver a host result under the client's own local command id,
## so every HUD/tool reconciliation loop keyed on command_completed works
## unchanged.
func complete_remote(command_id: int, result: Dictionary) -> void:
	command_completed.emit(command_id, result)


func _flush() -> void:
	_flush_scheduled = false
	while not _queue.is_empty():
		var command: Dictionary = _queue.pop_front()
		var command_id: int = command["id"]
		# Handlers read the actor_uid MEMBER (not the command dict). Point it at
		# whoever this command belongs to for the duration of its execution, then
		# restore the local player — this is what makes per-peer stores work
		# without touching every handler (COOP-HOST-V0 "Транспорт команд").
		var previous_actor := actor_uid
		actor_uid = String(command.get("actor_uid", previous_actor))
		var result := _execute(command)
		actor_uid = previous_actor
		result["command_kind"] = command.get("kind", StringName())
		command_completed.emit(
			command_id,
			result
		)
		command_executed.emit(command, result)


func _execute(command: Dictionary) -> Dictionary:
	# Second lock on invariant C1: a replica never executes a mutating command,
	# whatever the caller. Host worlds are authoritative and pass straight
	# through.
	if _session != null and _session.world != null and not _session.world.authoritative:
		return _result(&"not_authoritative")
	if not command.has("kind") or not command.has("target"):
		return _result(&"invalid_target")
	var target: Dictionary = command["target"]
	if not bool(target.get("valid", false)):
		return _result(&"no_target")

	match StringName(command["kind"]):
		&"voxel_remove":
			return _remove_voxel(command, target)
		&"dig_terrain_debris":
			return _dig_terrain_debris(command, target)
		&"scoop_spoil":
			return _scoop_spoil(command, target)
		&"dump_scoop":
			return _dump_scoop(command, target)
		&"debug_spawn_spoil":
			return _debug_spawn_spoil(command, target)
		&"damage_element":
			return _damage_element(command, target)
		&"place_block":
			return _place_block(command, target)
		&"toggle_control_seat":
			return _toggle_control_seat(command, target)
		&"construction_apply":
			return _construction_apply(command, target)
		&"weld_element":
			return _weld_element(command, target)
		&"dismantle_element":
			return _dismantle_element(command, target)
		&"transfer_resource":
			return _transfer_resource(command, target)
		&"assign_hotbar_instance":
			return _assign_hotbar_instance(command, target)
		&"connect_network":
			return _connect_network(command, target)
		&"disconnect_network":
			return _disconnect_network(command, target)
		&"set_machine_enabled":
			return _set_machine_enabled(command, target)
		&"oxygen_refill":
			return _oxygen_refill(command, target)
		&"set_element_name":
			return _set_element_name(command, target)
		&"enqueue_recipe":
			return _enqueue_recipe(command, target)
		&"dequeue_recipe":
			return _dequeue_recipe(command, target)
		&"collect_world_loot":
			return _collect_world_loot(command)
		&"set_actuator_target":
			return _set_actuator_target(command, target)
		&"configure_actuator":
			return _configure_actuator(command, target)
		&"configure_wheel":
			return _configure_wheel(command, target)
		&"configure_suspension":
			return _configure_suspension(command, target)
		&"configure_action_slot":
			return _configure_action_slot(command, target)
		&"configure_seat_controls":
			return _configure_seat_controls(command, target)
		_:
			return _result(&"invalid_target")


## True while this gateway is re-applying a dig confirmed by the coop host.
## Gates the side effects that must stay host-only (floating-chunk separation
## becomes elements and arrives via snapshot instead).
var _replaying_remote_dig := false


## Coop client entry point: carve/scoop/dump the local replica field exactly as
## the host did, crediting nothing. Bypasses _execute on purpose — a replica
## refuses mutating commands (invariant C1), but this is not a player command,
## it is the host's already-validated verdict arriving over the reliable op
## channel. For scoop/dump the coop layer stamps the host-confirmed volumes
## into parameters, so the replay moves exactly what the host moved.
func replay_remote_dig(command: Dictionary) -> bool:
	var target: Variant = command.get("target")
	if not (target is Dictionary) or not bool((target as Dictionary).get("valid", false)):
		return false
	var replay := command.duplicate(true)
	var result: Dictionary
	match StringName(command.get("kind", &"")):
		&"voxel_remove":
			var parameters: Dictionary = replay.get("parameters", {})
			# The host already routed the yield to the digger's store (and the
			# store arrives via snapshot); replaying it here would double-mine
			# every bite.
			parameters["discard_yield"] = true
			replay["parameters"] = parameters
			_replaying_remote_dig = true
			result = _remove_voxel(replay, replay["target"])
			_replaying_remote_dig = false
		&"scoop_spoil":
			result = _scoop_spoil(replay, replay["target"])
		&"dump_scoop":
			result = _dump_scoop(replay, replay["target"])
		_:
			return false
	return StringName(result.get("status", &"")) == &"ok"


func _remove_voxel(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayTerrainDigService._remove_voxel(self, command, target)


## Shove loose material out of the bit's cylinder without collecting any. The
## drill parts what it meets and mines rock only, so the parted spoil stays in
## the world (ringed on the rim by `plow_spoil`) rather than counting as yield.
## No-op when the scene has no volumetric granular world.
func _plow_hand_drill_loose(world_point: Vector3, radius_m: float) -> void:
	GatewayTerrainDigService._plow_hand_drill_loose(self, world_point, radius_m)


## Retired: the drill no longer scoops loose material (see `_remove_voxel`, which
## now parts spoil aside and cuts the rock behind it). Kept, not deleted, so the
## dig-a-heap-of-spoil path is one wiring change away if a future tool wants it.
## Drill a heap of loose material. Digging spoil moves thickness on a
## `GranularPatch` instead of carving the SDF — the rock underneath is
## untouched — but it yields the same regolith, so clearing your own spoil is
## a way to recover it rather than a dead end.
func _remove_granular(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayTerrainDigService._remove_granular(self, command, target)


## Fill a carried scoop from a heap. Reports the volume taken so the tool can
## add it to its load; the world has no record of it after this, so a caller
## that drops the number drops the material.
##
## No yield is credited: a scoop moves material around the world rather than
## into a store. Loading it into cargo is a separate mechanism and a separate
## decision.
func _scoop_spoil(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayTerrainDigService._scoop_spoil(self, command, target)


## Tip a carried load back out. Reports what the world accepted — the caller
## keeps the remainder in the tool rather than treating the dump as complete,
## or the shortfall is volume destroyed.
func _dump_scoop(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayTerrainDigService._dump_scoop(self, command, target)


## Debug: conjure loose material at the aim point, out of nothing.
##
## Loose material otherwise only exists where something dug or dumped, so a fresh
## world has nothing for a blade or a scoop to work — and getting a heap the
## honest way means standing there with the drill first. This is a test fixture,
## not a mechanic: it credits no yield and costs nothing, and no gameplay path
## reaches it.
func _debug_spawn_spoil(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayTerrainDigService._debug_spawn_spoil(self, command, target)


func _dig_terrain_debris(
	_command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayTerrainDigService._dig_terrain_debris(self, _command, target)


## Drop what the drill freed on the ground. Nothing goes straight into the
## pack: what you dug by hand you pick up by hand, so carrying capacity is a
## decision you make at the working face rather than a silent cap that turns
## into litter the moment it is reached.
##
## A bite is ~0.1 m³ every 0.15 s, so one pile per bite left a trail of small
## ones down the tunnel. Mass waits in `_hand_drill_yield_buffer` until it is
## worth a discrete object instead.
func _route_hand_drill_yield(
	center: Vector3,
	yields: Array[Dictionary]
) -> void:
	GatewayTerrainDigService._route_hand_drill_yield(self, center, yields)


## Mass of `resource_id` that has to accumulate before a chunk drops. The
## balance value is a volume, so chunks are a consistent size on the ground;
## this converts it with the resource's own density.
func _hand_drill_emit_quantum_kg(resource_id: String) -> float:
	return GatewayTerrainDigService._hand_drill_emit_quantum_kg(self, resource_id)


func apply_terrain_carve(
	op: Dictionary,
	volume_budget_m3: float = INF
) -> float:
	return GatewayTerrainDigService.apply_terrain_carve(self, op, volume_budget_m3)


func _dig_center_from_request(request: Dictionary) -> Vector3:
	return GatewayTerrainDigService._dig_center_from_request(self, request)


func _dig_radius_from_request(request: Dictionary) -> float:
	return GatewayTerrainDigService._dig_radius_from_request(self, request)


## Announce that loose material was sintered into the rock SDF, so the dig
## stream is marked dirty and the new solid persists. Does *not* touch
## `terrain_modified` — see that signal's note. The granular world writes the
## SDF itself (it owns the tool); this is only the persistence hand-off.
func mark_terrain_deposited(
	deposit_center: Vector3 = Vector3.ZERO,
	deposit_radius_m: float = 0.0
) -> void:
	GatewayTerrainDigService.mark_terrain_deposited(self, deposit_center, deposit_radius_m)


func _notify_terrain_modified(
	removed_volume_m3: float,
	dig_center: Vector3 = Vector3.ZERO,
	dig_radius_m: float = 0.0,
	dig_direction: Vector3 = Vector3.ZERO
) -> void:
	GatewayTerrainDigService._notify_terrain_modified(self, removed_volume_m3, dig_center, dig_radius_m, dig_direction)


func stationary_drill_has_terrain_contact(element_id: int) -> bool:
	return GatewayTerrainDigService.stationary_drill_has_terrain_contact(self, element_id)


## World-space point the drill's last carve worked, for material sampling. The
## drill service calls this straight after `carve_stationary_drill`, so the
## cached centre is the one it just cut. Falls back to a fresh contact resolve
## when nothing is cached yet (first tick / cache miss).
func stationary_drill_carve_point(element_id: int) -> Vector3:
	return GatewayTerrainDigService.stationary_drill_carve_point(self, element_id)


func carve_stationary_drill(element_id: int) -> float:
	return GatewayTerrainDigService.carve_stationary_drill(self, element_id)


func _maybe_separate_floating_chunks(
	world_center: Vector3,
	removed_m3: float,
	dig_radius_m: float
) -> void:
	GatewayTerrainDigService._maybe_separate_floating_chunks(self, world_center, removed_m3, dig_radius_m)


func _ensure_floating_debris_parent() -> Node3D:
	return GatewayTerrainDigService._ensure_floating_debris_parent(self)


func _stationary_drill_contact(element_id: int) -> Dictionary:
	return GatewayTerrainDigService._stationary_drill_contact(self, element_id)


func _stationary_drill_working_frame(element: SimulationElement) -> Transform3D:
	return GatewayTerrainDigService._stationary_drill_working_frame(self, element)


func _stationary_drill_physics_body(
	element: SimulationElement
) -> PhysicsBody3D:
	return GatewayTerrainDigService._stationary_drill_physics_body(self, element)


func _stationary_drill_sdf_contact_along_axis(
	tip: Vector3,
	direction: Vector3
) -> Dictionary:
	return GatewayTerrainDigService._stationary_drill_sdf_contact_along_axis(self, tip, direction)


# --- Dozer blade (mounted) terrain hooks -------------------------------------
#
# A dozer blade works loose (granular) material only — it never touches the SDF
# rock. `DozerBladeService` runs in the simulation (no scene tree) and reaches
# the granular world through these gateway callables, the same shape as the
# stationary drill's carve hooks. Contact is probed against loose material in
# front of the blade's working edge (local +X, like the drill).


func _granular_world() -> Node:
	return GatewayTerrainDigService._granular_world(self)


func dozer_blade_has_terrain_contact(element_id: int) -> bool:
	return GatewayTerrainDigService.dozer_blade_has_terrain_contact(self, element_id)


## World point the blade last worked, for material sampling. Falls back to a
## fresh contact resolve when nothing is cached (first tick / cache miss).
func dozer_blade_contact_point(element_id: int) -> Vector3:
	return GatewayTerrainDigService.dozer_blade_contact_point(self, element_id)


## Load up to `budget_m3` of loose material under the blade into the tool,
## returning the volume actually taken. The world loses that volume here; the
## service credits it as yield.
func dozer_blade_load(element_id: int, budget_m3: float) -> float:
	return GatewayTerrainDigService.dozer_blade_load(self, element_id, budget_m3)


## Shove loose material aside without collecting any (buffer full). Returns the
## volume moved; it stays in the world.
func dozer_blade_plow(element_id: int) -> float:
	return GatewayTerrainDigService.dozer_blade_plow(self, element_id)


func _dozer_blade_contact(element_id: int) -> Dictionary:
	return GatewayTerrainDigService._dozer_blade_contact(self, element_id)


func get_voxel_tool() -> VoxelTool:
	return _voxel_tool


func get_world() -> SimulationWorld:
	if _session == null:
		return null
	return _session.world


func _target_card_keys(target: Dictionary) -> Dictionary:
	var element_id := InteractionHit.element_id_from(target)
	if element_id <= 0:
		return {}
	var world := get_world()
	if world == null:
		return {}
	var card := world.get_interaction_card(element_id)
	if card == null:
		return {}
	return card.keys


## Suit damage from world events that are not structural commands (meteorites).
## Routed through the gateway so presentation never writes the world directly.
func damage_player_suit(
	player_id: String,
	amount: float,
	source: StringName = &""
) -> bool:
	var world := get_world()
	if world == null or player_id.is_empty():
		return false
	return world.apply_suit_damage(player_id, amount, source)


## Authoritative hold-interact path. Identity and cadence are server-owned:
## callers provide only the normal current-hit snapshot and source node.
func _oxygen_refill(command_data: Dictionary, target: Dictionary) -> Dictionary:
	return GatewayMachineCommandService._oxygen_refill(self, command_data, target)


## True when `point` lies on/near any authored collider of the module.
func _oxygen_module_hit_in_reach(
	module: SimulationElement,
	point: Vector3
) -> bool:
	return GatewayMachineCommandService._oxygen_module_hit_in_reach(self, module, point)


func _place_block(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayConstructionService._place_block(self, command, target)


func _toggle_control_seat(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewaySeatLocomotionService._toggle_control_seat(self, command, target)


func is_rover_seated(player: Node = null) -> bool:
	return GatewaySeatLocomotionService.is_rover_seated(self, player)


func get_local_seat_element_id() -> int:
	return GatewaySeatLocomotionService.get_local_seat_element_id(self)


func is_local_seat_driver() -> bool:
	return GatewaySeatLocomotionService.is_local_seat_driver(self)


static func is_passenger_seat_archetype(archetype_id: String) -> bool:
	return archetype_id == "passenger_seat"


## Enter-vs-exit for a remote actor must use occupancy, not the avatar node:
## RemotePlayer has no is_in_vehicle, so a node check would always enter.
## Local also treats gateway seat id / live attach as seated so a pruned
## occupancy cannot turn E into a failed re-enter (broken-seat trap).
func _actor_wants_seat_exit(player: Node3D, is_local_actor: bool) -> bool:
	return GatewaySeatLocomotionService._actor_wants_seat_exit(self, player, is_local_actor)


func tick_rover_locomotion_input() -> void:
	GatewaySeatLocomotionService.tick_rover_locomotion_input(self)


func _seat_frame_should_wake(locomotion: AssemblyLocomotionController) -> bool:
	return GatewaySeatLocomotionService._seat_frame_should_wake(self, locomotion)


## Normalize InputMap once per tick. jump and move_up share Space in project.godot.
## Public so CoopSession can sample the same raw dict for remote drivers.
func collect_seat_raw_input(zero_frame: bool) -> Dictionary:
	return GatewaySeatLocomotionService.collect_seat_raw_input(self, zero_frame)


## Host applies a guest driver's 20 Hz stream packet (not a gateway command —
## command completion would storm snapshot re-broadcasts).
func apply_remote_driver_input(
	remote_uid: String,
	raw: Dictionary,
	edges: Dictionary
) -> void:
	GatewaySeatLocomotionService.apply_remote_driver_input(self, remote_uid, raw, edges)


## Zero a disconnected / timed-out remote driver's continuous channels.
func clear_remote_driver_input(remote_uid: String) -> void:
	GatewaySeatLocomotionService.clear_remote_driver_input(self, remote_uid)


## Client-only: parent the local Player to the replica seat body after a host
## ok for toggle_control_seat. Bypasses _execute (replica is not authoritative).
func apply_local_seat_attach(
	player: Node3D,
	element_id: int,
	assembly_id: int,
	passenger: bool = false
) -> void:
	GatewaySeatLocomotionService.apply_local_seat_attach(self, player, element_id, assembly_id, passenger)


## Client: re-bind to the seat body if a snapshot recreate orphaned the Player
## while gateway seat id is still claimed. Cheap — only while seated.
func ensure_local_seat_binding() -> bool:
	return GatewaySeatLocomotionService.ensure_local_seat_binding(self)


## Client-only counterpart of apply_local_seat_attach.
func release_local_seat_attach() -> void:
	GatewaySeatLocomotionService.release_local_seat_attach(self)


func _consume_flight_look_delta() -> Vector2:
	return GatewaySeatLocomotionService._consume_flight_look_delta(self)


func _toggle_rover_parking_brake(
	assembly_id: int,
	locomotion: AssemblyLocomotionController
) -> void:
	GatewaySeatLocomotionService._toggle_rover_parking_brake(self, assembly_id, locomotion)


func _resolve_active_rover_assembly_id() -> int:
	return GatewaySeatLocomotionService._resolve_active_rover_assembly_id(self)


func _is_rover_seated(player: Node3D) -> bool:
	return GatewaySeatLocomotionService._is_rover_seated(self, player)


func _resolve_passenger_seat(command: Dictionary, element_id: int) -> bool:
	return GatewaySeatLocomotionService._resolve_passenger_seat(self, command, element_id)


func _enter_rover_seat(
	player: Node3D,
	element_id: int,
	assembly_id: int,
	is_local_actor: bool = true,
	passenger: bool = false
) -> Dictionary:
	return GatewaySeatLocomotionService._enter_rover_seat(self, player, element_id, assembly_id, is_local_actor, passenger)


func _prepare_rover_for_drive(assembly_id: int) -> void:
	GatewaySeatLocomotionService._prepare_rover_for_drive(self, assembly_id)


func _rover_has_powered_wheel(
	world: SimulationWorld,
	assembly_id: int
) -> bool:
	return GatewaySeatLocomotionService._rover_has_powered_wheel(self, world, assembly_id)


func _ensure_rover_power_network(
	world: SimulationWorld,
	assembly_id: int
) -> void:
	GatewaySeatLocomotionService._ensure_rover_power_network(self, world, assembly_id)


func _wake_rover_body(assembly_id: int) -> void:
	GatewaySeatLocomotionService._wake_rover_body(self, assembly_id)


func _exit_rover_seat(
	player: Node3D,
	is_local_actor: bool = true
) -> Dictionary:
	return GatewaySeatLocomotionService._exit_rover_seat(self, player, is_local_actor)


func _exit_remote_rover_seat() -> Dictionary:
	return GatewaySeatLocomotionService._exit_remote_rover_seat(self)


## Occupied ControlSeat: only the seated player's commands may edit bar/seat
## routing. UI nodes (terminal, compact bar) submit through gateway with
## actor_uid — not command.source (spec: same occupant check as seat enter).
func _seat_host_command_allowed(seat_element_id: int) -> bool:
	return GatewaySeatLocomotionService._seat_host_command_allowed(self, seat_element_id)


## Mouse attitude follows Control Gyros only when the assembly has gyros to
## consume look — wheel rovers keep FP freelook (CONTROL-AXES-V0).
func _sync_seat_mouse_attitude(player: Node3D, seat_element_id: int) -> void:
	GatewaySeatLocomotionService._sync_seat_mouse_attitude(self, player, seat_element_id)


func preview_construction(
	target: Dictionary,
	archetype_id: String,
	orientation_index: int,
	held_ground_pivot: Vector3 = Vector3(INF, INF, INF),
	held_attach_pivot: Vector3 = Vector3(INF, INF, INF)
) -> Dictionary:
	return GatewayConstructionService.preview_construction(self, target, archetype_id, orientation_index, held_ground_pivot, held_attach_pivot)


func baseline_ground_pivot(
	target: Dictionary,
	archetype_id: String
) -> Vector3:
	return GatewayConstructionService.baseline_ground_pivot(self, target, archetype_id)


func resolve_construction_placement(params: Dictionary) -> Dictionary:
	return GatewayConstructionService.resolve_construction_placement(self, params)


## Cheap staleness token for preview resolve reuse: any structural mutation
## bumps it. Motion/parking flips are covered by the preview's resolve
## heartbeat, not by this counter.
func snap_context_revision() -> int:
	return GatewayConstructionService.snap_context_revision(self)


func snap_resolve_stats() -> Dictionary:
	return GatewayConstructionService.snap_resolve_stats(self)


func reset_construction_snap() -> void:
	GatewayConstructionService.reset_construction_snap(self)


func player_carry_load() -> Dictionary:
	return GatewayReadModelService.player_carry_load(self)


func resource_store(store_id: String) -> SimulationResourceStore:
	return GatewayReadModelService.resource_store(self, store_id)


func store_snapshot(store_id: String) -> Dictionary:
	return GatewayReadModelService.store_snapshot(self, store_id)


func vehicle_power_snapshot(assembly_id: int = 0) -> Dictionary:
	return GatewayReadModelService.vehicle_power_snapshot(self, assembly_id)


func control_terminal_snapshot(
	assembly_id: int = 0,
	hint_element_id: int = 0
) -> Dictionary:
	return GatewayReadModelService.control_terminal_snapshot(
		self, assembly_id, hint_element_id
	)


func control_terminal_bar_snapshot(
	assembly_id: int = 0,
	hint_element_id: int = 0
) -> Dictionary:
	return GatewayReadModelService.control_terminal_bar_snapshot(
		self, assembly_id, hint_element_id
	)


func player_inventory() -> PlayerInventoryRegistry:
	return GatewayReadModelService.player_inventory(self)


func player_inventory_revision() -> int:
	return GatewayReadModelService.player_inventory_revision(self)


## Presentation entry for hotbar rebind. Always goes through submit() so coop
## clients hand the mutate to the host (actor_uid stamped host-side); local /
## host execute via `_assign_hotbar_instance`. Returns the queued command id.
func assign_player_hotbar_instance(
	page: int,
	slot: int,
	instance_id: String
) -> int:
	return submit({
		"kind": &"assign_hotbar_instance",
		"source": self,
		"target": {
			"valid": true,
			"point": Vector3.ZERO,
			"normal": Vector3.UP,
			"distance": 0.0,
			"target_kind": InteractionHit.KIND_NONE,
			"collider": null,
			"target_id": &"",
			"element_id": 0,
		},
		"parameters": {
			"page": page,
			"slot": slot,
			"instance_id": instance_id,
		},
	})


func construction_archetype(archetype_id: String) -> ElementArchetype:
	return GatewayReadModelService.construction_archetype(self, archetype_id)


func archetype_display_name(archetype_id: String) -> String:
	return GatewayReadModelService.archetype_display_name(self, archetype_id)


func map_overlay_entries() -> Array[Dictionary]:
	return GatewayReadModelService.map_overlay_entries(self)


func _damage_element(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._damage_element(self, command, target)


func apply_damage(
	element_id: int,
	amount: float,
	refund_fraction_on_destroy: float = 0.0,
	store_id: String = ""
) -> Dictionary:
	return GatewayMachineCommandService.apply_damage(self, element_id, amount, refund_fraction_on_destroy, store_id)


func _construction_apply(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayConstructionService._construction_apply(self, command, target)


func _weld_element(
	_command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayConstructionService._weld_element(self, _command, target)


func _apply_place_plan(plan: Dictionary) -> Dictionary:
	return GatewayConstructionService._apply_place_plan(self, plan)


## Reseats a first-on-ground placement so its footprint rests on the lowest
## terrain sample beneath it along Field down. Only shifts the continuous root;
## the discrete grid frame (topology) is untouched. Non-ground plans (attaching
## to an existing assembly) and invalid plans pass through unchanged.
func _seat_ground_plan(plan: Dictionary) -> Dictionary:
	return GatewayConstructionService._seat_ground_plan(self, plan)


func _physics_space_state() -> PhysicsDirectSpaceState3D:
	if _terrain == null or not _terrain.is_inside_tree():
		return null
	return _terrain.get_world_3d().direct_space_state


## Rejects a valid placement plan when its final world pose clips another
## construction, the player, or (for physical elements) terrain — the world-space
## checks the grid kernel cannot make. Invalid plans and plans without physics
## context pass through untouched.
func _guard_placement_collision(plan: Dictionary) -> Dictionary:
	return GatewayConstructionService._guard_placement_collision(self, plan)


func _get_archetype(archetype_id: String) -> ElementArchetype:
	if _archetype_cache.has(archetype_id):
		return _archetype_cache[archetype_id] as ElementArchetype
	var loaded := Slice01Archetypes.load_required(archetype_id)
	# Never cache a miss — a hot-added archetype would stay permanently null.
	if loaded != null:
		_archetype_cache[archetype_id] = loaded
	return loaded


func apply_transfer_resource(command: TransferResourceCommand) -> Dictionary:
	return GatewayMachineCommandService.apply_transfer_resource(self, command)


func apply_connect_network(
	element_a_id: int,
	element_b_id: int,
	port_a_id: String = "",
	port_b_id: String = "",
	waypoints: PackedVector3Array = PackedVector3Array(),
	waypoint_anchors: PackedInt32Array = PackedInt32Array()
) -> Dictionary:
	return GatewayMachineCommandService.apply_connect_network(self, element_a_id, element_b_id, port_a_id, port_b_id, waypoints, waypoint_anchors)


## Rope form: both ends are free attach points in world space. An end with
## element id 0 landed on bare terrain and gets a stake driven for it — see
## [CableStakeUtil]. [param stake_up] is local up at the click: gravity lives
## on a scene node, and the command that runs on the world cannot go looking
## for one. [param link_kind] is ELECTRIC (the `connect` tool's slack cable,
## current behaviour) or MECHANICAL (the `rope` tool, ROPE-CHAIN-V0): a
## physical rope/chain that mass-couples instead of conducting.
func apply_connect_rope(
	element_a_id: int,
	attach_a: Vector3,
	element_b_id: int,
	attach_b: Vector3,
	slack: float = CableAnchorUtil.DEFAULT_SLACK,
	routed_m: float = 0.0,
	stake_up: Vector3 = Vector3.UP,
	link_kind: int = IndustryElectricLink.Kind.ELECTRIC
) -> Dictionary:
	return GatewayMachineCommandService.apply_connect_rope(self, element_a_id, attach_a, element_b_id, attach_b, slack, routed_m, stake_up, link_kind)


func _connect_network(
	command: Dictionary,
	_target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._connect_network(self, command, _target)


func _connect_failure_reason(reason: StringName) -> StringName:
	match reason:
		StructuralCommandResult.REASON_DUPLICATE_CONNECTION:
			return &"duplicate_connection"
		StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION:
			return &"incompatible_connection"
		StructuralCommandResult.REASON_CABLE_TOO_LONG:
			return &"cable_too_long"
		StructuralCommandResult.REASON_ENDPOINT_NOT_WIREABLE:
			return &"endpoint_not_wireable"
		StructuralCommandResult.REASON_ELEMENT_INCOMPLETE:
			return &"element_incomplete"
		StructuralCommandResult.REASON_ELEMENT_BROKEN:
			return &"element_broken"
		_:
			return _map_structural_reason(reason)


func _disconnect_network(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._disconnect_network(self, command, target)


func _transfer_resource(
	command: Dictionary,
	_target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._transfer_resource(self, command, _target)


## Host-authoritative hotbar rebind for the current actor_uid (COOP-HOST-V0).
## Empty instance_id clears the slot; non-empty must be owned by that player.
func _assign_hotbar_instance(
	command: Dictionary,
	_target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._assign_hotbar_instance(self, command, _target)


## Переименование узла из терминала управления. Надёжная команда, но не
## структурная: меняет `state_revision` элемента, не топологию (CONTROL-ACTIONS-V0).
func _set_element_name(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._set_element_name(self, command, target)


## Право бить по слотам бара — только текущий occupant хоста (CONTROL-ACTIONS-V0
## «Persistence и кооп»). Занят кем-то другим сейчас проверяется только для
## кокпита (`_rover_seat_*` — эксклюзивная посадка); у control_terminal нет
## персистентного occupant'а («occupied_by ... interaction range (пульт)» —
## окно и так не откроется без interaction-range, дальше проверять нечего).
func _configure_action_slot(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._configure_action_slot(self, command, target)


func _configure_seat_controls(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._configure_seat_controls(self, command, target)


func _set_machine_enabled(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._set_machine_enabled(self, command, target)


func _enqueue_recipe(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._enqueue_recipe(self, command, target)


func _dequeue_recipe(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._dequeue_recipe(self, command, target)


func _set_actuator_target(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._set_actuator_target(self, command, target)


func _configure_actuator(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._configure_actuator(self, command, target)


func _configure_wheel(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._configure_wheel(self, command, target)


func _configure_suspension(
	command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayMachineCommandService._configure_suspension(self, command, target)


func _collect_world_loot(command: Dictionary) -> Dictionary:
	return GatewayMachineCommandService._collect_world_loot(self, command)


func _dismantle_element(
	_command: Dictionary,
	target: Dictionary
) -> Dictionary:
	return GatewayConstructionService._dismantle_element(self, _command, target)


func _structural_result(
	result: StructuralCommandResult
) -> Dictionary:
	if result == null:
		return _result(&"not_ready")
	return _result(
		&"ok" if result.is_ok() else _map_structural_reason(result.reason),
		result.data
	)


func _map_structural_reason(reason: StringName) -> StringName:
	match reason:
		StructuralCommandResult.REASON_OVERLAP:
			return &"blocked"
		StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION:
			return &"blocked"
		StructuralCommandResult.REASON_MISALIGNED_CONNECTION:
			return &"blocked"
		StructuralCommandResult.REASON_STALE_REVISION:
			return &"not_ready"
		StructuralCommandResult.REASON_INVALID_REFERENCE:
			return &"invalid_target"
		StructuralCommandResult.REASON_INVALID_TRANSFORM:
			return &"invalid_target"
		ConstructionPlacementCollision.REASON_STRUCTURE_OVERLAP:
			return &"structure_overlap"
		ConstructionPlacementCollision.REASON_TERRAIN_OVERLAP:
			return &"terrain_overlap"
		ConstructionPlacementCollision.REASON_PLAYER_BLOCKED:
			return &"player_blocked"
		_:
			return reason


func _result(
	reason: StringName,
	data: Dictionary = {}
) -> Dictionary:
	return {
		"status": &"ok" if reason == &"ok" else &"failed",
		"reason": reason,
		"data": data,
	}
