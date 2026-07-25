# Voxel Tools — шпаргалка для агентов

Плагин: **Voxel Tools 1.6x** (Zylann), GDExtension `addons/zylann.voxel/`.
Проектный контракт scale/raycast/spawn — `docs/specs/INDUSTRY-V1.md` § *Voxel scale (v1)*.
Код-обёртка — `scripts/simulation/runtime/voxel_space_util.gd`.

## Перед правками — обязательно

1. Прочитай **этот файл** и § *Voxel scale* в `INDUSTRY-V1.md`.
2. Сверь затронутый API с **официальной докой** (ссылки ниже) — не выводи
   контракт координат из существующего кода или «логики Godot».
3. При scale ≠ 1, raycast, collider lag, streaming — поищи **GitHub issues**
   `zylann/godot_voxel` (WebSearch / issues).
4. Верифицируй в **запущенной игре**: spawn, прицел, бур, проекция строительства.
   Headless-тесты не ловят смещение aim при неверном raycast.

## Официальные источники

| Что | URL |
|-----|-----|
| Документация | https://voxel-tools.readthedocs.io/en/latest/ |
| Smooth terrain | https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/ |
| Texturing (INDICES / SINGLE_S4) | https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/#voxel-texture-formats |
| `VoxelTool` API | https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/ |
| `VoxelTool.raycast` | https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/#raycast |
| Репозиторий / issues | https://github.com/Zylann/godot_voxel |

Рудные зоны / `CHANNEL_INDICES` / yield — контракт
`docs/specs/TERRAIN-MATERIALS-V1.md` (не выводить материал из shader).

## Visual mesh blocks (world RT)

Patched `Y:\godot_voxel` exposes on `VoxelLodTerrain` (rebuild
`libvoxel.windows.editor.double.x86_64.dll`):

- `get_mesh_block_surface(block_pos, lod) -> Array` (surface arrays + CUSTOM0)
- `get_meshed_block_positions_at_lod(lod) -> Array[Vector3i]` —
  **visual_active only** (GDScript binding; C++ Instancer path unchanged)
- `mesh_block_local_origin(block_pos, lod) -> Vector3`
- `get_mesh_block_transition_mask(block_pos, lod) -> int` — shader-space
  `u_transition_mask` (bake must apply `get_transvoxel_position` or RT ≠ visual)
- signals `mesh_block_visual_changed` / `mesh_block_visual_removed`
  (changed on remesh, activate, **and transition-mask updates**; removed on deactivate)
- `get_mesh_visual_topology_revision() -> int` + signal
  `mesh_block_visual_topology_committed(revision)` — emitted **once at the end**
  of a complete `apply_main_thread_update_tasks()` that had visual
  activate/deactivate/drop/unload/transition work, **and** at end of
  `process()` after coalesced dig/edit remeshes (`apply_mesh_update` on
  visual_active blocks). Per-block signals are mid-transaction dirty hints
  (LOD0 children can fire before LOD1 parents); they are **not** snapshot
  boundaries. Drop/unload may lack removed signals — the post-commit active
  snapshot covers that.

Consumer: `scripts/rendering/world_rt_geometry.gd` (versioned staging +
double-buffered TLAS, no `convert_to_nodes`). Pipeline:

1. On topology commit (or coalesced remesh dirty): capture full
   `visual_active` snapshot LOD0..MAX_RT_LOD inside `RAY_SPAN`, exact
   Transvoxel bake (CUSTOM0 + transition mask).
2. Per-block dig/remesh dirty keys are **evicted from committed immediately**
   (hole/CSM beats a phantom RT lid). Never reuse BLAS for dirty keys.
   Empty Transvoxel extracts are omitted (not whole-candidate reject).
3. Reuse committed BLAS by `key + content_hash`; budget-build the rest.
   Stale jobs carry a staging generation and cannot publish.
4. Publish only when every staged entry is READY and the candidate has
   **no parent/child active overlap** (reject/retry).
