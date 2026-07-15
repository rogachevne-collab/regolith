# Input handling — actions, events, polling

> Named actions in `InputMap`, polled via the `Input` singleton or read from `InputEvent` in `_unhandled_input`. Use physical keys for gameplay.

Godot input is two halves: **`InputMap`** stores named *actions* (each a list of bound `InputEvent`s + a deadzone); **`Input`** polls their state per frame, or events arrive in `_input`/`_unhandled_input`/`_gui_input`. Both are always-available engine singletons — no autoload needed.

## Version note
- `InputEventMouseMotion.screen_relative` / `screen_velocity` (unscaled, resolution-independent) and `Input.get_last_mouse_screen_velocity()` — **added 4.3**. Prefer `screen_relative` for mouse-look.
- `Input.is_action_just_pressed_by_event()` / `is_action_just_released_by_event()` — **added 4.4**.
- `InputEventMouseMotion.velocity` was Godot 3's `speed` — renamed in **4.0**.
- **4.5**: desktop gamepads migrated to SDL3. **4.6**: Control mouse/touch focus is tracked separately from keyboard/gamepad focus (clicking no longer shows the gamepad focus rectangle). Confirm with `get_godot_version` / `describe_class`.
- **4.7**: per-controller motion sensors for gyro aiming (`Input.get_joy_gyroscope/accelerometer/gravity(device)` + calibration), the `Input.ignore_joypad_on_unfocused_application` setting, consistent keyboard/mouse device IDs, and a built-in `VirtualJoystick` Control — all covered in the **mobile** skill.

## Required setup
- Define actions in **Project Settings > Input Map** (the canonical place; per-action deadzone there defaults to 0.5 for analog). Stored in `project.godot` `[input]` as `{ "deadzone": float, "events": [InputEvent…] }`.
- Built-in `ui_*` actions exist in every project (`ui_accept`, `ui_cancel`, `ui_left/right/up/down`, `ui_focus_next/prev`, `ui_page_up/down`, `ui_home/end`, `ui_cut/copy/paste/undo/redo`); enable "Show Built-in Actions" to see them. They can be remapped, not deleted.
- A custom action **must exist before query** — `Input.is_action_pressed("x")` on an unknown action pushes an error and returns false. Guard with `InputMap.has_action("x")`.

## InputMap (singleton) — methods
`add_action(action: StringName, deadzone: float = 0.2) -> void` (note: 0.2 here vs 0.5 in the editor UI), `erase_action(action)`, `has_action(action) -> bool`, `get_actions() -> Array[StringName]`, `action_add_event(action, event: InputEvent)`, `action_erase_event(action, event)`, `action_erase_events(action)`, `action_has_event(action, event) -> bool`, `action_get_events(action) -> Array[InputEvent]`, `action_set_deadzone(action, float)` / `action_get_deadzone(action) -> float`, `load_from_project_settings()`. Runtime changes are **not** saved to `project.godot`.

