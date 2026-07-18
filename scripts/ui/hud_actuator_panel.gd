extends Control
## Centered actuator settings panel (piston or rotor). Opens on E while
## targeting an actuator; shows the mouse cursor so +/- rows are clickable
## (FPS crosshair cannot reach corner HUD).

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
var _travel_key: Label
var _travel_val: Label
var _tune_box: VBoxContainer
var _motor_btn: Button
var _chain_btn: Button
var _hints: Label
var _tune_values: Dictionary = {}
var _tune_mode := ""
var _open := false
var _target_hit: InteractionHit
var _pending_command_ids: Dictionary = {}
var _interact_release_latch := false
var _tool_controller: Node


func setup(ctx: Dictionary) -> void:
	_gateway = ctx.get("gateway")
	_query = ctx.get("query")
	_player = ctx.get("player")
	_tool_controller = ctx.get("tools")
	if _tool_controller == null and _player != null:
		_tool_controller = _player.get_node_or_null("ToolController")
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
	if not HudActuatorTuneUtil.is_actuator_meta(hit.metadata):
		return false
	_target_hit = hit
	_open = true
	_apply_open_state()
	return true


func close() -> void:
	if not _open:
		return
	_open = false
	_target_hit = InteractionHit.empty()
	_apply_open_state()


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
		and HudActuatorTuneUtil.is_actuator_meta(hit.metadata)
		and HudActuatorTuneUtil.joint_id(hit.metadata)
		== HudActuatorTuneUtil.joint_id(_target_hit.metadata)
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
	_panel.offset_top = -168.0
	_panel.offset_bottom = 168.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	_panel_overlay = HudTokens.make_panel_overlay(Vector2(PANEL_WIDTH, 336.0))
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
	_title.text = "ПОРШЕНЬ"
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
	_status_val = _add_info_row(vb, "СОСТОЯНИЕ", HudTokens.COL_OK)
	_travel_val = _add_info_row(vb, "ХОД", HudTokens.COL_TEXT)
	_travel_key = (_travel_val.get_parent().get_child(0) as Label)
	vb.add_child(HudTokens.make_divider())

	_tune_box = VBoxContainer.new()
	_tune_box.add_theme_constant_override("separation", 4)
	_tune_box.mouse_filter = Control.MOUSE_FILTER_STOP
	vb.add_child(_tune_box)
	_ensure_tune_rows(HudActuatorTuneUtil.TUNE_ROWS, "piston")

	var control_row := HBoxContainer.new()
	control_row.add_theme_constant_override("separation", 8)
	control_row.mouse_filter = Control.MOUSE_FILTER_STOP
	vb.add_child(control_row)
	_motor_btn = Button.new()
	_motor_btn.theme_type_variation = &"HudSmall"
	_motor_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_motor_btn.pressed.connect(_on_motor_toggle_pressed)
	control_row.add_child(_motor_btn)
	_chain_btn = Button.new()
	_chain_btn.theme_type_variation = &"HudSmall"
	_chain_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chain_btn.pressed.connect(_on_chain_toggle_pressed)
	control_row.add_child(_chain_btn)

	_hints = Label.new()
	_hints.theme_type_variation = &"HudSmall"
	_hints.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_hints.text = "[+] выдв · [-] втяг · Y стоп"
	_hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_hints)


func _ensure_tune_rows(rows: Array[Dictionary], mode: String) -> void:
	if _tune_mode == mode:
		return
	_tune_mode = mode
	_tune_values.clear()
	for child_node: Node in _tune_box.get_children():
		_tune_box.remove_child(child_node)
		child_node.queue_free()
	for row: Dictionary in rows:
		_build_tune_row(_tune_box, str(row["key"]), str(row["field"]))


