# GridMap — paint 3D tiles from a MeshLibrary

> GridMap (Node3D) places MeshLibrary items into a 3D cell grid. The 3D analogue of TileMapLayer. Nothing renders until `mesh_library` is set.

## Version note
- **GridMap was NOT renamed** in 4.3+. There is no `GridMapLayer`. (Only the 2D `TileMap` was deprecated for `TileMapLayer` in 4.3.) Present and stable across 4.3–4.6.
- `map_to_local` / `local_to_map` — renamed in 4.0 from the 3.x `map_to_world`/`world_to_map`.
- `physics_material` and `collision_priority` (default `1.0`) exist since early 4.x (`physics_material` since 3.5); they are not new.
- 4.6: editor paint/erase interpolate input points with a Bresenham line so drags fill cells solidly. 4.5.1: fixed cell scale not applying to the cursor mesh.
- **4.7**: a dedicated **MeshLibrary editor** (TileSet-like — category copy/paste, better drag-drop). Editor convenience only; the scriptable API is unchanged — agents still build a `MeshLibrary` via its resource (`create_resource class=MeshLibrary`, then `create_item`/`set_item_mesh`/`set_item_shapes`/`set_item_name`) and assign it to `mesh_library`. Confirm with `describe_class class=MeshLibrary`.

Check with `get_godot_version` / `describe_class class=GridMap`.

## Required setup
- **Assign a `MeshLibrary` to `mesh_library`** — via `set_resource` or Inspector drag-drop. Nothing renders otherwise.
- **Collision** comes from the MeshLibrary item's shapes, NOT the mesh. Provide shapes (StaticBody3D + CollisionShape3D in the source scene, `-col`/`-colonly` import suffixes, or `set_item_shapes` from code). Then set GridMap `collision_layer`/`collision_mask`.
- **Navigation** bakes only if `bake_navigation = true` AND items carry a `NavigationMesh` (a NavigationRegion3D in the source scene). Agents still need a NavigationServer3D map.
- No project setting or autoload required — GridMap is a built-in module (standard builds).
- **Authoring a MeshLibrary in-editor:** build a scene of `MeshInstance3D` children (materials on the mesh surface slot, NOT `material_override`), add an optional `StaticBody3D`/`NavigationRegion3D`, then **Scene > Export As... > MeshLibrary...** and save a `.meshlib`/`.tres`. Enable "Merge with existing" to keep ids stable.

## GridMap key properties
`mesh_library` (MeshLibrary), `cell_size` (Vector3, **default `Vector3(2,2,2)` — not 1**), `cell_octant_size` (int, 8), `cell_center_x/y/z` (bool, all default true), `cell_scale` (float, 1.0), `collision_layer` (int), `collision_mask` (int), `collision_priority` (float, 1.0), `physics_material` (PhysicsMaterial), `bake_navigation` (bool, false). Constant `INVALID_CELL_ITEM = -1`.

## GridMap key methods
- `set_cell_item(position: Vector3i, item: int, orientation: int = 0) -> void` — place item id; pass `-1` (INVALID_CELL_ITEM) to erase.
- `get_cell_item(position: Vector3i) -> int` / `get_cell_item_orientation(position: Vector3i) -> int` (0–23, or -1 if empty).
- `get_orthogonal_index_from_basis(basis: Basis) -> int` / `get_basis_with_orthogonal_index(index: int) -> Basis` — convert a rotation to/from the legal orientation index.
- `get_used_cells() -> Array[Vector3i]`, `get_used_cells_by_item(item: int) -> Array[Vector3i]`, `clear()`.
- `map_to_local(map_position: Vector3i) -> Vector3` / `local_to_map(local_position: Vector3) -> Vector3i`.
- `set_collision_layer_value(layer_number, value)` / `set_collision_mask_value(...)` (1-based bits).

