extends Control
## Centered wheel/suspension settings panel. Opens on E while targeting a module.

const PANEL_WIDTH := 320.0
const INFO_ROW_HEIGHT := 18
const KEY_COL := HudTokens.INFO_KEY_COL

var _gateway: WorldCommandGateway
var _query: InteractionQuery
var _player: Node

var _panel: PanelContainer
var _panel_overlay: ColorRect
var _title: Label
var _status_val: Label
var _steer_row: HBoxContainer
var _steer_val: Label
var _tune_box: VBoxContainer
var _tune_values: Dictionary = {}
var _open := false
var _target_hit: InteractionHit
var _pending_command_ids: Dictionary = {}
var _interact_release_latch := false


func setup(ctx: Dictionary) -> void:
	_gateway = ctx.get("gateway")
	_query = ctx.get("query")
	_player = ctx.get("player")
	if (
		_gateway != null
		and not _gateway.command_completed.is_connected(_on_command_completed)
	):
		_gateway.command_completed.connect(_on_command_completed)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_apply_open_state()


func is_open() -> bool:
	return _open


func blocks_world_interact() -> bool:
	return _open or _interact_release_latch


func try_open_on_target(hit: InteractionHit) -> bool:
	if _open or hit == null or not hit.valid:
		return false
	if HudWheelTuneUtil.rows_for_hit(hit).is_empty():
		return false
	if not UIWindowStack.push(self, Callable(self, "close")):
		return false
	_target_hit = hit
	_open = true
	_apply_open_state()
	_rebuild_tune_rows()
	_refresh_from_hit(hit)
	return true


func close() -> void:
	if not _open:
		return
	_open = false
	_target_hit = InteractionHit.empty()
	_apply_open_state()
	UIWindowStack.remove(self)


func close_for_interact() -> void:
	_interact_release_latch = true
	close()


func _process(_delta: float) -> void:
	if _interact_release_latch and not Input.is_action_pressed(&"interact"):
		_interact_release_latch = false
	if not _open:
		return
	_refresh_from_hit(_current_hit())


func _current_hit() -> InteractionHit:
	if _query == null:
		return _target_hit
	var hit := _query.current_hit
	if (
		hit.valid
		and int(hit.metadata.get("element_id", 0))
		== int(_target_hit.metadata.get("element_id", 0))
	):
		return hit
	return _target_hit


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -PANEL_WIDTH * 0.5
	_panel.offset_right = PANEL_WIDTH * 0.5
	_panel.offset_top = -132.0
	_panel.offset_bottom = 132.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	_panel_overlay = HudTokens.make_panel_overlay(Vector2(PANEL_WIDTH, 264.0))
	_panel_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_panel_overlay)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", HudTokens.SECTION_GAP)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vb)

	var title_row := HBoxContainer.new()
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title_row)
	title_row.add_child(HudTokens.make_emblem(14.0))
	_title = Label.new()
	_title.theme_type_variation = &"HudSmall"
	_title.add_theme_color_override("font_color", HudTokens.COL_TITLE)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_title)
	var close_hint := Label.new()
	close_hint.text = "E / Esc — закрыть"
	close_hint.theme_type_variation = &"HudSmall"
	close_hint.add_theme_color_override("font_color", HudTokens.COL_DIM)
	close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_row.add_child(close_hint)

	vb.add_child(HudTokens.make_divider())
	_status_val = _add_info_row(vb, "СТАТУС", HudTokens.COL_TEXT)
	_steer_row = HBoxContainer.new()
	_steer_row.custom_minimum_size.y = INFO_ROW_HEIGHT
	_steer_row.mouse_filter = Control.MOUSE_FILTER_STOP
	vb.add_child(_steer_row)
	var steer_key := Label.new()
	steer_key.text = "РУЛЬ"
	steer_key.theme_type_variation = &"HudSmall"
	steer_key.custom_minimum_size = Vector2(KEY_COL, INFO_ROW_HEIGHT)
	_steer_row.add_child(steer_key)
	var steer_toggle := Button.new()
	steer_toggle.text = "перекл"
	steer_toggle.theme_type_variation = &"HudSmall"
	steer_toggle.custom_minimum_size = Vector2(52, INFO_ROW_HEIGHT)
	steer_toggle.pressed.connect(_on_toggle_steerable)
	_steer_row.add_child(steer_toggle)
	_steer_val = Label.new()
	_steer_val.theme_type_variation = &"HudValue"
	_steer_val.add_theme_color_override("font_color", HudTokens.COL_TEXT)
	_steer_val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_steer_row.add_child(_steer_val)
	vb.add_child(HudTokens.make_divider())
	_tune_box = VBoxContainer.new()
	_tune_box.add_theme_constant_override("separation", 4)
	_tune_box.mouse_filter = Control.MOUSE_FILTER_STOP
	vb.add_child(_tune_box)


func _add_info_row(parent_node: Node, key: String, value_color: Color) -> Label:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = INFO_ROW_HEIGHT
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent_node.add_child(row)
	var k := Label.new()
	k.text = key
	k.theme_type_variation = &"HudSmall"
	k.custom_minimum_size = Vector2(KEY_COL, INFO_ROW_HEIGHT)
	row.add_child(k)
	var v := Label.new()
	v.theme_type_variation = &"HudValue"
	v.add_theme_color_override("font_color", value_color)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(v)
	return v


