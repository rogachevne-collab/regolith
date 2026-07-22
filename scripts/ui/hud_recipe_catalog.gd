class_name HudRecipeCatalog
extends Control
## Factory-window recipe catalog (SE "blueprint" list). Renders one card per
## recipe the targeted machine can run — output icon, name and input chips — and
## enqueues jobs via WorldCommandGateway. Left click queues ×1, Ctrl ×10,
## Shift ×100. Presentation only: it reads the machine snapshot and submits
## typed `enqueue_recipe` commands; it never owns queue state.

const CARD_MIN_WIDTH := 168.0
const CARD_MIN_HEIGHT := 56.0
const CARD_TARGET_WIDTH := 200.0
const GRID_COLUMNS_MAX := 3
const OUTPUT_ICON := 36.0
const INPUT_ICON := 20.0
const INPUT_ICON_WIDTH := 30.0
const INNER_MARGIN := 10
const BATCH_CTRL := 10
const BATCH_SHIFT := 100

signal command_submitted(command_id: int)

var _gateway: WorldCommandGateway
var _element_id := 0
var _recipes: Array = []
var _active_recipe_id := ""
var _last_sig := "__unset__"

var _grid: GridContainer
var _scroll: ScrollContainer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()


func setup(gateway: WorldCommandGateway) -> void:
	_gateway = gateway


func set_element_id(element_id: int) -> void:
	_element_id = element_id


func apply_machine(machine: Dictionary) -> void:
	_recipes = machine.get("recipes", [])
	_active_recipe_id = str(machine.get("recipe_id", ""))
	_rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_columns()


func _build() -> void:
	var frame := PanelContainer.new()
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_stylebox_override("panel", HudTokens.make_subpanel_style())
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", INNER_MARGIN)
	margin.add_theme_constant_override("margin_right", INNER_MARGIN)
	margin.add_theme_constant_override("margin_top", INNER_MARGIN)
	margin.add_theme_constant_override("margin_bottom", INNER_MARGIN)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vb)

	# Title and batch hint share one row: the catalog needs every pixel of
	# height it can give the cards.
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	header_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(header_row)
	var header := HudTokens.make_section_header("РЕЦЕПТЫ")
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(header)
	var hint := HudTokens.make_section_header("ЛКМ +1 · Ctrl +10 · Shift +100")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header_row.add_child(hint)

	vb.add_child(HudTokens.make_divider())

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	vb.add_child(_scroll)

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_grid)


## Card count per row follows the column the window gave us, so a card is never
## squeezed below the width its icon + input chips need.
func _update_columns() -> void:
	if _grid == null:
		return
	var inner := size.x - float(INNER_MARGIN) * 2.0 - 16.0
	if inner <= 0.0:
		return
	var cols := clampi(int(floor(inner / CARD_TARGET_WIDTH)), 1, GRID_COLUMNS_MAX)
	if _grid.columns != cols:
		_grid.columns = cols


func _rebuild() -> void:
	if _grid == null:
		return
	# The recipe set is static per machine and the only visual state that varies
	# is which card is active, so skip the rebuild unless one of those changed.
	var signature := "%s@%s" % [
		"|".join(PackedStringArray(_recipes.map(func(x): return str(x)))),
		_active_recipe_id,
	]
	if signature == _last_sig:
		return
	_last_sig = signature
	for child_node in _grid.get_children():
		child_node.queue_free()
	for recipe_id: Variant in _recipes:
		var card := _make_card(str(recipe_id))
		_grid.add_child(card)
	_update_columns()


func _make_card(recipe_id: String) -> Control:
	var is_active := recipe_id == _active_recipe_id
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(CARD_MIN_WIDTH, CARD_MIN_HEIGHT)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.tooltip_text = _tooltip_for(recipe_id)
	card.add_theme_stylebox_override("panel", _card_style(is_active, false))
	card.set_meta("recipe_id", recipe_id)
	card.gui_input.connect(_on_card_input.bind(recipe_id))
	card.mouse_entered.connect(_on_card_hover.bind(card, recipe_id, true))
	card.mouse_exited.connect(_on_card_hover.bind(card, recipe_id, false))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	row.add_child(_make_output_icon(recipe_id))

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 3)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(info)

	var name_label := Label.new()
	name_label.text = HudTokens.recipe_label(recipe_id)
	name_label.theme_type_variation = &"HudSmall"
	name_label.add_theme_color_override(
		"font_color",
		HudTokens.COL_VALID if is_active else HudTokens.COL_TITLE
	)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(name_label)

	info.add_child(_make_input_chips(recipe_id))
	return card


