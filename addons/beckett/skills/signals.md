# Signals — wire nodes together (editor-persisted)

> Connect built-in and custom signals to handler methods, saved into the `.tscn`. The MCP `connect_signal` uses `CONNECT_PERSIST` so the wiring survives in the scene file, not just as a runtime-only connection.

`connect_signal from=<emitter> signal=<name> to=<receiver> method=<handler>` resolves both nodes in the open scene, connects with `Object.CONNECT_PERSIST`, and is **undoable** (EditorUndoRedoManager). It is **idempotent** (re-running returns "already connected"). If the signal name is unknown it errors and suggests `list_signals`; if the receiver lacks the method it still connects but warns — add the method with `write_script` + `attach_script`. `list_signals target=<node>` returns each signal + its current connections (to/method). `disconnect_signal from/signal/to/method` reverses it (also undoable). Params are `from/signal/to/method` — NOT `source=`.

Handler convention: `_on_<emitter>_<signal>`, e.g. `_on_start_button_pressed`, `_on_timer_timeout`.

## Version note
- Server runs **4.6.2** (baseline 4.3+). Confirm with `get_godot_version` / `describe_class class=Object`.
- **Callable-based API since 4.0**: `node.signal_name.connect(_handler)` and `signal_name.emit(args)`. The Godot 3 string forms `connect("sig", obj, "method")` / `emit_signal("sig", ...)` are replaced — `emit_signal(name, ...)` and `connect(name, callable)` still exist as `Object` methods but the dot-syntax is idiomatic.
- `await some_signal` (4.0) replaced Godot 3 `yield(obj, "sig")`.
- **ConnectFlags** (`Object`): `CONNECT_DEFERRED=1`, `CONNECT_PERSIST=2`, `CONNECT_ONE_SHOT=4`, `CONNECT_REFERENCE_COUNTED=8`. `CONNECT_APPEND_SOURCE_OBJECT=16` is a newer addition (appends the emitter as a trailing arg) — confirm availability/value with `describe_class class=Object` on your runtime before relying on it.

## Object signal API (verified via describe_class)
- `connect(signal: StringName, callable: Callable, flags: int = 0) -> Error` — flags are OR-combined ConnectFlags above.
- `disconnect(signal: StringName, callable: Callable) -> void`, `is_connected(signal, callable) -> bool`, `has_signal(signal) -> bool`.
- `emit_signal(signal: StringName, ...) -> Error` (vararg). Per-instance signals: `add_user_signal(signal: String, arguments: Array = [])`, `has_user_signal(signal) -> bool`, `remove_user_signal(signal)`.
- `get_signal_list()`, `get_signal_connection_list(signal)`, `get_incoming_connections()` for introspection (what `list_signals` wraps).

## Common built-in signals (confirm with list_signals / describe_class)
- **BaseButton (Button/CheckBox/CheckButton/TextureButton/OptionButton):** `pressed`, `toggled(toggled_on: bool)`, `button_down`, `button_up`. `OptionButton.item_selected(index: int)`, `ItemList.item_selected(index: int)`.
- **LineEdit:** `text_submitted(new_text: String)`, `text_changed(new_text: String)`. **TextEdit:** `text_changed`.
- **Range (Slider/ProgressBar/SpinBox):** `value_changed(value: float)`.
- **Timer:** `timeout`.
- **Area2D / Area3D:** `body_entered(body)`, `body_exited(body)`, `area_entered(area)`, `area_exited(area)`.
- **RigidBody2D / RigidBody3D:** `body_entered(body)` — requires `contact_monitor=true` AND `max_contacts_reported>0`.
- **AnimationPlayer:** `animation_finished(anim_name: StringName)`, `animation_changed`. **AnimatedSprite2D/3D:** `animation_finished`, `frame_changed`.
- **VisibleOnScreenNotifier2D/3D:** `screen_entered`, `screen_exited`.
- **Node:** `ready`, `tree_entered`, `tree_exiting`, `renamed`, `child_entered_tree(node)`. **Node3D:** `visibility_changed`. **CanvasItem (2D):** `visibility_changed`, `draw`.

