# Tween animation — code-driven property animation, no node required

> A non-node `Tween` from `create_tween()` chains `tween_property/method/callback/interval`. Auto-starts; one-shot.

In Godot 4 a `Tween` is a `RefCounted` object created at runtime — **there is no Tween node** (that was Godot 3.x). You cannot `create_node` it; obtain one from a script via `Node.create_tween()` (binds to that node) or `SceneTree.create_tween()` (unbound). It **auto-starts** the instant it's created.

## Version note
- **Tween (non-node, via `create_tween()`): since 4.0** — replaced the Godot 3.x Tween node and the 4.0-beta `SceneTreeTween`. Core API (`tween_property/method/callback/interval`, `set_parallel/parallel/chain`, `set_ease/trans/loops/speed_scale`, `bind_node`, `kill/pause/play/stop`, `is_running/is_valid`) is stable and baseline-safe for **4.3+**.
- **`get_loops_left()`: since 4.1** (not in 4.0). **`TRANS_SPRING`: since 4.1** (4.0 had 11 transitions, no SPRING).
- **`tween_subtween()` / `SubtweenTweener` and `set_ignore_time_scale()`: 4.4+** — NOT in 4.3.
- **`tween_await(signal: Signal)` and `has_tweeners()`: 4.7+** — `tween_await` pauses the chain until a signal emits (gate a sequence on gameplay events instead of fixed delays); `has_tweeners()` reports whether any tweener is still queued. NOT in ≤4.6.

Server runs 4.6.2. Confirm with `get_godot_version` / `describe_class class=Tween`.

## Required setup
- No project settings, autoloads, or flags — `Tween` is core and always available.
- It must be created at runtime from a node/the tree; drive it via `call_method target=<node> method=create_tween` or, better, from an attached script. It cannot be added as an editor node.
- **To replay**, create a NEW tween each time (tweens are one-shot). Store the old one and `kill()` it first to stop two tweens fighting one property.

## Tween (the chainable object)
- `PropertyTweener tween_property(object: Object, property: NodePath, final_val: Variant, duration: float)` — animate `object[property]`; NodePath supports sub-components like `"position:x"`, `"modulate:a"`, `"scale:y"`.
- `MethodTweener tween_method(method: Callable, from: Variant, to: Variant, duration: float)` — feed an interpolated value to a method each frame (shader uniforms, custom setters).
- `CallbackTweener tween_callback(callback: Callable)` — call once at this point; bind args with `Callable.bind(...)`.
- `IntervalTweener tween_interval(time: float)` — a pure delay/gap.
- `tween_await(signal: Signal)` **[4.7+]** — a gap that waits for a signal to emit before the chain continues (event-driven sequencing, e.g. `t.tween_await(anim.animation_finished)`). `has_tweeners() -> bool` **[4.7+]** reports whether any tweener is queued.
- `Tween set_parallel(parallel := true)` — following tweeners run together; `parallel()` affects ONLY the next; `chain()` resumes sequential order.
- `Tween set_ease(ease)`, `set_trans(trans)`, `set_loops(loops := 0)` (0/no-arg = infinite), `set_speed_scale(s)`, `set_process_mode(mode)`, `set_pause_mode(mode)`, `bind_node(node)`.
- Control: `kill()`, `pause()`, `play()`, `stop()`; queries `is_running()`, `is_valid()`, `get_loops_left()` (4.1+, -1 = infinite), `get_total_elapsed_time()`.
- Signals: `finished()` (all done — **never fires for infinite loops**), `loop_finished(loop_count: int)`, `step_finished(idx: int)`.

## Tweeners (returned by the above; all chainable, inherit `Tweener`)
- **PropertyTweener**: `from(value)`, `from_current()`, `as_relative()` (final_val is a delta), `set_delay(s)`, `set_ease(e)`, `set_trans(t)`, `set_custom_interpolator(callable)` (receives 0..1, returns eased value).
- **MethodTweener / CallbackTweener / IntervalTweener**: `set_delay(s)` (+ `set_ease/set_trans` on Method); auto-finish if the Callable's target is freed.

