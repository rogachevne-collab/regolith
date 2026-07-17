class_name ThrusterDefinition
extends Resource

## Force-on-hull axis (reaction). Nozzle visual is opposite.
@export var thrust_axis_face: OrientationUtil.Face = OrientationUtil.Face.POS_Y
@export var max_thrust_n: float = 2000.0
@export var power_draw_w: float = 800.0
@export var idle_w: float = 10.0
## Point of apply_force in element local frame (meters from cell origin corner
## convention used by GridPoseUtil — typically near cell center).
@export var nozzle_offset_local: Vector3 = Vector3(0.25, 0.1, 0.25)


func validate(archetype: ElementArchetype) -> Array[String]:
	var errors: Array[String] = []
	if archetype == null:
		errors.append("archetype is missing")
		return errors
	if not is_finite(max_thrust_n) or max_thrust_n <= 0.0:
		errors.append(
			"thruster '%s' max_thrust_n must be finite and positive"
			% archetype.archetype_id
		)
	if not is_finite(power_draw_w) or power_draw_w < 0.0:
		errors.append(
			"thruster '%s' power_draw_w must be finite and non-negative"
			% archetype.archetype_id
		)
	if not is_finite(idle_w) or idle_w < 0.0:
		errors.append(
			"thruster '%s' idle_w must be finite and non-negative"
			% archetype.archetype_id
		)
	if not nozzle_offset_local.is_finite():
		errors.append(
			"thruster '%s' nozzle_offset_local must be finite"
			% archetype.archetype_id
		)
	var face := int(thrust_axis_face)
	if (
		face < int(OrientationUtil.Face.POS_X)
		or face > int(OrientationUtil.Face.NEG_Z)
	):
		errors.append(
			"thruster '%s' thrust_axis_face is invalid"
			% archetype.archetype_id
		)
	return errors
