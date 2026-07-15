# Input devices - gamepad, analog, rumble, touch, remapping persistence

> Beyond the `input` pack (actions/polling): joypad axes+deadzones, hotplug, rumble, touchscreen `InputEventScreen*`, saving rebinds, and synthetic input for AI/replay. Read `input` first for the action/`InputMap` basics.

## Version note
- Server runs **4.6.2**; Beckett supports the **4.2+** floor. The `Input` joypad/vibration methods, `InputEventScreenTouch`/`InputEventScreenDrag`, and the two emulation settings below are all **4.0+**, stable through 4.7.
- `InputEventScreenDrag.screen_relative` / `screen_velocity` (unscaled, resolution-independent - mirror the `InputEventMouseMotion` pair) were added in **4.3**; on 4.2 use `relative` / `velocity`.
- `InputEventScreenTouch.canceled` (touch aborted, e.g. gesture stolen by the OS) and `double_tap` exist in 4.x; `canceled` on drag/touch is worth checking to avoid stuck-finger state.
- **4.5**: desktop gamepads migrated to SDL3 (may change `get_joy_name` strings and remapping). Per-controller gyro is **4.7+** (see the `input` and `mobile` packs). Confirm with `get_godot_version` / `describe_class class=Input`.

## Analog movement + per-action deadzones
- `Input.get_vector(neg_x, pos_x, neg_y, pos_y, deadzone := -1.0) -> Vector2` - RADIAL deadzone, length-clamped to 1.0; `-1.0` averages the four actions' deadzones. Best for 8-dir/analog stick movement (no diagonal speed boost).
- `Input.get_axis(neg, pos) -> float` - single axis, PER-AXIS deadzone. `Input.get_action_strength(action) -> float` (0..1, deadzone applied) vs `get_action_raw_strength(action)` (no deadzone).
- Deadzone lives on the ACTION, not the event. Editor Input Map default is 0.5; `InputMap.add_action(name, deadzone := 0.2)` defaults 0.2 in code - set it explicitly: `InputMap.action_set_deadzone(action, 0.2)` / `action_get_deadzone(action) -> float`.
- Bind an analog axis to an action with `InputEventJoypadMotion.new()`: set `axis` (JoyAxis) and `axis_value` (sign picks the half: `-1.0` for left/up, `1.0` for right/down). One action per direction.

## Joypad enums (values are stable, SDL-style)
- **JoyButton** (for `InputEventJoypadButton.button_index` / `Input.is_joy_button_pressed`): `JOY_BUTTON_A=0`, `B=1`, `X=2`, `Y=3`, `BACK=4`, `GUIDE=5`, `START=6`, `LEFT_STICK=7`, `RIGHT_STICK=8`, `LEFT_SHOULDER=9`, `RIGHT_SHOULDER=10`, `DPAD_UP=11`, `DPAD_DOWN=12`, `DPAD_LEFT=13`, `DPAD_RIGHT=14`. Labels follow Xbox layout; the SAME index is a differently-printed button on PlayStation/Nintendo pads.
- **JoyAxis** (for `InputEventJoypadMotion.axis` / `Input.get_joy_axis`): `JOY_AXIS_LEFT_X=0`, `LEFT_Y=1`, `RIGHT_X=2`, `RIGHT_Y=3`, `TRIGGER_LEFT=4`, `TRIGGER_RIGHT=5`. Triggers report `0..1`; sticks report `-1..1` (Y is +down).

## Hotplug + device identity
- `Input.get_connected_joypads() -> Array[int]` (device ids of pads present NOW; may skip numbers), `Input.get_joy_name(device) -> String`, `Input.get_joy_guid(device) -> String` (stable per model - key remaps by guid), `Input.is_joy_known(device) -> bool` (has an SDL mapping; unknown pads report raw axes/buttons).
- Signal `Input.joy_connection_changed(device: int, connected: bool)` - fires on plug/unplug. Connect it to re-scan and re-assign player slots. `device` in every `InputEventJoypad*` and `get_joy_*` call is this id; `0` is the first pad, NOT "all".

## Rumble (force feedback)
- `Input.start_joy_vibration(device, weak_magnitude: float, strong_magnitude: float, duration := 0.0)` - magnitudes `0..1` (weak = high-freq motor, strong = low-freq); `duration` seconds, `0` = until stopped. `Input.stop_joy_vibration(device)`.
- `Input.get_joy_vibration_strength(device) -> Vector2` (x=weak, y=strong), `get_joy_vibration_duration(device) -> float`. Not all pads/platforms support rumble; the call is a safe no-op when unsupported. Always stop on hit-end or the motor runs forever.

## Touchscreen - InputEventScreenTouch / InputEventScreenDrag
- `InputEventScreenTouch`: `index: int` (finger id), `position: Vector2`, `pressed: bool`, `canceled: bool`, `double_tap: bool`. Arrives in `_input`/`_unhandled_input`.
- `InputEventScreenDrag`: `index: int`, `position`, `relative`, `velocity`, `screen_relative` (4.3+), `screen_velocity` (4.3+), `pressure`, `tilt`, `pen_inverted`.
- **Multitouch:** track by `index`. Keep a `Dictionary` of active fingers keyed by `index`; add on `pressed` touch, update on drag, ERASE on release AND on `canceled`. Never assume index 0 is the only finger.