## MeshLibrary key methods
`create_item(id)`, `get_last_unused_item_id() -> int`, `set_item_mesh(id, Mesh)`, `set_item_name(id, String)`, `find_item_by_name(name) -> int` (-1 if none), `set_item_shapes(id, Array)` — **flat `[Shape3D, Transform3D, ...]` pairs**, `set_item_navigation_mesh(id, NavigationMesh)`, `get_item_list() -> PackedInt32Array`, `remove_item(id)`, `clear()`.

## Recipe — place floor tiles from an existing MeshLibrary
```
create_node type=GridMap name=Level parent=/root/Main
set_property target=/root/Main/Level property=cell_size value="Vector3(2, 2, 2)"
set_property target=/root/Main/Level property=cell_center_y value=false   # tiles rest on the floor plane
set_resource target=/root/Main/Level property=mesh_library resource=res://tiles.meshlib
call_method target=/root/Main/Level method=set_cell_item args=["Vector3i(0,0,0)", 0, 0]
call_method target=/root/Main/Level method=set_cell_item args=["Vector3i(1,0,0)", 0, 0]
call_method target=/root/Main/Level method=set_cell_item args=["Vector3i(0,0,1)", 1, 0]   # erase later with item = -1
```

## Recipe — build a MeshLibrary from code, then paint
```
write_script path=res://build_lib.gd content="...":
    var lib := MeshLibrary.new()
    var id := lib.get_last_unused_item_id()
    lib.create_item(id)
    lib.set_item_name(id, "floor")
    lib.set_item_mesh(id, preload("res://floor.obj"))
    var shape := BoxShape3D.new()
    shape.size = Vector3(2, 0.2, 2)
    lib.set_item_shapes(id, [shape, Transform3D.IDENTITY])   # flat [Shape3D, Transform3D] pairs
    ResourceSaver.save(lib, "res://tiles.meshlib")
set_resource target=/root/Main/Level property=mesh_library resource=res://tiles.meshlib
call_method target=/root/Main/Level method=set_cell_item args=["Vector3i(0,0,0)", 0, 0]
```
**Batch from a folder of scenes** (the scriptable form of 4.7's MeshLibrary editor): in one script, loop `DirAccess.get_files_at("res://tiles")`, `load(path).instantiate()`, find the `MeshInstance3D` (recurse children), then `lib.create_item(id)` + `lib.set_item_mesh(id, mi.mesh)` + `set_item_name(id, ...)`, `id += 1`, and finally `ResourceSaver.save(lib, "res://tiles.meshlib")`. Do it in a GDScript like this — Mesh objects can't pass through the generic `call_method` JSON args, so build the library in code, not via raw reflection calls.

Verify: `play_scene`, then `assert_node_state` on `get_used_cells()`.

## Common traps
- **GridMap renders nothing** until `mesh_library` is assigned.
- **`cell_size` defaults to `Vector3(2,2,2)`, not 1.** 1m-cube meshes leave gaps. Set it (to match the mesh footprint) BEFORE painting.
- **Set `cell_center_y = false`** so tiles sit on the floor; leaving it true sinks floor tiles halfway into the cell.
- The **orientation arg is an int 0–23**, NOT degrees and NOT a Basis — the 24 orthogonal rotations. Build a Basis (e.g. `Basis(Vector3(0,1,0), 1.5708)`), pass it to `get_orthogonal_index_from_basis` to get a legal index; **don't hardcode** the number.
- **Item ids are not contiguous 0..N** — iterate `get_item_list()` or use `find_item_by_name`.
- Cell coords are `Vector3i` (integers). Convert with `map_to_local`/`local_to_map`; don't multiply by `cell_size` manually when center flags are non-default.
- GridMap does **not** inherit VisualInstance3D — no cull/visibility layers. Hide via `Node3D.visible`.
- MeshLibrary materials must live on the **mesh surface slot**, not `material_override`, or export drops them.

Confirm exact names/signatures with `describe_class class=GridMap` and `describe_class class=MeshLibrary` before relying on them.
