class_name RotorDefinition
extends Resource

@export var top_archetype_id: String = ""
@export var axis_face: OrientationUtil.Face = OrientationUtil.Face.POS_Y
@export var top_offset_cells: int = 1
@export var default_speed_limit_rad_s: float = 0.5
@export var forward_velocity_rad_s: float = 1.0
@export var reverse_velocity_rad_s: float = 1.0
@export var torque_limit_nm: float = 3000.0
@export var max_velocity_rad_s: float = 3.14
@export var max_torque_limit_nm: float = 20000.0
@export var damping_nm_s_per_rad: float = 50.0
@export var power_draw_w: float = 800.0
@export var overload_policy: SimulationMotorState.OverloadPolicy = (
	SimulationMotorState.OverloadPolicy.STOP
)


func top_axis_offset_cell() -> Vector3i:
	return OrientationUtil.face_to_vector(axis_face) * top_offset_cells


func validate(
	base_archetype: ElementArchetype,
	top_archetype: ElementArchetype
) -> Array[String]:
	var errors := validate_base_archetype(base_archetype)
	if top_archetype == null:
		errors.append("top archetype is missing")
	elif not top_archetype.internal_archetype:
		errors.append("top archetype must be internal")
	else:
		var top_cells := _footprint_set(top_archetype)
		var offset := top_axis_offset_cell()
		for base_cell: Vector3i in base_archetype.footprint_cells:
			if top_cells.has(_cell_key(base_cell + offset)):
				errors.append("base and top home footprints overlap")
		var top_ports := 0
		for port: PortDefinition in top_archetype.ports:
			if (
				port != null
				and port.port_id == SimulationMotorState.ROTOR_TOP_PORT
			):
				top_ports += 1
		if top_ports != 1:
			errors.append(
				"rotor top must expose exactly one rotor_top port"
			)
	return errors


func validate_base_archetype(base_archetype: ElementArchetype) -> Array[String]:
	var errors: Array[String] = []
	if top_archetype_id.is_empty():
		errors.append("top_archetype_id is empty")
	if top_offset_cells < 1:
		errors.append("top_offset_cells must be >= 1")
	if (
		default_speed_limit_rad_s < 0.0
		or forward_velocity_rad_s < 0.0
		or reverse_velocity_rad_s < 0.0
		or torque_limit_nm <= 0.0
		or max_velocity_rad_s <= 0.0
		or max_torque_limit_nm <= 0.0
		or damping_nm_s_per_rad < 0.0
		or power_draw_w < 0.0
	):
		errors.append("rotor motor tuning must be non-negative")
	if overload_policy != SimulationMotorState.OverloadPolicy.STOP:
		errors.append("unsupported overload policy")
	if base_archetype == null:
		errors.append("base archetype is missing")
	else:
		var drive_ports := 0
		for port: PortDefinition in base_archetype.ports:
			if port != null and port.port_id == SimulationMotorState.ROTOR_DRIVE_PORT:
				drive_ports += 1
		if drive_ports != 1:
			errors.append("rotor base must expose exactly one rotor_drive port")
	return errors


static func _footprint_set(archetype: ElementArchetype) -> Dictionary:
	var cells: Dictionary = {}
	for cell: Vector3i in archetype.footprint_cells:
		cells[_cell_key(cell)] = true
	return cells


static func _cell_key(cell: Vector3i) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]
