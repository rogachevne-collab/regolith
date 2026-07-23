class_name SimulationWorld
extends Node

const BodyGroupMotionUtilScript := preload(
	"res://scripts/simulation/runtime/body_group_motion_util.gd"
)
const ConstructionOccupancyUtilScript := preload(
	"res://scripts/simulation/runtime/construction_occupancy_util.gd"
)
const ConstructionCommandServiceScript := preload(
	"res://scripts/simulation/runtime/construction_command_service.gd"
)
const TopologyMutationServiceScript := preload(
	"res://scripts/simulation/runtime/topology_mutation_service.gd"
)
const WorldLootServiceScript := preload(
	"res://scripts/simulation/runtime/world_loot_service.gd"
)
const IndustryNetworkCommandsScript := preload(
	"res://scripts/simulation/runtime/industry_network_commands.gd"
)

signal structural_event(event: Dictionary)
signal structural_command_completed(
	command_id: int,
	result: StructuralCommandResult
)
signal player_inventory_changed()
## Emitted when any channel of one player's suit actually moved.
signal suit_changed(player_id: String)

## Monotonic world-wide topology counter: bumps on every structural mutation.
## Cheap staleness check for presentation-side caches (snap resolve reuse).
var topology_generation := 0
## Nested: while > 0, structural_event is suppressed (except world_restored).
## Use around bulk compose so projections rebuild once at the end.
var _structural_batch_depth := 0
## Set when a topology change happened inside a batch. The heavy full-world
## derived recompute (store sync, cargo graph, network prune) is coalesced to
## run once when the batch closes instead of once per placed/welded element —
## the difference between an instant compose and a ~30 s one on big rovers.
var _deferred_derived_recompute := false
var _allocator := SimulationIdAllocator.new()
var _archetypes := ArchetypeRegistry.new()
var _assemblies: Dictionary = {}
var _elements: Dictionary = {}
var _joints: Dictionary = {}
var _redirects: Dictionary = {}
var _resource_stores: Dictionary = {}
var _player_inventory: PlayerInventoryRegistry
var _player_inventory_revision := 0
## player_id → SimulationSuitState.
var _suits: Dictionary = {}
var _industry_network := IndustryNetworkState.create_default()
var _industry_elements: Dictionary = {}
var _wheel_instances: Dictionary = {}
var _suspension_instances: Dictionary = {}
## element_id хоста (роль ControlSeat) → ActionBarState (CONTROL-ACTIONS-V0).
var _action_bars: Dictionary = {}
var _wheel_runtime: Dictionary = {}
var _assembly_locomotion: Dictionary = {}
var _cargo_graph := CargoGraph.new()
var _industry_runner: Node
var _world_loot_piles: Dictionary = {}
var _simulation_time_s: float = 0.0
var _command_queue: Array[StructuralCommand] = []
var _flush_scheduled := false
var _terrain_contact_probe: Callable
## Cache for ConstructionCommandService.validate_construction_archetype
## (key: archetype instance_id → fingerprint + validation result).
var _archetype_validation_cache: Dictionary = {}
## Cache for ConstructionOccupancyUtil.assembly_occupancy_index
## (key: assembly_id → {revision, cells}).
var _occupancy_index_cache: Dictionary = {}
## Cache BodyGroupCompiler results (key: assembly_id → {revision, result}).
## Without this, element_group_motion / preview validate recompile large
## rover graphs hundreds of times per second.
var _body_group_compile_cache: Dictionary = {}

func set_terrain_contact_probe(probe: Callable) -> void:
	_terrain_contact_probe = probe

func get_allocator() -> SimulationIdAllocator:
	return _allocator

func get_archetype_registry() -> ArchetypeRegistry:
	return _archetypes

func list_assemblies() -> Array[SimulationAssembly]:
	var result: Array[SimulationAssembly] = []
	for assembly_id: int in _sorted_keys(_assemblies):
		result.append(_assemblies[assembly_id])
	return result

func list_elements() -> Array[SimulationElement]:
	var result: Array[SimulationElement] = []
	for element_id: int in _sorted_keys(_elements):
		result.append(_elements[element_id])
	return result

func list_joints() -> Array[SimulationJoint]:
	var result: Array[SimulationJoint] = []
	for joint_id: int in _sorted_keys(_joints):
		result.append(_joints[joint_id])
	return result

func list_redirect_from_ids() -> Array[int]:
	return _sorted_keys(_redirects)

func list_resource_stores() -> Array[SimulationResourceStore]:
	var result: Array[SimulationResourceStore] = []
	var store_ids: Array = _resource_stores.keys()
	store_ids.sort()
	for store_id: Variant in store_ids:
		result.append(_resource_stores[store_id])
	return result

func get_resource_store(store_id: String) -> SimulationResourceStore:
	return _resource_stores.get(store_id) as SimulationResourceStore

## Suit state is per player id (COOP-HOST-V0 "Per-peer player state"): it lives
## here rather than on the player scene so it rides the snapshot into the save
## and, later, into the join payload. Presentation reads it through the
## `SuitState` view node and never writes it.
func get_suit_state(player_id: String) -> SimulationSuitState:
	return _suits.get(player_id) as SimulationSuitState

func ensure_suit_state(player_id: String) -> SimulationSuitState:
	var suit := get_suit_state(player_id)
	if suit == null:
		suit = SimulationSuitState.new()
		_suits[player_id] = suit
		suit_changed.emit(player_id)
	return suit

func has_suit_state(player_id: String) -> bool:
	return _suits.has(player_id)

func list_suit_state_ids() -> Array[String]:
	var ids: Array[String] = []
	for player_id: String in _suits.keys():
		ids.append(player_id)
	ids.sort()
	return ids

func apply_suit_damage(
	player_id: String,
	amount: float,
	source: StringName = &""
) -> bool:
	var suit := ensure_suit_state(player_id)
	if not suit.apply_damage(amount, source):
		return false
	suit_changed.emit(player_id)
	return true

func fill_suit_state(player_id: String) -> void:
	if ensure_suit_state(player_id).fill():
		suit_changed.emit(player_id)

## Advances the placeholder drain/regen for every known suit. Driven by
## SimulationSession so headless tests can step it deterministically.
func tick_suits(delta: float) -> void:
	for player_id: String in _suits.keys():
		var suit: SimulationSuitState = _suits[player_id]
		if suit.tick(delta):
			suit_changed.emit(player_id)