5. Build the inactive TLAS from that one snapshot, `set_world_tlas`, flip
   active index; keep old committed live until swap. Retire unique old
   bundles after `RenderingDevice.get_frame_delay()` frames.

Raw mesh buffers are **not** the shaded surface — Transvoxel secondary verts
+ inactive-transition cull live in the vertex shader. Inactive LOD shells
must never enter TLAS. Physics colliders stay too coarse for RT shadows.

Engine spawn (custom Godot `scene_forward_clustered.glsl`): RT Gems Ch.6
`offset_ray` + face-normal terminator (dFdx/dFdy Ng, Hanika-lite). Rebuild via
`.\tools\build_godot_double.ps1` after editing that shader. Do not remove the
terminator — it is not the LOD-swap fix.

## Проектные инварианты (кратко)

- **Voxel size:** uniform `scale` на `VoxelTerrain` / `VoxelLodTerrain`
  (сейчас **1.0** = 1 м; канон `MoonGeometry.VOXEL_SCALE`); отдельного
  `voxel_size` на узле нет — при scale ≠ 1 это официальный workaround плагина.
- **`VoxelTool.raycast`:** origin, direction, max_distance — **Godot world space**.
  Плагин сам учитывает transform terrain. World hit = `origin + dir * hit.distance`.
  **Не** делать ручной `world_to_local` для raycast при scale ≠ 1 — двойная
  трансформация смещает hit к origin terrain (симптом: бур/проекция «к игроку»).
- **SDF edits** (`do_sphere`, `do_path`, …): координаты в **local space** terrain
  (`VoxelSpaceUtil.world_to_local`).
- **Scale ≠ 1:** SDF surface Y может быть **выше** mesh/physics collider.
  - Посадка (spawn, base, ground seat): `resolve_ground_surface_y` — physics Y,
    SDF fallback.
  - Прицел на terrain: **physics raycast** (collider); SDF — только если collider
    ещё нет.
- **`generate_collisions = true`** на `VoxelTerrain` в `main.tscn` — обязателен для
  physics aim и ground anchor.
- **Spawn:** SDF gate для streaming + physics/settle (`bootstrap.gd`); не ждать
  полной готовности collider секундами — `begin_spawn_settle` находит пол.

## Известные грабли (issues / опыт)

| Тема | Где смотреть |
|------|----------------|
| Scale на узле terrain | GitHub #232 |
| Raycast offset от integer origins | GitHub #136 (epsilon ~0.1) |
| Collider отстаёт от SDF при edits | GitHub #677; aim — physics, edit — SDF local |
| `max_view_distance` vs `VoxelViewer` | terrain должен поднять clamp, иначе блоки не грузятся |
| Floating islands после dig | `VoxelToolLodTerrain.separate_floating_chunks` (~30³); обёртка `TerrainFloatingDebrisService` / INDUSTRY-V1 § Floating |

## Файлы проекта

| Область | Файлы |
|---------|--------|
| Координаты / raycast | `voxel_space_util.gd` |
| Spawn / settle | `bootstrap.gd` |
| Прицел / drill hit | `interaction_query.gd` |
| Вырезка SDF | `terrain_excavation_service.gd`, `terrain_impact_carver.gd` |
| Floating debris | `terrain_floating_debris_service.gd` ← gateway post-dig |
| Yield по материалу | `terrain_material_source.gd` → канон `TERRAIN-MATERIALS-V1.md` |
| Ground seat строительства | `world_command_gateway.gd` |
| Bench scale | `bench_voxel_scale.gd`, `scenes/bench_voxel_scale.tscn` |

## Анти-паттерны

- ❌ `world_to_local` перед `VoxelTool.raycast` «потому что terrain scaled»
- ❌ Vertical physics probe на XZ от **ошибочного** SDF hit (усиливает смещение aim)
- ❌ Блокировать spawn 30+ с «ожиданием collider» вместо settle
- ❌ Менять `set_sdf_scale` вручную без доки (#677)
- ❌ Headless-тест как единственная проверка aim/drill HUD
