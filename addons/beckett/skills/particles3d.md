# GPU particles 3D — GPUParticles3D, attractors, collision

> GPU-simulated 3D particles: a `GPUParticles3D` node + a `ParticleProcessMaterial` for behavior + a draw-pass `Mesh` to be visible. Attractor/collision nodes are separate scene nodes that only act when the material enables them.

## Version note
- Server runs **4.6.2** (baseline 4.3+). Check `get_godot_version`; confirm names with `describe_class`.
- **Godot 4.0**: the whole GPU attractor + collision node family (`GPUParticlesAttractorBox3D/Sphere3D/VectorField3D`, `GPUParticlesCollisionBox3D/Sphere3D/SDF3D/HeightField3D`), plus `turbulence_*`, trails, and sub-emitters, is new. Not in Godot 3.x. `ParticleProcessMaterial` was renamed from 3.x `ParticlesMaterial`.
- **Godot 4.2**: `GPUParticles3D.amount_ratio`, `GPUParticles3D.interp_to_end`; `ParticleProcessMaterial` `radial_velocity_*`, `directional_velocity_*`, `scale_over_velocity_*`, `emission_shape_offset`, `emission_shape_scale`, `particle_flag_damping_as_friction` (and `PARAM_RADIAL_VELOCITY`/`DIRECTIONAL_VELOCITY`/`SCALE_OVER_VELOCITY`).
- **Godot 4.4**: `GPUParticles3D.seed`/`use_fixed_seed` and `restart(keep_seed)` / `request_particles_process()` (absent in 4.2 and 4.3). `CPUParticles3D` also gained `seed`/`use_fixed_seed` and `restart(keep_seed)` around 4.4 — verify on the live server.
- **Godot 4.7**: per-particle **3D scale & rotation** on `ParticleProcessMaterial` — `use_scale_3d` + `scale_3d_min`/`scale_3d_max` (non-uniform per-axis scale), `use_rotation_3d` + `rotation_3d_min`/`rotation_3d_max`, `use_rotation_velocity_3d` + `rotation_velocity_3d_min`/`_max`/`rotation_velocity_3d_curve`, and `particle_flag_inherit_emitter_scale`. `GPUParticles3D` gained `transform_align_axis` + `transform_align_channel_filter`. All **4.7+** — guard with `get_godot_version` (on ≤4.6 only uniform `scale_min`/`scale_max` + 2D-plane `angle`/`angular_velocity` exist).
- **Renderer**: GPU particles, attractors, collision, and trails require **Forward+ or Mobile**; they do **not** work in the Compatibility (GLES3) renderer — use `CPUParticles3D` there.
- **2D vs 3D**: attractor and `GPUParticlesCollision*` nodes are **3D-only** (attractors are not implemented for 2D). 2D uses `GPUParticles2D` (same `ParticleProcessMaterial` class).

## Required setup
- **`draw_pass_1` MUST be a `Mesh`** or particles are completely invisible. Use a `QuadMesh` billboard or a real mesh.
- **`process_material` must be a `ParticleProcessMaterial`** — without it particles have no velocity/shape/gravity behavior.
- For the material's `color`/`color_ramp` to show, the draw-pass mesh's `StandardMaterial3D` needs `vertex_color_use_as_albedo = true` (and `billboard_mode = BILLBOARD_PARTICLES` for billboards).
- Attractor effect requires BOTH an attractor node AND the material's `attractor_interaction_enabled = true` (default true) AND overlapping visual layers (`cull_mask`) AND overlap with `visibility_aabb`.
- Collision requires the material's `collision_mode` set to RIGID/HIDE_ON_CONTACT AND a collision node AND `visibility_aabb` overlap.

