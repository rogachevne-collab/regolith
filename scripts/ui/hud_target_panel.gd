extends Control
## Top-left target readout panel. Presentation only: reads
## InteractionQuery.current_hit metadata for a simulation element and displays
## its name / status / integrity with the frozen state palette. Hidden unless a
## simulation element is targeted. Never mutates state.

const MACHINE_PROGRESS_BAR_WIDTH := 112.0
const PANEL_MARGIN_V := 18
const INFO_ROW_HEIGHT := 18
const HINT_LINES_HEIGHT := 30
const MAX_RECIPE_LINES := 8
const KEY_COL := HudTokens.INFO_KEY_COL
const INDEX_LETTERS: PackedStringArray = [
	"А", "Б", "В", "Г", "Д", "Е", "Ж", "З", "И", "К",
	"Л", "М", "Н", "П", "Р", "С", "Т", "У", "Ф", "Ц",
]

var _query: InteractionQuery
var _gateway: WorldCommandGateway
var _tools: ToolController

var _panel: PanelContainer
var _emblem_mat: ShaderMaterial
var _callsign: Label
var _distance: Label
var _name_val: Label
var _status_val: Label
var _metric_key: Label
var _metric_val: Label
var _store_view: HudStoreView
var _machine_block: VBoxContainer
var _machine_power_val: Label
var _machine_queue_box: VBoxContainer
var _machine_active_val: Label
var _machine_cargo_val: Label
var _machine_recipe_box: VBoxContainer
var _machine_hints: Label
var _machine_drill_info: Label
var _actuator_tune_box: VBoxContainer
var _actuator_tune_values: Dictionary = {}
var _actuator_tune_mode := ""
var _machine_progress_row: HBoxContainer
var _machine_progress_name: Label
var _machine_progress_mat: ShaderMaterial
var _machine_progress_value: Label
var _max_integrity_cache: Dictionary = {}
var _last_store_element_id := -1
var _panel_overlay: ColorRect
var _panel_overlay_mat: ShaderMaterial


