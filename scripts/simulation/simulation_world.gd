class_name SimulationWorld
extends Node

const BodyGroupMotionUtilScript := preload(
	"res://scripts/simulation/runtime/body_group_motion_util.gd"
)

signal structural_event(event: Dictionary)
signal structural_command_completed(
	command_id: int,
	result: StructuralCommandResult
)
signal player_inventory_changed()

var _allocator := SimulationIdAllocator.new()
var _archetypes := ArchetypeRegistry.new()
var _assemblies: Dictionary = {}
var _elements: Dictionary = {}
var _joints: Dictionary = {}
var _redirects: Dictionary = {}
var _resource_stores: Dictionary = {}
var _player_inventory: PlayerInventoryRegistry
var _player_inventory_revision := 0
var _industry_network := IndustryNetworkState.create_default()
var _industry_elements: Dictionary = {}
var _wheel_instances: Dictionary = {}
var _suspension_instances: Dictionary = {}
var _wheel_runtime: Dictionary = {}
var _assembly_locomotion: Dictionary = {}
var _cargo_graph := CargoGraph.new()
var _industry_runner: Node
var _world_loot_piles: Dictionary = {}
var _simulation_time_s: float = 0.0
var _command_queue: Array[StructuralCommand] = []
var _flush_scheduled := false
var _occupancy_index_cache: Dictionary = {}
var _archetype_validation_cache: Dictionary = {}
var _terrain_contact_probe: Callable


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
	waypoints: PackedVector3Array = PackedVector3Array()
) -> StructuralCommandResult:
	var command := ConnectNetworkCommand.new()
	command.element_a_id = element_a_id
	command.port_a_id = port_a_id
	command.element_b_id = element_b_id
	command.port_b_id = port_b_id
	command.expected_assembly_revision = expected_assembly_revision
	command.waypoints = waypoints
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
			or WheelSimulationService.is_locomotive_assembly(self, assembly_id)
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


func clear_wheel_element_state(element_id: int) -> void:
	_wheel_instances.erase(element_id)
	_suspension_instances.erase(element_id)
	_wheel_runtime.erase(element_id)


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
	var rows: Array[Dictionary] = []
	var pile_ids: Array = _world_loot_piles.keys()
	pile_ids.sort()
	for pile_id_variant: Variant in pile_ids:
		var pile: WorldLootPile = _world_loot_piles[int(pile_id_variant)]
		if pile != null:
			rows.append(pile.to_dict())
	return rows


func add_world_loot_pile(
	position: Vector3,
	resource_id: String,
	amount_kg: float,
	despawn_after_s: float = -1.0
) -> WorldLootPile:
	if resource_id.is_empty() or amount_kg <= 0.000001:
		return null
	var existing := _find_mergeable_loot_pile(
		position,
		resource_id,
		amount_kg
	)
	if existing != null:
		var max_mass := IndustryArchetypeProfile.hand_drill_loot_pile_max_mass_kg()
		if existing.amount_kg + amount_kg <= max_mass + 0.000001:
			return _merge_loot_pile(existing, position, amount_kg)
	var despawn_at := _simulation_time_s + (
		despawn_after_s
		if despawn_after_s > 0.0
		else IndustryArchetypeProfile.hand_drill_loot_despawn_s()
	)
	var pile := WorldLootPile.create(
		_allocator.allocate_loot_pile_id(),
		position,
		resource_id,
		amount_kg,
		despawn_at
	)
	_world_loot_piles[pile.pile_id] = pile
	return pile


func _find_mergeable_loot_pile(
	position: Vector3,
	resource_id: String,
	amount_kg: float
) -> WorldLootPile:
	var best: WorldLootPile = null
	var best_dist_sq := INF
	for pile_variant: Variant in _world_loot_piles.values():
		var pile := pile_variant as WorldLootPile
		if pile == null or pile.resource_id != resource_id:
			continue
		if not IndustryArchetypeProfile.hand_drill_loot_spheres_overlap(
			position,
			amount_kg,
			pile.position,
			pile.amount_kg
		):
			continue
		var dist_sq := position.distance_squared_to(pile.position)
		if best == null or dist_sq < best_dist_sq:
			best = pile
			best_dist_sq = dist_sq
	return best


func _merge_loot_pile(
	target: WorldLootPile,
	new_position: Vector3,
	add_amount_kg: float
) -> WorldLootPile:
	var total := target.amount_kg + add_amount_kg
	if total <= 0.000001:
		return target
	var blend := add_amount_kg / total
	target.position = target.position.lerp(new_position, blend)
	target.amount_kg = total
	return target


func sync_world_loot_position(pile_id: int, position: Vector3) -> bool:
	var pile := _world_loot_piles.get(pile_id) as WorldLootPile
	if pile == null:
		return false
	pile.position = position
	return true


func try_merge_world_loot_piles(pile_id_a: int, pile_id_b: int) -> bool:
	if pile_id_a == pile_id_b:
		return false
	var survivor_id := mini(pile_id_a, pile_id_b)
	var victim_id := maxi(pile_id_a, pile_id_b)
	var survivor: WorldLootPile = _world_loot_piles.get(survivor_id)
	var victim: WorldLootPile = _world_loot_piles.get(victim_id)
	if survivor == null or victim == null:
		return false
	if survivor.resource_id != victim.resource_id:
		return false
	if not IndustryArchetypeProfile.hand_drill_loot_spheres_overlap(
		survivor.position,
		survivor.amount_kg,
		victim.position,
		victim.amount_kg
	):
		return false
	var max_mass := IndustryArchetypeProfile.hand_drill_loot_pile_max_mass_kg()
	if survivor.amount_kg + victim.amount_kg > max_mass + 0.000001:
		return false
	_merge_loot_pile(survivor, victim.position, victim.amount_kg)
	_world_loot_piles.erase(victim_id)
	return true


func merge_nearby_world_loot_piles() -> bool:
	var pile_ids: Array = _world_loot_piles.keys()
	pile_ids.sort()
	var changed := false
	for i: int in range(pile_ids.size()):
		var survivor_id := int(pile_ids[i])
		if not _world_loot_piles.has(survivor_id):
			continue
		for j: int in range(i + 1, pile_ids.size()):
			var victim_id := int(pile_ids[j])
			if try_merge_world_loot_piles(survivor_id, victim_id):
				changed = true
	return changed


func remove_world_loot_pile(pile_id: int) -> bool:
	if not _world_loot_piles.has(pile_id):
		return false
	_world_loot_piles.erase(pile_id)
	return true


func collect_world_loot_pile(
	pile_id: int,
	to_store_id: String = IndustryStoreService.PLAYER_STORE_ID
) -> Dictionary:
	var pile := _world_loot_piles.get(pile_id) as WorldLootPile
	var store := get_resource_store(to_store_id)
	if pile == null or store == null:
		return {"status": &"failed", "reason": &"invalid_reference", "amount": 0.0}
	var unit_mass := ResourceCatalog.mass_per_unit_kg(pile.resource_id)
	if unit_mass <= 0.000001 or pile.amount_kg <= 0.000001:
		return {"status": &"failed", "reason": &"no_input", "amount": 0.0}
	var capacity := IndustryStoreService.capacity_l_for_store(self, to_store_id)
	var available_units := pile.amount_kg / unit_mass
	var amount := minf(
		available_units,
		ResourceCatalog.max_addable_amount(
			store,
			pile.resource_id,
			capacity
		)
	)
	if amount <= 0.000001:
		return {
			"status": &"failed",
			"reason": &"storage_full",
			"amount": 0.0,
			"resource_id": pile.resource_id,
		}
	if not store.add(pile.resource_id, amount, capacity):
		return {"status": &"failed", "reason": &"storage_full", "amount": 0.0}
	pile.amount_kg = maxf(pile.amount_kg - amount * unit_mass, 0.0)
	if pile.amount_kg <= 0.000001:
		_world_loot_piles.erase(pile_id)
	return {
		"status": &"ok",
		"reason": &"ok",
		"amount": amount,
		"resource_id": pile.resource_id,
	}


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
	if store_id == IndustryStoreService.PLAYER_STORE_ID:
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
	return BodyGroupMotionUtilScript.compile_for_assembly(self, assembly_id)


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
	var group_id := body_group_id_for_element(element_id)
	var group_motion := get_body_group_motion(element.assembly_id, group_id)
	return (
		group_motion.transform
		* GridPoseUtil.element_local_transform(
			element.origin_cell,
			element.orientation_index
		)
	)