func get_player_inventory() -> PlayerInventoryRegistry:
	return _player_inventory

func get_player_inventory_revision() -> int:
	return _player_inventory_revision

func ensure_player_inventory() -> PlayerInventoryRegistry:
	if _player_inventory == null:
		_player_inventory = PlayerInventoryRegistry.new()
		_player_inventory.seed_starter_tools(false)
	return _player_inventory

func assign_player_hotbar_instance(
	page: int,
	slot: int,
	instance_id: String
) -> bool:
	var registry := ensure_player_inventory()
	if registry == null or not registry.set_hotbar_ref(page, slot, instance_id):
		return false
	_bump_player_inventory_revision()
	return true

func _bump_player_inventory_revision() -> void:
	_player_inventory_revision += 1
	emit_signal("player_inventory_changed")

func get_industry_network() -> IndustryNetworkState:
	return _industry_network

func get_cargo_graph() -> CargoGraph:
	return _cargo_graph

func ensure_cargo_graph_current() -> CargoGraph:
	if _cargo_graph_needs_rebuild():
		_cargo_graph.rebuild(self)
	return _cargo_graph

func get_cargo_adjacency_graph() -> Array[Dictionary]:
	return ensure_cargo_graph_current().list_edges()

func industry_tick(delta_s: float) -> void:
	if _industry_runner == null:
		_industry_runner = IndustrySimulation.new()
		(_industry_runner as IndustrySimulation).bind_world(self)
	(_industry_runner as IndustrySimulation).tick(self, delta_s)

func advance_industry_time(delta_s: float) -> void:
	_simulation_time_s += maxf(delta_s, 0.0)
	_purge_expired_loot_piles()

func get_element_industry_buffer(element_id: int) -> ElementIndustryBuffer:
	var element := get_element(element_id)
	if element == null:
		return null
	return element.industry_buffer

func get_element_content_mass_kg(element_id: int) -> float:
	return IndustryStoreService.content_mass_kg(
		self,
		get_element(element_id)
	)

func list_electric_links() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for link: IndustryElectricLink in _industry_network.list_links():
		rows.append(link.to_dict())
	return rows

func connect_network(
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String,
	expected_assembly_revision: int = -1,
	waypoints: PackedVector3Array = PackedVector3Array(),
	waypoint_anchors: PackedInt32Array = PackedInt32Array()
) -> StructuralCommandResult:
	var command := ConnectNetworkCommand.new()
	command.element_a_id = element_a_id
	command.port_a_id = port_a_id
	command.element_b_id = element_b_id
	command.port_b_id = port_b_id
	command.expected_assembly_revision = expected_assembly_revision
	command.waypoints = waypoints
	command.waypoint_anchors = waypoint_anchors
	return apply_structural_command_now(command)

## Free-attached rope (CABLE-ROPE-V0). `attach_*` are world-space points;
## `element_*_id` 0 nails that end to the world. No placement requirements.
func connect_rope(
	element_a_id: int,
	attach_a: Vector3,
	element_b_id: int,
	attach_b: Vector3,
	slack: float = CableAnchorUtil.DEFAULT_SLACK,
	routed_m: float = 0.0
) -> StructuralCommandResult:
	var command := ConnectNetworkCommand.new()
	command.element_a_id = element_a_id
	command.element_b_id = element_b_id
	command.port_a_id = ""
	command.port_b_id = ""
	command.attach_a = attach_a
	command.attach_b = attach_b
	command.slack = slack
	command.routed_m = routed_m
	return apply_structural_command_now(command)

func disconnect_network(
	element_a_id: int = 0,
	port_a_id: String = "",
	element_b_id: int = 0,
	port_b_id: String = "",
	link_id: int = 0,
	expected_assembly_revision: int = -1
) -> StructuralCommandResult:
	var command := DisconnectNetworkCommand.new()
	command.element_a_id = element_a_id
	command.port_a_id = port_a_id
	command.element_b_id = element_b_id
	command.port_b_id = port_b_id
	command.link_id = link_id
	command.expected_assembly_revision = expected_assembly_revision
	return apply_structural_command_now(command)

func apply_transfer_resource(command: TransferResourceCommand) -> Dictionary:
	var service := CargoTransferService.new()
	var result := service.transfer_resource_command(self, command)
	if StringName(result.get("reason", &"")) == &"ok":
		_bump_player_inventory_revision()
	return result

func apply_set_machine_enabled(
	command: SetMachineEnabledCommand
) -> Dictionary:
	if _industry_runner == null:
		_industry_runner = IndustrySimulation.new()
		(_industry_runner as IndustrySimulation).bind_world(self)
	return (_industry_runner as IndustrySimulation).apply_set_machine_enabled(
		command
	)

## Переименование экземпляра: instance-состояние, не топология. Меняет только
## `state_revision` элемента (как weld/damage/repair), поэтому пересчёт связности,
## compound collider и `Assembly.revision` не трогаются.
func apply_set_element_name(command: SetElementNameCommand) -> Dictionary:
	if command == null or command.element_id <= 0:
		return {"reason": &"invalid_target"}
	var element := get_element(command.element_id)
	if element == null:
		return {"reason": &"invalid_target"}
	var clean := SetElementNameCommand.sanitize(command.element_name)
	if element.custom_name == clean:
		return {
			"reason": &"ok",
			"element_id": command.element_id,
			"custom_name": clean,
		}
	element.custom_name = clean
	element.bump_state_revision()
	return {
		"reason": &"ok",
		"element_id": command.element_id,
		"custom_name": clean,
	}


## Привязка/снятие одной клавиши бара хоста. Instance-состояние, не топология:
## как apply_set_element_name, меняет только `state_revision` хоста, не
## `Assembly.revision`. Гейт по роли — на этой границе (снапшот-валидация
## гейтует так же), хранилище само не гейтует (ensure_action_bar_state).
func apply_configure_action_slot(
	command: ConfigureActionSlotCommand
) -> Dictionary:
	if command == null or command.host_element_id <= 0:
		return {"reason": &"invalid_target"}
	var host := get_element(command.host_element_id)
	if host == null:
		return {"reason": &"invalid_target"}
	var archetype := host.get_archetype()
	if archetype == null or not archetype.roles.has("ControlSeat"):
		return {"reason": &"invalid_target"}
	if not host.is_operational():
		return {"reason": &"element_incomplete"}
	if (
		command.page < 0
		or command.page >= ActionBarState.PAGE_COUNT
		or command.index < 0
		or command.index >= ActionBarState.SLOTS_PER_PAGE
	):
		return {"reason": &"invalid_target"}
	var state := ensure_action_bar_state(command.host_element_id)
	state.set_slot(command.page, command.index, command.payload)
	host.bump_state_revision()
	return {
		"reason": &"ok",
		"host_element_id": command.host_element_id,
		"page": command.page,
		"index": command.index,
	}


