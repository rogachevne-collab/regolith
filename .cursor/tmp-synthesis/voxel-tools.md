# Voxel Tools (Zylann) — исследовательский отчёт для Regolith

Контекст: Regolith использует **Voxel Tools 1.6x** (GDExtension `addons/zylann.voxel/`) для лунного SDF-terrain на `VoxelLodTerrain` + Transvoxel, Jolt physics, `VoxelStreamSQLite` для сохранения вырезок. Слой loose material (`GranularPatch`, `GranularSpoil`) — **собственная симуляция проекта**, не часть плагина.

---

## 1. Что такое Voxel Tools — и чего он **не** делает

| Область | Статус в плагине |
|---|---|
| Объёмный terrain (overhangs, пещеры, runtime edit) | ✅ Ядро модуля |
| Smooth SDF + blocky Minecraft-style | ✅ Два режима |
| Streaming + persistence | ✅ `VoxelStream*` |
| LOD на большие дистанции | ✅ `VoxelLodTerrain` + Transvoxel |
| Godot physics (Jolt/Godot Physics) | ✅ Mesh colliders per chunk |
| Foliage/rocks на поверхности | ✅ `VoxelInstancer` |
| **Granular/soil/spoil piles после копания** | ❌ **Нет** |
| **Песок как loose particles / angle of repose** | ❌ **Нет** |
| Автоматический debris при `do_sphere` | ❌ **Нет** |

