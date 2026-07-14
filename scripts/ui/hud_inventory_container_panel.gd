class_name HudInventoryContainerPanel
extends PanelContainer
## Terminal inventory side panel: title, volume/mass chrome, item grid, and optional
## machine controls. Reads StoreSnapshot via WorldCommandGateway; never owns amounts.

const PANEL_MIN_WIDTH := 232.0
const MACHINE_PROGRESS_WIDTH := 148.0
const VOLUME_BAR_WIDTH := 76.0

var _gateway: WorldCommandGateway
var _peer_store_id := ""
var _store_id := ""
var _element_id := 0
var _snapshot: Dictionary = {}
var _column_width := 248.0
var _slot_size := HudTokens.SLOT_SIZE
var _max_grid_height := 0.0

var _title_label: Label
var _volume_row: HBoxContainer
var _volume_bar: ColorRect
var _volume_value: Label
var _volume_mat: ShaderMaterial
var _mass_label: Label
var _grid: HudInventoryGrid
var _feedback_label: Label
var _machine_block: VBoxContainer
var _machine_status: Label
var _machine_enabled_btn: Button
var _machine_progress_row: HBoxContainer
var _machine_progress_name: Label
var _machine_progress_mat: ShaderMaterial
var _machine_progress_value: Label
var _machine_queue_box: VBoxContainer
var _machine_recipe_box: VBoxContainer
var _pending_command_ids: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_build()
	_apply_panel_width()


func setup(gateway: WorldCommandGateway) -> void:
	if _gateway != null and _gateway.command_completed.is_connected(_on_command_completed):
		_gateway.command_completed.disconnect(_on_command_completed)
	_gateway = gateway
	if _grid != null:
		_grid.setup(gateway)
	if _gateway != null:
		_gateway.command_completed.connect(_on_command_completed)


func configure_layout(ctx: Dictionary) -> void:
	_column_width = float(ctx.get("column_width", _column_width))
	_slot_size = ctx.get("slot_size", _slot_size)
	_max_grid_height = float(ctx.get("max_grid_height", 0.0))
	_apply_panel_width()
	if _grid != null:
		_grid.configure_layout(_column_width, _slot_size, _max_grid_height)


func set_peer_store_id(peer_store_id: String) -> void:
	_peer_store_id = peer_store_id
	if _grid != null:
		_grid.set_peer_store_id(peer_store_id)


func apply_snapshot(snapshot: Dictionary) -> void:
	_snapshot = snapshot.duplicate(true)
	_store_id = str(snapshot.get("store_id", ""))
	_element_id = HudInventoryTransferUtil.element_id_for_store(_store_id)
	_refresh_chrome()
	if _grid != null:
		_grid.set_peer_store_id(_peer_store_id)
		_grid.apply_snapshot(snapshot)
		if _column_width > 0.0:
			_grid.configure_layout(_column_width, _slot_size, _max_grid_height)
	_refresh_machine_block()


func refresh() -> void:
	if _gateway == null or _store_id.is_empty():
		return
	apply_snapshot(_gateway.store_snapshot(_store_id))


func store_id() -> String:
	return _store_id


func _apply_panel_width() -> void:
	custom_minimum_size.x = maxf(_column_width, PANEL_MIN_WIDTH)


func _build() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 0)
	margin.add_theme_constant_override("margin_right", 0)
	margin.add_theme_constant_override("margin_top", 0)
	margin.add_theme_constant_override("margin_bottom", 0)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", HudTokens.SECTION_GAP)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vb)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title_row)
	title_row.add_child(HudTokens.make_emblem(12.0))
	_title_label = Label.new()
	_title_label.theme_type_variation = &"HudSmall"
	_title_label.add_theme_color_override("font_color", HudTokens.COL_TITLE)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.clip_text = true
	title_row.add_child(_title_label)

	vb.add_child(HudTokens.make_divider())

	var volume_row := HudTokens.make_progress_bar(VOLUME_BAR_WIDTH, "ОБ.")
	_volume_row = volume_row["row"] as HBoxContainer
	_volume_mat = volume_row["mat"] as ShaderMaterial
	_volume_value = volume_row["value"] as Label
	_volume_bar = _volume_row.get_child(1) as ColorRect
	_volume_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_volume_bar.custom_minimum_size.x = VOLUME_BAR_WIDTH
	_volume_value.custom_minimum_size.x = 64.0
	_volume_value.clip_text = true
	vb.add_child(_volume_row)

	_mass_label = Label.new()
	_mass_label.theme_type_variation = &"HudSmall"
	_mass_label.add_theme_color_override("font_color", HudTokens.COL_TEXT)
	_mass_label.clip_text = true
	_mass_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_mass_label)

	_grid = HudInventoryGrid.new()
	_grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_grid.transfer_failed.connect(_on_grid_transfer_failed)
	vb.add_child(_grid)

	_feedback_label = Label.new()
	_feedback_label.theme_type_variation = &"HudSmall"
	_feedback_label.add_theme_color_override("font_color", HudTokens.COL_CRITICAL)
	_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback_label.visible = false
	_feedback_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_feedback_label)

	_machine_block = VBoxContainer.new()
	_machine_block.add_theme_constant_override("separation", 8)
	_machine_block.visible = false
	_machine_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_machine_block)

	_machine_status = Label.new()
	_machine_status.theme_type_variation = &"HudSmall"
	_machine_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_machine_block.add_child(_machine_status)

	_machine_enabled_btn = Button.new()
	_machine_enabled_btn.theme_type_variation = &"HudSmall"
	_machine_enabled_btn.pressed.connect(_on_toggle_enabled_pressed)
	_machine_block.add_child(_machine_enabled_btn)

	_machine_queue_box = _make_subsection(_machine_block, "ОЧЕРЕДЬ")
	_machine_recipe_box = _make_subsection(_machine_block, "РЕЦЕПТЫ")

	var progress := HudTokens.make_progress_bar(MACHINE_PROGRESS_WIDTH, "")
	_machine_progress_row = progress["row"] as HBoxContainer
	_machine_progress_name = _machine_progress_row.get_child(0) as Label
	_machine_progress_mat = progress["mat"] as ShaderMaterial
	_machine_progress_value = progress["value"] as Label
	_machine_progress_row.visible = false
	_machine_block.add_child(_machine_progress_row)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_volume_bar_shader()


