# Scenes, instancing & autoloads — spawn, switch, persist

> PackedScene.instantiate() + add_child, SceneTree scene switching, autoload singletons, groups, and safe (deferred) tree mutation.

## Version note
- **`instantiate()`** is the Godot 4 name; Godot 3's `instance()` is gone. `change_scene(path)` split into **`change_scene_to_file(path)`** + **`change_scene_to_packed(PackedScene)`** in 4.0.
- **`%Name` access / `unique_name_in_owner` / `reparent()`** — added 4.0.
- **`unload_current_scene()`** and **`get_node_count_in_group()`** — added 4.3.
- **`SceneTree.scene_changed` signal** — added **4.5** (emitted after the new scene is added & initialized; reliable hook to read `current_scene`). Works on the 4.6.2 server.
- **Project Settings 'Globals' tab** (Autoload + Shader Globals + Global Groups) — consolidated in 4.5; in 4.3/4.4 Autoload is its own top-level tab.

Check with `get_godot_version` / `describe_class class=SceneTree`.

## Instancing (PackedScene → live nodes)
- `PackedScene.instantiate(edit_state := 0) -> Node` — builds the hierarchy; pass **`0`** (`GEN_EDIT_STATE_DISABLED`) at runtime. Returned node is **detached** — nothing runs and `_ready` does NOT fire until you `add_child()` it.
- Load it: `preload("res://x.tscn")` (compile-time, string literal, GDScript only) or `load(path)` (runtime / computed path / C#).
- `pack(node: Node) -> int` serializes a node + every descendant whose **`owner`** chain reaches it; returns `OK` (0).
- `can_instantiate() -> bool`, `get_state() -> SceneState`.

## SceneTree (via get_tree())
- `change_scene_to_file(path: String) -> int` — `OK` / `ERR_CANT_OPEN`(19, load failed) / `ERR_CANT_CREATE`(20, instantiate failed).
- `change_scene_to_packed(packed: PackedScene) -> int` — pass the **resource**, not an instantiated node; returns `ERR_CANT_CREATE` if it can't instantiate.
- `change_scene_to_node(node: Node) -> int` — switch to a pre-built node; `ERR_UNCONFIGURED`(3) if it's already in the tree.
- `reload_current_scene() -> int` — fresh instance from the original PackedScene. `unload_current_scene() -> void` (4.3+) — free current, no replacement.
- The old scene is removed at the call but **freed at frame end**; the new scene isn't reliably current until then — `await get_tree().scene_changed` (4.5+) or read `current_scene` next frame.
- `current_scene` (Node) is the **last child of `/root`**. `root` (Window) — never free it.

## Groups
- `node.add_to_group(name, persistent := false)` — pass `persistent=true` (or the Groups dock) to save membership in the `.tscn`.
- `get_tree().get_nodes_in_group(name) -> Array[Node]` / `get_first_node_in_group(name)` / `get_node_count_in_group(name)` (4.3+) / `has_group(name)`.
- `call_group(name, method, ...)` runs **immediately**; batch on big groups with `call_group_flags(SceneTree.GROUP_CALL_DEFERRED, name, method, ...)`. Flags: `DEFAULT=0, REVERSE=1, DEFERRED=2, UNIQUE=4` (UNIQUE requires DEFERRED).

## Required setup (autoloads)
- Project Settings > Globals > Autoload (4.5/4.6; 'AutoLoad' tab in 4.3/4.4): set **Path** + **Node Name**, keep the Enable/Global-Variable column checked. `project.godot` gets `[autoload]` `Name="*res://x.gd"` — the `*` enables bare-name access.
- Autoloading a script (extends Node) adds a Node under `/root`; autoloading a scene instantiates it under `/root`. Autoloads load top-to-bottom, **before** the main scene, and **persist across `change_scene_*`** (they're children of `/root`, not of the current scene).
- Access by bare name `Global.score` or `get_node("/root/Global")`. **Never** `free()`/`queue_free()` an autoload.

## Recipe — autoload that holds state & switches scenes
```
write_script path=res://global.gd content="extends Node\nvar score := 0\nfunc goto(path): get_tree().change_scene_to_file(path)"
# add res://global.gd as autoload 'Global' in Project Settings (* enabled)
call_method target=/root/Global method=goto args=["res://level2.tscn"]
# then await get_tree().scene_changed (4.5+) before touching the new scene
```

## Recipe — spawn a PackedScene instance at runtime
```
create_node type=Node2D name=World parent=root
write_script path=res://spawner.gd content="extends Node2D\nconst Bullet := preload(\"res://bullet.tscn\")\nfunc spawn():\n\tvar b := Bullet.instantiate()\n\tadd_child(b)\n\tb.global_position = global_position"
attach_script target=World path=res://spawner.gd
call_method target=World method=spawn
```
Inside a physics/area signal use `add_child.call_deferred(b)` (see traps).

## Common traps
- **Detached instance:** `instantiate()` alone does nothing — `add_child()` it or `_ready`/`_process` never run.
- **Flushing queries:** `add_child`/`remove_child`/`reparent`/`queue_free` during a physics callback or `body_entered`/`area_entered` signal errors *"Can't change this state while flushing queries."* Fix: `parent.add_child.call_deferred(child)` or connect the signal with `CONNECT_DEFERRED`(1).
- **`queue_free()` vs `free()`:** `queue_free()` defers deletion to frame end — safe for in-tree nodes. `free()` is immediate and invalidates refs — only for transient non-tree Objects.
- **`change_scene_to_packed` takes the resource**, `change_scene_to_node` takes a node NOT already in the tree — mixing these up is common.
- **owner & saving:** `add_child()` does NOT set `owner`. At runtime you don't need it, but in `@tool`/editor scripts and before `pack()`, set `child.owner = scene_root` (after add_child) or the child is silently dropped on save.
- **`%Name`** needs `unique_name_in_owner = true` on the target AND the accessor under the same owner, else `get_node("%X")` returns null.
- **Stale tree on switch:** after `change_scene_*`, the old scene is mid-teardown — don't read it; don't assume the new scene exists synchronously.

Always confirm exact names, signatures, and enum ints with `describe_class` (e.g. `describe_class class=SceneTree inherited=true`).