func apply_set_actuator_target(
	command: SetActuatorTargetCommand
) -> Dictionary:
	return ActuatorSimulationService.apply_set_actuator_target(self, command)

func apply_configure_actuator(
	command: ConfigureActuatorCommand
) -> Dictionary:
	return ActuatorSimulationService.apply_configure_actuator(self, command)

func apply_configure_wheel(
	command: ConfigureWheelCommand
) -> Dictionary:
	return WheelSimulationService.apply_configure_wheel(self, command)

func apply_configure_suspension(
	command: ConfigureSuspensionCommand
) -> Dictionary:
	return WheelSimulationService.apply_configure_suspension(self, command)

func get_locomotion_controller(
	assembly_id: int
) -> AssemblyLocomotionController:
	if not _assembly_locomotion.has(assembly_id):
		_assembly_locomotion[assembly_id] = AssemblyLocomotionController.new()
	return _assembly_locomotion[assembly_id] as AssemblyLocomotionController

func list_locomotion_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for assembly_id: int in _sorted_keys(_assembly_locomotion):
		var controller := (
			_assembly_locomotion[assembly_id] as AssemblyLocomotionController
		)
		if controller == null:
			continue
		var keep := (
			controller.is_activated()
			or controller.has_released_from_anchor()
			or ThrusterSimulationService.is_mobile_assembly(self, assembly_id)
		)
		if not keep:
			continue
		rows.append({
			"assembly_id": assembly_id,
			"state": controller.to_dict(),
		})
	return rows

func register_locomotion_state(
	assembly_id: int,
	state: Dictionary
) -> void:
	if assembly_id <= 0 or state.is_empty():
		return
	var controller := get_locomotion_controller(assembly_id)
	controller.apply_dict(state)

func clear_assembly_locomotion(assembly_id: int) -> void:
	_assembly_locomotion.erase(assembly_id)

func ensure_wheel_instance_state(element_id: int) -> WheelInstanceState:
	if not _wheel_instances.has(element_id):
		var state := WheelInstanceState.new()
		var element := get_element(element_id)
		var definition := (
			element.get_archetype().wheel_definition
			if element != null and element.get_archetype() != null
			else null
		)
		if definition != null:
			state.steerable = definition.steerable_default
		_wheel_instances[element_id] = state
	return _wheel_instances[element_id] as WheelInstanceState

func ensure_suspension_instance_state(
	element_id: int
) -> SuspensionInstanceState:
	if not _suspension_instances.has(element_id):
		_suspension_instances[element_id] = SuspensionInstanceState.new()
	return _suspension_instances[element_id] as SuspensionInstanceState

func list_wheel_instance_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for element_id: int in _sorted_keys(_wheel_instances):
		rows.append({
			"element_id": element_id,
			"state": (
				_wheel_instances[element_id] as WheelInstanceState
			).to_dict(),
		})
	return rows

func list_suspension_instance_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for element_id: int in _sorted_keys(_suspension_instances):
		rows.append({
			"element_id": element_id,
			"state": (
				_suspension_instances[element_id] as SuspensionInstanceState
			).to_dict(),
		})
	return rows

func register_wheel_instance_state(
	element_id: int,
	state: WheelInstanceState
) -> void:
	if element_id > 0 and state != null:
		_wheel_instances[element_id] = state

func register_suspension_instance_state(
	element_id: int,
	state: SuspensionInstanceState
) -> void:
	if element_id > 0 and state != null:
		_suspension_instances[element_id] = state

## Не гейтует по роли ControlSeat — как ensure_wheel_instance_state не гейтует
## по wheel_definition. Гейт живёт на границах (snapshot-валидация, команда).
func ensure_action_bar_state(element_id: int) -> ActionBarState:
	if not _action_bars.has(element_id):
		_action_bars[element_id] = ActionBarState.new()
	return _action_bars[element_id] as ActionBarState

## Для read-only путей (снапшот пульта для UI): просто посмотреть на хост не
## должно создавать постоянную запись в side-table — иначе даже открытие
## окна без единой привязки клавиши раздувает каждый будущий save пустым
## рядом (тот же принцип, что у ensure_wheel_instance_state, но там создание
## уже происходит при размещении колеса, здесь для бара такого триггера нет).
func has_action_bar_state(element_id: int) -> bool:
	return _action_bars.has(element_id)

func register_action_bar_state(element_id: int, state: ActionBarState) -> void:
	if element_id > 0 and state != null:
		_action_bars[element_id] = state

func list_action_bar_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for element_id: int in _sorted_keys(_action_bars):
		rows.append({
			"element_id": element_id,
			"state": (_action_bars[element_id] as ActionBarState).to_dict(),
		})
	return rows

func get_wheel_runtime(wheel_element_id: int) -> Dictionary:
	return _wheel_runtime.get(wheel_element_id, {})

func store_wheel_runtime(
	wheel_element_id: int,
	suspension_element_id: int,
	tick_result: Dictionary
) -> void:
	var runtime := tick_result.duplicate(true)
	runtime["wheel_element_id"] = wheel_element_id
	runtime["suspension_element_id"] = suspension_element_id
	for key: String in [
		"wheel_speed",
		"wheel_speed_rad_s",
		"steering_angle_rad",
		"compression_m",
		"suspension_length_m",
		"normal_force_n",
		"longitudinal_force_n",
		"lateral_force_n",
		"slip_speed_mps",
		"lateral_speed_mps",
		"drive_command",
		"brake_command",
	]:
		var value := float(runtime.get(key, 0.0))
		if not is_finite(value):
			value = 0.0
			runtime["status"] = &"invalid_body"
		runtime[key] = value
	for key: String in [
		"socket_body_local",
		"wheel_center_body_local",
		"contact_world",
		"contact_normal_world",
	]:
		var value: Vector3 = runtime.get(key, Vector3.ZERO)
		if not value.is_finite():
			value = Vector3.ZERO
			runtime["status"] = &"invalid_body"
		runtime[key] = value
	_wheel_runtime[wheel_element_id] = runtime

