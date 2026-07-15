# Physics 2D — bodies, shapes, collision layers, queries

> CharacterBody2D / RigidBody2D / StaticBody2D / Area2D + a CollisionShape2D. Mind move_and_slide()'s 4.x signature and apply gravity yourself. 2D up is `(0,-1)`.

## Version note
- **`move_and_slide()` takes NO arguments in Godot 4** (Godot 3 was `move_and_slide(velocity, up)`). `velocity` is now a settable property; **gravity is no longer auto-applied** — do `velocity.y += gravity * delta` yourself.
- **`AnimatableBody2D`** (4.0, extends StaticBody2D) for moving platforms/doors that carry/push bodies (`sync_to_physics`, default `true`); replaced the 3.x "move a StaticBody" pattern. Godot 3's `KinematicBody2D` → `CharacterBody2D`.
- **`ShapeCast2D`** introduced in 4.0; **`PhysicsBody2D.get_gravity()`** (net gravity incl. Area2D overrides) added in **4.3** (absent in 4.2). `get_platform_velocity()` is the 4.0 rename of 3.x `get_floor_velocity()`; Area2D `gravity_direction` renamed from 3.x `gravity_vec`.
- **2D physics has only one engine (Godot Physics).** Jolt (built-in 4.4, **default 3D engine for new 4.6 projects**) is **3D-only** — it does NOT change ShapeCast2D/CharacterBody2D/RigidBody2D/Area2D/KinematicCollision2D, which are stable through 4.6. Confirm with `get_godot_version` (server runs **4.6.2**, baseline 4.3+) / `describe_class`.

