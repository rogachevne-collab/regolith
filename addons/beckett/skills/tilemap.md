# TileMap — paint tiles from a TileSet

> Godot 4.3+ uses `TileMapLayer` (one node per layer); older 4.x uses `TileMap` with a layer index. A layer needs a `TileSet` resource. Cells are `Vector2i`; source/atlas ids index into the TileSet.

## Version note
- **Godot 4.3+ (incl. 4.6): `TileMapLayer`** — one node = one layer. `TileMap` is **deprecated** (still works).
- **Godot 4.0–4.2: `TileMap`** — methods take a `layer` int as the first arg.
- **`physics_quadrant_size` (int, default 16): added 4.5** — NOT in 4.3/4.4 (4.4 has only `rendering_quadrant_size`). Merges collision shapes of nearby cells with similar physics into one body, so one body RID can span many cells.
- `get_coords_for_body_rid(body: RID)`, terrains, patterns, transform readers, and `update_internals()` exist since 4.3. Server runs **4.6.2**.

Check with `get_godot_version` / `describe_class class=TileMapLayer`.

## TileMapLayer (4.3+)
- `tile_set` (TileSet) — required. Assign: `set_resource target=Ground property=tile_set resource=res://tiles.tres`.
- **Paint:** `set_cell(coords: Vector2i, source_id := -1, atlas_coords := Vector2i(-1,-1), alternative_tile := 0)`. `set_cell(coords, -1)` or **`erase_cell(coords: Vector2i)`** clears one cell (`erase_cell` is the explicit single-cell erase). `clear()` empties the layer.
- **Read:** `get_cell_source_id(coords)`, `get_cell_atlas_coords(coords)`, `get_cell_alternative_tile(coords)`. **Emptiness test = `get_cell_source_id(coords) == -1`** (do NOT test via `get_cell_atlas_coords`).
- **Query:** `get_used_cells()`; `get_used_cells_by_id(source_id := -1, atlas_coords := Vector2i(-1,-1), alternative_tile := -1)` for filtered scans.
- **Coords <-> world:** `local_to_map(local_pos: Vector2) -> Vector2i` and `map_to_local(cell: Vector2i) -> Vector2` (cell center). For a mouse click: `local_to_map(get_local_mouse_position())`.
- **Batch:** after many `set_cell` calls, collision/nav/occlusion rebuilds are deferred and `changed` can fire repeatedly — call **`update_internals()` once** to force a single immediate rebuild; keep `changed` handlers cheap.

Vector2i over reflection: pass `[x, y]` (coerced) or `"x y"`.

## TileMap (4.2 and earlier)
- `set_cell(layer, coords, source_id, atlas_coords, alternative)`; `erase_cell(layer, coords)`; `get_used_cells(layer)` — all take a leading `layer: int`.
- Migrate via editor: select the TileMap, open its bottom panel, click the toolbox icon (top-right), choose **"Extract TileMap layers as individual TileMapLayer nodes"** (added 4.3) — produces a parent Node2D with one TileMapLayer child per layer. Works on directly-openable scenes.

## Transform flags / variants
The `alternative_tile` id carries flips/rotations — OR the `TileSetAtlasSource` constants: `TRANSFORM_FLIP_H=4096`, `TRANSFORM_FLIP_V=8192`, `TRANSFORM_TRANSPOSE=16384` (e.g. `set_cell(c, sid, atlas, TRANSFORM_FLIP_H | TRANSFORM_TRANSPOSE)`). Readers: `is_cell_flipped_h(coords)`, `is_cell_flipped_v(coords)`, `is_cell_transposed(coords)`. The recipe's `alternative_tile=0` is the unflipped default — variants and flips live here.

## Patterns (copy/stamp blocks)
`get_pattern(coords_array: Array[Vector2i]) -> TileMapPattern` snapshots a block; `set_pattern(position: Vector2i, pattern: TileMapPattern)` stamps it — handy for procedural placement.

## Terrains (auto-tiling — 4.x replaced 3.x autotile)
After defining a terrain set on the TileSet (`add_terrain_set`) and painting terrain bits on tiles:
- `set_cells_terrain_connect(cells: Array[Vector2i], terrain_set: int, terrain: int, ignore_empty_terrains := true)` — area fill, auto-picks matching tiles.
- `set_cells_terrain_path(path: Array[Vector2i], terrain_set: int, terrain: int, ignore_empty_terrains := true)` — linear path (roads, walls).

