# UI — Control nodes, anchors, containers, theme

> Build responsive UI with Control nodes. Prefer containers over manual anchoring. Never set position/anchors on a container's child.

## Version note
- Server runs **4.6.2** (baseline 4.3+, recommend 4.4+). Check `get_godot_version` / `describe_class`.
- Godot 3→4: `ViewportContainer`→`SubViewportContainer`, `Viewport`→`SubViewport`; `Control.rect_*` props dropped the `rect_` prefix (`rect_size`→`size`, `rect_position`→`position`, `rect_min_size`→`custom_minimum_size`).
- `FlowContainer`/`HFlowContainer`/`VFlowContainer`, `AspectRatioContainer`, `SubViewportContainer`, `theme_type_variation` — all **4.0+**.
- `TabContainer.get_tab_bar()` — **4.3+**.
- `SplitContainer.dragging_enabled` and `drag_started`/`drag_ended` signals — **4.4+** (the 4.4 multi-child rework also **deprecated `split_offset`**; prefer the dragger API). Gate for 4.3.
- `FoldableContainer` + `FoldableGroup` — **NEW in 4.5** (absent on 4.3/4.4).
- `Control.mouse_behavior_recursive`, `Control.focus_behavior_recursive`, and `FocusMode.FOCUS_ACCESSIBILITY` (=3, AccessKit screen-reader) — **4.5+ only**. On 4.3/4.4 fall back to per-node `mouse_filter=MOUSE_FILTER_IGNORE` and `focus_mode=FOCUS_NONE`.
- **4.7+**: `Control` **offset transforms** (`offset_transform_enabled` + `offset_transform_position`/`_rotation`/`_scale`/`_pivot`, the `_ratio` variants, `offset_transform_visual_only`) move/rotate/scale a Control **without the parent container resetting it** — see the container-child rule below. Also `PopupMenu.search_bar_enabled` (+ `search_bar_fuzzy_search_enabled`/`_max_misses`, `search_bar_min_item_count`) to filter long menus, `Control.custom_maximum_size`/`propagate_maximum_size`, `Control.translation_context`, and font-relative `[img]` sizing in `RichTextLabel` bbcode. Guard with `get_godot_version`.

## Core controls
`Label` (`text`, `horizontal_alignment`), `Button` (`text`, `disabled`), `LineEdit` (`text`, `placeholder_text`), `TextureRect` (`texture`, `expand_mode`, `stretch_mode`), `ProgressBar` (`value`, `min_value`, `max_value`), `RichTextLabel` (`bbcode_enabled`, `text`), `Panel`, `ColorRect` (`color`), `CheckBox`, `OptionButton`.

## Layout — two ways
1. **Containers (recommended)** — children auto-arrange; you don't set positions.
   - `VBoxContainer` / `HBoxContainer` (stack; `separation` constant), `GridContainer` (`columns`; `h_separation`/`v_separation`), `MarginContainer` (margins, see below), `CenterContainer`, `PanelContainer`, `ScrollContainer`, `AspectRatioContainer`.
   - `FlowContainer`/`HFlowContainer`/`VFlowContainer` (4.0) — wrap children to the next line: `alignment` (ALIGNMENT_BEGIN=0/CENTER=1/END=2), `last_wrap_alignment`, `vertical` (bool), `reverse_fill` (bool); `h_separation`/`v_separation`.
   - `SplitContainer`/`HSplitContainer`/`VSplitContainer` — user-draggable divider: `collapsed` (bool), `dragger_visibility` (DRAGGER_VISIBLE=0/VISIBLE_DISABLED=1/HIDDEN=2), `dragging_enabled` [4.4]; signals `dragged(offset)`, `drag_started()` [4.4], `drag_ended()` [4.4]. (`split_offset` deprecated in 4.4+.)
   - `TabContainer` — `current_tab`, `tabs_visible`, `get_tab_bar()` [4.3], `set_tab_title(i,s)`/`set_tab_icon(i,tex)`/`set_tab_disabled(i,b)`; signals `tab_changed(tab)`, `tab_selected(tab)`, `tab_clicked(tab)`.
   - `FoldableContainer` [4.5] + `FoldableGroup` — clickable-title accordion for settings/inspector UIs: `folded` (bool), `title` (String), `title_alignment` (HorizontalAlignment); `fold()`/`expand()`, `set_foldable_group(grp)`/`get_foldable_group()`, `add_title_bar_control(ctrl)`; signal `folding_changed(is_folded)`. Group so only one opens at a time.
   - Configure each child via `size_flags_horizontal`/`size_flags_vertical`, `size_flags_stretch_ratio` (default 1.0; weights EXPAND siblings), and `custom_minimum_size` (`"120 40"`).
