# Particles — GPU/CPU particle effects (2D & 3D)

> GPUParticles2D/3D + ParticleProcessMaterial, or self-contained CPUParticles2D/3D. Drive with create_node + set_resource + set_property. GPU = material-based + needs a Forward+/Mobile renderer; CPU = props on the node, runs anywhere.

## Version note
- Server runs **4.6.2** (baseline 4.3+). Check `get_godot_version` / `describe_class`.
- **GPU particles need a Forward+ or Mobile renderer.** The **GL Compatibility** renderer has limited/no GPU-particle support — fall back to `CPUParticles2D/3D` there. `CPUParticles2D/3D.convert_from_particles(gpu_node)` copies a GPU setup to CPU.
- The 4.x parameter model uses **min/max RANGE pairs** (a redesign of Godot 3's value + random_deviation). Setting only one of `*_min`/`*_max` yields a fixed value — this is why nearly every parameter is doubled.
- **`amount_ratio` + `interp_to_end`** (node-level): added **4.2**. **Turbulence** + **sub-emitters**: **4.2**. Deterministic **`seed` / `use_fixed_seed` / `restart(keep_seed)` / `request_particles_process()`**: **4.3**. Many ParticleProcessMaterial velocity/scale params: **4.3** (see below).

## Nodes
- `GPUParticles2D` / `GPUParticles3D` — need a `process_material` (`ParticleProcessMaterial` or ShaderMaterial). 2D draws a `texture`; **3D has NO `texture`** — it draws meshes via `draw_pass_1` (see 3D setup).
- `CPUParticles2D` / `CPUParticles3D` — same look, all properties live directly on the node (no material). Simplest for quick effects; **no turbulence, no sub-emitters, no attractors/collision nodes** (GPU-only features).

## GPUParticles2D/3D — node-level properties (NOT on the material)
`amount` (int, default 8), `lifetime` (sec), `emitting` (bool), `one_shot` (bool), `explosiveness` (0–1), `randomness`, `preprocess`, `speed_scale`, `local_coords`, `fixed_fps`, `process_material` (ParticleProcessMaterial).
- **`amount_ratio`** (float, default 1.0, [4.2]) — emit a fraction of `amount` without reallocating buffers; ideal for runtime intensity control.
- **`interp_to_end`** (float, default 0.0, [4.2]) — interpolate all live particles toward end-of-life.
- **`seed`** (int) + **`use_fixed_seed`** (bool, default false) [4.3] — reproducible playback; without `use_fixed_seed` each restart re-randomizes. `restart(keep_seed := false)` and `request_particles_process(process_time)` [4.3] for seekable/preprocessed playback.
- **2D-only:** `texture` (Texture2D). **3D-only:** `draw_pass_1`..`draw_pass_4` (Mesh), `draw_passes` (int, default 1), `transform_align`, `collision_base_size`.
- **`draw_order` differs by node:** 2D default `DRAW_ORDER_LIFETIME`=1, enum INDEX=0/LIFETIME=1/REVERSE_LIFETIME=2 (no view-depth). 3D default `DRAW_ORDER_INDEX`=0 and **adds** `DRAW_ORDER_VIEW_DEPTH`=3 (sort by camera distance for correct transparency).

## ParticleProcessMaterial — key properties (set after assigning it; GPU only)
`direction` (Vector3, e.g. `[0,-1,0]` for up in 2D where +Y is down), `spread` (deg), `initial_velocity_min`/`max`, `gravity` (Vector3, e.g. `[0,98,0]` in 2D / `[0,-9.8,0]` in 3D), `scale_min`/`scale_max`, `color` (Color), `color_ramp` (a **Texture2D** — use `GradientTexture1D`), `angular_velocity_min`/`max`, `damping_min`/`max`.
- **`emission_shape`** enum (`ParticleProcessMaterial.EmissionShape`): **POINT=0, SPHERE=1, SPHERE_SURFACE=2, BOX=3, POINTS=4, DIRECTED_POINTS=5, RING=6.** A box is **3**, not 2 (2 is a sphere *surface*). Box uses **`emission_box_extents`** (Vector3). [4.3] `emission_shape_offset`/`emission_shape_scale` (Vector3) reposition/resize the shape.
- **Velocity/scale (added 4.3):** `radial_velocity_min`/`max` (+`radial_velocity_curve`), `directional_velocity_min`/`max` (+curve), `scale_over_velocity_min`/`max` (+curve), `velocity_pivot` (Vector3), `velocity_limit_curve`. The Parameter enum grew to **PARAM_MAX=18** (CPUParticles stop at **PARAM_MAX=12**).
- **Curves/gradients are Texture2D here:** `color_ramp`→`GradientTexture1D`; per-life curves (`scale_curve`, `*_velocity_curve`, [4.3] `emission_curve`, `alpha_curve`)→`CurveTexture` / `CurveXYZTexture`. **CPUParticles use raw `Gradient` / `Curve` resources instead** — the `set_resource class=` differs (see below).

## Turbulence (GPU only, [4.2])
`turbulence_enabled` (bool), `turbulence_noise_strength`, `turbulence_noise_scale`, `turbulence_noise_speed` (Vector3), `turbulence_influence_min`/`max`, `turbulence_influence_over_life` (Texture2D). Great for smoke/fire/dust swirl; raises GPU cost. CPUParticles have none.

## Sub-emitters (GPU only, [4.2])
Set the parent node's **`sub_emitter`** NodePath to a second particle node, then on the material set **`sub_emitter_mode`** (`SUB_EMITTER_DISABLED=0/CONSTANT=1/AT_END=2/AT_COLLISION=3/AT_START=4`) and `sub_emitter_amount_at_start`/`at_end`/`at_collision` or `sub_emitter_frequency`. Enables sparks→spawn-trails, fireworks bursts. CPUParticles have no sub-emitter.

## Attractors & collision (3D + GPU only)
Ignored by CPUParticles and by 2D. Add as sibling nodes near the particles:
- **Attractors:** `GPUParticlesAttractorSphere3D`/`Box3D`/`VectorField3D` (`strength`, `attenuation`, `directionality`, `cull_mask`). Require the material's **`attractor_interaction_enabled=true`**; node `cull_mask` must overlap the particles' visibility layers.
- **Collision:** `GPUParticlesCollisionBox3D`/`Sphere3D`/`SDF3D`/`HeightField3D`. Require material **`collision_mode`** = `COLLISION_RIGID`(1) or `COLLISION_HIDE_ON_CONTACT`(2) (0=DISABLED) **and** a non-zero **`collision_base_size`** on the particle node. **Default `collision_base_size` is 1.0 on GPUParticles2D but 0.01 on GPUParticles3D** — near-zero in 3D effectively disables visible collision until raised. (2D "collision" is a separate mechanism via `LightOccluder2D` SDF, not PhysicsBody2D.)

## CPUParticles2D/3D — properties live on the node
`amount`, `lifetime`, `emitting`, `one_shot`, `explosiveness`, `direction`, `spread`, `gravity`, `initial_velocity_min`/`max`, **`scale_amount_min`/`max`** (NOT `scale_min/max` — that name is GPU-only), `color`, `color_ramp` (a **`Gradient`** resource, not GradientTexture1D), `*_curve` (raw **`Curve`** resources). `emission_shape` enum exists but **CPUParticles2D uses `EMISSION_SHAPE_RECTANGLE`(3) with `emission_rect_extents` (Vector2)** where GPU 3D uses `EMISSION_SHAPE_BOX`(3) with `emission_box_extents` (Vector3) — same ordinal, different property name and type. `draw_order` here is only INDEX=0/LIFETIME=1.

## Recipe — fire (GPU 2D)
```
create_node type=GPUParticles2D name=Fire parent=<root>
set_resource target=Fire property=process_material class=ParticleProcessMaterial
set_property target=Fire property=amount value=48
set_property target=Fire property=lifetime value=0.8
set_property target=Fire property=texture value=<res://flame.png>          # 2D needs a texture
set_property target=Fire/process_material property=direction value=[0,-1,0]
set_property target=Fire/process_material property=initial_velocity_min value=30
set_property target=Fire/process_material property=initial_velocity_max value=60
set_resource target=Fire/process_material property=color_ramp class=GradientTexture1D
set_property target=Fire property=emitting value=true
```
If dotted material paths aren't supported, `set_resource` the material, then `describe_class class=ParticleProcessMaterial` to confirm names and set on the resolved resource.

## Recipe — GPU 3D billboard particles (NO texture — needs a mesh)
```
create_node type=GPUParticles3D name=Sparks parent=<root>
set_resource target=Sparks property=process_material class=ParticleProcessMaterial
set_resource target=Sparks property=draw_pass_1 class=QuadMesh           # 3D draws meshes, not a texture
set_property target=Sparks property=transform_align value=1              # Z_BILLBOARD faces camera
set_property target=Sparks/process_material property=gravity value=[0,-9.8,0]
set_property target=Sparks property=emitting value=true
```

## Recipe — one-shot burst that frees itself
```
create_node type=GPUParticles2D name=Pop parent=<root>
set_resource target=Pop property=process_material class=ParticleProcessMaterial
set_property target=Pop property=one_shot value=true
set_property target=Pop property=explosiveness value=1.0                 # all at once
connect_signal from=Pop signal=finished ...                           # fires ONLY for one_shot when all particles end → queue_free
set_property target=Pop property=emitting value=true
```
`finished()` fires only on `one_shot` emitters when every particle completes — perfect for auto-freeing a burst; do NOT rely on it for continuous emitters (never fires).

## Tips
- Smoke: low velocity, slight upward `gravity`, large `scale_max`, grey→transparent `color_ramp`, add turbulence (GPU).
- Rain/snow: downward `gravity`, narrow `spread`, wide emission area — **GPU 3D:** `emission_shape=BOX(3)` + `emission_box_extents`; **CPU 2D:** `emission_shape=RECTANGLE(3)` + `emission_rect_extents`.
- Runtime intensity: animate `amount_ratio` (0..1) instead of `amount` (no buffer realloc).
- Quick start with no material/renderer worries: `CPUParticles2D` + `gravity`, `initial_velocity_min/max`, `scale_amount_min/max`, `color` directly.

## Common traps
- **`emission_shape=2` is SPHERE_SURFACE, not Box.** Box=3. Mixing these silently emits the wrong shape.
- **GPUParticles3D has no `texture`** — setting it does nothing; you must set `draw_pass_1` to a Mesh (with `draw_passes>=1`) or nothing renders.
- **GPU vs CPU property names differ:** material `scale_min/max` vs node `scale_amount_min/max`; `color_ramp` is a `GradientTexture1D` (GPU) vs a `Gradient` (CPU); curves are `CurveTexture` (GPU) vs `Curve` (CPU). Pick the right `set_resource class=`.
- **GL Compatibility renderer:** GPU particles barely work — use CPUParticles or switch to Forward+/Mobile.
- **3D collision/attractors do nothing** unless the material flag (`collision_mode` / `attractor_interaction_enabled`) is set, `collision_base_size` is raised above its 0.01 3D default, and `cull_mask` layers overlap. These are 3D + GPU only.
- **2D +Y is down:** gravity up is negative Y, gravity down is `[0,98,0]`; 3D up is +Y.
- Half-set range = fixed value: set both `*_min` and `*_max` for randomness.
- Transparency sorting wrong in 3D → set `draw_order=DRAW_ORDER_VIEW_DEPTH` (3D only).

Confirm exact class, property, method, and enum names — and which version added them — with `describe_class` / `find_methods` (and `get_godot_version`) before relying on them; particle APIs gained many members across 4.2–4.3 and differ between GPU and CPU.
