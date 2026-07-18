class_name IndustryElectricBudget
extends RefCounted

const WATTS_TO_KWH_PER_SECOND := 1.0 / 3600000.0


static func apply_tick(world: SimulationWorld, dt: float) -> void:
	if world == null or dt <= 0.0:
		return
	WheelSimulationService.sync_power_demand(world)
	ActuatorSimulationService.sync_power_demand(world)
	ThrusterSimulationService.sync_power_demand(world)
	var network := world.get_industry_network()
	var graph := network.ensure_graph_current(world)
	var consumers: Array[SimulationElement] = []
	for element: SimulationElement in world.list_elements():
		if (
			element.is_operational()
			and IndustryElectricProfile.is_power_consumer(element)
		):
			consumers.append(element)

	var supplied_networks: Array[Dictionary] = []
	for component: Array in graph.components():
		var component_network := build_component_network(world, component)
		if bool(component_network["supplied"]):
			supplied_networks.append(component_network)

	# Consumers never enter the cable graph (wires connect only power
	# infrastructure); they are powered spatially by a supplied distributor.
	for consumer: SimulationElement in consumers:
		var runtime := world.ensure_industry_element_runtime(consumer.element_id)
		if not runtime.machine_enabled:
			_set_consumer_power(world, consumer, false, &"disabled")
			continue
		var radius_index := _nearest_covering_network(
			world,
			consumer,
			supplied_networks
		)
		if radius_index >= 0:
			(supplied_networks[radius_index]["consumers"] as Array).append(
				consumer
			)
			continue
		if supplied_networks.is_empty():
			_set_consumer_power(world, consumer, false, &"port_disconnected")
			continue
		_set_consumer_power(world, consumer, false, &"outside_power_radius")

	for supplied_network: Dictionary in supplied_networks:
		_solve_supplied_network(world, supplied_network, dt)


static func is_element_on_supplied_network(
	world: SimulationWorld,
	element_id: int
) -> bool:
	if world == null or element_id <= 0:
		return false
	var graph := world.get_industry_network().ensure_graph_current(world)
	for component: Array in graph.components():
		if not component.has(element_id):
			continue
		return bool(build_component_network(world, component)["supplied"])
	return false


static func element_world_position(
	world: SimulationWorld,
	element: SimulationElement
) -> Vector3:
	if world == null or element == null:
		return Vector3.ZERO
	return world.element_world_transform(element.element_id).origin


## First-time charge for a placed/spawned battery. Never refills after drain:
## once `battery_initialized` is set, empty means empty until a source charges it.
static func seed_battery_if_needed(
	world: SimulationWorld,
	battery_element_id: int
) -> void:
	if world == null or battery_element_id <= 0:
		return
	var element := world.get_element(battery_element_id)
	if element == null or not IndustryElectricProfile.is_battery(element):
		return
	var runtime := world.ensure_industry_element_runtime(battery_element_id)
	if runtime.battery_initialized:
		return
	runtime.battery_kwh = IndustryElectricProfile.battery_max_kwh(element)
	runtime.battery_initialized = true


static func mark_battery_charged(
	world: SimulationWorld,
	battery_element_id: int,
	kwh: float = -1.0
) -> void:
	if world == null or battery_element_id <= 0:
		return
	var element := world.get_element(battery_element_id)
	if element == null or not IndustryElectricProfile.is_battery(element):
		return
	var runtime := world.ensure_industry_element_runtime(battery_element_id)
	var max_kwh := IndustryElectricProfile.battery_max_kwh(element)
	if kwh < 0.0:
		runtime.battery_kwh = max_kwh
	else:
		runtime.battery_kwh = clampf(kwh, 0.0, max_kwh)
	runtime.battery_initialized = true


static func nearest_covering_network(
	world: SimulationWorld,
	consumer: SimulationElement,
	networks: Array[Dictionary]
) -> int:
	return _nearest_covering_network(world, consumer, networks)


## A component is "supplied" when it has an enabled operational source or
## battery. Distributors are no longer required for supply itself — they only
## extend it wirelessly to unwired consumers within supply_radius_m.
static func build_component_network(
	world: SimulationWorld,
	component: Array
) -> Dictionary:
	var sources: Array[SimulationElement] = []
	var distributors: Array[SimulationElement] = []
	var batteries: Array[SimulationElement] = []

	for element_id_variant: Variant in component:
		var element := world.get_element(int(element_id_variant))
		if element == null or not element.is_operational():
			continue
		if IndustryElectricProfile.is_power_source(element):
			sources.append(element)
		if IndustryElectricProfile.is_distributor(element):
			distributors.append(element)
		if IndustryElectricProfile.is_battery(element):
			batteries.append(element)

	var enabled_distributors: Array[SimulationElement] = []
	for distributor: SimulationElement in distributors:
		var runtime := world.ensure_industry_element_runtime(distributor.element_id)
		if runtime.machine_enabled:
			enabled_distributors.append(distributor)

	var enabled_sources: Array[SimulationElement] = []
	for source: SimulationElement in sources:
		var runtime := world.ensure_industry_element_runtime(source.element_id)
		if runtime.machine_enabled:
			enabled_sources.append(source)

	var enabled_batteries: Array[SimulationElement] = []
	for battery: SimulationElement in batteries:
		var runtime := world.ensure_industry_element_runtime(battery.element_id)
		if runtime.machine_enabled:
			enabled_batteries.append(battery)

	return {
		"component": component,
		"distributors": enabled_distributors,
		"sources": enabled_sources,
		"batteries": enabled_batteries,
		"consumers": [] as Array[SimulationElement],
		"supplied": (
			not enabled_sources.is_empty()
			or not enabled_batteries.is_empty()
		),
	}