2. **Anchors (manual)** — for free-floating HUD overlays only. Set a preset via `call_method target=<ctrl> method=set_anchors_preset args=[15]` (15 = PRESET_FULL_RECT) or anchors+offsets in one call (below). Common presets: 0 top-left, 8 center, 15 full rect, 12 bottom-wide. Note: `anchors_preset` reads -1 (Custom) once offsets are hand-edited.

### set_anchors_and_offsets_preset
`set_anchors_and_offsets_preset(preset, resize_mode := PRESET_MODE_MINSIZE, margin := 0)` sets anchors AND zeroes/positions offsets in one shot. `LayoutPresetMode`: PRESET_MODE_MINSIZE=0, KEEP_WIDTH=1, KEEP_HEIGHT=2, KEEP_SIZE=3.

## Key enums (verify with describe_class)
- `SizeFlags` (BitField): `SIZE_SHRINK_BEGIN=1`, `SIZE_FILL=2`, `SIZE_EXPAND=4`, **`SIZE_EXPAND_FILL=6`** (= FILL|EXPAND), `SIZE_SHRINK_CENTER=8`, `SIZE_SHRINK_END=16`. (Older docs/code may say 3 for EXPAND_FILL — wrong; it is 6.)
- `MouseFilter`: `MOUSE_FILTER_STOP=0` (default), `PASS=1`, `IGNORE=2` — IGNORE makes a node click-through for HUDs.
- `FocusMode`: `FOCUS_NONE=0`, `FOCUS_CLICK=1`, `FOCUS_ALL=2`, `FOCUS_ACCESSIBILITY=3` [4.5].
- Recursive subtree control [4.5]: `mouse_behavior_recursive` (INHERITED=0/DISABLED=1/ENABLED=2), `focus_behavior_recursive` (INHERITED=0/DISABLED=1/ENABLED=2) — disable mouse/focus for a whole subtree at once.

## Theme
- A `Theme` resource on a Control cascades to children. `set_resource target=UI property=theme resource=res://ui.tres`.
- `Control.theme_type_variation` (StringName, 4.0) — borrow a named variant from the assigned Theme (e.g. a "HeaderButton" Button variant) without per-node overrides. Cleaner than overrides for repeated styling.
- **Per-node overrides — two equivalent access styles:**
  - Inspector/scene paths via `set_property`/`set_resource`: `theme_override_colors/font_color`, `theme_override_font_sizes/font_size`, `theme_override_constants/<name>`, `theme_override_styles/panel` (a `StyleBox`).
  - Runtime methods via `call_method`: `add_theme_color_override(name, Color)`, `add_theme_font_size_override(name, int)`, `add_theme_font_override(name, Font)`, `add_theme_constant_override(name, int)`, `add_theme_icon_override(name, Texture2D)`, `add_theme_stylebox_override(name, StyleBox)`. Also `remove_theme_color_override(name)`, `has_theme_color_override(name)`. Batch many with `begin_bulk_theme_override()` … `end_bulk_theme_override()`.
- **MarginContainer** uses theme **constants** (not direct props): `margin_left`/`margin_top`/`margin_right`/`margin_bottom` (default 0) — set with `add_theme_constant_override("margin_left", N)` or path `theme_override_constants/margin_left`. BoxContainers use the `separation` constant; Grid/Flow use `h_separation`/`v_separation`.

## Critical container-children rule
Do **NOT** set `position`, `anchors_*`, or `offset_*` on a Control that is a **direct child of a Container** — the container overwrites them every layout pass. Control such children only via `size_flags_horizontal`/`vertical`, `size_flags_stretch_ratio`, and `custom_minimum_size`. (Anchors/offsets apply only to Controls NOT parented to a container.)

