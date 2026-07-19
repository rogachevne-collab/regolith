extends Control
## Terminal inventory: player store left, target store/buffer right (INDUSTRY-V1
## § Terminal inventory). Reads StoreSnapshot via WorldCommandGateway; drag/drop
## and machine controls live in HudInventoryContainerPanel. Presentation only.


const SOLO_COLUMN_WIDTH := 264.0
const SOLO_COLUMN_MIN := 232.0
const DUAL_COLUMN_PREFERRED := 276.0
const DUAL_COLUMN_MIN := 232.0
const DUAL_COLUMN_MAX := 296.0
const PANEL_GAP := 8.0
const PANEL_MARGIN_H := 16.0
const PANEL_MARGIN_V := 14.0
const PANEL_HEADER_V := 52.0
const SAFE_LEFT := 360.0
const SAFE_RIGHT := 48.0
const SAFE_TOP := 52.0
const SAFE_BOTTOM := 140.0
const MAX_HEIGHT_RATIO := 0.62

var _gateway: WorldCommandGateway
var _query: InteractionQuery
var _player: Node

var _panel: Panel
var _panel_overlay: ColorRect
var _content: VBoxContainer
var _body_scroll: ScrollContainer
var _body: HBoxContainer
var _player_panel: HudInventoryContainerPanel
var _target_panel: HudInventoryContainerPanel
var _panel_divider: Panel
var _open := false
var _solo := true
var _target_store_id := ""
var _close_hint: Label
var _interact_release_latch := false


func setup(ctx: Dictionary) -> void:
	_gateway = ctx.get("gateway")
	_query = ctx.get("query")
	_player = ctx.get("player")
	if _player_panel != null:
		_player_panel.setup(_gateway)
	if _target_panel != null:
		_target_panel.setup(_gateway)
	if _gateway != null and _gateway.has_signal("command_completed"):
		if not _gateway.command_completed.is_connected(_on_command_completed):
			_gateway.command_completed.connect(_on_command_completed)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_apply_open_state()
	call_deferred("_update_panel_layout")


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_panel_layout()


func is_open() -> bool:
	return _open


func try_open_on_target(hit: InteractionHit) -> bool:
	if _open:
		return false
	var store_id := IndustryTransferUtil.terminal_store_id_for_hit(hit, _gateway)
	if store_id.is_empty():
		return false
	open_dual(store_id)
	return true


func blocks_world_interact() -> bool:
	return _open or _interact_release_latch


func open_solo() -> void:
	_solo = true
	_target_store_id = ""
	_open = true
	_apply_open_state()


func open_dual(target_store_id: String) -> void:
	if target_store_id.is_empty():
		return
	_solo = false
	_target_store_id = target_store_id
	_open = true
	_apply_open_state()


func close() -> void:
	if not _open:
		return
	_open = false
	_target_store_id = ""
	_apply_open_state()


func close_for_interact() -> void:
	# The focused world target remains under the cursor after terminal closes.
	# Suppress reopening it until this exact E press has been released.
	_interact_release_latch = true
	close()


func _process(_delta: float) -> void:
	if _interact_release_latch and not Input.is_action_pressed(&"interact"):
		_interact_release_latch = false


