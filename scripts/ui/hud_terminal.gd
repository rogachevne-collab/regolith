extends Control
## Terminal window (INDUSTRY-V1 § Terminal inventory). One fixed, screen-centred
## rectangle: player store fills the left column, the right column holds either
## the target store alone or — for a recipe machine — the factory stack
## (recipes + queue on top, machine store below). Reads StoreSnapshot via
## WorldCommandGateway; drag/drop and machine controls live in the child
## widgets. Presentation only.


# Screen-safe box the window is centred in: leaves the compass above and the
# toolbar / vitals below untouched.
const SCREEN_MARGIN_H := 48.0
const SCREEN_MARGIN_TOP := 56.0
const SCREEN_MARGIN_BOTTOM := 132.0

const PANEL_MARGIN := 16.0
const CONTENT_GAP := 10.0
const COLUMN_GAP := 12.0

# Frozen window footprints per mode; each is clamped to the safe box.
const SOLO_SIZE := Vector2(372.0, 520.0)
const DUAL_SIZE := Vector2(768.0, 560.0)
const FACTORY_SIZE := Vector2(1040.0, 660.0)

const LEFT_COLUMN := 296.0
const LEFT_COLUMN_MIN := 232.0
const LEFT_COLUMN_RATIO := 0.42
const CATALOG_STRETCH := 1.9
const QUEUE_STRETCH := 1.0
const EXTRAS_STRETCH := 1.7
const STORE_STRETCH := 1.0
const FACTORY_REFRESH_INTERVAL := 0.2

var _gateway: WorldCommandGateway
var _query: InteractionQuery
var _player: Node

var _panel: Panel
var _panel_overlay: ColorRect
var _content: VBoxContainer
var _body: HBoxContainer
var _right_column: VBoxContainer
var _player_panel: HudInventoryContainerPanel
var _target_panel: HudInventoryContainerPanel
var _factory_extras: HBoxContainer
var _recipe_catalog: HudRecipeCatalog
var _queue_view: HudProductionQueue
var _machine_mode := false
var _factory_element_id := 0
var _factory_refresh_accum := 0.0
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
	if _recipe_catalog != null:
		_recipe_catalog.setup(_gateway)
	if _queue_view != null:
		_queue_view.setup(_gateway)
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


func _process(delta: float) -> void:
	if _interact_release_latch and not Input.is_action_pressed(&"interact"):
		_interact_release_latch = false
	if _open and _machine_mode:
		_factory_refresh_accum += delta
		if _factory_refresh_accum >= FACTORY_REFRESH_INTERVAL:
			_factory_refresh_accum = 0.0
			_refresh_factory()


func _build() -> void:
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.clip_contents = true
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	add_child(_panel)

	_panel_overlay = HudTokens.make_panel_overlay(FACTORY_SIZE)
	_panel_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_panel_overlay)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", int(PANEL_MARGIN))
	margin.add_theme_constant_override("margin_right", int(PANEL_MARGIN))
	margin.add_theme_constant_override("margin_top", int(PANEL_MARGIN))
	margin.add_theme_constant_override("margin_bottom", int(PANEL_MARGIN))
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(margin)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", int(CONTENT_GAP))
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_content)

	_build_header()
	_content.add_child(HudTokens.make_divider())

	_body = HBoxContainer.new()
	_body.add_theme_constant_override("separation", int(COLUMN_GAP))
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_body)

	_player_panel = HudInventoryContainerPanel.new()
	_player_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_player_panel)

	_right_column = VBoxContainer.new()
	_right_column.add_theme_constant_override("separation", int(COLUMN_GAP))
	_right_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_right_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(_right_column)

	_factory_extras = HBoxContainer.new()
	_factory_extras.add_theme_constant_override("separation", int(COLUMN_GAP))
	_factory_extras.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_factory_extras.size_flags_stretch_ratio = EXTRAS_STRETCH
	_factory_extras.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_factory_extras.visible = false
	_right_column.add_child(_factory_extras)

	_recipe_catalog = HudRecipeCatalog.new()
	_recipe_catalog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipe_catalog.size_flags_stretch_ratio = CATALOG_STRETCH
	_factory_extras.add_child(_recipe_catalog)

	_queue_view = HudProductionQueue.new()
	_queue_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_queue_view.size_flags_stretch_ratio = QUEUE_STRETCH
	_factory_extras.add_child(_queue_view)

	_target_panel = HudInventoryContainerPanel.new()
	_target_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_target_panel.size_flags_stretch_ratio = STORE_STRETCH
	_right_column.add_child(_target_panel)


