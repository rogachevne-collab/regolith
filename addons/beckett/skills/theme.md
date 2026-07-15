# Theme & styling — skin Control/Window UI with Theme + StyleBox

> A `Theme` resource holds named styling keyed by (item, theme_type). Assign to `Control.theme` to cascade; use `theme_override_*` for one node.

## Version note
- **Core theme API is Godot 4.0** and stable through 4.6: `Theme.set_color/set_stylebox/set_type_variation`, the `DataType` enum, `Control.add_theme_*_override`/`get_theme_*`, all StyleBox subclasses. Verified live on 4.6.2.
- **Godot 4.0 removed** `DynamicFont`/`DynamicFontData` → use `FontFile` (imported .ttf/.otf/.woff), `FontVariation` (axes/spacing/faux styles), `SystemFont` (OS fonts).
- **StyleBoxTexture** nine-patch margins were renamed `margin_*` → `texture_margin_*` in 4.0 (old names gone).
- **Label** constant `paragraph_spacing` exists in 4.3+ only — absent in 4.0–4.2. Confirm with `describe_class class=Label` before relying on it.

Check with `get_godot_version` / `describe_class`.

## How styling resolves (highest → lowest)
1. Local node override (`add_theme_*_override` / `theme_override_*` property) — **does NOT cascade to children**.
2. `Control.theme` on the nearest ancestor that sets one — **cascades to all direct + indirect Control descendants**.
3. Project-wide theme (`gui/theme/custom`).
4. Built-in engine default theme.

## Theme (Resource)
- Properties: `default_font` (Font), `default_font_size` (int, default **-1** = unset), `default_base_scale` (float, default **0.0** = unset).
- Setters: `set_color(name, theme_type, color)`, `set_stylebox(name, theme_type, stylebox)` *(its param is named `texture` but takes a StyleBox)*, `set_font(name, theme_type, font)`, `set_font_size(name, theme_type, size)`, `set_constant(name, theme_type, int)`, `set_icon(name, theme_type, Texture2D)`.
- Variations: `add_type(theme_type)`, `set_type_variation(theme_type, base_type)`, `clear()`, `has_color(name, theme_type)`.
- `DataType` (for `set_theme_item`): `DATA_TYPE_COLOR`, `_CONSTANT`, `_FONT`, `_FONT_SIZE`, `_ICON`, `_STYLEBOX`.

## Control theme helpers
- Overrides (local): `add_theme_color_override(name, Color)`, `add_theme_stylebox_override(name, StyleBox)`, `add_theme_font_override`, `add_theme_font_size_override`, `add_theme_constant_override`, `add_theme_icon_override`; matching `remove_theme_*_override(name)`.
- Lookup: `get_theme_color(name, theme_type=&"")`, `get_theme_stylebox(...)`, etc.; `has_theme_color_override(name) -> bool`.
- `theme_type_variation` (StringName) — resolve items as a named variation instead of the class.
- Batch many overrides: `begin_bulk_theme_override()` … `end_bulk_theme_override()`. Signal: `theme_changed`. `Window` has the same `theme` + helpers.
- Inspector paths usable with `set_property`: `theme_override_colors/<name>`, `theme_override_styles/<name>`, `theme_override_fonts/<name>`, `theme_override_font_sizes/<name>`, `theme_override_constants/<name>`, `theme_override_icons/<name>`.

## StyleBox subclasses
- `StyleBoxFlat` — drawn box: `bg_color` (Color), `draw_center` (bool), `border_color`, `border_width_left/top/right/bottom` (int), `corner_radius_*` (int), `expand_margin_*`, `shadow_color`/`shadow_size`/`shadow_offset`, `anti_aliasing`, `skew`. Helpers: `set_border_width_all(int)`, `set_corner_radius_all(int)`, `set_expand_margin_all(float)`.
- `StyleBoxTexture` — 9-patch: `texture` (Texture2D), `texture_margin_*` (float), `expand_margin_*`, `axis_stretch_horizontal/vertical` (AxisStretchMode: `STRETCH`/`TILE`/`TILE_FIT`). Helper: `set_texture_margin_all(float)`.
- `StyleBoxEmpty` — invisible; keeps `content_margin_*` padding. Use to remove a background.
- `StyleBoxLine` — `color`, `thickness` (int), `vertical` (bool); used by separators.
- All StyleBox: `content_margin_left/top/right/bottom` (float, default **-1** = auto-derive from border, not 0); `set_content_margin_all(float)`.

