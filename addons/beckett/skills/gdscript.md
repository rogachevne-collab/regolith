# GDScript authoring — write code that compiles the first time

> The good path for GDScript 4, plus the traps LLMs fall into. Always validate before writing.

GDScript is under-represented in training data, so models hallucinate Python/Godot-3 idioms that don't compile. This server fixes that at the source: **`write_script` validates (parses) before writing and refuses code that doesn't compile.** Use the loop below.

## Version note
- **Targets Godot 4.x.** Baseline **4.3+**; recommend **4.4+**. Server runs **4.6.2** — confirm with `get_godot_version`.
- Features tagged `[4.1]`/`[4.3]`/`[4.4]`/`[4.5]` require **that editor or newer** and will fail to parse on older ones. Do not emit them blindly against an unknown project: check `get_godot_version` first.
- Quick map of version-gated syntax below: `static var`/`_static_init`/`@static_unload` **[4.1]**; `@export_storage`/`@export_custom` **[4.3]**; typed `Dictionary[K,V]`/`@export_tool_button`/`@warning_ignore_start`+`_restore` **[4.4]**; `@abstract` **[4.5]**.

## Workflow
1. `read_script path=res://x.gd` (if editing) or `describe_class` to confirm the real API / `get_godot_version` for the gate.
2. `validate_script content="..."` — fast parse check.
3. `write_script path=res://x.gd content="..."` — validated again; refuses on error (pass `validate=false` only to force).
4. `attach_script target=<node> path=res://x.gd`.