func setup(ctx: Dictionary) -> void:
	_query = ctx.get("query")
	_gateway = ctx.get("gateway")
	_tools = ctx.get("tools")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_panel.visible = false


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.position = Vector2(HudTokens.PANEL_MARGIN, HudTokens.PANEL_MARGIN)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.resized.connect(_on_panel_resized)
	add_child(_panel)

	_panel_overlay = HudTokens.make_panel_overlay(Vector2(360.0, 128.0))
	_panel_overlay_mat = _panel_overlay.material as ShaderMaterial
	_panel_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_panel_overlay)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", PANEL_MARGIN_V)
	margin.add_theme_constant_override("margin_bottom", PANEL_MARGIN_V)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", HudTokens.SECTION_GAP)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vb)

	# Compact header: keep identity and distance, drop decorative chrome so the
	# readout remains subordinate to the world view.
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title_row)

	var emblem := HudTokens.make_emblem(14.0)
	_emblem_mat = emblem.material as ShaderMaterial
	title_row.add_child(emblem)

	var header_text := VBoxContainer.new()
	header_text.add_theme_constant_override("separation", 1)
	header_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(header_text)
	var title := Label.new()
	title.text = "ЦЕЛЬ"
	title.theme_type_variation = &"HudSmall"
	title.add_theme_color_override("font_color", HudTokens.COL_TITLE)
	header_text.add_child(title)
	_callsign = Label.new()
	_callsign.theme_type_variation = &"HudSmall"
	header_text.add_child(_callsign)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(spacer)

	_distance = Label.new()
	_distance.theme_type_variation = &"HudSmall"
	_distance.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_distance.size_flags_horizontal = Control.SIZE_SHRINK_END
	title_row.add_child(_distance)

	vb.add_child(HudTokens.make_divider())

	_name_val = _add_info_row(vb, "ТИП", HudTokens.COL_TEXT)
	_status_val = _add_info_row(vb, "СОСТОЯНИЕ", HudTokens.COL_OK)
	var metric := _add_info_row_keyed(vb, "ЦЕЛОСТНОСТЬ", HudTokens.COL_OK)
	_metric_key = metric[0] as Label
	_metric_val = metric[1] as Label

	_store_view = HudStoreView.new()
	_store_view.visible = false
	_store_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(_store_view)

	_machine_block = VBoxContainer.new()
	_machine_block.add_theme_constant_override("separation", 8)
	_machine_block.visible = false
	_machine_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_machine_block)

	_machine_power_val = _add_info_row(_machine_block, "ПИТАНИЕ", HudTokens.COL_TEXT)
	_machine_queue_box = _make_subsection(_machine_block, "ОЧЕРЕДЬ")
	_prefill_subsection_labels(
		_machine_queue_box,
		IndustryArchetypeProfile.queue_max_depth()
	)
	_machine_active_val = _add_info_row(_machine_block, "СЕЙЧАС", HudTokens.COL_OK)
	_machine_cargo_val = _add_info_row(_machine_block, "КАРГО", HudTokens.COL_TEXT)
	_machine_block.add_child(HudTokens.make_divider())
	_machine_recipe_box = _make_subsection(_machine_block, "РЕЦЕПТЫ")
	_prefill_subsection_labels(_machine_recipe_box, MAX_RECIPE_LINES)
	_machine_hints = Label.new()
	_machine_hints.theme_type_variation = &"HudSmall"
	_machine_hints.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_machine_hints.autowrap_mode = TextServer.AUTOWRAP_OFF
	_machine_hints.custom_minimum_size.y = HINT_LINES_HEIGHT
	_machine_hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_machine_block.add_child(_machine_hints)

	_actuator_tune_box = VBoxContainer.new()
	_actuator_tune_box.add_theme_constant_override("separation", 4)
	_actuator_tune_box.visible = false
	_actuator_tune_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_machine_block.add_child(_actuator_tune_box)
	_ensure_actuator_readout_rows(HudActuatorTuneUtil.TUNE_ROWS, "piston")

	_machine_drill_info = Label.new()
	_machine_drill_info.theme_type_variation = &"HudSmall"
	_machine_drill_info.add_theme_color_override("font_color", HudTokens.COL_TEXT)
	_machine_drill_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_machine_drill_info.visible = false
	_machine_drill_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_machine_drill_info)

	var progress := HudTokens.make_progress_bar(MACHINE_PROGRESS_BAR_WIDTH, "")
	_machine_progress_row = progress["row"] as HBoxContainer
	_machine_progress_name = _machine_progress_row.get_child(0) as Label
	_machine_progress_name.custom_minimum_size = Vector2(0, INFO_ROW_HEIGHT)
	_machine_progress_name.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_machine_progress_name.size_flags_stretch_ratio = 1.0
	_machine_progress_name.autowrap_mode = TextServer.AUTOWRAP_OFF
	_machine_progress_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var progress_bar := _machine_progress_row.get_child(1) as ColorRect
	progress_bar.custom_minimum_size.x = MACHINE_PROGRESS_BAR_WIDTH
	progress_bar.size_flags_horizontal = Control.SIZE_SHRINK_END
	_machine_progress_mat = progress["mat"] as ShaderMaterial
	_machine_progress_value = progress["value"] as Label
	_machine_progress_value.size_flags_horizontal = Control.SIZE_SHRINK_END
	_machine_progress_row.visible = false
	vb.add_child(_machine_progress_row)
	_on_panel_resized()


func _on_panel_resized() -> void:
	if _panel_overlay_mat != null and _panel != null:
		_panel_overlay_mat.set_shader_parameter("rect_size", _panel.size)


func _make_subsection(parent_node: Node, title: String) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 4)
	section.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent_node.add_child(section)
	var header := Label.new()
	header.text = title
	header.theme_type_variation = &"HudSmall"
	header.add_theme_color_override("font_color", HudTokens.COL_DIM)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	section.add_child(header)
	return section


func _make_list_label() -> Label:
	var item := Label.new()
	item.theme_type_variation = &"HudSmall"
	item.custom_minimum_size.y = 14
	item.autowrap_mode = TextServer.AUTOWRAP_OFF
	item.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.visible = false
	return item


func _prefill_subsection_labels(section: VBoxContainer, count: int) -> void:
	for _i: int in range(count):
		section.add_child(_make_list_label())


func _subsection_line_labels(section: VBoxContainer) -> Array[Label]:
	var labels: Array[Label] = []
	for child_node: Node in section.get_children():
		if child_node is Label and child_node.get_index() > 0:
			labels.append(child_node as Label)
	return labels


