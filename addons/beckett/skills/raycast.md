# Raycasts & physics queries — RayCast/ShapeCast nodes + code-driven space-state queries (2D & 3D)

> Two ways to query physics: NODE casters (RayCast2D/3D, ShapeCast2D/3D — auto-query each physics frame) or CODE via `get_world_*().direct_space_state` (any direction, **`_physics_process` only**).

## Version note
- Server runs **4.6.2** (baseline 4.3+). All listed classes/methods exist with these signatures since 4.3, unchanged through 4.6. Confirm with `get_godot_version` / `describe_class`.
- **Godot 4.6 makes Jolt the DEFAULT 3D physics engine** (built-in option since 4.4; was GodotPhysics in 4.3–4.5; existing projects keep their setting). Switch at Project Settings → Physics → 3D → Physics Engine (key `physics/3d/physics_engine`, values "Jolt Physics" / "GodotPhysics").
- **Jolt impact on `face_index`**: under Jolt, `RayCast3D.get_collision_face_index()` and `intersect_ray()`'s `face_index` are **always -1** unless you enable Project Settings → Physics → Jolt Physics 3D → Queries → **Enable Ray Cast Face Index** (raises ConcavePolygonShape3D memory ~25%). GodotPhysics3D returns it normally.
- **2D vs 3D**: `face_index` (result key + `get_collision_face_index()`) and `hit_back_faces` are **3D-only**. 2D ray results have no `face_index` key.

## Required setup
- No autoloads, import flags, or project settings needed — queries work out of the box.
- Targets MUST be a CollisionObject (StaticBody/RigidBody/CharacterBody/AnimatableBody 2D/3D, or Area2D/3D) with an **enabled** CollisionShape (or CollisionPolygon) and be in the tree. Plain MeshInstance3D/Sprite2D are invisible to queries; disabled shapes and freed nodes don't appear.
- To detect Area nodes, set **`collide_with_areas = true`** (default false). Bodies default true.
- Layers must align: target's `collision_layer` bit ∈ caster's `collision_mask`. Default everything-on-layer-1 works until you customize.
- ShapeCast and `intersect_shape`/`cast_motion`/`collide_shape`/`get_rest_info` REQUIRE a `shape` resource assigned, else the query is invalid.
- Code queries (`direct_space_state`) are only valid inside `_physics_process` / `_integrate_forces` — an enabling CONDITION, not a setting. When driving via MCP, `play_scene` then `wait_until`/`wait_for_node` so the physics loop runs before reading results.

## RayCast2D / RayCast3D — single ray, auto-cast each physics frame
Properties: `enabled: bool=true`, `target_position` (**LOCAL/RELATIVE** endpoint, NOT global; 3D Vector3 default `(0,-1,0)`, 2D Vector2 default `(0,50)`), `exclude_parent: bool=true` (excludes ONLY the immediate parent CollisionObject), `collide_with_bodies: bool=true`, `collide_with_areas: bool=false`, `collision_mask: int=1` (layer 1 only), `hit_from_inside: bool=false`. 3D adds `hit_back_faces: bool=true`, `debug_shape_thickness: int=2`, `debug_shape_custom_color`.
Methods: `force_raycast_update() -> void`, `is_colliding() -> bool`, `get_collider() -> Object` (the NODE, not its shape), `get_collider_rid() -> RID`, `get_collider_shape() -> int`, `get_collision_point() -> Vector2/3` (**GLOBAL**), `get_collision_normal() -> Vector2/3`, `add_exception(node)`, `add_exception_rid(rid)`, `remove_exception(node)`, `clear_exceptions()`, `set_collision_mask_value(layer_number: int, value: bool)` (1-based, 1..32), `get_collision_mask_value(layer_number) -> bool`. 3D only: `get_collision_face_index() -> int` (-1 if none; see Jolt note above).

