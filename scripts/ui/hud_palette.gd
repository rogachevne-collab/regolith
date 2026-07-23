extends Control
## "КАТАЛОГ БЛОКОВ" overlay palette (centre-screen, toggled with `toggle_palette`,
## key G). Presentation only: shows a grid of every construction archetype
## (ToolController.CONSTRUCTION_ARCHETYPES) with its latin tool code + cyrillic
## display name, styled with the frozen HudTokens theme. Dragging an entry onto a
## toolbar slot reassigns that slot via ToolController.assign_slot_archetype — a
## UI/config remap, not a simulation mutation (see docs/specs/HUD-UI-01.md). The
## palette owns only ephemeral open/drag presentation state.

const PANEL_WIDTH := 372.0
const PANEL_HEADER_HEIGHT := 96.0
const PANEL_MARGIN_V := 32.0
const PANEL_MIN_HEIGHT := 220.0
const PANEL_MAX_HEIGHT_RATIO := 0.68
const GRID_COLUMNS := 4
const ENTRY_SIZE := Vector2(78, 84)


## A draggable archetype entry. Presentation only: the drag payload is a plain
## descriptor consumed by the toolbar DropSlot; it never touches simulation.
class PaletteEntry:
	extends Panel

	var archetype_id := ""
	var code := ""
	var name_label: Label

	func _get_drag_data(_at_position: Vector2) -> Variant:
		set_drag_preview(_make_preview())
		return drag_payload()

	func drag_payload() -> Dictionary:
		return {"kind": "hud_block", "archetype_id": archetype_id}

	func _make_preview() -> Control:
		var preview := Panel.new()
		preview.theme_type_variation = &"HudSlotSelected"
		preview.custom_minimum_size = HudTokens.SLOT_SIZE
		preview.size = HudTokens.SLOT_SIZE
		# Centre the preview on the cursor.
		preview.position = -HudTokens.SLOT_SIZE * 0.5
		preview.modulate = Color(1, 1, 1, 0.9)
		var label := Label.new()
		label.text = code
		label.theme_type_variation = &"HudSmall"
		label.add_theme_color_override("font_color", HudTokens.COL_VALID)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		preview.add_child(label)
		return preview


var _gateway: Node
var _player: Node
var _panel: Panel
var _panel_overlay: ColorRect
var _scroll: ScrollContainer
var _grid: GridContainer
var _open := false
var _entries: Array[PaletteEntry] = []


func setup(ctx: Dictionary) -> void:
	_gateway = ctx.get("gateway")
	_player = ctx.get("player")
	# _build() runs in _ready(), which fires before the parent HUDRoot's own
	# _ready() calls setup() (Godot readies children before parents) — so every
	# entry is first labelled with _gateway still null. Re-stamp labels now that
	# the gateway reference exists so archetypes without a static HudTokens
	# translation (control_terminal, wizard-baked parts) don't stay frozen on
	# the raw archetype_id fallback.
	_refresh_display_names()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_apply_open_state()
	call_deferred("_update_panel_layout")


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_panel_layout()


func _build() -> void:
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.clip_contents = true
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", HudTokens.SECTION_GAP)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vb)

	# --- Header: emblem + title, national tick ---
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 10)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title_row)

	title_row.add_child(HudTokens.make_emblem())

	var title := Label.new()
	title.text = "КАТАЛОГ БЛОКОВ"
	title.theme_type_variation = &"HudTitle"
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(spacer)

	title_row.add_child(HudTokens.make_national_tick())

	vb.add_child(HudTokens.make_divider())

	var hint := Label.new()
	hint.text = "Перетащите блок на слот тулбара"
	hint.theme_type_variation = &"HudSmall"
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(hint)

	vb.add_child(HudTokens.make_gap(2))

	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	vb.add_child(_scroll)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.add_theme_constant_override("h_separation", HudTokens.SLOT_GAP)
	_grid.add_theme_constant_override("v_separation", HudTokens.SLOT_GAP)
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_grid)

	for archetype_id: String in ToolController.construction_archetype_ids():
		_grid.add_child(_make_entry(archetype_id))

	_panel_overlay = HudTokens.make_panel_overlay(Vector2(PANEL_WIDTH, PANEL_MIN_HEIGHT))
	_panel.add_child(_panel_overlay)