## Godot 4 syntax that LLMs get wrong (use the right one)
- **Await, not yield:** `await get_tree().create_timer(1.0).timeout` (Godot 3 `yield` is gone).
- **Signals:** declare `signal died(score: int)`; emit `died.emit(score)` (string `emit_signal("died", ...)` is legacy). Connect: `btn.pressed.connect(_on_pressed)` — string `connect("pressed", target, "method")` is the removed Godot-3 form.
- **Parent calls:** `super.method(args)` for the overridden method, `super(args)` for the parent constructor. Godot 3's `.method()` parent-call syntax is **gone**.
- **Annotations:** `@onready var hp := $HealthBar`, `@export var speed := 200.0`, `@export_range(0, 100) var pct := 50`. Editor-time code (custom node behaviour in the editor, `@export_tool_button`) needs **`@tool`** at the script top.
- **Node refs:** `$Path/To/Node`, `%UniqueName` (scene-unique node), `get_node("...")`. These resolve only at/after `_ready` (see traps).
- **Lifecycle:** `_init()`, `_enter_tree()`, `_ready()`, `_process(delta)`, `_physics_process(delta)`, `_input(event)`, `_unhandled_input(event)`.
- **Typed:** `var items: Array[int] = []`, `var scores: Dictionary[String, int] = {}` **[4.4]**, `func f(x: float) -> void:`. **Nested typed collections are NOT supported** (`Array[Array[int]]`, `Dictionary[String, Dictionary[...]]` won't parse).
- **Inline get/set** (replaces removed `setget`): `var hp: int: get: return _hp; set(v): _hp = clampi(v, 0, max_hp)`. Godot 3's `var hp setget set_hp, get_hp` is gone.
- **Lambdas** are first-class but **invoked with `.call()`**: `var double = func(x): return x * 2` → `double.call(21)`, NOT `double(21)`.
- **Class:** `class_name Foo`, `extends Node2D`. `preload("res://x.gd")` for compile-time, `load(...)` for runtime.
- **enums/consts:** `enum State { IDLE, RUN }`, `const SPEED := 200`.
- **`match`** not switch; **and/or/not** (`&&`/`||`/`!` are officially **unrecommended aliases** per the style guide — prefer words).
- Instancing a PackedScene: `preload("res://Bul.tscn").instantiate()` (Godot 3 `instance()` is gone).

## match patterns (more than a switch)
- Patterns: literals, `_` wildcard, comma for multiple (`1, 2, 3:`), **array** `[a, b]` / `[1, ..]`, **dict** `{"key": val}`, `var name` binding, nested.
- **`when` guards** (4.0): `match v:` → `var x when x > 10:` runs the branch only if the guard is true.

## Annotations worth knowing (version-gated)
- **Rich exports:** `@export_enum("A","B")`, `@export_file("*.png")`, `@export_dir`, `@export_multiline`, `@export_flags("Fire","Ice")`, `@export_color_no_alpha`, `@export_node_path("Camera3D")`, `@export_exp_easing`. Group with `@export_group`/`@export_subgroup`/`@export_category`. `@export_range` extra hints: `"or_greater"`, `"or_less"`, `"exp"`, `"hide_slider"`, `"radians_as_degrees"`, `"suffix:UNIT"` (e.g. `@export_range(0, 10, 0.1, "or_greater", "suffix:m")`).
- **`@export_storage`** / **`@export_custom(hint, hint_string, usage)`** **[4.3]** — serialize without showing / full manual control of an export.
- **`@export_tool_button("Regenerate", "Reload")`** **[4.4]** — clickable Inspector button; the var must hold a **Callable** (`var regen := _regenerate`) and the script must be **`@tool`**.
- **`static var`**, **static funcs**, the static constructor **`static func _static_init()`**, and **`@static_unload`** **[4.1]** — real singletons/counters instead of fakes.
- **`@abstract`** **[4.5]** — annotation (NOT a bare `abstract` keyword; dev snapshots briefly shipped a bare keyword that was renamed before release): `@abstract class_name Shape extends Resource` and `@abstract func area() -> float` (no body). Any class containing an abstract method must itself be `@abstract`; abstract classes can't be instantiated.
- **`@rpc("any_peer", "call_local", "reliable")`** — networking; modes: `"any_peer"`/`"authority"`, `"call_local"`/`"call_remote"`, `"reliable"`/`"unreliable"`/`"unreliable_ordered"`. Replaces Godot 3's removed `remote`/`master`/`puppet`/`sync` keywords.
- **`@warning_ignore("code")`** for one statement; **`@warning_ignore_start("code")`** / **`@warning_ignore_restore("code")`** **[4.4]** for a region.

## Style guide (the validator-friendly conventions)
- `snake_case` files/funcs/vars; `PascalCase` for classes/`class_name`/nodes; `CONSTANT_CASE` for consts and enum members; leading `_` for private members and virtual overrides; **past-tense `snake_case` signals** (`door_opened`, not `open_door`).
- Member order: `@tool`/`@icon` → `class_name` → `extends` → `signal`s → `enum`s → `const`s → `static var`s → `@export`s → public vars → `@onready` vars → methods (`_init`/`_ready` first).

## Removed Godot 3 APIs — do NOT emit these
- `yield` → `await`. `OS.get_ticks_msec()` → `Time.get_ticks_msec()`.
- `FuncRef` → `Callable`. `File`/`Directory` → `FileAccess.open()` / `DirAccess.open()`.
- `PackedScene.instance()` → `instantiate()`. `setget` → inline get/set. `.method()` parent call → `super.method()`.
- `Input.is_action_pressed("ui_accept")` needs the action to exist in the **Input Map** (Project Settings).

## Common traps
- **`_init()` has no children:** `$Child`, `get_node()`, and `@onready` values are **NOT available in `_init()`** — the node isn't in the tree yet. Access them in `_ready()` (or `_enter_tree()` for the node itself). `$` / `%` only resolve at/after `_ready`.
- **Lambdas:** call with `.call(args)`, never `()`. **`Tween`/timer callbacks** pass no args — bind with `Callable.bind(...)`.
- `move_and_slide()` on `CharacterBody2D`/`3D` takes **no args** in 4.x (set `velocity` first; do not multiply by delta).
- `KEY_*`/`MOUSE_BUTTON_*` are global enums; `Vector2.ZERO`, `Color.RED` shortcuts exist. Scene change: `get_tree().change_scene_to_file("res://X.tscn")`.
- **2D vs 3D:** different class names and suffixes (`Sprite2D`/`MeshInstance3D`, `Vector2`/`Vector3`, `Area2D`/`Area3D`) — never mix; confirm with `describe_class`.

## After writing
Attach + `play_scene`, then `wait_until condition=game_connected`, `screenshot`, `get_remote_tree`, `assert_node_state` to verify behaviour — don't assume it works. `list_skills`/`load_skill` for area-specific packs (node3d, tween, physics3d, …).

Confirm exact class, property, method, and annotation names — and whether a feature exists at the project's version — with `describe_class` / `find_methods` / `get_godot_version` before relying on them. APIs and syntax gates shift between Godot versions.
