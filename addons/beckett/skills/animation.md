# Animation — AnimationMixer, AnimationPlayer, AnimationTree

> Author keyframed animations and state machines. Multi-step and reflection-heavy; describe_class is your friend.

## Version note
- Server runs **4.6.2** (baseline 4.3+, recommend 4.4+). Confirm with `get_godot_version` / `describe_class`.
- **4.7**: the animation editor adds collapsible track groups (editor-only). For event-gated motion, `Tween.tween_await(signal)` is new in 4.7 (see the tween skill). No `AnimationPlayer`/`AnimationMixer` API change.
- **AnimationMixer is the shared base of both AnimationPlayer and AnimationTree since 4.2** — library management, root_node, root motion, callback modes, and the `animation_finished`/`animation_started` signals live there (inherited by both). Use `describe_class class=AnimationMixer inherited=true`.
- **Markers + `play_section` are NEW in 4.4** (absent in 4.3). **Capture was revived/generalized in 4.3** (broken in 4.2). **`callback_mode_discrete` is NEW in 4.3**; **`deterministic` is NEW in 4.2**; **`root_motion_local` is NEW in 4.4**.
- Godot 3→4 removals: combined Transform track → split `TYPE_POSITION_3D`/`ROTATION_3D`/`SCALE_3D`; boolean `loop` → `LoopMode` enum; `UPDATE_TRIGGER` removed; `Texture` → `Texture2D`.

## AnimationMixer (the base — owns library + playback config)
Inherited by AnimationPlayer and AnimationTree. Key members (use `describe_class class=AnimationMixer`):
- Library: `add_animation_library(name: StringName, lib: AnimationLibrary)`, `get_animation(name) -> Animation`, `get_animation_list()`, `has_animation(name)`. (Legacy `AnimationPlayer.add_animation(name, anim)` direct-add is **deprecated** — build an `AnimationLibrary` instead.)
- `root_node` (NodePath, default `".."`) — the node tracks resolve relative to. **Set this**, not the deprecated `AnimationTree.anim_player`.
- `callback_mode_process` (AnimationCallbackModeProcess: PHYSICS=0, **IDLE=1 default**, MANUAL=2) — replaces the old `process_callback`/`playback_process_mode`. MANUAL means nothing animates unless you call `advance(delta)` yourself.
- `callback_mode_method` (DEFERRED=0 default, IMMEDIATE=1) — replaces `method_call_mode`.
- `callback_mode_discrete` [4.3] (DOMINANT=0, **RECESSIVE=1 default**, FORCE_CONTINUOUS=2) — how discrete/value tracks blend.
- `deterministic` [4.2] (bool, default false) — when true, unmatched tracks reset to defaults at zero total blend weight.
- `advance(delta)` — step the mixer manually (required under MANUAL callback mode).
- Signals: `animation_finished(anim_name: StringName)`, `animation_started(anim_name: StringName)` — fire for **both** player and tree.

