class_name VehiclePowerSnapshotBuilder
extends RefCounted
## Read-only cabin power model for seated transport HUD.
## Aggregates assembly batteries + the electric component that feeds the
## vehicle's consumers. Does not mutate charge; may refresh transient
## `dynamic_power_w` via the same sync path the budget tick uses.

const WATTS_TO_KWH_PER_SECOND := 1.0 / 3600000.0
const ETA_INFINITE := -1.0


static func build(world: SimulationWorld, assembly_id: int) -> Dictionary:
	if world == null:
		return failure(&"not_ready")
	if assembly_id <= 0:
		return failure(&"invalid_assembly")
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return failure(&"invalid_assembly")

	WheelSimulationService.sync_power_demand(world)
	ActuatorSimulationService.sync_power_demand(world)
	ThrusterSimulationService.sync_power_demand(world)

	var battery_kwh := 0.0
	var battery_max_kwh := 0.0
	var battery_ids: Array[int] = []
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if (
			element == null
			or not element.is_operational()
			or not IndustryElectricProfile.is_battery(element)
		):
			continue
		var runtime := world.ensure_industry_element_runtime(element_id)
		if not runtime.machine_enabled:
			continue
		battery_ids.append(element_id)
		battery_kwh += maxf(runtime.battery_kwh, 0.0)
		battery_max_kwh += IndustryElectricProfile.battery_max_kwh(element)

	var network := _resolve_assembly_network(world, assembly)
	var source_w := float(network.get("source_w", 0.0))
	var demand_w := float(network.get("demand_w", 0.0))
	var consumers_powered := bool(network.get("consumers_powered", false))
	var power_reason: StringName = network.get("power_reason", &"ok")

	var net_drain_w := maxf(demand_w - source_w, 0.0)
	var eta_s := ETA_INFINITE
	if net_drain_w > 0.000001 and battery_kwh > 0.000001:
		eta_s = battery_kwh / (net_drain_w * WATTS_TO_KWH_PER_SECOND)
	elif battery_kwh <= 0.000001 and net_drain_w > 0.000001:
		eta_s = 0.0

	var fraction := 0.0
	if battery_max_kwh > 0.000001:
		fraction = clampf(battery_kwh / battery_max_kwh, 0.0, 1.0)

	return {
		"valid": true,
		"assembly_id": assembly_id,
		"battery_kwh": battery_kwh,
		"battery_max_kwh": battery_max_kwh,
		"battery_fraction": fraction,
		"battery_count": battery_ids.size(),
		"source_w": source_w,
		"demand_w": demand_w,
		"net_drain_w": net_drain_w,
		"eta_s": eta_s,
		"powered": consumers_powered,
		"power_reason": power_reason,
	}


static func failure(reason: StringName = &"invalid_assembly") -> Dictionary:
	return {
		"valid": false,
		"reason": reason,
		"battery_fraction": 0.0,
		"battery_kwh": 0.0,
		"battery_max_kwh": 0.0,
		"source_w": 0.0,
		"demand_w": 0.0,
		"net_drain_w": 0.0,
		"eta_s": ETA_INFINITE,
		"powered": false,
		"power_reason": reason,
	}


static func format_eta_s(eta_s: float) -> String:
	if eta_s < 0.0:
		return "∞"
	if eta_s < 0.5:
		return "0с"
	var total := int(round(eta_s))
	@warning_ignore("integer_division")
	var hours := total / 3600
	@warning_ignore("integer_division")
	var minutes := (total % 3600) / 60
	var seconds := total % 60
	if hours > 0:
		return "%dч %02dм" % [hours, minutes]
	if minutes > 0:
		return "%dм %02dс" % [minutes, seconds]
	return "%dс" % seconds


static func _resolve_assembly_network(
	world: SimulationWorld,
	assembly: SimulationAssembly
) -> Dictionary:
	var graph := world.get_industry_network().ensure_graph_current(world)
	var consumers: Array[SimulationElement] = []
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if (
			element == null
			or not element.is_operational()
			or not IndustryElectricProfile.is_power_consumer(element)
		):
			continue
		var runtime := world.ensure_industry_element_runtime(element_id)
		if runtime.machine_enabled:
			consumers.append(element)

	if consumers.is_empty():
		return {
			"source_w": 0.0,
			"demand_w": 0.0,
			"consumers_powered": true,
			"power_reason": &"ok",
		}

	var supplied_networks: Array[Dictionary] = []
	for component: Array in graph.components():
		var component_network := IndustryElectricBudget.build_component_network(
			world,
			component
		)
		if bool(component_network["supplied"]):
			supplied_networks.append(component_network)

	var demand_w := 0.0
	var source_w := 0.0
	var any_powered := false
	var any_unpowered := false
	var worst_reason: StringName = &"ok"

	for consumer: SimulationElement in consumers:
		var runtime := world.ensure_industry_element_runtime(consumer.element_id)
		demand_w += runtime.demand_w(consumer)
		if runtime.powered:
			any_powered = true
		else:
			any_unpowered = true
			if worst_reason == &"ok":
				worst_reason = runtime.power_reason

		var radius_index := IndustryElectricBudget.nearest_covering_network(
			world,
			consumer,
			supplied_networks
		)
		if radius_index < 0:
			continue
		var network: Dictionary = supplied_networks[radius_index]
		var network_source_w := 0.0
		for source: SimulationElement in network["sources"]:
			network_source_w += IndustryElectricProfile.output_w(source)
		# Prefer the strongest covering supply (rovers usually have one).
		source_w = maxf(source_w, network_source_w)

	var consumers_powered := any_powered and not any_unpowered
	if consumers.is_empty():
		consumers_powered = true
	elif not any_powered and any_unpowered:
		consumers_powered = false

	return {
		"source_w": source_w,
		"demand_w": demand_w,
		"consumers_powered": consumers_powered,
		"power_reason": worst_reason if not consumers_powered else &"ok",
	}