## Название по историческому первому потребителю; на деле — общая точка
## очистки instance side-table'ов при удалении элемента (см. единственный
## вызов в topology_mutation_service.gd, он зовётся для любого удалённого
## элемента, не только колёсного).
func clear_wheel_element_state(element_id: int) -> void:
	_wheel_instances.erase(element_id)
	_suspension_instances.erase(element_id)
	_wheel_runtime.erase(element_id)
	_action_bars.erase(element_id)

func sync_actuator_observation(
	joint_id: int,
	position_m: float,
	velocity_mps: float,
	applied_force_n: float,
	force_saturated: bool = false
) -> void:
	var joint := get_joint(joint_id)
	if joint == null:
		return
	ActuatorSimulationService.sync_observation(
		joint,
		position_m,
		velocity_mps,
		applied_force_n,
		force_saturated
	)
	ActuatorSimulationService.tick_joint(self, joint, 0.0)

func tick_actuators(delta_s: float) -> void:
	if delta_s <= 0.0:
		return
	for joint: SimulationJoint in list_joints():
		if not joint.is_driven():
			continue
		ActuatorSimulationService.tick_joint(self, joint, delta_s)

func apply_enqueue_recipe(command: EnqueueRecipeCommand) -> Dictionary:
	if _industry_runner == null:
		_industry_runner = IndustrySimulation.new()
		(_industry_runner as IndustrySimulation).bind_world(self)
	return (_industry_runner as IndustrySimulation).apply_enqueue_recipe(command)

func apply_dequeue_recipe(command: DequeueRecipeCommand) -> Dictionary:
	if _industry_runner == null:
		_industry_runner = IndustrySimulation.new()
		(_industry_runner as IndustrySimulation).bind_world(self)
	return (_industry_runner as IndustrySimulation).apply_dequeue_recipe(command)

func get_simulation_time_s() -> float:
	return _simulation_time_s

func list_world_loot_piles() -> Array[Dictionary]:
	return WorldLootServiceScript.list_world_loot_piles(self)

func add_world_loot_pile(
	position: Vector3,
	resource_id: String,
	amount_kg: float,
	despawn_after_s: float = -1.0
) -> WorldLootPile:
	return WorldLootServiceScript.add_world_loot_pile(self, position, resource_id, amount_kg, despawn_after_s)

func _find_mergeable_loot_pile(
	position: Vector3,
	resource_id: String,
	amount_kg: float
) -> WorldLootPile:
	return WorldLootServiceScript.find_mergeable_loot_pile(self, position, resource_id, amount_kg)

func _merge_loot_pile(
	target: WorldLootPile,
	new_position: Vector3,
	add_amount_kg: float
) -> WorldLootPile:
	return WorldLootServiceScript.merge_loot_pile(self, target, new_position, add_amount_kg)

func sync_world_loot_position(pile_id: int, position: Vector3) -> bool:
	return WorldLootServiceScript.sync_world_loot_position(self, pile_id, position)

func try_merge_world_loot_piles(pile_id_a: int, pile_id_b: int) -> bool:
	return WorldLootServiceScript.try_merge_world_loot_piles(self, pile_id_a, pile_id_b)

func merge_nearby_world_loot_piles() -> bool:
	return WorldLootServiceScript.merge_nearby_world_loot_piles(self)

func remove_world_loot_pile(pile_id: int) -> bool:
	return WorldLootServiceScript.remove_world_loot_pile(self, pile_id)

func collect_world_loot_pile(
	pile_id: int,
	to_store_id: String
) -> Dictionary:
	return WorldLootServiceScript.collect_world_loot_pile(self, pile_id, to_store_id)

func get_industry_element_runtime(
	element_id: int
) -> IndustryElementRuntime:
	return _industry_elements.get(element_id) as IndustryElementRuntime

func ensure_industry_element_runtime(
	element_id: int
) -> IndustryElementRuntime:
	var existing := get_industry_element_runtime(element_id)
	if existing != null:
		return existing
	var runtime := IndustryElementRuntime.create_default()
	_industry_elements[element_id] = runtime
	return runtime

func list_industry_element_runtimes() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var element_ids: Array = _industry_elements.keys()
	element_ids.sort()
	for element_id_variant: Variant in element_ids:
		var element_id := int(element_id_variant)
		var runtime: IndustryElementRuntime = _industry_elements[element_id]
		rows.append({
			"element_id": element_id,
			"runtime": runtime.to_dict(),
		})
	return rows

func get_industry_network_revision() -> int:
	return _industry_network.industry_network_revision

func ensure_resource_store(store_id: String) -> SimulationResourceStore:
	if store_id.is_empty():
		return null
	var existing := get_resource_store(store_id)
	if existing != null:
		return existing
	var store := SimulationResourceStore.new()
	store.store_id = store_id
	if PlayerIdentity.is_player_store(store_id):
		store.capacity_l = IndustryArchetypeProfile.player_carry_capacity_l()
	_resource_stores[store_id] = store
	return store

func set_resource_amount(
	store_id: String,
	resource_id: String,
	amount: float
) -> bool:
	if (
		store_id.is_empty()
		or resource_id.is_empty()
		or not is_finite(amount)
		or amount < 0.0
	):
		return false
	var store := get_resource_store(store_id)
	if store != null:
		return store.set_amount(resource_id, amount)
	var pending := SimulationResourceStore.new()
	pending.store_id = store_id
	if not pending.set_amount(resource_id, amount):
		return false
	_resource_stores[store_id] = pending
	return true

func get_redirect_target_raw(assembly_id: int) -> int:
	return int(_redirects.get(assembly_id, 0))

func get_assembly(assembly_id: int) -> SimulationAssembly:
	return get_assembly_raw(resolve_assembly_id(assembly_id))

func get_assembly_raw(assembly_id: int) -> SimulationAssembly:
	return _assemblies.get(assembly_id) as SimulationAssembly

func get_element(element_id: int) -> SimulationElement:
	return _elements.get(element_id) as SimulationElement

func get_joint(joint_id: int) -> SimulationJoint:
	return _joints.get(joint_id) as SimulationJoint

