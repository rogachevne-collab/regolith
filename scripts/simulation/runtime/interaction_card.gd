class_name InteractionCard
extends RefCounted
## Aim/HUD presentable view for one element (Interaction Read-Model).
## Structure comes from InteractionIndex; live fields refresh in-place O(1).
## In-place card keys for aim/HUD readers; no flatten into InteractionHit.

var element_id := 0
var structure: InteractionStructure = null
## Stable scratch for card readers / tests; mutated in-place on refresh.
var keys: Dictionary = {}


func refresh(world: SimulationWorld, entry: InteractionStructure) -> bool:
	if world == null or entry == null or entry.element_id <= 0:
		clear()
		return false
	var element := world.get_element(entry.element_id)
	if element == null:
		clear()
		return false
	structure = entry
	element_id = entry.element_id
	keys.clear()
	_write_structural(entry)
	_write_live_base(world, element)
	_write_driven_actuator(world, entry)
	_write_wheel_or_suspension(world, entry, element)
	_write_control_seat(world, entry, element)
	_write_recipe_machine_o1(world, element)
	return true


func clear() -> void:
	element_id = 0
	structure = null
	keys.clear()


## KIND_CONTROL_SEAT / enter prompt: structural ControlSeat role AND operational.
## Incomplete or broken seats stay ordinary simulation elements.
static func is_enterable_control_seat(
	world: SimulationWorld,
	element_id: int
) -> bool:
	if world == null or element_id <= 0:
		return false
	var structure := world.get_interaction_structure(element_id)
	if structure == null or not structure.control_seat:
		return false
	var element := world.get_element(element_id)
	return element != null and element.is_operational()


func _write_structural(entry: InteractionStructure) -> void:
	keys["element_id"] = entry.element_id
	keys["assembly_id"] = entry.assembly_id
	keys["archetype_id"] = entry.archetype_id
	if entry.wheel_element_id > 0:
		keys["wheel_element_id"] = entry.wheel_element_id
	if entry.suspension_element_id > 0:
		keys["suspension_element_id"] = entry.suspension_element_id
	for key: Variant in entry.authored.keys():
		keys[key] = entry.authored[key]
	match entry.driven_joint_kind:
		int(SimulationJoint.Kind.PISTON):
			if entry.driven_joint_id > 0:
				keys["piston_joint_id"] = entry.driven_joint_id
		int(SimulationJoint.Kind.ROTOR):
			if entry.driven_joint_id > 0:
				keys["rotor_joint_id"] = entry.driven_joint_id
		int(SimulationJoint.Kind.HINGE):
			if entry.driven_joint_id > 0:
				keys["hinge_joint_id"] = entry.driven_joint_id


func _write_live_base(world: SimulationWorld, element: SimulationElement) -> void:
	keys["integrity"] = element.integrity
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	keys["machine_enabled"] = runtime.machine_enabled
	if runtime.display_ready:
		keys["status_reason"] = runtime.display_status_reason
	else:
		keys["status_reason"] = _cheap_status_reason(world, element, runtime)


func _cheap_status_reason(
	world: SimulationWorld,
	element: SimulationElement,
	runtime: IndustryElementRuntime
) -> StringName:
	## O(1) fallback before first industry display sync (non-recipe / pre-tick).
	var structural := element.status_reason()
	if structural != &"ok":
		return structural
	if not element.is_operational():
		return structural
	if not runtime.machine_enabled:
		return &"disabled"
	var functional := element.industry_status_reason()
	if functional != &"ok":
		if (
			functional == &"port_disconnected"
			and IndustryElectricProfile.is_power_consumer(element)
			and not runtime.powered
			and runtime.power_reason == &"port_disconnected"
		):
			return &"electric_disconnected"
		return functional
	if IndustryElectricProfile.is_power_consumer(element):
		var reason := runtime.power_reason
		if reason == &"":
			return &"ok"
		if runtime.powered and reason == &"ok":
			return &"ok"
		return reason
	return &"ok"


