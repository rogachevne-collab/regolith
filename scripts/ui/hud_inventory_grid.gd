class_name HudInventoryGrid
extends Control
## Growing terminal inventory grid built from StoreSnapshot entries. Accepts
## compatible hud_item drops and submits transfer_resource via WorldCommandGateway.
## Refreshes from authoritative snapshots only — no optimistic slot mutations.

const GRID_COLUMNS_MIN := 2
const GRID_COLUMNS_MAX := 5

signal transfer_failed(reason: StringName, data: Dictionary)

var _gateway: WorldCommandGateway
var _store_id := ""
var _peer_store_id := ""
var _snapshot: Dictionary = {}
var _column_width := 248.0
var _slot_size := HudTokens.SLOT_SIZE
var _slot_gap: float = float(HudTokens.SLOT_GAP)
## Fill mode: the grid takes the height its container gives it and scrolls
## inside. Off, it grows with its content (legacy shrink-wrapped panels).
var _fill_mode := false

var _scroll: ScrollContainer
var _grid: GridContainer
var _empty_label: Label
var _drop_highlight: ColorRect
var _pending_command_ids: Dictionary = {}


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not _fill_mode:
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	_apply_fill_mode()


func setup(gateway: WorldCommandGateway) -> void:
	if _gateway != null and _gateway.command_completed.is_connected(_on_command_completed):
		_gateway.command_completed.disconnect(_on_command_completed)
	_gateway = gateway
	if _gateway != null:
		_gateway.command_completed.connect(_on_command_completed)


## Height comes from the container in fill mode; the grid only ever scrolls.
func set_fill_mode(on: bool) -> void:
	_fill_mode = on
	if on:
		size_flags_vertical = Control.SIZE_EXPAND_FILL
	_apply_fill_mode()


func _apply_fill_mode() -> void:
	if _scroll == null or not _fill_mode:
		return
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.custom_minimum_size.y = 0.0
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	custom_minimum_size.y = 0.0


func configure_layout(
	column_width: float,
	slot_size: Vector2
) -> void:
	_column_width = column_width
	_slot_size = slot_size
	_slot_gap = (
		8.0 if slot_size.x < HudTokens.SLOT_SIZE.x else float(HudTokens.SLOT_GAP)
	)
	if _grid != null:
		_grid.add_theme_constant_override("h_separation", int(_slot_gap))
		_grid.add_theme_constant_override("v_separation", int(_slot_gap))
		for child_node in _grid.get_children():
			if child_node is HudInventorySlot:
				(child_node as HudInventorySlot).configure(_slot_size)
	_update_columns()
	_apply_height_budget()
	_update_minimum_size()


func set_peer_store_id(peer_store_id: String) -> void:
	_peer_store_id = peer_store_id


func apply_snapshot(snapshot: Dictionary) -> void:
	_snapshot = snapshot.duplicate(true)
	_store_id = str(snapshot.get("store_id", ""))
	_rebuild_grid()


func refresh() -> void:
	if _gateway == null or _store_id.is_empty():
		return
	apply_snapshot(_gateway.store_snapshot(_store_id))


func store_id() -> String:
	return _store_id


func _build() -> void:
	_drop_highlight = ColorRect.new()
	_drop_highlight.color = Color(HudTokens.COL_VALID, 0.12)
	_drop_highlight.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_drop_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drop_highlight.visible = false
	add_child(_drop_highlight)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_scroll)

	var holder := VBoxContainer.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(holder)

	_grid = GridContainer.new()
	_grid.columns = 4
	_grid.add_theme_constant_override("h_separation", int(_slot_gap))
	_grid.add_theme_constant_override("v_separation", int(_slot_gap))
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(_grid)

	_empty_label = Label.new()
	_empty_label.text = "ПУСТО"
	_empty_label.theme_type_variation = &"HudSmall"
	_empty_label.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(_empty_label)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_columns()
		_apply_height_budget()
		_update_minimum_size()
	elif (
		what == NOTIFICATION_MOUSE_EXIT
		or what == NOTIFICATION_DRAG_END
	) and _drop_highlight != null:
		_drop_highlight.visible = false


