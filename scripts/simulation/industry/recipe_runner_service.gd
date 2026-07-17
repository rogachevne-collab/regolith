class_name RecipeRunnerService
extends RefCounted

const EPSILON := 0.000001

var _machine_cargo := MachineCargoService.new()


func tick(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	dt: float
) -> void:
	if world == null or dt <= 0.0:
		return
	for element: SimulationElement in world.list_elements():
		if not _is_recipe_machine(element):
			continue
		_tick_machine(world, cargo_graph, transfer_service, element, dt)


func apply_set_machine_enabled(
	world: SimulationWorld,
	command: SetMachineEnabledCommand,
	cargo_graph: CargoGraph = null,
	transfer_service: CargoTransferService = null
) -> Dictionary:
	if command == null or command.element_id <= 0:
		return _failed(&"invalid_target")
	var element := world.get_element(command.element_id)
	if element == null or not _is_recipe_machine(element):
		return _failed(&"invalid_target")
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	runtime.machine_enabled = command.enabled
	if not command.enabled:
		_cancel_active_job(world, element, runtime)
	else:
		_kick_idle_machine(
			world,
			element.element_id,
			cargo_graph,
			transfer_service
		)
	element.industry_functional_reason = &"disabled" if not command.enabled else &"ok"
	element.bump_state_revision()
	return _ok()


func apply_enqueue_recipe(
	world: SimulationWorld,
	command: EnqueueRecipeCommand,
	cargo_graph: CargoGraph = null,
	transfer_service: CargoTransferService = null
) -> Dictionary:
	if command == null or command.element_id <= 0 or command.recipe_id.is_empty():
		return _failed(&"invalid_target")
	if not RecipeCatalog.has_recipe(command.recipe_id):
		return _failed(&"invalid_target")
	var element := world.get_element(command.element_id)
	if element == null or not _is_recipe_machine(element):
		return _failed(&"invalid_target")
	if RecipeCatalog.machine_archetype_id(command.recipe_id) != element.archetype_id:
		return _failed(&"invalid_target")
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	var machine := runtime.ensure_machine_state()
	if machine.queue_depth() >= IndustryArchetypeProfile.queue_max_depth():
		return _failed(&"queue_full")
	machine.queue.append(command.recipe_id)
	element.bump_state_revision()
	_kick_idle_machine(
		world,
		element.element_id,
		cargo_graph,
		transfer_service
	)
	return _ok()


func apply_dequeue_recipe(
	world: SimulationWorld,
	command: DequeueRecipeCommand,
	cargo_graph: CargoGraph = null,
	transfer_service: CargoTransferService = null
) -> Dictionary:
	if command == null or command.element_id <= 0:
		return _failed(&"invalid_target")
	var element := world.get_element(command.element_id)
	if element == null or not _is_recipe_machine(element):
		return _failed(&"invalid_target")
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	var machine := runtime.ensure_machine_state()
	if machine.queue.is_empty():
		return _failed(&"no_effect")
	machine.queue.remove_at(0)
	element.bump_state_revision()
	_kick_idle_machine(
		world,
		element.element_id,
		cargo_graph,
		transfer_service
	)
	return _ok()


func kick_idle_machine(
	world: SimulationWorld,
	element_id: int,
	cargo_graph: CargoGraph = null,
	transfer_service: CargoTransferService = null
) -> void:
	_kick_idle_machine(world, element_id, cargo_graph, transfer_service)


func _kick_idle_machine(
	world: SimulationWorld,
	element_id: int,
	cargo_graph: CargoGraph = null,
	transfer_service: CargoTransferService = null
) -> void:
	if world == null or element_id <= 0:
		return
	var element := world.get_element(element_id)
	if element == null or not _is_recipe_machine(element):
		return
	var graph := cargo_graph if cargo_graph != null else world.ensure_cargo_graph_current()
	var transfer := (
		transfer_service if transfer_service != null else CargoTransferService.new()
	)
	IndustryElectricBudget.apply_tick(world, 0.001)
	_tick_machine(world, graph, transfer, element, 0.0)


func cancel_active_job(world: SimulationWorld, element_id: int) -> bool:
	var element := world.get_element(element_id)
	if element == null:
		return false
	var runtime := world.get_industry_element_runtime(element_id)
	if runtime == null:
		return false
	return _cancel_active_job(world, element, runtime)


