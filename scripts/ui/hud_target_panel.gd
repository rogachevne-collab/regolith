extends Control
## Top-left target readout panel. Presentation only: reads
## InteractionQuery.current_hit metadata for a simulation element and displays
## its name / status / integrity with the frozen state palette. Hidden unless a
## simulation element is targeted. Never mutates state.

const PANEL_SIZE := Vector2(320, 126)
const KEY_COL := 72.0
const INDEX_LETTERS: PackedStringArray = [
	"А", "Б", "В", "Г", "Д", "Е", "Ж", "З", "И", "К",
	"Л", "М", "Н", "П", "Р", "С", "Т", "У", "Ф", "Ц",
]

var _query: InteractionQuery
var _gateway: WorldCommandGateway

var _panel: Panel
var _emblem_mat: ShaderMaterial
var _callsign: Label
var _distance: Label
var _name_val: Label
var _status_val: Label
var _metric_key: Label
var _metric_val: Label
var _max_integrity_cache: Dictionary = {}


func setup(ctx: Dictionary) -> void:
	_query = ctx.get("query")
	_gateway = ctx.get("gateway")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_panel.visible = false


func _build() -> void:
	_panel = Panel.new()
	_panel.position = Vector2(HudTokens.PANEL_MARGIN, HudTokens.PANEL_MARGIN)
	_panel.size = PANEL_SIZE
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vb)

	# Compact header: keep identity and distance, drop decorative chrome so the
	# readout remains subordinate to the world view.
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title_row)

	var emblem := HudTokens.make_emblem(14.0)
	_emblem_mat = emblem.material as ShaderMaterial
	title_row.add_child(emblem)

	var header_text := VBoxContainer.new()
	header_text.add_theme_constant_override("separation", 1)
	header_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(header_text)
	var title := Label.new()
	title.text = "ЦЕЛЬ"
	title.theme_type_variation = &"HudSmall"
	title.add_theme_color_override("font_color", HudTokens.COL_TITLE)
	header_text.add_child(title)
	_callsign = Label.new()
	_callsign.theme_type_variation = &"HudSmall"
	header_text.add_child(_callsign)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(spacer)

	_distance = Label.new()
	_distance.theme_type_variation = &"HudSmall"
	_distance.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_distance.size_flags_horizontal = Control.SIZE_SHRINK_END
	title_row.add_child(_distance)

	vb.add_child(HudTokens.make_divider())

	_name_val = _add_info_row(vb, "ТИП", HudTokens.COL_TEXT)
	_status_val = _add_info_row(vb, "СОСТОЯНИЕ", HudTokens.COL_OK)
	var metric := _add_info_row_keyed(vb, "ЦЕЛОСТНОСТЬ", HudTokens.COL_OK)
	_metric_key = metric[0] as Label
	_metric_val = metric[1] as Label

	# Glow / border / scanline overlay on top of the fill.
	_panel.add_child(HudTokens.make_panel_overlay(PANEL_SIZE))


func _add_info_row(parent: Node, key: String, value_color: Color) -> Label:
	return _add_info_row_keyed(parent, key, value_color)[1] as Label


func _add_info_row_keyed(parent: Node, key: String, value_color: Color) -> Array:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)
	var k := Label.new()
	k.text = key
	k.theme_type_variation = &"HudSmall"
	k.custom_minimum_size = Vector2(KEY_COL, 0)
	row.add_child(k)
	var v := Label.new()
	v.theme_type_variation = &"HudValue"
	v.add_theme_color_override("font_color", value_color)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(v)
	return [k, v]


func _process(_delta: float) -> void:
	if _query == null:
		return
	var hit := _query.current_hit
	if not hit.valid or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT:
		_panel.visible = false
		return
	_panel.visible = true
	var meta := hit.metadata
	var archetype_id := str(meta.get("archetype_id", ""))
	var status := StringName(meta.get("status_reason", &"element_incomplete"))
	var status_color := HudTokens.color_for_status(status)

	_emblem_mat.set_shader_parameter("color", status_color)
	_callsign.text = "ОБЪЕКТ %02d · ИНДЕКС %02d-%s" % [
		int(meta.get("assembly_id", 0)) % 100,
		int(meta.get("element_id", 0)) % 100,
		_index_letter(int(meta.get("element_id", 0))),
	]
	_distance.text = "%.1f М" % hit.distance
	_name_val.text = _gateway.archetype_display_name(archetype_id).to_upper()

	_status_val.text = HudTokens.status_label(status)
	_status_val.add_theme_color_override("font_color", status_color)

	if status == &"element_incomplete":
		_metric_key.text = "СБОРКА"
		_metric_val.text = "%d%%" % int(round(float(meta.get("build_progress", 0.0)) * 100.0))
	else:
		_metric_key.text = "ЦЕЛОСТНОСТЬ"
		_metric_val.text = "%d%%" % int(round(_integrity_fraction(archetype_id, meta) * 100.0))
	_metric_val.add_theme_color_override("font_color", status_color)


func _integrity_fraction(archetype_id: String, meta: Dictionary) -> float:
	var current := float(meta.get("integrity", 0.0))
	var maximum := _max_integrity(archetype_id)
	if maximum <= 0.0:
		return 0.0
	return clampf(current / maximum, 0.0, 1.0)


func _max_integrity(archetype_id: String) -> float:
	if _max_integrity_cache.has(archetype_id):
		return _max_integrity_cache[archetype_id]
	var archetype := Slice01Archetypes.load_required(archetype_id)
	var value := archetype.max_integrity if archetype != null else 0.0
	_max_integrity_cache[archetype_id] = value
	return value


func _index_letter(element_id: int) -> String:
	if INDEX_LETTERS.is_empty():
		return "Х"
	return INDEX_LETTERS[element_id % INDEX_LETTERS.size()]
