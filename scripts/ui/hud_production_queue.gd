class_name HudProductionQueue
extends Control
## Factory-window production queue. Shows the active job with a live progress
## bar plus the pending queue as visual cards, grouping consecutive identical
## recipes into a single ×N card. Left click on a pending card cancels that
## whole run via `dequeue_recipe` (index + count). Presentation only.

const OUTPUT_ICON := 34.0
const PROGRESS_WIDTH := 132.0
const INNER_MARGIN := 10

signal command_submitted(command_id: int)

var _gateway: WorldCommandGateway
var _element_id := 0
var _machine: Dictionary = {}
var _last_queue_sig := "__unset__"

var _status_label: Label
var _enabled_btn: Button
var _clear_btn: Button
var _active_box: VBoxContainer
var _active_icon_holder: Control
var _active_name: Label
var _active_progress_row: HBoxContainer
var _active_progress_mat: ShaderMaterial
var _active_progress_value: Label
var _empty_label: Label
var _queue_scroll: ScrollContainer
var _queue_list: VBoxContainer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()


func setup(gateway: WorldCommandGateway) -> void:
	_gateway = gateway


func set_element_id(element_id: int) -> void:
	_element_id = element_id


func apply_machine(machine: Dictionary) -> void:
	_machine = machine.duplicate(true)
	_refresh()


func _build() -> void:
	var frame := PanelContainer.new()
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_stylebox_override("panel", HudTokens.make_subpanel_style())
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", INNER_MARGIN)
	margin.add_theme_constant_override("margin_right", INNER_MARGIN)
	margin.add_theme_constant_override("margin_top", INNER_MARGIN)
	margin.add_theme_constant_override("margin_bottom", INNER_MARGIN)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vb)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(header)
	var title := HudTokens.make_section_header("ОЧЕРЕДЬ")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(title)
	_clear_btn = Button.new()
	_clear_btn.text = "Очистить"
	_clear_btn.theme_type_variation = &"HudSmall"
	_clear_btn.pressed.connect(_on_clear_pressed)
	header.add_child(_clear_btn)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 6)
	status_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(status_row)
	_status_label = Label.new()
	_status_label.theme_type_variation = &"HudSmall"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.clip_text = true
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_row.add_child(_status_label)
	_enabled_btn = Button.new()
	_enabled_btn.theme_type_variation = &"HudSmall"
	_enabled_btn.pressed.connect(_on_toggle_enabled)
	status_row.add_child(_enabled_btn)

	vb.add_child(HudTokens.make_divider())

	_active_box = VBoxContainer.new()
	_active_box.add_theme_constant_override("separation", 4)
	_active_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_active_box)

	var active_row := HBoxContainer.new()
	active_row.add_theme_constant_override("separation", 8)
	active_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_active_box.add_child(active_row)
	_active_icon_holder = Control.new()
	_active_icon_holder.custom_minimum_size = Vector2(OUTPUT_ICON, OUTPUT_ICON)
	_active_icon_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	active_row.add_child(_active_icon_holder)
	var active_info := VBoxContainer.new()
	active_info.add_theme_constant_override("separation", 3)
	active_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	active_info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	active_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	active_row.add_child(active_info)
	_active_name = Label.new()
	_active_name.theme_type_variation = &"HudSmall"
	_active_name.add_theme_color_override("font_color", HudTokens.COL_TITLE)
	_active_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	active_info.add_child(_active_name)
	var progress := HudTokens.make_progress_bar(PROGRESS_WIDTH, "")
	_active_progress_row = progress["row"] as HBoxContainer
	(_active_progress_row.get_child(0) as Label).text = ""
	(_active_progress_row.get_child(0) as Label).custom_minimum_size = Vector2(0, 0)
	_active_progress_mat = progress["mat"] as ShaderMaterial
	_active_progress_value = progress["value"] as Label
	HudTokens.stretch_progress_bar(_active_progress_row, _active_progress_mat)
	active_info.add_child(_active_progress_row)

	_empty_label = Label.new()
	_empty_label.text = "ПРОСТОЙ · очередь пуста"
	_empty_label.theme_type_variation = &"HudSmall"
	_empty_label.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_empty_label)

	_queue_scroll = ScrollContainer.new()
	_queue_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_queue_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_queue_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_queue_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_queue_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	vb.add_child(_queue_scroll)
	_queue_list = VBoxContainer.new()
	_queue_list.add_theme_constant_override("separation", 5)
	_queue_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_queue_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_queue_scroll.add_child(_queue_list)


func _refresh() -> void:
	var enabled := bool(_machine.get("enabled", true))
	var status := StringName(_machine.get("status", &"ok"))
	if _status_label != null:
		_status_label.text = HudTokens.status_label(status)
		_status_label.add_theme_color_override(
			"font_color",
			HudTokens.color_for_status(status)
		)
	if _enabled_btn != null:
		_enabled_btn.text = "ВЫКЛ" if enabled else "ВКЛ"
	_refresh_active(enabled, status)
	_refresh_queue()


