class_name ToolContextInteractionService
extends RefCounted

## Context-interaction half of ToolController: aim card keys, per-machine recipe
## cursor, E-context routing (loot / panels / terminals) and the actuator
## nudge commands.
##
## `tool` (the owning ToolController) is deliberately untyped: the monolith
## declares `class_name ToolController`, so naming the type here would close a
## `class_name` cycle. Rope state stays in the monolith — this service only
## asks it through `tool._is_rope_tool(tool.active_tool)`.


static func _aim_keys(tool, hit: InteractionHit) -> Dictionary:
	if hit == null:
		return {}
	return hit.card_keys(tool._simulation_world())


static func selected_recipe_for_element(
	tool,
	element_id: int,
	archetype_id: String
) -> String:
	if element_id <= 0 or archetype_id.is_empty():
		return ""
	var recipe_ids := RecipeCatalog.recipe_ids_for_machine(archetype_id)
	if recipe_ids.is_empty():
		return ""
	_ensure_recipe_cursor(tool, element_id, archetype_id)
	var cursor := int(tool._recipe_cursor_by_element.get(element_id, 0))
	return recipe_ids[wrapi(cursor, 0, recipe_ids.size())]


static func next_recipe_for_target(tool, hit: InteractionHit) -> String:
	if not _is_recipe_machine_hit(tool, hit):
		return ""
	var archetype_id := str(_aim_keys(tool, hit).get("archetype_id", ""))
	var element_id := hit.element_id
	var recipe_ids := RecipeCatalog.recipe_ids_for_machine(archetype_id)
	if recipe_ids.is_empty():
		return ""
	_ensure_recipe_cursor(tool, element_id, archetype_id)
	var cursor := int(tool._recipe_cursor_by_element.get(element_id, 0))
	return recipe_ids[wrapi(cursor, 0, recipe_ids.size())]


static func recipe_ids_for_target(
	tool,
	hit: InteractionHit
) -> PackedStringArray:
	if not _is_recipe_machine_hit(tool, hit):
		return PackedStringArray()
	return RecipeCatalog.recipe_ids_for_machine(
		str(_aim_keys(tool, hit).get("archetype_id", ""))
	)


static func _ensure_recipe_cursor(
	tool,
	element_id: int,
	archetype_id: String
) -> void:
	if tool._recipe_cursor_by_element.has(element_id):
		return
	var recipe_ids := RecipeCatalog.recipe_ids_for_machine(archetype_id)
	if recipe_ids.is_empty():
		return
	var default_id := RecipeCatalog.default_recipe_for_machine(archetype_id)
	var default_index := recipe_ids.find(default_id)
	tool._recipe_cursor_by_element[element_id] = (
		default_index if default_index >= 0 else 0
	)


static func _cycle_target_recipe(tool, hit: InteractionHit, delta: int) -> bool:
	if not _is_recipe_machine_hit(tool, hit) or delta == 0:
		return false
	var archetype_id := str(_aim_keys(tool, hit).get("archetype_id", ""))
	var element_id := hit.element_id
	var recipe_ids := RecipeCatalog.recipe_ids_for_machine(archetype_id)
	if recipe_ids.is_empty():
		return false
	_ensure_recipe_cursor(tool, element_id, archetype_id)
	var cursor := int(tool._recipe_cursor_by_element.get(element_id, 0))
	tool._recipe_cursor_by_element[element_id] = wrapi(
		cursor + delta,
		0,
		recipe_ids.size()
	)
	return true


static func _is_recipe_machine_hit(tool, hit: InteractionHit) -> bool:
	if (
		hit == null
		or not hit.valid
		or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT
		or hit.distance > 4.0
	):
		return false
	return str(
		_aim_keys(tool, hit).get("archetype_id", "")
	) in ["processor", "fabricator"]


