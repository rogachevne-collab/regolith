class_name WheelSimulationService
extends RefCounted


static func discover_pairs(
	world: SimulationWorld,
	assembly_id: int
) -> Array[Dictionary]:
	var pairs: Array[Dictionary] = []
	if world == null:
		return pairs
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return pairs
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element == null or element.archetype_id != "wheel_suspension":
			continue
		var wheel_element_id := _wheel_for_suspension(world, assembly_id, element_id)
		pairs.append(
			_build_pair_record(world, element, wheel_element_id)
		)
	return pairs


static func is_complete_pair(pair: Dictionary) -> bool:
	if pair.is_empty():
		return false
	var wheel_element_id := int(pair.get("wheel_element_id", 0))
	if wheel_element_id <= 0:
		return false
	var suspension: SimulationElement = pair.get("suspension_element")
	var wheel_element: SimulationElement = pair.get("wheel_element")
	if suspension == null or wheel_element == null:
		return false
	return suspension.is_operational() and wheel_element.is_operational()


static func is_locomotive_assembly(
	world: SimulationWorld,
	assembly_id: int
) -> bool:
	for pair: Dictionary in discover_pairs(world, assembly_id):
		if is_complete_pair(pair):
			return true
	return false


static func apply_configure_wheel(
	world: SimulationWorld,
	command: ConfigureWheelCommand
) -> Dictionary:
	if world == null or command == null:
		return {"status": &"failed", "reason": &"not_ready"}
	var element := world.get_element(command.wheel_element_id)
	if element == null or element.archetype_id != "drive_wheel":
		return {"status": &"failed", "reason": &"invalid_reference"}
	if not element.is_operational():
		return {"status": &"failed", "reason": &"element_incomplete"}
	var definition := _wheel_definition_for_element(element)
	if definition == null:
		return {"status": &"failed", "reason": &"invalid_reference"}
	var state := world.ensure_wheel_instance_state(command.wheel_element_id)
	if command.steerable_set:
		state.steerable = command.steerable
	if command.drive_torque_scale >= 0.0:
		if command.drive_torque_scale > 1.0:
			return {"status": &"failed", "reason": &"invalid_reference"}
		state.drive_torque_scale = command.drive_torque_scale
	if command.brake_torque_n_m >= 0.0:
		if command.brake_torque_n_m > definition.brake_torque_n_m:
			return {"status": &"failed", "reason": &"invalid_reference"}
		state.brake_torque_n_m = command.brake_torque_n_m
	return {
		"status": &"ok",
		"reason": &"ok",
		"wheel_element_id": command.wheel_element_id,
	}


static func apply_configure_suspension(
	world: SimulationWorld,
	command: ConfigureSuspensionCommand
) -> Dictionary:
	if world == null or command == null:
		return {"status": &"failed", "reason": &"not_ready"}
	var element := world.get_element(command.suspension_element_id)
	if element == null or element.archetype_id != "wheel_suspension":
		return {"status": &"failed", "reason": &"invalid_reference"}
	if not element.is_operational():
		return {"status": &"failed", "reason": &"element_incomplete"}
	var definition := _suspension_definition_for_element(element)
	if definition == null:
		return {"status": &"failed", "reason": &"invalid_reference"}
	var state := world.ensure_suspension_instance_state(
		command.suspension_element_id
	)
	if command.travel_m >= 0.0:
		if (
			command.travel_m < definition.min_travel_m
			or command.travel_m > definition.max_travel_m
		):
			return {"status": &"failed", "reason": &"invalid_reference"}
		state.travel_m = command.travel_m
	if command.spring_stiffness_n_per_m >= 0.0:
		if command.spring_stiffness_n_per_m < 0.0:
			return {"status": &"failed", "reason": &"invalid_reference"}
		state.spring_stiffness_n_per_m = command.spring_stiffness_n_per_m
	if command.spring_damping_n_s_per_m >= 0.0:
		if command.spring_damping_n_s_per_m < 0.0:
			return {"status": &"failed", "reason": &"invalid_reference"}
		state.spring_damping_n_s_per_m = command.spring_damping_n_s_per_m
	return {
		"status": &"ok",
		"reason": &"ok",
		"suspension_element_id": command.suspension_element_id,
	}