## Theme item keys (exact names)
- **Button** (`theme_type="Button"`): styleboxes `normal, hover, pressed, hover_pressed, disabled, focus`; colors `font_color, font_pressed_color, font_hover_color, font_focus_color, font_disabled_color, font_outline_color`; `font`, `font_size`, `icon`; constants `h_separation, outline_size, icon_max_width`.
- **Label** (`theme_type="Label"`): colors `font_color, font_outline_color, font_shadow_color`; `font`, `font_size`; constants `line_spacing, outline_size, shadow_offset_x, shadow_offset_y` (+ `paragraph_spacing` in 4.3+).
- **Panel / PanelContainer**: stylebox item `panel`.

## Fonts
- `FontFile` — the usual concrete Font; just `load("res://font.ttf")`. `load_dynamic_font(path)`, `multichannel_signed_distance_field` for crisp scaling.
- `FontVariation` — wraps `base_font`; `variation_embolden` (float, faux bold), `variation_opentype` (Dictionary), `set_spacing(SpacingType, int)`. New in 4.0.
- `SystemFont` — `font_names` (PackedStringArray), `font_weight`, `font_italic`. Loads OS-installed fonts. New in 4.0.

## Required setup
- Project-wide theme: **Project Settings → GUI → Theme → Custom** (`gui/theme/custom`) = a `.tres` Theme.
- Project-wide font without a full theme: `gui/theme/custom_font` = a Font resource.
- No autoload/flag needed; theming is core and **Control-only** (no 3D analogue — render Controls into a SubViewport for 3D UI).
- Fonts: drag .ttf/.otf/.woff into FileSystem to auto-import as `FontFile`; tune MSDF/mipmaps in the Import dock, then Reimport.

## Recipe — skin all Buttons in a subtree (cascades)
```
create_node type=Panel name=Root parent=.
set_resource target=Root property=theme class=Theme        # empty Theme on Root.theme; cascades
set_resource target=Box property=__ class=StyleBoxFlat     # or build it in write_script (see below)
call_method target=<sbflat> method=set_corner_radius_all args=[10]
set_property  target=<sbflat> property=bg_color value=Color(0.15,0.35,0.8,1)
call_method target=<sbflat> method=set_border_width_all args=[2]
call_method target=Root:theme method=set_stylebox args=["normal","Button",<sbflat>]
call_method target=Root:theme method=set_color    args=["font_color","Button",Color(1,1,1,1)]
# any Button added under Root now uses this style — no per-node overrides
```

## Recipe — override one Label locally
```
create_node type=Label name=Title parent=Root
set_property target=Title property=text value="Hello"
set_property target=Title property=theme_override_colors/font_color value=Color(1,0.85,0,1)
set_property target=Title property=theme_override_font_sizes/font_size value=32
set_property target=Title property=theme_override_constants/outline_size value=4
```

## Recipe — build styleboxes + fonts in one script
```
write_script path=res://style_setup.gd content="
@tool
extends Node
@export var theme: Theme
func _ready():
    var sb := StyleBoxFlat.new()
    sb.bg_color = Color(0.12,0.12,0.14)
    sb.set_corner_radius_all(8)
    sb.set_border_width_all(1)
    theme.set_stylebox('panel','PanelContainer', sb)
    var f := FontVariation.new()
    f.base_font = load('res://Inter.ttf')
    f.variation_embolden = 0.6
    theme.default_font = f
    theme.default_font_size = 16
"
attach_script target=Root path=res://style_setup.gd
play_scene        # then screenshot to verify
```

## Common traps
- **Overrides never cascade.** `add_theme_*_override` / `theme_override_*` affect only that node; only `Control.theme` cascades.
- `set_stylebox`'s param is named `texture` but its type is **StyleBox**, not Texture2D — pass a StyleBox.
- Items are keyed by **(name, theme_type)**. To skin every Button, use `theme_type="Button"`; `get_theme_color(name)` with empty theme_type uses the control's own class.
- A `theme_type_variation` needs a base type: `theme.set_type_variation("DangerBtn","Button")`, else inherited Button items won't resolve.
- `content_margin_*` default **-1** = auto (derived from borders), not zero — set explicit values for predictable padding.
- `draw_center=false` + borders = outline-only; pair with `StyleBoxEmpty` to fully drop a background while keeping padding.
- `default_font_size` (-1) and `default_base_scale` (0.0) defaults both mean *unset*, not literal sizing.
- Faux bold (`variation_embolden`) can render wrong with MSDF fonts or TextMesh.

Confirm exact item names, signatures, and enum values with `describe_class` before relying on them.
