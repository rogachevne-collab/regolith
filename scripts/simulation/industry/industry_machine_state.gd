class_name IndustryMachineState
extends RefCounted

const _SCRIPT := preload(
	"res://scripts/simulation/industry/industry_machine_state.gd"
)

var active_recipe_id: String = ""
var progress_s: float = 0.0
var queue: Array[String] = []
var reserved_inputs: Dictionary = {}


static func create_default() -> IndustryMachineState:
	return _SCRIPT.new()


func clear_active() -> void:
	active_recipe_id = ""
	progress_s = 0.0
	reserved_inputs.clear()


func queue_depth() -> int:
	return queue.size()


func to_dict() -> Dictionary:
	return {
		"active_recipe_id": active_recipe_id,
		"progress_s": progress_s,
		"queue": queue.duplicate(),
		"reserved_inputs": reserved_inputs.duplicate(true),
	}


static func from_dict(data: Dictionary) -> IndustryMachineState:
	var state: IndustryMachineState = _SCRIPT.new()
	state.active_recipe_id = str(data.get("active_recipe_id", ""))
	state.progress_s = maxf(float(data.get("progress_s", 0.0)), 0.0)
	var queue_data: Variant = data.get("queue", [])
	if queue_data is Array:
		for recipe_id: Variant in queue_data:
			var recipe := str(recipe_id)
			if not recipe.is_empty():
				state.queue.append(recipe)
	var reserved: Variant = data.get("reserved_inputs", {})
	if reserved is Dictionary:
		for resource_id: Variant in reserved.keys():
			var amount := float(reserved[resource_id])
			if amount > 0.000001:
				state.reserved_inputs[str(resource_id)] = amount
	return state