func _build() -> void:
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.clip_contents = true
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	add_child(_panel)

	_panel_overlay = HudTokens.make_panel_overlay(Vector2(SOLO_COLUMN_WIDTH, 200.0))
	_panel_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_panel_overlay)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", int(PANEL_MARGIN_H))
	margin.add_theme_constant_override("margin_right", int(PANEL_MARGIN_H))
	margin.add_theme_constant_override("margin_top", int(PANEL_MARGIN_V))
	margin.add_theme_constant_override("margin_bottom", int(PANEL_MARGIN_V))
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(margin)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 6)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_content)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(title_row)
	title_row.add_child(HudTokens.make_emblem(14.0))
	var title := Label.new()
	title.text = "ТЕРМИНАЛ"
	title.theme_type_variation = &"HudSmall"
	title.add_theme_color_override("font_color", HudTokens.COL_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	_close_hint = Label.new()
	_close_hint.text = "E / I / Esc — закрыть"
	_close_hint.theme_type_variation = &"HudSmall"
	_close_hint.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_close_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	_close_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_close_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_close_hint.visible = false
	_content.add_child(_close_hint)

	_content.add_child(HudTokens.make_divider())

	_body_scroll = ScrollContainer.new()
	_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_body_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_body_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_body_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_scroll.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.add_child(_body_scroll)
	_body = HBoxContainer.new()
	_body.add_theme_constant_override("separation", int(PANEL_GAP))
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body_scroll.add_child(_body)

	_player_panel = HudInventoryContainerPanel.new()
	_player_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# Keep both store panels aligned to the top. A short/empty cargo panel must
	# not be vertically centered beside a fuller player inventory.
	_player_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_body.add_child(_player_panel)

	_panel_divider = Panel.new()
	_panel_divider.theme_type_variation = &"HudDivider"
	_panel_divider.custom_minimum_size = Vector2(1.0, 0.0)
	_panel_divider.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel_divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(_panel_divider)

	_target_panel = HudInventoryContainerPanel.new()
	_target_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_target_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_body.add_child(_target_panel)


func _input(event: InputEvent) -> void:
	if _open and _is_close_event(event):
		if event.is_action_pressed("interact"):
			close_for_interact()
		else:
			close()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		if event.is_action_pressed("toggle_inventory"):
			open_solo()
			get_viewport().set_input_as_handled()
		return


func _is_close_event(event: InputEvent) -> bool:
	return (
		event.is_action_pressed("toggle_inventory")
		or event.is_action_pressed("interact")
		or event.is_action_pressed("release_mouse")
		or event.is_action_pressed("ui_cancel")
	)


func _apply_open_state() -> void:
	if _panel == null:
		return
	_panel.visible = _open
	if _close_hint != null:
		_close_hint.visible = _open
	if not _open:
		call_deferred("_restore_gameplay_input_if_still_closed")
		return
	_wire_peer_panels()
	_refresh_panels()
	call_deferred("_update_panel_layout")
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


func _wire_peer_panels() -> void:
	if _player_panel == null or _target_panel == null:
		return
	if _solo:
		_target_panel.visible = false
		_panel_divider.visible = false
		_player_panel.set_peer_store_id("")
	else:
		_target_panel.visible = true
		_panel_divider.visible = true
		_player_panel.set_peer_store_id(_target_store_id)
		_target_panel.set_peer_store_id(PlayerIdentity.local_store_id())


func _refresh_panels() -> void:
	if _gateway == null or _player_panel == null:
		return
	var player_snap := _gateway.store_snapshot(PlayerIdentity.local_store_id())
	if bool(player_snap.get("valid", true)):
		_player_panel.apply_snapshot(player_snap)
	if _solo or _target_panel == null or _target_store_id.is_empty():
		return
	var target_snap := _gateway.store_snapshot(_target_store_id)
	if bool(target_snap.get("valid", true)):
		_target_panel.apply_snapshot(target_snap)


func _on_command_completed(_command_id: int, _result: Dictionary) -> void:
	if _open:
		_refresh_panels()
		call_deferred("_update_panel_layout")


func _update_panel_layout() -> void:
	if _panel == null or _body == null or not _open:
		return
	var vp := get_viewport_rect().size
	var safe_rect := _safe_rect(vp)
	var panel_count := 1 if _solo else 2
	var body_width := _body_width_for_mode(panel_count, safe_rect.size.x)
	var column_width := _column_width_for_mode(panel_count, body_width)

	var slot_size := HudTokens.SLOT_SIZE
	var max_body_h := _max_body_height(safe_rect.size.y)
	var layout_ctx := {
		"column_width": column_width,
		"slot_size": slot_size,
		"max_grid_height": max_body_h,
	}
	_player_panel.size_flags_horizontal = (
		Control.SIZE_SHRINK_CENTER if _solo else Control.SIZE_EXPAND_FILL
	)
	_target_panel.size_flags_horizontal = (
		Control.SIZE_SHRINK_CENTER if _solo else Control.SIZE_EXPAND_FILL
	)
	_player_panel.configure_layout(layout_ctx)
	if not _solo and _target_panel.visible:
		_target_panel.configure_layout(layout_ctx)

	var body_h := _body.get_combined_minimum_size().y
	body_h = minf(body_h, max_body_h)
	_body.custom_minimum_size = Vector2(body_width, 0.0)
	_body_scroll.custom_minimum_size = Vector2(body_width, body_h)
	_body_scroll.size = Vector2(body_width, body_h)
	_body_scroll.vertical_scroll_mode = (
		ScrollContainer.SCROLL_MODE_AUTO
		if _body.get_combined_minimum_size().y > body_h + 0.5
		else ScrollContainer.SCROLL_MODE_DISABLED
	)
	var panel_w := body_width + PANEL_MARGIN_H * 2.0
	var panel_h := PANEL_HEADER_V + PANEL_MARGIN_V * 2.0 + body_h
	panel_h = minf(panel_h, safe_rect.size.y)

	var half_w := panel_w * 0.5
	var half_h := panel_h * 0.5
	var shift := _panel_center_shift(vp, safe_rect)
	_panel.offset_left = -half_w + shift.x
	_panel.offset_right = half_w + shift.x
	_panel.offset_top = -half_h + shift.y
	_panel.offset_bottom = half_h + shift.y
	if _panel_overlay != null and _panel_overlay.material is ShaderMaterial:
		(_panel_overlay.material as ShaderMaterial).set_shader_parameter(
			"rect_size",
			Vector2(panel_w, panel_h)
		)


func _safe_rect(viewport_size: Vector2) -> Rect2:
	return Rect2(
		Vector2(SAFE_LEFT, SAFE_TOP),
		Vector2(
			maxf(viewport_size.x - SAFE_LEFT - SAFE_RIGHT, 160.0),
			maxf(viewport_size.y - SAFE_TOP - SAFE_BOTTOM, 160.0),
		)
	)


func _body_width_for_mode(panel_count: int, safe_width: float) -> float:
	var available := maxf(safe_width - PANEL_MARGIN_H * 2.0, SOLO_COLUMN_MIN)
	if panel_count == 1:
		return minf(SOLO_COLUMN_WIDTH, available)
	var max_columns_width := maxf(
		(available - PANEL_GAP * 2.0 - 1.0) * 0.5,
		DUAL_COLUMN_MIN
	)
	var column_width := clampf(
		DUAL_COLUMN_PREFERRED,
		DUAL_COLUMN_MIN,
		minf(DUAL_COLUMN_MAX, max_columns_width)
	)
	return column_width * 2.0 + PANEL_GAP * 2.0 + 1.0


func _column_width_for_mode(panel_count: int, body_width: float) -> float:
	if panel_count == 1:
		return clampf(body_width, SOLO_COLUMN_MIN, SOLO_COLUMN_WIDTH)
	return clampf(
		(body_width - PANEL_GAP * 2.0 - 1.0) * 0.5,
		DUAL_COLUMN_MIN,
		DUAL_COLUMN_MAX
	)


func _max_body_height(safe_height: float) -> float:
	var capped := minf(safe_height, _available_height() * MAX_HEIGHT_RATIO)
	return maxf(capped - PANEL_HEADER_V - PANEL_MARGIN_V * 2.0, 96.0)


func _panel_center_shift(viewport_size: Vector2, safe_rect: Rect2) -> Vector2:
	var vp_center := viewport_size * 0.5
	var safe_center := safe_rect.position + safe_rect.size * 0.5
	return safe_center - vp_center


func _available_height() -> float:
	var viewport_h := get_viewport_rect().size.y
	if size.y > 0.0:
		return minf(viewport_h, size.y)
	return viewport_h