func _configure_for_meta(meta: Dictionary) -> void:
	if HudActuatorTuneUtil.is_rotor_meta(meta):
		_title.text = "РОТОР"
		_travel_key.text = "УГОЛ"
		_hints.text = "[+] вращ+ · [-] вращ− · Y стоп"
		_ensure_tune_rows(HudActuatorTuneUtil.ROTOR_TUNE_ROWS, "rotor")
	elif HudActuatorTuneUtil.is_hinge_meta(meta):
		_title.text = "ШАРНИР"
		_travel_key.text = "УГОЛ"
		_hints.text = "[+] сгиб+ · [-] сгиб− · Y стоп"
		_ensure_tune_rows(HudActuatorTuneUtil.HINGE_TUNE_ROWS, "hinge")
	else:
		_title.text = "ПОРШЕНЬ"
		_travel_key.text = "ХОД"
		_hints.text = "[+] выдв · [-] втяг · Y стоп · цепь = все поршни"
		_ensure_tune_rows(HudActuatorTuneUtil.TUNE_ROWS, "piston")
	if _chain_btn != null:
		_chain_btn.visible = not (
			HudActuatorTuneUtil.is_rotor_meta(meta)
			or HudActuatorTuneUtil.is_hinge_meta(meta)
		)


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
	var meta := hit.metadata
	_configure_for_meta(meta)
	var actuator_status := StringName(meta.get("actuator_status", &"idle"))
	_status_val.text = HudTokens.status_label(actuator_status)
	_status_val.add_theme_color_override(
		"font_color",
		HudTokens.color_for_status(actuator_status)
	)
	if HudActuatorTuneUtil.is_rotor_meta(meta):
		var angle_deg := rad_to_deg(
			float(meta.get("rotor_observed_angle_rad", 0.0))
		)
		var target_velocity := float(
			meta.get("rotor_target_velocity_rad_s", 0.0)
		)
		_travel_val.text = "%.0f° · ЦЕЛЬ %.2f РАД/С" % [angle_deg, target_velocity]
	elif HudActuatorTuneUtil.is_hinge_meta(meta):
		var hinge_angle_deg := rad_to_deg(
			float(meta.get("hinge_observed_angle_rad", 0.0))
		)
		var hinge_target_velocity := float(
			meta.get("hinge_target_velocity_rad_s", 0.0)
		)
		_travel_val.text = "%.0f° · ЦЕЛЬ %.2f РАД/С" % [
			hinge_angle_deg,
			hinge_target_velocity,
		]
	else:
		var observed := float(meta.get("piston_observed_position_m", 0.0))
		var target := float(meta.get("piston_target_position_m", observed))
		_travel_val.text = "%.2f / %.2f М" % [observed, target]
	for row: Dictionary in HudActuatorTuneUtil.rows_for(meta):
		var field := str(row["field"])
		var label: Label = _tune_values.get(field)
		if label != null:
			label.text = HudActuatorTuneUtil.format_value(field, meta)
	_refresh_control_buttons(meta)


func _refresh_control_buttons(meta: Dictionary) -> void:
	var enabled := true
	if HudActuatorTuneUtil.is_rotor_meta(meta):
		enabled = bool(meta.get("rotor_motor_enabled", true))
	elif HudActuatorTuneUtil.is_hinge_meta(meta):
		enabled = bool(meta.get("hinge_motor_enabled", true))
	else:
		enabled = bool(meta.get("piston_motor_enabled", true))
	if _motor_btn != null:
		_motor_btn.text = "МОТОР: ВКЛ" if enabled else "МОТОР: ВЫКЛ"
	if _chain_btn != null:
		var sync := false
		if (
			_tool_controller != null
			and _tool_controller.has_method("is_actuator_chain_sync")
		):
			sync = bool(_tool_controller.call("is_actuator_chain_sync"))
		_chain_btn.text = "ЦЕПЬ: ВКЛ" if sync else "ЦЕПЬ: ВЫКЛ"


func _on_motor_toggle_pressed() -> void:
	if _tool_controller == null or not _target_hit.valid:
		return
	if _tool_controller.has_method("toggle_actuator_motor"):
		_tool_controller.call("toggle_actuator_motor", _current_hit())


func _on_chain_toggle_pressed() -> void:
	if _tool_controller == null:
		return
	if not _tool_controller.has_method("set_actuator_chain_sync"):
		return
	var sync := false
	if _tool_controller.has_method("is_actuator_chain_sync"):
		sync = bool(_tool_controller.call("is_actuator_chain_sync"))
	_tool_controller.call("set_actuator_chain_sync", not sync)
	_refresh_control_buttons(_current_hit().metadata)


func _on_tune_pressed(field: String, direction: int) -> void:
	if _gateway == null or not _target_hit.valid:
		return
	var meta := _current_hit().metadata
	var new_value := HudActuatorTuneUtil.next_value(meta, field, direction)
	if is_nan(new_value):
		return
	# Hinge angle limits are legitimately negative; other actuators keep the
	# "-1 means invalid field" sentinel.
	if not HudActuatorTuneUtil.is_hinge_meta(meta) and new_value < 0.0:
		return
	var parameters := {
		"joint_id": HudActuatorTuneUtil.joint_id(meta),
		field: new_value,
	}
	var command_id := _gateway.submit({
		"kind": &"configure_actuator",
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
			"configure_actuator failed: %s" % HudTokens.status_label(reason)
		)


func _input(event: InputEvent) -> void:
	if _open and _is_close_event(event):
		if event.is_action_pressed("interact"):
			close_for_interact()
		else:
			close()
		get_viewport().set_input_as_handled()


func _is_close_event(event: InputEvent) -> bool:
	return (
		event.is_action_pressed("interact")
		or event.is_action_pressed("release_mouse")
		or event.is_action_pressed("ui_cancel")
	)


func _apply_open_state() -> void:
	if _panel == null:
		return
	_panel.visible = _open
	if not _open:
		call_deferred("_restore_gameplay_input_if_still_closed")
		return
	_refresh_from_hit(_target_hit)
	if _player != null and _player.has_method("set_gameplay_input_enabled"):
		_player.call("set_gameplay_input_enabled", false)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _restore_gameplay_input_if_still_closed() -> void:
	if _open:
		return
	_restore_gameplay_input()


func _restore_gameplay_input() -> void:
	if _player != null and _player.has_method("set_gameplay_input_enabled"):
		_player.call("set_gameplay_input_enabled", true)
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