## GPUParticles3D (extends GeometryInstance3D < VisualInstance3D < Node3D)
Props: `emitting` (bool, true), `amount` (int, 8 — changing resets the system), `amount_ratio` (float, 1.0; 0..1 cheap throttle, 4.2+), `lifetime` (float, 1.0), `one_shot` (bool, false), `explosiveness` (float, 0.0; 1=burst), `randomness` (float, 0.0), `preprocess` (float, 0.0 sec pre-simulated), `speed_scale` (float, 1.0), `fixed_fps` (int, 30; raise vs thin colliders), `interpolate` (bool, true), `collision_base_size` (float, 0.01 — particle collision radius), `visibility_aabb` (AABB, `AABB(-4,-4,-4,8,8,8)` — must overlap attractors/colliders), `local_coords` (bool, false), `draw_order` (DrawOrder, INDEX=0), `transform_align` (TransformAlign, DISABLED=0), `trail_enabled` (bool, false), `trail_lifetime` (float, 0.3), `process_material` (Material, null), `draw_passes` (int, 1; 1..4), `draw_pass_1..4` (Mesh, null), `sub_emitter` (NodePath), `interp_to_end` (float, 0.0; 4.2+).
Methods: `restart(keep_seed := false)` (param 4.4+), `emit_particle(xform: Transform3D, velocity: Vector3, color: Color, custom: Color, flags: int)`, `capture_aabb() -> AABB`, `convert_from_particles(particles: Node)`, `set_draw_pass_mesh(pass: int, mesh: Mesh)`, `get_draw_pass_mesh(pass: int) -> Mesh`. Signal: `finished()` (fires when a `one_shot` burst completes).
Enums: DrawOrder {INDEX=0, LIFETIME=1, REVERSE_LIFETIME=2, VIEW_DEPTH=3}. TransformAlign {DISABLED=0, Z_BILLBOARD=1, Y_TO_VELOCITY=2, Z_BILLBOARD_Y_TO_VELOCITY=3}. EmitFlags (bitmask for `emit_particle`) {POSITION=1, ROTATION_SCALE=2, VELOCITY=4, COLOR=8, CUSTOM=16}.

## ParticleProcessMaterial (extends Material < Resource) — assign to `process_material`
Props: `direction` (Vector3, (1,0,0)), `spread` (float, 45.0 deg), `flatness` (float, 0.0), `gravity` (Vector3, (0,-9.8,0); set (0,0,0) for smoke/space), `initial_velocity_min`/`initial_velocity_max` (float, **0.0 — leave at 0 and particles barely move**), `angle_min/max`, `angular_velocity_min/max`, `linear_accel_min/max`, `radial_accel_min/max` (push from/to center), `tangential_accel_min/max` (orbital), `damping_min/max`, `scale_min`/`scale_max` (float, 1.0), `color` (Color, (1,1,1,1)), `color_ramp` (Texture2D — over lifetime), `color_initial_ramp` (Texture2D), `hue_variation_min/max`, `emission_shape` (EmissionShape, POINT=0), `emission_sphere_radius`, `emission_box_extents` (Vector3, **half-size**), `turbulence_enabled` (bool, false), `turbulence_noise_strength` (1.0), `turbulence_noise_scale` (9.0), `collision_mode` (CollisionMode, DISABLED=0), `collision_friction`, `collision_bounce`, `collision_use_scale` (bool, false), `sub_emitter_mode` (SubEmitterMode, DISABLED=0), `attractor_interaction_enabled` (bool, **true**), `particle_flag_align_y/rotate_y/disable_z` (bool, false).
Methods: `set_param_min(param: Parameter, value: float)`, `set_param_max(param, value)`, `get_param_min/max`, `set_param_texture(param: Parameter, texture: Texture2D)` (CurveTexture/CurveXYZTexture for over-lifetime control).
Enums: EmissionShape {POINT=0, SPHERE=1, SPHERE_SURFACE=2, BOX=3, POINTS=4, DIRECTED_POINTS=5, RING=6}. CollisionMode {DISABLED=0, **RIGID=1**, **HIDE_ON_CONTACT=2**}. SubEmitterMode {DISABLED=0, CONSTANT=1, AT_END=2, AT_COLLISION=3, AT_START=4}. Parameter {INITIAL_LINEAR_VELOCITY=0, ANGULAR_VELOCITY=1, ORBIT_VELOCITY=2, LINEAR_ACCEL=3, RADIAL_ACCEL=4, TANGENTIAL_ACCEL=5, DAMPING=6, ANGLE=7, SCALE=8, HUE_VARIATION=9, ANIM_SPEED=10, ANIM_OFFSET=11, ...}.