## Enums (set on the Tween default or per-tweener)
- `Tween.TransitionType`: `TRANS_LINEAR=0` (default), `TRANS_SINE=1`, `TRANS_QUINT=2`, `TRANS_QUART=3`, `TRANS_QUAD=4`, `TRANS_EXPO=5`, `TRANS_ELASTIC=6`, `TRANS_CUBIC=7`, `TRANS_CIRC=8`, `TRANS_BOUNCE=9`, `TRANS_BACK=10`, `TRANS_SPRING=11` (4.1+).
- `Tween.EaseType`: `EASE_IN=0`, `EASE_OUT=1`, `EASE_IN_OUT=2`, `EASE_OUT_IN=3`.
- `Tween.TweenProcessMode`: `TWEEN_PROCESS_PHYSICS=0`, `TWEEN_PROCESS_IDLE=1` (default).
- `Tween.TweenPauseMode`: `TWEEN_PAUSE_BOUND=0` (default), `TWEEN_PAUSE_STOP=1`, `TWEEN_PAUSE_PROCESS=2` (keep playing while the tree is paused — use for pause-menu animations).

## Recipe — fade out + shrink a Sprite2D, then free it
```
create_node type=Sprite2D name=Coin parent=/root/Main
write_script path=res://coin.gd content="extends Sprite2D
func collect():
    var t = create_tween()
    t.set_parallel(true)
    t.tween_property(self, \"modulate:a\", 0.0, 0.4)
    t.tween_property(self, \"scale\", Vector2.ZERO, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
    t.chain().tween_callback(queue_free)
"
attach_script target=/root/Main/Coin path=res://coin.gd
call_method target=/root/Main/Coin method=collect args=[]
play_scene
monitor_properties path=/root/Main/Coin property=modulate   # verify fade, then node frees
monitor_properties path=/root/Main/Coin property=scale      # verify shrink
```

## Recipe — infinite bob with easing (tween auto-starts in _ready)
```
write_script path=res://bob.gd content="extends Node2D
func _ready():
    var start = position
    var t = create_tween().set_loops()   # infinite — finished() never fires
    t.tween_property(self, \"position:y\", start.y - 40, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
    t.tween_property(self, \"position:y\", start.y, 0.6).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
"
attach_script target=<node> path=res://bob.gd
play_scene
monitor_properties path=<node> property=position   # confirm oscillation
```

## Common traps
- **`Tween.new()` is invalid** — it can't animate and `is_valid()` stays false. Always use `create_tween()`.
- **Tweens are one-shot and NOT reusable** — replaying via the same object is undefined behavior. Make a fresh tween every replay; `kill()` the previous one first.
- **Auto-starts on creation** — don't create until you want it to play (call `pause()` immediately to defer).
- **Sequential by default** — each `tween_*` runs after the previous finishes. Use `set_parallel(true)` / `parallel()` for concurrency; `chain()` to resume order.
- **`set_ease()` does nothing with `TRANS_LINEAR`** — pair ease with a curve (SINE/CUBIC/BACK/ELASTIC/BOUNCE).
- **Binding**: `Node.create_tween()` dies with that node; `SceneTree.create_tween()` is unbound and keeps running even if a referenced node frees — call `bind_node()` or it may error.
- **`finished` never fires for infinite tweens** (`set_loops()` with 0/no arg) — use a finite count or `loop_finished`.
- **Don't call `tween_property` in `_process`** — that spawns a new tween every frame. Create one tween for the whole motion.
- **2D vs 3D**: same API; paths differ. `Node3D` has no `modulate` — animate a material property or use `tween_method`. Sub-paths are colon paths: `"position:x"`, `"modulate:a"`.
- **Physics bodies**: tweening `position` fights the engine — use `set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)` or move kinematic bodies via their own functions.
- **`tween_callback` passes no args** — bind them: `tween_callback(func.bind(arg))`, or use a lambda.

Always confirm exact class, method, and enum names with `describe_class class=Tween` (and `PropertyTweener`/`MethodTweener`) before relying on them.