static func _try_emit_context_interaction(tool, hit: InteractionHit) -> bool:
	if _try_collect_world_loot(tool, hit):
		return true
	if (
		not tool._is_rope_tool(tool.active_tool)
		and _try_open_wheel_panel(tool, hit)
	):
		return true
	if (
		not tool._is_rope_tool(tool.active_tool)
		and _try_open_actuator_panel(tool, hit)
	):
		return true
	if (
		not tool._is_rope_tool(tool.active_tool)
		and _try_open_terminal(tool, hit)
	):
		return true
	# Перед toggle_control_seat: control_terminal несёт роль ControlSeat (тот
	# же тег, что кокпит), но не садит — стоя открывает окно. Если это не
	# перехватить здесь, E на пульте дойдёт до toggle_control_seat и попробует
	# посадить игрока в стационарную консоль (CONTROL-ACTIONS-V0 «Хосты бара»).
	if (
		not tool._is_rope_tool(tool.active_tool)
		and _try_open_control_terminal(tool, hit)
	):
		return true
	return false


static func _ui_modal_blocks_world_interact(_tool) -> bool:
	return UIWindowStack.any_open()


static func _try_open_actuator_panel(tool, hit: InteractionHit) -> bool:
	if (
		tool._actuator_panel == null
		or not tool._actuator_panel.has_method("try_open_on_target")
	):
		return false
	if _ui_modal_blocks_world_interact(tool):
		return false
	return bool(tool._actuator_panel.call("try_open_on_target", hit))


static func _try_open_wheel_panel(tool, hit: InteractionHit) -> bool:
	if (
		tool._wheel_panel == null
		or not tool._wheel_panel.has_method("try_open_on_target")
	):
		return false
	if _ui_modal_blocks_world_interact(tool):
		return false
	return bool(tool._wheel_panel.call("try_open_on_target", hit))


static func _try_open_terminal(tool, hit: InteractionHit) -> bool:
	if (
		tool._terminal == null
		or not tool._terminal.has_method("try_open_on_target")
	):
		return false
	if _ui_modal_blocks_world_interact(tool):
		return false
	return bool(tool._terminal.call("try_open_on_target", hit))


static func _try_open_control_terminal(tool, hit: InteractionHit) -> bool:
	if (
		tool._control_terminal == null
		or not tool._control_terminal.has_method("try_open_on_target")
	):
		return false
	if _ui_modal_blocks_world_interact(tool):
		return false
	return bool(tool._control_terminal.call("try_open_on_target", hit))


static func _is_terminal_target_hit(tool, hit: InteractionHit) -> bool:
	return not IndustryTransferUtil.terminal_store_id_for_hit(
		hit,
		tool._gateway
	).is_empty()


static func _try_collect_world_loot(tool, hit: InteractionHit) -> bool:
	if (
		hit == null
		or not hit.valid
		or hit.target_kind != InteractionHit.KIND_WORLD_LOOT
		or hit.distance > 4.0
	):
		return false
	var pile_id := hit.loot_pile_id
	if pile_id <= 0:
		return false
	tool.command_requested.emit({
		"kind": &"collect_world_loot",
		"source": tool.get_parent(),
		"target": hit.snapshot(),
		"parameters": {
			"pile_id": pile_id,
			"to_store_id": PlayerIdentity.local_store_id(),
		},
	})
	return true


static func _try_enqueue_target_recipe(tool, hit: InteractionHit) -> bool:
	if not _is_recipe_machine_hit(tool, hit):
		return false
	if Input.is_key_pressed(KEY_SHIFT):
		return _try_dequeue_target_recipe(tool, hit)
	var recipe_id := next_recipe_for_target(tool, hit)
	if recipe_id.is_empty():
		return false
	var element_id := hit.element_id
	tool.command_requested.emit({
		"kind": &"enqueue_recipe",
		"source": tool.get_parent(),
		"target": hit.snapshot(),
		"parameters": {
			"element_id": element_id,
			"recipe_id": recipe_id,
		},
	})
	return true


static func _try_dequeue_target_recipe(tool, hit: InteractionHit) -> bool:
	if not _is_recipe_machine_hit(tool, hit):
		return false
	var element_id := hit.element_id
	tool.command_requested.emit({
		"kind": &"dequeue_recipe",
		"source": tool.get_parent(),
		"target": hit.snapshot(),
		"parameters": {
			"element_id": element_id,
		},
	})
	return true


static func _is_actuator_target_hit(tool, hit: InteractionHit) -> bool:
	if (
		hit == null
		or not hit.valid
		or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT
		or hit.distance > 4.5
	):
		return false
	var keys := _aim_keys(tool, hit)
	return (
		keys.has("piston_joint_id")
		or keys.has("rotor_joint_id")
		or keys.has("hinge_joint_id")
	)


