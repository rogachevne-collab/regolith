class_name OxygenModuleDefinition
extends Resource

## Authored oxygen-module tuning, carried on the .tres itself so a baked
## module works without a matching resources/balance/game_balance.json entry —
## same pattern as BatteryDefinition / PowerSourceDefinition.
@export var capacity_l: float = 200.0
@export var initial_l: float = 200.0
@export var dispense_lps: float = 0.5
@export var idle_w: float = 10.0
@export var active_w: float = 50.0


func validate(archetype: ElementArchetype) -> Array[String]:
	var errors: Array[String] = []
	if archetype == null:
		errors.append("archetype is missing")
		return errors
	if not is_finite(capacity_l) or capacity_l <= 0.0:
		errors.append(
			"oxygen module '%s' capacity_l must be finite and positive"
			% archetype.archetype_id
		)
	if not is_finite(initial_l):
		errors.append(
			"oxygen module '%s' initial_l must be finite"
			% archetype.archetype_id
		)
	elif initial_l < 0.0 or initial_l > capacity_l:
		errors.append(
			"oxygen module '%s' initial_l must satisfy 0 <= initial_l <= capacity_l"
			% archetype.archetype_id
		)
	if not is_finite(dispense_lps) or dispense_lps <= 0.0:
		errors.append(
			"oxygen module '%s' dispense_lps must be finite and positive"
			% archetype.archetype_id
		)
	if not is_finite(idle_w) or idle_w < 0.0:
		errors.append(
			"oxygen module '%s' idle_w must be finite and >= 0"
			% archetype.archetype_id
		)
	if not is_finite(active_w) or active_w < 0.0:
		errors.append(
			"oxygen module '%s' active_w must be finite and >= 0"
			% archetype.archetype_id
		)
	var has_cargo_port := false
	for port: PortDefinition in archetype.ports:
		if port != null and port.kind == PortDefinition.Kind.CARGO:
			has_cargo_port = true
			break
	if not has_cargo_port:
		errors.append(
			"oxygen module '%s' has no cargo port — cockpit reachability needs one"
			% archetype.archetype_id
		)
	return errors