## Input (singleton) — polling
- `is_action_pressed(action, exact_match=false) -> bool` (held — movement), `is_action_just_pressed(action) -> bool` / `is_action_just_released(action) -> bool` (one frame).
- `get_axis(neg, pos) -> float` (per-axis deadzone), `get_vector(neg_x, pos_x, neg_y, pos_y, deadzone=-1.0) -> Vector2` (radial deadzone, length-clamped to 1; -1.0 = average of the 4 actions' deadzones — best for 8-dir/analog).
- `get_action_strength(action) -> float` (0..1, deadzone applied), `get_action_raw_strength(action) -> float` (no deadzone).
- `is_physical_key_pressed(keycode: Key) -> bool` (layout-INDEPENDENT — use for WASD), `is_key_pressed(keycode) -> bool` (layout-dependent — shortcuts).
- `set_mouse_mode(MouseMode)` / `get_mouse_mode()`, `warp_mouse(Vector2)`, `get_last_mouse_velocity() -> Vector2`, `get_last_mouse_screen_velocity() -> Vector2` (unscaled, 4.3+).
- Synthetic: `action_press(action, strength=1.0)`, `action_release(action)`, `parse_input_event(event)`. Joypad: `get_connected_joypads()`, `get_joy_axis(device, axis)`, `start_joy_vibration(device, weak, strong, duration=0)`.
- **No `Input.get_mouse_position()`** in Godot 4 — use `get_viewport().get_mouse_position()` or `get_global_mouse_position()` on a CanvasItem/Control.

## InputEvent subclasses (type-check before reading subclass props)
- `InputEvent` base: `is_action(action) -> bool`, `is_action_pressed(action, allow_echo=false) -> bool`, `is_action_released(action) -> bool`, `is_pressed()`, `is_echo()`.
- `InputEventKey`: `keycode` / `physical_keycode` / `key_label` (Key), `unicode` (int), `pressed`, `echo`, plus `shift_pressed`/`ctrl_pressed`/`alt_pressed`/`meta_pressed`.
- `InputEventMouseButton`: `button_index` (`MOUSE_BUTTON_LEFT=1`, `RIGHT=2`, `MIDDLE=3`, `WHEEL_UP=4`, `WHEEL_DOWN=5`), `pressed`, `double_click`, `position`.
- `InputEventMouseMotion`: `relative` (scaled), `screen_relative` (unscaled, 4.3+ — prefer for look), `velocity`, `position`.
- `InputEventJoypadButton`: `button_index` (`JOY_BUTTON_A=0…`); `InputEventJoypadMotion`: `axis` (`JOY_AXIS_LEFT_X=0…`), `axis_value` (-1..1).
- `InputEventAction`: synthetic action event; `action`, `pressed`, `strength`. Inject with `Input.parse_input_event()`.

`MouseMode`: `MOUSE_MODE_VISIBLE=0`, `HIDDEN=1`, `CAPTURED=2` (locked+hidden, gives relative deltas for FPS), `CONFINED=3`, `CONFINED_HIDDEN=4`.

## Driving input from the agent (`simulate_input` / `record_input` / `replay_input`)
`simulate_input` injects these event types into the running game: `key`, `action`, `mouse_button`, `mouse_motion`, `joy_button` (`{button, pressed, device}`, button = `JOY_BUTTON_*` index), `joy_axis` (`{axis, value, device}`, axis = `JOY_AXIS_*` index, value clamped -1..1), `touch` (`{index, position, pressed}`), `touch_drag` (`{index, position, relative}`). `record_input`/`replay_input` capture and replay the full set (gamepad and touch included), so a manual run round-trips.
**Caveat (same class as synthetic mouse):** injected events go through `Input.parse_input_event`, which drives the action system and `_input`/`_gui_input` callbacks. Games reading actions (`Input.get_vector`, `Input.is_action_pressed`, `_input` on `InputEventJoypad*`/`InputEventScreen*`) see them; raw-hardware polling (`Input.get_joy_axis(device, ...)`, `Input.get_connected_joypads()`) does NOT. Prefer `joy_axis` events + `get_vector`/`get_axis` over polling in code you playtest. Touch events arrive as `InputEventScreenTouch`/`Drag`; enable `input_devices/pointing/emulate_mouse_from_touch` if UI is mouse-only.

## Controller gyro & motion sensors (4.7+)
Per-controller sensors enable gyro aiming (separate from a phone's `Input.get_gyroscope()`). Enable with `Input.set_joy_motion_sensors_enabled(device, true)` and check `has_joy_motion_sensors(device)`, then read `get_joy_gyroscope(device) -> Vector3` (angular velocity, rad/s), `get_joy_accelerometer(device)`, `get_joy_gravity(device)`. Calibrate via `start_joy_motion_sensors_calibration()` / `stop_joy_motion_sensors_calibration()` (`is_joy_motion_sensors_calibrated(device)`). `Input.ignore_joypad_on_unfocused_application` (bool, default on) blocks pad input when the window is unfocused. See the **mobile** skill for touch + `VirtualJoystick`.

## Recipe — top-down movement (analog + WASD)
```
call_method target=InputMap method=add_action args=["move_left", 0.2]   # repeat for move_right/up/down (skip if already in Input Map)
create_node type=CharacterBody2D name=Player parent=.
```
attach a script (`write_script` validates first):
```gdscript
extends CharacterBody2D
func _physics_process(delta):
	var dir := Input.get_vector("move_left","move_right","move_up","move_down")
	velocity = dir * 300.0
	move_and_slide()
```
Then `play_scene`, `simulate_input` action `move_right`, `monitor_properties path=Player property=velocity`, `assert_node_state` velocity.x > 0, `stop_scene`.

## Recipe — reliable jump (one-shot, won't drop at low FPS)
Use the event path, not polling:
```gdscript
func _unhandled_input(event):
	if event.is_action_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
		get_viewport().set_input_as_handled()   # consume it
```

## Common traps
- `is_action_just_pressed()` returns the **same value for every call within one frame**, and differs between `_process` and `_physics_process` (each compares to its own tick). At low/variable FPS a press+release inside one frame is **dropped** — for reliable one-shots use `_unhandled_input` + `event.is_action_pressed(...)`.
- Bind **`physical_keycode`** (not `keycode`) for movement so AZERTY/Dvorak users get the same physical keys. `keycode` is for shortcuts where the printed letter matters (Ctrl+S).
- Always type-check: `if event is InputEventMouseButton:` before reading `.button_index`; reading `.relative` on a key event errors.
- Propagation order: `_input` → `Control._gui_input` → `_shortcut_input` → `_unhandled_key_input` → `_unhandled_input`. UI consumes before `_unhandled_input` — that's why gameplay belongs there. Consume with `get_viewport().set_input_as_handled()` (in `_input`/`_unhandled_input`) or `accept_event()` (in `_gui_input`).
- `get_vector` uses a single **radial** deadzone; `get_axis`/`get_action_strength` use **per-axis** — mixing them can feel inconsistent. `add_action` defaults deadzone 0.2 but the editor UI defaults 0.5; set it explicitly with `action_set_deadzone`.
- `exact_match=true` requires the modifier set to match exactly (plain "A" won't match if Shift is down); default false ignores extra modifiers.
- In captured mode prefer `screen_relative` over `relative` for look — `relative` is scaled by the stretch/content-scale factor, so sensitivity drifts with resolution.

Confirm exact class, property, and method names with `describe_class` (e.g. `describe_class class=Input`, `class=InputEventMouseMotion`) before relying on them.
