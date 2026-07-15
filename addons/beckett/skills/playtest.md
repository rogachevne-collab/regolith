# Playtest suites - record, save, and rerun input runs as regression tests

> Turn a one-off agent playtest into a durable asset: record an input run, attach asserts, save it as `res://tests/playtests/<name>.json`, and rerun it on demand or in CI. Deterministic (frame-exact) replay. Read `input` / `input-devices` for the event shapes and `gdunit4` for pure-GDScript unit tests (a different tool: `test_run`). The `playtest` tool is Full-only.

## Version note
- Server runs **4.6.2**; the frame-exact replay window and the `playtest` tool are Beckett **1.8+**. The 4.2+ engine floor holds: replay uses `Input.parse_input_event`, `Expression`, and `get_tree().paused`, all 4.0+.
- Events recorded on 1.8+ carry a frame stamp `f` (physics-frame delta). Older or hand-authored events without `f` still replay, but back-to-back (non-deterministic). Confirm with `get_godot_version`.

## The loop
1. `play_scene scene=res://your_scene.tscn` then `wait_until condition=game_connected` (the game must be running before you record or run - a handler cannot launch it and wait in one call).
2. `record_input action=start`, drive the game (`simulate_input`, `click_control`, or a human at the keyboard), `record_input action=stop` - you get an `events` array, each event stamped with `t` (ms) and `f` (physics frame).
3. `playtest op=save name=<name> scene=res://your_scene.tscn events=<those events> asserts=[...]` writes the suite file.
4. Re-run any time: replay from a FRESH play session so the initial state matches the recording, then `playtest op=run name=<name>`. It replays deterministically and checks the asserts, returning `{passed, failed, ok, asserts:[...]}`.

## Assert types (the `asserts` array)
- `{"type":"node_state","target":"Player","property":"health","equals":3}` - a node property equals a value (numeric-tolerant: `3` matches `3.0`).
- `{"type":"expr","condition":"get_node('Player').position.y < 500"}` - a GDScript boolean evaluated against the scene root (same scope as `time_control op=step_until`).
- `{"type":"screen_text","text":"You Win"}` - some visible node's `text` contains the string.
- `{"type":"screenshot","baseline":"res://tests/baselines/win.png","tolerance":2.0}` - pixel-diff vs a baseline. Needs an RHI, so it is SKIPPED (never failed) under the headless runner; use it for in-editor runs where the played game has a window.
- `{"type":"perf","metric":"frame_ms_p95","max":16.7}` (Beckett 1.9+) - bound a measured perf metric from the replay window; `max` and/or `min`. Metrics: `frames`, `frame_ms_min/avg/p95/max` (process-frame cost, ms), `fps_min/avg` (engine-reported), `memory_static_end`, `memory_delta`, `orphan_delta`, `draw_calls_end`. All measured Performance monitors, never estimates. `frame_ms_p95 max=16.7` = "95% of frames within a 60 fps budget".

Asserts are evaluated AFTER the replay settles. `op=run` leaves the game FROZEN so reads are stable - call `time_control op=unfreeze` to resume.

## Perf measurement + baseline (1.9+)
- Every deterministic `op=run` also MEASURES the replay window and returns the flat stats above as `result.perf` - no extra flag needed.
- `playtest op=run name=<name> save_baseline=true` stamps this run's stats into the suite file. Every later run returns `result.perf_diff` = per-metric `{baseline, current, delta, delta_pct}`.
- The optimize loop: run with `save_baseline=true` once -> change code -> fresh `play_scene` -> `op=run` -> read `perf_diff` ("frame_ms_p95 +2.1 ms = you made it slower"). Add a `{"type":"perf",...}` assert to make the suite FAIL on a perf regression in CI.
- Frame/fps/draw metrics are only honest with a WINDOWED game: for a headless play session (or the headless runner) they are SKIPPED with a note; `memory_delta` / `orphan_delta` stay valid everywhere.

## Determinism (why replay reproduces exactly)
- Replay opens a game-side window that unpauses, injects each event at its recorded physics frame `f`, then re-pauses. Because injection happens mid-frame while UNPAUSED, both `_input()` callbacks AND polled `Input.*` (e.g. `Input.get_vector`, `is_action_pressed`) see it - a naive freeze-then-inject would miss `_input` on pausable nodes.
- Same recording + same starting scene = same frames = same result, every run. This is the regression guarantee. It holds ONLY if the run starts from the same initial state: record right after a fresh `play_scene`, and rerun from a fresh `play_scene` too.

## Headless CI (the runner)
Run every suite outside the editor, exit non-zero on any failure:
```
godot --headless --path <project> res://addons/beckett/runtime/playtest_runner.tscn
```
It scans `res://tests/playtests/*.json`, plays each scene, replays deterministically, checks asserts, prints `[playtest] ok/FAIL <name>` plus a measured perf line, and quits 1 if any suite fails. `node_state` / `expr` / `screen_text` work headless, and so do `perf` asserts on `memory_*` / `orphan_delta`; `screenshot` asserts and rendering-cost `perf` metrics (`frame_ms_*` / `fps_*` / `draw_calls_*`) skip (no RHI - a render-less loop's frame numbers would prove nothing). Wire this into your own CI to keep the playtests verifying forever.

## Recipe - record a movement run and save it as a suite
```
play_scene scene=res://levels/level_1.tscn
wait_until condition=game_connected
record_input action=start
simulate_input type=key keycode=Right pressed=true
wait_until condition=seconds:0.4
simulate_input type=key keycode=Right pressed=false
record_input action=stop        # returns events:[{type:key,keycode:Right,pressed:true,t,f}, ...]
playtest op=save name=walk_right scene=res://levels/level_1.tscn events=<events from stop> asserts=[{"type":"expr","condition":"get_node('Player').position.x > 100"}]
```

## Recipe - rerun a saved suite and read the verdict
```
stop_scene
play_scene scene=res://levels/level_1.tscn
wait_until condition=game_connected
playtest op=run name=walk_right       # -> {ok:true, passed:1, failed:0, deterministic:true, ...}
time_control op=unfreeze              # replay leaves the game frozen; resume it
playtest op=list                      # every saved suite + its scene/event/assert counts
```

## Common traps
- **Record with KEY / mouse / joy / touch events, not `action`.** The recorder serializes real `InputEvent`s; synthetic `InputEventAction` (`simulate_input type=action`) is NOT captured. Drive `ui_right` by injecting `type=key keycode=Right` (the Input Map maps it to the action), which both records AND drives the action system.
- **The game must be connected first.** `playtest op=run` assumes a live, connected play session (`play_scene` then `wait_until game_connected`). It will not start the game for you.
- **Determinism needs a matching start state.** Replaying onto a game that is mid-level (already moved) will not reproduce the recording. Always rerun from a fresh `play_scene`.
- **Raw hardware polling is a blind spot.** Replayed events drive the action system and `_input`, not `Input.get_joy_axis(device, ...)` raw reads - the same caveat as all synthetic input (see `input-devices`).
- **`screenshot` asserts need a window.** They pass/fail in an in-editor run (the played game has an RHI) but SKIP under `--headless` - keep node-state / expr asserts for the headless CI path, screenshots for local visual checks.
- **`op=run` leaves the game frozen.** That is intentional (stable asserts); call `time_control op=unfreeze` before you keep driving.
- **`playtest` is not `test_run`.** `test_run` runs pure-GDScript `test_*` methods (unit tests, ships in Lite); `playtest` replays input into the RUNNING game and checks live state (Full). Use both.

Confirm class, property, and method names with `describe_class` (e.g. `class=Input`, `class=Expression`) and `get_godot_version` before relying on them.