func _add_info_row(parent_node: Node, key: String, value_color: Color) -> Label:
	return _add_info_row_keyed(parent_node, key, value_color)[1] as Label


func _add_info_row_keyed(parent_node: Node, key: String, value_color: Color) -> Array:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = INFO_ROW_HEIGHT
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent_node.add_child(row)
	var k := Label.new()
	k.text = key
	k.theme_type_variation = &"HudSmall"
	k.custom_minimum_size = Vector2(KEY_COL, INFO_ROW_HEIGHT)
	k.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(k)
	var v := Label.new()
	v.theme_type_variation = &"HudValue"
	v.add_theme_color_override("font_color", value_color)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.custom_minimum_size.y = INFO_ROW_HEIGHT
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	v.autowrap_mode = TextServer.AUTOWRAP_OFF
	v.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(v)
	return [k, v]


func _ensure_actuator_readout_rows(
	rows: Array[Dictionary],
	mode: String
) -> void:
	if _actuator_tune_mode == mode:
		return
	_actuator_tune_mode = mode
	_actuator_tune_values.clear()
	for child_node: Node in _actuator_tune_box.get_children():
		_actuator_tune_box.remove_child(child_node)
		child_node.queue_free()
	for row: Dictionary in rows:
		_build_actuator_readout_row(str(row["key"]), str(row["field"]))


func _build_actuator_readout_row(key: String, field: String) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = INFO_ROW_HEIGHT
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_actuator_tune_box.add_child(row)
	var k := Label.new()
	k.text = key
	k.theme_type_variation = &"HudSmall"
	k.custom_minimum_size = Vector2(KEY_COL, INFO_ROW_HEIGHT)
	k.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(k)
	var value := Label.new()
	value.theme_type_variation = &"HudValue"
	value.add_theme_color_override("font_color", HudTokens.COL_TEXT)
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.custom_minimum_size.y = INFO_ROW_HEIGHT
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value)
	_actuator_tune_values[field] = value


func _process(_delta: float) -> void:
	if _query == null:
		return
	var hit := _query.current_hit
	if not hit.valid or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT:
		_panel.visible = false
		return
	_panel.visible = true
	var meta := hit.metadata
	var archetype_id := str(meta.get("archetype_id", ""))
	var status := StringName(meta.get("status_reason", &"element_incomplete"))
	var status_color := HudTokens.color_for_status(status)

	_emblem_mat.set_shader_parameter("color", status_color)
	_callsign.text = "ОБЪЕКТ %02d · ИНДЕКС %02d-%s" % [
		int(meta.get("assembly_id", 0)) % 100,
		int(meta.get("element_id", 0)) % 100,
		_index_letter(int(meta.get("element_id", 0))),
	]
	_distance.text = "%.1f М" % hit.distance
	_name_val.text = _gateway.archetype_display_name(archetype_id).to_upper()

	_status_val.text = _status_summary(meta, status)
	_status_val.add_theme_color_override("font_color", status_color)

	_metric_key.text = "ЦЕЛОСТНОСТЬ"
	_metric_val.text = "%d%%" % int(round(_integrity_fraction(archetype_id, meta) * 100.0))
	_metric_val.add_theme_color_override("font_color", status_color)
	_refresh_store_view(archetype_id, meta)
	if _refresh_actuator_info(hit, meta, status):
		return
	_actuator_tune_box.visible = false
	_refresh_machine_info(archetype_id, meta, hit)


func _status_summary(meta: Dictionary, status: StringName) -> String:
	if meta.has("actuator_status"):
		return HudTokens.status_label(
			StringName(meta.get("actuator_status", &"idle"))
		)
	if status == &"port_disconnected" or status == &"cargo_disconnected":
		return HudTokens.status_label(status)
	if status == &"no_input":
		var missing := str(meta.get("missing_input_resource_id", ""))
		if not missing.is_empty():
			return "НЕТ %s" % HudTokens.resource_label(missing)
		if not bool(meta.get("cargo_network_connected", false)):
			return "НЕТ КАРГО-СВЯЗИ"
		return "НЕТ СЫРЬЯ"
	if status == &"standby":
		return "ПРОСТОЙ"
	return HudTokens.status_label(status)