## AnimationPlayer (keyframed playback)
Nodes/resources: `AnimationPlayer` → `AnimationLibrary` → `Animation`.
- Play: `play("library/anim")`; default library is `""`, so `play("walk")`. Also `play_backwards`, `pause`, `stop`, `queue`, `seek`.
- **Section playback [4.4]**: `play_section(name, start_time, end_time, custom_blend, custom_speed, from_end)`, `play_section_with_markers(name, start_marker, end_marker, ...)`, `play_section_backwards`, `get_section_start_time()`, `get_section_end_time()`, `set_section`, `reset_section`, `has_section()` — A-B loop a sub-window of a clip.
- **Capture [4.3]**: `play_with_capture(name, duration, ...)` snapshots current state and blends in (needed for `UPDATE_CAPTURE` tracks; plain `play()` won't trigger capture).
- `reset_on_save` (bool) — on save the editor applies/stores an Animation named exactly `RESET`. There is **no** `reset()` method; the "RESET" pose is a naming convention, not an API call.
- AnimationPlayer-specific signals: `current_animation_changed(name: StringName)` and `animation_changed(old_name: StringName, new_name: StringName)` (queue-advance, **two args** — not the inherited finish signal).

### Building an Animation (value + transform tracks)
`Animation` has tracks. Key methods (use `call_method`):
- `add_track(type) -> int` — `Animation.TrackType`: `TYPE_VALUE=0`, `TYPE_POSITION_3D=1`, `TYPE_ROTATION_3D=2` (keys are **Quaternion**), `TYPE_SCALE_3D=3`, `TYPE_BLEND_SHAPE=4`, `TYPE_METHOD=5`, `TYPE_BEZIER=6`, `TYPE_AUDIO=7`, `TYPE_ANIMATION=8`.
- `track_set_path(idx, "Sprite2D:position")` — `node:property` (sub-paths like `:position:x` work).
- `track_insert_key(idx, time_sec, value)`; typed helpers: `position_track_insert_key(idx, t, Vector3)`, `rotation_track_insert_key(idx, t, Quaternion)`, `scale_track_insert_key(idx, t, Vector3)`, `bezier_track_insert_key(idx, t, value, in_handle, out_handle)`.
- `find_track(path, type)` — the `type` arg is **required** in Godot 4.
- `value_track_set_update_mode(idx, mode)` — `UpdateMode`: `UPDATE_CONTINUOUS=0`, `UPDATE_DISCRETE=1`, `UPDATE_CAPTURE=2` (UPDATE_TRIGGER removed in 4.0). `UPDATE_CAPTURE` only blends when started via `play_with_capture()`/Auto Capture.
- `length` (sec), `loop_mode` (`LOOP_NONE=0`/`LOOP_LINEAR=1`/`LOOP_PINGPONG=2` — replaces 3.x boolean), `capture_included` (bool).
- **Markers [4.4]**: `add_marker(name, time)`, `remove_marker`, `has_marker`, `get_marker_names()`, `get_marker_time(name)`, `get_marker_at_time(t)`, `get_next_marker(t)`, `get_prev_marker(t)`, `get_marker_color`/`set_marker_color` — name the A/B points for `play_section_with_markers`.

Add the animation: `AnimationLibrary.add_animation("walk", anim)`, then `mixer.add_animation_library("", lib)`.

### Quick path
```
create_node type=AnimationPlayer name=Anim parent=<root>
# build Animation + library via call_method (or a @tool script), then:
call_method target=Anim method=play args=["walk"]
```
For many keys, author the `Animation` in a small `@tool` script via `write_script` — faster than per-key reflection.

## Root motion (mixer-level since 4.2)
Drive a `CharacterBody3D` from a baked clip:
- Set `root_motion_track` (NodePath, default `""`) to the bone/path carrying motion.
- Each `_physics_process`: read `get_root_motion_position()`, `get_root_motion_rotation()`, `get_root_motion_scale()` (+ `_accumulator` variants) and feed into `velocity`/transform.
- `root_motion_local` [4.4] (bool) — pre-multiplies the rotation accumulator before blending; flip it on when blended root-motion rotation looks wrong.

## AnimatedSprite2D (frame animation — simpler)
`AnimatedSprite2D` + a `SpriteFrames` resource: `set_resource target=Spr property=sprite_frames class=SpriteFrames`.
- Methods: `play("run")`, `play_backwards()` [4.2], `pause()` [4.2], `stop()`, `set_frame_and_progress(frame, progress)` [4.2]; properties `frame`, `frame_progress` [4.2].
- `SpriteFrames`: `add_animation("run")`, `add_frame(anim, texture: Texture2D, duration: float = 1.0, at_position: int = -1)` — the per-frame `duration` multiplier is a 4.x capability for variable timing; `set_animation_speed(anim, fps)`, `set_animation_loop(anim, bool)`.
- Signals: `animation_looped` (looping clips) vs `animation_finished` (non-looping only), plus `frame_changed`, `animation_changed`. (3D equivalent is `AnimatedSprite3D`.)

## AnimationTree (state machines / blending)
- `AnimationTree` node; set the inherited **`root_node`** to the AnimationPlayer/skeleton root (the `anim_player` property is **deprecated since 4.2**, kept only for back-compat). `tree_root` = an `AnimationNodeStateMachine` (or `AnimationNodeBlendTree`/`AnimationNodeBlendSpace2D`).
- Build states: `AnimationNodeStateMachine.add_node("idle", <AnimationNodeAnimation instance>)`, `add_transition("idle", "run", <AnimationNodeStateMachineTransition>)`.
- Runtime: `tree.get("parameters/playback")` → `AnimationNodeStateMachinePlayback` → `.travel("run")`. Set blend params via `set("parameters/<node>/blend_position", v)`.
- `active = true` to run.

## Required setup
- No autoload/project setting required for AnimationPlayer/AnimatedSprite2D. For deterministic/server-authoritative playback, set `callback_mode_process=MANUAL` **and call `advance(delta)`** every frame or nothing moves.
- Root motion only matters when `root_motion_track` is set; read accumulators in `_physics_process`.
- AnimationTree needs `root_node` pointing at a valid AnimationPlayer and `active=true`.

## Recipe — value-track fade via AnimationPlayer
```
create_node type=AnimationPlayer name=Anim parent=/root/Main
write_script path=res://make_anim.gd content="@tool
extends Node
func build(p: AnimationPlayer) -> void:
    var a := Animation.new()
    a.length = 0.5
    a.loop_mode = Animation.LOOP_NONE
    var t := a.add_track(Animation.TYPE_VALUE)
    a.track_set_path(t, \"../Sprite2D:modulate:a\")
    a.track_insert_key(t, 0.0, 1.0)
    a.track_insert_key(t, 0.5, 0.0)
    var lib := AnimationLibrary.new()
    lib.add_animation(\"fade\", a)
    p.add_animation_library(\"\", lib)   # add_animation_library is on AnimationMixer
"
# call build(Anim) from a @tool/_ready context, then:
call_method target=/root/Main/Anim method=play args=["fade"]
play_scene
monitor_properties path=/root/Main/Sprite2D property=modulate   # verify alpha 1→0
```

## Recipe — AnimationTree state machine travel
```
create_node type=AnimationPlayer name=Anim parent=/root/Main   # holds idle/run clips
create_node type=AnimationTree name=Tree parent=/root/Main
set_property target=/root/Main/Tree property=root_node value="../Anim"   # NOT anim_player (deprecated)
set_resource target=/root/Main/Tree property=tree_root class=AnimationNodeStateMachine
# add_node "idle"/"run" + add_transition via call_method on tree_root, then:
set_property target=/root/Main/Tree property=active value=true
play_scene
call_method target=/root/Main/Tree method=get args=["parameters/playback"]   # → playback obj, then .travel("run")
```

## Common traps
- **`AnimationTree.anim_player` is deprecated** (4.2) — wire via `root_node`. Library/finish APIs are on **AnimationMixer**, inherited by both nodes.
- `animation_changed` on AnimationPlayer takes **`(old_name, new_name)`** (queue advance) — the simple finish callback is the inherited `animation_finished(anim_name)`.
- **`UPDATE_CAPTURE` does nothing under plain `play()`** — start via `play_with_capture()` / Auto Capture [4.3].
- **MANUAL callback mode requires `advance(delta)`** each frame; otherwise the mixer is frozen.
- Markers, `play_section*`, and `root_motion_local` are **4.4+** — guard with `get_godot_version` if you may run on 4.3.
- There is **no `reset()`** — "RESET" is an Animation-name convention saved when `reset_on_save=true`.
- Rotation 3D keys are **Quaternion**, not Euler; the 3.x combined transform track no longer exists (use the split position/rotation/scale tracks).
- `find_track` **requires the `type` arg** in Godot 4.
- AnimatedSprite2D: `animation_looped` fires for looping clips, `animation_finished` only for non-looping — don't wait on the wrong one.

Confirm exact class, property, method, and enum names with `describe_class` (and `get_godot_version`) before driving — this domain shifts the most across versions.
