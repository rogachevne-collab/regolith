class_name PistonProjectionUtil
extends RefCounted

const POSITION_ARRIVE_EPSILON_M := 0.005
const STOP_BRAKE_DAMPING_SCALE := 3.0
const VELOCITY_RESPONSE_TIME_S := 0.15
const MIN_CARRIAGE_MASS_KG := 0.001


static func build_collision_shapes_for_elements(
	world,
	assembly: SimulationAssembly,
	element_ids: Array[int]
) -> Array[Dictionary]:
	var allowed: Dictionary = {}
	for element_id: int in element_ids:
		allowed[element_id] = true
	var records: Array[Dictionary] = []
	for record: Dictionary in ColliderProjectionUtil.build_collision_shapes(
		world,
		assembly
	):
		if allowed.has(int(record.get("element_id", 0))):
			records.append(record)
	return records


static func dry_mass_for_elements(world, element_ids: Array[int]) -> float:
	var total := 0.0
	for element_id: int in element_ids:
		var element: SimulationElement = world.get_element(element_id)
		if element != null:
			total += element.total_mass_kg(world)
	return total


static func carriage_mass_kg(
	world: SimulationWorld,
	carriage_element_ids: Array
) -> float:
	var element_ids: Array[int] = []
	for element_id_variant: Variant in carriage_element_ids:
		element_ids.append(int(element_id_variant))
	return maxf(dry_mass_for_elements(world, element_ids), MIN_CARRIAGE_MASS_KG)


static func center_of_mass_local_for_records(
	records: Array[Dictionary]
) -> Vector3:
	if records.is_empty():
		return Vector3.ZERO
	var weighted := Vector3.ZERO
	var total_volume := 0.0
	for record: Dictionary in records:
		var shape: Shape3D = record["shape"]
		var local_transform: Transform3D = record["local_transform"]
		var volume := _shape_volume_m3(shape)
		if volume <= 0.0:
			continue
		weighted += local_transform.origin * volume
		total_volume += volume
	if total_volume <= 0.0:
		return Vector3.ZERO
	return weighted / total_volume


static func _shape_volume_m3(shape: Shape3D) -> float:
	if shape is BoxShape3D:
		var box := shape as BoxShape3D
		return box.size.x * box.size.y * box.size.z
	if shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		return PI * cylinder.radius * cylinder.radius * cylinder.height
	return 0.0


static func port_anchor_assembly_local(
	element: SimulationElement,
	port_id: String
) -> Vector3:
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null:
		return element_center_assembly_local(element)
	for port: PortDefinition in archetype.ports:
		if port == null or port.port_id != port_id:
			continue
		var face_vec: Vector3i = OrientationUtil.rotate_direction(
			OrientationUtil.face_to_vector(port.local_face),
			element.orientation_index
		)
		var world_cell: Vector3i = (
			element.origin_cell
			+ OrientationUtil.rotate_cell(port.local_cell, element.orientation_index)
		)
		return (
			GridMetric.cell_center_meters(world_cell)
			+ Vector3(face_vec) * GridMetric.HALF_CELL_SIZE_M
		)
	return element_center_assembly_local(element)


static func element_center_assembly_local(element: SimulationElement) -> Vector3:
	return ColliderProjectionUtil.element_center_of_mass_local(element)


static func piston_axis_assembly_local(
	base_element: SimulationElement,
	definition: PistonDefinition
) -> Vector3:
	var axis_cell: Vector3i = OrientationUtil.rotate_cell(
		definition.head_axis_offset_cell(),
		base_element.orientation_index
	)
	return Vector3(axis_cell).normalized()


static func basis_from_axis(axis: Vector3) -> Basis:
	var y_axis := axis.normalized()
	if y_axis.length_squared() <= 0.000001:
		return Basis.IDENTITY
	var x_axis := y_axis.cross(Vector3.UP)
	if x_axis.length_squared() <= 0.000001:
		x_axis = y_axis.cross(Vector3.RIGHT)
	x_axis = x_axis.normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)


static func measure_axial_state(
	base_body: PhysicsBody3D,
	head_body: PhysicsBody3D,
	base_anchor_local: Vector3,
	head_anchor_local: Vector3,
	axis_world: Vector3
) -> Dictionary:
	var axis := axis_world.normalized()
	var base_anchor_world: Vector3 = base_body.to_global(base_anchor_local)
	var head_anchor_world: Vector3 = head_body.to_global(head_anchor_local)
	var extension_m := (head_anchor_world - base_anchor_world).dot(axis)
	var relative_velocity_mps := (
		(head_body as RigidBody3D).linear_velocity
		- (base_body as RigidBody3D).linear_velocity
	).dot(axis) if (
		base_body is RigidBody3D and head_body is RigidBody3D
	) else 0.0
	return {
		"extension_m": extension_m,
		"relative_velocity_mps": relative_velocity_mps,
	}


