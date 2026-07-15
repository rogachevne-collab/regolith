# Settings / options menu — video, audio, input remapping, persistence

> Options UI drives RUNTIME singletons, NOT ProjectSettings: DisplayServer (window/vsync), Window (content scale), AudioServer (volume), InputMap (rebinding). Persist with ConfigFile to `user://`.

## The #1 rule
**Most ProjectSettings are read once at boot** — `ProjectSettings.set_setting()` has no runtime effect. Apply every option through the matching runtime singleton. Use `ProjectSettings.get_setting(name, default)` only to read launch DEFAULTS.

## Version note
- Server runs **4.6.2** (baseline 4.3+). Confirm with `get_godot_version` / `describe_class`.
- **`AudioServer.set_bus_volume_linear(idx, v)` / `get_bus_volume_linear(idx)`: added 4.4** (absent in 4.3). On 4.3 use `set_bus_volume_db(idx, linear_to_db(v))` and `db_to_linear(get_bus_volume_db(idx))`.
- **`BaseButton.toggled` signal param renamed `button_pressed` → `toggled_on` in 4.2** (positional, so connections still work).
- DisplayServer/Window/AudioServer/InputMap/ConfigFile members below are all **4.0+**, stable through 4.6. 2D vs 3D is irrelevant for these singletons; the only fork is `Window.content_scale_mode` (see below).

## Required setup
- **Audio buses:** open the Audio bottom panel; "Master" (index 0) exists by default — add "Music"/"SFX" and route each `AudioStreamPlayer.bus` to one. `AudioServer.get_bus_index(name)` returns **-1** for an unknown bus; guard it.
- **Input actions:** define gameplay actions (e.g. `jump`) in Project Settings > Input Map so they exist at boot; runtime rebinding edits these (or `InputMap.add_action(name, deadzone)`).
- **Autoload:** register the settings script (Project Settings > Autoload, e.g. name `Settings`, path `res://settings.gd`) so its `_ready` applies saved options **before the first gameplay frame** — set via ProjectSettings key `autoload/Settings` = `*res://settings.gd`.
- Persist to `user://` (always writable, in editor and exports). **Never `res://`** (read-only when exported). No import flags needed.

## DisplayServer (singleton — call `DisplayServer.method()`)
- `window_set_mode(mode: WindowMode, window_id := 0)` / `window_get_mode(window_id := 0) -> WindowMode`
- `window_set_vsync_mode(vsync_mode: VSyncMode, window_id := 0)` / `window_get_vsync_mode(window_id := 0)`
- `window_set_size(size: Vector2i, window_id := 0)` (only takes effect in WINDOWED) / `window_get_size`
- `window_set_position(position: Vector2i, window_id := 0)`, `screen_get_size(screen := -1) -> Vector2i`, `get_screen_count() -> int`
- **WindowMode:** `WINDOW_MODE_WINDOWED=0`, `MINIMIZED=1`, `MAXIMIZED=2`, `FULLSCREEN=3` (borderless windowed-fullscreen, smooth alt-tab — safe default), `EXCLUSIVE_FULLSCREEN=4` (Windows-only true exclusive; equals FULLSCREEN elsewhere).
- **VSyncMode:** `VSYNC_DISABLED=0`, `ENABLED=1` (default), `ADAPTIVE=2`, `MAILBOX=3` (low-latency, unlimited fps; falls back to ENABLED if unsupported).

## Window (the main window — `get_window()` at runtime; `Window.mode` mirrors DisplayServer)
- `content_scale_factor: float = 1.0` — UI scale multiplier (set 1.25/1.5/2.0 for a UI-scale option).
- `content_scale_mode: ContentScaleMode` — `CONTENT_SCALE_MODE_DISABLED=0`, `CANVAS_ITEMS=1` (crisp 2D/UI — typical), `VIEWPORT=2` (fixed internal res; pixel-art / a "render resolution" option).
- `content_scale_aspect: ContentScaleAspect` — `IGNORE=0`, `KEEP=1`, `KEEP_WIDTH=2`, `KEEP_HEIGHT=3`, `EXPAND=4`. Also `content_scale_size: Vector2i`.
- Signal `size_changed` — **inherited from Viewport** (Window extends Viewport); valid via `get_window().size_changed`. For true 3D render-scale use `Viewport.scaling_3d_scale` (separate API).