## TileSet setup (resource shared by all layers)
A `TileSet` needs at least one source — usually a `TileSetAtlasSource` (a `texture` sliced into tiles). Authoring is involved; prefer the editor or a `@tool` script over pure reflection. Minimal in-code path (order matters):
```gdscript
var ts := TileSet.new()
ts.tile_shape = TileSet.TILE_SHAPE_SQUARE   # or ISOMETRIC / HALF_OFFSET_SQUARE / HEXAGON
ts.tile_size  = Vector2i(16, 16)            # set shape & size BEFORE creating tiles
var atlas := TileSetAtlasSource.new()
atlas.texture = preload("res://tiles.png")
atlas.texture_region_size = Vector2i(16, 16)  # set before creating/auto-generating tiles
atlas.create_tile(Vector2i(0, 0))           # create_tile(atlas_coords, size := Vector2i(1,1))
var sid := ts.add_source(atlas)             # returns the source_id to pass to set_cell (-1 on failure)
```
**Enabling conditions (TileSet layers):** collision needs `add_physics_layer` + collision polygons on tiles + `collision_enabled` on the TileMapLayer (default true). Pathfinding needs `add_navigation_layer` + `navigation_enabled`. Lighting/shadow masks need `add_occlusion_layer` + `occlusion_enabled`. For moving platforms set `use_kinematic_bodies=true` (default false).

## Recipe — paint a 3-wide floor (4.3+)
```
create_node type=TileMapLayer name=Ground
set_resource target=Ground property=tile_set resource=res://world_tiles.tres
call_method target=Ground method=set_cell args=[[0,0], 0, [0,0], 0]
call_method target=Ground method=set_cell args=[[1,0], 0, [0,0], 0]
call_method target=Ground method=set_cell args=[[2,0], 0, [0,0], 0]
call_method target=Ground method=update_internals args=[]   # one rebuild after the batch
get_remote_tree   # or screenshot to confirm tiles drew
```

## Recipe — terrain fill a rectangle (auto-tiling)
```
# TileSet must already define terrain_set 0 with terrain 0 painted on tiles
call_method target=Ground method=set_cells_terrain_connect args=[[[0,0],[1,0],[2,0],[0,1],[1,1],[2,1]], 0, 0, true]
call_method target=Ground method=update_internals args=[]
```

## Common traps
- **Empty-cell check is `get_cell_source_id(coords) == -1`** — `get_cell_atlas_coords` on an empty cell returns `Vector2i(-1,-1)`, not a reliable emptiness signal.
- **Nothing paints without a valid `tile_set`** AND a real `source_id`/`atlas_coords` that exist in it — `set_cell(coords, 0, [0,0])` is silent if source 0 / atlas (0,0) isn't defined.
- **`physics_quadrant_size` is 4.5+ only**; merged shapes mean one body RID covers several cells — map back with `get_coords_for_body_rid(body)`, not by assuming one body per cell.
- **Flips don't have their own args** — they're packed into `alternative_tile` via `TRANSFORM_FLIP_H/_V/_TRANSPOSE`; passing `0` always yields the unflipped base tile.
- **Set `tile_shape` and `tile_size`/`texture_region_size` BEFORE creating tiles** — changing them after can invalidate or misplace existing tiles.
- **Batch edits**: skip `update_internals()` and collision/nav may lag a frame and `changed` storms; never do heavy work in a `changed` handler during bulk painting.
- **2D-only**: TileMapLayer is a `Node2D`; there is no 3D TileMap (use `GridMap` + a `MeshLibrary` for 3D). Coordinates are `Vector2i` cells, not pixels — convert with `local_to_map`/`map_to_local`.
- **4.0–4.2 `TileMap`**: every cell call takes a leading `layer: int`; the 4.3+ `TileMapLayer` methods drop it.

Confirm exact class, property, and method names with `describe_class` (and `get_godot_version`) before relying on them — TileMap APIs shifted significantly across 4.x.