func _refresh_store_view(archetype_id: String, meta: Dictionary) -> void:
	if _store_view == null or _gateway == null:
		return
	if archetype_id != "cargo_store":
		_store_view.visible = false
		_last_store_element_id = -1
		return
	var element_id := int(meta.get("element_id", 0))
	if element_id <= 0:
		_store_view.visible = false
		return
	var store_id := IndustryStoreService.element_store_id(element_id)
	var store := _gateway.resource_store(store_id)
	if store == null:
		_store_view.visible = false
		return
	_store_view.visible = true
	if element_id != _last_store_element_id:
		_store_view.bind(store, "СКЛАД")
		_last_store_element_id = element_id
	else:
		_store_view.refresh()


func _refresh_actuator_info(
	_hit: InteractionHit,
	meta: Dictionary,
	status: StringName
) -> bool:
	if not HudActuatorTuneUtil.is_actuator_meta(meta):
		return false
	var is_rotor := HudActuatorTuneUtil.is_rotor_meta(meta)
	var is_hinge := HudActuatorTuneUtil.is_hinge_meta(meta)
	var is_angular := is_rotor or is_hinge
	_store_view.visible = false
	_machine_block.visible = true
	_actuator_tune_box.visible = true
	_machine_drill_info.visible = false
	_set_machine_progress_visible(false)
	var target_velocity: float
	var powered: bool
	var enabled: bool
	if is_rotor:
		target_velocity = float(meta.get("rotor_target_velocity_rad_s", 0.0))
		powered = bool(meta.get("rotor_powered", false))
		enabled = bool(meta.get("rotor_motor_enabled", true))
	elif is_hinge:
		target_velocity = float(meta.get("hinge_target_velocity_rad_s", 0.0))
		powered = bool(meta.get("hinge_powered", false))
		enabled = bool(meta.get("hinge_motor_enabled", true))
	else:
		target_velocity = float(meta.get("piston_target_velocity_mps", 0.0))
		powered = bool(meta.get("piston_powered", false))
		enabled = bool(meta.get("piston_motor_enabled", true))
	var actuator_status := StringName(meta.get("actuator_status", status))
	_refresh_actuator_tune_values(meta)
	if is_rotor:
		_metric_key.text = "УГОЛ"
		_metric_val.text = "%.0f°" % rad_to_deg(
			float(meta.get("rotor_observed_angle_rad", 0.0))
		)
	elif is_hinge:
		_metric_key.text = "УГОЛ"
		_metric_val.text = "%.0f° [%.0f°…%.0f°]" % [
			rad_to_deg(float(meta.get("hinge_observed_angle_rad", 0.0))),
			rad_to_deg(float(meta.get("hinge_lower_limit_rad", -PI / 2.0))),
			rad_to_deg(float(meta.get("hinge_upper_limit_rad", PI / 2.0))),
		]
	else:
		var observed := float(meta.get("piston_observed_position_m", 0.0))
		var target := float(meta.get("piston_target_position_m", observed))
		_metric_key.text = "ХОД"
		_metric_val.text = "%.2f / %.2f М" % [observed, target]
	_metric_val.add_theme_color_override(
		"font_color",
		HudTokens.color_for_status(actuator_status)
	)
	_status_val.text = _status_summary(meta, actuator_status)
	_status_val.add_theme_color_override(
		"font_color",
		HudTokens.color_for_status(actuator_status)
	)
	_machine_power_val.get_parent().visible = true
	if not enabled:
		_machine_power_val.text = "ВЫКЛЮЧЕН"
		_machine_power_val.add_theme_color_override(
			"font_color",
			HudTokens.COL_DIM
		)
	elif powered:
		_machine_power_val.text = "ПИТАНИЕ ЕСТЬ"
		_machine_power_val.add_theme_color_override(
			"font_color",
			HudTokens.COL_OK
		)
	else:
		_machine_power_val.text = "НЕТ ПИТАНИЯ"
		_machine_power_val.add_theme_color_override(
			"font_color",
			HudTokens.COL_WARNING
		)
	_machine_queue_box.visible = false
	_machine_active_val.get_parent().visible = false
	_machine_cargo_val.get_parent().visible = false
	_machine_recipe_box.visible = false
	_machine_hints.visible = true
	if is_rotor:
		_machine_hints.text = "E — настройки · [+] вращ+ · [-] вращ− · Y стоп"
	elif is_hinge:
		_machine_hints.text = "E — настройки · [+] сгиб+ · [-] сгиб− · Y стоп"
	else:
		_machine_hints.text = "E — настройки · [+] выдв · [-] втяг · Y стоп"
	if absf(target_velocity) > 0.0001:
		_status_val.text = (
			"%s · %.2f %s"
			% [
				_status_summary(meta, actuator_status),
				target_velocity,
				"РАД/С" if is_angular else "М/С",
			]
		)
	return true


