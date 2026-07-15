# Automated testing — gdUnit4 / GUT addons (Godot has no built-in test framework)

> Godot 4 ships NO test runner. Install gdUnit4 (fluent asserts, scene runner, mocking) or GUT (xUnit asserts, doubles) from AssetLib, enable in Plugins, write `test_*()` methods. Both run headless and emit JUnit XML.

## Version note
- **No built-in framework** — you MUST install a third-party addon under `res://addons/`. Verify the engine with `get_godot_version` and the installed addon with `read_script res://addons/gdUnit4/plugin.cfg` (or `.../gut/plugin.cfg`).
- **gdUnit4 is hard-pinned to the Godot minor version** (load errors otherwise): **v6.x** (current 6.1.x; lists 4.6.2 support) = Godot **4.5/4.6 ONLY, not backward compatible**; **v5.x** (5.1.1) = 4.3/4.4/4.4.1; **v4.x** (4.4.0/4.3.2) = 4.2/4.3. Server runs 4.6.2 → use **gdUnit4 v6.x**.
- **GUT is version-tolerant across 4.x**: GUT **9.x** covers all of Godot 4 (point releases track engines: 9.4.0≈4.2, 9.5.0≈4.5, 9.6.0≈4.6), min engine ~4.0/4.1. Pick GUT if the project upgrades engines often; pick gdUnit4 for richer scene/mocking tooling.
- **gdUnit4 v4.x→v5/v6**: separate `assert_vector2/assert_vector3` were unified into a single `assert_vector`. **GUT 9.0** (first Godot 4 line): `assert_eq/assert_ne` now compare arrays & dicts BY VALUE (added `assert_same/assert_not_same` for reference equality); `double()` no longer accepts a path string — `load()` the script first.
- Confirm the installed API with `describe_class class=GdUnitTestSuite inherited=true` / `describe_class class=GutTest inherited=true`.

## Required setup
- Install from the in-editor **AssetLib** tab: gdUnit4 (asset id 1522 or 4390) and/or GUT (asset id 1709). Files extract to `res://addons/gdUnit4/` or `res://addons/gut/`.
- Enable under **Project > Project Settings > Plugins** (toggle `gdUnit4` / `Gut`). This adds the in-editor test panel.
- Put tests in `res://test/` (GUT panel default) or `res://tests/`; name files `test_*.gd` and methods `test_*()` so they auto-discover.
- No autoloads required. gdUnit4 auto-snapshots & restores `ProjectSettings` per suite/test; **GUT does NOT** — reset global state in `after_each`.
- CI needs the matching Godot binary; open the project once headless first so `.godot` import cache exists. Addon paths are **case-sensitive on Linux** (`addons/gdUnit4`, not `gdunit4`).

## gdUnit4 — `GdUnitTestSuite` (extends `Node`)
Lifecycle: `before()` / `after()` (once per suite, may `await`), `before_test()` / `after_test()` (per test).
Asserts are **FLUENT** (chain on the returned assert): `assert_that(v)`, `assert_int(int)`, `assert_float(float)`, `assert_str(String)`, `assert_bool(bool)`, `assert_array(arr)`, `assert_dict(Dictionary)`, `assert_object(o)`, `assert_vector(v)` (all Vector types), `assert_file(path)`. Common chains: `.is_equal(x)`, `.is_not_equal(x)`, `.is_null()`, `.is_not_null()`, `.is_true()`, `.is_false()`, `.contains(x)`.
- `assert_signal(emitter: Object) -> GdUnitSignalAssert` — auto-monitors; chain `.is_emitted("name", [args])` / `.is_not_emitted("name")` / `.wait_until(ms)`.
- `assert_func(instance, func_name, args:=[]) -> GdUnitFuncAssert` — polls a method; chain `.is_equal(x).wait_until(ms)`.
- `assert_error(callable: Callable)` — asserts runtime errors. `fail(msg)` / `assert_not_yet_implemented()` mark explicit states.
- `auto_free(obj) -> Variant` — registers Node/RefCounted/Object for `free()` at test end; returns the obj so you wrap inline: `var n := auto_free(Node.new())`.
- `scene_runner(scene: Variant, verbose := false) -> GdUnitSceneRunner` — `scene` is a `res://` path String or an instantiated Node (two params only).
- Mocking (GDScript only): `mock(class_or_path, mock_mode := RETURN_DEFAULTS) -> Object`; `do_return(value) -> GdUnitMock` chained `.on(mock).method(args)`; `spy(instance) -> Object`; `verify(mock_or_spy, times := 1).method(args)`; `verify_no_interactions(o)`, `verify_no_more_interactions(o)`, `reset(o)`.

