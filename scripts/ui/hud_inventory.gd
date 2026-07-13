extends Control
## "ИНВЕНТАРЬ" overlay panel (centre-screen, toggled with `toggle_inventory`).
## Presentation only: shows the player's authoritative resource store rendered by
## the reusable HudStoreView. It reads the store through the WorldCommandGateway's
## read-only accessor and never mutates simulation state (see HUD-UI-01). The
## store is fetched lazily on open because bootstrap seeds it after the HUD is
## ready; the panel only owns ephemeral open/close presentation state.

const PLAYER_STORE_ID := "player"
const PANEL_SIZE := Vector2(300, 236)

var _gateway: Node
var _panel: Panel
var _store_view: HudStoreView
var _open := false


func setup(ctx: Dictionary) -> void:
	_gateway = ctx.get("gateway")
	if _gateway != null and _gateway.has_signal("command_completed"):
		_gateway.command_completed.connect(_on_command_completed)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_apply_open_state()


func _build() -> void:
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Centre the panel on screen (distinct from the anchored corner widgets).
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

	# --- Header: emblem + title, national tick + store id ---
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 10)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title_row)

	title_row.add_child(HudTokens.make_emblem())

	var title := Label.new()
	title.text = "ИНВЕНТАРЬ"
	title.theme_type_variation = &"HudTitle"
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(spacer)

	var right_box := VBoxContainer.new()
	right_box.add_theme_constant_override("separation", 4)
	right_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(right_box)
	right_box.add_child(HudTokens.make_national_tick())
	var store_id_label := Label.new()
	store_id_label.text = "СКЛАД · %s" % HudTokens.store_label(PLAYER_STORE_ID)
	store_id_label.theme_type_variation = &"HudSmall"
	store_id_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	store_id_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	right_box.add_child(store_id_label)

	vb.add_child(HudTokens.make_divider())
	vb.add_child(HudTokens.make_gap(6))

	_store_view = HudStoreView.new()
	_store_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(_store_view)

	# Glow / border / scanline overlay on top of the fill.
	_panel.add_child(HudTokens.make_panel_overlay(PANEL_SIZE))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_inventory"):
		_open = not _open
		_apply_open_state()
		get_viewport().set_input_as_handled()


func _apply_open_state() -> void:
	if _panel == null:
		return
	_panel.visible = _open
	if _open:
		_refresh_store()


func _refresh_store() -> void:
	if _store_view == null:
		return
	var store: SimulationResourceStore = null
	if _gateway != null and _gateway.has_method("resource_store"):
		store = _gateway.resource_store(PLAYER_STORE_ID)
	_store_view.bind(store, "ГРУЗ")


func _on_command_completed(_command_id: int, _result: Dictionary) -> void:
	# Keep the open panel in sync when commands change the store (e.g. placing a
	# block consumes construction_component). Closed → nothing to redraw.
	if _open:
		_refresh_store()