## ShapeCast2D / ShapeCast3D — sweep a shape, ALL hits + safe/unsafe fraction
Adds over RayCast: `shape: Shape2D/3D` (**REQUIRED**, no default), `margin: float=0.0`, `max_results: int=32`, `collision_result: Array` (Array of Dictionaries; same fields as `get_rest_info`: `collider_id, linear_velocity, normal, point, rid, shape`).
Methods (result accessors are **INDEXED**, gated by `get_collision_count()`): `force_shapecast_update()`, `is_colliding()`, `get_collision_count() -> int`, `get_collider(index) -> Object`, `get_collider_rid(index)`, `get_collider_shape(index) -> int`, `get_collision_point(index) -> Vector2/3`, `get_collision_normal(index) -> Vector2/3`, `get_closest_collision_safe_fraction() -> float` (0..1; `1.0` = full sweep clear), `get_closest_collision_unsafe_fraction() -> float`, `add_exception(node)`, `clear_exceptions()`.

## Code queries — PhysicsDirectSpaceState2D/3D (from `get_world_2d()/get_world_3d().direct_space_state`)
- `intersect_ray(params) -> Dictionary` — single CLOSEST hit; `{}` on miss, else `{position, normal, collider, collider_id, rid, shape}` (3D adds `face_index`). Test with `if result:`.
- `intersect_point(params, max_results:=32) -> Array[Dictionary]` — shapes containing the point; each `{collider, collider_id, rid, shape}`.
- `intersect_shape(params, max_results:=32) -> Array[Dictionary]` — overlapping shapes (motion ignored).
- `cast_motion(params) -> PackedFloat32Array` — `[safe_fraction, unsafe_fraction]` (0..1); `[1.0, 1.0]` = no collision.
- `collide_shape(params, max_results:=32) -> Array[Vector2/3]` — FLAT contact-point pairs `[ownA, otherA, ownB, otherB, ...]`.
- `get_rest_info(params) -> Dictionary` — `{}` on miss, else `{point, normal, collider_id, rid, shape, linear_velocity}` (zero for Areas).

### Query parameter objects (all `RefCounted`)
- **PhysicsRayQueryParameters2D/3D**: `from`, `to` (both **GLOBAL**), `collision_mask: int=4294967295` (**ALL layers** — differs from node default 1), `collide_with_bodies=true`, `collide_with_areas=false`, `exclude: Array[RID]=[]`, `hit_from_inside=false` (3D adds `hit_back_faces=true`). Static helper: `create(from, to, collision_mask:=4294967295, exclude:=[]) -> PhysicsRayQueryParameters2D/3D` (leaves `collide_with_areas=false`).
- **PhysicsPointQueryParameters2D/3D**: `position` (GLOBAL), `collision_mask=4294967295`, `collide_with_areas=false`, `exclude`. **No `create()`** — use `.new()` then set `position`.
- **PhysicsShapeQueryParameters2D/3D**: `shape`, `transform` (GLOBAL placement; `transform.origin` positions it), `motion` (for `cast_motion`, ignored by `intersect_shape`), `margin=0.0`, `collision_mask=4294967295`, `collide_with_areas=false`, `exclude`. **No `create()`** — use `.new()`.

## Camera3D mouse picking (3D has no point-pick — build a ray)
`project_ray_origin(screen: Vector2) -> Vector3` (handles perspective AND orthogonal), `project_ray_normal(screen: Vector2) -> Vector3`, plus `project_position`, `unproject_position`, `is_position_behind`. Standard pick: `origin = cam.project_ray_origin(mouse); to = origin + cam.project_ray_normal(mouse) * RAY_LENGTH`. For 2D, prefer `intersect_point` with `get_global_mouse_position()`.

## Recipe — RayCast3D ground-check under a player (NODE way)
```
get_godot_version                                          # if >=4.6, Jolt is default 3D engine
find_classes query=RayCast base=Node3D                     # discover RayCast3D / ShapeCast3D
describe_class class=RayCast3D inherited=true              # confirm target_position, collide_with_areas, collision_mask
create_node type=RayCast3D name=GroundCheck parent=Player
set_property target=Player/GroundCheck property=target_position value=[0,-1.2,0]   # LOCAL, points down
set_property target=Player/GroundCheck property=collision_mask value=1            # scan layer 1
play_scene  →  wait_until ...  →  call_method target=Player/GroundCheck method=force_raycast_update args=[]
call_method target=Player/GroundCheck method=is_colliding args=[]                 # -> bool
call_method target=Player/GroundCheck method=get_collider args=[]                 # -> floor node
call_method target=Player/GroundCheck method=get_collision_point args=[]          # -> Vector3 GLOBAL
stop_scene
```

