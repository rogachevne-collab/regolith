class_name OxygenRefillService
extends RefCounted

const EPSILON := 0.000001

var _auto_refill_players: Dictionary = {}
var _pending_auto: Array[Dictionary] = []
var _manual_intents: Dictionary = {}
var _pending_manual: Array[Dictionary] = []


func queue_manual(command: OxygenRefillCommand) -> Dictionary:
	if (
		command == null
		or command.player_id.is_empty()
		or command.module_element_id <= 0
	):
		return _failed(&"invalid_target")
	# One server-owned transfer quantum per player per industry tick. Repeated
	# hold packets replace the same intent and cannot amplify rate or delta.
	_manual_intents[command.player_id] = command.module_element_id
	return {
		"status": &"ok",
		"reason": &"queued",
		"accepted_l": 0.0,
		"player_id": command.player_id,
		"module_element_id": command.module_element_id,
	}


func prepare_auto_refill(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	delta_s: float
) -> void:
	_pending_auto.clear()
	_pending_manual.clear()
	if world == null or cargo_graph == null or delta_s <= 0.0:
		return
	_clear_module_active_draws(world)
	world.prune_seat_contexts()
	var claimed_modules: Dictionary = {}
	var manual_player_ids: Array[String] = []
	for player_id: String in _manual_intents.keys():
		manual_player_ids.append(player_id)
	manual_player_ids.sort()
	for player_id: String in manual_player_ids:
		var module_id := int(_manual_intents[player_id])
		var suit := world.get_suit_state(player_id)
		var module := world.get_element(module_id)
		if (
			suit == null
			or suit.oxygen >= suit.oxygen_max - EPSILON
			or claimed_modules.has(module_id)
			or not _base_module_usable(world, module)
		):
			continue
		claimed_modules[module_id] = true
		var definition := module.get_archetype().oxygen_module_definition
		world.ensure_industry_element_runtime(module_id).dynamic_power_w = (
			definition.active_w
		)
		_pending_manual.append({
			"player_id": player_id,
			"module_element_id": module_id,
			"delta_s": delta_s,
		})
	_manual_intents.clear()
	for player_id: String in world.list_seat_context_player_ids():
		var suit := world.get_suit_state(player_id)
		if suit == null:
			continue
		var fraction := suit.oxygen_fraction()
		var active := bool(_auto_refill_players.get(player_id, false))
		if active and fraction >= 1.0 - EPSILON:
			active = false
		elif not active and fraction < 0.95:
			active = true
		_auto_refill_players[player_id] = active
		if not active:
			continue
		var seat_id := world.get_player_seat_element_id(player_id)
		var module_id := _nearest_usable_module(
			world,
			cargo_graph,
			seat_id,
			claimed_modules
		)
		if module_id <= 0:
			continue
		claimed_modules[module_id] = true
		var module := world.get_element(module_id)
		var definition := module.get_archetype().oxygen_module_definition
		world.ensure_industry_element_runtime(module_id).dynamic_power_w = (
			definition.active_w
		)
		_pending_auto.append({
			"player_id": player_id,
			"module_element_id": module_id,
			"delta_s": delta_s,
		})


func execute_auto_refill(world: SimulationWorld) -> void:
	for row: Dictionary in _pending_manual + _pending_auto:
		var command := OxygenRefillCommand.new()
		command.player_id = str(row["player_id"])
		command.module_element_id = int(row["module_element_id"])
		command.delta_s = float(row["delta_s"])
		var result := _transfer(world, command, false)
		if StringName(result.get("reason", &"")) != &"ok":
			var runtime := world.get_industry_element_runtime(
				command.module_element_id
			)
			if runtime != null:
				runtime.dynamic_power_w = 0.0
	_pending_manual.clear()
	_pending_auto.clear()


