# AnimationTree & state machines — drive complex animation by string parameters

> An AnimationTree plays a graph of AnimationNode resources pulled from an AnimationPlayer. Control it at runtime via `parameters/...` get/set and the state-machine playback object. `active` MUST be true.

## Version note
- **AnimationMixer** (shared base of AnimationPlayer & AnimationTree) was introduced in **4.2**. In 4.0/4.1 `AnimationTree` inherited `Node` directly. `root_node`, `deterministic`, `callback_mode_process/method/discrete`, root-motion accumulators, `capture()`, and the deprecation of `set_process_callback` all arrived in **4.2**.
- The core state-machine / blend-tree / blend-space API works in **4.0+**. `AnimationNodeAnimation` custom timeline (`use_custom_timeline`, `timeline_length`, `stretch_time_scale`, `start_offset`, `loop_mode`) is **4.3+**; `advance_on_start` is **4.4+**.
- `anim_player` is the property name in both Godot 3.x and 4.x (setter `set_animation_player`). Old tutorials using `animation_player` as a property are simply wrong.
Server runs 4.6.2 (baseline 4.3+). Check with `get_godot_version` / `describe_class`.

## Required setup
- A linked **AnimationPlayer** (`anim_player` NodePath) that actually holds the named clips — the tree owns no clips.
- `tree_root` must be an **AnimationRootNode**: `AnimationNodeStateMachine`, `AnimationNodeBlendTree`, `AnimationNodeBlendSpace1D/2D`, or `AnimationNodeAnimation`. No `tree_root` = no graph.
- `active` (bool, inherited from AnimationMixer) **= true** or nothing applies — the #1 "nothing happens" cause.
- `root_node` (NodePath, default `..`) should point at the node the tracks target (usually the character root); keep distinct from `anim_player`.
- No project settings/autoloads needed. `deterministic` defaults **true** on AnimationTree (false on base) — set blend params in `_physics_process` so they apply order-independently.

## Key classes & runtime parameters
- **AnimationTree**: `anim_player` (NodePath), `tree_root` (AnimationRootNode), `active` (bool), `advance_expression_base_node` (NodePath, default `.`). All runtime control = `get("parameters/<path>")` / `set("parameters/<path>", value)`. Paths are **case-sensitive** and must match node names exactly.
- **AnimationNodeStateMachine** (tree_root): `add_node(name, node, position:=Vector2())`, `add_transition(from, to, transition)`, `state_machine_type` (ROOT=0/NESTED=1/GROUPED=2), `allow_transition_to_self` (bool). Built-in node names `Start` / `End` (no exported constants).
- **AnimationNodeStateMachinePlayback** — get via `tree.get("parameters/playback")`. Methods: `travel(to:StringName, reset_on_teleport:=true)`, `start(node, reset:=true)`, `stop()`, `next()`, `is_playing()`, `get_current_node()`, `get_travel_path()`, `get_current_play_position()`/`get_current_length()`, `get_fading_from_node()`, `get_fading_from_play_position()`, `get_fading_from_length()`. Signals: `state_started(state)`, `state_finished(state)`.
- **AnimationNodeStateMachineTransition**: `switch_mode` (IMMEDIATE=0/SYNC=1/AT_END=2), `advance_mode` (DISABLED=0/ENABLED=1/AUTO=2), `advance_condition` (StringName → reads `parameters/conditions/<name>`), `advance_expression` (String), `xfade_time` (float), `xfade_curve` (Curve), `priority` (int=1, lower preferred by travel), `reset` (bool=true), `break_loop_at_end` (bool).
- **AnimationNodeBlendTree**: `add_node`, `connect_node(input_node, input_index, output_node)`, `disconnect_node(input_node, input_index)`. Auto-creates terminal node `output`. Sub-params at `parameters/<node>/...`.
- **AnimationNodeBlendSpace1D/2D**: `add_blend_point(node, pos, at_index:=-1)`; runtime `parameters/<node>/blend_position` (float / Vector2). 2D: `auto_triangles` (bool=true), `add_triangle(x,y,z)`.
- **AnimationNodeBlend2 / Add2**: runtime `parameters/<node>/blend_amount` (float). Filter via `set_filter_path(path, enable)`.
- **AnimationNodeOneShot**: `fadein_time`/`fadeout_time`, `mix_mode` (BLEND=0/ADD=1), `autorestart`. Runtime: write `parameters/<node>/request` (NONE=0/FIRE=1/ABORT=2/FADE_OUT=3, auto-clears next frame); read-only `parameters/<node>/active`.
- **AnimationNodeTimeScale**: runtime `parameters/<node>/scale` (float, 1.0; 0 pauses, negative reverses). **AnimationNodeAnimation**: `animation` (StringName), `play_mode` (FORWARD=0/BACKWARD=1).

## Recipe — state machine with travel()
```
get_godot_version                                   # confirm 4.3+
create_node type=AnimationTree name=AnimationTree parent=Character
set_property target=AnimationTree property=anim_player value="../AnimationPlayer"
set_resource target=AnimationTree property=tree_root class=AnimationNodeStateMachine
# add a state per clip (set each AnimationNodeAnimation.animation first)
call_method target=AnimationTree/tree_root method=add_node args=["idle", <AnimationNodeAnimation animation=idle>, [100,100]]
call_method target=AnimationTree/tree_root method=add_node args=["run",  <AnimationNodeAnimation animation=run>,  [300,100]]
# transition (xfade_time=0.15, advance_mode=ENABLED so travel() drives it)
call_method target=AnimationTree/tree_root method=add_transition args=["idle","run", <AnimationNodeStateMachineTransition>]
set_property target=AnimationTree property=active value=true     # REQUIRED, do last
attach_script target=Character path=res://char.gd
```
```gdscript
@onready var sm = $AnimationTree.get("parameters/playback")
func _physics_process(_d):
    sm.travel("run" if velocity.length() > 0 else "idle")
```
Then `play_scene`, `simulate_input`, `monitor_properties` / `assert_node_state` to confirm `get_current_node()` changes.

## Common traps
- `active=false` → tree applies nothing. Set it true last.
- Parameter path typos silently no-op (case-sensitive `parameters/<NodeName>/<param>`).
- `travel()` follows the shortest connected ENABLED path; if **no path connects**, it **teleports** to the target (`reset_on_teleport` controls restart) — it does not error. Use `start()` to force a jump ignoring connections.
- `advance_condition` / `advance_expression` only auto-fire transitions with `advance_mode == AUTO(2)`. ENABLED only fires via `travel()`; DISABLED never fires. Condition booleans live at `parameters/conditions/<name>`.
- `switch_mode = AT_END(2)` never fires on a looping clip unless `break_loop_at_end` is set (or the clip is non-looping).
- OneShot `request` auto-clears to NONE after one process frame — poll the read-only `parameters/<node>/active`, not `request`, to know if it's still playing.
- With `deterministic=true` (the AnimationTree default), set blend params in `_physics_process` or they apply on the wrong frame.
- When an AnimationPlayer is bound to a tree, drive playback through the **tree**, not by calling `play()`/`seek()` on the player (community caution).

Confirm exact class names, property types, and method signatures with `describe_class` / `find_methods` before relying on them.