func _make_entry(archetype_id: String) -> Control:
	var entry := PaletteEntry.new()
	entry.archetype_id = archetype_id
	entry.code = HudTokens.tool_code(archetype_id)
	entry.theme_type_variation = &"HudSlot"
	entry.custom_minimum_size = ENTRY_SIZE
	entry.mouse_filter = Control.MOUSE_FILTER_STOP
	entry.tooltip_text = "Перетащите на слот"

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 4)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry.add_child(vb)

	var code_label := Label.new()
	code_label.text = entry.code
	code_label.theme_type_variation = &"HudValue"
	code_label.add_theme_color_override("font_color", HudTokens.COL_VALID)
	code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	code_label.clip_text = true
	code_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(code_label)

	var name_label := Label.new()
	name_label.text = _display_name(archetype_id)
	name_label.theme_type_variation = &"HudSmall"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.custom_minimum_size = Vector2(ENTRY_SIZE.x - 8, 0)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(name_label)

	entry.name_label = name_label
	_entries.append(entry)
	return entry


## Re-stamps every card's name label from the current _gateway. Safe to call
## repeatedly: cheap text-only refresh, no grid rebuild.
func _refresh_display_names() -> void:
	for entry in _entries:
		entry.name_label.text = _display_name(entry.archetype_id)


func _display_name(archetype_id: String) -> String:
	var gateway_name := ""
	if _gateway != null and _gateway.has_method("archetype_display_name"):
		gateway_name = String(_gateway.archetype_display_name(archetype_id))
	return HudTokens.archetype_label(archetype_id, gateway_name)


func _update_panel_layout() -> void:
	if _panel == null or _grid == null:
		return
	var viewport_h := _available_height()
	var grid_h := _grid.get_combined_minimum_size().y
	var ideal_h := PANEL_MARGIN_V + PANEL_HEADER_HEIGHT + grid_h
	var max_h := viewport_h * PANEL_MAX_HEIGHT_RATIO
	var panel_h := minf(ideal_h, max_h)
	panel_h = maxf(panel_h, minf(PANEL_MIN_HEIGHT, max_h))
	var half_w := PANEL_WIDTH * 0.5
	var half_h := panel_h * 0.5
	_panel.offset_left = -half_w
	_panel.offset_right = half_w
	_panel.offset_top = -half_h
	_panel.offset_bottom = half_h
	if _panel_overlay != null and _panel_overlay.material is ShaderMaterial:
		(_panel_overlay.material as ShaderMaterial).set_shader_parameter(
			"rect_size",
			Vector2(PANEL_WIDTH, panel_h)
		)


func _available_height() -> float:
	var viewport_h := get_viewport_rect().size.y
	if size.y > 0.0:
		return minf(viewport_h, size.y)
	return viewport_h


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_palette"):
		_toggle()
		get_viewport().set_input_as_handled()


func _close() -> void:
	if not _open:
		return
	_open = false
	_apply_open_state()
	UIWindowStack.remove(self)


func _toggle() -> void:
	if _open:
		_close()
		return
	if not UIWindowStack.push(self, Callable(self, "_close")):
		return
	_open = true
	_apply_open_state()


func _apply_open_state() -> void:
	if _panel == null:
		return
	_panel.visible = _open
	if _open:
		_refresh_display_names()
		call_deferred("_update_panel_layout")
	# While the palette is open the cursor must be visible to drag, and gameplay
	# input is paused so WASD/drill do not fire behind the overlay. Both are
	# ephemeral presentation concerns (mirrors player_settings_overlay).
	if _player != null and _player.has_method("set_gameplay_input_enabled"):
		_player.call("set_gameplay_input_enabled", not _open)
	Input.set_mouse_mode(
		Input.MOUSE_MODE_VISIBLE if _open else Input.MOUSE_MODE_CAPTURED
	)
