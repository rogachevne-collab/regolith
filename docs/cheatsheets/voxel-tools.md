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
| `VoxelTool` API | https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/ |
| `VoxelTool.raycast` | https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/#raycast |
| Репозиторий / issues | https://github.com/Zylann/godot_voxel |

## Проектные инварианты (кратко)

- **Voxel size:** uniform `scale` на `VoxelTerrain` (сейчас **0.65**); отдельного
  `voxel_size` на узле нет — это официальный workaround плагина.
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

## Файлы проекта

| Область | Файлы |
|---------|--------|
| Координаты / raycast | `voxel_space_util.gd` |
| Spawn / settle | `bootstrap.gd` |
| Прицел / drill hit | `interaction_query.gd` |
| Вырезка SDF | `terrain_excavation_service.gd`, `terrain_impact_carver.gd` |
| Ground seat строительства | `world_command_gateway.gd` |
| Bench scale | `bench_voxel_scale.gd`, `scenes/bench_voxel_scale.tscn` |

## Анти-паттерны

- ❌ `world_to_local` перед `VoxelTool.raycast` «потому что terrain scaled»
- ❌ Vertical physics probe на XZ от **ошибочного** SDF hit (усиливает смещение aim)
- ❌ Блокировать spawn 30+ с «ожиданием collider» вместо settle
- ❌ Менять `set_sdf_scale` вручную без доки (#677)
- ❌ Headless-тест как единственная проверка aim/drill HUD