static func desired_axial_velocity_mps(motor: SimulationMotorState) -> float:
	match motor.control_mode:
		SimulationMotorState.ControlMode.POSITION:
			var error := motor.position_error()
			if absf(error) <= POSITION_ARRIVE_EPSILON_M:
				return 0.0
			var direction := signf(error)
			return direction * motor.velocity_limit_for_sign(direction)
		SimulationMotorState.ControlMode.VELOCITY:
			return motor.clamp_target_velocity()
	return 0.0


static func effective_desired_axial_velocity_mps(
	motor: SimulationMotorState,
	mass_kg: float,
	axis_world: Vector3,
	gravity: Vector3
) -> float:
	var commanded := desired_axial_velocity_mps(motor)
	if commanded == 0.0:
		return 0.0
	var motion_sign := signf(commanded)
	var nominal_abs := absf(commanded)
	var hold_n := axial_load_hold_force_n(
		mass_kg,
		axis_world,
		gravity
	)
	var motion_budget := motor.force_limit_n
	if motion_sign > 0.0:
		motion_budget -= maxf(hold_n, 0.0)
	else:
		motion_budget -= maxf(-hold_n, 0.0)
	if motion_budget <= 0.0:
		return 0.0
	var effective_mass := maxf(mass_kg, MIN_CARRIAGE_MASS_KG)
	var denom := motor.damping_n_s_per_m + (
		effective_mass / maxf(VELOCITY_RESPONSE_TIME_S, 0.0001)
	)
	if denom <= 0.0001:
		return commanded
	var velocity_cap := motion_budget / denom
	return motion_sign * minf(nominal_abs, velocity_cap)


static func axial_load_hold_force_n(
	mass_kg: float,
	axis_world: Vector3,
	gravity: Vector3
) -> float:
	if mass_kg <= 0.0 or axis_world.length_squared() <= 0.000001:
		return 0.0
	return -mass_kg * gravity.dot(axis_world.normalized())


static func compute_motor_force_scalar(
	motor: SimulationMotorState,
	observed_velocity_mps: float,
	powered: bool,
	mass_kg: float = 0.0,
	axis_world: Vector3 = Vector3.ZERO,
	gravity: Vector3 = Vector3.ZERO
) -> Dictionary:
	if motor == null or not powered or not motor.enabled:
		return {"force_n": 0.0, "saturated": false}
	if motor.status == SimulationMotorState.Status.OVERLOADED:
		return {"force_n": 0.0, "saturated": false}
	var desired_velocity_mps := 0.0
	if motor.control_mode == SimulationMotorState.ControlMode.STOP:
		desired_velocity_mps = 0.0
	else:
		desired_velocity_mps = effective_desired_axial_velocity_mps(
			motor,
			mass_kg,
			axis_world,
			gravity
		)
	var brake_hold := motor.control_mode == SimulationMotorState.ControlMode.STOP
	var ideal_force_n := _ideal_motor_force_n(
		motor,
		observed_velocity_mps,
		desired_velocity_mps,
		mass_kg,
		axis_world,
		gravity,
		brake_hold
	)
	var saturated := absf(ideal_force_n) >= motor.force_limit_n - 0.001
	var force_n := clampf(
		ideal_force_n,
		-motor.force_limit_n,
		motor.force_limit_n
	)
	return {
		"force_n": force_n,
		"saturated": saturated,
	}


static func _ideal_motor_force_n(
	motor: SimulationMotorState,
	observed_velocity_mps: float,
	desired_velocity_mps: float,
	mass_kg: float,
	axis_world: Vector3,
	gravity: Vector3,
	brake_hold: bool
) -> float:
	var effective_mass := maxf(mass_kg, MIN_CARRIAGE_MASS_KG)
	var velocity_error := desired_velocity_mps - observed_velocity_mps
	var response_time := VELOCITY_RESPONSE_TIME_S
	if brake_hold:
		response_time /= STOP_BRAKE_DAMPING_SCALE
	var desired_accel := velocity_error / maxf(response_time, 0.0001)
	var hold_n := axial_load_hold_force_n(
		mass_kg,
		axis_world,
		gravity
	)
	var damping_n := motor.damping_n_s_per_m * observed_velocity_mps
	return effective_mass * desired_accel + hold_n + damping_n


