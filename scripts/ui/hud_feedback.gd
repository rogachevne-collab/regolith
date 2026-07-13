extends Control
## Contextual prompt + timed result toast. Presentation only: reads
## InteractionQuery / ToolController / player state to hint the current action,
## and shows a short localized toast when WorldCommandGateway reports a command
## result. It only initiates existing commands indirectly (it initiates nothing).

var _query: InteractionQuery
var _tools: ToolController
var _gateway: WorldCommandGateway
var _preview: ConstructionPreview
var _player: Node

var _prompt: Label
var _result: Label
var _result_left := 0.0


func setup(ctx: Dictionary) -> void:
	_query = ctx.get("query")
	_tools = ctx.get("tools")
	_gateway = ctx.get("gateway")
	_preview = ctx.get("preview")
	_player = ctx.get("player")
	if _gateway != null:
		_gateway.command_completed.connect(_on_command_completed)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_prompt = _make_centered_label(64.0, 88.0)
	_prompt.add_theme_color_override("font_color", HudTokens.COL_TEXT)
	add_child(_prompt)

	_result = _make_centered_label(96.0, 122.0)
	_result.theme_type_variation = &"HudValue"
	_result.visible = false
	add_child(_result)


func _make_centered_label(offset_top: float, offset_bottom: float) -> Label:
	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.anchor_left = 0.5
	lbl.anchor_right = 0.5
	lbl.anchor_top = 0.5
	lbl.anchor_bottom = 0.5
	lbl.offset_left = -260.0
	lbl.offset_right = 260.0
	lbl.offset_top = offset_top
	lbl.offset_bottom = offset_bottom
	return lbl


func _process(delta: float) -> void:
	if _query == null:
		return
	_result_left = maxf(_result_left - delta, 0.0)
	_result.visible = _result_left > 0.0
	_prompt.text = _prompt_for(_query.current_hit)
	_prompt.visible = not _prompt.text.is_empty()


func _prompt_for(hit: InteractionHit) -> String:
	if _player.call("is_in_vehicle"):
		return "E — выйти из кокпита"
	if hit.valid and hit.distance <= 4.0:
		if hit.target_kind == InteractionHit.KIND_WORLD_LOOT:
			return "E — собрать %s" % HudTokens.resource_label(
				str(hit.metadata.get("resource_id", ""))
			)
		if _is_recipe_machine(hit):
			return "E — вкл/выкл · R — добавить рецепт"
		if (
			hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
			and _is_industry_transfer_target(hit)
		):
			return "E — забрать / положить груз"
	if _tools.active_tool == &"drill":
		return ""
	if _tools.active_tool == &"connect":
		if _tools.connect_pending_element_id() > 0:
			return "ЛКМ — второй блок с соседним электропортом"
		if (
			hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
			and hit.distance <= 4.0
		):
			return "ЛКМ — первый блок для провода"
		return "ЛКМ — электрический провод между соседними блоками"
	if _tools.active_tool == &"grinder":
		if (
			hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
			and hit.distance <= 2.2
		):
			return "Удерживать ЛКМ — снос с возвратом материалов"
		return "ЛКМ — снос только по конструкции"
	if not hit.valid:
		return ""
	if (
		hit.target_kind == InteractionHit.KIND_CONTROL_SEAT
		and hit.distance <= 4.5
	):
		return "E — сесть в кокпит"
	if _tools.active_tool == &"weld":
		if (
			hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
			and hit.distance <= 4.0
		):
			var status := StringName(
				hit.metadata.get("status_reason", &"element_incomplete")
			)
			if status == &"element_incomplete":
				return "Удерживать ЛКМ — наращивание целостности"
			if status == &"ok":
				return "Блок готов"
		return "ЛКМ — сварка по конструкции"
	if _tools.active_tool == &"build":
		if _preview != null and _preview.has_resolved_placement():
			var block_name := _gateway.archetype_display_name(
				_tools.selected_archetype_id
			)
			var target_kind := StringName(
				_preview.resolved_target.get("target_kind", &"")
			)
			if target_kind == InteractionHit.KIND_VOXEL:
				return "ЛКМ — поставить %s на грунт" % block_name
			if target_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
				return "ЛКМ — поставить %s" % block_name
		return ""
	return ""


func _is_recipe_machine(hit: InteractionHit) -> bool:
	if hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT:
		return false
	return str(hit.metadata.get("archetype_id", "")) in [
		"processor",
		"fabricator",
	]


func _is_industry_transfer_target(hit: InteractionHit) -> bool:
	if _gateway == null:
		return false
	var session := _gateway.get_node_or_null(
		_gateway.simulation_session_path
	) as SimulationSession
	if session == null:
		return false
	var element := session.world.get_element(int(hit.metadata.get("element_id", 0)))
	return IndustryTransferUtil.is_transfer_target(element)


func _on_command_completed(
	_command_id: int,
	action_result: Dictionary
) -> void:
	var reason := StringName(action_result.get("reason", &"not_ready"))
	if reason == &"ok":
		if _suppress_success_feedback():
			return
		_result.text = "Готово"
		_result.add_theme_color_override("font_color", HudTokens.COL_OK)
		_result_left = 0.35
		return
	_result.text = _reason_text(reason)
	_result.add_theme_color_override("font_color", HudTokens.COL_CRITICAL)
	_result_left = 1.2


func _suppress_success_feedback() -> bool:
	var action := _tools.active_action
	if action == &"tool_primary" and (
		_tools.active_tool == &"drill"
		or _tools.active_tool == &"grinder"
		or _tools.active_tool == &"weld"
	):
		return true
	return false


func _reason_text(reason: StringName) -> String:
	match reason:
		&"no_target":
			return "Нет цели"
		&"out_of_range":
			return "Слишком далеко"
		&"invalid_target":
			return "Неподходящая цель"
		&"blocked":
			return "Действие заблокировано"
		&"insufficient_material":
			return "Недостаточно компонентов"
		&"anchor_required":
			return "Нет опоры для первого блока"
		&"anchor_not_allowed":
			return "Этот блок только для старта на грунте"
		&"already_complete":
			return "Элемент уже готов"
		&"not_damaged":
			return "Ремонт не требуется"
		&"element_incomplete":
			return "Элемент не завершён"
		&"element_broken":
			return "Элемент сломан"
		&"duplicate_connection":
			return "Провод уже подключён"
		&"incompatible_connection":
			return "Нет совместимых электропортов"
		&"no_electric_ports":
			return "У блока нет электропортов"
		&"cable_too_long":
			return "Кабель длиннее 12 м"
		&"storage_full":
			return "Склад полон"
		&"no_input":
			return "Нечего переносить"
		_:
			return "Действие недоступно"