func element_group_motion(element_id: int) -> AssemblyMotionState:
	var element := get_element(element_id)
	if element == null:
		return AssemblyMotionState.new()
	return get_body_group_motion(
		element.assembly_id,
		body_group_id_for_element(element_id)
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
	_player_inventory = restored._player_inventory
	_player_inventory_revision = restored._player_inventory_revision
	_industry_network = restored._industry_network
	_industry_elements = restored._industry_elements
	_wheel_instances = restored._wheel_instances
	_suspension_instances = restored._suspension_instances
	_wheel_runtime.clear()
	_assembly_locomotion = restored._assembly_locomotion
	_world_loot_piles = restored._world_loot_piles
	_simulation_time_s = restored._simulation_time_s
	_command_queue.clear()
	_flush_scheduled = false
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
	if command == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	return _validate_place_element(command)


func _place_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	if (
		PistonPlacementUtil.is_piston_archetype(command.archetype)
		or RotorPlacementUtil.is_rotor_archetype(command.archetype)
	):
		return _place_driven_element(command)
	var validation := _validate_place_element(command)
	if not validation.is_ok():
		return validation
	var store := get_resource_store(command.store_id)
	var resource_id := str(validation.data["placement_resource_id"])
	var resource_amount := float(validation.data["placement_resource_amount"])
	if not store.remove(resource_id, resource_amount):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL
		)
	if not _archetypes.register(command.archetype):
		store.add(resource_id, resource_amount)
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)

	var assembly: SimulationAssembly
	var new_assembly := command.assembly_id == 0
	if new_assembly:
		assembly = SimulationAssembly.new()
		assembly.assembly_id = _allocator.allocate_assembly_id()
		assembly.grid_frame = command.new_assembly_grid_frame.duplicate_transform()
		assembly.motion = (
			command.initial_motion.duplicate_state()
			if command.initial_motion != null
			else AssemblyMotionState.from_grid_frame(assembly.grid_frame)
		)
	else:
		assembly = get_assembly_raw(command.assembly_id)

	var element_id := _allocator.allocate_element_id()
	var element := SimulationElement.frame(
		element_id,
		assembly.assembly_id,
		command.archetype,
		command.origin_cell,
		command.orientation_index,
		{resource_id: resource_amount}
	)
	var joint_ids: Array[int] = []
	if new_assembly:
		# A first block placed on terrain rests on the surface by construction
		# (continuous bottom-face contact), so it always starts anchored.
		var allocate_joint := func() -> int:
			return _allocator.allocate_joint_id()
		for joint: SimulationJoint in (
			RuntimeConnectivity.materialize_ground_start_anchors(
				assembly.assembly_id,
				[element],
				allocate_joint
			)
		):
			_joints[joint.joint_id] = joint
			joint_ids.append(joint.joint_id)
		element.terrain_contact = true
		_assemblies[assembly.assembly_id] = assembly
	else:
		for connection_variant: Variant in validation.data["connections"]:
			var connection: Dictionary = connection_variant
			var joint_id := _allocator.allocate_joint_id()
			var joint := SimulationJoint.rigid(
				joint_id,
				assembly.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				element_id,
				str(connection["new_port_id"])
			)
			_joints[joint_id] = joint
			joint_ids.append(joint_id)

	_elements[element_id] = element
	assembly.element_ids.append(element_id)
	assembly.element_ids.sort()
	# Every block placed onto the terrain must anchor immediately, otherwise the
	# whole construction hangs off the single first-block anchor and detaching it
	# frees (and physically ejects) everything else. Non-first blocks are probed
	# live at placement; the fact is stored on the block and re-verified on split.
	if not new_assembly:
		_record_placement_terrain_contact(assembly, element, joint_ids)
	assembly.bump_revision()
	_notify_topology_changed()
	joint_ids.sort()
	var event_kind := &"assembly_spawned" if new_assembly else &"assembly_changed"
	_emit_structural_event({
		"kind": event_kind,
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_ids": assembly.element_ids.duplicate(),
		"placed_element_id": element_id,
		"joint_ids": joint_ids,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_id": element_id,
		"state_revision": element.state_revision,
		"build_progress": element.build_progress,
		"joint_ids": joint_ids,
		"resource_id": resource_id,
		"resource_remaining": store.amount(resource_id),
	})


func _validate_place_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	if (
		PistonPlacementUtil.is_piston_archetype(command.archetype)
		or RotorPlacementUtil.is_rotor_archetype(command.archetype)
	):
		return _validate_driven_place_element(command)
	if WheelPlacementUtil.is_wheel_archetype(command.archetype):
		return _validate_wheel_place_element(command)
	var archetype := command.archetype
	if (
		archetype == null
		or archetype.archetype_id.is_empty()
		or archetype.resource_path.is_empty()
		or archetype.internal_archetype
		or command.orientation_index < 0
		or command.orientation_index >= OrientationUtil.ORIENTATION_COUNT
		or archetype.build_requirements.is_empty()
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var archetype_validation := _validate_construction_archetype(
		archetype,
		command.orientation_index
	)
	if not archetype_validation.is_ok():
		return archetype_validation
	if _archetypes.has(archetype.archetype_id) and (
		ArchetypeRegistry.fingerprint_of(
			_archetypes.get_archetype(archetype.archetype_id)
		)
		!= ArchetypeRegistry.fingerprint_of(archetype)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)
	var first_requirement: BuildRequirement = archetype.build_requirements[0]
	if (
		first_requirement == null
		or first_requirement.resource_id.is_empty()
		or not is_finite(first_requirement.amount)
		or first_requirement.amount <= 0.0
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var placement_amount := minf(first_requirement.amount, 1.0)
	var store := get_resource_store(command.store_id)
	if (
		store == null
		or not store.can_remove(first_requirement.resource_id, placement_amount)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
			{
				"resource_id": first_requirement.resource_id,
				"required": placement_amount,
				"available": (
					store.amount(first_requirement.resource_id)
					if store != null else 0.0
				),
			}
		)

	var preview := SimulationElement.frame(
		-1,
		command.assembly_id,
		archetype,
		command.origin_cell,
		command.orientation_index,
		{first_requirement.resource_id: placement_amount}
	)
	var connections: Array[Dictionary] = []
	if command.assembly_id == 0:
		if (
			command.new_assembly_grid_frame == null
			or not command.new_assembly_grid_frame.is_valid()
			or (
				command.initial_motion != null
				and not command.initial_motion.is_valid()
			)
		):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_TRANSFORM
			)
		if RuntimeConnectivity.ground_anchor_port_id(preview).is_empty():
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_ANCHOR_REQUIRED
			)
	else:
		var assembly := get_assembly_raw(command.assembly_id)
		if assembly == null or assembly.tombstoned:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_REFERENCE
			)
		if not _construction_attach_allowed(assembly.assembly_id):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_TARGET,
				{"detail": &"mobile_construction_not_supported"}
			)
		if assembly.topology_revision != command.expected_assembly_revision:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_STALE_REVISION,
				{
					"expected": command.expected_assembly_revision,
					"actual": assembly.topology_revision,
				}
			)
		if _archetype_has_anchor_port(archetype):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_ANCHOR_NOT_ALLOWED
			)
		var occupancy := _assembly_occupancy_index(assembly)
		var preview_cells := preview.occupied_cells()
		for cell: Vector3i in preview_cells:
			if occupancy.has(cell):
				return StructuralCommandResult.failed(
					StructuralCommandResult.REASON_OVERLAP
				)
		# A rigid edge requires adjacent derived structural surface faces, so only
		# elements occupying a neighbour of the preview footprint can ever connect.
		var neighbour_ids := _neighbour_element_ids(preview_cells, occupancy)
		for existing_id: int in neighbour_ids:
			var existing := get_element(existing_id)
			var connection := RuntimeConnectivity.find_rigid_connection(
				existing,
				preview
			)
			if connection.is_empty():
				continue
			connections.append({
				"existing_element_id": existing_id,
				"existing_port_id": connection["left_port_id"],
				"new_port_id": connection["right_port_id"],
			})
		if connections.is_empty():
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
			)
		var bridge_error := _validate_new_rigid_connections(
			assembly.assembly_id,
			preview,
			connections
		)
		if bridge_error != null:
			return bridge_error
		var moving_error := _validate_driven_head_construction_target(
			connections
		)
		if moving_error != null:
			return moving_error

	return StructuralCommandResult.ok({
		"placement_resource_id": first_requirement.resource_id,
		"placement_resource_amount": placement_amount,
		"connections": connections,
		"build_progress": preview.build_progress,
	})


