extends Control
## Cabin power panel (bottom-right) while seated in transport. Presentation only:
## reads `WorldCommandGateway.vehicle_power_snapshot()` — charge bar, load (W),
## and predicted trip duration at the current demand. Never mutates simulation.

const PANEL_SIZE := Vector2(252, 118)
const BAR_LEN := 140.0
const WARN_FRACTION := 0.5
const CRIT_FRACTION := 0.25
const REFRESH_S := 0.2

var _gateway: WorldCommandGateway
var _player: Node
var _panel: Panel
var _bar_mat: ShaderMaterial
var _pct_label: Label
var _load_label: Label
var _eta_label: Label
var _status_label: Label
var _refresh_left := 0.0


func setup(ctx: Dictionary) -> void:
	_gateway = ctx.get("gateway")
	_player = ctx.get("player")
	_refresh()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_refresh()


func _process(delta: float) -> void:
	_refresh_left = maxf(_refresh_left - delta, 0.0)
	if _refresh_left > 0.0:
		return
	_refresh_left = REFRESH_S
	_refresh()


func _build() -> void:
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -(HudTokens.PANEL_MARGIN + PANEL_SIZE.x)
	_panel.offset_right = -HudTokens.PANEL_MARGIN
	_panel.offset_top = -(PANEL_SIZE.y + HudTokens.PANEL_MARGIN)
	_panel.offset_bottom = -HudTokens.PANEL_MARGIN
	_panel.visible = false
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

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title_row)

	title_row.add_child(HudTokens.make_emblem(14.0))

	var title := Label.new()
	title.text = "ТРАНСПОРТ"
	title.theme_type_variation = &"HudSmall"
	title.add_theme_color_override("font_color", HudTokens.COL_TITLE)
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(spacer)

	_status_label = Label.new()
	_status_label.text = "—"
	_status_label.theme_type_variation = &"HudSmall"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	title_row.add_child(_status_label)

	_add_charge_row(vb)

	_load_label = Label.new()
	_load_label.theme_type_variation = &"HudSmall"
	_load_label.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_load_label.text = "НАГРУЗКА —"
	vb.add_child(_load_label)

	_eta_label = Label.new()
	_eta_label.theme_type_variation = &"HudSmall"
	_eta_label.add_theme_color_override("font_color", HudTokens.COL_TEXT)
	_eta_label.text = "ЗАПАС —"
	vb.add_child(_eta_label)

	_panel.add_child(HudTokens.make_panel_overlay(PANEL_SIZE))


func _add_charge_row(parent_node: Node) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent_node.add_child(row)

	var name_label := Label.new()
	name_label.text = "АКБ"
	name_label.theme_type_variation = &"HudSmall"
	name_label.custom_minimum_size = Vector2(28, 0)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)

	var bar_size := Vector2(BAR_LEN, HudTokens.BAR_SIZE.y)
	var bar := ColorRect.new()
	bar.color = Color(1, 1, 1, 1)
	bar.custom_minimum_size = bar_size
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_mat = ShaderMaterial.new()
	_bar_mat.shader = load(HudTokens.SH_BAR)
	_bar_mat.set_shader_parameter("rect_size", bar_size)
	_bar_mat.set_shader_parameter("fill", 1.0)
	_bar_mat.set_shader_parameter("fill_color", HudTokens.COL_OK)
	_bar_mat.set_shader_parameter("segments", 24.0)
	_bar_mat.set_shader_parameter("gap_ratio", 0.16)
	_bar_mat.set_shader_parameter("glow_strength", 0.22)
	_bar_mat.set_shader_parameter("lead_strength", 0.35)
	bar.material = _bar_mat
	row.add_child(bar)

	_pct_label = Label.new()
	_pct_label.theme_type_variation = &"HudValue"
	_pct_label.custom_minimum_size = Vector2(36, 0)
	_pct_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_pct_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_pct_label)


func _refresh() -> void:
	if _panel == null:
		return
	var seated := (
		_player != null
		and _player.has_method("is_in_vehicle")
		and bool(_player.call("is_in_vehicle"))
	)
	if not seated or _gateway == null:
		_panel.visible = false
		return

	var snap: Dictionary = _gateway.vehicle_power_snapshot()
	if not bool(snap.get("valid", false)):
		_panel.visible = false
		return

	_panel.visible = true
	var fraction := clampf(float(snap.get("battery_fraction", 0.0)), 0.0, 1.0)
	var col := _color_for_fraction(fraction)
	if _bar_mat != null:
		_bar_mat.set_shader_parameter("fill", fraction)
		_bar_mat.set_shader_parameter("fill_color", col)
	_pct_label.text = "%d%%" % int(round(fraction * 100.0))
	_pct_label.add_theme_color_override("font_color", col)

	var demand_w := float(snap.get("demand_w", 0.0))
	var net_drain_w := float(snap.get("net_drain_w", 0.0))
	_load_label.text = "НАГРУЗКА %d Вт" % int(round(demand_w))
	if net_drain_w > 0.5:
		_load_label.add_theme_color_override("font_color", HudTokens.COL_TEXT)
	else:
		_load_label.add_theme_color_override("font_color", HudTokens.COL_DIM)

	var eta_s := float(snap.get("eta_s", VehiclePowerSnapshotBuilder.ETA_INFINITE))
	var eta_text := VehiclePowerSnapshotBuilder.format_eta_s(eta_s)
	if eta_s < 0.0:
		_eta_label.text = "ЗАПАС ∞"
		_eta_label.add_theme_color_override("font_color", HudTokens.COL_OK)
	else:
		_eta_label.text = "ЗАПАС %s" % eta_text
		_eta_label.add_theme_color_override("font_color", col)

	var powered := bool(snap.get("powered", false))
	if powered:
		_status_label.text = "В СЕТИ"
		_status_label.add_theme_color_override("font_color", HudTokens.COL_OK)
	else:
		var reason: StringName = snap.get("power_reason", &"no_power")
		_status_label.text = HudTokens.status_label(reason)
		_status_label.add_theme_color_override(
			"font_color",
			HudTokens.color_for_status(reason)
		)


func _color_for_fraction(fraction: float) -> Color:
	if fraction <= CRIT_FRACTION:
		return HudTokens.COL_CRITICAL
	if fraction <= WARN_FRACTION:
		return HudTokens.COL_WARNING
	return HudTokens.COL_OK