func _refresh_actuator_tune_values(meta: Dictionary) -> void:
	_ensure_actuator_readout_rows(
		HudActuatorTuneUtil.rows_for(meta),
		HudActuatorTuneUtil.mode_for(meta)
	)
	for row: Dictionary in HudActuatorTuneUtil.rows_for(meta):
		var field := str(row["field"])
		_set_actuator_tune_value(
			field,
			HudActuatorTuneUtil.format_value(field, meta)
		)


func _set_actuator_tune_value(field: String, text: String) -> void:
	var label: Label = _actuator_tune_values.get(field)
	if label != null:
		label.text = text


func _refresh_machine_info(
	archetype_id: String,
	meta: Dictionary,
	hit: InteractionHit
) -> void:
	if _machine_block == null:
		return
	if archetype_id not in ["stationary_drill", "processor", "fabricator"]:
		_machine_block.visible = false
		_machine_drill_info.visible = false
		_set_machine_progress_visible(false)
		return
	_store_view.visible = false
	var active := str(meta.get("active_recipe_id", ""))
	var is_working := not active.is_empty()
	var enabled := bool(meta.get("machine_enabled", true))
	if archetype_id == "stationary_drill":
		_machine_block.visible = false
		_machine_drill_info.visible = true
		_set_machine_progress_visible(false)
		_machine_drill_info.text = "Головка: рабочая грань +X\nE — открыть инвентарь"
		return
	_machine_block.visible = true
	_machine_drill_info.visible = false
	var queue: Array = meta.get("recipe_queue", [])
	var missing := str(meta.get("missing_input_resource_id", ""))
	var status := StringName(meta.get("status_reason", &"ok"))
	var next_recipe := (
		_tools.next_recipe_for_target(hit)
		if _tools != null
		else ""
	)
	if is_working:
		_machine_power_val.get_parent().visible = false
		_machine_queue_box.visible = false
		_machine_active_val.get_parent().visible = false
		_machine_recipe_box.visible = false
		_machine_hints.visible = false
		var cargo_note := _format_cargo_network(meta)
		if not missing.is_empty():
			cargo_note = "НЕТ %s" % HudTokens.resource_label(missing)
		elif status in [&"storage_full", &"no_input", &"port_disconnected"]:
			cargo_note = HudTokens.status_label(status)
		var show_cargo := (
			not missing.is_empty()
			or status in [&"storage_full", &"no_input", &"port_disconnected"]
		)
		_machine_block.visible = show_cargo
		_machine_cargo_val.get_parent().visible = show_cargo
		_machine_cargo_val.text = cargo_note
	else:
		_machine_block.visible = true
		_machine_power_val.get_parent().visible = true
		_machine_power_val.text = "ВКЛЮЧЕНО" if enabled else "ВЫКЛЮЧЕНО"
		_machine_power_val.add_theme_color_override(
			"font_color",
			HudTokens.COL_OK if enabled else HudTokens.COL_DIM
		)
		_machine_queue_box.visible = not queue.is_empty()
		if not queue.is_empty():
			_refresh_queue_list(queue)
		else:
			_refresh_queue_list([])
		_machine_active_val.get_parent().visible = false
		_machine_cargo_val.get_parent().visible = true
		_machine_cargo_val.text = _format_cargo_network(meta)
		_machine_recipe_box.visible = true
		_refresh_recipe_picker(archetype_id, next_recipe)
		_machine_hints.text = "E — открыть инвентарь"
	_refresh_machine_progress(meta, enabled, active)


func _refresh_queue_list(queue: Array) -> void:
	if _machine_queue_box == null:
		return
	var labels := _subsection_line_labels(_machine_queue_box)
	for index: int in range(labels.size()):
		var item := labels[index]
		if index < queue.size():
			item.text = "%d. %s" % [
				index + 1,
				HudTokens.recipe_label(str(queue[index])),
			]
			item.add_theme_color_override("font_color", HudTokens.COL_TEXT)
			item.visible = true
		else:
			item.visible = false