func _validate_wheel_place_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	var archetype := command.archetype
	if (
		archetype == null
		or archetype.wheel_definition == null
		or archetype.internal_archetype
		or command.orientation_index < 0
		or command.orientation_index >= OrientationUtil.ORIENTATION_COUNT
		or archetype.build_requirements.is_empty()
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var archetype_validation := _validate_construction_archetype(
		archetype,
		command.orientation_index
	)
	if not archetype_validation.is_ok():
		return archetype_validation
	var first_requirement: BuildRequirement = archetype.build_requirements[0]
	if (
		first_requirement == null
		or first_requirement.resource_id.is_empty()
		or not is_finite(first_requirement.amount)
		or first_requirement.amount <= 0.0
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var placement_amount := minf(first_requirement.amount, 1.0)
	var store := get_resource_store(command.store_id)
	if (
		store == null
		or not store.can_remove(first_requirement.resource_id, placement_amount)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
			{
				"resource_id": first_requirement.resource_id,
				"required": placement_amount,
				"available": (
					store.amount(first_requirement.resource_id)
					if store != null else 0.0
				),
			}
		)
	var preview := SimulationElement.frame(
		-1,
		command.assembly_id,
		archetype,
		command.origin_cell,
		command.orientation_index,
		{first_requirement.resource_id: placement_amount}
	)
	var wheel_error: Variant = WheelPlacementUtil.validate_wheel_placement(
		self,
		command,
		preview
	)
	if (
		wheel_error is StructuralCommandResult
		and not (wheel_error as StructuralCommandResult).is_ok()
	):
		return wheel_error
	if command.assembly_id == 0:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION,
			{"detail": &"wheel_socket_required"}
		)
	var assembly := get_assembly_raw(command.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if not _construction_attach_allowed(assembly.assembly_id):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"detail": &"mobile_construction_not_supported"}
		)
	if assembly.topology_revision != command.expected_assembly_revision:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"expected": command.expected_assembly_revision,
				"actual": assembly.topology_revision,
			}
		)
	var occupancy := _assembly_occupancy_index(assembly)
	var preview_cells := preview.occupied_cells()
	for cell: Vector3i in preview_cells:
		if occupancy.has(cell):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_OVERLAP
			)
	var connections: Array[Dictionary] = []
	var neighbour_ids := _neighbour_element_ids(preview_cells, occupancy)
	for existing_id: int in neighbour_ids:
		var existing := get_element(existing_id)
		var connection := RuntimeConnectivity.find_rigid_connection(
			existing,
			preview
		)
		if connection.is_empty():
			continue
		if (
			existing.archetype_id == "wheel_suspension"
			and WheelPlacementUtil.wheel_attached_to_suspension(
				self,
				assembly.assembly_id,
				existing_id
			)
		):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION,
				{"detail": &"socket_occupied"}
			)
		connections.append({
			"existing_element_id": existing_id,
			"existing_port_id": connection["left_port_id"],
			"new_port_id": connection["right_port_id"],
		})
	if connections.is_empty():
		var empty_error: Variant = WheelPlacementUtil.validate_wheel_placement(
			self,
			command,
			preview
		)
		if empty_error is StructuralCommandResult:
			return empty_error
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION,
			{"detail": &"wheel_socket_required"}
		)
	var bridge_error := _validate_new_rigid_connections(
		assembly.assembly_id,
		preview,
		connections
	)
	if bridge_error != null:
		return bridge_error
	var moving_error := _validate_driven_head_construction_target(connections)
	if moving_error != null:
		return moving_error
	return StructuralCommandResult.ok({
		"placement_resource_id": first_requirement.resource_id,
		"placement_resource_amount": placement_amount,
		"connections": connections,
		"build_progress": preview.build_progress,
	})


func _validate_driven_place_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	var base_archetype := command.archetype
	var is_rotor := RotorPlacementUtil.is_rotor_archetype(base_archetype)
	if (
		base_archetype == null
		or (
			base_archetype.piston_definition == null
			and base_archetype.rotor_definition == null
		)
		or base_archetype.internal_archetype
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var head_archetype_id := (
		base_archetype.rotor_definition.top_archetype_id
		if is_rotor
		else base_archetype.piston_definition.head_archetype_id
	)
	var head_archetype := _archetypes.get_archetype(head_archetype_id)
	var definition_errors := (
		RotorPlacementUtil.validate_rotor_archetype(
			base_archetype,
			head_archetype,
			_archetypes
		)
		if is_rotor
		else PistonPlacementUtil.validate_piston_archetype(
			base_archetype,
			head_archetype,
			_archetypes
		)
	)
	for error_text: String in definition_errors:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"detail": error_text}
		)
	var archetype_validation := _validate_construction_archetype(
		base_archetype,
		command.orientation_index
	)
	if not archetype_validation.is_ok():
		return archetype_validation
	if head_archetype == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"detail": &"missing_head_archetype"}
		)
	if not _archetypes.register(head_archetype):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)
	var first_requirement: BuildRequirement = base_archetype.build_requirements[0]
	if first_requirement == null or first_requirement.resource_id.is_empty():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var placement_amount := minf(first_requirement.amount, 1.0)
	var store := get_resource_store(command.store_id)
	if store == null or not store.can_remove(
		first_requirement.resource_id,
		placement_amount
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL
		)
	var previews := (
		RotorPlacementUtil.preview_elements(
			command,
			head_archetype,
			first_requirement.resource_id,
			placement_amount
		)
		if is_rotor
		else PistonPlacementUtil.preview_elements(
			command,
			head_archetype,
			first_requirement.resource_id,
			placement_amount
		)
	)
	var base_preview: SimulationElement = previews["base"]
	var head_preview: SimulationElement = previews["head"]
	if RuntimeConnectivity.elements_have_rigid_connection(
		base_preview,
		head_preview
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{
				"detail": (
					&"rotor_home_rigid_conflict"
					if is_rotor
					else &"piston_home_rigid_conflict"
				),
			}
		)

	var base_connections: Array[Dictionary] = []
	var head_connections: Array[Dictionary] = []
	if command.assembly_id == 0:
		if (
			command.new_assembly_grid_frame == null
			or not command.new_assembly_grid_frame.is_valid()
		):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_TRANSFORM
			)
		if RuntimeConnectivity.ground_anchor_port_id(base_preview).is_empty():
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_ANCHOR_REQUIRED
			)
	else:
		var assembly := get_assembly_raw(command.assembly_id)
		if assembly == null or assembly.tombstoned:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_REFERENCE
			)
		if not _construction_attach_allowed(assembly.assembly_id):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INVALID_TARGET,
				{"detail": &"mobile_construction_not_supported"}
			)
		if assembly.topology_revision != command.expected_assembly_revision:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_STALE_REVISION
			)
		var occupancy := _assembly_occupancy_index(assembly)
		for preview: SimulationElement in [base_preview, head_preview]:
			for cell: Vector3i in preview.occupied_cells():
				if occupancy.has(cell):
					return StructuralCommandResult.failed(
						StructuralCommandResult.REASON_OVERLAP
					)
		base_connections = PistonPlacementUtil.collect_rigid_connections(
			self,
			assembly.assembly_id,
			base_preview,
			[-2]
		)
		head_connections = PistonPlacementUtil.collect_rigid_connections(
			self,
			assembly.assembly_id,
			head_preview,
			[-1]
		)
		if base_connections.is_empty():
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
			)
		for connections: Array in [base_connections, head_connections]:
			var bridge_error := _validate_new_rigid_connections(
				assembly.assembly_id,
				base_preview,
				connections
			)
			if bridge_error != null:
				return bridge_error
		var moving_error := _validate_driven_head_construction_target(
			head_connections
		)
		if moving_error != null:
			return moving_error

	return StructuralCommandResult.ok({
		"placement_resource_id": first_requirement.resource_id,
		"placement_resource_amount": placement_amount,
		"base_connections": base_connections,
		"head_connections": head_connections,
		"head_archetype": head_archetype,
		"build_progress": base_preview.build_progress,
	})


