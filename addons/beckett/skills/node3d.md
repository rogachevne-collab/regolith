# 3D fundamentals — Node3D, meshes, materials, cameras, lights, environment

> Spatial transforms, mesh rendering, PBR materials, cameras, lights, WorldEnvironment, CharacterBody3D movement, CSG blockouts. Y is UP, forward is local **-Z**.

## Coordinate system (memorize)
Right-handed, **Y up**, **forward = local -Z** (-X is left). Cameras, lights, and `look_at` all aim down -Z. `rotation` is in **RADIANS** (use `rotation_degrees` for degrees, or `deg_to_rad()`).

## Node3D — base of every 3D node
Properties: `position` (Vector3), `rotation` (Vector3, **radians**), `rotation_degrees` (Vector3), `scale` (Vector3, default (1,1,1)), `quaternion` (Quaternion), `basis` (Basis — rotation+scale; columns `basis.x/y/z` are local axes), `transform` (Transform3D), `global_transform` (Transform3D), `global_position` (Vector3), `top_level` (bool), `visible` (bool).
Methods: `look_at(target: Vector3, up := Vector3(0,1,0), use_model_front := false)` (added 4.1), `look_at_from_position(position, target, up, use_model_front)`, `rotate(axis, angle)`, `rotate_object_local(axis, angle)`, `rotate_x/y/z(angle)`, `translate(offset)`, `translate_object_local(offset)`, `global_translate(offset)`, `to_local(p)`, `to_global(p)`, `orthonormalize()`, `is_visible_in_tree()`. Signal: `visibility_changed`.

## MeshInstance3D — renders geometry
`mesh` (Mesh), `material_override` (Material — replaces ALL surfaces), `material_overlay` (Material — drawn on top), `cast_shadow` (ShadowCastingSetting: 0 OFF, 1 ON, 2 DOUBLE_SIDED, 3 SHADOWS_ONLY), `skeleton` (NodePath, default `NodePath("")`).
Methods: `set_surface_override_material(surface: int, material: Material)`, `get_active_material(surface: int) -> Material`, `get_surface_override_material_count() -> int`, `create_trimesh_collision()` (STATIC concave only), `create_convex_collision(clean := true, simplify := false)`.

## PrimitiveMesh resources (assign to MeshInstance3D.mesh)
- `BoxMesh`: `size` (Vector3, (1,1,1)). `SphereMesh`: `radius` (0.5), `height` (1.0), `radial_segments` (64), `rings` (32), `is_hemisphere` (bool).
- `PlaneMesh`: `size` (Vector2, (2,2)), `orientation` (FACE_X=0, **FACE_Y=1 default** ground plane, FACE_Z=2 vertical). `QuadMesh` = PlaneMesh defaulting FACE_Z, size (1,1).
- `CapsuleMesh`: `radius` (0.5), `height` (2.0) — height must be ≥ 2·radius. `CylinderMesh`: `top_radius` (0.5), `bottom_radius` (0.5), `height` (2.0) — set a radius to 0 for a cone.
- Shared: `material` (Material), `flip_faces` (bool). **`PrimitiveMesh.material` is shared by every instance using that mesh** — for per-instance use `material_override` / `set_surface_override_material`.

## StandardMaterial3D (extends BaseMaterial3D) — PBR
`albedo_color` (Color, (1,1,1,1)), `metallic` (0.0), `roughness` (1.0), `emission_enabled` (bool), `emission` (Color), `emission_energy_multiplier` (1.0), `normal_enabled` (bool) + `normal_texture`, `transparency` (Transparency enum), `cull_mode` (CullMode), `shading_mode` (ShadingMode), `uv1_scale` (Vector3).
- Transparency enum: DISABLED=0 (default), ALPHA=1, ALPHA_SCISSOR=2, ALPHA_HASH=3, ALPHA_DEPTH_PRE_PASS=4. **Albedo alpha < 1 does nothing unless `transparency` is non-DISABLED.**
- CullMode: CULL_BACK=0, CULL_FRONT=1, CULL_DISABLED=2 (both faces). ShadingMode: UNSHADED=0 (ignores lights, flat color), PER_PIXEL=1 (default), PER_VERTEX=2.

## Camera3D — looks down its local -Z
`current` (bool — make active), `projection` (PERSPECTIVE=0, ORTHOGONAL=1, FRUSTUM=2), `fov` (75.0, vertical degrees), `size` (orthogonal), `near` (0.05), `far` (4000.0), `keep_aspect` (KEEP_WIDTH=0, KEEP_HEIGHT=1 default), `cull_mask` (int), `environment` (Environment).
Methods: `make_current()`, `is_current()`, `project_ray_origin(screen: Vector2)`, `project_ray_normal(screen: Vector2)`, `unproject_position(world: Vector3) -> Vector2`, `is_position_behind(world: Vector3) -> bool`.