func _tick_machine(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement,
	dt: float
) -> void:
	IndustryStoreService.sync_element_storage(world, element)
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	var machine := runtime.ensure_machine_state()

	if not element.is_operational():
		runtime.active_recipe_power_w = 0.0
		element.industry_functional_reason = element.status_reason()
		return

	if not runtime.machine_enabled:
		runtime.active_recipe_power_w = 0.0
		element.industry_functional_reason = &"disabled"
		return

	if not runtime.powered:
		runtime.active_recipe_power_w = _active_power_w(machine)
		element.industry_functional_reason = runtime.power_reason
		return

	if machine.active_recipe_id.is_empty():
		_prefetch_recipe_inputs(
			world,
			cargo_graph,
			transfer_service,
			element,
			machine
		)
		_try_start_job(world, cargo_graph, transfer_service, element, runtime, machine)

	if machine.active_recipe_id.is_empty():
		runtime.active_recipe_power_w = 0.0
		_prefetch_recipe_inputs(
			world,
			cargo_graph,
			transfer_service,
			element,
			machine
		)
		element.industry_functional_reason = _idle_reason(
			world,
			cargo_graph,
			element,
			machine
		)
		return

	runtime.active_recipe_power_w = RecipeCatalog.power_w(machine.active_recipe_id)
	_machine_cargo.pull_inputs_for_recipe(
		world,
		cargo_graph,
		transfer_service,
		element,
		RecipeCatalog.inputs(machine.active_recipe_id)
	)

	if not _outputs_have_capacity(
		world,
		cargo_graph,
		element,
		RecipeCatalog.outputs(machine.active_recipe_id)
	):
		element.industry_functional_reason = &"storage_full"
		return

	machine.progress_s += dt
	var duration := RecipeCatalog.duration_s(machine.active_recipe_id)
	if machine.progress_s + EPSILON < duration:
		element.industry_functional_reason = &"ok"
		return

	_complete_job(
		world,
		cargo_graph,
		transfer_service,
		element,
		runtime,
		machine
	)
	element.industry_functional_reason = &"ok"


func _try_start_job(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement,
	runtime: IndustryElementRuntime,
	machine: IndustryMachineState
) -> void:
	if machine.queue.is_empty():
		var default_id := RecipeCatalog.default_recipe_for_machine(
			element.archetype_id
		)
		if default_id.is_empty():
			return
		if _try_start_recipe(
			world,
			cargo_graph,
			transfer_service,
			element,
			runtime,
			machine,
			default_id
		):
			return
		return
	var attempts := machine.queue.size()
	for _attempt: int in range(attempts):
		var recipe_id := machine.queue[0]
		machine.queue.remove_at(0)
		if _try_start_recipe(
			world,
			cargo_graph,
			transfer_service,
			element,
			runtime,
			machine,
			recipe_id
		):
			return
		machine.queue.append(recipe_id)


func _try_start_recipe(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement,
	runtime: IndustryElementRuntime,
	machine: IndustryMachineState,
	recipe_id: String
) -> bool:
	if recipe_id.is_empty():
		return false
	if not _try_reserve_inputs(
		world,
		cargo_graph,
		transfer_service,
		element,
		recipe_id,
		machine
	):
		return false
	var outputs := RecipeCatalog.outputs(recipe_id)
	if not _outputs_have_capacity(
		world,
		cargo_graph,
		element,
		outputs
	):
		var buffer_capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
			element.archetype_id
		)
		_refund_reserved(element, machine.reserved_inputs, buffer_capacity)
		machine.reserved_inputs.clear()
		return false
	machine.active_recipe_id = recipe_id
	machine.progress_s = 0.0
	runtime.active_recipe_power_w = RecipeCatalog.power_w(recipe_id)
	return true


func _buffer_has_inputs(element: SimulationElement, inputs: Dictionary) -> bool:
	for resource_id: Variant in inputs.keys():
		var needed := float(inputs[resource_id])
		if needed <= EPSILON:
			continue
		if element.industry_buffer.amount(str(resource_id)) + EPSILON < needed:
			return false
	return true


func _try_reserve_inputs(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement,
	recipe_id: String,
	machine: IndustryMachineState
) -> bool:
	var inputs := RecipeCatalog.inputs(recipe_id)
	_evict_buffer_for_inputs(
		world,
		cargo_graph,
		transfer_service,
		element,
		inputs
	)
	_machine_cargo.pull_inputs_for_recipe(
		world,
		cargo_graph,
		transfer_service,
		element,
		inputs
	)
	if not _buffer_has_inputs(element, inputs):
		return false
	var reserved: Dictionary = {}
	var buffer_capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
		element.archetype_id
	)
	for resource_id: Variant in inputs.keys():
		var amount := float(inputs[resource_id])
		if amount <= EPSILON:
			continue
		var resource := str(resource_id)
		if not element.industry_buffer.can_remove(resource, amount):
			_refund_reserved(element, reserved, buffer_capacity)
			return false
		if not element.industry_buffer.remove(resource, amount):
			_refund_reserved(element, reserved, buffer_capacity)
			return false
		reserved[resource] = amount
	machine.reserved_inputs = reserved
	return true


