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
	"large_frame": "L25",
	"frame_beam": "BEM",
	"frame_basalt": "BAS",
	"power_source": "PWR",
	"power_distributor": "DST",
	"power_battery": "BAT",
	"stationary_drill": "SDR",
	"cargo_store": "CRG",
	"cargo_pipe": "PIP",
	"processor": "PRC",
	"fabricator": "FAB",
	"foundation": "FND",
	"connect": "CON",
	"piston_base": "PST",
}

## Short Cyrillic chrome labels for construction archetypes shown in the Block
## Palette name row. Keeps cards readable without mid-word wrapping of raw ids.
const ARCHETYPE_LABELS := {
	"frame": "КАРКАС",
	"large_frame": "БЛОК 2.5М",
	"frame_beam": "БАЛКА",
	"frame_basalt": "БАЗАЛЬТ",
	"power_source": "ПИТАНИЕ",
	"power_distributor": "РАСПРЕД",
	"power_battery": "БАТАРЕЯ",
	"stationary_drill": "БУР",
	"cargo_store": "СКЛАД",
	"cargo_pipe": "ТРУБА",
	"processor": "ПРОЦЕССОР",
	"fabricator": "ФАБРИКАТОР",
	"foundation": "ФУНДАМЕНТ",
	"rover_frame": "БЛОК РОВЕРА",
	"rover_wheel": "КОЛЕСО",
	"runtime_custom": "СВОЙ БЛОК",
	"piston_base": "ПОРШЕНЬ",
	"piston_head": "ГОЛОВКА",
}

const STORE_LABELS := {
	"player": "ИГРОК",
}


## Cyrillic chrome labels for known resource ids shown in the inventory /
## store view. Falls back to the raw id (uppercased) for unknown resources so
## presentation never fabricates a name it does not have.
const RESOURCE_LABELS := {
	"construction_component": "КОМПОНЕНТ",
	"raw_regolith": "РЕГОЛИТ",
	"regolith_fines": "ФРАКЦИЯ",
	"sintered_basalt": "БАЗАЛЬТ",
	"calcined_oxide": "ОКСИД",
	"metal_ingot": "СЛИТОК",
	"custom_component": "КОМПОНЕНТ",
	"tool_hand_drill": "БУР",
	"tool_welder": "СВАРКА",
	"tool_grinder": "БОЛГАРКА",
	"tool_connector": "СОЕДИНЕНИЕ",
}

const RECIPE_LABELS := {
	"crush_regolith": "ДРОБЛЕНИЕ РЕГОЛИТА",
	"sinter_basalt": "СПЕКАНИЕ БАЗАЛЬТА",
	"calcine_fines": "ОБЖИГ ФРАКЦИИ",
	"reduce_oxide": "ВОССТАНОВЛЕНИЕ ОКСИДА",
	"sinter_component": "СПЕКАНИЕ КОМПОНЕНТА",
}

## Short latin item codes for terminal grid icons (chrome only).
const ITEM_CODES := {
	"raw_regolith": "RGL",
	"regolith_fines": "FNS",
	"sintered_basalt": "BAS",
	"calcined_oxide": "OXD",
	"metal_ingot": "ING",
	"construction_component": "CMP",
	"tool_hand_drill": "DRL",
	"tool_welder": "WLD",
	"tool_grinder": "GRD",
	"tool_connector": "CON",
}

## Category-tinted icon colors; stable per item_id via catalog category.
const ITEM_CATEGORY_COLORS := {
	"ore": Color(0.82, 0.58, 0.28),
	"material": Color(0.36, 0.62, 0.78),
	"ingot": COL_VALID,
	"component": COL_OK,
	"tool": COL_TEXT,
	"consumable": COL_WARNING,
	"bottle": COL_OK,
}

## Frozen per-item icon colors (category-derived fixtures).
const ITEM_COLORS := {
	"raw_regolith": ITEM_CATEGORY_COLORS["ore"],
	"regolith_fines": ITEM_CATEGORY_COLORS["ore"],
	"sintered_basalt": ITEM_CATEGORY_COLORS["material"],
	"calcined_oxide": ITEM_CATEGORY_COLORS["material"],
	"metal_ingot": ITEM_CATEGORY_COLORS["ingot"],
	"construction_component": ITEM_CATEGORY_COLORS["component"],
	"tool_hand_drill": ITEM_CATEGORY_COLORS["tool"],
	"tool_welder": ITEM_CATEGORY_COLORS["tool"],
	"tool_grinder": ITEM_CATEGORY_COLORS["tool"],
	"tool_connector": ITEM_CATEGORY_COLORS["tool"],
}


static func load_theme() -> Theme:
	return load(THEME_PATH)


static func store_label(store_id: String) -> String:
	if STORE_LABELS.has(store_id):
		return STORE_LABELS[store_id]
	if store_id.is_empty():
		return "—"
	return store_id.to_upper()


static func resource_label(resource_id: String) -> String:
	if RESOURCE_LABELS.has(resource_id):
		return RESOURCE_LABELS[resource_id]
	if resource_id.is_empty():
		return "—"
	return resource_id.to_upper()