func _place_driven_element(
	command: PlaceElementCommand
) -> StructuralCommandResult:
	var is_rotor := RotorPlacementUtil.is_rotor_archetype(command.archetype)
	var validation := _validate_driven_place_element(command)
	if not validation.is_ok():
		return validation
	var store := get_resource_store(command.store_id)
	var resource_id := str(validation.data["placement_resource_id"])
	var resource_amount := float(validation.data["placement_resource_amount"])
	if not store.remove(resource_id, resource_amount):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL
		)
	if not _archetypes.register(command.archetype):
		store.add(resource_id, resource_amount)
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)
	var head_archetype: ElementArchetype = validation.data["head_archetype"]
	if not _archetypes.register(head_archetype):
		store.add(resource_id, resource_amount)
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)

	var assembly: SimulationAssembly
	var new_assembly := command.assembly_id == 0
	if new_assembly:
		assembly = SimulationAssembly.new()
		assembly.assembly_id = _allocator.allocate_assembly_id()
		assembly.grid_frame = command.new_assembly_grid_frame.duplicate_transform()
		assembly.motion = (
			command.initial_motion.duplicate_state()
			if command.initial_motion != null
			else AssemblyMotionState.from_grid_frame(assembly.grid_frame)
		)
	else:
		assembly = get_assembly_raw(command.assembly_id)

	var base_element_id := _allocator.allocate_element_id()
	var head_element_id := _allocator.allocate_element_id()
	var base_element := SimulationElement.frame(
		base_element_id,
		assembly.assembly_id,
		command.archetype,
		command.origin_cell,
		command.orientation_index,
		{resource_id: resource_amount}
	)
	var head_origin := (
		RotorPlacementUtil.top_origin_cell(
			command.origin_cell,
			command.orientation_index,
			command.archetype.rotor_definition
		)
		if is_rotor
		else PistonPlacementUtil.head_origin_cell(
			command.origin_cell,
			command.orientation_index,
			command.archetype.piston_definition
		)
	)
	var head_element := SimulationElement.frame(
		head_element_id,
		assembly.assembly_id,
		head_archetype,
		head_origin,
		command.orientation_index,
		{}
	)
	head_element.apply_placement_integrity()
	head_element.condition = base_element.condition

	var joint_ids: Array[int] = []
	var driven_joint_id := _allocator.allocate_joint_id()
	var driven_joint := (
		SimulationJoint.rotor(
			driven_joint_id,
			assembly.assembly_id,
			base_element_id,
			head_element_id,
			command.archetype.rotor_definition
		)
		if is_rotor
		else SimulationJoint.piston(
			driven_joint_id,
			assembly.assembly_id,
			base_element_id,
			head_element_id,
			command.archetype.piston_definition
		)
	)
	_joints[driven_joint_id] = driven_joint
	joint_ids.append(driven_joint_id)

	if new_assembly:
		var allocate_joint := func() -> int:
			return _allocator.allocate_joint_id()
		for joint: SimulationJoint in (
			RuntimeConnectivity.materialize_ground_start_anchors(
				assembly.assembly_id,
				[base_element],
				allocate_joint
			)
		):
			_joints[joint.joint_id] = joint
			joint_ids.append(joint.joint_id)
		base_element.terrain_contact = true
		_assemblies[assembly.assembly_id] = assembly
	else:
		for connection_variant: Variant in validation.data["base_connections"]:
			var connection: Dictionary = connection_variant
			var joint_id := _allocator.allocate_joint_id()
			_joints[joint_id] = SimulationJoint.rigid(
				joint_id,
				assembly.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				base_element_id,
				str(connection["new_port_id"])
			)
			joint_ids.append(joint_id)
		for connection_variant: Variant in validation.data["head_connections"]:
			var connection: Dictionary = connection_variant
			var joint_id := _allocator.allocate_joint_id()
			_joints[joint_id] = SimulationJoint.rigid(
				joint_id,
				assembly.assembly_id,
				int(connection["existing_element_id"]),
				str(connection["existing_port_id"]),
				head_element_id,
				str(connection["new_port_id"])
			)
			joint_ids.append(joint_id)

	_elements[base_element_id] = base_element
	_elements[head_element_id] = head_element
	assembly.element_ids.append(base_element_id)
	assembly.element_ids.append(head_element_id)
	assembly.element_ids.sort()
	if not new_assembly:
		_record_placement_terrain_contact(assembly, base_element, joint_ids)
	assembly.bump_revision()
	_notify_topology_changed()
	joint_ids.sort()
	var event_kind := &"assembly_spawned" if new_assembly else &"assembly_changed"
	var joint_id_key := "rotor_joint_id" if is_rotor else "piston_joint_id"
	_emit_structural_event({
		"kind": event_kind,
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_ids": assembly.element_ids.duplicate(),
		"placed_element_id": base_element_id,
		"placed_head_element_id": head_element_id,
		joint_id_key: driven_joint_id,
		"driven_joint_id": driven_joint_id,
		"joint_ids": joint_ids,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_id": base_element_id,
		"head_element_id": head_element_id,
		joint_id_key: driven_joint_id,
		"driven_joint_id": driven_joint_id,
		"state_revision": base_element.state_revision,
		"build_progress": base_element.build_progress,
		"joint_ids": joint_ids,
		"resource_id": resource_id,
		"resource_remaining": store.amount(resource_id),
	})


func _validate_new_rigid_connections(
	assembly_id: int,
	_preview: SimulationElement,
	connections: Array[Dictionary]
) -> StructuralCommandResult:
	if connections.is_empty():
		return null
	var assembly := get_assembly_raw(assembly_id)
	if assembly == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var compiled := BodyGroupCompiler.compile(
		assembly.element_ids,
		_elements,
		_joints_for_assembly(assembly_id)
	)
	if not bool(compiled.get("valid", false)):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"detail": compiled.get("reason", &"invalid_body_groups")}
		)
	var touched_groups: Dictionary = {}
	for connection_variant: Variant in connections:
		var connection: Dictionary = connection_variant
		var existing_id := int(connection["existing_element_id"])
		var group_id := int(
			(compiled["element_to_group"] as Dictionary).get(existing_id, 0)
		)
		if group_id <= 0:
			continue
		touched_groups[group_id] = true
	if touched_groups.size() <= 1:
		return null
	for spec_variant: Variant in compiled["driven_specs"]:
		var spec: Dictionary = spec_variant
		var left := int(spec["base_group_id"])
		var right := int(spec["head_group_id"])
		if touched_groups.has(left) and touched_groups.has(right):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_DRIVEN_JOINT_CYCLE
			)
	return null


func _validate_driven_head_construction_target(
	head_connections: Array[Dictionary]
) -> StructuralCommandResult:
	if head_connections.is_empty():
		return null
	for connection_variant: Variant in head_connections:
		var connection: Dictionary = connection_variant
		var existing := get_element(int(connection["existing_element_id"]))
		if existing == null:
			continue
		for joint: SimulationJoint in _joints_for_assembly(existing.assembly_id):
			if not joint.is_driven():
				continue
			if (
				joint.element_b_id != existing.element_id
				and joint.element_a_id != existing.element_id
			):
				continue
			if joint.motor == null:
				continue
			var at_home := true
			if joint.kind == SimulationJoint.Kind.ROTOR:
				at_home = (
					absf(SimulationMotorState.wrap_angle(
						joint.motor.observed_position_m
					))
					<= SimulationMotorState.OVERLOAD_ERROR_M
				)
			else:
				at_home = is_equal_approx(
					joint.motor.observed_position_m,
					joint.motor.lower_limit_m
				)
			if not at_home:
				return StructuralCommandResult.failed(
					StructuralCommandResult.REASON_MOVING_TARGET_NOT_SUPPORTED
				)
			if (
				absf(joint.motor.observed_velocity_mps)
				> SimulationMotorState.OVERLOAD_VELOCITY_MPS
			):
				return StructuralCommandResult.failed(
					StructuralCommandResult.REASON_MOVING_TARGET_NOT_SUPPORTED
				)
	return null


func _validate_construction_archetype(
	archetype: ElementArchetype,
	orientation_index: int
) -> StructuralCommandResult:
	if (
		orientation_index < 0
		or orientation_index >= OrientationUtil.ORIENTATION_COUNT
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	# Archetype self-validation depends only on the archetype definition, not on
	# where or how it is placed, so cache it by identity + fingerprint instead of
	# rebuilding a throwaway Blueprint on every preview/plan call.
	var cache_key := archetype.get_instance_id()
	var fingerprint := ArchetypeRegistry.fingerprint_of(archetype)
	var cached: Dictionary = _archetype_validation_cache.get(cache_key, {})
	if str(cached.get("fingerprint", "")) != fingerprint:
		var validation := BlueprintValidator.validate_archetype(archetype)
		cached = {
			"fingerprint": fingerprint,
			"ok": validation.ok,
			"errors": validation.errors.duplicate(),
			"footprint_empty": archetype.footprint_cells.is_empty(),
		}
		_archetype_validation_cache[cache_key] = cached
	if not bool(cached.get("ok", false)) or bool(cached.get("footprint_empty", true)):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"errors": cached.get("errors", [])}
		)
	return StructuralCommandResult.ok()