func _write_driven_actuator(
	world: SimulationWorld,
	entry: InteractionStructure
) -> void:
	if entry.driven_joint_id <= 0:
		return
	var joint := world.get_joint(entry.driven_joint_id)
	if joint == null or joint.motor == null or not joint.is_driven():
		return
	var motor := joint.motor
	# Phase 2c: observed pose/status from DisplayPose; tune/limits from motor O(1).
	var actuator_status: StringName = (
		entry.display_actuator_status
		if entry.display_actuator_status != &""
		else _motor_status_name(motor.status)
	)
	var observed_pose := (
		entry.display_pose_m
		if entry.display_actuator_status != &""
		else motor.observed_position_m
	)
	keys["actuator_status"] = actuator_status
	var status_reason := StringName(keys.get("status_reason", &"ok"))
	if status_reason in [&"ok", &"standby"]:
		keys["status_reason"] = actuator_status
	var powered := _joint_base_powered(world, joint.element_a_id)
	match joint.kind:
		SimulationJoint.Kind.PISTON:
			keys["piston_joint_id"] = joint.joint_id
			keys["piston_observed_position_m"] = observed_pose
			keys["piston_target_position_m"] = _display_target_position_m(motor)
			keys["piston_lower_limit_m"] = motor.lower_limit_m
			keys["piston_upper_limit_m"] = motor.upper_limit_m
			keys["piston_force_limit_n"] = motor.force_limit_n
			keys["piston_extend_velocity_mps"] = motor.extend_velocity_mps
			keys["piston_retract_velocity_mps"] = motor.retract_velocity_mps
			keys["piston_target_velocity_mps"] = motor.clamp_target_velocity()
			keys["piston_powered"] = powered
			keys["piston_motor_enabled"] = motor.enabled
		SimulationJoint.Kind.ROTOR:
			keys["rotor_joint_id"] = joint.joint_id
			keys["rotor_observed_angle_rad"] = observed_pose
			keys["rotor_target_velocity_rad_s"] = motor.clamp_target_velocity()
			keys["rotor_forward_velocity_rad_s"] = motor.extend_velocity_mps
			keys["rotor_reverse_velocity_rad_s"] = motor.retract_velocity_mps
			keys["rotor_torque_limit_nm"] = motor.force_limit_n
			keys["rotor_powered"] = powered
			keys["rotor_motor_enabled"] = motor.enabled
		SimulationJoint.Kind.HINGE:
			keys["hinge_joint_id"] = joint.joint_id
			keys["hinge_observed_angle_rad"] = observed_pose
			keys["hinge_target_velocity_rad_s"] = motor.clamp_target_velocity()
			keys["hinge_forward_velocity_rad_s"] = motor.extend_velocity_mps
			keys["hinge_reverse_velocity_rad_s"] = motor.retract_velocity_mps
			keys["hinge_torque_limit_nm"] = motor.force_limit_n
			keys["hinge_lower_limit_rad"] = motor.lower_limit_m
			keys["hinge_upper_limit_rad"] = motor.upper_limit_m
			keys["hinge_powered"] = powered
			keys["hinge_motor_enabled"] = motor.enabled


func _write_wheel_or_suspension(
	world: SimulationWorld,
	entry: InteractionStructure,
	element: SimulationElement
) -> void:
	if entry.wheel_element_id > 0:
		_write_wheel(world, element)
	elif entry.suspension_element_id > 0:
		_write_suspension(world, element)


func _write_wheel(world: SimulationWorld, element: SimulationElement) -> void:
	var definition := element.get_archetype().wheel_definition
	if definition == null:
		return
	var state := world.ensure_wheel_instance_state(element.element_id)
	keys["wheel_element_id"] = element.element_id
	keys["wheel_steerable"] = state.steerable
	keys["wheel_drive_torque_scale"] = state.drive_torque_scale
	keys["wheel_grip_scale"] = state.grip_scale
	keys["wheel_brake_torque_n_m"] = (
		state.brake_torque_n_m
		if state.brake_torque_n_m >= 0.0
		else definition.brake_torque_n_m
	)
	keys["wheel_max_brake_torque_n_m"] = definition.brake_torque_n_m
	keys["wheel_max_steering_angle_rad"] = (
		state.max_steering_angle_rad
		if state.max_steering_angle_rad >= 0.0
		else definition.max_steering_angle_rad
	)
	keys["wheel_authored_max_steering_angle_rad"] = (
		definition.max_steering_angle_rad
	)
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	keys["wheel_powered"] = runtime.machine_enabled and runtime.powered
	var wheel_runtime := world.get_wheel_runtime(element.element_id)
	keys["wheel_status"] = StringName(
		wheel_runtime.get("status", runtime.power_reason)
	)