static func tick_assembly(
	world: SimulationWorld,
	body: RigidBody3D,
	assembly_id: int,
	delta: float
) -> void:
	if (
		world == null
		or body == null
		or delta <= 0.0
		or not is_locomotive_assembly(world, assembly_id)
	):
		return
	var locomotion := world.get_locomotion_controller(assembly_id)
	if locomotion.has_active_input():
		body.sleeping = false
	for pair: Dictionary in discover_pairs(world, assembly_id):
		if not is_complete_pair(pair):
			continue
		var tick_pair := _tick_context(world, pair)
		var wheel_element: SimulationElement = pair.get("wheel_element")
		var powered := _is_wheel_powered(world, wheel_element)
		var tick_result := WheelProjectionUtil.tick_pair(
			body,
			tick_pair,
			locomotion,
			delta,
			powered
		)
		world.store_wheel_runtime(
			int(pair.get("wheel_element_id", 0)),
			int(pair.get("suspension_element_id", 0)),
			tick_result
		)


static func _tick_context(
	world: SimulationWorld,
	pair: Dictionary
) -> Dictionary:
	var suspension: SimulationElement = pair.get("suspension_element")
	var wheel_element: SimulationElement = pair.get("wheel_element")
	var suspension_def := _suspension_definition_for_element(suspension)
	var wheel_def := _wheel_definition_for_element(wheel_element)
	var suspension_state := world.ensure_suspension_instance_state(
		suspension.element_id
	)
	var wheel_state := world.ensure_wheel_instance_state(wheel_element.element_id)
	var runtime := world.get_wheel_runtime(wheel_element.element_id)
	var context := pair.duplicate(true)
	context["travel_m"] = (
		suspension_state.travel_m
		if suspension_state.travel_m > 0.0
		else suspension_def.suspension_travel_m
	)
	context["spring_stiffness"] = (
		suspension_state.spring_stiffness_n_per_m
		if suspension_state.spring_stiffness_n_per_m >= 0.0
		else suspension_def.spring_stiffness_n_per_m
	)
	context["spring_damping"] = (
		suspension_state.spring_damping_n_s_per_m
		if suspension_state.spring_damping_n_s_per_m >= 0.0
		else suspension_def.spring_damping_n_s_per_m
	)
	context["radius_m"] = wheel_def.radius_m
	context["drive_torque"] = wheel_def.drive_torque_n_m
	context["brake_torque"] = wheel_def.brake_torque_n_m
	context["longitudinal_grip"] = wheel_def.longitudinal_grip
	context["lateral_grip"] = wheel_def.lateral_grip
	context["slip_stiffness"] = wheel_def.slip_stiffness
	context["lateral_stiffness"] = wheel_def.lateral_stiffness
	context["wheel_inertia"] = wheel_def.wheel_inertia
	context["max_steering_angle_rad"] = wheel_def.max_steering_angle_rad
	context["steering_response"] = wheel_def.steering_response
	context["steerable"] = wheel_state.steerable
	context["drive_torque_scale"] = wheel_state.drive_torque_scale
	if wheel_state.brake_torque_n_m >= 0.0:
		context["configured_brake_torque"] = wheel_state.brake_torque_n_m
	context["wheel_speed"] = float(runtime.get("wheel_speed", 0.0))
	context["steering_angle_rad"] = float(runtime.get("steering_angle_rad", 0.0))
	return context


static func _build_pair_record(
	world: SimulationWorld,
	suspension: SimulationElement,
	wheel_element_id: int
) -> Dictionary:
	var wheel_element := (
		world.get_element(wheel_element_id) if wheel_element_id > 0 else null
	)
	return {
		"suspension_element_id": suspension.element_id,
		"wheel_element_id": wheel_element_id,
		"suspension_element": suspension,
		"wheel_element": wheel_element,
	}


static func _wheel_for_suspension(
	world: SimulationWorld,
	assembly_id: int,
	suspension_element_id: int
) -> int:
	for joint: SimulationJoint in world.list_joints():
		if (
			joint.assembly_id != assembly_id
			or joint.kind != SimulationJoint.Kind.RIGID
		):
			continue
		var other_id := 0
		if joint.element_a_id == suspension_element_id:
			other_id = joint.element_b_id
		elif joint.element_b_id == suspension_element_id:
			other_id = joint.element_a_id
		else:
			continue
		var other := world.get_element(other_id)
		if other != null and other.archetype_id == "drive_wheel":
			return other_id
	return 0


static func _wheel_definition_for_element(
	element: SimulationElement
) -> WheelDefinition:
	var archetype := element.get_archetype() if element != null else null
	if archetype == null:
		return null
	return archetype.wheel_definition


static func _suspension_definition_for_element(
	element: SimulationElement
) -> SuspensionDefinition:
	var archetype := element.get_archetype() if element != null else null
	if archetype == null:
		return null
	return archetype.suspension_definition


static func _is_wheel_powered(
	world: SimulationWorld,
	wheel_element: SimulationElement
) -> bool:
	if wheel_element == null:
		return false
	var runtime := world.ensure_industry_element_runtime(
		wheel_element.element_id
	)
	return runtime.machine_enabled and runtime.powered
