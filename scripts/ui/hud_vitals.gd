extends Control
## Suit telemetry cluster (bottom-left). Presentation only: reads the
## authoritative SuitState (health / oxygen / hydrogen) via its `changed` signal
## and renders three vital bars with the frozen hud_bar shader + HudTokens
## palette. Never writes SuitState (see HUD-UI-01).
##
## Ambient by design. Vitals sit at 100% for most of a session, so the nominal
## state is the one worth optimising: the numerals recede to COL_DIM and only a
## degraded channel lights up (amber → red, with a stronger glow at critical) to
## claim attention. Frameless — no panel fill, border or overlay — so the cluster
## stays subordinate to the world; an outline on the text keeps it legible over
## bright regolith without the weight of a box, and a single hairline rule binds
## the three rows into one instrument instead of three floating readouts.

const BAR_LEN := 92.0
const BAR_H := 6.0
# Width reserved for the numerals so the cluster's right edge does not jitter
# as values step 100 → 99 → 9.
const VALUE_COL := 34.0

# Fraction thresholds for the state palette (drops trigger warning then critical).
const WARN_FRACTION := 0.5
const CRIT_FRACTION := 0.25

# Glow rises on critical so a failing channel reads urgent, not merely red.
const GLOW_NOMINAL := 0.14
const GLOW_CRITICAL := 0.34

var _suit: Node
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
	var cluster := HBoxContainer.new()
	cluster.add_theme_constant_override("separation", 9)
	cluster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cluster)
	# Collapse the rect onto the bottom-left corner at the shared panel margin and
	# let it grow up/right to whatever the rows need. Growth directions rather
	# than a MINSIZE preset: the preset would bake in the minimum size measured at
	# call time (zero, before the rows exist), while these re-resolve on every
	# layout pass — so there is no hand-kept panel size to drift out of sync.
	cluster.anchor_left = 0.0
	cluster.anchor_right = 0.0
	cluster.anchor_top = 1.0
	cluster.anchor_bottom = 1.0
	cluster.offset_left = HudTokens.PANEL_MARGIN
	cluster.offset_right = HudTokens.PANEL_MARGIN
	cluster.offset_top = -HudTokens.PANEL_MARGIN
	cluster.offset_bottom = -HudTokens.PANEL_MARGIN
	cluster.grow_horizontal = Control.GROW_DIRECTION_END
	cluster.grow_vertical = Control.GROW_DIRECTION_BEGIN

	# Hairline rule: the only chrome left, standing in for the old frame.
	var rule := ColorRect.new()
	rule.color = Color(HudTokens.COL_OK, 0.5)
	rule.custom_minimum_size = Vector2(1, 0)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cluster.add_child(rule)

	# Grid, not stacked rows: a GridContainer sizes each column to the widest
	# cell it actually contains, so the three bars share one true left edge no
	# matter how "ЗДР" / "О₂" / "Н₂" differ in rendered width.
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 6)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cluster.add_child(grid)

	_add_bar(grid, "health", "ЗДР")
	_add_bar(grid, "oxygen", "О₂")
	_add_bar(grid, "hydrogen", "Н₂")


func _add_bar(grid: GridContainer, key: String, label_text: String) -> void:
	var name_label := Label.new()
	name_label.text = label_text
	name_label.theme_type_variation = &"HudSmall"
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_outline(name_label)
	grid.add_child(name_label)

	var bar_size := Vector2(BAR_LEN, BAR_H)
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
	mat.set_shader_parameter("segments", 16.0)
	mat.set_shader_parameter("gap_ratio", 0.18)
	mat.set_shader_parameter("glow_strength", GLOW_NOMINAL)
	mat.set_shader_parameter("lead_strength", 0.24)
	bar.material = mat
	grid.add_child(bar)

	var value_label := Label.new()
	value_label.theme_type_variation = &"HudValue"
	value_label.add_theme_font_size_override("font_size", 12)
	value_label.custom_minimum_size = Vector2(VALUE_COL, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_outline(value_label)
	grid.add_child(value_label)

	_bars[key] = {"mat": mat, "value": value_label}


# Frameless text needs its own contrast: a tight dark outline keeps the cluster
# readable against sunlit regolith without reintroducing a panel behind it.
func _outline(label: Label) -> void:
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.75))
	label.add_theme_constant_override("outline_size", 3)


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
	mat.set_shader_parameter(
		"glow_strength",
		GLOW_CRITICAL if fraction <= CRIT_FRACTION else GLOW_NOMINAL
	)
	var value: Label = refs["value"]
	value.text = "%d%%" % int(round(fraction * 100.0))
	# Nominal readings stay quiet; a degraded channel is the only thing that
	# earns a lit numeral.
	value.add_theme_color_override(
		"font_color",
		HudTokens.COL_DIM if fraction > WARN_FRACTION else col
	)


func _color_for_fraction(fraction: float) -> Color:
	if fraction <= CRIT_FRACTION:
		return HudTokens.COL_CRITICAL
	if fraction <= WARN_FRACTION:
		return HudTokens.COL_WARNING
	return HudTokens.COL_OK
