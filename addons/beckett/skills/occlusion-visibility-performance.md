# Occlusion & visibility - cull what the player cannot see

> Rendering cost scales with what is SUBMITTED, not what is visible. Three engine systems cut submission: occlusion culling (hidden-behind-geometry), visibility notifiers/enablers (off-screen logic), and visibility ranges / LOD (distance). Measure before and after with `get_performance_monitors` (`draw_calls`, `render_objects`, `render_primitives`) - never guess. Pairs with the `profiling` workflow and `renderer-tuning`.

## Version note
- Server runs **4.6.2**; everything here exists since **4.0** except where marked. Occlusion culling and visibility ranges are 3D; notifiers exist in 2D and 3D. Confirm availability with `get_godot_version` + `describe_class`.

## Occlusion culling (3D, CPU-side)
1. Enable the project setting `rendering/occlusion_culling/use_occlusion_culling` (`set_project_setting`).
2. Add `OccluderInstance3D` nodes with occluder shapes (Box/Sphere/Quad/Polygon or a baked `ArrayOccluder3D`) on big blockers: walls, terrain, buildings.
3. Bake from the editor (OccluderInstance3D toolbar > Bake Occluders) - baking scans child meshes; `bake_simplification_distance` trades precision for speed.
4. Verify: `get_performance_monitors target=game` while looking AT a wall - `render_objects` should drop vs. the same view with culling off. In-editor: Perspective menu > Display Advanced > Occlusion Culling Buffer to eyeball the depth buffer.
- It culls on the CPU (embree rasterizer): wins are biggest when many objects hide behind few large occluders. Tiny/thin occluders cost more than they save.

## Visibility notifiers & enablers (2D + 3D)
- `VisibleOnScreenNotifier2D/3D` - emits `screen_entered` / `screen_exited`; poll `is_on_screen()`. Drive your own logic (pause AI, stop particles) from these signals.
- `VisibleOnScreenEnabler2D/3D` - the automatic version: set `enable_node_path` and it flips that node's `process_mode` off-screen. Zero code.
- The rect/AABB is checked against the CAMERA, not actual pixels: an object behind a wall but inside the frustum still counts as "on screen" (that is what occlusion culling is for).

## Distance: visibility ranges + LOD (3D)
- Per `GeometryInstance3D`: `visibility_range_begin/end` (+ `_margin`) hide geometry outside a distance band; `visibility_range_fade_mode` cross-fades instead of popping. Build manual HLOD: near mesh 0-30 m, far imposter 30-300 m.
- Automatic mesh LOD comes from the importer (Advanced Import Settings > LODs) and `rendering/mesh_lod/lod_change/threshold_pixels`; force per-instance with `lod_bias`.
- Lights and `Decal`s also have `distance_fade_*` properties - shadows are usually the bigger win: keep `SpotLight3D`/`OmniLight3D` `shadow_enabled` off unless the light needs it.

## Mass instancing
- Hundreds of identical meshes: one `MultiMeshInstance3D` = one draw call. `scatter_nodes` can place scenes, but for pure visual clutter prefer MultiMesh.
- 2D: `CanvasItem` batching is automatic, but thousands of distinct textures break batches - atlas them.

## Measure -> change -> re-measure (the loop this pack exists for)
```
get_performance_monitors target=game duration_s=5   # baseline: draw_calls/fps stats {min,avg,p95,max}
# ... add occluders / enablers / ranges ...
get_performance_monitors target=game duration_s=5   # compare p95, not a single lucky frame
```
Lock the win in as a regression test: a playtest suite with `{"type":"perf","metric":"frame_ms_p95","max":16.7}` (see the `playtest` pack).

## Common traps
- **Occlusion culling silently does nothing until the project setting is on AND occluders are baked.** An `OccluderInstance3D` with no bake data culls nothing.
- **Transparent materials do not occlude.** Windows, foliage cards and anything alpha-blended will not hide what is behind them.
- **Notifier rects are approximate.** `VisibleOnScreenNotifier3D.aabb` defaults small - a mesh larger than its AABB "exits" while still visible. Set the AABB to cover the visual.
- **Enabler disables the TARGET node's processing, not rendering.** The mesh still draws; pair with visibility ranges when you want pixels gone too.
- **Frustum culling is already free.** Do not build manual "hide when behind camera" logic - the engine does it; your job is occlusion (behind things) and distance.
- **Editor numbers lie about game cost.** Always measure `target=game` on a real play session; the editor viewport renders differently.

Confirm class, property, and method names with `describe_class` (e.g. `class=OccluderInstance3D`, `class=GeometryInstance3D`, `class=VisibleOnScreenEnabler3D`) before relying on them.