## Lights (Light3D base) — shadows OFF by default
Shared: `light_color` (Color), `light_energy` (1.0), `light_specular` (1.0), `shadow_enabled` (**bool, default false — set true for shadows**), `shadow_bias` (0.1), `light_bake_mode` (DISABLED=0, STATIC=1, DYNAMIC=2 default).
- `DirectionalLight3D`: aims down local -Z (position irrelevant); `directional_shadow_mode` (ORTHOGONAL=0, PARALLEL_2_SPLITS=1, PARALLEL_4_SPLITS=2 default), `directional_shadow_max_distance` (100.0), `sky_mode`.
- `OmniLight3D`: `omni_range` (5.0), `omni_attenuation` (1.0), `omni_shadow_mode` (DUAL_PARABOLOID=0, CUBE=1 default).
- `SpotLight3D`: `spot_range` (5.0), `spot_angle` (45.0, **stored in degrees**), `spot_attenuation` (1.0).
- `AreaLight3D` **(4.7+)**: rectangular **area light** for soft shadows/reflections. `area_size` (Vector2 — rect W×H), `area_range` (float), `area_attenuation` (float), `area_texture` (Texture2D — projected), `area_normalize_energy` (bool). Inherits Light3D (`light_color`/`light_energy`/`shadow_enabled` — shadows off by default). Forward+ renderer.
- `omni_range`/`spot_range`/`spot_angle` are NOT affected by Node3D scale.

## WorldEnvironment + Environment
`WorldEnvironment.environment` (Environment). Only ONE active WorldEnvironment per tree (a second warns).
`Environment`: `background_mode` (BGMode: CLEAR_COLOR=0, COLOR=1, **SKY=2**, CANVAS=3, KEEP=4, CAMERA_FEED=5), `background_color` (Color), `sky` (Sky), `ambient_light_source` (AmbientSource: BG=0, DISABLED=1, COLOR=2, **SKY=3**), `ambient_light_color` (Color), `ambient_light_energy` (1.0), `tonemap_mode` (ToneMapper), `glow_enabled` (bool), `fog_enabled` / `ssao_enabled` / `sdfgi_enabled` (bool).
ToneMapper: LINEAR=0 (default), **REINHARDT=1**, FILMIC=2, ACES=3, **AGX=4 (added 4.4)**.

## Version note
- Server runs on **4.6.2** (baseline 4.3+). Check `get_godot_version`.
- Godot 3→4: `Spatial`→`Node3D`, `KinematicBody3D`→`CharacterBody3D`, `Camera`→`Camera3D`, `SpatialMaterial`→`StandardMaterial3D`; all 3D nodes gained the `3D` suffix.
- **`CharacterBody3D.move_and_slide()`** (4.0): takes **NO arguments**, reads the `.velocity` property, returns `bool`. Godot 3's `move_and_slide(velocity, ...)` is gone.
- `Node3D.look_at` `use_model_front` param added in **4.1**.
- Environment **AGX tonemapper added in 4.4** (NOT 4.3; 4.3 enum stops at ACES=3).
- CSG `bake_static_mesh()` / `bake_collision_shape()` added in **4.4**.
- **`AreaLight3D` is new in 4.7** (rectangular area light) — `create_node AreaLight3D` works on 4.7+ only; guard with `get_godot_version`. 3D `GPUParticles3D` gained per-particle scale/rotation in 4.7 (see the particles3d skill).

## CharacterBody3D — kinematic movement
`velocity` (Vector3 — set before calling `move_and_slide()`; **units/second, do NOT multiply by delta**), `up_direction` (Vector3, (0,1,0)), `motion_mode` (GROUNDED=0, FLOATING=1), `floor_max_angle` (≈0.785 rad = 45°, **radians**), `floor_snap_length` (0.1).
Methods: `move_and_slide() -> bool`, `is_on_floor()`, `is_on_wall()`, `is_on_ceiling()`, `get_floor_normal()`, `get_slide_collision_count()`, `get_slide_collision(i) -> KinematicCollision3D`. **Requires a CollisionShape3D child** and runs in `_physics_process(delta)`.

## CSGShape3D family — prototyping blockouts
`CSGBox3D` (`size`), `CSGSphere3D` (`radius`), `CSGCylinder3D` (`radius`, `height`, `cone` bool — single radius, NOT top/bottom), `CSGTorus3D`, `CSGPolygon3D`, `CSGCombiner3D`. Shared: `operation` (UNION=0, INTERSECTION=1, SUBTRACTION=2), `use_collision` (bool, false). **Only the ROOT CSG node performs the boolean op**; set `use_collision=true` on the root. `bake_static_mesh()` (4.4) for shipping.