static func recipe_label(recipe_id: String) -> String:
	if RECIPE_LABELS.has(recipe_id):
		return RECIPE_LABELS[recipe_id]
	if recipe_id.is_empty():
		return "—"
	return recipe_id.to_upper()


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
		&"no_power", &"outside_power_radius", &"port_disconnected":
			return COL_WARNING
		&"electric_disconnected", &"cargo_disconnected":
			return COL_WARNING
		&"no_input", &"no_terrain_contact", &"storage_full", &"queue_full":
			return COL_WARNING
		&"standby":
			return COL_DIM
		&"disabled":
			return COL_DIM
		&"moving":
			return COL_OK
		&"joint_limit":
			return COL_WARNING
		&"stuck", &"overloaded":
			return COL_WARNING
		&"idle":
			return COL_DIM
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
		&"no_power":
			return "НЕТ ПИТАНИЯ"
		&"outside_power_radius":
			return "ВНЕ ЗОНЫ"
		&"port_disconnected":
			return "НЕТ СВЯЗИ"
		&"electric_disconnected":
			return "НЕТ ЭЛЕКТРОСВЯЗИ"
		&"cargo_disconnected":
			return "НЕТ КАРГО-СВЯЗИ"
		&"no_input":
			return "НЕТ СЫРЬЯ"
		&"no_terrain_contact":
			return "НЕТ ГРУНТА"
		&"storage_full":
			return "СКЛАД ПОЛОН"
		&"disabled":
			return "ВЫКЛ"
		&"queue_full":
			return "ОЧЕРЕДЬ ПОЛНА"
		&"standby":
			return "ПРОСТОЙ"
		&"moving":
			return "ДВИЖЕНИЕ"
		&"joint_limit":
			return "ПРЕДЕЛ"
		&"stuck":
			return "ЗАЕДАНИЕ"
		&"overloaded":
			return "ПЕРЕГРУЗ"
		&"idle":
			return "ПРОСТОЙ"
		_:
			return "—"


static func tool_code(id: String) -> String:
	if TOOL_CODES.has(id):
		return TOOL_CODES[id]
	if id.is_empty():
		return ""
	return id.substr(0, 3).to_upper()


static func item_code(item_id: String) -> String:
	if ITEM_CODES.has(item_id):
		return ITEM_CODES[item_id]
	if item_id.is_empty():
		return ""
	return item_id.substr(0, 3).to_upper()


static func item_color(item_id: String) -> Color:
	if ITEM_COLORS.has(item_id):
		return ITEM_COLORS[item_id]
	var category := ResourceCatalog.category(item_id)
	if ITEM_CATEGORY_COLORS.has(category):
		return ITEM_CATEGORY_COLORS[category]
	return COL_DIM


## Colored plate with a short item code. API is bound to item_id so future PNG
## art can replace the primitive without changing terminal transfer contracts.
static func make_item_icon(item_id: String, size: float = SLOT_SIZE.x) -> Control:
	var icon_size := Vector2(size, size)
	var holder := Control.new()
	holder.custom_minimum_size = icon_size
	holder.size = icon_size
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var tint := ColorRect.new()
	tint.color = Color(item_color(item_id), 0.28)
	tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(tint)

	var code_label := Label.new()
	code_label.text = item_code(item_id)
	code_label.theme_type_variation = &"HudValue"
	code_label.add_theme_color_override("font_color", item_color(item_id))
	code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	code_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	code_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	code_label.clip_text = true
	code_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(code_label)

	return holder


static func archetype_label(archetype_id: String, gateway_name: String = "") -> String:
	if ARCHETYPE_LABELS.has(archetype_id):
		return ARCHETYPE_LABELS[archetype_id]
	if not gateway_name.is_empty() and gateway_name != archetype_id:
		return gateway_name.to_upper()
	if archetype_id.is_empty():
		return "—"
	return archetype_id.replace("_", " ").to_upper()


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


## Segmented progress bar matching the suit vitals chrome. Returns
## `{"row": HBoxContainer, "mat": ShaderMaterial, "value": Label}`.
static func make_progress_bar(
	width: float = 196.0,
	label_text: String = "ЦИКЛ"
) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var name_label := Label.new()
	name_label.text = label_text
	name_label.theme_type_variation = &"HudSmall"
	name_label.custom_minimum_size = Vector2(36, 0)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)

	var bar_size := Vector2(width, BAR_SIZE.y)
	var bar := ColorRect.new()
	bar.color = Color(1, 1, 1, 1)
	bar.custom_minimum_size = bar_size
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load(SH_BAR)
	mat.set_shader_parameter("rect_size", bar_size)
	mat.set_shader_parameter("fill", 0.0)
	mat.set_shader_parameter("fill_color", COL_VALID)
	mat.set_shader_parameter("segments", 28.0)
	mat.set_shader_parameter("gap_ratio", 0.14)
	mat.set_shader_parameter("glow_strength", 0.34)
	mat.set_shader_parameter("lead_strength", 0.55)
	bar.material = mat
	row.add_child(bar)

	var value_label := Label.new()
	value_label.theme_type_variation = &"HudValue"
	value_label.custom_minimum_size = Vector2(36, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value_label)

	return {"row": row, "mat": mat, "value": value_label}
