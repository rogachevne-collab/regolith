# Physics 3D — bodies, shapes, collision layers, queries

> CharacterBody3D / RigidBody3D / StaticBody3D / Area3D + a CollisionShape3D. Mind move_and_slide()'s 4.x signature and apply gravity yourself.

## Version note
- **`move_and_slide()` takes NO arguments in Godot 4** (Godot 3 was `move_and_slide(velocity, up)`). `velocity` is now a property; **gravity is no longer auto-applied** — do `velocity.y -= gravity * delta` yourself.
- **`AnimatableBody3D`** (4.0) split from StaticBody3D for moving platforms that carry/push bodies (uses `sync_to_physics`); Godot 3's `KinematicBody3D` became `CharacterBody3D`.
- **`ShapeCast3D`** introduced in 4.0; `PhysicsBody3D.get_gravity()` (net gravity incl. Area3D overrides) added in 4.3.
- **Jolt Physics** became a built-in alternative in **4.4** (`physics/3d/physics_engine`); in **4.6** new projects **default to Jolt**. Confirm with `get_godot_version` (server runs 4.6.2) / `describe_class`.

## Body types
- `CharacterBody3D` — code-driven. Set `velocity` (Vector3), then call `move_and_slide()` once in `_physics_process(delta)`. Helpers: `is_on_floor()`, `is_on_wall()`, `is_on_ceiling()`, `get_floor_normal()`, `get_slide_collision_count()`, `get_slide_collision(i)`, `get_real_velocity()`. Needs `up_direction` (default `(0,1,0)`) set for floor/slope logic. `motion_mode`: `MOTION_MODE_GROUNDED=0` / `MOTION_MODE_FLOATING=1`.
- `RigidBody3D` — physics-simulated. Push via `apply_central_impulse(vec)`, `apply_impulse(vec, pos)`, `apply_central_force(vec)`, `apply_torque(vec)`. Props: `mass`, `gravity_scale`, `linear_velocity`, `angular_velocity`, `linear_damp`, `freeze`+`freeze_mode` (`FREEZE_MODE_KINEMATIC=1` for scripted motion that still pushes others), `continuous_cd` (anti-tunneling).
- `StaticBody3D` — immovable world geometry; the ONLY 3D body that may use concave/trimesh shapes. `constant_linear_velocity` pushes touching bodies (conveyor) without moving.
- `AnimatableBody3D` — moving platforms (`sync_to_physics`).
- `Area3D` — overlap detection / gravity-damp zones (no collision response). Signals `body_entered(body)`, `area_entered(area)`; `get_overlapping_bodies()`.

## Collision shape (required)
Every body/Area3D needs a `CollisionShape3D` (direct child) with a `shape` Resource, or it won't collide/detect:
```
create_node type=CharacterBody3D name=Player parent=World
create_node type=CollisionShape3D name=Col parent=World/Player
# size: describe_class class=CapsuleShape3D → radius (float, 0.5), height (float, 2.0; must be >= 2*radius).
# Mint the SIZED shape as a .tres, then attach it — set_property can't path-walk into a resource.
create_resource class=CapsuleShape3D properties={"radius":0.5,"height":2.0} path=res://shapes/player_col.tres
set_resource target=World/Player/Col property=shape resource=res://shapes/player_col.tres
```
Shape classes: `BoxShape3D` (`size` Vector3), `SphereShape3D` (`radius`), `CapsuleShape3D` (`radius`,`height`), `CylinderShape3D`, `ConvexPolygonShape3D` (`points`; movers), `ConcavePolygonShape3D` (`backface_collision`; trimesh **static-only**, set geometry via `set_faces(PackedVector3Array)`), `WorldBoundaryShape3D` (`plane`; static-only). Generate hulls with `Mesh.create_convex_shape()` (movers) / `Mesh.create_trimesh_shape()` (static).

## Collision layers/masks (bitmasks)
- `collision_layer` = layers this object IS ON; `collision_mask` = layers it SCANS. Interact iff `(A.collision_mask & B.collision_layer) != 0`.
- Bits: layer 1=`1`, layer 2=`2`, layer 3=`4`. Prefer `set_collision_layer_value(n, true)` / `set_collision_mask_value(n, true)` where **n is the 1-based layer number (1..32)**, not the bit value.

