class_name IndustryElectricProfile
extends RefCounted

## Placeholder fixture values until archetype `.tres` export fields land.
## Keys are `archetype_id`; roles provide fallback classification.

const DEFAULT_OUTPUT_W := 2000.0
const DEFAULT_IDLE_W := 50.0
const DEFAULT_SUPPLY_RADIUS_M := 12.0
const DEFAULT_BATTERY_MAX_KWH := 10.0
const DEFAULT_BATTERY_CHARGE_W := 500.0
const DEFAULT_BATTERY_DISCHARGE_W := 500.0

const _ARCHETYPE_DEFAULTS := {
	"power_source": {
		"is_source": true,
		"output_w": 2000.0,
	},
	"power_distributor": {
		"is_distributor": true,
		"supply_radius_m": 12.0,
	},
	"power_battery": {
		"is_battery": true,
		"max_kwh": 10.0,
		"charge_w": 500.0,
		"discharge_w": 500.0,
	},
	"processor": {
		"is_consumer": true,
		"idle_w": 50.0,
	},
	"fabricator": {
		"is_consumer": true,
		"idle_w": 50.0,
	},
	"stationary_drill": {
		"is_consumer": true,
		"idle_w": 80.0,
	},
	"piston_base": {
		"is_consumer": true,
		"idle_w": 0.0,
	},
	"rotor_base": {
		"is_consumer": true,
		"idle_w": 0.0,
	},
	"rotor_base_large": {
		"is_consumer": true,
		"idle_w": 0.0,
	},
	"drive_wheel": {
		"is_consumer": true,
		"idle_w": 20.0,
	},
	"power_battery_small": {
		"is_battery": true,
		"max_kwh": 2.5,
		"charge_w": 250.0,
		"discharge_w": 1500.0,
	},
	"power_distributor_small": {
		"is_distributor": true,
		"supply_radius_m": 6.0,
	},
}


static func for_element(element: SimulationElement) -> Dictionary:
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null:
		return _empty_profile()
	var profile: Dictionary = _empty_profile()
	var archetype_defaults: Variant = _ARCHETYPE_DEFAULTS.get(
		archetype.archetype_id,
		{}
	)
	if archetype_defaults is Dictionary:
		for key: Variant in archetype_defaults.keys():
			profile[key] = archetype_defaults[key]
	_apply_role_fallback(archetype.roles, profile)
	if (
		profile["is_consumer"]
		and float(profile["idle_w"]) <= 0.0
		and (
			not archetype_defaults is Dictionary
			or not (archetype_defaults as Dictionary).has("idle_w")
		)
	):
		profile["idle_w"] = DEFAULT_IDLE_W
	return profile


static func is_power_consumer(element: SimulationElement) -> bool:
	return bool(for_element(element).get("is_consumer", false))


static func is_power_source(element: SimulationElement) -> bool:
	return bool(for_element(element).get("is_source", false))


static func is_distributor(element: SimulationElement) -> bool:
	return bool(for_element(element).get("is_distributor", false))


static func is_battery(element: SimulationElement) -> bool:
	return bool(for_element(element).get("is_battery", false))


static func output_w(element: SimulationElement) -> float:
	return float(for_element(element).get("output_w", 0.0))


static func idle_w(element: SimulationElement) -> float:
	if element != null:
		var archetype := element.get_archetype()
		if archetype != null and archetype.wheel_definition != null:
			return archetype.wheel_definition.idle_w
	return float(for_element(element).get("idle_w", 0.0))


static func supply_radius_m(element: SimulationElement) -> float:
	return float(
		for_element(element).get("supply_radius_m", DEFAULT_SUPPLY_RADIUS_M)
	)


static func battery_max_kwh(element: SimulationElement) -> float:
	return float(for_element(element).get("max_kwh", DEFAULT_BATTERY_MAX_KWH))


static func battery_charge_w(element: SimulationElement) -> float:
	return float(
		for_element(element).get("charge_w", DEFAULT_BATTERY_CHARGE_W)
	)


static func battery_discharge_w(element: SimulationElement) -> float:
	return float(
		for_element(element).get("discharge_w", DEFAULT_BATTERY_DISCHARGE_W)
	)


static func archetype_default(archetype_id: String, key: String, fallback: Variant = null) -> Variant:
	var defaults: Variant = _ARCHETYPE_DEFAULTS.get(archetype_id, {})
	if defaults is Dictionary and (defaults as Dictionary).has(key):
		return (defaults as Dictionary)[key]
	return fallback


static func _empty_profile() -> Dictionary:
	return {
		"is_source": false,
		"is_distributor": false,
		"is_battery": false,
		"is_consumer": false,
		"output_w": 0.0,
		"idle_w": 0.0,
		"supply_radius_m": DEFAULT_SUPPLY_RADIUS_M,
		"max_kwh": DEFAULT_BATTERY_MAX_KWH,
		"charge_w": DEFAULT_BATTERY_CHARGE_W,
		"discharge_w": DEFAULT_BATTERY_DISCHARGE_W,
	}


static func _apply_role_fallback(
	roles: PackedStringArray,
	profile: Dictionary
) -> void:
	for role: String in roles:
		match role:
			"Source":
				profile["is_source"] = true
				if float(profile["output_w"]) <= 0.0:
					profile["output_w"] = DEFAULT_OUTPUT_W
			"Tank":
				if not profile["is_source"]:
					profile["is_battery"] = true
			"Processor", "Fabricator", "Tool":
				profile["is_consumer"] = true
