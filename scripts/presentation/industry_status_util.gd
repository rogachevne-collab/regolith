class_name IndustryStatusUtil
extends RefCounted
## Read-only bridge from simulation industry runtime to HUD status_reason tokens.
## Construction reasons win over functional industry reasons (INDUSTRY-V1 § Functional status).


static func resolve_display_reason(
	world: SimulationWorld,
	element: SimulationElement
) -> StringName:
	if element == null:
		return &"invalid_target"
	var structural := element.status_reason()
	if structural != &"ok":
		return structural
	if not element.is_operational():
		return structural
	if world == null:
		return &"ok"
	var runtime := world.ensure_industry_element_runtime(element.element_id)
	if not runtime.machine_enabled:
		return &"disabled"
	var functional := element.industry_status_reason()
	if functional != &"ok":
		return functional
	if IndustryElectricProfile.is_power_consumer(element):
		var reason := runtime.power_reason
		if reason == &"":
			return &"ok"
		if runtime.powered and reason == &"ok":
			return &"ok"
		return reason
	return &"ok"
