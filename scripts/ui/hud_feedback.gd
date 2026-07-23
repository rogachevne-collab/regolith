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
	if _tools != null:
		_tools.connect_rejected.connect(_on_connect_rejected)


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


func _make_centered_label(top_px: float, bottom_px: float) -> Label:
	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.anchor_left = 0.5
	lbl.anchor_right = 0.5
	lbl.anchor_top = 0.5
	lbl.anchor_bottom = 0.5
	lbl.offset_left = -260.0
	lbl.offset_right = 260.0
	lbl.offset_top = top_px
	lbl.offset_bottom = bottom_px
	return lbl


func _process(delta: float) -> void:
	if _query == null:
		return
	_result_left = maxf(_result_left - delta, 0.0)
	_result.visible = _result_left > 0.0
	_prompt.text = (
		""
		if HudTokens.modal_window_open(self)
		else _prompt_for(_query.current_hit)
	)
	_prompt.visible = not _prompt.text.is_empty()


func _prompt_for(hit: InteractionHit) -> String:
	if _player.call("is_in_vehicle"):
		return "E — выйти · P — стояночный"
	if hit.valid and hit.distance <= 4.0:
		if hit.target_kind == InteractionHit.KIND_WORLD_LOOT:
			return "E — собрать %s" % HudTokens.resource_label(
				str(hit.metadata.get("resource_id", ""))
			)
		if _is_terminal_target(hit):
			return "E — открыть инвентарь"
	# Seat / module E-prompts stay visible with any tool (including drill).
	if (
		hit.valid
		and hit.distance <= 4.5
		and hit.target_kind == InteractionHit.KIND_CONTROL_SEAT
	):
		return "E — сесть в кокпит"
	if (
		hit.valid
		and hit.distance <= 4.0
		and hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
		and (
			hit.metadata.has("wheel_element_id")
			or hit.metadata.has("suspension_element_id")
		)
	):
		return "E — настройки модуля"
	if _tools.active_tool == &"scoop":
		# The load has no other readout, and it is the whole state of the tool:
		# a scoop that looks empty but is full simply refuses to scoop, with
		# nothing on screen to say why.
		var load_text := "%.2f / %.2f м³" % [
			_tools.scoop_load_m3,
			ToolController.SCOOP_CAPACITY_M3,
		]
		if _tools.scoop_load_m3 >= ToolController.SCOOP_CAPACITY_M3 - 0.000001:
			return "совок полон: %s · ПКМ — высыпать" % load_text
		if _tools.scoop_load_m3 <= 0.000001:
			return "совок пуст · ЛКМ — зачерпнуть сыпучее"
		return "совок %s · ЛКМ — черпать · ПКМ — высыпать" % load_text
	if _tools.active_tool == &"drill":
		return ""
	if _tools.active_tool == &"connect":
		if _tools.rope_routing_active():
			return (
				"ЛКМ — бросить конец (%d м) · колесо — натяг %.0f%% (Shift — грубо) · ПКМ — отмена"
				% [
					int(round(_tools.rope_click_range())),
					(1.0 - _tools.rope_slack()) * 100.0,
				]
			)
		return "ЛКМ — тянуть провод от чего угодно к чему угодно"
	if _tools.active_tool == &"grinder":
		if (
			hit.target_kind == InteractionHit.KIND_ELECTRIC_CABLE
			and hit.distance <= 2.2
		):
			return "ЛКМ — срезать кабель"
		if (
			hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
			and hit.distance <= 2.2
		):
			return "Удерживать ЛКМ — снос с возвратом материалов"
		return "ЛКМ — снос только по конструкции"
	if (
		hit.valid
		and hit.distance <= 4.0
		and hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
		and str(hit.metadata.get("archetype_id", "")) == "power_distributor"
	):
		return "Удерживай / — радиус питания"
	if not hit.valid:
		return ""
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
		if (
			_preview != null
			and not _preview.resolved_target.is_empty()
			and not _preview.has_resolved_placement()
		):
			var detail := StringName(
				_preview.resolved_plan.get("data", {}).get("detail", &"")
			)
			var wheel_prompt := _wheel_placement_prompt(detail)
			if not wheel_prompt.is_empty():
				return wheel_prompt
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


