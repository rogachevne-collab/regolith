extends Control
## "СИСТЕМЫ СКАФАНДРА" suit-systems panel (bottom-left). Presentation only: reads
## the authoritative SuitState (health / oxygen / hydrogen) via its `changed`
## signal and renders three vital bars with the frozen hud_bar shader + HudTokens
## palette. Colour follows the state language: steel-blue normal → amber warning →
## red critical as the fraction drops. Never writes SuitState (see HUD-UI-01).

const PANEL_SIZE := Vector2(252, 112)
const BAR_LEN := 140.0

# Fraction thresholds for the state palette (drops trigger warning then critical).
const WARN_FRACTION := 0.5
const CRIT_FRACTION := 0.25

var _suit: Node
var _panel: Panel
# channel key -> {"mat": ShaderMaterial, "value": Label}
var _bars: Dictionary = {}


func setup(ctx: Dictionary) -> void:
	_suit = ctx.get("suit")
	if _suit != null and _suit.has_signal("changed"):
		_suit.changed.connect(_refresh)
	_refresh()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_refresh()


func _build() -> void:
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchor bottom-left so it stays clear of the top-left target panel and the
	# bottom-centre toolbar.
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = HudTokens.PANEL_MARGIN
	_panel.offset_right = HudTokens.PANEL_MARGIN + PANEL_SIZE.x
	_panel.offset_top = -(PANEL_SIZE.y + HudTokens.PANEL_MARGIN)
	_panel.offset_bottom = -HudTokens.PANEL_MARGIN
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 9)
	margin.add_theme_constant_override("margin_bottom", 9)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vb)

	# Compact single-line header: vitals stay subordinate to the world and never
	# compete with the bottom-centre toolbar.
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title_row)

	title_row.add_child(HudTokens.make_emblem(14.0))

	var title := Label.new()
	title.text = "СКАФАНДР"
	title.theme_type_variation = &"HudSmall"
	title.add_theme_color_override("font_color", HudTokens.COL_TITLE)
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(spacer)

	var online := Label.new()
	online.text = "В СЕТИ"
	online.theme_type_variation = &"HudSmall"
	online.add_theme_color_override("font_color", HudTokens.COL_OK)
	online.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	online.size_flags_horizontal = Control.SIZE_SHRINK_END
	title_row.add_child(online)

	# --- Vital bars: health (ЗДР) / oxygen (О₂) / hydrogen (Н₂) ---
	_add_bar(vb, "health", "ЗДР")
	_add_bar(vb, "oxygen", "О\u2082")
	_add_bar(vb, "hydrogen", "Н\u2082")

	# Glow / border / scanline overlay on top of the fill.
	_panel.add_child(HudTokens.make_panel_overlay(PANEL_SIZE))


func _add_bar(parent_node: Node, key: String, label_text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent_node.add_child(row)

	var name_label := Label.new()
	name_label.text = label_text
	name_label.theme_type_variation = &"HudSmall"
	name_label.custom_minimum_size = Vector2(24, 0)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)

	var bar_size := Vector2(BAR_LEN, HudTokens.BAR_SIZE.y)
	var bar := ColorRect.new()
	bar.color = Color(1, 1, 1, 1)
	bar.custom_minimum_size = bar_size
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load(HudTokens.SH_BAR)
	mat.set_shader_parameter("rect_size", bar_size)
	mat.set_shader_parameter("fill", 1.0)
	mat.set_shader_parameter("fill_color", HudTokens.COL_OK)
	mat.set_shader_parameter("segments", 24.0)
	mat.set_shader_parameter("gap_ratio", 0.16)
	mat.set_shader_parameter("glow_strength", 0.22)
	mat.set_shader_parameter("lead_strength", 0.35)
	bar.material = mat
	row.add_child(bar)

	var value_label := Label.new()
	value_label.theme_type_variation = &"HudValue"
	value_label.custom_minimum_size = Vector2(32, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value_label)

	_bars[key] = {"mat": mat, "value": value_label}


func _refresh() -> void:
	if _suit == null or _bars.is_empty():
		return
	_update_bar("health", _suit.health_fraction())
	_update_bar("oxygen", _suit.oxygen_fraction())
	_update_bar("hydrogen", _suit.hydrogen_fraction())


func _update_bar(key: String, fraction: float) -> void:
	var refs: Dictionary = _bars.get(key, {})
	if refs.is_empty():
		return
	var col := _color_for_fraction(fraction)
	var mat: ShaderMaterial = refs["mat"]
	mat.set_shader_parameter("fill", fraction)
	mat.set_shader_parameter("fill_color", col)
	var value: Label = refs["value"]
	value.text = "%d%%" % int(round(fraction * 100.0))
	value.add_theme_color_override("font_color", col)


func _color_for_fraction(fraction: float) -> Color:
	if fraction <= CRIT_FRACTION:
		return HudTokens.COL_CRITICAL
	if fraction <= WARN_FRACTION:
		return HudTokens.COL_WARNING
	return HudTokens.COL_OK