func _refresh_recipe_picker(archetype_id: String, selected_recipe_id: String) -> void:
	if _machine_recipe_box == null:
		return
	var recipe_ids := RecipeCatalog.recipe_ids_for_machine(archetype_id)
	var labels := _subsection_line_labels(_machine_recipe_box)
	for index: int in range(labels.size()):
		var item := labels[index]
		if index < recipe_ids.size():
			var recipe_id: String = recipe_ids[index]
			var marker := "▸ " if recipe_id == selected_recipe_id else "   "
			item.text = "%s%s" % [marker, HudTokens.recipe_label(recipe_id)]
			item.add_theme_color_override(
				"font_color",
				HudTokens.COL_VALID if recipe_id == selected_recipe_id else HudTokens.COL_TEXT
			)
			item.visible = true
		else:
			item.visible = false


func _format_cargo_network(meta: Dictionary) -> String:
	if not bool(meta.get("cargo_network_connected", false)):
		return "НЕТ СВЯЗИ"
	var parts: PackedStringArray = []
	var raw_amount := float(meta.get("cargo_network_raw_regolith", 0.0))
	var fines_amount := float(meta.get("cargo_network_regolith_fines", 0.0))
	if raw_amount > 0.000001:
		parts.append(
			"%s %s" % [
				HudTokens.resource_label("raw_regolith"),
				HudTokens.format_amount(raw_amount),
			]
		)
	if fines_amount > 0.000001:
		parts.append(
			"%s %s" % [
				HudTokens.resource_label("regolith_fines"),
				HudTokens.format_amount(fines_amount),
			]
		)
	if parts.is_empty():
		return "СКЛАД ПУСТ"
	return "%s" % " · ".join(parts)


func _refresh_machine_progress(
	meta: Dictionary,
	enabled: bool,
	active: String = ""
) -> void:
	if _machine_progress_mat == null or _machine_progress_value == null:
		return
	if active.is_empty():
		active = str(meta.get("active_recipe_id", ""))
	var show_bar := not active.is_empty()
	_set_machine_progress_visible(show_bar)
	if not show_bar:
		return
	if _machine_progress_name != null:
		_machine_progress_name.text = HudTokens.recipe_label(active)
	var duration_s := maxf(float(meta.get("recipe_duration_s", 0.0)), 0.000001)
	var fraction := clampf(
		float(meta.get("recipe_progress_s", 0.0)) / duration_s,
		0.0,
		1.0
	)
	var status := StringName(meta.get("status_reason", &"ok"))
	var bar_color := HudTokens.COL_VALID
	if not enabled:
		bar_color = HudTokens.COL_DIM
	elif status == &"no_power":
		bar_color = HudTokens.COL_WARNING
	elif status != &"ok":
		bar_color = HudTokens.color_for_status(status)
	_machine_progress_mat.set_shader_parameter("fill", fraction)
	_machine_progress_mat.set_shader_parameter("fill_color", bar_color)
	_machine_progress_mat.set_shader_parameter(
		"lead_strength",
		0.75 if fraction > 0.02 and enabled and status == &"ok" else 0.2
	)
	_machine_progress_value.text = "%d%%" % int(round(fraction * 100.0))
	_machine_progress_value.add_theme_color_override("font_color", bar_color)


func _set_machine_progress_visible(is_visible: bool) -> void:
	if _machine_progress_row != null:
		_machine_progress_row.visible = is_visible


func _integrity_fraction(archetype_id: String, meta: Dictionary) -> float:
	var current := float(meta.get("integrity", 0.0))
	var maximum := _max_integrity(archetype_id)
	if maximum <= 0.0:
		return 0.0
	return clampf(current / maximum, 0.0, 1.0)


func _max_integrity(archetype_id: String) -> float:
	if _max_integrity_cache.has(archetype_id):
		return _max_integrity_cache[archetype_id]
	var archetype := Slice01Archetypes.load_required(archetype_id)
	var value := archetype.max_integrity if archetype != null else 0.0
	_max_integrity_cache[archetype_id] = value
	return value


func _index_letter(element_id: int) -> String:
	if INDEX_LETTERS.is_empty():
		return "Х"
	return INDEX_LETTERS[element_id % INDEX_LETTERS.size()]