func _is_terminal_target(hit: InteractionHit) -> bool:
	return not IndustryTransferUtil.terminal_store_id_for_hit(hit, _gateway).is_empty()


func _on_command_completed(
	_command_id: int,
	action_result: Dictionary
) -> void:
	var reason := StringName(action_result.get("reason", &"not_ready"))
	var data: Dictionary = action_result.get("data", {})
	if reason == &"ok":
		if _suppress_success_feedback():
			return
		_result.text = "Готово"
		_result.add_theme_color_override("font_color", HudTokens.COL_OK)
		_result_left = 0.35
		return
	_result.text = _reason_text(reason, data)
	_result.add_theme_color_override(
		"font_color",
		HudTokens.COL_WARNING if reason == &"terrain_unavailable" else HudTokens.COL_CRITICAL
	)
	_result_left = 1.2 if reason != &"terrain_unavailable" else 0.7


func _on_connect_rejected(reason: StringName) -> void:
	_result.text = _reason_text(reason)
	_result.add_theme_color_override("font_color", HudTokens.COL_CRITICAL)
	_result_left = 1.2


func _wheel_placement_prompt(detail: StringName) -> String:
	match detail:
		&"wheel_socket_required":
			return "Нужна подвеска рядом"
		&"socket_occupied":
			return "Гнездо подвески занято"
		&"wrong_orientation":
			return "Поверни колесо к гнезду"
	return ""


func _suppress_success_feedback() -> bool:
	var action := _tools.active_action
	if action == &"tool_primary" and (
		_tools.active_tool == &"drill"
		or _tools.active_tool == &"grinder"
		or _tools.active_tool == &"weld"
	):
		return true
	return false


func _reason_text(reason: StringName, data: Dictionary = {}) -> String:
	match reason:
		&"no_target":
			return "Нет цели"
		&"out_of_range":
			return "Слишком далеко"
		&"invalid_target":
			if (
				StringName(data.get("detail", &""))
				== &"mobile_construction_not_supported"
			):
				return "Останови транспорт — на ходу строить нельзя"
			return "Неподходящая цель"
		&"parking_brake_needs_stop":
			return "Стояночный — только после полной остановки"
		&"blocked":
			if StringName(data.get("detail", &"")) == &"not_locomotive":
				return "Ровер не готов — нужны колёса и подвеска"
			return "Действие заблокировано"
		&"structure_overlap":
			return "Пересекает другую конструкцию"
		&"terrain_overlap":
			return "Нельзя ставить в грунт"
		&"player_blocked":
			return "Освободи место — ты стоишь здесь"
		&"insufficient_material":
			var resource_id := str(data.get("resource_id", ""))
			if not resource_id.is_empty():
				return "Недостаточно: %s" % HudTokens.resource_label(resource_id)
			return "Недостаточно материалов"
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
		&"moving_target_not_supported":
			return "Подожди, пока актуатор остановится"
		&"incompatible_connection":
			var detail := StringName(data.get("detail", &""))
			var wheel_text := _wheel_placement_prompt(detail)
			if not wheel_text.is_empty():
				return wheel_text
			if _tools != null and _tools.active_tool == &"build":
				return "Нет стыка с поверхностью блока"
			return "Нет совместимых электропортов"
		&"no_electric_ports":
			return "У блока нет электропортов"
		&"cable_too_long":
			return (
				"Пролёт кабеля длиннее %d м — нужна скоба"
				% int(IndustryElectricPortUtil.MAX_CABLE_LENGTH_M)
			)
		&"endpoint_not_wireable":
			return "Провод — только между генераторами, распределителями и батареями"
		&"cable_obstructed":
			return "Провод упирается в препятствие"
		&"storage_full":
			var resource_id := str(data.get("resource_id", ""))
			if resource_id == "ore_mare_regolith":
				return "Карман материалов полон"
			if resource_id == "plate_metal":
				return "Карман компонентов полон"
			return "Склад полон"
		&"no_input":
			return "Нечего переносить"
		&"queue_full":
			return "Очередь полна"
		&"no_effect":
			return "Очередь пуста"
		&"not_ready":
			return "Симуляция не готова"
		&"terrain_unavailable":
			return "Грунт ещё загружается"
		_:
			return "Действие недоступно"
