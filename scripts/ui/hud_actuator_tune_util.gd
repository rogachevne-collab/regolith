class_name HudActuatorTuneUtil
extends RefCounted

const TUNE_STEP := {
	"extend_velocity_mps": 0.05,
	"retract_velocity_mps": 0.05,
	"force_limit_n": 5000.0,
	"lower_limit_m": 0.1,
	"upper_limit_m": 0.1,
}

const TUNE_ROWS: Array[Dictionary] = [
	{"key": "ВЫД", "field": "extend_velocity_mps"},
	{"key": "ВТЯ", "field": "retract_velocity_mps"},
	{"key": "СИЛА", "field": "force_limit_n"},
	{"key": "МИН", "field": "lower_limit_m"},
	{"key": "МАКС", "field": "upper_limit_m"},
]

## Rotor rows reuse ConfigureActuatorCommand field names: extend/retract map
## to forward/reverse angular velocity, force limit maps to torque limit.
const ROTOR_TUNE_STEP := {
	"extend_velocity_mps": 0.1,
	"retract_velocity_mps": 0.1,
	"force_limit_n": 1000.0,
}

const ROTOR_TUNE_ROWS: Array[Dictionary] = [
	{"key": "ВПЕР", "field": "extend_velocity_mps"},
	{"key": "НАЗАД", "field": "retract_velocity_mps"},
	{"key": "МОМЕНТ", "field": "force_limit_n"},
]

## Hinge rows: rotor angular tuning plus min/max angle limits in degrees.
const HINGE_LIMIT_STEP_RAD := 5.0 * PI / 180.0
const HINGE_LIMIT_GAP_RAD := 5.0 * PI / 180.0

const HINGE_TUNE_STEP := {
	"extend_velocity_mps": 0.1,
	"retract_velocity_mps": 0.1,
	"force_limit_n": 1000.0,
	"lower_limit_m": HINGE_LIMIT_STEP_RAD,
	"upper_limit_m": HINGE_LIMIT_STEP_RAD,
}

const HINGE_TUNE_ROWS: Array[Dictionary] = [
	{"key": "ВПЕР", "field": "extend_velocity_mps"},
	{"key": "НАЗАД", "field": "retract_velocity_mps"},
	{"key": "МОМЕНТ", "field": "force_limit_n"},
	{"key": "МИН", "field": "lower_limit_m"},
	{"key": "МАКС", "field": "upper_limit_m"},
]


static func is_rotor_meta(meta: Dictionary) -> bool:
	return meta.has("rotor_joint_id") and not meta.has("piston_joint_id")


static func is_hinge_meta(meta: Dictionary) -> bool:
	return (
		meta.has("hinge_joint_id")
		and not meta.has("piston_joint_id")
		and not meta.has("rotor_joint_id")
	)


static func is_actuator_meta(meta: Dictionary) -> bool:
	return (
		meta.has("piston_joint_id")
		or meta.has("rotor_joint_id")
		or meta.has("hinge_joint_id")
	)


static func joint_id(meta: Dictionary) -> int:
	var piston_id := int(meta.get("piston_joint_id", 0))
	if piston_id > 0:
		return piston_id
	var rotor_id := int(meta.get("rotor_joint_id", 0))
	if rotor_id > 0:
		return rotor_id
	return int(meta.get("hinge_joint_id", 0))


static func mode_for(meta: Dictionary) -> String:
	if is_rotor_meta(meta):
		return "rotor"
	if is_hinge_meta(meta):
		return "hinge"
	return "piston"


static func rows_for(meta: Dictionary) -> Array[Dictionary]:
	if is_rotor_meta(meta):
		return ROTOR_TUNE_ROWS
	if is_hinge_meta(meta):
		return HINGE_TUNE_ROWS
	return TUNE_ROWS


static func format_value(field: String, meta: Dictionary) -> String:
	if is_rotor_meta(meta):
		return _format_rotor_value(field, meta)
	if is_hinge_meta(meta):
		return _format_hinge_value(field, meta)
	match field:
		"extend_velocity_mps":
			return "%.2f М/С" % float(meta.get("piston_extend_velocity_mps", 0.0))
		"retract_velocity_mps":
			return "%.2f М/С" % float(meta.get("piston_retract_velocity_mps", 0.0))
		"force_limit_n":
			return "%.1f кН" % (
				float(meta.get("piston_force_limit_n", 0.0)) / 1000.0
			)
		"lower_limit_m":
			return "%.1f М" % float(meta.get("piston_lower_limit_m", 0.0))
		"upper_limit_m":
			return "%.1f М" % float(meta.get("piston_upper_limit_m", 0.0))
	return "—"


static func _format_rotor_value(field: String, meta: Dictionary) -> String:
	match field:
		"extend_velocity_mps":
			return "%.2f РАД/С" % float(
				meta.get("rotor_forward_velocity_rad_s", 0.0)
			)
		"retract_velocity_mps":
			return "%.2f РАД/С" % float(
				meta.get("rotor_reverse_velocity_rad_s", 0.0)
			)
		"force_limit_n":
			return "%.1f кН·М" % (
				float(meta.get("rotor_torque_limit_nm", 0.0)) / 1000.0
			)
	return "—"