**(4.7+) Offset transforms — the sanctioned escape hatch.** To nudge/rotate/scale/pulse a Control that *is* a container child without the layout fighting you, set `offset_transform_enabled=true`, then `offset_transform_position` / `offset_transform_rotation` / `offset_transform_scale` (or the `_ratio` variants, relative to the node's rect; `offset_transform_pivot`/`_pivot_ratio` sets the pivot). `offset_transform_visual_only=true` keeps layout + hit-testing at the original rect (pure visual juice). This is now the right way to animate Controls inside containers (hover-pop a grid button, shake an inventory slot) — `describe_class class=Control` to confirm exact types.

## Recipe — a centered menu
```
create_node type=CenterContainer name=UI
call_method target=UI method=set_anchors_preset args=[15]      # fill the screen
create_node type=VBoxContainer name=Menu parent=UI
create_node type=Button name=Play parent=UI/Menu
set_property target=UI/Menu/Play property=text value="Play"
create_node type=Button name=Quit parent=UI/Menu
set_property target=UI/Menu/Quit property=text value="Quit"
```
CenterContainer centers its child at the child's **minimum size** and ignores child `SIZE_EXPAND` flags — exactly right for a compact centered menu. For full-width buttons instead, drop the CenterContainer and give the VBox `size_flags_horizontal=SIZE_FILL` under a full-rect parent.

## Recipe — scrollable list
```
create_node type=ScrollContainer name=Scroll parent=UI
create_node type=VBoxContainer name=List parent=UI/Scroll
set_property target=UI/Scroll/List property=size_flags_horizontal value=2   # SIZE_FILL, fill width
# add many children to List; ScrollContainer wraps a SINGLE child
```
`horizontal_scroll_mode`/`vertical_scroll_mode`: SCROLL_MODE_DISABLED=0, AUTO=1 (default), SHOW_ALWAYS=2, SHOW_NEVER=3, RESERVE=4. Also `follow_focus` (bool), `ensure_control_visible(ctrl)`, `get_v_scroll_bar()`/`get_h_scroll_bar()`.

## Recipe — embed a 3D scene inside UI
```
create_node type=SubViewportContainer name=View3D parent=UI
set_property target=UI/View3D property=stretch value=true        # resize SubViewport to container
create_node type=SubViewport name=SV parent=UI/View3D
create_node type=Camera3D name=Cam parent=UI/View3D/SV
# parent your 3D content under SV; set Camera3D.current=true
```
`stretch_shrink` (int) divides render resolution while keeping on-screen size — cheap downscale. (2D-vs-3D: this is the only canonical bridge for putting Node3D content inside Control UI.)

## Verify at runtime
`play_scene` → `find_ui_elements` / `get_remote_tree` / `screenshot` to confirm layout; `click_button_by_text text="Play"` to exercise it; `wait_for_node` / `monitor_properties` / `assert_node_state` to check state. `simulate_input` for keyboard/focus navigation.

## Common traps
- Setting `position`/`anchors`/`offsets` on a container child does nothing — the parent container resets them. Use size flags + `custom_minimum_size`.
- `SIZE_EXPAND_FILL` is **6**, not 3. A node only stretches if it has `SIZE_EXPAND`; `SIZE_FILL` alone just fills its allotted cell.
- CenterContainer/AspectRatioContainer ignore child EXPAND flags (they size to min/ratio). Use VBox/HBox + EXPAND for proportional stretch.
- MarginContainer margins are theme **constants**, not properties — direct `set_property target=MC property=margin_left` fails; use `add_theme_constant_override`/`theme_override_constants/margin_left`.
- Click-through HUD: set `mouse_filter=MOUSE_FILTER_IGNORE` on overlay Controls (or [4.5] `mouse_behavior_recursive=DISABLED` on the root) so input reaches the game.
- `FoldableContainer`, recursive mouse/focus props, and `FOCUS_ACCESSIBILITY` are **4.5+** — guard with `get_godot_version` before emitting them for older targets.
- `SplitContainer.split_offset` is deprecated (4.4+) — read/move dividers via the dragger API; `dragging_enabled`/`drag_started`/`drag_ended` are 4.4+.
- ScrollContainer/SubViewportContainer host a **single** child — wrap multiple items in a VBox first.
- Theme cascades to ALL descendants; a per-node `theme_override_*` or `theme_type_variation` beats the inherited Theme.

Confirm exact class, property, method, signal, and enum names with `describe_class` (and `get_godot_version`) before relying on them — APIs shift between Godot versions.