func resolve_assembly_id(assembly_id: int) -> int:
	var current := assembly_id
	var visited: Dictionary = {}
	while _redirects.has(current):
		if visited.has(current):
			return 0
		visited[current] = true
		current = int(_redirects[current])
	return current

func submit_structural_command(command: StructuralCommand) -> int:
	if command == null:
		return 0
	var queued := command.execution_copy()
	if queued == null:
		return 0
	queued.command_id = _allocator.allocate_command_id()
	_command_queue.append(queued)
	if not _flush_scheduled:
		_flush_scheduled = true
		call_deferred("_flush_commands")
	return queued.command_id

func apply_structural_command_now(
	command: StructuralCommand
) -> StructuralCommandResult:
	if command == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	if command.command_id != 0:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_COMMAND_ID
		)
	command.command_id = _allocator.allocate_command_id()
	return _execute_structural_command(command)

func sync_assembly_motion(
	assembly_id: int,
	motion_state: AssemblyMotionState
) -> bool:
	# Root body-group write path. Child groups use sync_assembly_body_group_motion.
	# Projection is the only live-body caller; internal seeding reuses it.
	var assembly := get_assembly_raw(assembly_id)
	if (
		assembly == null
		or assembly.tombstoned
		or motion_state == null
		or not motion_state.is_valid()
	):
		return false
	assembly.motion = motion_state.duplicate_state()
	return true

func compile_body_groups(assembly_id: int) -> Dictionary:
	var assembly := get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return {"valid": false, "reason": &"missing_assembly"}
	var cached: Variant = _body_group_compile_cache.get(assembly_id)
	if (
		cached is Dictionary
		and int(cached.get("revision", -1)) == assembly.topology_revision
	):
		return cached["result"]
	var result: Dictionary = BodyGroupMotionUtilScript.compile_for_assembly(
		self,
		assembly_id
	)
	_body_group_compile_cache[assembly_id] = {
		"revision": assembly.topology_revision,
		"result": result,
	}
	return result


func root_body_group_id(assembly_id: int) -> int:
	var compiled := compile_body_groups(assembly_id)
	if not bool(compiled.get("valid", false)):
		return 0
	return int(compiled.get("root_group_id", 0))

func body_group_id_for_element(element_id: int) -> int:
	var element := get_element(element_id)
	if element == null:
		return 0
	var compiled := compile_body_groups(element.assembly_id)
	if not bool(compiled.get("valid", false)):
		return 0
	return int(compiled.get("element_to_group", {}).get(element_id, 0))

func get_body_group_motion(
	assembly_id: int,
	group_id: int
) -> AssemblyMotionState:
	var assembly := get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return AssemblyMotionState.new()
	var root_id := root_body_group_id(assembly_id)
	if group_id <= 0 or group_id == root_id:
		return (
			assembly.motion.duplicate_state()
			if assembly.motion != null
			else AssemblyMotionState.new()
		)
	var stored: Variant = assembly.body_group_motions.get(group_id)
	if stored is AssemblyMotionState:
		return (stored as AssemblyMotionState).duplicate_state()
	return BodyGroupMotionUtilScript.reconstruct_group_motion(
		self,
		assembly_id,
		group_id
	)

## Read-only group transform for hot paths (wires / snap / preview).
## One compile lookup, no AssemblyMotionState.duplicate_state().
## Do not frame-cache: reconstruct-on-read (actuators) can change within a frame.
func element_group_transform(element_id: int) -> Transform3D:
	var element := get_element(element_id)
	if element == null:
		return Transform3D.IDENTITY
	var assembly := get_assembly_raw(element.assembly_id)
	if assembly == null or assembly.tombstoned or assembly.motion == null:
		return Transform3D.IDENTITY
	var compiled := compile_body_groups(element.assembly_id)
	if not bool(compiled.get("valid", false)):
		return assembly.motion.transform
	var group_id := int(
		compiled.get("element_to_group", {}).get(element_id, 0)
	)
	var root_id := int(compiled.get("root_group_id", 0))
	if group_id <= 0 or group_id == root_id:
		return assembly.motion.transform
	var stored: Variant = assembly.body_group_motions.get(group_id)
	if stored is AssemblyMotionState:
		return (stored as AssemblyMotionState).transform
	return BodyGroupMotionUtilScript.reconstruct_group_motion(
		self,
		element.assembly_id,
		group_id
	).transform

func assembly_is_single_body_group(assembly_id: int) -> bool:
	var compiled := compile_body_groups(assembly_id)
	if not bool(compiled.get("valid", false)):
		return false
	return (compiled.get("groups", {}) as Dictionary).size() <= 1

func sync_assembly_body_group_motion(
	assembly_id: int,
	group_id: int,
	motion_state: AssemblyMotionState
) -> bool:
	var assembly := get_assembly_raw(assembly_id)
	if (
		assembly == null
		or assembly.tombstoned
		or motion_state == null
		or not motion_state.is_valid()
		or group_id <= 0
	):
		return false
	var root_id := root_body_group_id(assembly_id)
	if group_id == root_id or root_id <= 0:
		return sync_assembly_motion(assembly_id, motion_state)
	assembly.body_group_motions[group_id] = motion_state.duplicate_state()
	return true

func sync_assembly_body_group_motions(
	assembly_id: int,
	motions_by_group: Dictionary
) -> bool:
	var assembly := get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return false
	var root_id := root_body_group_id(assembly_id)
	var ok := true
	var group_ids: Array = motions_by_group.keys()
	group_ids.sort()
	for group_id_variant: Variant in group_ids:
		var group_id := int(group_id_variant)
		var motion: Variant = motions_by_group.get(group_id_variant)
		if not motion is AssemblyMotionState:
			ok = false
			continue
		var motion_state := motion as AssemblyMotionState
		if not motion_state.is_valid() or group_id <= 0:
			ok = false
			continue
		if group_id == root_id or root_id <= 0:
			if not sync_assembly_motion(assembly_id, motion_state):
				ok = false
			continue
		assembly.body_group_motions[group_id] = motion_state.duplicate_state()
	return ok

func element_world_transform(element_id: int) -> Transform3D:
	var element := get_element(element_id)
	if element == null:
		return Transform3D.IDENTITY
	return (
		element_group_transform(element_id)
		* GridPoseUtil.element_local_transform(
			element.origin_cell,
			element.orientation_index,
			element.pose_offset
		)
	)

