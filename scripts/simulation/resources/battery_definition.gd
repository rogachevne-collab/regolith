class_name BatteryDefinition
extends Resource

## Authored battery tuning, carried on the .tres itself so a baked battery
## works without a matching resources/balance/game_balance.json entry — see
## IndustryElectricProfile.battery_max_kwh()/battery_charge_w()/discharge_w(),
## which prefer this definition over the JSON archetype-id lookup exactly the
## way idle_w() already prefers wheel_definition/thruster_definition.
@export var capacity_kwh: float = 10.0
@export var charge_w: float = 500.0
@export var discharge_w: float = 500.0


func validate(archetype: ElementArchetype) -> Array[String]:
	var errors: Array[String] = []
	if archetype == null:
		errors.append("archetype is missing")
		return errors
	if not is_finite(capacity_kwh) or capacity_kwh <= 0.0:
		errors.append(
			"battery '%s' capacity_kwh must be finite and positive"
			% archetype.archetype_id
		)
	if not is_finite(charge_w) or charge_w <= 0.0:
		errors.append(
			"battery '%s' charge_w must be finite and positive"
			% archetype.archetype_id
		)
	if not is_finite(discharge_w) or discharge_w <= 0.0:
		errors.append(
			"battery '%s' discharge_w must be finite and positive"
			% archetype.archetype_id
		)
	var has_electric_port := false
	for port: PortDefinition in archetype.ports:
		if port != null and port.kind == PortDefinition.Kind.ELECTRIC:
			has_electric_port = true
			break
	if not has_electric_port:
		errors.append(
			"battery '%s' has no electric port — nothing can wire to it"
			% archetype.archetype_id
		)
	return errors
