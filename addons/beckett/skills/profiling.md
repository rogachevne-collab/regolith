# Profiling - runtime performance monitors + frame budget

> Make build -> test -> fix cover framerate, not just correctness. The `Performance` singleton exposes live counters (fps, memory, draw calls, physics/object counts); Beckett's `get_performance_monitors` reads them from the RUNNING game so an AI can spot regressions and self-correct.

## Version note
- Server runs **4.6.2**; Beckett supports the **4.2+** floor. `Performance.get_monitor`, `add_custom_monitor`, `Engine.get_frames_per_second`, and the core Monitor enums below are all **4.0+**, stable through 4.7.
- The `PIPELINE_COMPILATIONS_*` monitors (shader/pipeline stalls) were added in **4.3**; the split `NAVIGATION_2D_*` / `NAVIGATION_3D_*` monitors in **4.4+**. The plain `NAVIGATION_*` set and everything in the "key monitors" list below exist since 4.0. Confirm with `get_godot_version` / `describe_class class=Performance`.
- Enum values shift as constants are inserted between versions - cite them by SYMBOLIC NAME (`Performance.TIME_FPS`), not the integer, in scripts.

## Performance singleton - reading a monitor
- `Performance.get_monitor(monitor: Monitor) -> float` - one built-in counter. Pass the symbolic enum, e.g. `Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)`.
- Render/physics monitors are updated per rendered/physics frame; read them inside the running game (they are meaningless before the first frame).

## Key Monitor enums (name = category_metric)
- **Frame time (seconds):** `TIME_FPS` (frames/sec), `TIME_PROCESS` (last `_process` frame time), `TIME_PHYSICS_PROCESS` (last `_physics_process` time), `TIME_NAVIGATION_PROCESS`.
- **Memory (bytes):** `MEMORY_STATIC` (in-use), `MEMORY_STATIC_MAX` (peak). (There is no reliable dynamic-memory monitor in 4.x - track `MEMORY_STATIC` growth over time to spot leaks.)
- **Objects:** `OBJECT_COUNT` (all Objects), `OBJECT_RESOURCE_COUNT`, `OBJECT_NODE_COUNT` (nodes in tree), `OBJECT_ORPHAN_NODE_COUNT` (nodes created but NOT in the tree - a leak signal; should trend to ~0).
- **Rendering (per frame):** `RENDER_TOTAL_OBJECTS_IN_FRAME`, `RENDER_TOTAL_PRIMITIVES_IN_FRAME`, `RENDER_TOTAL_DRAW_CALLS_IN_FRAME` (the batching/overdraw signal), `RENDER_VIDEO_MEM_USED`, `RENDER_TEXTURE_MEM_USED`, `RENDER_BUFFER_MEM_USED` (all bytes).
- **Physics (active counts):** `PHYSICS_2D_ACTIVE_OBJECTS`, `PHYSICS_2D_COLLISION_PAIRS`, `PHYSICS_2D_ISLAND_COUNT`, and the `PHYSICS_3D_*` triplet.
- **Audio/nav:** `AUDIO_OUTPUT_LATENCY` (seconds), `NAVIGATION_ACTIVE_MAPS`, `NAVIGATION_REGION_COUNT`, `NAVIGATION_AGENT_COUNT`.
- **Pipeline stalls (4.3+):** `PIPELINE_COMPILATIONS_CANVAS/MESH/SURFACE/DRAW/SPECIALIZATION` - nonzero mid-gameplay means a shader compiled on the hot path (a stutter cause); prewarm to keep these at 0 after load.

## Custom monitors - your own graphable counter
- `Performance.add_custom_monitor(id: StringName, callable: Callable, arguments := [], type := 0)` - `id` looks like `"category/name"`; `callable` returns a number each frame (`arguments` are bound extra args). Appears in the debugger Monitors tab.
- `Performance.remove_custom_monitor(id)`, `has_custom_monitor(id) -> bool`, `get_custom_monitor(id) -> Variant`.
- Use it to expose game-specific budgets (enemy count, active bullets, pathfinds/sec) so the SAME tooling that watches fps watches your hot systems.

## Frame budget - the math that prevents lag
- `Engine.get_frames_per_second() -> int` - same value as `TIME_FPS`, no singleton import. At 60 fps the whole frame budget is ~16.6 ms; `_process` + rendering + `_physics_process` must fit.
- `Engine.physics_ticks_per_second` (default 60) - physics runs a FIXED step; heavy `_physics_process` work runs this many times/sec regardless of render fps. `Engine.max_fps` (0 = uncapped) caps render rate; `Engine.time_scale` slows/speeds the whole clock (great for slow-mo tests, but skews raw timing reads).
- **`_process` vs `_physics_process`:** per-frame visual/logic work goes in `_process` (variable dt); physics/movement in `_physics_process` (fixed dt). Putting expensive work in `_physics_process` multiplies cost by the tick rate; putting movement in `_process` makes it frame-rate-dependent. `TIME_PROCESS` vs `TIME_PHYSICS_PROCESS` tell you which half is over budget.

