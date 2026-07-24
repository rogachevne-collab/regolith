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
##
## Low-O₂ warning (OXYGEN-SURVIVAL-V0): restrained vignette + rate-limited cue.
## Thresholds/cooldown live in game_balance.json `hud.*` — no magic numbers.

const BAR_LEN := 92.0
const BAR_H := 6.0
# Width reserved for the numerals so the cluster's right edge does not jitter
# as values step 100 → 99 → 9.
const VALUE_COL := 34.0

# Bar palette fallbacks when balance is unavailable (tests / early boot).
const WARN_FRACTION_FALLBACK := 0.5
const CRIT_FRACTION_FALLBACK := 0.25

# Glow rises on critical so a failing channel reads urgent, not merely red.
const GLOW_NOMINAL := 0.14
const GLOW_CRITICAL := 0.34

const VIGNETTE_WARN_ALPHA := 0.10
const VIGNETTE_CRIT_ALPHA := 0.22

var _suit: Node
# channel key -> {"mat": ShaderMaterial, "value": Label}
var _bars: Dictionary = {}
var _vignette: ColorRect
var _warn_audio: AudioStreamPlayer
var _warn_stream: AudioStreamWAV
var _last_audio_msec := -1000000
var _was_low_oxygen := false


func setup(ctx: Dictionary) -> void:
	var next_suit: Node = ctx.get("suit")
	if (
		_suit != null
		and is_instance_valid(_suit)
		and _suit.has_signal("changed")
		and _suit.changed.is_connected(_refresh)
	):
		_suit.changed.disconnect(_refresh)
	_suit = next_suit
	if (
		_suit != null
		and _suit.has_signal("changed")
		and not _suit.changed.is_connected(_refresh)
	):
		_suit.changed.connect(_refresh)
	_refresh()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_refresh()


func _build() -> void:
	_vignette = ColorRect.new()
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.color = Color(HudTokens.COL_CRITICAL, 0.0)
	_vignette.visible = false
	add_child(_vignette)

	_warn_audio = AudioStreamPlayer.new()
	_warn_audio.bus = &"Master"
	_warn_audio.volume_db = -8.0
	add_child(_warn_audio)

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
	var oxygen_fraction := float(_suit.oxygen_fraction())
	_update_bar("oxygen", oxygen_fraction)
	_update_bar("hydrogen", _suit.hydrogen_fraction())
	_update_low_oxygen_warning(oxygen_fraction)


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
		GLOW_CRITICAL if fraction <= _bar_crit_fraction() else GLOW_NOMINAL
	)
	var value: Label = refs["value"]
	value.text = "%d%%" % int(round(fraction * 100.0))
	# Nominal readings stay quiet; a degraded channel is the only thing that
	# earns a lit numeral.
	value.add_theme_color_override(
		"font_color",
		HudTokens.COL_DIM if fraction > _bar_warn_fraction() else col
	)


func _color_for_fraction(fraction: float) -> Color:
	if fraction <= _bar_crit_fraction():
		return HudTokens.COL_CRITICAL
	if fraction <= _bar_warn_fraction():
		return HudTokens.COL_WARNING
	return HudTokens.COL_OK


func _bar_warn_fraction() -> float:
	return WARN_FRACTION_FALLBACK


func _bar_crit_fraction() -> float:
	return CRIT_FRACTION_FALLBACK


func _update_low_oxygen_warning(oxygen_fraction: float) -> void:
	if _vignette == null:
		return
	var warn := GameBalance.hud_float("low_oxygen_warn_fraction", 0.25)
	var crit := GameBalance.hud_float("low_oxygen_crit_fraction", 0.12)
	var is_low := oxygen_fraction <= warn
	if not is_low:
		_vignette.visible = false
		_vignette.color = Color(HudTokens.COL_CRITICAL, 0.0)
		_was_low_oxygen = false
		return
	var t := 0.0
	if warn > crit:
		t = clampf((warn - oxygen_fraction) / (warn - crit), 0.0, 1.0)
	else:
		t = 1.0 if oxygen_fraction <= crit else 0.0
	var alpha := lerpf(VIGNETTE_WARN_ALPHA, VIGNETTE_CRIT_ALPHA, t)
	_vignette.color = Color(HudTokens.COL_CRITICAL, alpha)
	_vignette.visible = alpha > 0.001
	var cooldown_s := GameBalance.hud_float("low_oxygen_audio_cooldown_s", 3.0)
	var now_msec := Time.get_ticks_msec()
	var cooldown_msec := int(cooldown_s * 1000.0)
	var edge := not _was_low_oxygen
	_was_low_oxygen = true
	if edge or now_msec - _last_audio_msec >= cooldown_msec:
		_play_low_oxygen_cue()
		_last_audio_msec = now_msec


func _play_low_oxygen_cue() -> void:
	if _warn_audio == null:
		return
	if _warn_stream == null:
		_warn_stream = _generate_low_oxygen_cue()
		_warn_audio.stream = _warn_stream
	if _warn_audio.playing:
		_warn_audio.stop()
	_warn_audio.play()


func _generate_low_oxygen_cue() -> AudioStreamWAV:
	## Short soft dual-tone beep; generated once, no disk asset.
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = 22050
	stream.stereo = false
	var sample_count := int(stream.mix_rate * 0.12)
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	for i: int in range(sample_count):
		var t := float(i) / float(stream.mix_rate)
		var env := 1.0 - (float(i) / float(sample_count))
		env *= env
		var sample := (
			sin(TAU * 880.0 * t) * 0.22
			+ sin(TAU * 660.0 * t) * 0.14
		) * env
		var q := int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, q)
	stream.data = data
	return stream