Официальный disclaimer автора: модуль — «hobbyist experiments», не fits-all решение.  
→ [Документация](https://voxel-tools.readthedocs.io/en/latest/) · [GitHub](https://github.com/Zylann/godot_voxel)

---

## 2. Деформация terrain и копание

### Доступно **сегодня** (1.6x)

Основной API — [`VoxelTool`](https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/), получается через `terrain.get_voxel_tool()`.

**Smooth terrain (SDF, Regolith):**
- `channel = VoxelBuffer.CHANNEL_SDF`
- `mode = MODE_REMOVE` — вырезка; `MODE_ADD` — добавление материи обратно
- **`do_sphere(center, radius)`** — рекомендуемый способ копания (инкрементальный, min/max по SDF)
- **`do_path(points, radii)`** — «труба»/буровой путь (с 1.6 также на `VoxelToolLodTerrain`)
- **`do_box`**, **`do_mesh(VoxelMeshSDF)`** — bulk-операции
- **`grow_sphere`** — постепенное «наращивание/сжатие» SDF; **хрупкий** при `sdf_clip_threshold` в генераторе ([#864](https://github.com/Zylann/godot_voxel/issues/864), [#833](https://github.com/Zylann/godot_voxel/issues/833))
- **`smooth_sphere`** — сглаживание после правок
- **`copy` / `paste` / `paste_masked`** — восстановление/перенос блоков

**Blocky terrain:**
- `channel = VoxelBuffer.CHANNEL_TYPE`, `mode = MODE_SET/REMOVE`
- `VoxelMesherBlocky` + `VoxelBlockyLibrary`

**Ограничения редактирования:**
- Только **загруженные** блоки: `is_area_editable(AABB)`
- На `VoxelLodTerrain` редактируется **только LOD 0** (полное разрешение); LOD>0 — mip-аппроксимация, не для правок ([#316](https://github.com/Zylann/godot_voxel/issues/316))
- Координаты edits — **local space** terrain (Regolith: `VoxelSpaceUtil.world_to_local`)

**Scripting guide:** [voxel-tools.readthedocs.io/en/latest/scripting/](https://voxel-tools.readthedocs.io/en/latest/scripting/)

### Roadmap / community requests

- **`full_load_mode` branch** — загрузка всего LOD0 в радиусе для edit-at-distance ([#316](https://github.com/Zylann/godot_voxel/issues/316)) — эксперимент, не в master
- **`custom_lod_distances` branch** — ручная настройка LOD distances ([#640](https://github.com/Zylann/godot_voxel/issues/640), [#379](https://github.com/Zylann/godot_voxel/issues/379))
- **`dmc2` branch** — Dual Marching Cubes как альтернатива Transvoxel ([#640](https://github.com/Zylann/godot_voxel/issues/640))
- Multipass generation — в master с 1.4+ ([#545](https://github.com/Zylann/godot_voxel/issues/545))

---

## 3. Loose material / spoil piles / debris

### В плагине: **нет granular layer**

Voxel Tools **не создаёт** кучи грунта, песок или debris при удалении voxels. Вырезанный объём просто исчезает из SDF-сетки.

**Ближайшие встроенные механизмы:**

| Механизм | Что делает | Подходит для spoil? |
|---|---|---|
| `separate_floating_chunks(box, parent)` | Отрезает **висящие SDF-острова** → `RigidBody3D` с convex collider | Частично: «обломки скалы», не regolith heap |
| `VoxelInstancer` | Декор (трава, камни) на mesh chunks | Нет: не loose material после dig |
| `do_sphere MODE_ADD` | Вернуть материю в другое место | Можно эмулировать «насыпь» в SDF, но это solid terrain, не granular |

**`separate_floating_chunks`** ([API](https://voxel-tools.readthedocs.io/en/latest/api/VoxelToolLodTerrain/#separate_floating_chunks)):
- Только **`VoxelToolLodTerrain`** (не `VoxelTerrain`)
- Box ~**30 voxels** max (дорого)
- Bodies стартуют kinematic → rigid через паузу
- Regolith уже использует это через `TerrainFloatingDebrisService`
- WIP branch `floating_chunks`: расширение на `VoxelTerrain`, blocky, кастомизация ([#640](https://github.com/Zylann/godot_voxel/issues/640))

**Community / сторонние решения:**
- [Terabase-Studios/Godot-Voxel-Destruction](https://github.com/Terabase-Studios/Godot-Voxel-Destruction) — `.vox` объекты + debris modes; **не terrain**, отдельный addon ([Asset Library](https://godotengine.org/asset-library/asset/3743))
- Форум: debris при разрушении — particles / pre-baked animation, не voxel terrain ([forum #138114](https://forum.godotengine.org/t/making-debris/138114))
- Issue [#647](https://github.com/Zylann/godot_voxel/issues/647): sand/water как **отдельный negated `VoxelTerrain`** — workaround от community, не фича модуля

**Regolith-подход (правильный для lunar sandbox):**
- SDF carve → volume accounting → `GranularSpoil` → deposit на `GranularPatch` (своя CA-симуляция)
- Spec: `docs/specs/GRANULAR-V0.md`
- Это **вне контракта Voxel Tools** — плагин даёт только «дыру в скале»

---

## 4. Smooth vs blocky terrain

| | **Smooth (SDF)** | **Blocky** |
|---|---|---|
| Mesher | `VoxelMesherTransvoxel` | `VoxelMesherBlocky`, `VoxelMesherCubes` |
| Алгоритм | Transvoxel (Marching Cubes + LOD stitching) | Cuboid faces + AO |
| Terrain node | `VoxelLodTerrain` (рекомендуется) или `VoxelTerrain` | Оба |
| Materials | Splat/indices в voxel channels + shader | `VoxelBlockyLibrary` model IDs |
| Physics alt | Mesh colliders (Jolt) | `VoxelBoxMover` (Minecraft-style, быстрее) |
| LOD blocky | Базовая поддержка с 1.3; multi-material на LOD>1 — pending ([#702](https://github.com/Zylann/godot_voxel/issues/702)) | |

**Smooth terrain docs:** [smooth_terrain/](https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/)  
**Blocky docs:** [blocky_terrain/](https://voxel-tools.readthedocs.io/en/latest/blocky_terrain/)

**Regolith:** smooth Transvoxel SDF, `scale = 1.0` м/voxel.

---

## 5. VoxelMesher и LOD

### VoxelMesher (базовый класс)

Наследники: `VoxelMesherTransvoxel`, `VoxelMesherBlocky`, `VoxelMesherCubes`.  
→ [API VoxelMesher](https://voxel-tools.readthedocs.io/en/latest/api/VoxelMesher/)

### VoxelTerrain vs VoxelLodTerrain

| | `VoxelTerrain` | `VoxelLodTerrain` |
|---|---|---|
| Структура | Простая grid of blocks | **Octree LOD** (powers of 2) |
| View distance | Ограничен (~Minecraft scale) | Очень большие дистанции |
| Редактирование | Все loaded blocks | **Только LOD 0** |
| Streaming | Cubic region around viewer | Octree subdivision **или** Clipbox (1.2+) |
| Mesher | Любой | Transvoxel preferred |

**LOD internals** ([issue #213](https://github.com/Zylann/godot_voxel/issues/213), [issue #26](https://github.com/Zylann/godot_voxel/issues/26)):
- Octree subdivides blocks by powers of 2; `lod_split_scale` / `secondary_lod_distance` управляют дистанциями
- Transvoxel stitching + vertex smoothing через `CUSTOM0` attribute
- Distant normalmaps — expensive optional feature
- **Clipbox** streaming (1.2+): concentric boxes, multi-viewer, collision-only viewers; experimental

**Roadmap LOD:**
- Blocky LOD improvements ([#506](https://github.com/Zylann/godot_voxel/issues/506) `blocky_revamp`)
- `custom_lod_distances` branch ([#640](https://github.com/Zylann/godot_voxel/issues/640))
- README roadmap: «Level of detail with blocky voxels» — still WIP

---

## 6. Voxel terrain + physics (Jolt)

Regolith на Godot 4.5+ с **Jolt Physics** — совместимо: плагин использует стандартный `PhysicsServer3D`.

### Два режима физики ([Performance § Physics](https://voxel-tools.readthedocs.io/en/latest/performance/))

1. **Standard Physics (Jolt/Godot Physics):**
   - `generate_collisions = true` на terrain
   - **VoxelViewer** обязателен для генерации colliders
   - Static **concave mesh colliders** per 16³/32³ chunk
   - Создание collider **~3–5× дороже meshing**; defer на main thread (Jolt усугубляет — [#676 comment](https://github.com/Zylann/godot_voxel/issues/676#issuecomment-2236392681))

2. **Box Physics (`VoxelBoxMover`):**
   - Только blocky; Minecraft-style AABB
   - С 1.6: поддержка `VoxelLodTerrain` + `intersects()`
   - Regolith **не использует** (smooth terrain)

### Известные проблемы с Jolt + voxels

| Проблема | Mitigation |
|---|---|
| **Tunnelling** через mesh colliders | CCD, cap speed, длинный raycast ([#676](https://github.com/Zylann/godot_voxel/issues/676), [#677](https://github.com/Zylann/godot_voxel/issues/677)) |
| Collider lag vs SDF после edit | Physics raycast для aim; SDF для edit ([#677](https://github.com/Zylann/godot_voxel/issues/677)) |
| RigidBody падает сквозь terrain при старте | Ждать `is_area_editable` / `is_area_meshed`; `collision_lod_count`; VoxelViewer на body ([#676](https://github.com/Zylann/godot_voxel/issues/676)) |
| Scale ≠ 1: SDF surface выше collider | `resolve_ground_surface_y` pattern (Regolith `bootstrap.gd`) |
| Instancer colliders + Jolt overload | Issue [#756](https://github.com/Zylann/godot_voxel/issues/756): thousands of pebble colliders → fall-through |

**Godot Jolt docs:** [Using Jolt Physics](https://docs.godotengine.org/en/stable/tutorials/physics/using_jolt_physics.html)

---

## 7. Granular / soil features в Voxel Tools

**Ответ: отсутствуют.** Нет:
- particle soil simulation
- sand flow / angle of repose
- moisture/consolidation
- dual-phase solid+loose в одной voxel grid
- automatic volume conservation при dig

Единственное смежное в changelog 1.5:
- `VoxelInstanceLibraryItem.floating_sdf_*` — детекция «плавающих» instancer props после dig (трава/камни), не spoil
- `VoxelInstancer.remove_instances_in_sphere` — удаление декора

---

## 8. GitHub issues и обсуждения: sand, debris, spoil

| Issue | Тема | Вывод |
|---|---|---|
| [#647](https://github.com/Zylann/godot_voxel/issues/647) | Sand/water как отдельный terrain | Workaround community; Zylann: нет планов на «закрытие срезов» mesh |
| [#756](https://github.com/Zylann/godot_voxel/issues/756) | Instancer + dig + Jolt | Grass floats после dig; pebble colliders overload Jolt |
| [#640](https://github.com/Zylann/godot_voxel/issues/640) | `floating_chunks` branch | Улучшения `separate_floating_chunks` |
| [#864](https://github.com/Zylann/godot_voxel/issues/864) | `grow_sphere` artifacts | Prefer `do_sphere`; watch `sdf_clip_threshold` |
| [#833](https://github.com/Zylann/godot_voxel/issues/833) | grow_sphere holes in solar demo | Часто user error (dual dig/add) |
| [#507](https://github.com/Zylann/godot_voxel/issues/507) | Persistent instancer | Custom gameplay nodes — save yourself |
| [#765](https://github.com/Zylann/godot_voxel/issues/765) | Manual instancing | Instancer ≠ entity system |
| [#702](https://github.com/Zylann/godot_voxel/issues/702) | Blocky + LOD | Basic support; multi-material pending |
| [#677](https://github.com/Zylann/godot_voxel/issues/677) | Raycast + dig offset | `set_sdf_scale` deprecated; scale/raycast pitfalls |
| [#676](https://github.com/Zylann/godot_voxel/issues/676) | RigidBody through terrain | Streaming + tunnelling guide |

**Forum:**
- [Mixed biomes with Zylann voxel](https://forum.godotengine.org/t/help-with-creating-different-types-of-mixed-terrain-or-biomes-in-the-add-on-zylann-godot-voxel/139186) — Discord recommended
- [Destructible voxel models (FPS)](https://forum.godotengine.org/t/how-to-make-dynaimically-destructible-and-scalable-voxel-models/104327) — нет tutorial для R6-style walls
- [Streaming large maps p.3](https://forum.godotengine.org/t/handling-data-streaming-chunk-loading-for-large-3d-maps-in-godot/138774?page=3) — сравнение heightmap vs voxels

---

## 9. VoxelTool API — removal и add-back

### Removal (dig)

```gdscript
var vt := terrain.get_voxel_tool()
vt.channel = VoxelBuffer.CHANNEL_SDF
vt.mode = VoxelTool.MODE_REMOVE
vt.do_sphere(local_center, radius_m)  # local space!
```

Alternatives: `do_path`, `do_box`, `do_mesh`, `grow_sphere` (осторожно).

### Add back (fill / build / «вернуть regolith в скалу»)

```gdscript
vt.mode = VoxelTool.MODE_ADD
vt.do_sphere(local_center, radius_m)
# или paste скопированного VoxelBuffer
```

### Query

- `raycast(origin, direction, max_distance)` — world space; SDF/blocky DDA
- `get_voxel_f` / `get_voxel_f_interpolated` (LOD tool) — sample SDF
- `is_area_editable(AABB)` — gate перед edit

### Regolith-specific pitfalls (из `docs/cheatsheets/voxel-tools.md`)

- [#232](https://github.com/Zylann/godot_voxel/issues/232) — terrain `scale`
- [#136](https://github.com/Zylann/godot_voxel/issues/136) — raycast epsilon
- [#677](https://github.com/Zylann/godot_voxel/issues/677) — collider vs SDF lag

---

## 10. VoxelStream, octree, FastLooseOctree

### VoxelStream ([docs](https://voxel-tools.readthedocs.io/en/latest/streams/))

| Класс | Назначение |
|---|---|
| **`VoxelStreamSQLite`** | Основной: один `.sqlite`; voxels + instancer data; ZSTD compression (1.6) |
| `VoxelStreamRegionFiles` | Legacy Minecraft-style regions |
| `VoxelStreamScript` | Custom GDScript stream |
| `VoxelStreamMemory` | Testing |

**Persistence model:**
- По умолчанию сохраняются **только modified blocks**
- Async save/load; `save_modified_blocks()` + `VoxelSaveCompletionTracker`
- Unload distant blocks → auto-save
- `save_generator_output` — опционально сохранять generated blocks (Minecraft-style)

**Regolith:** `VoxelStreamSQLite` в `bootstrap.gd`, digs SQLite отдельно.

### Octree в Voxel Tools (не FastLooseOctree)

**`FastLooseOctree` — не существует** в Voxel Tools, документации или GitHub Zylann. Вероятные путаницы:

| Термин | Что это на самом деле |
|---|---|
| **LOD Octree** | Внутренняя структура `VoxelLodTerrain` для subdivision blocks |
| **Legacy Octree streaming** | Default streaming system (1.2+) |
| **Clipbox streaming** | Альтернатива octree; multi-viewer |
| **FastNoiseLite / ZN_FastNoiseLite** | Noise в `VoxelGeneratorGraph` (1.6: GPU domain warp) |
| Loose octree (CS concept) | Общая структура данных; **не API плагина** |

Overview: [doc/source/overview.md](https://github.com/Zylann/godot_voxel/blob/master/doc/source/overview.md)

---

## 11. Прототипы и демо Zylann

| Репозиторий | Содержание | Ссылка |
|---|---|---|
| **godot_voxel** | Модуль / GDExtension | [github.com/Zylann/godot_voxel](https://github.com/Zylann/godot_voxel) |
| **voxelgame** | Blocky game, smooth terrain, blocky terrain demos | [github.com/Zylann/voxelgame](https://github.com/Zylann/voxelgame) |
| **solar_system_demo** | Planets 1–20 km, caves, spaceship dig, save per planet | [github.com/Zylann/solar_system_demo](https://github.com/Zylann/solar_system_demo) |
| **TokisanGames/voxelgame** | Fork + **fps_demo** (shoot to dig, LOD tests) | [github.com/TokisanGames/voxelgame](https://github.com/TokisanGames/voxelgame) |

Quick start list: [quick_start/](https://voxel-tools.readthedocs.io/en/latest/quick_start/)

**Solar system demo** — лучший reference для:
- Spherical SDF planets (`SdfSphere` + noise in graph)
- Runtime terrain edit + persistence
- `grow_sphere`/`do_sphere` edge cases near surface ([#833](https://github.com/Zylann/godot_voxel/issues/833))

**Blocky game** — reference для multiplayer voxel sync (server-authoritative edits).

---

## 12. TODAY vs ROADMAP — сводка

### ✅ Production-ready сегодня (1.6x, Feb 2026)

- SDF smooth terrain + Transvoxel + LOD streaming
- Runtime dig/add: `do_sphere`, `do_path`, `copy`/`paste`
- `VoxelStreamSQLite` persistence (voxels + instancer)
- Mesh physics colliders с Jolt
- `separate_floating_chunks` → rigid debris (LOD terrain only)
- `VoxelInstancer` для environment props
- `VoxelGeneratorGraph` + GPU generation
- GDExtension для Godot 4.5+ (Regolith path)
- `VoxelBoxMover` + blocky fluids (1.4+)

### 🟡 Partial / experimental

- Blocky + LOD (limited multi-material)
- Clipbox multi-viewer streaming
- Instancer persistence (positions only, chunk-coupled)
- `grow_sphere` progressive dig (fragile)
- GDExtension — «less tested than module builds» (release notes)

### 🔴 Not planned / community-only

- Granular regolith / spoil piles / sand physics
- Auto debris on terrain dig
- Loose material layer separate from SDF
- Full entity system via VoxelInstancer
- Navigation mesh integration (`navigation` branch inactive, [#610](https://github.com/Zylann/godot_voxel/issues/610))
- Multiplayer sync (README roadmap item, no turnkey solution)

### 📋 Active feature branches ([#640](https://github.com/Zylann/godot_voxel/issues/640))

`floating_chunks`, `dmc2`, `custom_lod_distances`, `connected_textures`, `mesher_script`, `voxel_size`, `step_climb2`, …

---

## 13. Implications для Regolith

**Что Voxel Tools даёт Regolith:**
- Planet-scale editable SDF crust
- Deterministic dig persistence (`VoxelStreamSQLite`)
- Physics colliders для rovers/players (Jolt)
- Optional floating rock debris (`separate_floating_chunks`)

**Что Regolith **должен** делать сам** (и уже делает):
- **Spoil/regolith heaps** → `GranularPatch` + `GranularSpoil` (не плагин)
- Volume conservation dig → loose deposit
- Drill aim → physics raycast, не SDF-only
- Spawn settle → SDF gate + physics probe (`bootstrap.gd`)

**Архитектурный вывод:** Voxel Tools — **solid substrate layer**. Lunar regolith как loose material — **simulation overlay**, architecturally correct и aligned с intent автора («not every 3D grid needs this module for everything»).

---

## Ключевые ссылки

| Ресурс | URL |
|---|---|
| Документация | https://voxel-tools.readthedocs.io/en/latest/ |
| VoxelTool API | https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/ |
| Smooth terrain | https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/ |
| Streams | https://voxel-tools.readthedocs.io/en/latest/streams/ |
| Instancing | https://voxel-tools.readthedocs.io/en/latest/instancing/ |
| Performance / Physics | https://voxel-tools.readthedocs.io/en/latest/performance/ |
| Changelog 1.6 | https://voxel-tools.readthedocs.io/en/latest/changelog/#16-04022026-tag-v16 |
| Release v1.6 | https://github.com/Zylann/godot_voxel/releases/tag/v1.6 |
| Feature branches tracker | https://github.com/Zylann/godot_voxel/issues/640 |
| Regolith voxel cheatsheet | `docs/cheatsheets/voxel-tools.md` |

[REDACTED]