static func _compute_velocity_tracking_force(
	motor: SimulationMotorState,
	observed_velocity_mps: float,
	desired_velocity_mps: float,
	mass_kg: float,
	brake_hold: bool
) -> Dictionary:
	var ideal_force_n := _ideal_motor_force_n(
		motor,
		observed_velocity_mps,
		desired_velocity_mps,
		mass_kg,
		Vector3.ZERO,
		Vector3.ZERO,
		brake_hold
	)
	var saturated := absf(ideal_force_n) >= motor.force_limit_n - 0.001
	var force_n := clampf(
		ideal_force_n,
		-motor.force_limit_n,
		motor.force_limit_n
	)
	return {"force_n": force_n, "saturated": saturated}


## Default SE-like angular compliance when definition is unavailable.
const DEFAULT_ANGULAR_SOFT_LIMIT_RAD := 0.12
const DEFAULT_ANGULAR_STIFFNESS_NM_PER_RAD := 18000.0
const DEFAULT_ANGULAR_DAMPING_NM_S_PER_RAD := 600.0


## Godot Generic6DOFJoint3D linear limits are relative to the body poses at
## joint creation. `bind_extension_m` is the absolute travel-from-home at that
## moment so motor [lower, upper] stay absolute across reprojection.
static func configure_slider_joint(
	joint: Generic6DOFJoint3D,
	motor: SimulationMotorState,
	compliance: Dictionary = {},
	lock_extension_m: float = NAN,
	bind_extension_m: float = 0.0
) -> void:
	for axis: String in ["x", "z"]:
		joint.set("linear_limit_%s/enabled" % axis, true)
		joint.set("linear_limit_%s/lower_distance" % axis, 0.0)
		joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
	joint.set("linear_limit_y/enabled", true)
	var lower_abs := motor.lower_limit_m
	var upper_abs := motor.upper_limit_m
	if is_finite(lock_extension_m):
		var locked := clampf(lock_extension_m, lower_abs, upper_abs)
		lower_abs = locked
		upper_abs = locked
	joint.set(
		"linear_limit_y/lower_distance",
		lower_abs - bind_extension_m
	)
	joint.set(
		"linear_limit_y/upper_distance",
		upper_abs - bind_extension_m
	)
	# Soft angular cone + springs (Jolt supports springs; *_limit_*/softness
	# is unsupported in the built-in module — do not set those).
	var soft_limit := float(
		compliance.get("soft_limit_rad", DEFAULT_ANGULAR_SOFT_LIMIT_RAD)
	)
	var stiffness := float(
		compliance.get(
			"stiffness_nm_per_rad",
			DEFAULT_ANGULAR_STIFFNESS_NM_PER_RAD
		)
	)
	var damping := float(
		compliance.get(
			"damping_nm_s_per_rad",
			DEFAULT_ANGULAR_DAMPING_NM_S_PER_RAD
		)
	)
	soft_limit = maxf(soft_limit, 0.0)
	for axis: String in ["x", "y", "z"]:
		joint.set("angular_limit_%s/enabled" % axis, true)
		joint.set("angular_limit_%s/lower_angle" % axis, -soft_limit)
		joint.set("angular_limit_%s/upper_angle" % axis, soft_limit)
		joint.set("angular_spring_%s/enabled" % axis, soft_limit > 0.0)
		joint.set("angular_spring_%s/equilibrium_point" % axis, 0.0)
		joint.set("angular_spring_%s/stiffness" % axis, stiffness)
		joint.set("angular_spring_%s/damping" % axis, damping)


static func compliance_from_definition(definition: PistonDefinition) -> Dictionary:
	if definition == null:
		return {}
	return definition.angular_compliance()


## Soft SE-like flex only while the piston can hold load (powered + complete).
## Incomplete / unpowered → hard angular lock so heavy carriages do not flop.
static func runtime_angular_compliance(
	definition: PistonDefinition,
	allow_flex: bool
) -> Dictionary:
	var compliance := compliance_from_definition(definition)
	if allow_flex:
		return compliance
	var locked := compliance.duplicate()
	locked["soft_limit_rad"] = 0.0
	return locked


static func is_piston_powered(
	world: SimulationWorld,
	base_element_id: int
) -> bool:
	var runtime := world.get_industry_element_runtime(base_element_id)
	if runtime == null:
		return false
	return runtime.powered and runtime.machine_enabled
