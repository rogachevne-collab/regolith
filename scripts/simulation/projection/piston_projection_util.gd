class_name PistonProjectionUtil
extends RefCounted

const POSITION_RESPONSE_SCALE := 2.0


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


static func center_of_mass_local_for_records(
	records: Array[Dictionary]
) -> Vector3:
	if records.is_empty():
		return Vector3.ZERO
	var weighted := Vector3.ZERO
	var total_volume := 0.0
	for record: Dictionary in records:
		var shape: BoxShape3D = record["shape"]
		var local_transform: Transform3D = record["local_transform"]
		var volume: float = shape.size.x * shape.size.y * shape.size.z
		if volume <= 0.0:
			continue
		weighted += local_transform.origin * volume
		total_volume += volume
	if total_volume <= 0.0:
		return Vector3.ZERO
	return weighted / total_volume


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


static func compute_motor_force_scalar(
	motor: SimulationMotorState,
	observed_velocity_mps: float,
	powered: bool
) -> Dictionary:
	if motor == null or not powered or not motor.enabled:
		return {"force_n": 0.0, "saturated": false}
	if motor.status == SimulationMotorState.Status.OVERLOADED:
		return {"force_n": 0.0, "saturated": false}
	var desired_velocity_mps := 0.0
	match motor.control_mode:
		SimulationMotorState.ControlMode.POSITION:
			var response_gain := POSITION_RESPONSE_SCALE
			desired_velocity_mps = clampf(
				motor.position_error() * response_gain,
				-motor.speed_limit_mps,
				motor.speed_limit_mps
			)
		SimulationMotorState.ControlMode.VELOCITY:
			desired_velocity_mps = motor.clamp_target_velocity()
		_:
			return {"force_n": 0.0, "saturated": false}
	var force_n := (
		motor.stiffness_n_per_m * motor.position_error()
		+ motor.damping_n_s_per_m
		* (desired_velocity_mps - observed_velocity_mps)
	)
	var saturated := absf(force_n) >= motor.force_limit_n - 0.001
	force_n = clampf(force_n, -motor.force_limit_n, motor.force_limit_n)
	return {"force_n": force_n, "saturated": saturated}


static func configure_slider_joint(
	joint: Generic6DOFJoint3D,
	motor: SimulationMotorState
) -> void:
	for axis: String in ["x", "z"]:
		joint.set("linear_limit_%s/enabled" % axis, true)
		joint.set("linear_limit_%s/lower_distance" % axis, 0.0)
		joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
	joint.set("linear_limit_y/enabled", true)
	joint.set("linear_limit_y/lower_distance", motor.lower_limit_m)
	joint.set("linear_limit_y/upper_distance", motor.upper_limit_m)
	for axis: String in ["x", "y", "z"]:
		joint.set("angular_limit_%s/enabled" % axis, true)
		joint.set("angular_limit_%s/lower_angle" % axis, 0.0)
		joint.set("angular_limit_%s/upper_angle" % axis, 0.0)


static func is_piston_powered(
	world: SimulationWorld,
	base_element_id: int
) -> bool:
	var runtime := world.get_industry_element_runtime(base_element_id)
	if runtime == null:
		return false
	return runtime.powered and runtime.machine_enabled
