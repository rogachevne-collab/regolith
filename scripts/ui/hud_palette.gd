extends Control
## "КАТАЛОГ БЛОКОВ" overlay palette (centre-screen, toggled with `toggle_palette`,
## key G). Presentation only: shows a grid of every construction archetype
## (ToolController.CONSTRUCTION_ARCHETYPES) with its latin tool code + cyrillic
## display name, styled with the frozen HudTokens theme. Dragging an entry onto a
## toolbar slot reassigns that slot via ToolController.assign_slot_archetype — a
## UI/config remap, not a simulation mutation (see docs/specs/HUD-UI-01.md). The
## palette owns only ephemeral open/drag presentation state.

const PANEL_SIZE := Vector2(372, 300)
const GRID_COLUMNS := 4
const ENTRY_SIZE := Vector2(78, 84)


## A draggable archetype entry. Presentation only: the drag payload is a plain
## descriptor consumed by the toolbar DropSlot; it never touches simulation.
class PaletteEntry:
	extends Panel

	var archetype_id := ""
	var code := ""

	func _get_drag_data(_at_position: Vector2) -> Variant:
		set_drag_preview(_make_preview())
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
var _open := false


func setup(ctx: Dictionary) -> void:
	_gateway = ctx.get("gateway")
	_player = ctx.get("player")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_apply_open_state()


func _build() -> void:
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -PANEL_SIZE.x * 0.5
	_panel.offset_right = PANEL_SIZE.x * 0.5
	_panel.offset_top = -PANEL_SIZE.y * 0.5
	_panel.offset_bottom = PANEL_SIZE.y * 0.5
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

	var grid := GridContainer.new()
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override("h_separation", HudTokens.SLOT_GAP)
	grid.add_theme_constant_override("v_separation", HudTokens.SLOT_GAP)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(grid)

	for archetype_id: String in ToolController.CONSTRUCTION_ARCHETYPES:
		grid.add_child(_make_entry(archetype_id))

	_panel.add_child(HudTokens.make_panel_overlay(PANEL_SIZE))


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
	code_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(code_label)

	var name_label := Label.new()
	name_label.text = _display_name(archetype_id)
	name_label.theme_type_variation = &"HudSmall"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(name_label)

	return entry


func _display_name(archetype_id: String) -> String:
	if _gateway != null and _gateway.has_method("archetype_display_name"):
		return String(_gateway.archetype_display_name(archetype_id)).to_upper()
	return archetype_id.to_upper()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_palette"):
		_toggle()
		get_viewport().set_input_as_handled()
	elif _open and event.is_action_pressed("release_mouse"):
		_toggle()
		get_viewport().set_input_as_handled()


func _toggle() -> void:
	_open = not _open
	_apply_open_state()


func _apply_open_state() -> void:
	if _panel == null:
		return
	_panel.visible = _open
	# While the palette is open the cursor must be visible to drag, and gameplay
	# input is paused so WASD/drill do not fire behind the overlay. Both are
	# ephemeral presentation concerns (mirrors player_settings_overlay).
	if _player != null and _player.has_method("set_gameplay_input_enabled"):
		_player.call("set_gameplay_input_enabled", not _open)
	Input.set_mouse_mode(
		Input.MOUSE_MODE_VISIBLE if _open else Input.MOUSE_MODE_CAPTURED
	)