func _weld_element(
	command: WeldElementCommand
) -> StructuralCommandResult:
	var element := get_element(command.element_id)
	var state_error := _validate_state_command(
		element,
		command.expected_state_revision
	)
	if state_error != null:
		return state_error
	if not is_finite(command.max_material_amount) or command.max_material_amount <= 0.0:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	if element.is_complete():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ALREADY_COMPLETE
		)
	var was_operational := element.is_operational()
	var store := get_resource_store(command.store_id)
	if store == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL
		)
	var transfers: Array[Dictionary] = []
	var remaining := command.max_material_amount
	var archetype := element.get_archetype()
	for requirement: BuildRequirement in archetype.build_requirements:
		if remaining <= 0.000001:
			break
		var missing := maxf(
			requirement.amount
			- element.installed_material_amount(requirement.resource_id),
			0.0
		)
		var amount := minf(missing, remaining)
		if amount <= 0.000001:
			continue
		transfers.append({
			"resource_id": requirement.resource_id,
			"amount": amount,
		})
		remaining -= amount
	if transfers.is_empty():
		var deficit := maxf(archetype.max_integrity - element.integrity, 0.0)
		if deficit <= 0.000001:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_ALREADY_COMPLETE
			)
		var integrity_per_component := (
			archetype.max_integrity
			* SimulationElement.WELD_REPAIR_INTEGRITY_FRACTION
		)
		var material_amount := minf(
			command.max_material_amount,
			deficit / integrity_per_component
		)
		if ResourceCatalog.is_discrete("construction_component"):
			material_amount = ceilf(material_amount - 0.000001)
		if material_amount <= 0.000001:
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
				{
					"resource_id": "construction_component",
					"required": material_amount,
					"available": store.amount("construction_component"),
				}
			)
		if not store.can_remove("construction_component", material_amount):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
				{
					"resource_id": "construction_component",
					"required": material_amount,
					"available": store.amount("construction_component"),
				}
			)
		store.remove("construction_component", material_amount)
		element.integrity = minf(
			element.integrity + material_amount * integrity_per_component,
			archetype.max_integrity
		)
		element.sync_build_progress_from_integrity()
		element.bump_state_revision()
		_emit_element_state_changed(
			element,
			command.command_id,
			&"weld",
			was_operational != element.is_operational()
		)
		return _element_state_result(element, {
			"transfers": [{
				"resource_id": "construction_component",
				"amount": material_amount,
			}],
			"store_id": command.store_id,
		})
	var totals: Dictionary = {}
	for transfer: Dictionary in transfers:
		var resource_id := str(transfer["resource_id"])
		totals[resource_id] = (
			float(totals.get(resource_id, 0.0))
			+ float(transfer["amount"])
		)
	for resource_id: Variant in totals.keys():
		var amount := float(totals[resource_id])
		if ResourceCatalog.is_discrete(str(resource_id)):
			amount = floorf(amount + 0.000001)
		if amount <= 0.000001:
			continue
		if not store.can_remove(str(resource_id), amount):
			return StructuralCommandResult.failed(
				StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
				{
					"resource_id": str(resource_id),
					"required": totals[resource_id],
					"available": store.amount(str(resource_id)),
				}
			)
	for resource_id: Variant in totals.keys():
		var amount := float(totals[resource_id])
		if ResourceCatalog.is_discrete(str(resource_id)):
			amount = floorf(amount + 0.000001)
		if amount <= 0.000001:
			continue
		store.remove(str(resource_id), amount)
	for transfer: Dictionary in transfers:
		element.install_material(
			str(transfer["resource_id"]),
			float(transfer["amount"])
		)
	element.bump_state_revision()
	_emit_element_state_changed(
		element,
		command.command_id,
		&"weld",
		was_operational != element.is_operational()
	)
	return _element_state_result(element, {
		"transfers": transfers,
		"store_id": command.store_id,
	})


func _damage_element(
	command: DamageElementCommand
) -> StructuralCommandResult:
	var element := get_element(command.element_id)
	var state_error := _validate_state_command(
		element,
		command.expected_state_revision
	)
	if state_error != null:
		return state_error
	if not is_finite(command.damage) or command.damage <= 0.0:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	if element.is_broken():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_NO_EFFECT
		)
	element.integrity = maxf(element.integrity - command.damage, 0.0)
	element.sync_build_progress_from_integrity()
	if element.integrity <= 0.000001:
		var refund_store: SimulationResourceStore = null
		if command.refund_fraction_on_destroy > 0.000001:
			refund_store = get_resource_store(command.store_id)
		return _remove_element_from_topology(
			element,
			command.command_id,
			command.refund_fraction_on_destroy,
			refund_store
		)
	element.bump_state_revision()
	_emit_element_state_changed(element, command.command_id, &"damage")
	return _element_state_result(element)


func _repair_element(
	command: RepairElementCommand
) -> StructuralCommandResult:
	var element := get_element(command.element_id)
	var state_error := _validate_state_command(
		element,
		command.expected_state_revision
	)
	if state_error != null:
		return state_error
	if (
		not is_finite(command.max_material_amount)
		or command.max_material_amount <= 0.0
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var archetype := element.get_archetype()
	var deficit := maxf(archetype.max_integrity - element.integrity, 0.0)
	if deficit <= 0.000001:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_NOT_DAMAGED
		)
	var was_operational := element.is_operational()
	var integrity_per_component := archetype.max_integrity * 0.25
	var material_amount := minf(
		command.max_material_amount,
		deficit / integrity_per_component
	)
	if ResourceCatalog.is_discrete("construction_component"):
		material_amount = ceilf(material_amount - 0.000001)
	if material_amount <= 0.000001:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
			{
				"resource_id": "construction_component",
				"required": material_amount,
				"available": 0.0,
			}
		)
	var store := get_resource_store(command.store_id)
	if (
		store == null
		or not store.can_remove("construction_component", material_amount)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INSUFFICIENT_MATERIAL,
			{
				"resource_id": "construction_component",
				"required": material_amount,
				"available": (
					store.amount("construction_component")
					if store != null else 0.0
				),
			}
		)
	store.remove("construction_component", material_amount)
	element.integrity = minf(
		element.integrity + material_amount * integrity_per_component,
		archetype.max_integrity
	)
	element.bump_state_revision()
	_emit_element_state_changed(
		element,
		command.command_id,
		&"repair",
		was_operational != element.is_operational()
	)
	return _element_state_result(element, {
		"resource_id": "construction_component",
		"material_used": material_amount,
		"resource_remaining": store.amount("construction_component"),
	})


func _dismantle_element(
	command: DismantleElementCommand
) -> StructuralCommandResult:
	var element := get_element(command.element_id)
	if element == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var assembly := get_assembly_raw(element.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if assembly.topology_revision != command.expected_assembly_revision:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION
		)
	var store := get_resource_store(command.store_id)
	if store == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	return _remove_element_from_topology(
		element,
		command.command_id,
		0.5,
		store
	)


