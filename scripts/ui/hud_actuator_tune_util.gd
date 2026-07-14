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


static func format_value(field: String, meta: Dictionary) -> String:
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


static func next_value(meta: Dictionary, field: String, delta: float) -> float:
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