## AudioServer (singleton). Sliders are linear 0..1; convert with `linear_to_db` / `db_to_linear` (@GlobalScope)
- `get_bus_index(bus_name: StringName) -> int`, `set_bus_volume_db(idx: int, db: float)`, `get_bus_volume_db(idx) -> float`, `set_bus_mute(idx, enable: bool)`, `is_bus_mute(idx) -> bool`. (4.4+: `set_bus_volume_linear`/`get_bus_volume_linear`.)
- `linear_to_db(0.0)` is `-inf` dB (silent) — the desired "off" for a slider min of 0. Mute is independent of volume; persist both.

## InputMap (singleton — runtime key/pad rebinding)
- `action_get_events(action: StringName) -> Array[InputEvent]`, `action_erase_events(action)`, `action_add_event(action, event: InputEvent)`, `has_action(action) -> bool`, `add_action(action, deadzone := 0.2)`, `load_from_project_settings()` (restore editor defaults — use for a "Reset to defaults" button).
- Build events with `InputEventKey.new()` (set `physical_keycode: Key` — stable across keyboard layouts, store this for gameplay; `keycode` is layout-dependent; `key_label` is the localized glyph for display) or `InputEventJoypadButton.new()` (`button_index: JoyButton` — `JOY_BUTTON_A=0`,`B=1`,`X=2`,`Y=3`,…).
- Display a key via `OS.get_keycode_string(event.physical_keycode)`, or `DisplayServer.keyboard_get_keycode_from_physical(code)` then `OS.get_keycode_string()` for the layout-correct glyph.

## Persistence + silent setters
- **ConfigFile** (`ConfigFile.new()`): `load(path) -> Error` (non-OK on first run — branch to defaults), `save(path) -> Error`, `set_value(section, key, value)`, `get_value(section, key, default)` — **always pass a default**. Stores most Variants natively (store a resolution as `Vector2i`).
- Restoring saved values must NOT re-fire apply/save: `Range/HSlider.set_value_no_signal(v)` (slider `value_changed(value)` fires every frame while dragging), `OptionButton.select(idx)` (`item_selected(index)` fires on user change; programmatic `select()` does not emit it — add items with `add_item(label, id)` + read `get_selected_id()`), `BaseButton.set_pressed_no_signal(p)` (`toggled(toggled_on)`).

## Recipe — Settings autoload: persist to user://settings.cfg + apply on boot
```
write_script path=res://settings.gd content="extends Node
const PATH := \"user://settings.cfg\"
var cfg := ConfigFile.new()
func _ready() -> void:
    cfg.load(PATH)            # non-OK on first run is fine; defaults below cover it
    apply_all()
func store(section, key, value) -> void:
    cfg.set_value(section, key, value); cfg.save(PATH)
func fetch(section, key, default): return cfg.get_value(section, key, default)
func apply_all() -> void:
    DisplayServer.window_set_mode(fetch(\"video\", \"mode\", DisplayServer.WINDOW_MODE_WINDOWED))
    DisplayServer.window_set_vsync_mode(fetch(\"video\", \"vsync\", DisplayServer.VSYNC_ENABLED))
    get_window().content_scale_factor = fetch(\"video\", \"ui_scale\", 1.0)
    for bus in [\"Master\", \"Music\", \"SFX\"]:
        var idx := AudioServer.get_bus_index(bus)
        if idx != -1:
            AudioServer.set_bus_volume_db(idx, linear_to_db(fetch(\"audio\", bus, 1.0)))
"
# Register as Autoload 'Settings' via ProjectSettings key autoload/Settings = *res://settings.gd
```

