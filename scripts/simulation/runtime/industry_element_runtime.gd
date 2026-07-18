class_name IndustryElementRuntime
extends RefCounted

const _SCRIPT := preload(
	"res://scripts/simulation/runtime/industry_element_runtime.gd"
)

var machine_enabled: bool = true
var battery_kwh: float = 0.0
## True after first seed/charge. Empty+initialized stays empty (no seat refill).
var battery_initialized: bool = false
var active_recipe_power_w: float = 0.0
## Transient actuator/tool demand. Recomputed from current control state.
var dynamic_power_w: float = 0.0
var power_reason: StringName = &"ok"
var powered: bool = false
var machine_state: IndustryMachineState = null


static func create_default() -> IndustryElementRuntime:
	var runtime: IndustryElementRuntime = _SCRIPT.new()
	runtime.machine_enabled = true
	runtime.battery_kwh = 0.0
	runtime.battery_initialized = false
	runtime.active_recipe_power_w = 0.0
	runtime.dynamic_power_w = 0.0
	runtime.power_reason = &"ok"
	runtime.powered = false
	runtime.machine_state = IndustryMachineState.create_default()
	return runtime


func ensure_machine_state() -> IndustryMachineState:
	if machine_state == null:
		machine_state = IndustryMachineState.create_default()
	return machine_state


func demand_w(element: SimulationElement) -> float:
	if not machine_enabled:
		return 0.0
	return (
		IndustryElectricProfile.idle_w(element)
		+ maxf(active_recipe_power_w, 0.0)
		+ maxf(dynamic_power_w, 0.0)
	)


func to_dict() -> Dictionary:
	var row := {
		"machine_enabled": machine_enabled,
		"battery_kwh": battery_kwh,
		"battery_initialized": battery_initialized,
		"active_recipe_power_w": active_recipe_power_w,
	}
	if machine_state != null:
		row["machine_state"] = machine_state.to_dict()
	return row


static func from_dict(data: Dictionary) -> IndustryElementRuntime:
	var runtime: IndustryElementRuntime = _SCRIPT.new()
	runtime.machine_enabled = bool(data.get("machine_enabled", true))
	runtime.battery_kwh = maxf(float(data.get("battery_kwh", 0.0)), 0.0)
	# Legacy snapshots without the flag: any known charge counts as initialized.
	if data.has("battery_initialized"):
		runtime.battery_initialized = bool(data.get("battery_initialized", false))
	else:
		runtime.battery_initialized = runtime.battery_kwh > 0.000001
	runtime.active_recipe_power_w = maxf(
		float(data.get("active_recipe_power_w", 0.0)),
		0.0
	)
	runtime.dynamic_power_w = 0.0
	var machine_row: Variant = data.get("machine_state", {})
	if machine_row is Dictionary and not machine_row.is_empty():
		runtime.machine_state = IndustryMachineState.from_dict(machine_row)
	return runtime