## Attractor nodes (extend GPUParticlesAttractor3D < VisualInstance3D, all 4.0+)
Shared props: `strength` (float, 1.0; positive=attract, **negative=repel**), `attenuation` (float, 1.0; falloff exponent, zero outside region), `directionality` (float, 0.0; 0=pull to center, 1=push along the node's local **-Z** — rotate to aim a "wind"), `cull_mask` (int, all 20 layers — matched against the particle system's visual layers).
- `GPUParticlesAttractorBox3D`: `size` (Vector3, (2,2,2) — full size).
- `GPUParticlesAttractorSphere3D`: `radius` (float, 1.0; non-uniform node scale → ellipsoid).
- `GPUParticlesAttractorVectorField3D`: `size` (Vector3, (2,2,2)), `texture` (Texture3D, null — RGB encodes a direction+strength vector per cell; keep low-res, e.g. 64³).

## Collision nodes (extend GPUParticlesCollision3D < VisualInstance3D, all 4.0+)
Shared prop: `cull_mask` (int — matched against the particle system's visual layers). Particles only collide if the material's `collision_mode` is RIGID or HIDE_ON_CONTACT.
- `GPUParticlesCollisionBox3D`: `size` (Vector3, (2,2,2)). `GPUParticlesCollisionSphere3D`: `radius` (float, 1.0). Both real-time movable, no baking.
- `GPUParticlesCollisionHeightField3D`: `size`, `resolution` (Resolution, RESOLUTION_1024=2; range 256..8192), `update_mode` (UPDATE_MODE_WHEN_MOVED=0, ALWAYS=1), `follow_camera_enabled` (bool, false), `heightfield_mask` (int). Live updates, **no baking**; cannot represent overhangs/tunnels.
- `GPUParticlesCollisionSDF3D`: `size`, `resolution` (Resolution, RESOLUTION_64=2; range 16..512), `texture` (Texture3D, null — the baked SDF), `thickness` (float, 1.0), `bake_mask` (int). Methods `set_bake_mask_value(layer, value)`, `get_bake_mask_value(layer)`. **Baking is EDITOR-ONLY** ("Bake SDF" toolbar button) — there is NO `bake()`/`bake_begin()`/`bake_end()` method or signal. An MCP agent cannot bake an SDF; only assign a pre-baked `Texture3D` to `texture`, or have a human click Bake SDF. For agent-driven scenes prefer Box/Sphere/HeightField.

## CPUParticles3D fallback (extends GeometryInstance3D < VisualInstance3D)
For the Compatibility renderer / low-end GPUs. **No `process_material`** — all params live on the node. `mesh` (Mesh, single render mesh; no multi-pass). Shares `emitting`/`amount`/`lifetime`/`one_shot`/`explosiveness`/etc. **Different name: `scale_amount_min`/`scale_amount_max`** (vs the material's `scale_min/max`). `convert_from_particles(particles: Node)` copies from a GPUParticles3D but does NOT carry attractors, collision nodes, turbulence, sub-emitters, or extra draw passes. **Does NOT support attractor nodes, GPU collision nodes, turbulence, or sub-emitters.**

## Recipe — minimal VISIBLE fountain (do this first)
```
get_godot_version                                   # confirm 4.x + Forward+/Mobile renderer
create_node type=GPUParticles3D name=Fountain parent=<root>
set_resource target=Fountain property=draw_pass_1 class=QuadMesh        # REQUIRED or invisible
set_resource target=Fountain property=process_material class=ParticleProcessMaterial
set_property target=Fountain property=amount value=200
set_property target=Fountain property=lifetime value=2.0
set_property target=Fountain/process_material property=direction value=[0,1,0]
set_property target=Fountain/process_material property=spread value=20.0
set_property target=Fountain/process_material property=initial_velocity_min value=4.0
set_property target=Fountain/process_material property=initial_velocity_max value=6.0   # without velocity it only falls
play_scene
screenshot
assert_node_state target=Fountain property=emitting equals=true
```

## Recipe — sphere attractor (vortex / push)
```
create_node type=GPUParticlesAttractorSphere3D name=Pull parent=<root>
set_property target=Pull property=radius value=3.0
set_property target=Pull property=strength value=8.0          # negative (-8.0) repels instead
set_property target=Pull property=attenuation value=1.0
set_property target=Pull property=directionality value=0.0    # 1.0 + rotate node = directional wind
# enabling check: material default attractor_interaction_enabled is true
monitor_properties path=Fountain/process_material property=attractor_interaction_enabled
# if no effect: expand Fountain.visibility_aabb (e.g. [-8,-8,-8,16,16,16]) and confirm cull_mask shares a layer
play_scene
screenshot
```

## Recipe — bounce off a floor box (no bake)
```
set_property target=Fountain/process_material property=collision_mode value=1   # 1=RIGID (2=HIDE_ON_CONTACT)
set_property target=Fountain/process_material property=collision_bounce value=0.5
set_property target=Fountain/process_material property=collision_friction value=0.2
create_node type=GPUParticlesCollisionBox3D name=Floor parent=<root>
set_property target=Floor property=size value=[10,0.5,10]
set_property target=Floor property=position value=[0,-2,0]      # below emitter, inside visibility_aabb
set_property target=Fountain property=fixed_fps value=60        # anti-tunneling for fast particles
play_scene
screenshot
```

## Common traps
- **Invisible particles (#1):** `draw_pass_1` is empty. The `process_material` does not make particles visible — assign a `QuadMesh`/mesh.
- **No motion:** `initial_velocity_min/max` default to 0.0, so particles only fall under gravity. Set velocity and/or accelerations.
- **Attractor does nothing:** needs the node AND `attractor_interaction_enabled = true` AND overlapping `cull_mask` layers AND overlap with `visibility_aabb`. No warning when any is missing.
- **Collision does nothing:** the material's `collision_mode` is still DISABLED (0) — set RIGID (1) or HIDE_ON_CONTACT (2). Collider must also overlap `visibility_aabb`.
- **Fast particles tunnel through thin colliders:** raise `fixed_fps` (60–120), increase `collision_base_size`, and/or the SDF collider's `thickness`.
- **SDF bake is editor-only:** no scriptable bake exists in any 4.x. Assign a pre-baked `Texture3D`, or prefer Box/Sphere/HeightField for programmatic scenes.
- **Material color not showing:** the draw-pass mesh's `StandardMaterial3D` needs `vertex_color_use_as_albedo = true` (and `billboard_mode = BILLBOARD_PARTICLES`).
- **Trails need special meshes:** with `trail_enabled = true`, `draw_pass_1` must be a `RibbonTrailMesh` (flat) or `TubeTrailMesh` (volume, set `transform_align = Y_TO_VELOCITY=2` or tubes flatten); the trail mesh's material must enable "Use Particle Trails".
- **Compatibility renderer:** GPU particles/attractors/collision/trails don't work — switch to `CPUParticles3D` (loses attractors/collision/turbulence).
- **`one_shot` re-trigger:** the burst plays once; call `restart()` or toggle `emitting` false→true, and listen to `finished()`.
- **Box `size` vs legacy "Extents":** current class refs use `size` (full dimensions) for Box attractor/collision but `emission_box_extents` (half-size) on the material. Confirm exact semantics with `describe_class` on the target build.
- **CPUParticles3D scale name differs:** `scale_amount_min/max`, not the material's `scale_min/max` — don't assume identical names when converting.

Confirm exact class, property, and method names (and the live property defaults, e.g. Box `size` vs `extents`) with `describe_class` / `find_methods` and `get_godot_version` before relying on them — APIs shift between Godot versions.