func _remove_element_from_topology(
	element: SimulationElement,
	command_id: int,
	refund_fraction: float,
	store: SimulationResourceStore
) -> StructuralCommandResult:
	var assembly := get_assembly_raw(element.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)

	var removed_joint_ids: Array[int] = []
	var remaining_joints: Array[SimulationJoint] = []
	for joint: SimulationJoint in _joints_for_assembly(assembly.assembly_id):
		if joint.involves_element(element.element_id):
			removed_joint_ids.append(joint.joint_id)
		else:
			remaining_joints.append(joint)
	var remaining_elements: Array[int] = assembly.element_ids.duplicate()
	remaining_elements.erase(element.element_id)
	var components: Array[Array] = []
	var survivor_index := 0
	if not remaining_elements.is_empty():
		components = RuntimeConnectivity.mechanical_connected_components(
			remaining_elements,
			_elements,
			remaining_joints
		)
		if components.size() > 1:
			var scores: Array[Dictionary] = []
			for component: Array in components:
				scores.append(SurvivorPolicy.component_score(
					component,
					_elements,
					remaining_joints
				))
			survivor_index = SurvivorPolicy.pick_survivor_index(scores)

	var refunds: Dictionary = {}
	if refund_fraction > 0.000001 and store != null:
		for resource_id: Variant in element.installed_materials.keys():
			var amount := float(element.installed_materials[resource_id]) * refund_fraction
			if amount > 0.000001:
				refunds[str(resource_id)] = amount

	for joint_id: int in removed_joint_ids:
		_joints.erase(joint_id)
	_elements.erase(element.element_id)
	clear_wheel_element_state(element.element_id)
	_notify_topology_changed()
	for resource_id: Variant in refunds.keys():
		store.add(str(resource_id), float(refunds[resource_id]))
	removed_joint_ids.sort()

	if remaining_elements.is_empty():
		_assemblies.erase(assembly.assembly_id)
		clear_assembly_locomotion(assembly.assembly_id)
		_emit_structural_event({
			"kind": &"assembly_removed",
			"command_id": command_id,
			"assembly_id": assembly.assembly_id,
			"removed_element_id": element.element_id,
		})
		return StructuralCommandResult.ok({
			"assembly_removed": true,
			"assembly_id": assembly.assembly_id,
			"removed_element_id": element.element_id,
			"removed_joint_ids": removed_joint_ids,
			"refunds": refunds,
		})

	if components.size() <= 1:
		assembly.element_ids.assign(remaining_elements)
		assembly.element_ids.sort()
		_reconcile_terrain_anchors_for_assemblies([assembly.assembly_id])
		assembly.bump_revision()
		_notify_topology_changed()
		_emit_structural_event({
			"kind": &"assembly_changed",
			"command_id": command_id,
			"assembly_id": assembly.assembly_id,
			"topology_revision": assembly.topology_revision,
			"removed_element_id": element.element_id,
			"removed_joint_ids": removed_joint_ids,
		})
		return StructuralCommandResult.ok({
			"assembly_removed": false,
			"split": false,
			"assembly_id": assembly.assembly_id,
			"topology_revision": assembly.topology_revision,
			"removed_element_id": element.element_id,
			"removed_joint_ids": removed_joint_ids,
			"refunds": refunds,
		})

	var survivor_component: Array = components[survivor_index]
	var mappings: Array[Dictionary] = []
	var new_ids: Array[int] = []
	for index: int in range(components.size()):
		if index == survivor_index:
			continue
		var component: Array = components[index]
		var new_id := _allocator.allocate_assembly_id()
		var split_assembly := SimulationAssembly.new()
		split_assembly.assembly_id = new_id
		split_assembly.grid_frame = assembly.grid_frame.duplicate_transform()
		split_assembly.motion = assembly.motion.duplicate_state()
		split_assembly.element_ids.assign(component)
		split_assembly.bump_revision()
		_assemblies[new_id] = split_assembly
		new_ids.append(new_id)
		for element_id: int in component:
			(get_element(element_id) as SimulationElement).assembly_id = new_id
		for candidate: SimulationJoint in remaining_joints:
			if _joint_belongs_to_component(candidate, component):
				candidate.assembly_id = new_id
		mappings.append({
			"assembly_id": new_id,
			"element_ids": component.duplicate(),
			"topology_revision": split_assembly.topology_revision,
		})
	assembly.element_ids.assign(survivor_component)
	var affected_assembly_ids: Array[int] = [assembly.assembly_id]
	affected_assembly_ids.append_array(new_ids)
	_reconcile_terrain_anchors_for_assemblies(affected_assembly_ids)
	assembly.bump_revision()
	_notify_topology_changed()
	_emit_structural_event({
		"kind": &"assembly_split",
		"command_id": command_id,
		"removed_element_id": element.element_id,
		"survivor_assembly_id": assembly.assembly_id,
		"survivor_topology_revision": assembly.topology_revision,
		"new_assemblies": mappings,
	})
	return StructuralCommandResult.ok({
		"assembly_removed": false,
		"split": true,
		"removed_element_id": element.element_id,
		"survivor_assembly_id": assembly.assembly_id,
		"survivor_topology_revision": assembly.topology_revision,
		"new_assembly_ids": new_ids,
		"removed_joint_ids": removed_joint_ids,
		"refunds": refunds,
	})


func _break_rigid_joint(
	command: BreakRigidJointCommand
) -> StructuralCommandResult:
	var joint := get_joint(command.joint_id)
	if joint == null or joint.kind != SimulationJoint.Kind.RIGID:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var assembly := get_assembly_raw(joint.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if assembly.topology_revision != command.expected_assembly_revision:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"expected": command.expected_assembly_revision,
				"actual": assembly.topology_revision,
			}
		)

	var remaining_joints := _joints_for_assembly(assembly.assembly_id)
	remaining_joints.erase(joint)
	var components := RuntimeConnectivity.mechanical_connected_components(
		assembly.element_ids.duplicate(),
		_elements,
		remaining_joints
	)
	var survivor_index := 0
	if components.size() > 1:
		var scores: Array[Dictionary] = []
		for component: Array in components:
			scores.append(SurvivorPolicy.component_score(
				component,
				_elements,
				remaining_joints
			))
		survivor_index = SurvivorPolicy.pick_survivor_index(scores)

	# Apply only after all validation and component planning succeeds.
	_joints.erase(command.joint_id)
	if components.size() <= 1:
		_reconcile_terrain_anchors_for_assemblies([assembly.assembly_id])
		assembly.bump_revision()
		_notify_topology_changed()
		_emit_structural_event({
			"kind": &"rigid_joint_broken",
			"command_id": command.command_id,
			"joint_id": command.joint_id,
			"assembly_id": assembly.assembly_id,
			"topology_revision": assembly.topology_revision,
			"split": false,
		})
		return StructuralCommandResult.ok({
			"joint_id": command.joint_id,
			"assembly_id": assembly.assembly_id,
			"topology_revision": assembly.topology_revision,
			"split": false,
		})

	var survivor_component: Array = components[survivor_index]
	var mappings: Array[Dictionary] = []
	var new_ids: Array[int] = []
	for index: int in range(components.size()):
		if index == survivor_index:
			continue
		var component: Array = components[index]
		var new_id := _allocator.allocate_assembly_id()
		var split_assembly := SimulationAssembly.new()
		split_assembly.assembly_id = new_id
		split_assembly.grid_frame = assembly.grid_frame.duplicate_transform()
		split_assembly.motion = assembly.motion.duplicate_state()
		split_assembly.element_ids.assign(component)
		split_assembly.bump_revision()
		_assemblies[new_id] = split_assembly
		new_ids.append(new_id)
		for element_id: int in component:
			(_elements[element_id] as SimulationElement).assembly_id = new_id
		for candidate: SimulationJoint in remaining_joints:
			if _joint_belongs_to_component(candidate, component):
				candidate.assembly_id = new_id
		mappings.append({
			"assembly_id": new_id,
			"element_ids": component.duplicate(),
			"topology_revision": split_assembly.topology_revision,
		})
	assembly.element_ids.assign(survivor_component)
	var split_assembly_ids: Array[int] = [assembly.assembly_id]
	split_assembly_ids.append_array(new_ids)
	_reconcile_terrain_anchors_for_assemblies(split_assembly_ids)
	assembly.bump_revision()
	_notify_topology_changed()
	_emit_structural_event({
		"kind": &"assembly_split",
		"command_id": command.command_id,
		"broken_joint_id": command.joint_id,
		"survivor_assembly_id": assembly.assembly_id,
		"survivor_topology_revision": assembly.topology_revision,
		"new_assemblies": mappings,
	})
	return StructuralCommandResult.ok({
		"joint_id": command.joint_id,
		"split": true,
		"survivor_assembly_id": assembly.assembly_id,
		"survivor_topology_revision": assembly.topology_revision,
		"new_assembly_ids": new_ids,
		"split_mappings": mappings,
	})