func _refund_reserved(
	element: SimulationElement,
	reserved: Dictionary,
	buffer_capacity: float
) -> void:
	for resource_id: Variant in reserved.keys():
		element.industry_buffer.add(
			str(resource_id),
			float(reserved[resource_id]),
			buffer_capacity
		)


func _complete_job(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement,
	runtime: IndustryElementRuntime,
	machine: IndustryMachineState
) -> void:
	var outputs := RecipeCatalog.outputs(machine.active_recipe_id)
	var buffer_capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
		element.archetype_id
	)
	for resource_id: Variant in outputs.keys():
		var amount := float(outputs[resource_id])
		if amount <= EPSILON:
			continue
		element.industry_buffer.add(str(resource_id), amount, buffer_capacity)
	machine.clear_active()
	runtime.active_recipe_power_w = 0.0
	var output_ids := PackedStringArray()
	for resource_id: Variant in outputs.keys():
		output_ids.append(str(resource_id))
	_machine_cargo.push_outputs_from_buffer(
		world,
		cargo_graph,
		transfer_service,
		element,
		output_ids
	)
	element.bump_state_revision()


func _cancel_active_job(
	_world: SimulationWorld,
	element: SimulationElement,
	runtime: IndustryElementRuntime
) -> bool:
	var machine := runtime.ensure_machine_state()
	if machine.active_recipe_id.is_empty():
		return false
	var buffer_capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
		element.archetype_id
	)
	for resource_id: Variant in machine.reserved_inputs.keys():
		element.industry_buffer.add(
			str(resource_id),
			float(machine.reserved_inputs[resource_id]),
			buffer_capacity
		)
	machine.clear_active()
	runtime.active_recipe_power_w = 0.0
	element.bump_state_revision()
	return true


func _prefetch_recipe_inputs(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement,
	machine: IndustryMachineState
) -> void:
	var recipe_id := _pending_recipe_id(element, machine)
	if recipe_id.is_empty():
		return
	var inputs := RecipeCatalog.inputs(recipe_id)
	_evict_buffer_for_inputs(
		world,
		cargo_graph,
		transfer_service,
		element,
		inputs
	)
	_machine_cargo.pull_inputs_for_recipe(
		world,
		cargo_graph,
		transfer_service,
		element,
		inputs
	)


func _evict_buffer_for_inputs(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	transfer_service: CargoTransferService,
	element: SimulationElement,
	inputs: Dictionary
) -> void:
	if element == null or inputs.is_empty():
		return
	var buffer_capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
		element.archetype_id
	)
	for _attempt: int in range(128):
		if _buffer_has_inputs(element, inputs):
			return
		if not _buffer_needs_room_for_inputs(element, inputs, buffer_capacity):
			return
		var progressed := false
		for resource_id: String in element.industry_buffer.resource_ids():
			if inputs.has(resource_id):
				continue
			var before := element.industry_buffer.amount(resource_id)
			if before <= EPSILON:
				continue
			_machine_cargo.push_outputs_from_buffer(
				world,
				cargo_graph,
				transfer_service,
				element,
				PackedStringArray([resource_id])
			)
			if element.industry_buffer.amount(resource_id) + EPSILON < before:
				progressed = true
		if not progressed:
			return


func _buffer_needs_room_for_inputs(
	element: SimulationElement,
	inputs: Dictionary,
	buffer_capacity: float
) -> bool:
	for resource_id: Variant in inputs.keys():
		var needed := float(inputs[resource_id])
		if needed <= EPSILON:
			continue
		var resource := str(resource_id)
		var have := element.industry_buffer.amount(resource)
		var remaining := maxf(needed - have, 0.0)
		if remaining <= EPSILON:
			continue
		if (
			element.industry_buffer.max_addable_amount(resource, buffer_capacity)
			+ EPSILON
			< remaining
		):
			return true
	return false


func _pending_recipe_id(
	element: SimulationElement,
	machine: IndustryMachineState
) -> String:
	if not machine.queue.is_empty():
		return str(machine.queue[0])
	return RecipeCatalog.default_recipe_for_machine(element.archetype_id)


func _idle_reason(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	element: SimulationElement,
	machine: IndustryMachineState
) -> StringName:
	return _idle_reason_for_recipe(
		world,
		cargo_graph,
		element,
		machine,
		_pending_recipe_id(element, machine)
	)