## gdUnit4 — `GdUnitSceneRunner` (integration / runtime / UI; 2D and 3D identical)
- `simulate_frames(frames: int, delta_milli := -1) -> GdUnitSceneRunner` — **awaitable**, deterministic frame advance: `await runner.simulate_frames(60)`.
- `set_time_factor(factor := 1.0) -> GdUnitSceneRunner` (2.0 = 2x speed). `await_input_processed() -> void`.
- `await_func(name, ...args) -> GdUnitFuncAssert`; `await_signal(name, args := [], timeout := 2000) -> void`; `await_signal_on(source, name, args, timeout)`; `simulate_until_signal(name, ...args)`.
- Input: `simulate_key_pressed(key_code, shift := false, ctrl := false)` (full press+release; `KEY_*` enum), `simulate_action_pressed(action, event_index := -1)` (InputMap names), `simulate_mouse_button_pressed(button_index, double_click := false)` (`MOUSE_BUTTON_LEFT`…), `simulate_mouse_move(pos: Vector2)`, `simulate_screen_touch_pressed(index, pos, double_tap := false)`. Each `*_press`/`*_release` variant also exists.
- `invoke(name, ...args) -> Variant`, `get_property(name) -> Variant`, `set_property(name, value) -> bool`, `find_child(name, recursive := true, owned := false) -> Node`, `scene() -> Node`, `move_window_to_foreground() -> GdUnitSceneRunner`.

## gdUnit4 enums / CLI
- `mock_mode`: `RETURN_DEFAULTS` (default — stubbed methods return type defaults) | `CALL_REAL_FUNC`. Matchers for `verify`/`do_return`: `any()`, `any_int()`, `any_float()`, `any_string()`, `any_bool()`, `any_object()`, `any_array()`, `any_dictionary()`, `any_class(Type)`, `any_vector2()`/`any_vector3()`.
- Parameterized: add a trailing default arg named exactly `test_parameters` — each row is a case: `func test_add(a:int, b:int, exp:int, test_parameters := [[1,1,2],[2,3,5]]) -> void:`. Silence unused-arg warnings with `@warning_ignore("unused_parameter")`.
- CLI: `addons/gdUnit4/runtest.cmd|.sh` (wraps `addons/gdUnit4/bin/GdUnitCmdTool.gd`). Flags `-a/--add <dir>` (repeatable), `-i/--ignore <suite|suite:test>`, `-c/--continue`, `-rd/--report-directory <dir>` (default `res://reports/`), `-rc/--report-count <n>` (default 20). Reports: `index.htm` + `results.xml` (JUnit). **Exit codes: 0 = pass, 100 = failures, 101 = warnings.**

## GUT — `GutTest` (extends `Node`)
Lifecycle: `before_all()` / `after_all()` (once), `before_each()` / `after_each()` (per test). `gut` member for the runner; `gut.p(text, level := 0)` logs.
Asserts are **POSITIONAL** (do NOT mix with gdUnit4 fluent style): `assert_eq(got, expected, text := "")`, `assert_ne`, `assert_same`/`assert_not_same` (reference equality), `assert_almost_eq(got, expected, error_interval, text)`, `assert_gt/gte/lt/lte`, `assert_between(got, low, high)`, `assert_true`, `assert_false`, `assert_null`, `assert_not_null`, `assert_has(obj, element)`, `assert_is(obj, a_class)`, `assert_typeof(obj, TYPE_*)`, `assert_freed(obj)`/`assert_not_freed(obj)`.
- Signals: call `watch_signals(object)` BEFORE the action, then `assert_signal_emitted(obj, "sig")`, `assert_signal_not_emitted`, `assert_signal_emit_count(obj, "sig", n)`, `assert_signal_emitted_with_parameters(obj, "sig", params: Array, index := -1)`.
- Doubles: `double(loaded_script)` (full), `partial_double(loaded_script)` (real unless stubbed), `stub(thing, "method").to_return(value)` / `.to_call(callable)`, `assert_called(inst, "method", params=null)`, `assert_called_count(callable: Callable, expected_count: int)`.
- Memory: `autofree(obj)`, `autoqfree(obj)`, `add_child_autofree(node)`, `add_child_autoqfree(node)`. `pending(text)`, `pass_test(text)`, `fail_test(text)`.
- CLI: `godot --headless -s res://addons/gut/gut_cmdln.gd -gdir=res://test -ginclude_subdirs -gexit -gjunit_xml_file=res://gut_results.xml`. Flags: `-gtest=<scripts>`, `-gprefix=` (default `test_`), `-gconfig=<.gutconfig.json>`, `-gselect=<script>`. **Exit 0 = all pass, 1 = any fail.**

## Recipe — gdUnit4 unit suite, run headless (Godot 4.6.2, v6.x)
```
get_godot_version                                  # confirm 4.6.2
read_script path=res://addons/gdUnit4/plugin.cfg   # confirm gdUnit4 v6.x enabled
describe_class class=GdUnitTestSuite inherited=true # verify assert_* on this version
write_script path=res://tests/test_calculator.gd content="extends GdUnitTestSuite
func test_add() -> void:
	assert_int(2 + 3).is_equal(5)
@warning_ignore(\"unused_parameter\")
func test_add_param(a:int, b:int, exp:int, test_parameters := [[1,1,2],[2,3,5],[10,-4,6]]) -> void:
	assert_int(a + b).is_equal(exp)
func test_node_autofree() -> void:
	var n := auto_free(Node.new())
	assert_object(n).is_not_null()"
# headless: godot --headless --path . -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd --add res://tests --continue
# then read res://reports/results.xml (JUnit) / index.htm; exit 0=pass, 100=fail
```