static func _actuator_hit_joint_id(tool, hit: InteractionHit) -> int:
	var keys := _aim_keys(tool, hit)
	return HudActuatorTuneUtil.joint_id(keys)


static func _actuator_hit_forward_velocity(tool, hit: InteractionHit) -> float:
	var keys := _aim_keys(tool, hit)
	if keys.has("rotor_joint_id"):
		return float(keys.get("rotor_forward_velocity_rad_s", 0.5))
	if keys.has("hinge_joint_id"):
		return float(keys.get("hinge_forward_velocity_rad_s", 0.5))
	return float(keys.get("piston_extend_velocity_mps", 0.25))


static func _actuator_hit_reverse_velocity(tool, hit: InteractionHit) -> float:
	var keys := _aim_keys(tool, hit)
	if keys.has("rotor_joint_id"):
		return float(keys.get("rotor_reverse_velocity_rad_s", 0.5))
	if keys.has("hinge_joint_id"):
		return float(keys.get("hinge_reverse_velocity_rad_s", 0.5))
	return float(keys.get("piston_retract_velocity_mps", 0.25))


static func _try_actuator_extend(tool, hit: InteractionHit) -> bool:
	return _emit_actuator_target(
		tool,
		hit,
		SimulationMotorState.ControlMode.VELOCITY,
		_actuator_hit_forward_velocity(tool, hit),
		true
	)


static func _try_actuator_retract(tool, hit: InteractionHit) -> bool:
	return _emit_actuator_target(
		tool,
		hit,
		SimulationMotorState.ControlMode.VELOCITY,
		-_actuator_hit_reverse_velocity(tool, hit),
		true
	)


static func _try_actuator_stop(tool, hit: InteractionHit) -> bool:
	return _emit_actuator_target(
		tool,
		hit,
		SimulationMotorState.ControlMode.STOP,
		0.0,
		true
	)


static func _emit_actuator_target(
	tool,
	hit: InteractionHit,
	mode: SimulationMotorState.ControlMode,
	target_velocity_mps: float,
	enabled: bool
) -> bool:
	if not _is_actuator_target_hit(tool, hit):
		return false
	var joint_id := _actuator_hit_joint_id(tool, hit)
	if joint_id <= 0:
		return false
	var keys := _aim_keys(tool, hit)
	var joint_ids: Array[int] = [joint_id]
	if (
		tool.actuator_chain_sync
		and keys.has("piston_joint_id")
		and not keys.has("rotor_joint_id")
		and not keys.has("hinge_joint_id")
	):
		var assembly_id := hit.assembly_id
		var world: SimulationWorld = tool._simulation_world()
		if world != null and assembly_id > 0:
			joint_ids = PistonPlacementUtil.piston_joint_ids_in_assembly(
				world,
				assembly_id
			)
			if joint_ids.is_empty():
				joint_ids = [joint_id]
	for target_joint_id: int in joint_ids:
		tool.command_requested.emit({
			"kind": &"set_actuator_target",
			"source": tool.get_parent(),
			"target": hit.snapshot(),
			"parameters": {
				"joint_id": target_joint_id,
				"mode": mode,
				"target_velocity_mps": target_velocity_mps,
				"enabled": enabled,
			},
		})
	return true


static func toggle_actuator_motor(tool, hit: InteractionHit) -> bool:
	if not _is_actuator_target_hit(tool, hit):
		return false
	var joint_id := _actuator_hit_joint_id(tool, hit)
	if joint_id <= 0:
		return false
	var keys := _aim_keys(tool, hit)
	var enabled_now := true
	if keys.has("piston_joint_id"):
		enabled_now = bool(keys.get("piston_motor_enabled", true))
	elif keys.has("rotor_joint_id"):
		enabled_now = bool(keys.get("rotor_motor_enabled", true))
	elif keys.has("hinge_joint_id"):
		enabled_now = bool(keys.get("hinge_motor_enabled", true))
	return _emit_actuator_target(
		tool,
		hit,
		SimulationMotorState.ControlMode.STOP,
		0.0,
		not enabled_now
	)