func _idle_reason_for_recipe(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	element: SimulationElement,
	machine: IndustryMachineState,
	recipe_id: String
) -> StringName:
	if recipe_id.is_empty():
		return &"standby"
	var inputs := RecipeCatalog.inputs(recipe_id)
	if not _buffer_has_inputs(element, inputs):
		if not cargo_graph.has_connected_cargo_store(world, element.element_id):
			return &"port_disconnected"
		if not _connected_inputs_available(world, cargo_graph, element, inputs):
			return &"no_input"
		var buffer_capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
			element.archetype_id
		)
		if _buffer_needs_room_for_inputs(element, inputs, buffer_capacity):
			return &"storage_full"
		return &"standby"
	if not _outputs_have_capacity(
		world,
		cargo_graph,
		element,
		RecipeCatalog.outputs(recipe_id)
	):
		return &"storage_full"
	if machine.queue.is_empty():
		return &"standby"
	return &"standby"


static func preview_idle_reason_for_recipe(
	world: SimulationWorld,
	element: SimulationElement,
	recipe_id: String
) -> StringName:
	if world == null or element == null or recipe_id.is_empty():
		return &"standby"
	var service := RecipeRunnerService.new()
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	return service._idle_reason_for_recipe(
		world,
		world.ensure_cargo_graph_current(),
		element,
		runtime.ensure_machine_state(),
		recipe_id
	)


static func connected_supply_amount(
	world: SimulationWorld,
	from_element_id: int,
	resource_id: String
) -> float:
	if (
		world == null
		or from_element_id <= 0
		or resource_id.is_empty()
	):
		return 0.0
	var graph := world.ensure_cargo_graph_current()
	var total := 0.0
	for element: SimulationElement in world.list_elements():
		if (
			not element.is_operational()
			or not IndustryArchetypeProfile.has_keyed_store(
				element.archetype_id
			)
		):
			continue
		if graph.shortest_hop_distance(from_element_id, element.element_id) < 0:
			continue
		var store := IndustryStoreService.ensure_element_keyed_store(
			world,
			element
		)
		if store != null:
			total += store.amount(resource_id)
	return total


static func connected_cargo_has_path(
	world: SimulationWorld,
	from_element_id: int
) -> bool:
	if world == null or from_element_id <= 0:
		return false
	return (
		world.ensure_cargo_graph_current().has_connected_cargo_store(
			world,
			from_element_id
		)
	)


static func missing_input_resource_id(
	world: SimulationWorld,
	element: SimulationElement,
	recipe_id: String = ""
) -> String:
	if world == null or element == null:
		return ""
	if element.archetype_id not in ["processor", "fabricator"]:
		return ""
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	var machine := runtime.ensure_machine_state()
	if not machine.active_recipe_id.is_empty():
		return ""
	var pending_recipe := recipe_id
	if pending_recipe.is_empty():
		pending_recipe = (
			str(machine.queue[0])
			if not machine.queue.is_empty()
			else RecipeCatalog.default_recipe_for_machine(element.archetype_id)
		)
	return missing_input_for_recipe(world, element, pending_recipe)


static func missing_input_for_recipe(
	world: SimulationWorld,
	element: SimulationElement,
	recipe_id: String
) -> String:
	if world == null or element == null or recipe_id.is_empty():
		return ""
	var graph := world.ensure_cargo_graph_current()
	if not graph.has_connected_cargo_store(world, element.element_id):
		return ""
	var inputs := RecipeCatalog.inputs(recipe_id)
	for resource_id: Variant in inputs.keys():
		var needed := float(inputs[resource_id])
		if needed <= EPSILON:
			continue
		var resource := str(resource_id)
		if element.industry_buffer.amount(resource) + EPSILON >= needed:
			continue
		if connected_supply_amount(world, element.element_id, resource) + EPSILON >= needed:
			continue
		return resource
	return ""


func _connected_inputs_available(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	element: SimulationElement,
	inputs: Dictionary
) -> bool:
	for resource_id: Variant in inputs.keys():
		var needed := float(inputs[resource_id])
		if needed <= EPSILON:
			continue
		if (
			cargo_graph.nearest_cargo_store_element_id_with_resource(
				world,
				element.element_id,
				str(resource_id),
				needed
			)
			<= 0
		):
			return false
	return true


func _outputs_have_capacity(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	element: SimulationElement,
	outputs: Dictionary
) -> bool:
	return _machine_cargo.can_accept_outputs(world, cargo_graph, element, outputs)


func _active_power_w(machine: IndustryMachineState) -> float:
	if machine.active_recipe_id.is_empty():
		return 0.0
	return RecipeCatalog.power_w(machine.active_recipe_id)


func _is_recipe_machine(element: SimulationElement) -> bool:
	return IndustryArchetypeProfile.is_recipe_machine(element.archetype_id)


func _ok() -> Dictionary:
	return {"status": &"ok", "reason": &"ok"}


func _failed(reason: StringName) -> Dictionary:
	return {"status": &"failed", "reason": reason}
