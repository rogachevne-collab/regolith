class_name ThrusterSimulationService
extends RefCounted


static func is_thruster_element(element: SimulationElement) -> bool:
	if element == null or not element.is_operational():
		return false
	var archetype := element.get_archetype()
	return archetype != null and archetype.thruster_definition != null


static func is_gyro_element(element: SimulationElement) -> bool:
	if element == null or not element.is_operational():
		return false
	var archetype := element.get_archetype()
	return archetype != null and archetype.gyro_definition != null


static func is_flight_assembly(
	world: SimulationWorld,
	assembly_id: int
) -> bool:
	if world == null or assembly_id <= 0:
		return false
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return false
	for element_id: int in assembly.element_ids:
		if is_thruster_element(world.get_element(element_id)):
			return true
	return false


static func is_mobile_assembly(
	world: SimulationWorld,
	assembly_id: int
) -> bool:
	return (
		WheelSimulationService.is_locomotive_assembly(world, assembly_id)
		or is_flight_assembly(world, assembly_id)
	)


static func list_thruster_elements(
	world: SimulationWorld,
	assembly_id: int
) -> Array[SimulationElement]:
	var result: Array[SimulationElement] = []
	if world == null:
		return result
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return result
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if is_thruster_element(element):
			result.append(element)
	return result


static func list_gyro_elements(
	world: SimulationWorld,
	assembly_id: int
) -> Array[SimulationElement]:
	var result: Array[SimulationElement] = []
	if world == null:
		return result
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return result
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if is_gyro_element(element):
			result.append(element)
	return result


static func is_element_powered(
	world: SimulationWorld,
	element: SimulationElement
) -> bool:
	if world == null or element == null:
		return false
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	return runtime.machine_enabled and runtime.powered


static func sync_power_demand(world: SimulationWorld) -> void:
	if world == null:
		return
	for element: SimulationElement in world.list_elements():
		var archetype := element.get_archetype()
		if archetype == null:
			continue
		if (
			archetype.thruster_definition == null
			and archetype.gyro_definition == null
		):
			continue
		world.ensure_industry_element_runtime(
			element.element_id
		).dynamic_power_w = 0.0
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly == null or assembly.tombstoned:
			continue
		var locomotion := world.get_locomotion_controller(assembly.assembly_id)
		if not locomotion.is_activated():
			continue
		for thruster: SimulationElement in list_thruster_elements(
			world,
			assembly.assembly_id
		):
			var definition: ThrusterDefinition = (
				thruster.get_archetype().thruster_definition
			)
			var runtime := world.ensure_industry_element_runtime(
				thruster.element_id
			)
			runtime.dynamic_power_w = (
				definition.power_draw_w * locomotion.thrust_command
			)
		var attitude_mag := maxf(
			absf(locomotion.pitch_command),
			maxf(
				absf(locomotion.yaw_command),
				absf(locomotion.roll_command)
			)
		)
		var gyro_load := attitude_mag
		if locomotion.is_dampeners() and attitude_mag <= 0.001:
			gyro_load = 0.25
		for gyro: SimulationElement in list_gyro_elements(
			world,
			assembly.assembly_id
		):
			var gyro_def: GyroDefinition = gyro.get_archetype().gyro_definition
			var gyro_runtime := world.ensure_industry_element_runtime(
				gyro.element_id
			)
			gyro_runtime.dynamic_power_w = gyro_def.power_draw_w * gyro_load


static func activation_clearance_m(
	world: SimulationWorld,
	assembly_id: int
) -> float:
	if WheelSimulationService.is_locomotive_assembly(world, assembly_id):
		return WheelSimulationService.activation_clearance_m(world, assembly_id)
	if is_flight_assembly(world, assembly_id):
		return 0.08
	return 0.0