func _write_suspension(
	world: SimulationWorld,
	element: SimulationElement
) -> void:
	var definition := element.get_archetype().suspension_definition
	if definition == null:
		return
	var state := world.ensure_suspension_instance_state(element.element_id)
	keys["suspension_element_id"] = element.element_id
	keys["suspension_travel_m"] = (
		state.travel_m
		if state.travel_m > 0.0
		else definition.suspension_travel_m
	)
	keys["suspension_spring_stiffness_n_per_m"] = (
		state.spring_stiffness_n_per_m
		if state.spring_stiffness_n_per_m >= 0.0
		else definition.spring_stiffness_n_per_m
	)
	keys["suspension_spring_damping_n_s_per_m"] = (
		state.spring_damping_n_s_per_m
		if state.spring_damping_n_s_per_m >= 0.0
		else definition.spring_damping_n_s_per_m
	)
	keys["suspension_min_travel_m"] = definition.min_travel_m
	keys["suspension_max_travel_m"] = definition.max_travel_m


func _write_control_seat(
	world: SimulationWorld,
	entry: InteractionStructure,
	element: SimulationElement
) -> void:
	## Drop: seat_offset / locomotive / flight / mobile — gateway recomputes.
	if is_enterable_control_seat(world, element.element_id):
		keys["control_seat"] = true
	if not entry.control_seat:
		return
	## Routing flags via card keys — UI must not read seat side-table directly.
	## Shared ref / defaults — no alloc, no ensure (same as action bar has_).
	var policy := world.get_seat_control_state_ref(element.element_id)
	keys["control_wheels"] = policy.control_wheels
	keys["control_thrusters"] = policy.control_thrusters
	keys["control_gyros"] = policy.control_gyros


func _write_recipe_machine_o1(
	world: SimulationWorld,
	element: SimulationElement
) -> void:
	if not IndustryArchetypeProfile.is_recipe_machine(element.archetype_id):
		return
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	var machine := runtime.ensure_machine_state()
	keys["active_recipe_id"] = machine.active_recipe_id
	keys["recipe_queue"] = machine.queue.duplicate()
	keys["recipe_progress_s"] = machine.progress_s
	var duration_s := (
		RecipeCatalog.duration_s(machine.active_recipe_id)
		if not machine.active_recipe_id.is_empty()
		else 0.0
	)
	keys["recipe_duration_s"] = duration_s
	## Phase 2b: cargo/missing only from tick-written display_* (never graph here).
	if runtime.display_ready:
		keys["missing_input_resource_id"] = runtime.display_missing_input_resource_id
		keys["cargo_network_connected"] = runtime.display_cargo_network_connected
		keys["cargo_network_ore_mare_regolith"] = (
			runtime.display_cargo_network_ore_mare_regolith
		)
		keys["cargo_network_regolith_fines"] = (
			runtime.display_cargo_network_regolith_fines
		)


static func _joint_base_powered(world: SimulationWorld, base_element_id: int) -> bool:
	var runtime := world.get_industry_element_runtime(base_element_id)
	if runtime == null:
		return false
	return runtime.powered and runtime.machine_enabled


static func _display_target_position_m(motor: SimulationMotorState) -> float:
	match motor.control_mode:
		SimulationMotorState.ControlMode.POSITION:
			return motor.clamp_target_position()
		SimulationMotorState.ControlMode.VELOCITY:
			if motor.clamp_target_velocity() >= 0.0:
				return motor.upper_limit_m
			return motor.lower_limit_m
	return motor.observed_position_m


## Local status tokens — avoid ActuatorSimulationService load cycle.
static func _motor_status_name(status: SimulationMotorState.Status) -> StringName:
	match status:
		SimulationMotorState.Status.ELEMENT_INCOMPLETE:
			return &"element_incomplete"
		SimulationMotorState.Status.NO_POWER:
			return &"no_power"
		SimulationMotorState.Status.OVERLOADED:
			return &"overloaded"
		SimulationMotorState.Status.STUCK:
			return &"stuck"
		SimulationMotorState.Status.JOINT_LIMIT:
			return &"joint_limit"
		SimulationMotorState.Status.MOVING:
			return &"moving"
		_:
			return &"idle"