func apply_manual(
	world: SimulationWorld,
	command: OxygenRefillCommand
) -> Dictionary:
	if world == null or command == null:
		return _failed(&"invalid_target")
	var module := world.get_element(command.module_element_id)
	if not _base_module_usable(world, module):
		return _failed(_module_reason(world, module))
	return queue_manual(command)


func _transfer(
	world: SimulationWorld,
	command: OxygenRefillCommand,
	_require_connectivity: bool
) -> Dictionary:
	if (
		world == null
		or command == null
		or command.player_id.is_empty()
		or command.module_element_id <= 0
		or not is_finite(command.delta_s)
		or command.delta_s <= 0.0
	):
		return _failed(&"invalid_target")
	var suit := world.get_suit_state(command.player_id)
	if suit == null:
		return _failed(&"invalid_player")
	var module := world.get_element(command.module_element_id)
	if not _base_module_usable(world, module):
		return _failed(_module_reason(world, module))
	var runtime := world.get_industry_element_runtime(module.element_id)
	if runtime == null or not runtime.powered:
		return _failed(&"no_power")
	var store := IndustryStoreService.ensure_element_keyed_store(world, module)
	if store == null:
		return _failed(&"invalid_target")
	var liters_per_unit := ResourceCatalog.volume_per_unit_l("oxygen")
	var available_l := store.amount("oxygen") * liters_per_unit
	var headroom_l := maxf(suit.oxygen_max - suit.oxygen, 0.0)
	var definition := module.get_archetype().oxygen_module_definition
	var accepted_l := minf(
		minf(available_l, headroom_l),
		definition.dispense_lps * command.delta_s
	)
	if accepted_l <= EPSILON:
		return _failed(&"no_capacity" if headroom_l <= EPSILON else &"no_input")
	var remove_units := accepted_l / liters_per_unit
	if not store.remove("oxygen", remove_units):
		return _failed(&"no_input")
	if not suit.set_oxygen(suit.oxygen + accepted_l):
		store.add("oxygen", remove_units, definition.capacity_l)
		return _failed(&"no_capacity")
	suit.reset_hypoxia()
	world.notify_suit_changed(command.player_id)
	module.bump_state_revision()
	return {
		"status": &"ok",
		"reason": &"ok",
		"accepted_l": accepted_l,
		"module_element_id": module.element_id,
		"player_id": command.player_id,
	}


func _nearest_usable_module(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	seat_element_id: int,
	claimed_modules: Dictionary = {}
) -> int:
	return cargo_graph.nearest_reachable_matching(
		world,
		seat_element_id,
		func(element: SimulationElement) -> bool:
			return (
				not claimed_modules.has(element.element_id)
				and _base_module_usable(world, element)
			)
	)


func _base_module_usable(
	world: SimulationWorld,
	element: SimulationElement
) -> bool:
	if (
		element == null
		or not element.is_operational()
		or not IndustryStoreService.is_oxygen_module(element)
	):
		return false
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	if not runtime.machine_enabled:
		return false
	var store := IndustryStoreService.ensure_element_keyed_store(world, element)
	return store != null and store.amount("oxygen") > EPSILON


func _module_reason(
	world: SimulationWorld,
	element: SimulationElement
) -> StringName:
	if element == null or not IndustryStoreService.is_oxygen_module(element):
		return &"invalid_target"
	if not element.is_operational():
		return &"element_incomplete"
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	if not runtime.machine_enabled:
		return &"disabled"
	return &"no_input"


func _clear_module_active_draws(world: SimulationWorld) -> void:
	for element: SimulationElement in world.list_elements():
		if not IndustryStoreService.is_oxygen_module(element):
			continue
		var runtime := world.get_industry_element_runtime(element.element_id)
		if runtime != null:
			runtime.dynamic_power_w = 0.0
			runtime.oxygen_manual_dispensed_since_tick = false


static func _failed(reason: StringName) -> Dictionary:
	return {
		"status": &"failed",
		"reason": reason,
		"accepted_l": 0.0,
	}