## Common bottleneck patterns
- **Draw calls / overdraw:** high `RENDER_TOTAL_DRAW_CALLS_IN_FRAME` - too many unbatched materials/nodes or transparent overdraw. Merge materials, use MultiMesh for crowds, cut overlapping alpha.
- **Per-frame allocations:** creating arrays/dictionaries/strings or `.new()` objects every `_process` frame churns the GC and spikes `MEMORY_STATIC`; rising `OBJECT_ORPHAN_NODE_COUNT` means nodes are `.new()`'d but never freed. Pool and reuse.
- **Physics body count:** large `PHYSICS_*_ACTIVE_OBJECTS` / `COLLISION_PAIRS` tank `TIME_PHYSICS_PROCESS` - sleep idle bodies, prune off-screen colliders, widen collision masks less.
- **Particles / fill rate:** big transparent `GPUParticles` cover many pixels; fill-rate-bound frames show high frame time with modest draw calls - shrink emitters, cap `amount`, reduce overdraw.
- **Shader stalls:** nonzero `PIPELINE_COMPILATIONS_*` after the loading screen = first-use compilation hitching; render each material once during load to prewarm.

## Recipe - read live monitors from the running game (Beckett)
```
play_scene                                   # counters are only live while playing
get_performance_monitors                     # fps, process/physics time, draw calls, memory, object/orphan counts
# optional: target a specific running instance/source
get_performance_monitors target=game
wait_until condition="Performance.get_monitor(Performance.TIME_FPS) > 0" timeout_ms=3000
stop_scene
```

## Recipe - assert a frame budget in a playtest
```
play_scene
wait_for_node path=Main timeout_ms=5000
wait_until condition="Engine.get_frames_per_second() >= 55" timeout_ms=5000   # fps floor = pass/fail gate
get_performance_monitors                     # snapshot draw calls / physics time to catch a regression
stop_scene
```
Use `wait_until` on `Engine.get_frames_per_second()` as the numeric gate (it fails the run if the floor is never met within the timeout), and `get_performance_monitors` for the human-readable snapshot of what caused it.

## Recipe - expose a custom monitor for a hot system
```
write_script path=res://perf_probe.gd content="extends Node
var bullets: int = 0
func _ready() -> void:
    Performance.add_custom_monitor(\"game/active_bullets\", _count)
func _count() -> int:
    return bullets
func _exit_tree() -> void:
    Performance.remove_custom_monitor(\"game/active_bullets\")"
attach_script target=Main path=res://perf_probe.gd
play_scene → get_performance_monitors → stop_scene
```

## Common traps
- **Read only while playing** - `Performance.get_monitor` returns stale/zero before the first frame or after `stop_scene`; call it during `play_scene`, and gate with `wait_until` on `TIME_FPS > 0`.
- **Cite enums by name** - integer Monitor values differ across 4.2/4.3/4.4 (constants were inserted); `Performance.TIME_FPS` is safe, a hardcoded int is not.
- **fps is a smoothed average**, not a spike detector - a 200 ms hitch may barely move `TIME_FPS`. Watch `TIME_PROCESS`/`TIME_PHYSICS_PROCESS` peaks and `PIPELINE_COMPILATIONS_*` for stutters.
- **Editor vs export numbers differ** - the running editor adds overhead and debug checks; profile an EXPORTED build (or at least the game window, not the editor viewport) before trusting absolute figures. `get_performance_monitors` reads whichever instance is running.
- **`_physics_process` cost multiplies** by `Engine.physics_ticks_per_second`; lowering the tick rate (or moving non-physics work to `_process`) can rescue `TIME_PHYSICS_PROCESS` more than micro-optimizing.
- **Orphan nodes are a quiet leak** - a climbing `OBJECT_ORPHAN_NODE_COUNT` means `.new()`'d nodes are never `queue_free()`'d or added to the tree; pool or free them.
- **`time_scale` skews timing reads** - slow-mo tests change wall-clock-derived numbers; reset to 1.0 before measuring real frame budget.
- **No per-function profiler via reflection** - these are aggregate counters; for hot-function attribution use the editor's Profiler/Visual Profiler panels manually, then confirm the win via monitors.

Confirm exact enum names, values, and method signatures with `describe_class class=Performance` / `class=Engine` and `get_godot_version` before relying on them - Monitor integer values shift between Godot versions.
