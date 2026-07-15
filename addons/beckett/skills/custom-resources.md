# Custom Resources — inspector-editable, serializable data types

> `extends Resource` + `class_name` makes a reusable data container with @export fields, saved to .tres/.res. Drive with write_script + set_resource + call_method.

A custom Resource is a `RefCounted` data object (NOT a Node): no scene tree, no `_ready`/`_process`/`_physics_process`/input, freed when no references remain. It appears in the editor's *New Resource* dialog and as a drop target for matching `@export` vars — **only if it has a `class_name`**. Use it for items, stats, save games, configs.

## Version note
- **`@export` + `class_name`** custom resources — Godot **4.0** (GDScript 2.0; was `export`/`hint_color` in 3.x; `File`/`Directory` became `FileAccess`/`DirAccess`).
- **`@export_storage`, `@export_custom(hint, hint_string, usage=6)`, `@export_tool_button(text, icon="")`** — Godot **4.4** (require `@tool` for the button; var must hold a `Callable`).
- **`Resource.duplicate_deep(deep_subresources_mode: DeepDuplicateMode = 1)`** and recursive container deep-copy — Godot **4.5** (absent in 4.4).
- Server runs **4.6.2** (baseline 4.3+). Confirm with `get_godot_version` / `describe_class class=Resource inherited=true`.

## Required setup
- Write a **top-level** `.gd` with `extends Resource` and `class_name MyData` — registration is automatic, **no project setting/autoload/import flag needed**.
- Add `@tool` at the top **only** if setters, `_setup_local_to_scene`, tool buttons, or `changed` reactions must run in the editor.
- An autoload holding the active resource is a common but optional pattern to keep a runtime-mutated resource alive (RefCounted — drops when unreferenced).
- Nested (inner) `class` definitions do NOT serialize their custom properties — always use top-level `class_name` scripts for resource types.

## Resource class — key members
- `resource_local_to_scene: bool = false` — if true, duplicated per scene instance so edits don't bleed across instances.
- `resource_name: String`, `resource_path: String`, `resource_scene_unique_id: String` (letters/digits/underscore only if set manually).
- `duplicate(deep: bool = false) -> Resource` — copies stored/exported props. `deep=false` shares nested arrays/dicts/sub-resources by reference; `deep=true` recursively duplicates nested arrays, dictionaries, and packed arrays — any Resource inside is duplicated **only if it is local** (no path or a scene-local path), like `DEEP_DUPLICATE_INTERNAL`. (In 4.4 and earlier, sub-resources inside Array/Dictionary were never duplicated.)
- `duplicate_deep(deep_subresources_mode: DeepDuplicateMode = 1) -> Resource` — 4.5+ explicit deep copy. `DeepDuplicateMode`: `DEEP_DUPLICATE_NONE=0`, `DEEP_DUPLICATE_INTERNAL=1` (default; only path-less/scene-local subresources), `DEEP_DUPLICATE_ALL=2` (every subresource).
- `emit_changed() -> void` — custom resources do **not** auto-emit on property writes; call this yourself (usually in a setter).
- `take_over_path(path: String) -> void`, `get_rid() -> RID` (empty for non-server-backed).
- `_setup_local_to_scene()` virtual — override to init per-instance state on a scene-local duplicate. `setup_local_to_scene()` is deprecated (call only internally).
- Signal `changed` — emit via `emit_changed()`; useful for @tool live-preview and runtime reactivity. `setup_local_to_scene_requested` is deprecated (only emitted when the resource is created).

