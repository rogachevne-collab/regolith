class_name HudTokens
extends RefCounted
## Frozen HUD theme tokens + declarative widget builders. Single source of the
## style-proof values (see docs/specs/HUD-UI-01.md "Theme-токены"). Presentation
## only: builders return styled nodes, they never read or mutate simulation state.

const THEME_PATH := "res://resources/ui/hud_theme.tres"
const SH_PANEL := "res://resources/ui/shaders/hud_panel.gdshader"
const SH_BAR := "res://resources/ui/shaders/hud_bar.gdshader"
const SH_RETICLE := "res://resources/ui/shaders/hud_reticle.gdshader"
const SH_EMBLEM := "res://resources/ui/shaders/hud_emblem.gdshader"

# --- Frozen state palette (CONSTRUCTION-V1 colour language) ---
const COL_VALID := Color(0.20, 0.882, 1.0)      # cyan   — valid / available
const COL_OK := Color(0.298, 0.608, 0.91)       # steel  — operational / ok
const COL_WARNING := Color(1.0, 0.694, 0.235)   # amber  — warning / damaged
const COL_CRITICAL := Color(1.0, 0.267, 0.22)   # red    — critical / broken

# --- Frozen neutrals ---
const COL_BG := Color(0.0196, 0.0314, 0.0471)   # bg_screen #05080C
const COL_BORDER := Color(0.129, 0.18, 0.235)   # panel_border hairline #212E3C
const COL_TEXT := Color(0.78, 0.871, 0.925)     # text_primary #C7DEEC
const COL_TITLE := Color(0.702, 0.847, 0.914)   # text_title #B3D8E9
const COL_DIM := Color(0.431, 0.518, 0.58)      # text_dim #6E8494

# --- Frozen national-accent tick (chrome only, low opacity) ---
const TICK_WHITE := Color(0.859, 0.898, 0.937, 0.5)  # #DBE5EF
const TICK_BLUE := Color(0.20, 0.36, 0.66, 0.5)
const TICK_RED := Color(0.780, 0.239, 0.239, 0.5)    # #C73D3D

# --- Frozen geometry / spacing ---
const PANEL_MARGIN := 48        # panel↔screen (48–52px)
const SECTION_GAP := 11         # row/section gap
const BAR_SIZE := Vector2(232, 10)
const SLOT_SIZE := Vector2(52, 52)
const SLOT_GAP := 10
const TOOLBAR_BOTTOM := 48
const INFO_KEY_COL := 96

## Latin tool/archetype codes shown in toolbar slots (chrome). Cyrillic names
## live in the target panel; codes stay short latin abbreviations per contract.
const TOOL_CODES := {
	"drill": "DRL",
	"weld": "WLD",
	"grinder": "GRD",
	"frame": "FRM",
	"frame_beam": "BEM",
	"power_source": "PWR",
	"stationary_drill": "SDR",
	"cargo_store": "CRG",
	"processor": "PRC",
	"fabricator": "FAB",
	"foundation": "FND",
}


## Cyrillic chrome labels for known resource ids shown in the inventory /
## store view. Falls back to the raw id (uppercased) for unknown resources so
## presentation never fabricates a name it does not have.
const RESOURCE_LABELS := {
	"construction_component": "КОМПОНЕНТ",
}


static func load_theme() -> Theme:
	return load(THEME_PATH)


static func resource_label(resource_id: String) -> String:
	if RESOURCE_LABELS.has(resource_id):
		return RESOURCE_LABELS[resource_id]
	if resource_id.is_empty():
		return "—"
	return resource_id.to_upper()


## Compact numeric formatting for store amounts: whole numbers show without a
## decimal, fractional values keep one place.
static func format_amount(value: float) -> String:
	var rounded := roundf(value)
	if absf(value - rounded) < 0.05:
		return "%d" % int(rounded)
	return "%.1f" % value


