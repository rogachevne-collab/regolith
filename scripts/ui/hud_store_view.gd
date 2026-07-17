class_name HudStoreView
extends VBoxContainer
## Reusable, read-only view of a single resource store. Given any
## SimulationResourceStore it renders a heading plus one row per resource
## (label → amount) styled with HudTokens. Presentation only: it reads the
## store's amounts and never mutates it (see docs/specs/HUD-UI-01.md). If the
## store model later exposes capacity/fill (Industry v1) this component is the
## single place to add a fill bar; today the model has amounts only, so it shows
## amounts and never fabricates a capacity it does not have.

const ROW_GAP := 7

var _store: SimulationResourceStore
var _heading_text := "ГРУЗ"
var _heading: Label
var _rows_box: VBoxContainer
var _empty_label: Label


func _ready() -> void:
	add_theme_constant_override("separation", HudTokens.SECTION_GAP)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	refresh()


func _build() -> void:
	_heading = Label.new()
	_heading.text = _heading_text
	_heading.theme_type_variation = &"HudSmall"
	_heading.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_heading)

	add_child(HudTokens.make_divider())

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", ROW_GAP)
	_rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_rows_box)

	_empty_label = Label.new()
	_empty_label.text = "ПУСТО"
	_empty_label.theme_type_variation = &"HudSmall"
	_empty_label.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows_box.add_child(_empty_label)


## Bind the store to view and (optional) heading text. Safe to call before or
## after _ready(); rebuilds rows if the view is already built.
func bind(store: SimulationResourceStore, heading: String = "") -> void:
	_store = store
	if not heading.is_empty():
		_heading_text = heading
		if _heading != null:
			_heading.text = _heading_text
	if is_node_ready():
		refresh()


func refresh() -> void:
	if _rows_box == null:
		return
	for child_node: Node in _rows_box.get_children():
		if child_node == _empty_label:
			continue
		child_node.queue_free()

	var ids := PackedStringArray()
	if _store != null:
		ids = _store.resource_ids()

	_empty_label.visible = ids.is_empty()
	for resource_id: String in ids:
		_rows_box.add_child(_make_row(resource_id, _store.amount(resource_id)))


func _make_row(resource_id: String, amount: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var name_label := Label.new()
	name_label.text = HudTokens.resource_label(resource_id)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)

	var value_label := Label.new()
	value_label.text = HudTokens.format_amount(amount)
	value_label.theme_type_variation = &"HudValue"
	value_label.add_theme_color_override("font_color", HudTokens.COL_VALID)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.custom_minimum_size = Vector2(64, 0)
	value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(value_label)

	return row