## Required setup
A visible 3D scene needs, at minimum: a `Camera3D` set `current`, at least one light (or ambient via WorldEnvironment), and a MeshInstance3D/CSG to render. No autoload required. Physical light units only apply when ProjectSettings `rendering/lights_and_shadows/use_physical_light_units` is on. Forward+ renderer (default) supports SDFGI/SSIL/volumetric fog; Compatibility renderer lacks several.

## Recipe — lit, colored cube with PBR material
```
create_node type=MeshInstance3D name=Cube parent=<root>
set_resource target=Cube property=mesh class=BoxMesh
set_property target=Cube/mesh property=size value=[2,2,2]
set_property target=Cube property=position value=[0,1,0]      # Y up
set_resource target=Cube property=material_override class=StandardMaterial3D
set_property target=Cube/material_override property=albedo_color value=[0.2,0.6,1.0,1.0]
set_property target=Cube/material_override property=roughness value=0.4
```

## Recipe — viewable scene (camera + sun + sky ambient)
```
create_node type=Camera3D name=Camera3D parent=<root>
set_property target=Camera3D property=position value=[4,3,6]
set_property target=Camera3D property=current value=true
call_method target=Camera3D method=look_at args=[[0,0,0],[0,1,0]]   # after it's in tree
create_node type=DirectionalLight3D name=Sun parent=<root>
set_property target=Sun property=rotation_degrees value=[-50,-30,0]
set_property target=Sun property=shadow_enabled value=true
create_node type=WorldEnvironment name=WorldEnvironment parent=<root>
set_resource target=WorldEnvironment property=environment class=Environment
set_property target=WorldEnvironment/environment property=background_mode value=2   # BG_SKY
set_resource target=WorldEnvironment/environment property=sky class=Sky
set_resource target=WorldEnvironment/environment/sky property=sky_material class=ProceduralSkyMaterial
set_property target=WorldEnvironment/environment property=ambient_light_source value=3   # SKY
```

## Recipe — CharacterBody3D player (gravity + WASD)
```
create_node type=CharacterBody3D name=Player parent=<root>
create_node type=CollisionShape3D name=Col parent=Player
set_resource target=Player/Col property=shape class=CapsuleShape3D
write_script path=res://player.gd content="extends CharacterBody3D
const SPEED := 5.0
var gravity := 9.8
func _physics_process(delta):
	if not is_on_floor():
		velocity.y -= gravity * delta
	var dir := Input.get_vector(\"ui_left\",\"ui_right\",\"ui_up\",\"ui_down\")
	velocity.x = dir.x * SPEED
	velocity.z = dir.y * SPEED
	move_and_slide()   # no args, no *delta
"
attach_script target=Player path=res://player.gd
```

## Common traps
- `move_and_slide()` takes **no args** in Godot 4; set `.velocity` first and do NOT multiply by delta (units/second). It returns a bool.
- CharacterBody3D passes through everything without a **CollisionShape3D** child; set `up_direction` so `is_on_floor()` works.
- Albedo alpha < 1 renders opaque unless `transparency` is non-DISABLED. Emission glow needs `Environment.glow_enabled=true` too.
- Shadows are **off** on every light by default — set `shadow_enabled=true`. No lights + ambient disabled = black scene (except UNSHADED materials).
- Nothing renders unless a Camera3D is `current` (set `current=true` or `make_current()`).
- `look_at()` needs the node **inside the tree** (valid `global_transform`, i.e. at/after `_ready`); target ≠ position and `up` not parallel to look dir. Use `look_at_from_position()` to aim before entering the tree.
- `rotation` / `floor_max_angle` / `wall_min_slide_angle` are **radians** (`deg_to_rad()`); but `SpotLight3D.spot_angle` is stored in degrees.
- `CSGCylinder3D` uses a single `radius` + `cone` bool — `top_radius`/`bottom_radius` belong to `CylinderMesh`, not CSG.
- Repeated per-frame transform composition drifts/skews the basis — call `orthonormalize()` (loses scale; scale a child instead). Avoid driving Euler `rotation` for continuous gameplay (gimbal lock) — prefer `quaternion.slerp()` or `look_at`.
- `create_trimesh_collision()` is STATIC concave only (not for moving bodies) — use `create_convex_collision()` for dynamic bodies.

Confirm exact class, property, and method names with `describe_class` (and `get_godot_version`) before relying on them — APIs shift between Godot versions.