func _build_header() -> void:
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(title_row)

	title_row.add_child(HudTokens.make_emblem(14.0))
	var title := Label.new()
	title.text = "ТЕРМИНАЛ"
	title.theme_type_variation = &"HudSmall"
	title.add_theme_color_override("font_color", HudTokens.COL_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_row.add_child(title)

	_close_hint = Label.new()
	_close_hint.text = "E / I / Esc — закрыть"
	_close_hint.theme_type_variation = &"HudSmall"
	_close_hint.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_close_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_close_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	# No overrun trimming: a trimmable label reports a near-zero minimum width,
	# so the expanding title next to it would eat the hint entirely.
	_close_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(_close_hint)


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
	_right_column.visible = not _solo
	if _solo:
		_player_panel.set_peer_store_id("")
	else:
		_player_panel.set_peer_store_id(_target_store_id)
		_target_panel.set_peer_store_id(PlayerIdentity.local_store_id())


func _refresh_panels() -> void:
	if _gateway == null or _player_panel == null:
		return
	var player_snap := _gateway.store_snapshot(PlayerIdentity.local_store_id())
	if bool(player_snap.get("valid", true)):
		_player_panel.apply_snapshot(player_snap)
	if _solo or _target_panel == null or _target_store_id.is_empty():
		_set_machine_mode(false, {})
		return
	var target_snap := _gateway.store_snapshot(_target_store_id)
	if bool(target_snap.get("valid", true)):
		_target_panel.apply_snapshot(target_snap)
		_apply_factory_mode(target_snap)
	else:
		_set_machine_mode(false, {})


func _apply_factory_mode(target_snap: Dictionary) -> void:
	var machine: Variant = target_snap.get("machine", null)
	var is_recipe_machine: bool = (
		bool(target_snap.get("is_machine", false))
		and machine is Dictionary
		and not (machine as Dictionary).get("recipes", []).is_empty()
	)
	if not is_recipe_machine:
		_set_machine_mode(false, {})
		return
	_factory_element_id = HudInventoryTransferUtil.element_id_for_store(
		_target_store_id
	)
	_set_machine_mode(true, machine as Dictionary)


func _set_machine_mode(on: bool, machine: Dictionary) -> void:
	var mode_changed := _machine_mode != on
	_machine_mode = on
	if _factory_extras != null:
		_factory_extras.visible = on
	if _target_panel != null:
		_target_panel.set_machine_controls_visible(not on)
	if not on:
		_factory_element_id = 0
		if mode_changed:
			call_deferred("_update_panel_layout")
		return
	if _recipe_catalog != null:
		_recipe_catalog.set_element_id(_factory_element_id)
		_recipe_catalog.apply_machine(machine)
	if _queue_view != null:
		_queue_view.set_element_id(_factory_element_id)
		_queue_view.apply_machine(machine)
	if mode_changed:
		call_deferred("_update_panel_layout")


## Lightweight poll while a factory window is open: the sim tick advances job
## progress and completes jobs without emitting a command, so we re-read the
## machine snapshot to keep the progress bar and queue live. The widgets skip
## rebuilds when nothing changed, so this stays cheap and click-safe.
func _refresh_factory() -> void:
	if _gateway == null or not _machine_mode or _target_store_id.is_empty():
		return
	var target_snap := _gateway.store_snapshot(_target_store_id)
	if not bool(target_snap.get("valid", true)):
		return
	if _target_panel != null:
		_target_panel.apply_snapshot(target_snap)
	_apply_factory_mode(target_snap)


func _on_command_completed(_command_id: int, _result: Dictionary) -> void:
	if _open:
		_refresh_panels()


## The window is a fixed rectangle centred in the screen-safe box: the columns
## inside it stretch, so nothing here depends on how full a store happens to be.
func _update_panel_layout() -> void:
	if _panel == null or not _open:
		return
	var vp := get_viewport_rect().size
	var safe_rect := _safe_rect(vp)
	var panel_size := Vector2(
		minf(_preferred_size().x, safe_rect.size.x),
		minf(_preferred_size().y, safe_rect.size.y)
	)
	var center := safe_rect.position + safe_rect.size * 0.5
	var offset := center - vp * 0.5
	_panel.offset_left = offset.x - panel_size.x * 0.5
	_panel.offset_right = offset.x + panel_size.x * 0.5
	_panel.offset_top = offset.y - panel_size.y * 0.5
	_panel.offset_bottom = offset.y + panel_size.y * 0.5
	if _panel_overlay != null and _panel_overlay.material is ShaderMaterial:
		(_panel_overlay.material as ShaderMaterial).set_shader_parameter(
			"rect_size",
			panel_size
		)
	_apply_column_widths(panel_size.x - PANEL_MARGIN * 2.0)


func _apply_column_widths(content_width: float) -> void:
	var slot_size := HudTokens.SLOT_SIZE
	if _solo:
		_player_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_player_panel.configure_layout({
			"column_width": content_width,
			"slot_size": slot_size,
		})
		return
	# Two plain stores read as a pair — split them evenly. Only the factory
	# window pins the player to a narrow column so the machine side gets the
	# room its recipes and queue need.
	var left := (content_width - COLUMN_GAP) * 0.5
	if _machine_mode:
		left = clampf(
			LEFT_COLUMN,
			LEFT_COLUMN_MIN,
			maxf(content_width * LEFT_COLUMN_RATIO, LEFT_COLUMN_MIN)
		)
	var right := maxf(content_width - left - COLUMN_GAP, LEFT_COLUMN_MIN)
	_player_panel.size_flags_horizontal = (
		Control.SIZE_FILL if _machine_mode else Control.SIZE_EXPAND_FILL
	)
	_player_panel.configure_layout({
		"column_width": left,
		"slot_size": slot_size,
	})
	_target_panel.configure_layout({
		"column_width": right,
		"slot_size": slot_size,
	})


func _preferred_size() -> Vector2:
	if _solo:
		return SOLO_SIZE
	return FACTORY_SIZE if _machine_mode else DUAL_SIZE


func _safe_rect(viewport_size: Vector2) -> Rect2:
	return Rect2(
		Vector2(SCREEN_MARGIN_H, SCREEN_MARGIN_TOP),
		Vector2(
			maxf(viewport_size.x - SCREEN_MARGIN_H * 2.0, 320.0),
			maxf(
				viewport_size.y - SCREEN_MARGIN_TOP - SCREEN_MARGIN_BOTTOM,
				280.0
			),
		)
	)