func _rebuild_tune_rows() -> void:
	for child_node: Node in _tune_box.get_children():
		child_node.queue_free()
	_tune_values.clear()
	for row: Dictionary in HudWheelTuneUtil.rows_for_hit(_target_hit):
		_build_tune_row(_tune_box, str(row["key"]), str(row["field"]))


func _build_tune_row(parent_node: Node, key: String, field: String) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = INFO_ROW_HEIGHT
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	parent_node.add_child(row)
	var k := Label.new()
	k.text = key
	k.theme_type_variation = &"HudSmall"
	k.custom_minimum_size = Vector2(KEY_COL, INFO_ROW_HEIGHT)
	row.add_child(k)
	var minus := Button.new()
	minus.text = "−"
	minus.theme_type_variation = &"HudSmall"
	minus.custom_minimum_size = Vector2(22, INFO_ROW_HEIGHT)
	minus.pressed.connect(_on_tune_pressed.bind(field, -1))
	row.add_child(minus)
	var value := Label.new()
	value.theme_type_variation = &"HudValue"
	value.add_theme_color_override("font_color", HudTokens.COL_TEXT)
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(value)
	var plus := Button.new()
	plus.text = "+"
	plus.theme_type_variation = &"HudSmall"
	plus.custom_minimum_size = Vector2(22, INFO_ROW_HEIGHT)
	plus.pressed.connect(_on_tune_pressed.bind(field, 1))
	row.add_child(plus)
	_tune_values[field] = value


func _refresh_from_hit(hit: InteractionHit) -> void:
	if hit == null or not hit.valid:
		return
	_title.text = HudWheelTuneUtil.panel_title(hit)
	# По возможностям детали, а не по списку id: испечённая визардом деталь
	# иначе молча остаётся без строки руля.
	var is_wheel := hit.metadata.has("wheel_element_id")
	_steer_row.visible = is_wheel
	if is_wheel:
		var powered := bool(hit.metadata.get("wheel_powered", false))
		var status := StringName(
			hit.metadata.get(
				"wheel_status",
				&"ok" if powered else &"no_power"
			)
		)
		_status_val.text = {
			&"ok": "контакт",
			&"airborne": "в воздухе",
			&"no_power": "нет питания",
			&"invalid_body": "ошибка физики",
		}.get(status, str(status))
		_status_val.add_theme_color_override(
			"font_color",
			HudTokens.COL_OK if status == &"ok" else HudTokens.COL_WARNING
		)
		_steer_val.text = (
			"поворотное" if bool(hit.metadata.get("wheel_steerable", false))
			else "фиксированное"
		)
	else:
		_status_val.text = "—"
		_status_val.add_theme_color_override("font_color", HudTokens.COL_DIM)
	for row: Dictionary in HudWheelTuneUtil.rows_for_hit(hit):
		var field := str(row["field"])
		var label: Label = _tune_values.get(field)
		if label != null:
			label.text = HudWheelTuneUtil.format_value(field, hit.metadata)


func _on_toggle_steerable() -> void:
	if _gateway == null or not _target_hit.valid:
		return
	var meta := _current_hit().metadata
	var command_id := _gateway.submit({
		"kind": &"configure_wheel",
		"source": self,
		"target": _target_hit.snapshot(),
		"parameters": {
			"wheel_element_id": int(meta.get("wheel_element_id", 0)),
			"steerable": not bool(meta.get("wheel_steerable", false)),
		},
	})
	_pending_command_ids[command_id] = true


func _on_tune_pressed(field: String, direction: int) -> void:
	if _gateway == null or not _target_hit.valid:
		return
	var meta := _current_hit().metadata
	var new_value := HudWheelTuneUtil.next_value(meta, field, direction)
	if new_value < 0.0:
		return
	var kind := HudWheelTuneUtil.configure_kind_for_hit(_target_hit)
	if kind.is_empty():
		return
	var parameters := {}
	if kind == &"configure_wheel":
		parameters["wheel_element_id"] = int(meta.get("wheel_element_id", 0))
	else:
		parameters["suspension_element_id"] = int(
			meta.get("suspension_element_id", 0)
		)
	parameters[field] = new_value
	var command_id := _gateway.submit({
		"kind": kind,
		"source": self,
		"target": _target_hit.snapshot(),
		"parameters": parameters,
	})
	_pending_command_ids[command_id] = true


func _on_command_completed(command_id: int, result: Dictionary) -> void:
	if not _pending_command_ids.erase(command_id):
		return
	var reason := StringName(result.get("reason", &"not_ready"))
	if reason != &"ok":
		push_warning(
			"configure wheel module failed: %s" % HudTokens.status_label(reason)
		)


func _apply_open_state() -> void:
	_panel.visible = _open
	if _open:
		if _player != null and _player.has_method("set_gameplay_input_enabled"):
			_player.call("set_gameplay_input_enabled", false)
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		if _player != null and _player.has_method("set_gameplay_input_enabled"):
			_player.call("set_gameplay_input_enabled", true)
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
