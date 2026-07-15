# Navigation / pathfinding — NavigationServer, regions, agents

> Bake walkable surfaces (NavigationRegion2D/3D), steer actors (NavigationAgent2D/3D), or query NavigationServer directly — but always sync one physics frame first.

## Version note
- **Godot 4.0:** the whole navigation system (NavigationServer2D/3D, NavigationRegion, NavigationAgent, NavigationLink, NavigationObstacle, NavigationPathQueryParameters/Result) was rewritten onto the NavigationServer; replaced 3.x `Navigation`/`Navigation2D`/`Navigation2DServer`. `AStarGrid2D` also new in 4.0 (4.1 added jumping/diagonal modes).
- **4.3:** `NavigationAgent.simplify_path` / `simplify_epsilon` (and on `NavigationPathQueryParameters`); `TileMapLayer` (replaces `TileMap`) carries 2D nav layers.
- **4.4:** `NavigationPathQueryParameters.included_regions` / `excluded_regions`; `NavigationPathQueryResult.path_length`.
- Deprecated: `NavigationRegion.get_region_rid()` → use `get_rid()`; `NavigationPolygon.make_polygons_from_outlines()` (see traps).
- Most navigation classes are flagged **experimental** in the 4.x class reference (names stable across 4.3–4.6). Confirm with `get_godot_version` / `describe_class`.

## Required setup
- No project setting or autoload needed — `NavigationServer2D` / `NavigationServer3D` are always-present singletons; a default map exists per `World2D`/`World3D`. Nodes register to it unless you `set_navigation_map(RID)`.
- 3D bake needs parseable geometry under the `NavigationRegion3D` — `MeshInstance3D` and/or `StaticBody3D` colliders (per `NavigationMesh.geometry_parsed_geometry_type`: `PARSED_GEOMETRY_MESH_INSTANCES`=0 / `STATIC_COLLIDERS`=1 / `BOTH`=2).
- For 2D tile nav: enable a Navigation Layer in the TileSet and paint per-tile polygons; the `TileMapLayer` builds regions automatically.
- Debug: enable `Debug > Visible Navigation` in the running game (+ per-node `debug_enabled`).

## Core classes
- **NavigationRegion2D** — `navigation_polygon` (NavigationPolygon), `enabled` (bool), `navigation_layers` (int=1), `enter_cost` (float=0.0), `travel_cost` (float=1.0), `use_edge_connections` (bool=true). Methods: `bake_navigation_polygon(on_thread: bool = true)` (emits `bake_finished`), `get_rid()`, `set_navigation_map(RID)`.
- **NavigationRegion3D** — `navigation_mesh` (NavigationMesh) + same costs/layers. `bake_navigation_mesh(on_thread: bool = true)` runs on a thread by default — **await `bake_finished` before querying**.
- **NavigationAgent2D/3D** — child of a CharacterBody. Key props: `target_position` (Vector2/3; setting it triggers a path query), `path_desired_distance` (float, 2D=20.0), `target_desired_distance` (2D=10.0), `path_max_distance` (2D=100.0), `navigation_layers` (int=1), `path_postprocessing` (PathPostProcessing=0), `avoidance_enabled` (bool=false), `radius` (2D=10.0), `max_speed` (2D=100.0). Methods: `get_next_path_position() -> Vector2/3` (GLOBAL coords; **call every physics frame** — it advances path state), `set_target_position(v)`, `is_navigation_finished() -> bool`, `is_target_reachable() -> bool`, `get_final_position()`, `set_velocity(v)` (avoidance). 2D units are pixels; 3D are meters — don't copy 2D numbers.
- **NavigationLink2D/3D** — `start_position`/`end_position` (local), `bidirectional` (bool=true), `navigation_layers`, `enter_cost`, `travel_cost`. Bridges gaps/jumps/teleporters. The engine does NOT move the body across a link — you handle it on `link_reached`.
- **NavigationObstacle2D/3D** — dynamic avoidance (`radius`, `velocity`) OR static carving (`vertices` outline + `carve_navigation_mesh`, `affect_navigation_mesh`). 2D winding: clockwise pushes agents inward, counter-clockwise outward.
- **NavigationPolygon** (2D) / **NavigationMesh** (3D) — `cell_size` (NavigationMesh defaults 0.25; `cell_height` 0.25 in 3D) and `agent_radius` (erodes walkable area). 3D adds `agent_height` (1.5), `agent_max_climb` (0.25), `agent_max_slope` (45.0°).
- **AStarGrid2D / AStar2D / AStar3D** — grid/graph pathfinding fully independent of NavigationServer (**no sync gotcha** — query immediately). AStarGrid2D: set `region` (Rect2i; `size` is deprecated), `cell_size`, `set_point_solid(Vector2i, bool)`, `update()`, `get_id_path(from, to)`, `get_point_path(from, to)`, `diagonal_mode`. Use for uniform grids/TileMapLayer.