## Required setup
- RigidBody3D `body_entered`/`body_exited` need **`contact_monitor=true` AND `max_contacts_reported>0`** (e.g. 4); same for `get_contact_count()`/`get_colliding_bodies()`.
- Area3D needs `monitoring=true` and its `collision_mask` must include the other object's `collision_layer`; for `area_entered`, the other area's `monitorable=true`.
- Gravity source: `ProjectSettings physics/3d/default_gravity` (9.8) / `default_gravity_vector` (`(0,-1,0)`); read via `PhysicsBody3D.get_gravity()` or `ProjectSettings.get_setting(...)`. Physics tick: `physics/common/physics_ticks_per_second` (60).

## Recipe — CharacterBody3D player (walk + jump + gravity)
```
create_node type=CharacterBody3D name=Player parent=World
create_node type=CollisionShape3D name=Col parent=World/Player
set_resource target=World/Player/Col property=shape class=CapsuleShape3D   # default-sized capsule
write_script path=res://player.gd content="extends CharacterBody3D
const SPEED := 5.0
const JUMP := 4.5
var gravity: float = ProjectSettings.get_setting(\"physics/3d/default_gravity\")
func _physics_process(delta):
    if not is_on_floor():
        velocity.y -= gravity * delta
    if Input.is_action_just_pressed(\"ui_accept\") and is_on_floor():
        velocity.y = JUMP
    var iv := Input.get_vector(\"ui_left\",\"ui_right\",\"ui_up\",\"ui_down\")
    var dir := (transform.basis * Vector3(iv.x, 0, iv.y)).normalized()
    velocity.x = dir.x * SPEED
    velocity.z = dir.z * SPEED
    move_and_slide()"
attach_script target=World/Player path=res://player.gd
set_property target=World/Player property=floor_snap_length value=0.3
play_scene → simulate_input (jump/move) → assert_node_state on is_on_floor / velocity
```

## Recipe — bouncing ball + contact signal
```
create_node type=RigidBody3D name=Ball parent=World
create_node type=CollisionShape3D name=BallCol parent=World/Ball
set_resource target=World/Ball/BallCol property=shape class=SphereShape3D   # default radius is fine here
create_resource class=PhysicsMaterial properties={"bounce":0.8} path=res://shapes/bouncy.tres
set_resource target=World/Ball property=physics_material_override resource=res://shapes/bouncy.tres
set_property target=World/Ball property=contact_monitor value=true
set_property target=World/Ball property=max_contacts_reported value=4
connect_signal from=World/Ball signal=body_entered ...   # needs both props above
```

## Queries — RayCast3D / ShapeCast3D
- `RayCast3D`: `target_position` (Vector3, **LOCAL** space, default `(0,-1,0)`), `enabled`, `collision_mask`, `collide_with_bodies` (true), `collide_with_areas` (**false** — set true to hit Area3D). Read `is_colliding()`, `get_collider()`, `get_collision_point()` (global), `get_collision_normal()`. Updates once per physics tick — call `force_raycast_update()` after moving it mid-frame.
- `ShapeCast3D`: sweeps a `shape` along `target_position`; `get_collision_count()`, `get_collider(i)`, `get_closest_collision_safe_fraction()` (position a spring-arm just short of a wall). `force_shapecast_update()`.
- Code-only ray: `get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D)`.

## Common traps
- **Don't** multiply final `velocity` by `delta` before `move_and_slide()` — it applies delta internally; only multiply gravity/acceleration terms. (`move_and_collide(motion)` is the opposite: pass the full delta-scaled displacement.)
- `is_on_floor()`/etc. are only valid AFTER `move_and_slide()` and need `up_direction`; always `false` in `MOTION_MODE_FLOATING`. Flickering on slopes/stairs → raise `floor_snap_length` (0.3–0.5), keep `floor_stop_on_slope=true`.
- RigidBody3D: never write `position`/`global_transform` every frame (fights the solver, jitters) — use forces/impulses, or `freeze` + `FREEZE_MODE_KINEMATIC`. Apply forces in `_physics_process`/`_integrate_forces`; `apply_force` accumulates only for the current step.
- Concave/trimesh & WorldBoundaryShape3D are **static-only** — a moving RigidBody3D/CharacterBody3D using one tunnels or misbehaves; use convex/primitives for movers.
- Area3D/RigidBody3D entered signals are NOT reliable on the first frame after entering the tree — wait one physics frame or poll `get_overlapping_bodies()`/`get_colliding_bodies()`.
- Matching layers but forgetting the **mask** is the classic no-collision bug.
- 2D vs 3D: different classes (`BoxShape3D` vs `RectangleShape2D`), and 3D `up_direction` defaults to `(0,1,0)` while 2D defaults to `(0,-1)`.

Always confirm exact class names, property types, and method signatures with `describe_class` / `find_methods` before relying on them — names differ subtly across versions and between Godot Physics and Jolt.