## Emulation settings (pick the right one)
- `input_devices/pointing/emulate_touch_from_mouse` (bool) - synthesizes touch events from mouse clicks. Turn ON to test a touch-only game on desktop with a mouse.
- `input_devices/pointing/emulate_mouse_from_touch` (bool, default **true**) - synthesizes mouse events (and thus button-based UI clicks) from touches. Keep ON so `_gui_input`/Button presses work on mobile without touch-specific code; turn OFF only when raw multitouch must not also fire mouse events. Set via `set_project_setting` (read once at boot; not a runtime toggle for existing input).

## Action remapping persistence (ConfigFile)
- Rebind: `InputMap.action_erase_events(action)` **before** `action_add_event(action, event)` or bindings accumulate. Build events with `InputEventKey.new()` (store `physical_keycode` - layout-stable across AZERTY/Dvorak; `keycode` is layout-dependent) or `InputEventJoypadButton.new()` (`button_index`).
- Serialize to `user://` (writable in exports; `res://` is read-only there). `InputEvent` is not a plain Variant, so store its FIELDS, not the object: save `{"type":"key","physical_keycode": e.physical_keycode}` or `{"type":"pad","button_index": e.button_index}` via `ConfigFile.set_value(section, key, dict)`; on load reconstruct `.new()` and re-add. "Reset to defaults" = `InputMap.load_from_project_settings()` then re-save.

## Synthetic input (AI / replay / tests)
- `Input.action_press(action, strength := 1.0)` / `Input.action_release(action)` - flip a named action's polled state directly (great for scripted movement; `is_action_pressed` sees it next frame).
- `Input.parse_input_event(event)` - inject a fully-built `InputEvent` (key/joypad/screen) into the pipeline; drives `_input` callbacks and the action system. NOTE: games that poll raw hardware (`Input.get_joy_axis(device, ...)`) will NOT see parsed events - same caveat as synthetic mouse motion.
- Beckett's `simulate_input` (Full) injects `key` / `action` / `mouse_button` / `mouse_motion` today; joy/touch injection is a v1.7 target. Until then, drive synthetic pad/touch from a script via `parse_input_event`.

## Recipe - twin-stick analog move bound to a gamepad axis
```
call_method target=InputMap method=add_action args=["move_right", 0.2]   # + move_left/up/down (skip if already in Input Map)
create_node type=CharacterBody2D name=Player parent=.
write_script path=res://player.gd content="extends CharacterBody2D
func _ready() -> void:
    # bind right-stick X to move_right (positive half) once, in code
    var ev := InputEventJoypadMotion.new()
    ev.axis = JOY_AXIS_LEFT_X
    ev.axis_value = 1.0
    InputMap.action_add_event(\"move_right\", ev)
func _physics_process(_delta) -> void:
    var dir := Input.get_vector(\"move_left\", \"move_right\", \"move_up\", \"move_down\")   # radial deadzone
    velocity = dir * 300.0
    move_and_slide()"
attach_script target=Player path=res://player.gd
play_scene → wait_for_node path=Player → monitor_properties path=Player property=velocity → stop_scene
```

## Recipe - hotplug watcher + rumble on connect
```
write_script path=res://pads.gd content="extends Node
func _ready() -> void:
    Input.joy_connection_changed.connect(_on_pad)
    for d in Input.get_connected_joypads():
        _on_pad(d, true)
func _on_pad(device: int, connected: bool) -> void:
    if connected:
        print(device, ' -> ', Input.get_joy_name(device), ' (', Input.get_joy_guid(device), ')')
        Input.start_joy_vibration(device, 0.4, 0.7, 0.3)   # brief buzz to confirm"
# Register pads.gd as an autoload, then play_scene and check game_logs for the pad name.
```

## Common traps
- **Deadzone mismatch:** `get_vector` uses ONE radial deadzone; `get_axis`/`get_action_strength` use per-axis. Mixing them in the same controller feels inconsistent. `add_action` defaults 0.2 but the editor UI defaults 0.5 - set it with `action_set_deadzone`.
- **`device` is an id, not a count** - `0` is the first pad; a negative or wrong id silently does nothing. Ids can have gaps after unplugs; iterate `get_connected_joypads()`, don't assume 0..N.
- **Unknown pad = raw mapping** - `is_joy_known(device)` false means A/B/X/Y and axes may be swapped; offer a manual-remap screen and key by `get_joy_guid`.
- **Rumble never stops** if you forget `stop_joy_vibration` and pass `duration = 0`. Always pair start/stop or set a duration.
- **Multitouch by index** - do not treat touches as a single pointer; erase your finger dict entry on BOTH release and `canceled`, or a lifted finger stays "held".
- **Emulation direction confusion** - `emulate_touch_from_mouse` (test touch with a mouse) vs `emulate_mouse_from_touch` (make UI work under fingers, default on). Enabling both can double-fire; pick per platform.
- **Rebinds accumulate** - `action_erase_events` before `action_add_event`, every time. Runtime `InputMap` edits are NOT written to `project.godot`; persist them yourself to `user://`.
- **Store `physical_keycode`, display the glyph** - persist `physical_keycode` (layout-stable) but show `OS.get_keycode_string(...)` / `key_label` so the on-screen prompt matches the user's keyboard.
- **Synthetic input blind spot** - `parse_input_event`/`action_press` feed the action system and `_input`, not raw `get_joy_axis` polling; scripts that read hardware directly won't observe replayed pad axes.

Confirm exact class, property, and method names with `describe_class` (e.g. `class=Input`, `class=InputEventScreenTouch`, `class=InputEventJoypadMotion`) and `get_godot_version` before relying on them.