func _merge_assemblies(
	command: MergeAssembliesCommand
) -> StructuralCommandResult:
	var assembly_a := get_assembly_raw(command.assembly_a_id)
	var assembly_b := get_assembly_raw(command.assembly_b_id)
	if (
		assembly_a == null
		or assembly_b == null
		or assembly_a.tombstoned
		or assembly_b.tombstoned
		or assembly_a == assembly_b
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if (
		assembly_a.topology_revision != command.expected_revision_a
		or assembly_b.topology_revision != command.expected_revision_b
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION
		)
	if not assembly_a.grid_frame.is_valid() or not assembly_b.grid_frame.is_valid():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TRANSFORM
		)
	if command.b_to_a_grid == null or not command.b_to_a_grid.is_valid():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TRANSFORM
		)
	if (
		assembly_a.motion == null
		or assembly_b.motion == null
		or not assembly_a.motion.is_valid()
		or not assembly_b.motion.is_valid()
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TRANSFORM
		)
	var alignment: Dictionary = GridAlignment.validate_supplied(
		assembly_a.motion.transform,
		assembly_b.motion.transform,
		command.b_to_a_grid
	)
	if not bool(alignment["valid"]):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_MISALIGNED_CONNECTION,
			{
				"position_error_m": alignment["position_error_m"],
				"angle_error_rad": alignment["angle_error_rad"],
				"matches_supplied": alignment["matches_supplied"],
			}
		)
	var element_a := get_element(command.element_a_id)
	var element_b := get_element(command.element_b_id)
	if element_a == null or element_b == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if (
		element_a.assembly_id != assembly_a.assembly_id
		or element_b.assembly_id != assembly_b.assembly_id
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)

	var score_a := SurvivorPolicy.assembly_score(
		assembly_a.assembly_id,
		assembly_a.element_ids,
		_elements,
		_joints_for_assembly(assembly_a.assembly_id)
	)
	var score_b := SurvivorPolicy.assembly_score(
		assembly_b.assembly_id,
		assembly_b.element_ids,
		_elements,
		_joints_for_assembly(assembly_b.assembly_id)
	)
	var survivor_id := SurvivorPolicy.pick_survivor_assembly([score_a, score_b])
	var survivor: SimulationAssembly
	var loser: SimulationAssembly
	var b_to_a: GridTransform = command.b_to_a_grid.duplicate_transform()
	var loser_to_survivor: GridTransform
	if survivor_id == assembly_a.assembly_id:
		survivor = assembly_a
		loser = assembly_b
		loser_to_survivor = b_to_a
	else:
		survivor = assembly_b
		loser = assembly_a
		loser_to_survivor = b_to_a.inverse()

	var planned_poses: Dictionary = {}
	var preview_elements: Array[SimulationElement] = []
	for element_id: int in loser.element_ids:
		var element := get_element(element_id)
		var pose := loser_to_survivor.map_element_pose(
			element.origin_cell,
			element.orientation_index
		)
		planned_poses[element_id] = pose
		var preview := SimulationElement.new()
		preview.element_id = element.element_id
		preview.assembly_id = survivor.assembly_id
		preview.archetype_id = element.archetype_id
		preview.bind_archetype(element.get_archetype())
		preview.origin_cell = pose["origin_cell"]
		preview.orientation_index = int(pose["orientation_index"])
		preview_elements.append(preview)
	if not _occupancy_is_unique(
		_elements_for_ids(survivor.element_ids),
		_cells_by_element_id(preview_elements)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_OVERLAP
		)

	var connection_a := element_a
	var connection_b := element_b
	if loser == assembly_a:
		connection_a = _preview_for_id(preview_elements, element_a.element_id)
	else:
		connection_b = _preview_for_id(preview_elements, element_b.element_id)
	if not RuntimeConnectivity.validate_merge_connection(
		connection_a,
		command.port_a_id,
		connection_b,
		command.port_b_id
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
		)

	# All checks complete. Preserve existing element objects and mutate atomically.
	var removed_anchors: Array[int] = []
	if _assembly_has_anchor(survivor.assembly_id) and _assembly_has_anchor(loser.assembly_id):
		for joint: SimulationJoint in _joints_for_assembly(loser.assembly_id):
			if joint.kind == SimulationJoint.Kind.ANCHOR:
				removed_anchors.append(joint.joint_id)
	for joint_id: int in removed_anchors:
		_joints.erase(joint_id)
	for element_id: int in loser.element_ids:
		var element := get_element(element_id)
		var pose: Dictionary = planned_poses[element_id]
		element.origin_cell = pose["origin_cell"]
		element.orientation_index = int(pose["orientation_index"])
		element.assembly_id = survivor.assembly_id
		survivor.element_ids.append(element_id)
	for joint: SimulationJoint in _joints_for_assembly(loser.assembly_id):
		joint.assembly_id = survivor.assembly_id
	var bridge_id := _allocator.allocate_joint_id()
	_joints[bridge_id] = SimulationJoint.rigid(
		bridge_id,
		survivor.assembly_id,
		command.element_a_id,
		command.port_a_id,
		command.element_b_id,
		command.port_b_id
	)
	survivor.element_ids.sort()
	loser.element_ids.clear()
	loser.tombstoned = true
	loser.redirect_to = survivor.assembly_id
	_redirects[loser.assembly_id] = survivor.assembly_id
	survivor.bump_revision()
	loser.bump_revision()
	_notify_topology_changed()
	removed_anchors.sort()
	_emit_structural_event({
		"kind": &"assembly_merged",
		"command_id": command.command_id,
		"survivor_assembly_id": survivor.assembly_id,
		"loser_assembly_id": loser.assembly_id,
		"survivor_topology_revision": survivor.topology_revision,
		"loser_topology_revision": loser.topology_revision,
		"removed_anchor_joint_ids": removed_anchors,
		"bridge_joint_id": bridge_id,
	})
	return StructuralCommandResult.ok({
		"survivor_assembly_id": survivor.assembly_id,
		"loser_assembly_id": loser.assembly_id,
		"survivor_topology_revision": survivor.topology_revision,
		"loser_topology_revision": loser.topology_revision,
		"bridge_joint_id": bridge_id,
		"redirect_to": survivor.assembly_id,
		"removed_anchor_joint_ids": removed_anchors,
	})


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
	if operational_changed:
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
	var result: Dictionary = {}
	for element: SimulationElement in elements:
		result[element.element_id] = element.occupied_cells()
	return result


func _occupancy_is_unique(
	base: Array[SimulationElement],
	extra: Dictionary
) -> bool:
	var seen: Dictionary = {}
	for element: SimulationElement in base:
		for cell: Vector3i in element.occupied_cells():
			var key := _cell_key(cell)
			if seen.has(key):
				return false
			seen[key] = element.element_id
	for element_id: int in _sorted_keys(extra):
		for cell: Vector3i in extra[element_id]:
			var key := _cell_key(cell)
			if seen.has(key):
				return false
			seen[key] = element_id
	return true


func _cell_key(cell: Vector3i) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]


const _CELL_NEIGHBOURS: Array[Vector3i] = [
	Vector3i.RIGHT,
	Vector3i.LEFT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.BACK,
	Vector3i.FORWARD,
]


func _assembly_occupancy_index(assembly: SimulationAssembly) -> Dictionary:
	var cached: Dictionary = _occupancy_index_cache.get(
		assembly.assembly_id,
		{}
	)
	if int(cached.get("revision", -1)) == assembly.topology_revision:
		return cached["cells"]
	var cells: Dictionary = {}
	for element_id: int in assembly.element_ids:
		var element := get_element(element_id)
		if element == null:
			continue
		for cell: Vector3i in element.occupied_cells():
			cells[cell] = element_id
	_occupancy_index_cache[assembly.assembly_id] = {
		"revision": assembly.topology_revision,
		"cells": cells,
	}
	return cells


func _neighbour_element_ids(
	preview_cells: Array[Vector3i],
	occupancy: Dictionary
) -> Array[int]:
	var seen: Dictionary = {}
	for cell: Vector3i in preview_cells:
		for offset: Vector3i in _CELL_NEIGHBOURS:
			var neighbour: Variant = occupancy.get(cell + offset)
			if neighbour != null:
				seen[int(neighbour)] = true
	var ids: Array[int] = []
	for element_id: Variant in seen.keys():
		ids.append(int(element_id))
	ids.sort()
	return ids


func _joint_belongs_to_component(
	joint: SimulationJoint,
	component: Array
) -> bool:
	if joint.kind == SimulationJoint.Kind.ANCHOR:
		return component.has(joint.element_a_id)
	return (
		component.has(joint.element_a_id)
		and component.has(joint.element_b_id)
	)


func assembly_has_anchor(assembly_id: int) -> bool:
	return _assembly_has_anchor(assembly_id)


func construction_attach_allowed(assembly_id: int) -> bool:
	return _construction_attach_allowed(assembly_id)


func _should_reconcile_assembly(assembly_id: int) -> bool:
	var assembly := get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return false
	for element_id: int in assembly.element_ids:
		var element := get_element(element_id)
		if (
			element != null
			and TerrainAnchorProbe.is_construction_archetype(
				element.archetype_id
			)
		):
			return true
	return false


func _reconcile_terrain_anchors_for_assemblies(
	assembly_ids: Array[int]
) -> void:
	if not _terrain_contact_probe.is_valid():
		return
	var unique_ids: Dictionary = {}
	for assembly_id_variant: Variant in assembly_ids:
		var assembly_id := int(assembly_id_variant)
		if assembly_id <= 0 or unique_ids.has(assembly_id):
			continue
		if not _should_reconcile_assembly(assembly_id):
			continue
		unique_ids[assembly_id] = true
		var assembly := get_assembly_raw(assembly_id)
		if assembly == null or assembly.tombstoned:
			continue
		var elements: Array[SimulationElement] = []
		for element_id: int in assembly.element_ids:
			var element := get_element(element_id)
			if (
				element != null
				and TerrainAnchorProbe.is_construction_archetype(
					element.archetype_id
				)
			):
				elements.append(element)
		if elements.is_empty():
			continue
		var touching_variant: Variant = _terrain_contact_probe.call(
			assembly,
			elements
		)
		if touching_variant is not Array:
			continue
		var touching: Array[int] = []
		for entry: Variant in touching_variant:
			touching.append(int(entry))
		# Probe can miss (collider on terrain child, etc.). Never mass-strip anchors
		# when we already know some blocks were grounded.
		if touching.is_empty():
			for joint: SimulationJoint in _joints_for_assembly(assembly_id):
				if joint.kind != SimulationJoint.Kind.ANCHOR:
					continue
				for element: SimulationElement in elements:
					if element.element_id == joint.element_a_id:
						touching.append(joint.element_a_id)
						break
			touching.sort()
		# Re-verify and persist the terrain-contact fact per block: the terrain is
		# destructible, so a block that used to sit on ground may now float (and
		# vice versa) after a split/dismantle.
		var touching_lookup: Dictionary = {}
		for touching_id: int in touching:
			touching_lookup[touching_id] = true
		for element: SimulationElement in elements:
			element.terrain_contact = touching_lookup.has(element.element_id)
		var result := RuntimeConnectivity.reconcile_terrain_anchors(
			assembly_id,
			elements,
			_joints_for_assembly(assembly_id),
			touching,
			func() -> int:
				return _allocator.allocate_joint_id()
		)
		var changed := false
		for removed_id: int in result["removed_joint_ids"]:
			if _joints.erase(removed_id):
				changed = true
		for added_joint: SimulationJoint in result["added_joints"]:
			_joints[added_joint.joint_id] = added_joint
			changed = true
		if changed:
			assembly.bump_revision()
			_notify_topology_changed()