## Custom signals
Declare in the emitter script with typed args: `signal health_changed(amount: int)`; emit `health_changed.emit(amount)`. After the script is attached and the node exists, `connect_signal from=<emitter> signal=health_changed to=<ui> method=_on_health_changed`. (For a signal defined entirely at runtime without a script field, `add_user_signal` exists, but a `signal` declaration is preferred.)

## Recipe — wire a button to a scene change (persisted into .tscn)
```
create_node type=Button name=StartBtn parent=UI
set_property target=UI/StartBtn property=text value="Start"
write_script path=res://menu.gd content="extends Control
func _on_start_btn_pressed() -> void:
	get_tree().change_scene_to_file(\"res://game.tscn\")
"
attach_script target=UI path=res://menu.gd
connect_signal from=UI/StartBtn signal=pressed to=UI method=_on_start_btn_pressed
list_signals target=UI/StartBtn      # expect pressed -> UI._on_start_btn_pressed
play_scene
click_button_by_text text="Start"     # or simulate_input to fire it
```

## Recipe — custom signal: enemy death updates a score label
```
write_script path=res://enemy.gd content="extends Node2D
signal died(points: int)
func kill() -> void:
	died.emit(10)
	queue_free()
"
attach_script target=/root/Main/Enemy path=res://enemy.gd
write_script path=res://hud.gd content="extends CanvasLayer
var score := 0
func _on_enemy_died(points: int) -> void:
	score += points
	$ScoreLabel.text = str(score)
"
attach_script target=/root/Main/HUD path=res://hud.gd
connect_signal from=/root/Main/Enemy signal=died to=/root/Main/HUD method=_on_enemy_died
play_scene
call_method target=/root/Main/Enemy method=kill args=[]
assert_node_state target=/root/Main/HUD/ScoreLabel property=text equals="10"
```

## Connecting in code (when not persisting)
```gdscript
timer.timeout.connect(_on_timeout)                          # idiomatic 4.x
button.pressed.connect(_on_pressed.bind("extra"))           # bind() appends args (Callable)
sig.connect(_handler, CONNECT_ONE_SHOT | CONNECT_DEFERRED)  # OR-combine flags
var result = await some_node.some_signal                     # suspend until it fires
```
`Callable.bind(a)` appends trailing args to the handler; `Callable.unbind(n)` drops the last `n` emitted args (use when the handler signature is narrower than the signal).

## Common traps
- **Wrong tool params.** It is `from=`/`to=` (and `signal=`/`method=`), not `source=`/`target=`. `list_signals`/`disconnect_signal` only take `target=` / `from/signal/to/method` respectively.
- **Method must match the signal's arg count** (or use `unbind`). A `pressed` handler takes 0 args; `toggled` takes 1 (`bool`). Mismatched arity errors at emit time.
- **Order of operations:** the emitter node must exist before `connect_signal`; the receiver's method need not exist yet (you'll get a warning) but must exist before the signal fires. Attach the script first when the signal is custom.
- **Re-running is safe** (idempotent), but connecting the SAME callable twice in code fires the handler twice unless you pass `CONNECT_REFERENCE_COUNTED` or guard with `is_connected`.
- **Physics/area signals during a physics callback** can't mutate the tree directly ("Can't change this state while flushing queries") — connect with `CONNECT_DEFERRED` (1) or use `call_deferred`. Entered/exited signals are also unreliable on the first frame in-tree — wait one physics frame or poll `get_overlapping_bodies()`.
- **`await some_signal` never resumes** if the signal is never emitted (or the emitter frees first) — the coroutine just hangs. Prefer `CONNECT_ONE_SHOT` + a normal handler for fire-once logic you must observe.
- **Lambdas/bound callables capturing a freed object** error on emit. Disconnect on `tree_exiting`, or connect to a method on a node that outlives the emitter.
- **2D vs 3D:** signal NAMES match across dimensions (`body_entered`, `visibility_changed`) but the emitter classes differ (`Area2D` vs `Area3D`); pass the right node path. `Node3D` has `visibility_changed`; the 2D equivalent lives on `CanvasItem`.

Confirm exact signal names, argument types, and method signatures with `describe_class class=<Type>` / `list_signals target=<node>` (and `get_godot_version`) before relying on them — signals and ConnectFlags shift between Godot versions.
