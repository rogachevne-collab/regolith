# Viewmodel RT shadows (DrillVisual)

Vulkan ray-tracing visibility mask for the hand drill viewmodel. Raster
Forward+ still provides albedo/PBR; RT only darkens self-shadowed texels.

## Requirements

- Custom Godot **precision=double** build with Vulkan RT plumbing (≥ PR
  [#99119](https://github.com/godotengine/godot/pull/99119)).
- Pinned engine hash (probe on this machine): `a7625b44947c98a83a589f29484b978293940179`
  (`4.8.dev.double.custom_build`).
- Windows/Linux + RT-capable GPU (AMD/Intel/NVIDIA). macOS / no RT → soft-disable.

Rebuild if probe fails:

```powershell
.\tools\build_godot_double.ps1
```

## Probe

```powershell
.\run.ps1 res://scenes/test_viewmodel_rt_probe.tscn --quit-after 5
```

Expect `SUPPORTS_RAYTRACING_PIPELINE=true` and `hello_triangle=true`.

Headless has no `RenderingDevice` — use the probe scene with a display.

## In-game

1. `./run.ps1` → main scene, drill equipped.
2. Console: `viewmodel_rt 1` (default on) / `viewmodel_rt 0` for CSM-only A/B.
3. Debug mask overlay: `viewmodel_rt debug` (drill pixels show sun visibility as greyscale).
3. Rotate toward sun — handle shadows on body should sharpen vs CSM mush.
4. Toggle **MiningLight** (mining) — local self-shadows in `G` mask channel.
5. Mine with spinning bit — TLAS updates per frame (body + bit instances).

Earthshine is **not** ray-traced (fill only).

## Architecture

| File | Role |
|------|------|
| `scripts/rendering/viewmodel_rt_shadows.gd` | Capability gate, BLAS bake, TLAS instance transforms (camera-relative float32), light buffer, `cast_shadow` override |
| `scripts/rendering/viewmodel_rt_composite_effect.gd` | `CompositorEffect` POST_TRANSPARENT: trace + multiply color buffer |
| `shaders/rt/viewmodel_shadow.glsl` | Raygen/miss/hit — 1 shadow ray per sun + MiningLight, mask `R=sun G=lamp B=drill` |
| `resources/rendering/viewmodel_rt_compositor.tres` | Assigned to `Camera3D.compositor` in `scenes/player.tscn` |

Patterns adapted from [Fahien/godot-raytracing-gdscript-demo](https://github.com/Fahien/godot-raytracing-gdscript-demo) (MIT).

## Gotchas (cost a debugging session each)

- A `Compositor` attaches to `WorldEnvironment.compositor` or
  `Camera3D.compositor` — **not** to the `Environment` resource. Assigning it in
  an `.tres` Environment fails silently: `_render_callback` never fires.
- `gl_HitTriangleVertexPositionsEXT` needs `GL_EXT_ray_tracing_position_fetch`
  and BLAS data-access flags. Avoided: closest-hit returns only `gl_HitTEXT` and
  the shadow origin is pulled back along the view ray instead of along a normal.
- `.glsl` edits are not picked up by a plain run — the compiled SPIR-V is cached.
  Run `godot --headless --import` after every shader edit.
- Freeing the per-frame TLAS also destroys any uniform set referencing it, so the
  set must be recreated, never freed again.
- Free BLAS scratch RIDs derived-first: `vertex_array` before `vertex_buffer`.

## CSM coexistence

The RT pass only has the drill in its TLAS, so it can never know about world
occluders. Division of labour while RT is active:

- Drill meshes get `cast_shadow = OFF` → they leave the shadow map, which is
  what kills the CSM self-shadow mush.
- Drill meshes still **receive** CSM → cave walls, rover and terrain darken the
  viewmodel as before. Do not use `disable_receive_shadows` here: it leaves the
  drill fully sunlit underground.
- RT multiplies in the self-shadow term on top (`R` sun, `G` lamp).

`MiningLight` has no shadow map at all (`shadow_enabled` unset), so lamp
self-shadows exist only via RT.

## Limits (v1)

- Drill viewmodel only (`industrial_drill.glb` under `Camera/DrillVisual`).
- World geometry is absent from the TLAS: RT never casts cave/terrain shadows
  onto the viewmodel — that stays CSM's job.
- No denoiser, no DLSS, no NVIDIA fork.
- No RT on terrain/rover/welder yet (`register_viewmodel_mesh` hook reserved).

## Roadmap

- Half-res mask + upsample
- Soft penumbra (solar angular size)
- Welder + shared `RtLight` buffer