## Recipe — gdUnit4 scene/integration test (2D or 3D root)
```
write_script path=res://tests/test_player_scene.gd content="extends GdUnitTestSuite
func test_takes_damage() -> void:
	var runner := scene_runner(\"res://scenes/Player.tscn\")
	var player := runner.scene()
	assert_signal(player)                       # auto-monitors from here
	runner.invoke(\"take_damage\", 30)
	await runner.simulate_frames(1)             # MUST await or assert runs early
	assert_int(runner.get_property(\"health\")).is_equal(70)
func test_dies_on_lethal_hit() -> void:
	var runner := scene_runner(\"res://scenes/Player.tscn\")
	runner.set_time_factor(5.0)
	runner.invoke(\"take_damage\", 999)
	await runner.await_signal(\"died\", [], 2000)
	assert_bool(runner.get_property(\"is_dead\")).is_true()"
play_scene → screenshot / get_remote_tree to inspect; assert_node_state for live checks
```

## Recipe — GUT suite with double + signal (version-tolerant 4.3→4.6)
```
read_script path=res://addons/gut/plugin.cfg       # confirm GUT 9.x enabled
write_script path=res://test/test_inventory.gd content="extends GutTest
var inv
func before_each():
	inv = add_child_autofree(Inventory.new())
func test_add_item_increases_count():
	watch_signals(inv)                              # BEFORE the action
	inv.add_item(\"sword\")
	assert_eq(inv.count(), 1, \"count should be 1\")
	assert_signal_emitted(inv, \"item_added\")
func test_with_double():
	var dbl = double(load(\"res://src/Logger.gd\")).new()  # load(), not a path string
	stub(dbl, \"level\").to_return(3)
	assert_eq(dbl.level(), 3)"
# headless: godot --headless -s res://addons/gut/gut_cmdln.gd -gdir=res://test -gexit -gjunit_xml_file=res://gut_results.xml
```

## Common traps
- **Pick the right addon version.** gdUnit4 v6.x ONLY loads on 4.5/4.6 (use it on 4.6.2); v5.x for 4.3/4.4. Wrong version = plugin load error. GUT 9.x spans all 4.x. Always `get_godot_version` + read the addon `plugin.cfg`.
- **Don't mix assert styles.** gdUnit4 is fluent (`assert_int(x).is_equal(y)`); GUT is positional (`assert_eq(x, y)`). A gdUnit4 suite extends `GdUnitTestSuite`; a GUT test extends `GutTest`.
- **Memory/orphans:** a `Node.new()` never added to the tree leaks and is flagged. gdUnit4: `auto_free(Node.new())`. GUT: `autofree()` / `add_child_autofree()`. For scene roots prefer the gdUnit4 scene runner or GUT `add_child_autoqfree`.
- **Async:** real-time waits are flaky. gdUnit4: `await runner.simulate_frames(n)` (forgetting the `await` runs the assert before frames advance) or `await_func(...).is_equal(x).wait_until(ms)`. GUT: `await get_tree().process_frame` / signal awaits.
- **Signals:** gdUnit4 `assert_signal(emitter)` auto-monitors; GUT requires `watch_signals(object)` BEFORE the action or `assert_signal_emitted` always fails. Both handle Nodes and plain Objects.
- **gdUnit4 mocking is GDScript-only** (`mock()`); C# uses Moq via gdUnit4Net. You cannot reliably spy/mock engine **core** methods (e.g. `Node.get_child`) — mock a Node and `do_return` on it instead.
- **GUT `double()` takes no path string in Godot 4** — `load()` the script/scene first. `assert_eq`/`assert_ne` compare arrays/dicts BY VALUE (GUT 9.0); use `assert_same`/`assert_not_same` for reference equality.
- **`scene_runner` has only two params** (`scene`, `verbose`) — there is no `hide_window` argument. Bring the window up with `runner.move_window_to_foreground()`.
- **ProjectSettings isolation:** gdUnit4 auto-restores them per suite/test — don't hand-roll save/restore. GUT does NOT — reset any global state you mutate in `after_each`.
- **CI:** open the project once headless so resources import before running. JUnit lands at `res://reports/results.xml` (gdUnit4, exit 100 on fail) or your `-gjunit_xml_file` path (GUT, exit 1 on fail).

Confirm exact class, method, and enum names with `describe_class` (e.g. `GdUnitTestSuite`, `GdUnitSceneRunner`, `GutTest`) and `get_godot_version` + the addon `plugin.cfg` before relying on them — the test API tracks the installed addon version, not the engine.