## Body types
- `CharacterBody2D` — code-driven. Set `velocity` (Vector2), then call `move_and_slide()` once in `_physics_process(delta)`. Helpers (valid only AFTER the call): `is_on_floor()`, `is_on_wall()`, `is_on_ceiling()`, `get_floor_normal()`, `get_slide_collision_count()`, `get_slide_collision(i) -> KinematicCollision2D`, `get_last_slide_collision()`, `get_real_velocity()` (actual post-slide velocity; `velocity` is your *requested* one), `get_platform_velocity()`. Tuning props below.
- `RigidBody2D` — physics-simulated. **Forces** (per-step): `apply_central_force(force)` / `apply_force(force, position=Vector2(0,0))`; **impulses** (one-shot): `apply_central_impulse(impulse)` / `apply_impulse(impulse, position=Vector2(0,0))`; torque: `apply_torque(t)` / `apply_torque_impulse(t)`. Props: `mass`, `gravity_scale`, `linear_velocity`, `angular_velocity`, `linear_damp`, `freeze`+`freeze_mode` (`FREEZE_MODE_KINEMATIC=1` for scripted motion that still pushes others), `continuous_cd` (anti-tunneling). **`body_entered`/`body_exited`/`get_colliding_bodies()` fire only with `contact_monitor=true` AND `max_contacts_reported>0`** (both default off — #1 "signal never fires" bug). Its `body_entered(body: Node)` passes a plain `Node`.
- `StaticBody2D` — immovable world geometry. `constant_linear_velocity` pushes touching bodies (conveyor) without moving the body itself.
- `AnimatableBody2D` — code/animation-moved platforms (`sync_to_physics`); use this, NOT a moved StaticBody2D, so it carries riders.
- `Area2D` — overlap detection / gravity-damp zones (no collision response). Signals `body_entered(body: Node2D)`, `area_entered(area: Area2D)`; `get_overlapping_bodies() -> Array[Node2D]`, `get_overlapping_areas() -> Array[Area2D]`.

## CharacterBody2D tuning
- `motion_mode`: `MOTION_MODE_GROUNDED=0` (default, platformer — has floor/wall/ceiling) vs `MOTION_MODE_FLOATING=1` (top-down, no floor concept — `is_on_floor()` is always false). `up_direction` (Vector2, default `(0,-1)`/UP) defines what counts as floor vs ceiling.
- `floor_max_angle` (~0.785 rad = 45°, **radians**), `floor_snap_length` (default `1.0`), `floor_stop_on_slope` (true), `max_slides` (4). Set `up_direction` or `is_on_floor()`/slope handling misbehave.

## Collision shape (required)
Every body/Area2D needs a `CollisionShape2D` (or `CollisionPolygon2D`) direct child with a `shape` Resource, or it won't collide/detect:
```
create_node type=CharacterBody2D name=Player parent=World
create_node type=CollisionShape2D name=Col parent=World/Player
# size: describe_class class=RectangleShape2D → 'size' (Vector2, FULL width/height).
# Mint the SIZED shape as a .tres, then attach it — set_property can't path-walk into a resource.
create_resource class=RectangleShape2D properties={"size":[32,48]} path=res://shapes/player_col.tres
set_resource target=World/Player/Col property=shape resource=res://shapes/player_col.tres
```
Shape classes: `RectangleShape2D` (`size`), `CircleShape2D` (`radius`), `CapsuleShape2D` (`radius`,`height`,`mid_height`), `WorldBoundaryShape2D`, `SegmentShape2D`, `ConcavePolygonShape2D` (**static-only**). **No `extents` anywhere in Godot 4** — `RectangleShape2D.size` is full width/height (half-extents in 3.x). The 3→4 converter renames `extents`→`size` but KEEPS the number, halving the shape — **double it manually**. `CapsuleShape2D.height` is the FULL height incl. semicircles (must be ≥ `2*radius`); `mid_height` is the central segment.

## Collision layers/masks (bitmasks)
- `collision_layer` = layers this object IS ON; `collision_mask` = layers it SCANS. Interact iff `(A.collision_mask & B.collision_layer) != 0`. Matching layers but forgetting the **mask** is the classic no-collision bug.
- Bits: layer 1=`1`, layer 2=`2`, layer 3=`4`, layers 1+3=`5`. Prefer the editor-matching helpers `set_collision_layer_value(n, true)` / `set_collision_mask_value(n, true)` (+ `get_*_value`) where **n is the 1-based layer number (1..32)**, not the bit. Name layers in Project Settings → Layer Names → 2D Physics.

## KinematicCollision2D — getter METHODS, not properties
Godot 4 reads collision data via methods (NOT 3.x `collision.normal`): `get_normal()`, `get_position()`, `get_travel()`, `get_remainder()`, `get_collider()`, `get_collider_velocity()`, `get_depth()`, `get_angle(up_direction=Vector2(0,-1))`. Obtain via `get_slide_collision(i)`, `get_last_slide_collision()`, or `move_and_collide()`.

## move_and_collide / queries
- `PhysicsBody2D.move_and_collide(motion, test_only=false, safe_margin=0.08, recovery_as_collision=false) -> KinematicCollision2D`. **CRITICAL contrast:** `move_and_collide` needs the FULL motion (`velocity * delta`) — it does NOT apply delta, unlike `move_and_slide()`. Bounce: `velocity = velocity.bounce(col.get_normal())`. `test_move(transform, motion, ...)` checks without moving.
- `ShapeCast2D` (4.0) sweeps a `shape` along `target_position` and returns MULTIPLE indexed hits: `get_collision_count()`, `get_collider(i)`, `get_collision_point(i)`, `get_collision_normal(i)`, `is_colliding()`, `get_closest_collision_safe_fraction()`. `collide_with_areas` defaults **false**. Call `force_shapecast_update()` for same-frame queries (wide beams, floor snapping, ledge detection).
- `RayCast2D`: single hit; `target_position` is **LOCAL**, `collide_with_areas` defaults false, `force_raycast_update()` after moving mid-frame. Code-only: `get_world_2d().direct_space_state.intersect_ray(PhysicsRayQueryParameters2D)`.

## Required setup
- RigidBody2D contact signals / `get_colliding_bodies()`: **`contact_monitor=true` AND `max_contacts_reported>0`**.
- Area2D detection: `monitoring=true` (to detect) AND its `collision_mask` includes the other's `collision_layer`; for `area_entered`, the other area's `monitorable=true` (both default true).
- Gravity source: `ProjectSettings physics/2d/default_gravity` (980) / `default_gravity_vector` (`(0,1)`); read net via `PhysicsBody2D.get_gravity()` (4.3+) or `ProjectSettings.get_setting(...)`. Tick: `physics/common/physics_ticks_per_second` (60). Area2D can override a region: `gravity_space_override` (SpaceOverride: DISABLED/COMBINE/COMBINE_REPLACE/REPLACE/REPLACE_COMBINE), `gravity_direction` (renamed from 3.x `gravity_vec`), `gravity`, `gravity_point`+`gravity_point_center`/`gravity_point_unit_distance`, `linear_damp`/`angular_damp`.

## Recipe — CharacterBody2D platformer (walk + jump + project gravity)
```
create_node type=CharacterBody2D name=Player parent=World
create_node type=CollisionShape2D name=Col parent=World/Player
create_resource class=RectangleShape2D properties={"size":[32,48]} path=res://shapes/player_col.tres
set_resource target=World/Player/Col property=shape resource=res://shapes/player_col.tres
write_script path=res://player.gd content="extends CharacterBody2D
@export var speed := 220.0
@export var jump := -380.0
func _physics_process(delta):
    velocity += get_gravity() * delta          # 4.3+: respects project + Area2D zones
    var dir := Input.get_axis(\"ui_left\", \"ui_right\")
    velocity.x = dir * speed
    if Input.is_action_just_pressed(\"ui_accept\") and is_on_floor():
        velocity.y = jump
    move_and_slide()                            # no args, velocity already units/sec
"
attach_script target=World/Player path=res://player.gd
play_scene → simulate_input (move/jump) → assert_node_state on is_on_floor / velocity
```

## Recipe — bouncing RigidBody2D + contact signal
```
create_node type=RigidBody2D name=Ball parent=World
create_node type=CollisionShape2D name=BallCol parent=World/Ball
set_resource target=World/Ball/BallCol property=shape class=CircleShape2D   # default radius is fine here
create_resource class=PhysicsMaterial properties={"bounce":0.8} path=res://shapes/bouncy.tres
set_resource target=World/Ball property=physics_material_override resource=res://shapes/bouncy.tres
set_property target=World/Ball property=contact_monitor value=true     # required
set_property target=World/Ball property=max_contacts_reported value=4  # required (>0)
connect_signal from=World/Ball signal=body_entered ...              # needs both props above
```

## Common traps
- **`move_and_slide()` takes no args** — set `.velocity` first; do NOT multiply final velocity by delta (it's units/second). Only multiply gravity/acceleration terms. `move_and_collide(motion)` is the opposite — pass full `velocity * delta`.
- `is_on_floor()`/etc. are valid ONLY after `move_and_slide()` and need `up_direction`; always false in `MOTION_MODE_FLOATING`. Slope/stair jitter → raise `floor_snap_length`, keep `floor_stop_on_slope=true`.
- **Never scale a CollisionShape2D / collider node** — edit the Shape2D resource's `size`/`radius` instead; scaling distorts the physics shape and glitches.
- RigidBody2D contact signals/`get_colliding_bodies()` silently no-op without `contact_monitor=true` + `max_contacts_reported>0`.
- RigidBody2D: never write `position`/`transform` every frame (fights the solver, jitters) — use forces/impulses, or `freeze`+`FREEZE_MODE_KINEMATIC`. `apply_force` accumulates only for the current step; call it each `_physics_process`.
- Area2D `get_overlapping_bodies()`/entered signals update on the **physics step** — the list can be empty/stale the same frame a body enters; defer reads one physics frame.
- `apply_force(force)` ≠ whole-body force — that's `apply_central_force(force)`; `apply_force` adds a `position` offset (torque). Same for `apply_impulse` vs `apply_central_impulse`.
- ShapeCast2D/RayCast2D ignore Area2D unless `collide_with_areas=true`; both need `force_*_update()` after moving them within a frame.
- 2D vs 3D: different classes (`RectangleShape2D` vs `BoxShape3D`), and **2D `up_direction` defaults to `(0,-1)`** while 3D defaults to `(0,1,0)`; default gravity 980 (2D) vs 9.8 (3D).

Confirm exact class, property, and method names with `describe_class` / `find_methods` (and `get_godot_version`) before relying on them — APIs shift between Godot versions.