func _update_volume_bar_shader() -> void:
	if _volume_bar == null or _volume_mat == null:
		return
	var bar_w := maxf(_volume_bar.size.x, _volume_bar.custom_minimum_size.x)
	var bar_size := Vector2(bar_w, HudTokens.BAR_SIZE.y)
	_volume_mat.set_shader_parameter("rect_size", bar_size)


func _make_subsection(parent: Node, title: String) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 4)
	section.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(section)
	var header := Label.new()
	header.text = title
	header.theme_type_variation = &"HudSmall"
	header.add_theme_color_override("font_color", HudTokens.COL_DIM)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	section.add_child(header)
	return section


func _refresh_chrome() -> void:
	if _title_label != null:
		_title_label.text = str(_snapshot.get("title", "—"))
	var used_l := float(_snapshot.get("used_l", 0.0))
	var capacity_l := maxf(float(_snapshot.get("capacity_l", 0.0)), 0.000001)
	var fill := clampf(used_l / capacity_l, 0.0, 1.0)
	if _volume_mat != null:
		_volume_mat.set_shader_parameter("fill", fill)
		var bar_color := HudTokens.COL_VALID
		if fill >= 0.95:
			bar_color = HudTokens.COL_CRITICAL
		elif fill >= 0.8:
			bar_color = HudTokens.COL_WARNING
		_volume_mat.set_shader_parameter("fill_color", bar_color)
	if _volume_value != null:
		_volume_value.text = "%s/%s L" % [
			HudTokens.format_amount(used_l),
			HudTokens.format_amount(capacity_l),
		]
	if _mass_label != null:
		_mass_label.text = "МАССА %s кг" % HudTokens.format_amount(
			float(_snapshot.get("mass_kg", 0.0))
		)
	_update_volume_bar_shader()
	_clear_feedback()


func _refresh_machine_block() -> void:
	if _machine_block == null:
		return
	var is_machine := bool(_snapshot.get("is_machine", false))
	_machine_block.visible = is_machine and _element_id > 0
	if not _machine_block.visible:
		return
	var machine: Dictionary = _snapshot.get("machine", {})
	var enabled := bool(machine.get("enabled", true))
	var status := StringName(machine.get("status", &"ok"))
	if _machine_status != null:
		_machine_status.text = HudTokens.status_label(status)
		_machine_status.add_theme_color_override(
			"font_color",
			HudTokens.color_for_status(status)
		)
	if _machine_enabled_btn != null:
		_machine_enabled_btn.text = "ВЫКЛЮЧИТЬ" if enabled else "ВКЛЮЧИТЬ"
	_refresh_queue(machine.get("queue", []))
	_refresh_recipes(machine.get("recipes", []), str(machine.get("recipe_id", "")))
	_refresh_machine_progress(machine, enabled)


func _refresh_queue(queue: Array) -> void:
	if _machine_queue_box == null:
		return
	_clear_subsection_rows(_machine_queue_box)
	if queue.is_empty():
		_machine_queue_box.visible = false
		return
	_machine_queue_box.visible = true
	for index: int in range(queue.size()):
		var label := Label.new()
		label.text = "%d. %s" % [index + 1, HudTokens.recipe_label(str(queue[index]))]
		label.theme_type_variation = &"HudSmall"
		label.add_theme_color_override("font_color", HudTokens.COL_TEXT)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_machine_queue_box.add_child(label)
	var dequeue_btn := Button.new()
	dequeue_btn.text = "Убрать из очереди"
	dequeue_btn.theme_type_variation = &"HudSmall"
	dequeue_btn.pressed.connect(_on_dequeue_pressed)
	_machine_queue_box.add_child(dequeue_btn)