func element_group_motion(element_id: int) -> AssemblyMotionState:
	var element := get_element(element_id)
	if element == null:
		return AssemblyMotionState.new()
	var compiled := compile_body_groups(element.assembly_id)
	if not bool(compiled.get("valid", false)):
		return AssemblyMotionState.new()
	var group_id := int(
		compiled.get("element_to_group", {}).get(element_id, 0)
	)
	var assembly := get_assembly_raw(element.assembly_id)
	if assembly == null or assembly.tombstoned:
		return AssemblyMotionState.new()
	var root_id := int(compiled.get("root_group_id", 0))
	if group_id <= 0 or group_id == root_id:
		return (
			assembly.motion.duplicate_state()
			if assembly.motion != null
			else AssemblyMotionState.new()
		)
	var stored: Variant = assembly.body_group_motions.get(group_id)
	if stored is AssemblyMotionState:
		return (stored as AssemblyMotionState).duplicate_state()
	return BodyGroupMotionUtilScript.reconstruct_group_motion(
		self,
		element.assembly_id,
		group_id
	)

func capture_snapshot() -> Dictionary:
	return SimulationSnapshot.capture(self)

func restore_snapshot(snapshot: Dictionary, emit_event := true) -> bool:
	var restored = SimulationSnapshot.create_from_snapshot(snapshot)
	if restored == null:
		return false
	_allocator = restored._allocator
	_archetypes = restored._archetypes
	_assemblies = restored._assemblies
	_elements = restored._elements
	_joints = restored._joints
	_redirects = restored._redirects
	_resource_stores = restored._resource_stores
	_suits = restored._suits
	_player_inventory = restored._player_inventory
	_player_inventory_revision = restored._player_inventory_revision
	_industry_network = restored._industry_network
	_industry_elements = restored._industry_elements
	_wheel_instances = restored._wheel_instances
	_suspension_instances = restored._suspension_instances
	_action_bars = restored._action_bars
	_wheel_runtime.clear()
	_assembly_locomotion = restored._assembly_locomotion
	_world_loot_piles = restored._world_loot_piles
	_simulation_time_s = restored._simulation_time_s
	_command_queue.clear()
	_flush_scheduled = false
	_body_group_compile_cache.clear()
	_archetype_validation_cache.clear()
	_occupancy_index_cache.clear()
	restored.free()
	if emit_event:
		emit_world_restored()
	return true

func emit_world_restored() -> void:
	_emit_structural_event({"kind": &"world_restored"})

func _flush_commands() -> void:
	_flush_scheduled = false
	while not _command_queue.is_empty():
		var command: StructuralCommand = _command_queue.pop_front()
		var result := _execute_structural_command(command)
		structural_command_completed.emit(command.command_id, result)

func _execute_structural_command(
	command: StructuralCommand
) -> StructuralCommandResult:
	if command is SpawnBlueprintCommand:
		return _spawn_blueprint(command as SpawnBlueprintCommand)
	if command is BreakRigidJointCommand:
		return _break_rigid_joint(command as BreakRigidJointCommand)
	if command is MergeAssembliesCommand:
		return _merge_assemblies(command as MergeAssembliesCommand)
	if command is PlaceElementCommand:
		return _place_element(command as PlaceElementCommand)
	if command is WeldElementCommand:
		return _weld_element(command as WeldElementCommand)
	if command is DamageElementCommand:
		return _damage_element(command as DamageElementCommand)
	if command is RepairElementCommand:
		return _repair_element(command as RepairElementCommand)
	if command is DismantleElementCommand:
		return _dismantle_element(command as DismantleElementCommand)
	if command is ConnectNetworkCommand:
		return _connect_network(command as ConnectNetworkCommand)
	if command is DisconnectNetworkCommand:
		return _disconnect_network(command as DisconnectNetworkCommand)
	return StructuralCommandResult.failed(
		StructuralCommandResult.REASON_INVALID_TARGET
	)

func _spawn_blueprint(
	command: SpawnBlueprintCommand
) -> StructuralCommandResult:
	var blueprint := command.blueprint
	if blueprint == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_BLUEPRINT
		)
	var validation := BlueprintValidator.validate(blueprint)
	if not validation.ok:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_BLUEPRINT,
			{"errors": validation.errors}
		)
	if command.grid_frame == null or not command.grid_frame.is_valid():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TRANSFORM
		)
	if not _can_register_blueprint_archetypes(blueprint):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)
	# Blueprint validation has already checked occupancy and placement identity.
	# No topology ID is consumed before all rejection paths above complete.
	for placement: BlueprintElementPlacement in blueprint.placements:
		_archetypes.register(placement.archetype)

	var assembly_id := _allocator.allocate_assembly_id()
	var assembly := SimulationAssembly.new()
	assembly.assembly_id = assembly_id
	assembly.grid_frame = command.grid_frame.duplicate_transform()
	assembly.motion = AssemblyMotionState.from_grid_frame(assembly.grid_frame)
	var local_to_element: Dictionary = {}
	var spawned: Array[SimulationElement] = []
	for placement: BlueprintElementPlacement in blueprint.placements:
		var element_id := _allocator.allocate_element_id()
		var element := SimulationElement.from_placement(
			element_id,
			assembly_id,
			placement
		)
		spawned.append(element)
		assembly.element_ids.append(element_id)
		local_to_element[placement.local_id] = element_id
	assembly.element_ids.sort()

	var allocate_joint := func() -> int:
		return _allocator.allocate_joint_id()
	var new_joints := RuntimeConnectivity.materialize_rigid_joints(
		assembly_id,
		spawned,
		allocate_joint
	)
	new_joints.append_array(
		RuntimeConnectivity.materialize_anchor_joints(
			assembly_id,
			spawned,
			allocate_joint
		)
	)
	for element: SimulationElement in spawned:
		_elements[element.element_id] = element
	for joint: SimulationJoint in new_joints:
		_joints[joint.joint_id] = joint
	_assemblies[assembly_id] = assembly
	assembly.bump_revision()
	_notify_topology_changed()
	var joint_ids := _joint_ids_for_assembly(assembly_id)
	_emit_structural_event({
		"kind": &"assembly_spawned",
		"command_id": command.command_id,
		"assembly_id": assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_ids": assembly.element_ids.duplicate(),
		"joint_ids": joint_ids,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": assembly_id,
		"topology_revision": assembly.topology_revision,
		"local_to_element_id": local_to_element,
		"element_ids": assembly.element_ids.duplicate(),
		"joint_ids": joint_ids,
	})