func _make_output_icon(recipe_id: String) -> Control:
	var output_id := _primary_output(recipe_id)
	if output_id.is_empty():
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(OUTPUT_ICON, OUTPUT_ICON)
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return spacer
	return HudTokens.make_item_icon(output_id, OUTPUT_ICON)


func _make_input_chips(recipe_id: String) -> Control:
	# Flow, not a fixed row: a three-input recipe wraps to a second line instead
	# of running past the card border.
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 2)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var inputs := RecipeCatalog.inputs(recipe_id)
	if inputs.is_empty():
		var none := Label.new()
		none.text = "—"
		none.theme_type_variation = &"HudSmall"
		none.add_theme_color_override("font_color", HudTokens.COL_DIM)
		none.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(none)
		return row
	for resource_id: Variant in inputs.keys():
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override("separation", 2)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(
			HudTokens.make_item_icon(str(resource_id), INPUT_ICON, INPUT_ICON_WIDTH)
		)
		var amount := Label.new()
		amount.text = "×%s" % HudTokens.format_amount(float(inputs[resource_id]))
		amount.theme_type_variation = &"HudSmall"
		amount.add_theme_color_override("font_color", HudTokens.COL_TEXT)
		amount.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(amount)
		row.add_child(chip)
	return row


func _tooltip_for(recipe_id: String) -> String:
	var parts: Array[String] = [HudTokens.recipe_label(recipe_id)]
	var outputs := RecipeCatalog.outputs(recipe_id)
	if not outputs.is_empty():
		var out_bits: Array[String] = []
		for resource_id: Variant in outputs.keys():
			out_bits.append("%s ×%s" % [
				HudTokens.resource_label(str(resource_id)),
				HudTokens.format_amount(float(outputs[resource_id])),
			])
		parts.append("→ " + ", ".join(out_bits))
	parts.append("%s с · %s Вт" % [
		HudTokens.format_amount(RecipeCatalog.duration_s(recipe_id)),
		HudTokens.format_amount(RecipeCatalog.power_w(recipe_id)),
	])
	return "\n".join(parts)


func _primary_output(recipe_id: String) -> String:
	var outputs := RecipeCatalog.outputs(recipe_id)
	var best_id := ""
	var best_amount := -1.0
	for resource_id: Variant in outputs.keys():
		var amount := float(outputs[resource_id])
		if amount > best_amount:
			best_amount = amount
			best_id = str(resource_id)
	return best_id


func _card_style(active: bool, hovered: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.09, 0.13, 0.17, 0.55)
	box.set_corner_radius_all(2)
	box.set_border_width_all(1)
	box.border_color = HudTokens.COL_BORDER
	if active:
		box.bg_color = Color(HudTokens.COL_VALID, 0.10)
		box.border_color = HudTokens.COL_VALID
	elif hovered:
		box.border_color = HudTokens.COL_OK
		box.bg_color = Color(0.12, 0.18, 0.24, 0.7)
	return box


func _on_card_hover(card: Control, recipe_id: String, hovered: bool) -> void:
	if card == null:
		return
	card.add_theme_stylebox_override(
		"panel",
		_card_style(recipe_id == _active_recipe_id, hovered)
	)


func _on_card_input(event: InputEvent, recipe_id: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var count := 1
	if mb.shift_pressed:
		count = BATCH_SHIFT
	elif mb.ctrl_pressed:
		count = BATCH_CTRL
	_enqueue(recipe_id, count)
	accept_event()


func _enqueue(recipe_id: String, count: int) -> void:
	if _gateway == null or _element_id <= 0 or recipe_id.is_empty():
		return
	var command_id := _gateway.submit({
		"kind": &"enqueue_recipe",
		"source": self,
		"target": _machine_target(),
		"parameters": {
			"element_id": _element_id,
			"recipe_id": recipe_id,
			"count": maxi(1, count),
		},
	})
	command_submitted.emit(command_id)


func _machine_target() -> Dictionary:
	return InteractionHit.create(
		Vector3.ZERO,
		Vector3.UP,
		0.0,
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		&"",
		{"element_id": _element_id}
	).snapshot()