func _rebuild_grid() -> void:
	if _grid == null:
		return
	for child_node in _grid.get_children():
		child_node.queue_free()
	var entries: Array = _snapshot.get("entries", [])
	_empty_label.visible = entries.is_empty()
	for entry: Variant in entries:
		if not entry is Dictionary:
			continue
		var slot := HudInventorySlot.new()
		slot.configure(_slot_size)
		slot.bind(_store_id, entry)
		slot.double_clicked.connect(_on_slot_double_clicked)
		_grid.add_child(slot)
	_update_columns()
	_apply_height_budget()
	_update_minimum_size()


func _update_columns() -> void:
	if _grid == null:
		return
	# Once laid out, the real width wins: the caller's column estimate is only a
	# seed for the first frame. Reserve the scrollbar either way.
	var width := (size.x - 14.0) if size.x > 1.0 else (_column_width - 20.0)
	var inner_w := maxf(width, _slot_size.x)
	var cell_w := _slot_size.x + _slot_gap
	var cols := clampi(int(floor((inner_w + _slot_gap) / cell_w)), GRID_COLUMNS_MIN, GRID_COLUMNS_MAX)
	if _grid.columns != cols:
		_grid.columns = cols


func _content_height() -> float:
	var entries: Array = _snapshot.get("entries", [])
	if entries.is_empty():
		return 24.0
	var cols := maxi(_grid.columns, 1)
	var rows := ceili(float(entries.size()) / float(cols))
	return float(rows) * _slot_size.y + float(maxi(rows - 1, 0)) * _slot_gap


func _apply_height_budget() -> void:
	if _scroll == null or _fill_mode:
		return
	var budget := _content_height()
	_scroll.custom_minimum_size.y = budget
	_scroll.size.y = budget
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED


func _update_minimum_size() -> void:
	if _fill_mode:
		custom_minimum_size.y = 0.0
		return
	custom_minimum_size.y = _scroll.custom_minimum_size.y if _scroll != null else 0.0


func _on_slot_double_clicked(slot: HudInventorySlot) -> void:
	if _peer_store_id.is_empty() or slot.item_id.is_empty():
		return
	var payload := HudInventoryTransferUtil.drag_payload(
		slot.source_store_id,
		slot.item_id,
		slot.amount,
		slot.discrete,
		false,
		slot.instance_id
	)
	_submit_transfer(payload, _peer_store_id)


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	var accepts := HudInventoryTransferUtil.is_compatible_drop(data, _store_id)
	if _drop_highlight != null:
		_drop_highlight.visible = accepts
	return accepts


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if _drop_highlight != null:
		_drop_highlight.visible = false
	if data is Dictionary:
		_submit_transfer(data, _store_id)


func _submit_transfer(payload: Dictionary, destination_store_id: String) -> void:
	if _gateway == null:
		transfer_failed.emit(&"not_ready", {})
		return
	if not HudInventoryTransferUtil.is_compatible_drop(payload, destination_store_id):
		transfer_failed.emit(&"invalid_target", {})
		return
	var parameters := HudInventoryTransferUtil.transfer_parameters(
		payload,
		destination_store_id
	)
	if float(parameters.get("amount", 0.0)) <= ResourceCatalog.EPSILON:
		transfer_failed.emit(&"no_input", parameters)
		return
	var command_id := _gateway.submit({
		"kind": &"transfer_resource",
		"source": self,
		"target": HudInventoryTransferUtil.command_target_for_store(_store_id),
		"parameters": parameters,
	})
	_pending_command_ids[command_id] = true


func _on_command_completed(command_id: int, result: Dictionary) -> void:
	var was_pending := _pending_command_ids.erase(command_id)
	if was_pending:
		var reason := StringName(result.get("reason", &"not_ready"))
		if reason != &"ok":
			transfer_failed.emit(reason, result.get("data", {}))
	refresh()
