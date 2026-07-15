# Reflection discovery — reach any Godot class without a per-domain tool

> The meta-skill: find any class, learn its real API, then drive it with the generic tools. No wrappers, never stale.

This server has no hand-coded tool per subsystem. The **entire engine surface is discoverable**, and a few generic tools drive it. Learn this loop once and you can operate particles, animation, tilemaps, audio, UI, physics, navigation, shaders — anything with a class.

**Version-proof by design:** classes added in a new Godot release are reachable the day you upgrade — Godot 4.7's `AreaLight3D`, `VirtualJoystick`, and `DrawableTexture2D` already work through `find_classes`/`describe_class` + `create_node`/`set_property` with **no server update**. Always `get_godot_version` first, then `describe_class` to confirm members for the running build.

## The loop
1. **Find the class.** `find_classes query=<substring> [base=<ClassName>]`
   - `find_classes query=Particles base=Node2D` → `GPUParticles2D`, `CPUParticles2D`
   - `base` restricts to subclasses; omit for a global name search.
2. **Describe it.** `describe_class class=<name> [inherited=true]`
   - Lists every property (`name`, `type`) and method (`name`, `signature`). **This is the key** — it tells you exactly what to `set_property` / `call_method`. `inherited=true` walks the base chain.
3. **Search methods** (optional). `find_methods query=<substring> [class=<name>]`.
4. **Act:**
   - `create_node type=<Class> name=<n> [parent=<path>]` — add a node (undoable).
   - `set_property target=<node> property=<Name> value=<v>` — vectors accept `"x y z"` or `[x,y,z]`; colors `[r,g,b,a]`.
   - `set_resource target=<node> property=<Name> resource=<res://...>` **or** `class=<ResourceClass>` — assign/mint a resource (e.g. a `ParticleProcessMaterial`, a `Shape2D`).
   - `call_method target=<node> method=<Name> args=[...]`.
   - `connect_signal from=<a> signal=<s> to=<b> method=<m>`.

## `target` can be
- a node name/path in the open scene: `Player`, `UI/HealthBar`
- a `res://` resource path
- a class name → its defaults (read-only inspection)

## Worked example — a fire effect, no particle-specific tool
```
find_classes query=Particles base=Node2D      # → GPUParticles2D
create_node type=GPUParticles2D name=Fire
set_resource target=Fire property=process_material class=ParticleProcessMaterial
describe_class class=ParticleProcessMaterial   # find the exact knobs
set_property target=Fire property=amount value=64
set_property target=Fire property=emitting value=true
```

## When a domain is multi-step
Load its pack: `list_skills`, then `load_skill name=particles` (or animation, signals, tilemap, ui, audio, physics2d, …). The pack names the exact classes/properties so you skip the search. Packs are knowledge, not magic — you still drive with the tools above, and they're undoable + never go stale.

## Tip — don't hallucinate GDScript
Before writing scripts, confirm APIs with `describe_class`/`find_methods`, and always let `write_script` validate (it refuses code that doesn't compile). See `load_skill name=gdscript`.