func preview_place_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	return ConstructionCommandServiceScript.preview_place_element(self, command)

func _place_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	return ConstructionCommandServiceScript.place_element(self, command)

func _validate_place_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	return ConstructionCommandServiceScript.validate_place_element(self, command)
func _weld_element(
	command: WeldElementCommand
) -> StructuralCommandResult:
	return ConstructionCommandServiceScript.weld_element(self, command)

func _damage_element(
	command: DamageElementCommand
) -> StructuralCommandResult:
	return ConstructionCommandServiceScript.damage_element(self, command)

func _repair_element(
	command: RepairElementCommand
) -> StructuralCommandResult:
	return ConstructionCommandServiceScript.repair_element(self, command)

func _dismantle_element(
	command: DismantleElementCommand
) -> StructuralCommandResult:
	return ConstructionCommandServiceScript.dismantle_element(self, command)

func _remove_element_from_topology(
	element: SimulationElement,
	command_id: int,
	refund_fraction: float,
	store: SimulationResourceStore
) -> StructuralCommandResult:
	return TopologyMutationServiceScript.remove_element_from_topology(self, element, command_id, refund_fraction, store)

func _break_rigid_joint(
	command: BreakRigidJointCommand
) -> StructuralCommandResult:
	return TopologyMutationServiceScript.break_rigid_joint(self, command)

func _merge_assemblies(
	command: MergeAssembliesCommand
) -> StructuralCommandResult:
	return TopologyMutationServiceScript.merge_assemblies(self, command)

func _can_register_blueprint_archetypes(blueprint: Blueprint) -> bool:
	var pending: Dictionary = {}
	for placement: BlueprintElementPlacement in blueprint.placements:
		var archetype := placement.archetype
		if archetype == null or archetype.resource_path.is_empty():
			return false
		var fingerprint := ArchetypeRegistry.fingerprint_of(archetype)
		if pending.has(archetype.archetype_id):
			if pending[archetype.archetype_id] != fingerprint:
				return false
		elif _archetypes.has(archetype.archetype_id):
			if (
				ArchetypeRegistry.fingerprint_of(
					_archetypes.get_archetype(archetype.archetype_id)
				)
				!= fingerprint
			):
				return false
		else:
			pending[archetype.archetype_id] = fingerprint
	return true

func _archetype_has_anchor_port(archetype: ElementArchetype) -> bool:
	if archetype == null:
		return false
	for port: PortDefinition in archetype.ports:
		if (
			port != null
			and port.kind == PortDefinition.Kind.MECHANICAL
			and port.compatibility_tags.has("anchor")
		):
			return true
	return false

func _validate_state_command(
	element: SimulationElement,
	expected_state_revision: int
) -> StructuralCommandResult:
	if element == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if element.state_revision != expected_state_revision:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"expected": expected_state_revision,
				"actual": element.state_revision,
			}
		)
	return null

func _emit_element_state_changed(
	element: SimulationElement,
	command_id: int,
	change_kind: StringName,
	operational_changed: bool = false
) -> void:
	_emit_structural_event({
		"kind": &"element_state_changed",
		"change_kind": change_kind,
		"command_id": command_id,
		"assembly_id": element.assembly_id,
		"element_id": element.element_id,
		"state_revision": element.state_revision,
		"build_progress": element.build_progress,
		"integrity": element.integrity,
		"status_reason": element.status_reason(),
		"operational_changed": operational_changed,
	})
	# Cargo adjacency tracks operational membership only. Partial weld/repair
	# ticks do not change it; the final tick that brings the element online does.
	# Inside a batch (bulk weld_all) coalesce to one rebuild at batch close.
	if operational_changed:
		if _structural_batch_depth > 0:
			_deferred_derived_recompute = true
		else:
			_cargo_graph.rebuild(self)

func _element_state_result(
	element: SimulationElement,
	extra: Dictionary = {}
) -> StructuralCommandResult:
	var data := {
		"assembly_id": element.assembly_id,
		"element_id": element.element_id,
		"state_revision": element.state_revision,
		"build_progress": element.build_progress,
		"integrity": element.integrity,
		"status_reason": element.status_reason(),
	}
	data.merge(extra, true)
	return StructuralCommandResult.ok(data)

func _preview_for_id(
	previews: Array[SimulationElement],
	element_id: int
) -> SimulationElement:
	for preview: SimulationElement in previews:
		if preview.element_id == element_id:
			return preview
	return null

func _register_assembly(assembly: SimulationAssembly) -> void:
	_assemblies[assembly.assembly_id] = assembly

func _register_element(element: SimulationElement) -> void:
	_elements[element.element_id] = element

func _register_joint(joint: SimulationJoint) -> void:
	_joints[joint.joint_id] = joint

func _register_redirect(from_id: int, to_id: int) -> void:
	_redirects[from_id] = to_id

func _register_resource_store(store: SimulationResourceStore) -> void:
	_resource_stores[store.store_id] = store

func _register_player_inventory(registry: PlayerInventoryRegistry) -> void:
	_player_inventory = registry

func _register_suit_state(player_id: String, suit: SimulationSuitState) -> void:
	_suits[player_id] = suit

func _joints_for_assembly(assembly_id: int) -> Array[SimulationJoint]:
	var result: Array[SimulationJoint] = []
	for joint: SimulationJoint in list_joints():
		if joint.assembly_id == assembly_id:
			result.append(joint)
	return result

func _joint_ids_for_assembly(assembly_id: int) -> Array[int]:
	var ids: Array[int] = []
	for joint: SimulationJoint in _joints_for_assembly(assembly_id):
		ids.append(joint.joint_id)
	ids.sort()
	return ids

func _elements_for_ids(ids: Array[int]) -> Array[SimulationElement]:
	var result: Array[SimulationElement] = []
	for element_id: int in ids:
		result.append(_elements[element_id])
	return result

func _cells_by_element_id(
	elements: Array[SimulationElement]
) -> Dictionary:
	return ConstructionOccupancyUtilScript.cells_by_element_id(elements)

func _occupancy_is_unique(
	base: Array[SimulationElement],
	extra: Dictionary
) -> bool:
	return ConstructionOccupancyUtilScript.occupancy_is_unique(self, base, extra)

