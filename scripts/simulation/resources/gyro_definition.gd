class_name GyroDefinition
extends Resource

@export var max_torque_nm: float = 400.0
@export var power_draw_w: float = 200.0
@export var idle_w: float = 5.0
## Proportional dampener gain: N·m per (rad/s) of body angular velocity.
@export var dampen_gain: float = 80.0


func validate(archetype: ElementArchetype) -> Array[String]:
	var errors: Array[String] = []
	if archetype == null:
		errors.append("archetype is missing")
		return errors
	if not is_finite(max_torque_nm) or max_torque_nm <= 0.0:
		errors.append(
			"gyro '%s' max_torque_nm must be finite and positive"
			% archetype.archetype_id
		)
	if not is_finite(power_draw_w) or power_draw_w < 0.0:
		errors.append(
			"gyro '%s' power_draw_w must be finite and non-negative"
			% archetype.archetype_id
		)
	if not is_finite(idle_w) or idle_w < 0.0:
		errors.append(
			"gyro '%s' idle_w must be finite and non-negative"
			% archetype.archetype_id
		)
	if not is_finite(dampen_gain) or dampen_gain <= 0.0:
		errors.append(
			"gyro '%s' dampen_gain must be finite and positive"
			% archetype.archetype_id
		)
	return errors