static func color_for_status(status: StringName) -> Color:
	match status:
		&"ok":
			return COL_OK
		&"element_incomplete":
			return COL_VALID
		&"damaged":
			return COL_WARNING
		&"element_broken":
			return COL_CRITICAL
		_:
			return COL_TEXT


static func status_label(status: StringName) -> String:
	match status:
		&"ok":
			return "РАБОТА"
		&"element_incomplete":
			return "МОНТАЖ"
		&"damaged":
			return "ПОВРЕЖДЕНИЕ"
		&"element_broken":
			return "СЛОМАН"
		_:
			return "—"


static func tool_code(id: String) -> String:
	if TOOL_CODES.has(id):
		return TOOL_CODES[id]
	if id.is_empty():
		return ""
	return id.substr(0, 3).to_upper()


# Additive framed-panel overlay (hairline border + faint edge glow + quiet
# corner accents) sitting on top of the StyleBoxFlat fill. Frozen params.
static func make_panel_overlay(rect_size: Vector2, glow: Color = COL_VALID, border: Color = COL_OK) -> ColorRect:
	var overlay := ColorRect.new()
	overlay.color = Color(1, 1, 1, 1)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load(SH_PANEL)
	mat.set_shader_parameter("rect_size", rect_size)
	mat.set_shader_parameter("glow_color", glow)
	mat.set_shader_parameter("border_color", border)
	mat.set_shader_parameter("border_width", 1.0)
	mat.set_shader_parameter("glow_width", 6.0)
	mat.set_shader_parameter("glow_strength", 0.14)
	mat.set_shader_parameter("corner_len", 14.0)
	mat.set_shader_parameter("corner_strength", 0.4)
	mat.set_shader_parameter("scanline_density", 3.5)
	mat.set_shader_parameter("scanline_strength", 0.02)
	mat.set_shader_parameter("sweep_speed", 0.1)
	mat.set_shader_parameter("sweep_strength", 0.0)
	overlay.material = mat
	return overlay


static func make_reticle(rect_size: Vector2 = Vector2(64, 64)) -> ColorRect:
	var reticle := ColorRect.new()
	reticle.color = Color(1, 1, 1, 1)
	reticle.custom_minimum_size = rect_size
	reticle.size = rect_size
	reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load(SH_RETICLE)
	mat.set_shader_parameter("rect_size", rect_size)
	mat.set_shader_parameter("color", COL_VALID)
	mat.set_shader_parameter("gap", 6.0)
	mat.set_shader_parameter("len", 9.0)
	mat.set_shader_parameter("thick", 1.0)
	mat.set_shader_parameter("dot_size", 1.0)
	mat.set_shader_parameter("bracket_strength", 0.0)
	mat.set_shader_parameter("glow_strength", 0.15)
	reticle.material = mat
	return reticle


static func make_emblem(px: float = 22.0, color: Color = COL_VALID) -> ColorRect:
	var emblem := ColorRect.new()
	emblem.color = Color(1, 1, 1, 1)
	emblem.custom_minimum_size = Vector2(px, px)
	emblem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load(SH_EMBLEM)
	mat.set_shader_parameter("color", color)
	mat.set_shader_parameter("radius", 0.58)
	mat.set_shader_parameter("line_w", 0.06)
	emblem.material = mat
	return emblem


# Understated tricolor accent tick: three short segments at low opacity. An
# accent, not a flag — chrome only, no branding.
static func make_national_tick() -> Control:
	var holder := HBoxContainer.new()
	holder.add_theme_constant_override("separation", 2)
	holder.size_flags_horizontal = Control.SIZE_SHRINK_END
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c: Color in [TICK_WHITE, TICK_BLUE, TICK_RED]:
		var seg := ColorRect.new()
		seg.color = c
		seg.custom_minimum_size = Vector2(9, 3)
		seg.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(seg)
	return holder


static func make_gap(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func make_divider() -> Panel:
	var div := Panel.new()
	div.theme_type_variation = &"HudDivider"
	div.custom_minimum_size = Vector2(0, 1)
	div.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	div.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return div
