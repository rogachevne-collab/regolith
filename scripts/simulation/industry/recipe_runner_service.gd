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
	command: SetMachineEnabledCommand
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
	element.industry_functional_reason = &"disabled" if not command.enabled else &"ok"
	element.bump_state_revision()
	return _ok()


func apply_enqueue_recipe(
	world: SimulationWorld,
	command: EnqueueRecipeCommand
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
	return _ok()


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
		_try_start_job(world, cargo_graph, transfer_service, element, runtime, machine)

	if machine.active_recipe_id.is_empty():
		runtime.active_recipe_power_w = 0.0
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
	var recipe_id := ""
	if not machine.queue.is_empty():
		recipe_id = machine.queue[0]
		machine.queue.remove_at(0)
	else:
		recipe_id = _pick_default_recipe(element)
	if recipe_id.is_empty():
		return
	if not _try_reserve_inputs(
		world,
		cargo_graph,
		transfer_service,
		element,
		recipe_id,
		machine
	):
		if not machine.queue.is_empty():
			machine.queue.insert(0, recipe_id)
		return
	machine.active_recipe_id = recipe_id
	machine.progress_s = 0.0
	runtime.active_recipe_power_w = RecipeCatalog.power_w(recipe_id)


func _pick_default_recipe(element: SimulationElement) -> String:
	var default_id := RecipeCatalog.default_recipe_for_machine(element.archetype_id)
	if (
		not default_id.is_empty()
		and _buffer_has_inputs(element, RecipeCatalog.inputs(default_id))
	):
		return default_id
	for recipe_id: String in RecipeCatalog.recipe_ids_for_machine(
		element.archetype_id
	):
		if _buffer_has_inputs(element, RecipeCatalog.inputs(recipe_id)):
			return recipe_id
	return ""


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
	var buffer_capacity := IndustryArchetypeProfile.internal_buffer_capacity_kg(
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
	var buffer_capacity := IndustryArchetypeProfile.internal_buffer_capacity_kg(
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
	world: SimulationWorld,
	element: SimulationElement,
	runtime: IndustryElementRuntime
) -> bool:
	var machine := runtime.ensure_machine_state()
	if machine.active_recipe_id.is_empty():
		return false
	var buffer_capacity := IndustryArchetypeProfile.internal_buffer_capacity_kg(
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


func _idle_reason(
	world: SimulationWorld,
	cargo_graph: CargoGraph,
	element: SimulationElement,
	machine: IndustryMachineState
) -> StringName:
	if machine.queue_depth() >= IndustryArchetypeProfile.queue_max_depth():
		return &"queue_full"
	var recipe_id := _pick_default_recipe(element)
	if recipe_id.is_empty():
		recipe_id = RecipeCatalog.default_recipe_for_machine(element.archetype_id)
	if recipe_id.is_empty():
		return &"ok"
	if not _buffer_has_inputs(element, RecipeCatalog.inputs(recipe_id)):
		if cargo_graph.nearest_cargo_store_element_id(world, element.element_id) <= 0:
			return &"port_disconnected"
		return &"no_input"
	if not _outputs_have_capacity(
		world,
		cargo_graph,
		element,
		RecipeCatalog.outputs(recipe_id)
	):
		return &"storage_full"
	return &"ok"


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
