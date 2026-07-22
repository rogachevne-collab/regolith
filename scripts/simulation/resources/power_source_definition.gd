class_name PowerSourceDefinition
extends Resource

## Authored power-source tuning, carried on the .tres itself so a baked
## source works without a matching resources/balance/game_balance.json entry —
## see IndustryElectricProfile.output_w(), which prefers this definition over
## the JSON archetype-id lookup the same way idle_w() prefers wheel_definition.
@export var output_w: float = 2000.0


func validate(archetype: ElementArchetype) -> Array[String]:
	var errors: Array[String] = []
	if archetype == null:
		errors.append("archetype is missing")
		return errors
	if not is_finite(output_w) or output_w <= 0.0:
		errors.append(
			"power source '%s' output_w must be finite and positive"
			% archetype.archetype_id
		)
	var has_electric_port := false
	for port: PortDefinition in archetype.ports:
		if port != null and port.kind == PortDefinition.Kind.ELECTRIC:
			has_electric_port = true
			break
	if not has_electric_port:
		errors.append(
			"power source '%s' has no electric port — nothing can wire to it"
			% archetype.archetype_id
		)
	return errors
