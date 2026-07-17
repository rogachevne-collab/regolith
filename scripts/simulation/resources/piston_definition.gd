class_name PistonDefinition
extends Resource

@export var head_archetype_id: String = ""
@export var axis_face: OrientationUtil.Face = OrientationUtil.Face.POS_Y
@export var retracted_offset_m: float = 0.0
@export var lower_limit_m: float = 0.0
@export var upper_limit_m: float = 2.0
@export var default_speed_limit_mps: float = 0.25
@export var extend_velocity_mps: float = 0.25
@export var retract_velocity_mps: float = 0.25
@export var force_limit_n: float = 5000.0
@export var max_velocity_mps: float = 5.0
@export var max_force_limit_n: float = 100000.0
@export var stiffness_n_per_m: float = 8000.0
@export var damping_n_s_per_m: float = 400.0
@export var power_draw_w: float = 1500.0
@export var overload_policy: SimulationMotorState.OverloadPolicy = (
	SimulationMotorState.OverloadPolicy.STOP
)


func head_axis_offset_cell() -> Vector3i:
	return OrientationUtil.face_to_vector(axis_face)


func validate(
	base_archetype: ElementArchetype,
	head_archetype: ElementArchetype
) -> Array[String]:
	var errors := validate_base_archetype(base_archetype)
	if head_archetype == null:
		errors.append("head archetype is missing")
	elif not head_archetype.internal_archetype:
		errors.append("head archetype must be internal")
	else:
		var _base_cells := _footprint_set(base_archetype)
		var head_cells := _footprint_set(head_archetype)
		var offset := head_axis_offset_cell()
		for base_cell: Vector3i in base_archetype.footprint_cells:
			if head_cells.has(_cell_key(base_cell + offset)):
				errors.append("base and head home footprints overlap")
		var carriage_ports := 0
		for port: PortDefinition in head_archetype.ports:
			if (
				port != null
				and port.port_id == SimulationMotorState.PISTON_CARRIAGE_PORT
			):
				carriage_ports += 1
		if carriage_ports != 1:
			errors.append(
				"piston head must expose exactly one piston_carriage port"
			)
	return errors


func validate_base_archetype(base_archetype: ElementArchetype) -> Array[String]:
	var errors: Array[String] = []
	if head_archetype_id.is_empty():
		errors.append("head_archetype_id is empty")
	if lower_limit_m < 0.0 or upper_limit_m <= lower_limit_m:
		errors.append("invalid piston travel limits")
	if (
		retracted_offset_m < lower_limit_m - 0.0001
		or retracted_offset_m > upper_limit_m + 0.0001
	):
		errors.append("retracted offset outside travel limits")
	if (
		default_speed_limit_mps < 0.0
		or extend_velocity_mps < 0.0
		or retract_velocity_mps < 0.0
		or force_limit_n <= 0.0
		or max_velocity_mps <= 0.0
		or max_force_limit_n <= 0.0
		or stiffness_n_per_m < 0.0
		or damping_n_s_per_m < 0.0
		or power_draw_w < 0.0
	):
		errors.append("piston motor tuning must be non-negative")
	if overload_policy != SimulationMotorState.OverloadPolicy.STOP:
		errors.append("unsupported overload policy")
	if base_archetype == null:
		errors.append("base archetype is missing")
	else:
		var drive_ports := 0
		for port: PortDefinition in base_archetype.ports:
			if port != null and port.port_id == SimulationMotorState.PISTON_DRIVE_PORT:
				drive_ports += 1
		if drive_ports != 1:
			errors.append("piston base must expose exactly one piston_drive port")
	return errors


static func _footprint_set(archetype: ElementArchetype) -> Dictionary:
	var cells: Dictionary = {}
	for cell: Vector3i in archetype.footprint_cells:
		cells[_cell_key(cell)] = true
	return cells


static func _cell_key(cell: Vector3i) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]