func _notify_topology_changed() -> void:
	_industry_network.prune_dangling_links(self)
	_purge_industry_runtime_for_missing_elements()
	IndustryStoreService.sync_all_elements(self)
	_cargo_graph.rebuild(self)


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
	var validation := IndustryElectricPortUtil.validate_connect_endpoints(
		self,
		command.element_a_id,
		command.port_a_id,
		command.element_b_id,
		command.port_b_id,
		command.waypoints
	)
	if not validation.is_ok():
		return validation
	var assembly_a_id := int(validation.data["assembly_a_id"])
	var assembly_b_id := int(validation.data["assembly_b_id"])
	if command.assembly_id > 0 and command.assembly_id != assembly_a_id:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var assembly_a := get_assembly_raw(assembly_a_id)
	var assembly_b := get_assembly_raw(assembly_b_id)
	if (
		assembly_a == null
		or assembly_a.tombstoned
		or assembly_b == null
		or assembly_b.tombstoned
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var expected_a := command.expected_revision_a
	if expected_a < 0:
		expected_a = command.expected_assembly_revision
	if (
		expected_a >= 0
		and assembly_a.topology_revision != expected_a
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"endpoint": &"a",
				"expected": expected_a,
				"actual": assembly_a.topology_revision,
			}
		)
	if (
		command.expected_revision_b >= 0
		and assembly_b.topology_revision != command.expected_revision_b
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"endpoint": &"b",
				"expected": command.expected_revision_b,
				"actual": assembly_b.topology_revision,
			}
		)
	if _industry_network.has_pair(
		command.element_a_id,
		command.port_a_id,
		command.element_b_id,
		command.port_b_id
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_DUPLICATE_CONNECTION
		)
	var link_id := _allocator.allocate_link_id()
	var link := _industry_network.add_link(
		link_id,
		command.element_a_id,
		command.port_a_id,
		command.element_b_id,
		command.port_b_id,
		command.waypoints
	)
	_industry_network.bump_revision()
	_emit_structural_event({
		"kind": &"electric_link_added",
		"command_id": command.command_id,
		"assembly_id": assembly_a_id,
		"assembly_a_id": assembly_a_id,
		"assembly_b_id": assembly_b_id,
		"topology_revision": assembly_a.topology_revision,
		"industry_network_revision": _industry_network.industry_network_revision,
		"link_id": link.link_id,
		"element_a_id": link.element_a,
		"port_a_id": link.port_a,
		"element_b_id": link.element_b,
		"port_b_id": link.port_b,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": assembly_a_id,
		"assembly_a_id": assembly_a_id,
		"assembly_b_id": assembly_b_id,
		"topology_revision": assembly_a.topology_revision,
		"industry_network_revision": _industry_network.industry_network_revision,
		"link_id": link.link_id,
		"distance_m": validation.data["distance_m"],
	})


func _disconnect_network(
	command: DisconnectNetworkCommand
) -> StructuralCommandResult:
	var link: IndustryElectricLink = null
	if command.link_id > 0:
		link = _industry_network.get_link(command.link_id)
	else:
		link = _find_electric_link_by_endpoints(
			command.element_a_id,
			command.port_a_id,
			command.element_b_id,
			command.port_b_id
		)
	if link == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var element_a := get_element(link.element_a)
	if element_a == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var assembly := get_assembly_raw(element_a.assembly_id)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if command.assembly_id > 0 and command.assembly_id != assembly.assembly_id:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	if (
		command.expected_assembly_revision >= 0
		and assembly.topology_revision != command.expected_assembly_revision
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"expected": command.expected_assembly_revision,
				"actual": assembly.topology_revision,
			}
		)
	var removed := _industry_network.remove_link(link.link_id)
	_industry_network.bump_revision()
	_emit_structural_event({
		"kind": &"electric_link_removed",
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"industry_network_revision": _industry_network.industry_network_revision,
		"link_id": removed.link_id,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"industry_network_revision": _industry_network.industry_network_revision,
		"link_id": removed.link_id,
	})


func _find_electric_link_by_endpoints(
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String
) -> IndustryElectricLink:
	for link: IndustryElectricLink in _industry_network.list_links():
		if link.matches_endpoints(
			element_a_id,
			port_a_id,
			element_b_id,
			port_b_id
		):
			return link
	return null


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
	var stale: Array[int] = []
	for pile_id_variant: Variant in _world_loot_piles.keys():
		var pile_id := int(pile_id_variant)
		var pile: WorldLootPile = _world_loot_piles[pile_id]
		if pile == null:
			stale.append(pile_id)
			continue
		if pile.despawn_at_s > 0.0 and _simulation_time_s + 0.000001 >= pile.despawn_at_s:
			stale.append(pile_id)
	for pile_id: int in stale:
		_world_loot_piles.erase(pile_id)


func _record_placement_terrain_contact(
	assembly: SimulationAssembly,
	element: SimulationElement,
	joint_ids: Array[int]
) -> void:
	if not TerrainAnchorProbe.is_construction_archetype(element.archetype_id):
		return
	if not _terrain_contact_probe.is_valid():
		return
	var touching: Array[int] = _probe_touching_ids(assembly, [element])
	element.terrain_contact = touching.has(element.element_id)
	if not element.terrain_contact:
		return
	if _element_anchor_joint_id(assembly.assembly_id, element.element_id) != 0:
		return
	var port_id := RuntimeConnectivity.ground_anchor_port_id(element)
	if port_id.is_empty():
		return
	var joint_id := _allocator.allocate_joint_id()
	_joints[joint_id] = SimulationJoint.anchor(
		joint_id,
		assembly.assembly_id,
		element.element_id,
		port_id
	)
	joint_ids.append(joint_id)


func _probe_touching_ids(
	assembly: SimulationAssembly,
	elements: Array[SimulationElement]
) -> Array[int]:
	var out: Array[int] = []
	if not _terrain_contact_probe.is_valid():
		return out
	var touching_variant: Variant = _terrain_contact_probe.call(
		assembly,
		elements
	)
	if touching_variant is Array:
		for entry: Variant in touching_variant:
			out.append(int(entry))
	return out


func _element_anchor_joint_id(assembly_id: int, element_id: int) -> int:
	for joint_variant: Variant in _joints.values():
		var joint: SimulationJoint = joint_variant
		if (
			joint.assembly_id == assembly_id
			and joint.kind == SimulationJoint.Kind.ANCHOR
			and joint.element_a_id == element_id
		):
			return joint.joint_id
	return 0


func _assembly_has_anchor(assembly_id: int) -> bool:
	for joint_variant: Variant in _joints.values():
		var joint: SimulationJoint = joint_variant
		if (
			joint.assembly_id == assembly_id
			and joint.kind == SimulationJoint.Kind.ANCHOR
		):
			return true
	return false


## Terrain-anchored builds always attach. Floating locomotives may expand only
## while nearly stopped (parking brake or coast-to-stop).
func _construction_attach_allowed(assembly_id: int) -> bool:
	if _assembly_has_anchor(assembly_id):
		return true
	if not WheelSimulationService.is_locomotive_assembly(self, assembly_id):
		return false
	var assembly := get_assembly_raw(assembly_id)
	if assembly == null:
		return false
	var eps := AssemblyLocomotionController.PARKING_BRAKE_SPEED_EPS
	return (
		assembly.motion.linear_velocity.length() < eps
		and assembly.motion.angular_velocity.length() < eps
	)


func _sorted_keys(dictionary: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key: Variant in dictionary.keys():
		result.append(int(key))
	result.sort()
	return result


func _emit_structural_event(event: Dictionary) -> void:
	structural_event.emit(event)