## Recipe — 3D mouse picking via code (CODE way, inside `_physics_process`)
```
describe_class class=PhysicsRayQueryParameters3D inherited=false   # confirm static create(from,to,mask,exclude)
describe_class class=Camera3D inherited=false                      # confirm project_ray_origin / project_ray_normal
write_script path=res://picker.gd content="extends Camera3D
const RAY_LENGTH := 1000.0
func _physics_process(_delta):
    var space := get_world_3d().direct_space_state      # ONLY valid here
    var mouse := get_viewport().get_mouse_position()
    var from := project_ray_origin(mouse)
    var to := from + project_ray_normal(mouse) * RAY_LENGTH
    var q := PhysicsRayQueryParameters3D.create(from, to)
    q.collide_with_areas = true                          # default false!
    var hit := space.intersect_ray(q)
    if hit:
        print(hit.collider, ' at ', hit.position)"
attach_script target=Camera3D path=res://picker.gd
play_scene  →  simulate_input (mouse move/click over object)  →  screenshot / get_remote_tree
stop_scene
```

## Recipe — ShapeCast3D sweep to predict a wall ahead (safe fraction)
```
describe_class class=ShapeCast3D inherited=true
create_node type=ShapeCast3D name=Sweep parent=Player
set_resource target=Player/Sweep property=shape class=SphereShape3D    # REQUIRED Shape3D
set_property target=Player/Sweep property=target_position value=[0,0,-3]   # LOCAL sweep 3m forward (-Z)
play_scene  →  call_method target=Player/Sweep method=force_shapecast_update args=[]
call_method target=Player/Sweep method=get_closest_collision_safe_fraction args=[]   # 0..1; 1.0 == clear
call_method target=Player/Sweep method=get_collider args=[0]          # first hit (INDEXED)
stop_scene
```

## Common traps
- **TIMING (most common error)**: `direct_space_state` is locked outside `_physics_process`/`_integrate_forces` — calling it from `_process`, `_ready`, input handlers, signals, or a thread errors (physics may run on another thread). On input, set a flag and run the query next `_physics_process`.
- **`target_position` is LOCAL/RELATIVE** for ALL node casters (endpoint = node global pos + `target_position` rotated by transform), NOT a global target. But params `from`/`to` ARE global. Most-common confusion.
- **Results lag one physics frame**: after moving a caster (or with `enabled=false`, or reading in `_ready`), call `force_raycast_update()` / `force_shapecast_update()` first.
- **Areas off by default**: set `collide_with_areas=true` on the node or params to hit Area2D/3D.
- **`collision_mask` default differs**: NODES default `1` (layer 1); `.create()`/`.new()` PARAM objects default `4294967295` (ALL). Node "hits nothing" → widen mask; code "hits too much" → narrow it. `create()` also leaves `collide_with_areas=false`.
- **`exclude_parent` excludes ONLY the direct parent**, not siblings/children. In code, skip self with `query.exclude = [self.get_rid()]` (or `get_parent().get_rid()`); for nodes use `add_exception()`/`add_exception_rid()`.
- **Ray starting inside a shape returns NOTHING** unless `hit_from_inside=true`; the reported normal is then the zero vector.
- **`intersect_ray` returns only the closest hit** (`{}` on miss). For all/multiple hits use ShapeCast, repeated rays with growing `exclude`, or `intersect_shape`/`intersect_point` (Arrays, honor `max_results` default 32).
- **ShapeCast accessors are INDEXED** (`get_collider(i)`, gated by `get_collision_count()`); RayCast accessors take no index. Don't mix the two APIs.
- **`get_collider()` returns the NODE**, not its CollisionShape child — use `get_collider_shape()` (index) + `collider.shape_owner_*` to find the sub-shape.
- **Jolt + `face_index`**: always -1 under Jolt unless the query setting is enabled (or use GodotPhysics) — check `get_godot_version` and the physics engine before relying on it.

Always confirm exact class names, property types, and method signatures with `describe_class` / `find_methods` (and `get_godot_version`) before relying on them — defaults differ between node casters and param objects, and between GodotPhysics and Jolt.
