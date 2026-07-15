# C# / .NET — the dev loop, and driving C# nodes from the agent

> Beckett is GDScript-first but works with C#/.NET Godot projects. The one real difference: C# has no in-process compile-gate — use `build_csharp` to compile-check after every `.cs` edit.

## Requirements & version note
- Needs the **Godot .NET build** (the plain build can't run C#) + the **.NET SDK** — already installed for any C# Godot project, so Beckett adds no new dependency. Confirm the engine with `get_godot_version`.
- **Compile diagnostics need Godot 4.4+** (subprocess output capture). On 4.2–4.3 `build_csharp` still runs but only reports the exit code.

## The loop (this replaces GDScript's validate-before-write)
`write_script` writes `.cs` but does **NOT** compile-check it — the GDScript gate can't parse C#. So:
1. `write_script path=res://Player.cs content="..."` — writes the file (no compile gate for `.cs`).
2. `build_csharp` — the C# compile-check: runs `dotnet build` to a scratch output (safe while the editor is open), returns structured `diagnostics` `[{file, line, column, code, message}]`. Auto-detects the `.csproj`, or `build_csharp csproj=res://Game.csproj`.
3. Read the `CSxxxx` diagnostics, fix at their file:line, repeat until `ok:true`. First build restores packages (slower); incremental ~1–3s.
4. `play_scene` — Godot **builds before running**, so the running game always has your latest C#. No manual reload step.

## Discovering C# types
- `find_classes query=Player` and `describe_class class=Player` now surface your **`[GlobalClass]`** C# types (and GDScript `class_name`), not only engine classes.
- C# member info is **build-gated**: if `describe_class` on a C# type lists no members, run `build_csharp` first, then retry (un-built C# has no type info yet). Engine base-class members are shown regardless.

## Driving a RUNNING C# game — two naming rules + one trap (read this)
C# nodes are driven over the same Variant channel as GDScript, but:
- **User-defined C# members use EXACT PascalCase.** `runtime_call class=Player method=TakeDamage args=[10]`, `runtime_get_property class=Player property=Speed`. `take_damage` / `speed` will NOT resolve.
- **Engine-inherited members stay snake_case**, even on a C# node: `runtime_get_property class=Player property=position` (not `Position`). One node mixes both — your members PascalCase, inherited members snake_case.
- **Properties enumerate only if `[Export]`.** A plain `public` property is get/set-able by name but may not appear in `describe_object target=%Player`; mark it `[Export]` to make it discoverable.
- **Cross-language calls fail SILENTLY on a wrong arg count/type** — no error, no return value. Verify the method + arg types (`describe_class`, `get_remote_tree`) before calling.

## C# idioms (the good path)
- **Class:** `public partial class Player : Node2D` — `partial` is REQUIRED (the source generator needs it; without it Godot silently ignores the class's methods/exports).
- **Global class:** `[GlobalClass]` above the class registers it (Create-Node dialog + `find_classes`). The **file name must equal the class name** (case-sensitive) or it won't register.
- **Exports:** `[Export] public float Speed = 200f;` — Inspector-visible AND discoverable. Hints: `[Export(PropertyHint.Range, "0,100")]`.
- **Lifecycle is PascalCase, delta is double:** `_Ready()`, `_Process(double delta)`, `_PhysicsProcess(double delta)`, `_Input(InputEvent @event)`.
- **Signals:** `[Signal] public delegate void DiedEventHandler(int score);` → emit `EmitSignal(SignalName.Died, score);`. Connect in C#: `button.Pressed += OnPressed;`.
- **Output & nodes:** `GD.Print("hi")` (not `Console.WriteLine`); `GetNode<Sprite2D>("Sprite")`, `GetNode<Label>("%Score")`.
- **Types:** `Vector2`/`Vector3`, `Mathf.` (not `System.Math`), float literals need `f` (`200f`).

## GDScript → C# quick map
- `func _ready():` → `public override void _Ready()`
- `@export var speed := 200.0` → `[Export] public float Speed = 200f;`
- `signal died(score)` → `[Signal] public delegate void DiedEventHandler(int score);`
- `$Sprite` / `%Score` → `GetNode<Sprite2D>("Sprite")` / `GetNode<Label>("%Score")`
- `emit_signal("died", s)` → `EmitSignal(SignalName.Died, s);`
- `preload("res://B.tscn")` → `GD.Load<PackedScene>("res://B.tscn")`

## Traps
- **No hot-reload of external builds.** `build_csharp` gives diagnostics but does NOT make the open editor see new C# types — that happens on Godot's own Build (hammer) or on `play_scene`. To author a scene with a brand-new C# type, `play_scene` once (or Build) so the editor loads it.
- **`partial` missing** → source generator skips the class; its methods/exports are invisible to Godot.
- **Filename ≠ class name** → `[GlobalClass]` won't register.
- Confirm the version supports what you emit with `get_godot_version`; verify member names with `describe_class` before driving them.
