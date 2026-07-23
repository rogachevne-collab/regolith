class_name HudWheelTuneUtil
extends RefCounted

const WHEEL_TUNE_STEP := {
	"drive_torque_scale": 0.1,
	"grip_scale": 0.1,
	"brake_torque_n_m": 20.0,
	"travel_m": 0.05,
	"spring_stiffness_n_per_m": 100.0,
	"spring_damping_n_s_per_m": 25.0,
}

const WHEEL_ROWS: Array[Dictionary] = [
	{"key": "МОМ", "field": "drive_torque_scale"},
	{"key": "ТОРМ", "field": "brake_torque_n_m"},
	{"key": "СЦЕП", "field": "grip_scale"},
]

const SUSPENSION_ROWS: Array[Dictionary] = [
	{"key": "ХОД", "field": "travel_m"},
	{"key": "ПРУЖ", "field": "spring_stiffness_n_per_m"},
	{"key": "ДЕМП", "field": "spring_damping_n_s_per_m"},
]


## Что за узел под прицелом, решает МЕТАДАННЫЕ, а не список archetype_id:
## WheelPlacementUtil кладёт wheel_element_id / suspension_element_id любому
## колесу и любой подвеске, включая испечённые визардом. Со списком id
## авторская деталь молча оставалась без панели настройки.
static func rows_for_hit(hit: InteractionHit) -> Array[Dictionary]:
	if hit == null or not hit.valid:
		return []
	if hit.metadata.has("wheel_element_id"):
		return WHEEL_ROWS
	if hit.metadata.has("suspension_element_id"):
		return SUSPENSION_ROWS
	return []


static func panel_title(hit: InteractionHit) -> String:
	if hit != null and hit.valid:
		if hit.metadata.has("wheel_element_id"):
			return "КОЛЕСО"
		if hit.metadata.has("suspension_element_id"):
			return "ПОДВЕСКА"
	return "МОДУЛЬ"


static func format_value(field: String, meta: Dictionary) -> String:
	match field:
		"drive_torque_scale":
			return "%.0f%%" % (
				float(meta.get("wheel_drive_torque_scale", 1.0)) * 100.0
			)
		"brake_torque_n_m":
			return "%.0f Н·м" % float(meta.get("wheel_brake_torque_n_m", 0.0))
		"grip_scale":
			return "%.0f%%" % (float(meta.get("wheel_grip_scale", 1.0)) * 100.0)
		"travel_m":
			return "%.2f М" % float(meta.get("suspension_travel_m", 0.0))
		"spring_stiffness_n_per_m":
			return "%.0f Н/М" % float(
				meta.get("suspension_spring_stiffness_n_per_m", 0.0)
			)
		"spring_damping_n_s_per_m":
			return "%.0f Н·с/М" % float(
				meta.get("suspension_spring_damping_n_s_per_m", 0.0)
			)
	return "—"


static func next_value(meta: Dictionary, field: String, delta: float) -> float:
	var step := float(WHEEL_TUNE_STEP.get(field, 0.0))
	if step <= 0.0:
		return -1.0
	match field:
		"drive_torque_scale":
			return clampf(
				float(meta.get("wheel_drive_torque_scale", 1.0)) + delta * step,
				0.0,
				1.0
			)
		"brake_torque_n_m":
			return clampf(
				float(meta.get("wheel_brake_torque_n_m", 0.0)) + delta * step,
				0.0,
				float(meta.get("wheel_max_brake_torque_n_m", 180.0))
			)
		"grip_scale":
			return clampf(
				float(meta.get("wheel_grip_scale", 1.0)) + delta * step,
				0.0,
				1.0
			)
		"travel_m":
			return clampf(
				float(meta.get("suspension_travel_m", 0.6)) + delta * step,
				float(meta.get("suspension_min_travel_m", 0.2)),
				float(meta.get("suspension_max_travel_m", 1.0))
			)
		"spring_stiffness_n_per_m":
			return maxf(
				0.0,
				float(meta.get("suspension_spring_stiffness_n_per_m", 1600.0))
				+ delta * step
			)
		"spring_damping_n_s_per_m":
			return maxf(
				0.0,
				float(meta.get("suspension_spring_damping_n_s_per_m", 400.0))
				+ delta * step
			)
	return -1.0


static func configure_kind_for_hit(hit: InteractionHit) -> StringName:
	if hit == null or not hit.valid:
		return &""
	if hit.metadata.has("wheel_element_id"):
		return &"configure_wheel"
	if hit.metadata.has("suspension_element_id"):
		return &"configure_suspension"
	return &""


static func parameter_name_for_field(field: String) -> String:
	return field
