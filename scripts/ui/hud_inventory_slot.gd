class_name HudInventorySlot
extends Panel
## One terminal inventory cell: item icon + amount badge. Drag payload uses the
## frozen hud_item contract; Shift-drag requests a half stack per INDUSTRY-V1.

signal double_clicked(slot: Panel)

var source_store_id := ""
var item_id := ""
var amount := 0.0
var discrete := false
var instance_id := ""

var _slot_size := HudTokens.SLOT_SIZE
var _amount_label: Label


func configure(size: Vector2) -> void:
	_slot_size = size
	custom_minimum_size = size
	if is_node_ready():
		_build()


func _ready() -> void:
	theme_type_variation = &"HudSlot"
	custom_minimum_size = _slot_size
	size = _slot_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


func bind(source_store: String, entry: Dictionary) -> void:
	var bind := HudInventoryTransferUtil.slot_bind_from_entry(source_store, entry)
	source_store_id = str(bind.get("source_store_id", ""))
	item_id = str(bind.get("item_id", ""))
	amount = float(bind.get("amount", 0.0))
	discrete = bool(bind.get("discrete", false))
	instance_id = str(bind.get("instance_id", ""))
	if is_node_ready():
		_build()


func drag_payload(half: bool = false) -> Dictionary:
	return HudInventoryTransferUtil.drag_payload(
		source_store_id,
		item_id,
		amount,
		discrete,
		half,
		instance_id
	)


func _build() -> void:
	for child in get_children():
		child.queue_free()
	var icon := HudTokens.make_item_icon(item_id, _slot_size.x)
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(icon)

	_amount_label = Label.new()
	_amount_label.theme_type_variation = &"HudSmall"
	_amount_label.add_theme_color_override("font_color", HudTokens.COL_TEXT)
	_amount_label.clip_text = true
	_amount_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_amount_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_amount_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_amount_label.offset_left = 2.0
	_amount_label.offset_top = 2.0
	_amount_label.offset_right = -4.0
	_amount_label.offset_bottom = -2.0
	_amount_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_amount_label)
	_refresh_visual()


func _refresh_visual() -> void:
	if _amount_label == null:
		return
	_amount_label.text = HudTokens.format_amount(amount)
	tooltip_text = "%s · %s" % [
		HudTokens.resource_label(item_id),
		HudTokens.format_amount(amount),
	]


func _get_drag_data(_at_position: Vector2) -> Variant:
	var half := Input.is_key_pressed(KEY_SHIFT)
	var payload := drag_payload(half)
	if float(payload.get("amount", 0.0)) <= ResourceCatalog.EPSILON:
		return null
	set_drag_preview(_make_drag_preview(payload))
	return payload


func _make_drag_preview(payload: Dictionary) -> Control:
	var preview := Panel.new()
	preview.theme_type_variation = &"HudSlotSelected"
	preview.custom_minimum_size = _slot_size
	preview.size = _slot_size
	preview.position = -_slot_size * 0.5
	preview.modulate = Color(1.0, 1.0, 1.0, 0.92)
	var icon := HudTokens.make_item_icon(
		str(payload.get("item_id", "")),
		_slot_size.x
	)
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview.add_child(icon)
	var badge := Label.new()
	badge.text = HudTokens.format_amount(float(payload.get("amount", 0.0)))
	badge.theme_type_variation = &"HudSmall"
	badge.add_theme_color_override("font_color", HudTokens.COL_VALID)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	badge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.offset_right = -4.0
	badge.offset_bottom = -2.0
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.add_child(badge)
	return preview


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if (
			mouse.button_index == MOUSE_BUTTON_LEFT
			and mouse.pressed
			and mouse.double_click
		):
			double_clicked.emit(self)
			accept_event()
