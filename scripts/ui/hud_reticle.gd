extends Control
## Reticle + quiet target-summary line. Presentation only: reads
## InteractionQuery.current_hit and colours the crosshair by validity / target
## kind, never mutating state. Frozen style from HudTokens.

var _query: InteractionQuery
var _gateway: WorldCommandGateway

var _reticle: ColorRect
var _reticle_mat: ShaderMaterial
var _tline: Label
var _last_color := Color(1, 1, 1, 1)


func setup(ctx: Dictionary) -> void:
	_query = ctx.get("query")
	_gateway = ctx.get("gateway")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_reticle = HudTokens.make_reticle()
	_reticle_mat = _reticle.material as ShaderMaterial
	_reticle.anchor_left = 0.5
	_reticle.anchor_right = 0.5
	_reticle.anchor_top = 0.5
	_reticle.anchor_bottom = 0.5
	_reticle.offset_left = -32.0
	_reticle.offset_top = -32.0
	_reticle.offset_right = 32.0
	_reticle.offset_bottom = 32.0
	add_child(_reticle)

	_tline = Label.new()
	_tline.theme_type_variation = &"HudSmall"
	_tline.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_tline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tline.anchor_left = 0.5
	_tline.anchor_right = 0.5
	_tline.anchor_top = 0.5
	_tline.anchor_bottom = 0.5
	_tline.offset_left = -160.0
	_tline.offset_right = 160.0
	_tline.offset_top = 34.0
	_tline.offset_bottom = 54.0
	add_child(_tline)


func _process(_delta: float) -> void:
	if _query == null:
		return
	# An open window owns the cursor; a crosshair drawn over its middle aims at
	# nothing.
	var modal_open := HudTokens.modal_window_open(self)
	_reticle.visible = not modal_open
	if modal_open:
		_tline.visible = false
		return
	var hit := _query.current_hit
	var color := (
		HudTokens.COL_VALID
		if hit.valid
		else Color(1.0, 1.0, 1.0, 0.55)
	)
	if color != _last_color:
		_reticle_mat.set_shader_parameter("color", color)
		_last_color = color
	_tline.text = _target_summary(hit)
	_tline.visible = not _tline.text.is_empty()


func _target_summary(hit: InteractionHit) -> String:
	if not hit.valid:
		return ""
	if hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT:
		return ""
	var archetype_id := str(hit.metadata.get("archetype_id", ""))
	if archetype_id in ["processor", "fabricator", "stationary_drill", "cargo_store"]:
		return ""
	if archetype_id.is_empty():
		return ""
	var display := _gateway.archetype_display_name(archetype_id).to_upper()
	var status := StringName(hit.metadata.get("status_reason", &"element_incomplete"))
	return "%s  \u00b7  %s" % [display, _status_summary(hit.metadata, status)]


func _status_summary(meta: Dictionary, status: StringName) -> String:
	if status == &"port_disconnected" or status == &"cargo_disconnected":
		return HudTokens.status_label(status)
	if status == &"no_input":
		var missing := str(meta.get("missing_input_resource_id", ""))
		if not missing.is_empty():
			return "НЕТ %s" % HudTokens.resource_label(missing)
		if not bool(meta.get("cargo_network_connected", false)):
			return "НЕТ КАРГО-СВЯЗИ"
		return "НЕТ СЫРЬЯ"
	if status == &"standby":
		return "ПРОСТОЙ"
	return HudTokens.status_label(status)
