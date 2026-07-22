extends Node

## Kernel acceptance: no two project-defined input actions may share the same
## physical key (+ modifiers). A silent collision here means whichever action
## Godot happens to fire first wins and the other is unreachable — the exact
## class of bug that let `toggle_parking_brake`/`playground_respawn_stands`
## (both physical P) and `control_terminal_toggle`/`playground_ram_launch`
## (both physical K) sit unnoticed until they broke a rover mid-drive.

const ALLOWED_SYNONYMS: Array[Array] = [
	["jump", "move_up"],
	# `interact` (on-foot context action) and `roll_right` (flight-vehicle 6DOF)
	# are deliberately state-gated onto the same physical key in
	# tool_controller.gd's connect-tool branch (`not in_vehicle` guard) rather
	# than given separate keys — the two states never fire together.
	["interact", "roll_right"],
]


func _ready() -> void:
	var errors := _run()
	if errors.is_empty():
		print("INPUT-BINDINGS: PASS")
		get_tree().quit(0)
	else:
		for error: String in errors:
			push_error(error)
		print("INPUT-BINDINGS: FAIL")
		get_tree().quit(1)


func _run() -> PackedStringArray:
	var errors := PackedStringArray()
	var groups: Dictionary = {}
	for action_name: String in _project_action_names():
		for event: InputEvent in InputMap.action_get_events(StringName(action_name)):
			if not event is InputEventKey:
				continue
			var key := event as InputEventKey
			if key.physical_keycode == 0:
				continue
			var signature := "%d/%s/%s/%s/%s" % [
				key.physical_keycode,
				key.ctrl_pressed,
				key.alt_pressed,
				key.shift_pressed,
				key.meta_pressed,
			]
			var bucket: Array = groups.get(signature, [])
			if not bucket.has(action_name):
				bucket.append(action_name)
			groups[signature] = bucket

	for signature: String in groups.keys():
		var actions: Array = groups[signature]
		if actions.size() <= 1 or _is_allowed_synonym(actions):
			continue
		actions.sort()
		errors.append(
			"physical key %s is bound to multiple actions: %s"
			% [signature, ", ".join(actions)]
		)
	return errors


func _is_allowed_synonym(actions: Array) -> bool:
	var sorted_actions := actions.duplicate()
	sorted_actions.sort()
	for allowed: Array in ALLOWED_SYNONYMS:
		var sorted_allowed := allowed.duplicate()
		sorted_allowed.sort()
		if sorted_actions == sorted_allowed:
			return true
	return false


## Only actions actually defined in project.godot's [input] section — not
## Godot's built-in ui_* actions, which this project never overrides and
## which legitimately share physical keys with gameplay actions (e.g.
## ui_accept/ui_select on Space, ui_cancel on Escape) by engine design.
func _project_action_names() -> PackedStringArray:
	var names := PackedStringArray()
	for property: Dictionary in ProjectSettings.get_property_list():
		var name := str(property.get("name", ""))
		if name.begins_with("input/"):
			names.append(name.substr(6))
	return names