## Serialization — ResourceSaver / ResourceLoader
- Only `@export` (and 4.4+ `@export_storage`) properties serialize. Plain `var`s are NOT saved.
- `ResourceSaver.save(resource, path = "", flags = 0) -> Error` — extension picks format: `.tres`=text, `.res`=binary. Returns `OK` (0) or an Error code. `SaverFlags`: `FLAG_NONE=0`, `FLAG_RELATIVE_PATHS=1`, `FLAG_BUNDLE_RESOURCES=2`, `FLAG_CHANGE_PATH=4`, `FLAG_OMIT_EDITOR_PROPERTIES=8`, `FLAG_COMPRESS=32` (.res only) — combine with `|`.
- `ResourceLoader.load(path, type_hint = "", cache_mode = 1) -> Resource` — `CacheMode`: `CACHE_MODE_IGNORE=0`, `CACHE_MODE_REUSE=1` (default), `CACHE_MODE_REPLACE=2`, `CACHE_MODE_IGNORE_DEEP=3`, `CACHE_MODE_REPLACE_DEEP=4`. Use `0` (IGNORE) to re-read a player save and avoid a stale cached instance. `ResourceLoader.exists(path, type_hint = "") -> bool`.
- `load("res://x.tres")` is GDScript shorthand for `ResourceLoader.load`; `preload(...)` is compile-time (constant path, GDScript only). Use `res://` for shipped (read-only in exports) and `user://` for runtime-writable saves.

## Recipe — define ItemData and persist an instance
```
write_script path=res://item_data.gd content="extends Resource
class_name ItemData

@export var display_name: String = \"\"
@export_multiline var description: String = \"\"
@export_range(0, 999, 1) var max_stack: int = 1
@export var icon: Texture2D
@export_color_no_alpha var tint: Color = Color.WHITE

func _init(p_name: String = \"\", p_stack: int = 1) -> void:
\tdisplay_name = p_name
\tmax_stack = p_stack"            # write_script validates GDScript before writing
describe_class class=ItemData inherited=true   # confirm it resolves as a named Resource
set_resource target=<inventory node> property=item class=ItemData   # fresh instance on @export var item: ItemData
set_property target=<that ItemData> property=display_name value="Health Potion"
set_property target=<that ItemData> property=max_stack value=10
call_method target=ResourceSaver method=save args=[<the ItemData>, "res://items/health_potion.tres"]
```

## Recipe — @tool resource that reacts to inspector edits + per-instance copies
```
write_script path=res://enemy_stats.gd content="@tool
extends Resource
class_name EnemyStats

@export var max_hp: int = 10:
\tset(v):
\t\tmax_hp = max(v, 1)
\t\temit_changed()
@export var speed: float = 100.0

func _setup_local_to_scene() -> void:
\tpass"                                          # @tool runs setters in-editor; emit_changed() refreshes listeners
set_property target=<the EnemyStats> property=resource_local_to_scene value=true   # each scene instance gets its own copy
connect_signal from=<the EnemyStats> signal=changed ...   # refresh visuals on inspector edit
call_method target=<the EnemyStats> method=duplicate args=[true]   # or an independent deep runtime copy
```

## Common traps
- **No `class_name` → not registered:** works in code but won't appear in *New Resource* or as an `@export` drop target.
- **Only `@export`/`@export_storage` serialize.** Plain `var`s vanish on save/load.
- **`_init()` params MUST all have defaults** — the editor calls `_init()` with no args; missing defaults break inspector editing.
- **Shared-by-default:** `load()` returns a cached shared instance, and assigning one `.tres` to many nodes shares the SAME object — mutating affects all. Use `duplicate(true)` for an independent copy or `resource_local_to_scene=true` per scene instance.
- **No auto `changed`:** write `set(v): x = v; emit_changed()` to react in editor/runtime.
- **No scene tree:** no `_ready`/`_process`/input — put behavior in plain methods called from a Node.
- **Typed exported arrays:** `@export var items: Array[ItemData] = []` (not plain `Array`) for typed drag-drop and correct serialization.
- **`res://` is read-only in exported builds** — save player data to `user://`. Re-load saves with `CACHE_MODE_IGNORE` (0).
- **Security:** `.tres`/`.res` can embed objects/scripts; loading an untrusted/downloaded resource is a code-execution risk. For player data prefer `FileAccess.store_var(value, full_objects=false)` or JSON, or a safe-resource-loader add-on — restrict ResourceSaver/ResourceLoader to your own internal resources.
- **RefCounted lifetime:** an unreferenced resource is freed and unsaved runtime changes lost — hold a reference before mutating.

Always confirm exact class/property/method names with `describe_class` (and `get_godot_version` for version-gated APIs) before relying on them.