## Enum/option values
- `PathPostProcessing`: `CORRIDORFUNNEL`=0 (default, natural shortest), `EDGECENTERED`=1, `NONE`=2.
- `PathMetadataFlags` (BitField): `INCLUDE_TYPES`=1, `INCLUDE_RIDS`=2, `INCLUDE_OWNERS`=4, `INCLUDE_ALL`=7 (default; required for `waypoint_reached`/`link_reached` dicts to populate).
- `AStarGrid2D.DiagonalMode`: `ALWAYS`=0, `NEVER`=1, `AT_LEAST_ONE_WALKABLE`=2, `ONLY_IF_NO_OBSTACLES`=3. `Heuristic`: `EUCLIDEAN`=0, `MANHATTAN`=1, `OCTILE`=2, `CHEBYSHEV`=3.

## Key signals
- Agent: `velocity_computed(safe_velocity)` (only while avoidance on), `target_reached()`, `navigation_finished()`, `path_changed()`, `waypoint_reached(details)`, `link_reached(details)` (dict keys: position, type, rid, owner, link_entry_position, link_exit_position).
- Server: `map_changed(map: RID)` (first emit means the map has synced).

## Recipe — 2D: CharacterBody2D follows a baked region
```
create_node type=NavigationRegion2D name=NavRegion parent=/root/Main
set_resource target=/root/Main/NavRegion property=navigation_polygon class=NavigationPolygon
call_method target=/root/Main/NavRegion method=bake_navigation_polygon args=[true]
create_node type=CharacterBody2D name=Actor parent=/root/Main
create_node type=NavigationAgent2D name=NavAgent parent=/root/Main/Actor
set_property target=/root/Main/Actor/NavAgent property=path_desired_distance value=4.0
attach_script target=/root/Main/Actor path=res://actor.gd   # write_script first (validates)
play_scene
wait_until condition=is_navigation_finished
```
```gdscript
extends CharacterBody2D
@export var movement_speed := 200.0
@onready var agent: NavigationAgent2D = $NavAgent
func _ready():
    set_movement_target.call_deferred(Vector2(400, 300))
func set_movement_target(p):
    await get_tree().physics_frame    # REQUIRED: wait for NavigationServer sync
    agent.target_position = p
func _physics_process(_d):
    if agent.is_navigation_finished(): return
    var next := agent.get_next_path_position()
    velocity = global_position.direction_to(next) * movement_speed
    move_and_slide()
```
For RVO avoidance: set `avoidance_enabled=true`, `connect_signal from=NavAgent signal=velocity_computed to=Actor method=_on_velocity_computed`, then `agent.set_velocity(desired)` in `_physics_process` (do NOT move there) and `velocity = safe_velocity; move_and_slide()` in the callback.

## Common traps
- **One-frame sync (the #1 trap):** map/region/agent changes apply at the END of the physics frame. A path query in `_ready()` returns EMPTY. Fix: `call_deferred` your setup, `await get_tree().physics_frame` once before the first query, OR guard with `if NavigationServer2D.map_get_iteration_id(map) == 0: return`, OR `NavigationServer2D.map_force_update(map)`.
- `get_next_path_position()` must run every physics frame — reading the path array alone does not advance path-following.
- **cell_size mismatch:** a region's polygon/mesh `cell_size` (and `cell_height` in 3D) must equal the map's `map_set_cell_size`, or adjacent regions silently fail to connect.
- `navigation_layers` is AND-of-bits: a query traverses a region/link only if `(query.navigation_layers & region.navigation_layers) != 0`. Everything defaults to layer 1.
- Avoidance flips the control flow: with `avoidance_enabled` you MUST `set_velocity(desired)` and apply `velocity_computed`'s `safe_velocity` — don't also push your own velocity into `move_and_slide`. An avoidance-only agent still needs a `target_position` or `velocity_computed` won't fire.
- `bake_navigation_mesh` (3D) is threaded by default — await `bake_finished` (or pass `on_thread=false`).
- `map_get_path` returns a straight line / empty if start or end is outside any region; clamp targets with `NavigationServer2D.map_get_closest_point`.
- A `NavigationLink` doesn't move the body — implement the jump/teleport when `link_reached` fires.
- Don't change static `NavigationObstacle.vertices` every frame (forces a rebuild); for moving obstacles use `radius` + `velocity` dynamic avoidance.
- `NavigationPolygon.make_polygons_from_outlines()` is deprecated — use `NavigationServer2D.parse_source_geometry_data()` to gather into a `NavigationMeshSourceGeometryData2D`, then `NavigationServer2D.bake_from_source_geometry_data()`; or simply `NavigationRegion2D.bake_navigation_polygon()`. `get_region_rid()` → `get_rid()`. `AStarGrid2D.size` → `region`.

Confirm exact class names, property types, and method signatures with `describe_class` (and `get_godot_version`) before relying on them — navigation classes are experimental and version-sensitive.