## Recipe — live Master volume slider wired to AudioServer
```
create_node type=HSlider name=MasterVolume parent=OptionsMenu/VBox
set_property target=OptionsMenu/VBox/MasterVolume property=min_value value=0.0
set_property target=OptionsMenu/VBox/MasterVolume property=max_value value=1.0
set_property target=OptionsMenu/VBox/MasterVolume property=step value=0.001
write_script path=res://ui/volume_slider.gd content="extends HSlider
@export var bus_name: StringName = \"Master\"
var _idx: int
func _ready() -> void:
    _idx = AudioServer.get_bus_index(bus_name)
    set_value_no_signal(db_to_linear(AudioServer.get_bus_volume_db(_idx)))  # no apply loop
    value_changed.connect(_on_changed)
func _on_changed(v: float) -> void:
    AudioServer.set_bus_volume_db(_idx, linear_to_db(v))
    Settings.store(\"audio\", bus_name, v)
"
attach_script target=OptionsMenu/VBox/MasterVolume path=res://ui/volume_slider.gd
play_scene → simulate_input (drag) → monitor_properties path=OptionsMenu/VBox/MasterVolume property=value
```

## Recipe — window-mode dropdown calling DisplayServer at runtime
```
create_node type=OptionButton name=WindowMode parent=OptionsMenu/VBox
call_method target=OptionsMenu/VBox/WindowMode method=add_item args=["Windowed", 0]      # id = WINDOW_MODE_WINDOWED
call_method target=OptionsMenu/VBox/WindowMode method=add_item args=["Fullscreen", 3]     # id = WINDOW_MODE_FULLSCREEN
call_method target=OptionsMenu/VBox/WindowMode method=add_item args=["Exclusive", 4]
write_script path=res://ui/window_mode.gd content="extends OptionButton
func _ready() -> void:
    var m := DisplayServer.window_get_mode()
    for i in get_item_count():
        if get_item_id(i) == m: select(i)        # select() does not emit item_selected
    item_selected.connect(func(_i): _apply())
func _apply() -> void:
    var mode := get_selected_id()
    DisplayServer.window_set_mode(mode); Settings.store(\"video\", \"mode\", mode)
"
attach_script target=OptionsMenu/VBox/WindowMode path=res://ui/window_mode.gd
play_scene → click_button_by_text "Fullscreen" → assert_node_state (window_get_mode()==3) → screenshot
```

## Common traps
- **ProjectSettings.set_setting() does nothing at runtime** for display/audio/etc. — apply via the singleton. Apply in an autoload's `_ready` AFTER `cfg.load`, or the game launches with project defaults.
- **Feedback loop:** setting a control in code fires its signal → re-apply → re-save. On load use `set_value_no_signal` / silent `select()` / `set_pressed_no_signal`.
- `window_set_size` only shows in WINDOWED — set windowed mode first, then size, then center via `window_set_position` with `screen_get_size()`.
- **Always pass `get_value(..., default)`** — a missing key returns null and `db_to_linear(null)` errors. First-run `load()` returns non-OK; branch to defaults, don't treat as fatal.
- `get_bus_index` returns **-1** for a missing bus (forgot to create "Music"/"SFX") — guard before using the index.
- Audio: keep sliders linear 0..1 mapped via `linear_to_db`; do NOT store dB tied to a 0..1 slider. On 4.4+ `set_bus_volume_linear` skips the conversion; on 4.3 it doesn't exist.
- Rebinding: call `action_erase_events(action)` **before** `action_add_event` or bindings accumulate. Store `physical_keycode` (layout-stable) but DISPLAY via `key_label` / `keyboard_get_keycode_from_physical`. "Reset" = `load_from_project_settings()` then re-save.
- VSYNC_MAILBOX / EXCLUSIVE_FULLSCREEN can silently fall back — read back `window_get_vsync_mode`/`window_get_mode` if you reflect the true state; cap fps with `Engine.max_fps`.
- HSlider `value_changed` fires every frame while dragging (good for live preview) — debounce the cfg save (on `focus_exited` or an Apply button), don't write every frame.

Confirm exact class, property, and method names with `describe_class` / `find_methods` (and `get_godot_version`) before relying on them — APIs shift between Godot versions.
