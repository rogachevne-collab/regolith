# Renderer tuning - pick the right pipeline and spend frame budget where it shows

> Godot 4 ships three renderers (Forward+, Mobile, Compatibility) and a stack of per-project quality dials: AA, 3D resolution scaling (FSR), shadows, and screen-space/global-illumination effects. Tune by MEASURING (`get_performance_monitors` `duration_s` stats; playtest perf asserts lock results in) - the expensive effects are opt-out, not opt-in, on a template project. Sibling packs: `occlusion-visibility-performance` (submission), `lighting2d`, `shaders`, `mobile`.

## Version note
- Server runs **4.6.2**. Renderer names + settings paths are stable across 4.x; FSR2 upscaling is **4.3+**, TAA is 3D-only. The renderer is picked by `rendering/renderer/rendering_method` (`forward_plus` | `mobile` | `gl_compatibility`) and **needs an editor restart** after change. Confirm current values with `get_project_setting` and availability with `get_godot_version`.

## Renderer choice (the biggest single decision)
- **Forward+** - desktop default: clustered lighting (many lights cheap), full effect set (SDFGI, SSR, SSIL, volumetric fog).
- **Mobile** - phones/quest + weaker desktops: cheaper per-pixel cost, but no SDFGI/SSR/SSIL and lights are per-object limited (`rendering/limits/opengl/max_lights_per_object` class of limits).
- **Compatibility (gl_compatibility)** - old GPUs + web: OpenGL path, fewest features, most reach.
- Per-platform override: most `rendering/*` settings accept `.mobile` / `.web` suffixed overrides in project.godot (`set_project_setting` with e.g. `rendering/renderer/rendering_method.mobile`).

## Resolution scaling (3D) - the best fps-per-quality lever
- `rendering/scaling_3d/scale` (0.25..2.0): render 3D at 0.77, UI stays native-crisp.
- `rendering/scaling_3d/mode`: `bilinear` | `fsr` (spatial FSR 1.0) | `fsr2` (temporal, 4.3+, better but costlier; set `scaling_3d/fsr_sharpness` to taste).

## Anti-aliasing (cost order, cheap -> expensive)
- `rendering/anti_aliasing/quality/screen_space_aa` = FXAA: near-free, slightly blurry.
- TAA `use_taa`: good on Forward+, adds ghosting on fast motion; combine with FSR2 = redundant (FSR2 already temporal).
- MSAA `msaa_3d` (2x/4x/8x): geometry edges only (not specular/shader aliasing), real GPU + video-mem cost; `msaa_2d` exists separately for canvas.

## Shadows
- Directional: `rendering/lights_and_shadows/directional_shadow/size` (+ `soft_shadow_filter_quality`); PSSM `directional_split_count` 4->2 is a big win on weak GPUs.
- Point/spot: shared `positional_shadow/atlas_size` + quadrant subdivision - many shadowed lights fight for the atlas; drop per-light `shadow_enabled` before dropping atlas size.

## Global illumination + screen-space effects (Forward+ costs)
- `Environment` toggles, roughly cheap -> expensive: SSAO -> SSIL -> SSR -> volumetric fog -> **SDFGI** (dynamic GI, the single heaviest switch). Baked `LightmapGI` gives GI at near-zero runtime cost for static scenes; `VoxelGI` sits between.
- Half-resolution toggles exist for the SS effects (`rendering/environment/ssao/half_size` etc.) - visually minor, large savings.
- Glow: `Environment.glow_enabled` + fewer `glow_levels` on mobile.

## The measure loop (what "tuned" means here)
```
get_performance_monitors target=game duration_s=5        # fps/frame stats + video_mem + draw_calls
set_project_setting setting=rendering/scaling_3d/scale value=0.77
# play again (renderer-method changes need a restart; most quality dials apply live)
get_performance_monitors target=game duration_s=5        # compare p95 fps, video_mem_used
```
Gate it forever: playtest suite assert `{"type":"perf","metric":"fps_min","min":55}` on your heaviest scene (`playtest` pack).

## Common traps
- **Changing `rendering_method` does nothing until restart** - and silently falls back (Forward+ -> Mobile on unsupported GPUs); read the boot log, do not assume.
- **Effects cost even when invisible.** SDFGI/SSR enabled on an Environment burn budget in scenes with no visible benefit; audit the WorldEnvironment of every level.
- **`video_mem_used` creep** usually means oversized textures, not effects - check import sizes before dropping quality dials (`get_performance_monitors` exposes `texture_mem`).
- **TAA + FSR2 together** double-pay temporal cost; pick one.
- **Tuning in the editor viewport measures the editor.** Editor overlays + gizmos change cost; only `target=game` numbers count, ideally p95 over a stress window, not a menu screen.
- **Mobile renderer is not "Forward+ but slower"** - features are ABSENT (SDFGI/SSR/SSIL); design lighting around baked `LightmapGI` there from day one.

Confirm class, property, and method names with `describe_class` (e.g. `class=Environment`, `class=Viewport`, `class=LightmapGI`) and settings with `get_project_setting` before relying on them.