static func _format_hinge_value(field: String, meta: Dictionary) -> String:
	match field:
		"extend_velocity_mps":
			return "%.2f РАД/С" % float(
				meta.get("hinge_forward_velocity_rad_s", 0.0)
			)
		"retract_velocity_mps":
			return "%.2f РАД/С" % float(
				meta.get("hinge_reverse_velocity_rad_s", 0.0)
			)
		"force_limit_n":
			return "%.1f кН·М" % (
				float(meta.get("hinge_torque_limit_nm", 0.0)) / 1000.0
			)
		"lower_limit_m":
			return "%.0f°" % rad_to_deg(
				float(meta.get("hinge_lower_limit_rad", 0.0))
			)
		"upper_limit_m":
			return "%.0f°" % rad_to_deg(
				float(meta.get("hinge_upper_limit_rad", 0.0))
			)
	return "—"


static func next_value(meta: Dictionary, field: String, delta: float) -> float:
	if is_rotor_meta(meta):
		return _next_rotor_value(meta, field, delta)
	if is_hinge_meta(meta):
		return _next_hinge_value(meta, field, delta)
	var step := float(TUNE_STEP.get(field, 0.0))
	if step <= 0.0:
		return -1.0
	match field:
		"extend_velocity_mps", "retract_velocity_mps":
			var max_velocity := float(meta.get("piston_max_velocity_mps", 5.0))
			var meta_key := (
				"piston_extend_velocity_mps"
				if field == "extend_velocity_mps"
				else "piston_retract_velocity_mps"
			)
			return clampf(
				float(meta.get(meta_key, 0.0)) + delta * step,
				0.0,
				max_velocity
			)
		"force_limit_n":
			var max_force := float(meta.get("piston_max_force_limit_n", 100000.0))
			return clampf(
				float(meta.get("piston_force_limit_n", 0.0)) + delta * step,
				100.0,
				max_force
			)
		"lower_limit_m":
			var authored_lower := float(
				meta.get("piston_authored_lower_limit_m", 0.0)
			)
			var authored_upper := float(
				meta.get("piston_authored_upper_limit_m", 2.0)
			)
			var upper := float(meta.get("piston_upper_limit_m", authored_upper))
			return clampf(
				snappedf(
					float(meta.get("piston_lower_limit_m", 0.0)) + delta * step,
					0.1
				),
				authored_lower,
				upper - 0.1
			)
		"upper_limit_m":
			var authored_lower := float(
				meta.get("piston_authored_lower_limit_m", 0.0)
			)
			var authored_upper := float(
				meta.get("piston_authored_upper_limit_m", 2.0)
			)
			var lower := float(meta.get("piston_lower_limit_m", authored_lower))
			return clampf(
				snappedf(
					float(meta.get("piston_upper_limit_m", 0.0)) + delta * step,
					0.1
				),
				lower + 0.1,
				authored_upper
			)
	return -1.0


## Hinge limits are signed angles, so invalid fields report NAN (the piston
## "-1 means invalid" sentinel would collide with legal negative values).
static func _next_hinge_value(
	meta: Dictionary,
	field: String,
	delta: float
) -> float:
	var step := float(HINGE_TUNE_STEP.get(field, 0.0))
	if step <= 0.0:
		return NAN
	match field:
		"extend_velocity_mps", "retract_velocity_mps":
			var max_velocity := float(meta.get("hinge_max_velocity_rad_s", 2.0))
			var meta_key := (
				"hinge_forward_velocity_rad_s"
				if field == "extend_velocity_mps"
				else "hinge_reverse_velocity_rad_s"
			)
			return clampf(
				float(meta.get(meta_key, 0.0)) + delta * step,
				0.0,
				max_velocity
			)
		"force_limit_n":
			var max_torque := float(
				meta.get("hinge_max_torque_limit_nm", 20000.0)
			)
			return clampf(
				float(meta.get("hinge_torque_limit_nm", 0.0)) + delta * step,
				1.0,
				max_torque
			)
		"lower_limit_m":
			var authored_lower := float(
				meta.get("hinge_authored_lower_limit_rad", -PI / 2.0)
			)
			var upper := float(meta.get("hinge_upper_limit_rad", PI / 2.0))
			return clampf(
				snappedf(
					float(meta.get("hinge_lower_limit_rad", 0.0)) + delta * step,
					HINGE_LIMIT_STEP_RAD
				),
				authored_lower,
				upper - HINGE_LIMIT_GAP_RAD
			)
		"upper_limit_m":
			var authored_upper := float(
				meta.get("hinge_authored_upper_limit_rad", PI / 2.0)
			)
			var lower := float(meta.get("hinge_lower_limit_rad", 0.0))
			return clampf(
				snappedf(
					float(meta.get("hinge_upper_limit_rad", 0.0)) + delta * step,
					HINGE_LIMIT_STEP_RAD
				),
				lower + HINGE_LIMIT_GAP_RAD,
				authored_upper
			)
	return NAN


static func _next_rotor_value(
	meta: Dictionary,
	field: String,
	delta: float
) -> float:
	var step := float(ROTOR_TUNE_STEP.get(field, 0.0))
	if step <= 0.0:
		return -1.0
	match field:
		"extend_velocity_mps", "retract_velocity_mps":
			var max_velocity := float(meta.get("rotor_max_velocity_rad_s", 3.14))
			var meta_key := (
				"rotor_forward_velocity_rad_s"
				if field == "extend_velocity_mps"
				else "rotor_reverse_velocity_rad_s"
			)
			return clampf(
				float(meta.get(meta_key, 0.0)) + delta * step,
				0.0,
				max_velocity
			)
		"force_limit_n":
			var max_torque := float(
				meta.get("rotor_max_torque_limit_nm", 20000.0)
			)
			return clampf(
				float(meta.get("rotor_torque_limit_nm", 0.0)) + delta * step,
				1.0,
				max_torque
			)
	return -1.0