static func _solve_supplied_network(
	world: SimulationWorld,
	network: Dictionary,
	dt: float
) -> void:
	var sources: Array[SimulationElement] = network["sources"]
	var batteries: Array[SimulationElement] = network["batteries"]
	var consumers: Array[SimulationElement] = network["consumers"]

	var raw_supply_w := 0.0
	for source: SimulationElement in sources:
		raw_supply_w += IndustryElectricProfile.output_w(source)

	var raw_demand_w := 0.0
	for consumer: SimulationElement in consumers:
		var runtime := world.ensure_industry_element_runtime(consumer.element_id)
		raw_demand_w += runtime.demand_w(consumer)

	var battery_discharge_w := 0.0
	var deficit_w := maxf(raw_demand_w - raw_supply_w, 0.0)
	if (
		deficit_w > 0.000001
		and _available_battery_discharge_w(world, batteries, dt)
		+ 0.000001 >= deficit_w
	):
		battery_discharge_w = _discharge_batteries(
			world,
			batteries,
			deficit_w,
			dt
		)

	var effective_supply_w := raw_supply_w + battery_discharge_w
	var powered := (
		raw_demand_w <= 0.000001
		or effective_supply_w + 0.000001 >= raw_demand_w
	)

	for consumer: SimulationElement in consumers:
		if powered:
			_set_consumer_power(world, consumer, true, &"ok")
		else:
			_set_consumer_power(world, consumer, false, &"no_power")

	var surplus_w := maxf(effective_supply_w - raw_demand_w, 0.0)
	if surplus_w > 0.000001:
		_charge_batteries(world, batteries, surplus_w, dt)


static func _nearest_covering_network(
	world: SimulationWorld,
	consumer: SimulationElement,
	networks: Array[Dictionary]
) -> int:
	var consumer_position := element_world_position(world, consumer)
	var best_network_index := -1
	var best_distance := INF
	for network_index: int in range(networks.size()):
		var distributors: Array[SimulationElement] = (
			networks[network_index]["distributors"]
		)
		for distributor: SimulationElement in distributors:
			var radius := IndustryElectricProfile.supply_radius_m(distributor)
			var distributor_position := element_world_position(world, distributor)
			var distance := consumer_position.distance_to(distributor_position)
			if (
				distance <= radius + 0.000001
				and distance < best_distance
			):
				best_distance = distance
				best_network_index = network_index
	return best_network_index


static func _available_battery_discharge_w(
	world: SimulationWorld,
	batteries: Array[SimulationElement],
	dt: float
) -> float:
	var available_w := 0.0
	for battery: SimulationElement in batteries:
		var runtime := world.ensure_industry_element_runtime(battery.element_id)
		var available_energy_w := (
			runtime.battery_kwh
			/ maxf(dt * WATTS_TO_KWH_PER_SECOND, 0.000001)
		)
		available_w += minf(
			IndustryElectricProfile.battery_discharge_w(battery),
			available_energy_w
		)
	return available_w


static func _discharge_batteries(
	world: SimulationWorld,
	batteries: Array[SimulationElement],
	deficit_w: float,
	dt: float
) -> float:
	var remaining_deficit := deficit_w
	var discharged_w := 0.0
	for battery: SimulationElement in batteries:
		if remaining_deficit <= 0.000001:
			break
		var runtime := world.ensure_industry_element_runtime(battery.element_id)
		if not runtime.machine_enabled or runtime.battery_kwh <= 0.000001:
			continue
		var max_power_w := IndustryElectricProfile.battery_discharge_w(battery)
		var available_energy_w := (
			runtime.battery_kwh / maxf(dt * WATTS_TO_KWH_PER_SECOND, 0.000001)
		)
		var deliver_w := minf(
			remaining_deficit,
			minf(max_power_w, available_energy_w)
		)
		if deliver_w <= 0.000001:
			continue
		var energy_kwh := deliver_w * dt * WATTS_TO_KWH_PER_SECOND
		runtime.battery_kwh = maxf(runtime.battery_kwh - energy_kwh, 0.0)
		discharged_w += deliver_w
		remaining_deficit -= deliver_w
	return discharged_w


static func _charge_batteries(
	world: SimulationWorld,
	batteries: Array[SimulationElement],
	surplus_w: float,
	dt: float
) -> void:
	var remaining_surplus := surplus_w
	for battery: SimulationElement in batteries:
		if remaining_surplus <= 0.000001:
			break
		var runtime := world.ensure_industry_element_runtime(battery.element_id)
		if not runtime.machine_enabled:
			continue
		var max_kwh := IndustryElectricProfile.battery_max_kwh(battery)
		var headroom_kwh := maxf(max_kwh - runtime.battery_kwh, 0.0)
		if headroom_kwh <= 0.000001:
			continue
		var max_power_w := IndustryElectricProfile.battery_charge_w(battery)
		var deliver_w := minf(remaining_surplus, max_power_w)
		var energy_kwh := deliver_w * dt * WATTS_TO_KWH_PER_SECOND
		if energy_kwh > headroom_kwh + 0.000001:
			deliver_w = headroom_kwh / maxf(dt * WATTS_TO_KWH_PER_SECOND, 0.000001)
			energy_kwh = headroom_kwh
		if deliver_w <= 0.000001:
			continue
		runtime.battery_kwh += energy_kwh
		runtime.battery_initialized = true
		remaining_surplus -= deliver_w


static func _set_consumer_power(
	world: SimulationWorld,
	element: SimulationElement,
	is_powered: bool,
	reason: StringName
) -> void:
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	runtime.powered = is_powered
	runtime.power_reason = reason