func _refresh_recipes(recipe_ids: Array, active_recipe_id: String) -> void:
	if _machine_recipe_box == null:
		return
	_clear_subsection_rows(_machine_recipe_box)
	_machine_recipe_box.visible = not recipe_ids.is_empty()
	for recipe_id: Variant in recipe_ids:
		var recipe := str(recipe_id)
		var btn := Button.new()
		btn.text = HudTokens.recipe_label(recipe)
		btn.theme_type_variation = &"HudSmall"
		btn.add_theme_color_override(
			"font_color",
			HudTokens.COL_VALID if recipe == active_recipe_id else HudTokens.COL_TEXT
		)
		btn.pressed.connect(_on_enqueue_pressed.bind(recipe))
		_machine_recipe_box.add_child(btn)


func _refresh_machine_progress(machine: Dictionary, enabled: bool) -> void:
	if _machine_progress_row == null:
		return
	var active := str(machine.get("recipe_id", ""))
	var show := not active.is_empty()
	_machine_progress_row.visible = show
	if not show:
		return
	if _machine_progress_name != null:
		_machine_progress_name.text = HudTokens.recipe_label(active)
	var fraction := clampf(float(machine.get("progress", 0.0)), 0.0, 1.0)
	if _machine_progress_mat != null:
		_machine_progress_mat.set_shader_parameter("fill", fraction)
		var bar_color := HudTokens.COL_VALID
		if not enabled:
			bar_color = HudTokens.COL_DIM
		elif StringName(machine.get("status", &"ok")) == &"no_power":
			bar_color = HudTokens.COL_WARNING
		_machine_progress_mat.set_shader_parameter("fill_color", bar_color)
	if _machine_progress_value != null:
		_machine_progress_value.text = "%d%%" % int(round(fraction * 100.0))


func _clear_subsection_rows(section: VBoxContainer) -> void:
	if section == null:
		return
	for child in section.get_children():
		if child is Label:
			continue
		child.queue_free()


func _machine_target() -> Dictionary:
	return InteractionHit.create(
		Vector3.ZERO,
		Vector3.UP,
		0.0,
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		&"",
		{"element_id": _element_id}
	).snapshot()


func _submit_machine_command(kind: StringName, parameters: Dictionary) -> void:
	if _gateway == null or _element_id <= 0:
		_show_feedback(&"not_ready", {})
		return
	var command_id := _gateway.submit({
		"kind": kind,
		"source": self,
		"target": _machine_target(),
		"parameters": parameters,
	})
	_pending_command_ids[command_id] = true


func _on_toggle_enabled_pressed() -> void:
	var machine: Dictionary = _snapshot.get("machine", {})
	var enabled := bool(machine.get("enabled", true))
	_submit_machine_command(&"set_machine_enabled", {
		"element_id": _element_id,
		"enabled": not enabled,
	})


func _on_enqueue_pressed(recipe_id: String) -> void:
	_submit_machine_command(&"enqueue_recipe", {
		"element_id": _element_id,
		"recipe_id": recipe_id,
	})


func _on_dequeue_pressed() -> void:
	_submit_machine_command(&"dequeue_recipe", {
		"element_id": _element_id,
	})


func _on_command_completed(command_id: int, result: Dictionary) -> void:
	var was_pending := _pending_command_ids.erase(command_id)
	if was_pending:
		var reason := StringName(result.get("reason", &"not_ready"))
		if reason != &"ok":
			_show_feedback(reason, result.get("data", {}))
	refresh()


func _on_grid_transfer_failed(reason: StringName, data: Dictionary) -> void:
	_show_feedback(reason, data)


func _show_feedback(reason: StringName, data: Dictionary) -> void:
	if _feedback_label == null:
		return
	_feedback_label.text = _feedback_text(reason, data)
	_feedback_label.visible = not _feedback_label.text.is_empty()


func _clear_feedback() -> void:
	if _feedback_label != null:
		_feedback_label.visible = false
		_feedback_label.text = ""


func _feedback_text(reason: StringName, data: Dictionary) -> String:
	match reason:
		&"no_input":
			return "Нечего переносить"
		&"storage_full":
			var resource_id := str(data.get("resource_id", ""))
			if resource_id == "construction_component":
				return "Карман компонентов полон"
			if resource_id == "raw_regolith":
				return "Карман материалов полон"
			return "Склад полон"
		&"invalid_target", &"invalid_reference":
			return "Перенос недоступен"
		&"not_ready":
			return "Симуляция не готова"
		&"queue_full":
			return "Очередь полна"
		&"no_effect":
			return "Очередь пуста"
		_:
			return "Действие недоступно"