func _cell_key(cell: Vector3i) -> String:
	return ConstructionOccupancyUtilScript.cell_key(cell)

func _assembly_occupancy_index(assembly: SimulationAssembly) -> Dictionary:
	return ConstructionOccupancyUtilScript.assembly_occupancy_index(self, assembly)

func _neighbour_element_ids(
	preview_cells: Array[Vector3i],
	occupancy: Dictionary
) -> Array[int]:
	return ConstructionOccupancyUtilScript.neighbour_element_ids(
		preview_cells,
		occupancy
	)

func _joint_belongs_to_component(
	joint: SimulationJoint,
	component: Array
) -> bool:
	return ConstructionOccupancyUtilScript.joint_belongs_to_component(joint, component)

func assembly_has_anchor(assembly_id: int) -> bool:
	return _assembly_has_anchor(assembly_id)

func construction_attach_allowed(assembly_id: int) -> bool:
	return _construction_attach_allowed(assembly_id)

func _should_reconcile_assembly(assembly_id: int) -> bool:
	return ConstructionCommandServiceScript.should_reconcile_assembly(self, assembly_id)

func _reconcile_terrain_anchors_for_assemblies(
	assembly_ids: Array[int]
) -> void:
	return ConstructionCommandServiceScript.reconcile_terrain_anchors_for_assemblies(self, assembly_ids)

func _notify_topology_changed() -> void:
	topology_generation += 1
	# Cheap per-op cache invalidation must stay eager: mid-batch validation
	# (occupancy, body groups) reads these and must see the current topology.
	_body_group_compile_cache.clear()
	_occupancy_index_cache.clear()
	# Origin-keyed surface lookups must not grow unbounded across places.
	GridSurfaceUtil.clear_descriptor_cache()
	_mark_derived_dirty()


## Full-world derived recompute. Every step is a from-scratch rebuild, so
## running it once after a batch of topology edits yields the same result as
## running it after each edit — only far cheaper.
func _recompute_derived_now() -> void:
	_deferred_derived_recompute = false
	_industry_network.prune_dangling_links(self)
	_purge_industry_runtime_for_missing_elements()
	IndustryStoreService.sync_all_elements(self)
	_cargo_graph.rebuild(self)


## Run the heavy derived recompute now, or defer it to batch close. Consumers
## that need fresh derived state mid-batch use the lazy paths
## (ensure_cargo_graph_current), which rebuild on demand off topology_revision.
func _mark_derived_dirty() -> void:
	if _structural_batch_depth > 0:
		_deferred_derived_recompute = true
		return
	_recompute_derived_now()

func _cargo_graph_needs_rebuild() -> bool:
	for assembly: SimulationAssembly in list_assemblies():
		if assembly.tombstoned:
			continue
		if _cargo_graph.needs_rebuild_for_assembly(
			assembly.assembly_id,
			assembly.topology_revision
		):
			return true
	return false

func _purge_industry_runtime_for_missing_elements() -> void:
	var stale: Array[int] = []
	for element_id_variant: Variant in _industry_elements.keys():
		var element_id := int(element_id_variant)
		if not _elements.has(element_id):
			stale.append(element_id)
	for element_id: int in stale:
		_industry_elements.erase(element_id)

func _connect_network(
	command: ConnectNetworkCommand
) -> StructuralCommandResult:
	return IndustryNetworkCommandsScript.connect_network(self, command)

func _disconnect_network(
	command: DisconnectNetworkCommand
) -> StructuralCommandResult:
	return IndustryNetworkCommandsScript.disconnect_network(self, command)

func _find_electric_link_by_endpoints(
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String
) -> IndustryElectricLink:
	return IndustryNetworkCommandsScript.find_electric_link_by_endpoints(self, element_a_id, port_a_id, element_b_id, port_b_id)

func _register_industry_network(state: IndustryNetworkState) -> void:
	if state == null:
		_industry_network = IndustryNetworkState.create_default()
		return
	_industry_network = state

func _register_industry_element_runtime(
	element_id: int,
	runtime: IndustryElementRuntime
) -> void:
	if element_id <= 0 or runtime == null:
		return
	_industry_elements[element_id] = runtime

func _register_world_loot_pile(pile: WorldLootPile) -> void:
	if pile == null or pile.pile_id <= 0:
		return
	_world_loot_piles[pile.pile_id] = pile

func _register_simulation_time(time_s: float) -> void:
	_simulation_time_s = maxf(time_s, 0.0)

func _purge_expired_loot_piles() -> void:
	return WorldLootServiceScript.purge_expired_loot_piles(self)

func _record_placement_terrain_contact(
	assembly: SimulationAssembly,
	element: SimulationElement,
	joint_ids: Array[int]
) -> void:
	return ConstructionCommandServiceScript.record_placement_terrain_contact(self, assembly, element, joint_ids)

func _probe_touching_ids(
	assembly: SimulationAssembly,
	elements: Array[SimulationElement]
) -> Array[int]:
	return ConstructionCommandServiceScript.probe_touching_ids(self, assembly, elements)

func _element_anchor_joint_id(assembly_id: int, element_id: int) -> int:
	return ConstructionCommandServiceScript.element_anchor_joint_id(self, assembly_id, element_id)

func _assembly_has_anchor(assembly_id: int) -> bool:
	return ConstructionCommandServiceScript.assembly_has_anchor(self, assembly_id)

## Terrain-anchored builds always attach. Floating locomotives may expand only
## while nearly stopped (parking brake or coast-to-stop).
func _construction_attach_allowed(assembly_id: int) -> bool:
	return ConstructionCommandServiceScript.construction_attach_allowed(self, assembly_id)

func _sorted_keys(dictionary: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key: Variant in dictionary.keys():
		result.append(int(key))
	result.sort()
	return result

func begin_structural_batch() -> void:
	_structural_batch_depth += 1


func end_structural_batch() -> void:
	_structural_batch_depth = maxi(_structural_batch_depth - 1, 0)
	if _structural_batch_depth == 0 and _deferred_derived_recompute:
		_recompute_derived_now()


func _emit_structural_event(event: Dictionary) -> void:
	if _structural_batch_depth > 0:
		var kind := StringName(event.get("kind", &""))
		if kind != &"world_restored":
			return
	structural_event.emit(event)
