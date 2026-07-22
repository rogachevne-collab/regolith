class_name IndustryElectricProfile
extends RefCounted

## Electric archetype defaults. Authoritative values live in
## `res://resources/balance/game_balance.json` (Game Balance v0).

## Compatibility aliases for callers that still reference DEFAULT_* constants.
static var DEFAULT_OUTPUT_W: float:
	get:
		return _default_float("output_w", 2000.0)
static var DEFAULT_IDLE_W: float:
	get:
		return _default_float("idle_w", 50.0)
static var DEFAULT_SUPPLY_RADIUS_M: float:
	get:
		return _default_float("supply_radius_m", 12.0)
static var DEFAULT_BATTERY_MAX_KWH: float:
	get:
		return _default_float("battery_max_kwh", 10.0)
static var DEFAULT_BATTERY_CHARGE_W: float:
	get:
		return _default_float("battery_charge_w", 500.0)
static var DEFAULT_BATTERY_DISCHARGE_W: float:
	get:
		return _default_float("battery_discharge_w", 500.0)


static func for_element(element: SimulationElement) -> Dictionary:
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null:
		return _empty_profile()
	var profile: Dictionary = _empty_profile()
	var archetype_defaults: Variant = GameBalance.electric_archetypes().get(
		archetype.archetype_id,
		{}
	)
	if archetype_defaults is Dictionary:
		for key: Variant in archetype_defaults.keys():
			profile[key] = archetype_defaults[key]
	_apply_role_fallback(archetype.roles, profile)
	# A part that drives, thrusts or spins burns power by definition. Without
	# this, being a consumer depended on the archetype id being listed in
	# game_balance.json — so any authored wheel silently stayed unpowered and
	# its drive command was zeroed every tick.
	if not bool(profile["is_consumer"]) and _has_powered_mechanism(archetype):
		profile["is_consumer"] = true
		if float(profile["idle_w"]) <= 0.0:
			profile["idle_w"] = _mechanism_idle_w(archetype)
	if (
		profile["is_consumer"]
		and float(profile["idle_w"]) <= 0.0
		and (
			not archetype_defaults is Dictionary
			or not (archetype_defaults as Dictionary).has("idle_w")
		)
	):
		profile["idle_w"] = _default_float("idle_w", 50.0)
	return profile


static func _has_powered_mechanism(archetype: ElementArchetype) -> bool:
	return (
		archetype.wheel_definition != null
		or archetype.thruster_definition != null
		or archetype.gyro_definition != null
	)


static func _mechanism_idle_w(archetype: ElementArchetype) -> float:
	if archetype.wheel_definition != null:
		return archetype.wheel_definition.idle_w
	if archetype.thruster_definition != null:
		return archetype.thruster_definition.idle_w
	if archetype.gyro_definition != null:
		return archetype.gyro_definition.idle_w
	return 0.0


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
		if archetype != null and archetype.thruster_definition != null:
			return archetype.thruster_definition.idle_w
		if archetype != null and archetype.gyro_definition != null:
			return archetype.gyro_definition.idle_w
	return float(for_element(element).get("idle_w", 0.0))


static func supply_radius_m(element: SimulationElement) -> float:
	return float(
		for_element(element).get(
			"supply_radius_m",
			_default_float("supply_radius_m", 12.0)
		)
	)


static func battery_max_kwh(element: SimulationElement) -> float:
	return float(
		for_element(element).get(
			"max_kwh",
			_default_float("battery_max_kwh", 10.0)
		)
	)


static func battery_charge_w(element: SimulationElement) -> float:
	return float(
		for_element(element).get(
			"charge_w",
			_default_float("battery_charge_w", 500.0)
		)
	)


static func battery_discharge_w(element: SimulationElement) -> float:
	return float(
		for_element(element).get(
			"discharge_w",
			_default_float("battery_discharge_w", 500.0)
		)
	)


static func archetype_default(
	archetype_id: String,
	key: String,
	fallback: Variant = null
) -> Variant:
	var defaults: Variant = GameBalance.electric_archetypes().get(
		archetype_id,
		{}
	)
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
		"supply_radius_m": _default_float("supply_radius_m", 12.0),
		"max_kwh": _default_float("battery_max_kwh", 10.0),
		"charge_w": _default_float("battery_charge_w", 500.0),
		"discharge_w": _default_float("battery_discharge_w", 500.0),
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
					profile["output_w"] = _default_float("output_w", 2000.0)
			"Tank":
				if not profile["is_source"]:
					profile["is_battery"] = true
			"Processor", "Fabricator", "Tool":
				profile["is_consumer"] = true


static func _default_float(key: String, fallback: float) -> float:
	return float(GameBalance.electric_defaults().get(key, fallback))