func _refresh_active(enabled: bool, status: StringName) -> void:
	var active := str(_machine.get("recipe_id", ""))
	var has_active := not active.is_empty()
	if _active_box != null:
		_active_box.visible = has_active
	if _empty_label != null:
		var queue: Array = _machine.get("queue", [])
		_empty_label.visible = not has_active and queue.is_empty()
	if not has_active:
		return
	for child_node in _active_icon_holder.get_children():
		child_node.queue_free()
	var output_id := _primary_output(active)
	if not output_id.is_empty():
		_active_icon_holder.add_child(
			HudTokens.make_item_icon(output_id, OUTPUT_ICON)
		)
	if _active_name != null:
		_active_name.text = "В РАБОТЕ · %s" % HudTokens.recipe_label(active)
	var fraction := clampf(float(_machine.get("progress", 0.0)), 0.0, 1.0)
	if _active_progress_mat != null:
		_active_progress_mat.set_shader_parameter("fill", fraction)
		var bar_color := HudTokens.COL_VALID
		if not enabled:
			bar_color = HudTokens.COL_DIM
		elif status == &"no_power" or status == &"storage_full":
			bar_color = HudTokens.COL_WARNING
		_active_progress_mat.set_shader_parameter("fill_color", bar_color)
	if _active_progress_value != null:
		_active_progress_value.text = "%d%%" % int(round(fraction * 100.0))


func _refresh_queue() -> void:
	if _queue_list == null:
		return
	var queue: Array = _machine.get("queue", [])
	if _clear_btn != null:
		_clear_btn.disabled = queue.is_empty()
	if _queue_scroll != null:
		_queue_scroll.visible = not queue.is_empty()
	# Rebuild the cards only when the queue actually changed. A poll that leaves
	# the queue untouched must not free cards mid-hover/click.
	var signature := "|".join(PackedStringArray(queue.map(func(x): return str(x))))
	if signature == _last_queue_sig:
		return
	_last_queue_sig = signature
	for child_node in _queue_list.get_children():
		child_node.queue_free()
	var runs := _group_runs(queue)
	for run: Dictionary in runs:
		_queue_list.add_child(_make_run_card(run))


## Collapse consecutive identical recipe ids into runs while preserving the
## absolute queue index so cancel maps back to `dequeue_recipe` cleanly.
func _group_runs(queue: Array) -> Array:
	var runs: Array = []
	var index := 0
	while index < queue.size():
		var recipe_id := str(queue[index])
		var count := 1
		while index + count < queue.size() and str(queue[index + count]) == recipe_id:
			count += 1
		runs.append({"recipe_id": recipe_id, "start": index, "count": count})
		index += count
	return runs


func _make_run_card(run: Dictionary) -> Control:
	var recipe_id := str(run.get("recipe_id", ""))
	var start := int(run.get("start", 0))
	var count := int(run.get("count", 1))
	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.tooltip_text = "ЛКМ — отменить (×%d)" % count
	card.add_theme_stylebox_override("panel", _card_style(false))
	card.gui_input.connect(_on_run_input.bind(start, count))
	card.mouse_entered.connect(_on_run_hover.bind(card, true))
	card.mouse_exited.connect(_on_run_hover.bind(card, false))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_bottom", 5)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	var output_id := _primary_output(recipe_id)
	if not output_id.is_empty():
		row.add_child(HudTokens.make_item_icon(output_id, OUTPUT_ICON))

	var name_label := Label.new()
	name_label.text = HudTokens.recipe_label(recipe_id)
	name_label.theme_type_variation = &"HudSmall"
	name_label.add_theme_color_override("font_color", HudTokens.COL_TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)

	var count_label := Label.new()
	count_label.text = "×%d" % count
	count_label.theme_type_variation = &"HudValue"
	count_label.add_theme_color_override("font_color", HudTokens.COL_TITLE)
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(count_label)
	return card


func _card_style(hovered: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.09, 0.13, 0.17, 0.55)
	box.set_corner_radius_all(2)
	box.set_border_width_all(1)
	box.border_color = HudTokens.COL_BORDER
	if hovered:
		box.border_color = HudTokens.COL_CRITICAL
		box.bg_color = Color(0.16, 0.11, 0.11, 0.7)
	return box


func _on_run_hover(card: Control, hovered: bool) -> void:
	if card != null:
		card.add_theme_stylebox_override("panel", _card_style(hovered))


func _on_run_input(event: InputEvent, start: int, count: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_dequeue(start, count)
	accept_event()


func _on_clear_pressed() -> void:
	var queue: Array = _machine.get("queue", [])
	if queue.is_empty():
		return
	_dequeue(0, queue.size())


func _on_toggle_enabled() -> void:
	if _gateway == null or _element_id <= 0:
		return
	var enabled := bool(_machine.get("enabled", true))
	var command_id := _gateway.submit({
		"kind": &"set_machine_enabled",
		"source": self,
		"target": _machine_target(),
		"parameters": {"element_id": _element_id, "enabled": not enabled},
	})
	command_submitted.emit(command_id)


func _dequeue(index: int, count: int) -> void:
	if _gateway == null or _element_id <= 0:
		return
	var command_id := _gateway.submit({
		"kind": &"dequeue_recipe",
		"source": self,
		"target": _machine_target(),
		"parameters": {
			"element_id": _element_id,
			"index": maxi(0, index),
			"count": maxi(1, count),
		},
	})
	command_submitted.emit(command_id)


func _primary_output(recipe_id: String) -> String:
	var outputs := RecipeCatalog.outputs(recipe_id)
	var best_id := ""
	var best_amount := -1.0
	for resource_id: Variant in outputs.keys():
		var amount := float(outputs[resource_id])
		if amount > best_amount:
			best_amount = amount
			best_id = str(resource_id)
	return best_id


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
