# Спека — Moon Experiment v0 (promoted → main)

Канонический мир Regolith: редактируемая луна Ø **1 км** как основной ландшафт
[`scenes/main.tscn`](../../scenes/main.tscn), с **полным геймплейным паритетом**
legacy flat yard (стройка, физика, шарниры, колёса, бур, impact carve) и
**persistence копок**. Плоский бесконечный yard сохранён как legacy:
[`scenes/flat_moon.tscn`](../../scenes/flat_moon.tscn).

Родительские контракты: `docs/PHYSICAL-LANGUAGE.md` («Граница владения»,
`Field`), `docs/cheatsheets/voxel-tools.md`, `docs/specs/INDUSTRY-V1.md`
§ *Voxel scale (v1)*.

## Проект

- Godot 4.8, Voxel Tools 1.6x (`addons/zylann.voxel/`), Jolt 5.6
  (встроенный модуль, не legacy `godot-jolt`).
- Гравитация PoC: **1.62 m/s²** (`Field`, не `gravity_scale` на телах).
- Запуск: `./run.sh` или `./run.sh res://scenes/main.tscn` (default run-scene).
- Legacy flat yard: `./run.sh res://scenes/flat_moon.tscn`.
- Kernel-тесты не ломать. Headless `test_*.tscn` не плодить под
  геймплей планеты (R2) — верификация в запущенной main-сцене.

## Зачем

Текущий `flat_moon`: бесконечный процедурный `VoxelTerrain` + `VoxelGeneratorNoise2D`
без `VoxelStream` → копки не переживают рестарт; неудобно якорить транспорт и
структуры на «бесконечном» шуме.

Цель (достигнута): конечная луна + сохранение SDF-правок + тот же геймплейный
стек, что на плоском террейне.

## Геометрия и scale

| Параметр | Значение |
|---|---|
| Диаметр | **19000 м** (`MoonGeometry.DIAMETER_M`) |
| Радиус поверхности (целевой) | 9500 м |
| Voxel node scale | **1.0** (1 м / воксель; `MoonGeometry.VOXEL_SCALE`) |
| Радиус в local voxel | 9500 / 1.0 = **9500** voxel |
| Bounds (local, с запасом) | ≈ ± radius_voxels × 1.25 (~±11875); `lod_count=10` |
| Центр луны | world origin `(0,0,0)` на v0 (без origin shifting) |

## Официальные опоры (сверять, не угадывать)

### Voxel Tools

| Тема | Источник |
|---|---|
| Планеты / `SdfSphere` | [Generators → Planet](https://voxel-tools.readthedocs.io/en/stable/generators/) |
| `VoxelLodTerrain` (bounds, stream, save) | [VoxelLodTerrain API](https://voxel-tools.readthedocs.io/en/stable/api/VoxelLodTerrain/) |
| Smooth / Transvoxel | [Smooth terrain](https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/) |
| `VoxelTool` / raycast | [VoxelTool](https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/) |
| Issues (scale, collider lag) | GitHub `Zylann/godot_voxel` (#232 scale, #677 collider/SDF) |
| Demo масштаба | [solar_system_demo](https://github.com/Zylann/solar_system_demo) (планеты ~км) |

Контракт проекта при scale ≠ 1 (`voxel-tools.md`):

- `VoxelTool.raycast` — **world space**;
- SDF edits (`do_sphere` / `do_path`) — **terrain local** через `VoxelSpaceUtil`;
- aim на terrain — **physics collider**; SDF fallback только если collider ещё нет;
- `generate_collisions = true` обязателен.

Оф. альтернатива «6 spherified heightmaps» — для *нередактируемой* планеты.
Нам нужна копка → **SDF + `VoxelLodTerrain`**, не heightmap-only.

### Jolt / Godot Physics

| Тема | Источник |
|---|---|
| Встроенный Jolt | [Using Jolt Physics](https://docs.godotengine.org/en/stable/tutorials/physics/using_jolt_physics.html) |
| Введение в физику | [Physics introduction](https://docs.godotengine.org/en/stable/tutorials/physics/physics_introduction.html) |
| Point gravity | [`Area3D`](https://docs.godotengine.org/en/stable/classes/class_area3d.html): `gravity_point`, `gravity_point_center`, `gravity_point_unit_distance`, `gravity_space_override` |

Важно:

- `RigidBody3D` получает point gravity из `Area3D` (Jolt поддерживает Area
  gravity override).
- `CharacterBody3D` **не** едет на Area gravity сам — нужен явный local `up`
  в моторе игрока (сейчас `character_motor.gd` жёстко −Y / `Vector3.UP`).
- Joint nodes: не опираться на soft-limit свойства, которые Jolt игнорирует
  (см. док Jolt «Joint properties»).
- Single-body joints: учитывать `World Node` semantics Jolt vs Godot Physics.

### PHYSICAL-LANGUAGE

- Симуляция владеет структурой, joints, командами; Jolt — позой, контактами,
  constraints.
- Гравитация задаётся `Field`, не локальным `gravity_scale`.
- v0 сейчас: одно поле на локацию, direction ≈ −Y. Для луны Field становится
  **радиальным**: `g(pos) = -1.62 * (pos - moon_center).normalized()` на
  поверхности (с optional inverse-square через `gravity_point_unit_distance`,
  если используем Area3D API as-is).

## Архитектура сцены

Канон: `scenes/main.tscn` + `scripts/bootstrap.gd` (planetoid).

Legacy flat yard: `scenes/flat_moon.tscn` + `scripts/flat_moon_bootstrap.gd`.

Минимальный паритет wiring (main ↔ flat_moon):

- terrain node (Lod, см. ниже);
- `Player` (+ drill / interaction);
- `WorldCommandGateway`;
- `SimulationSession`;
- `PlacedBlocks` (если используется main-path);
- light / environment;
- `VoxelViewer` (под камерой / игроком) с view distance, согласованным с
  `max_view_distance` terrain;
- `Area3D` радиальной гравитации (фаза 3).

## Terrain

Цель визуала: **SE-like moon** (круглые ударные кратеры, цельная кора).
В Space Engineers планеты — заранее подготовленные voxel/heightmap данные;
у нас тот же контракт через bake.

- Узел: **`VoxelLodTerrain`** (планеты / большие smooth volumes — путь доки).
- **Play (канон с фазы native-SDF):** `MoonNativeSdfGenerator`
  (`VoxelGeneratorScript`) — аналитический `sdf = |p| − (R + H(n))`, где H(n)
  считает нативный `MoonHeightmapBake.sample_block_sdf16` (C++, весь блок за
  один вызов, запись через `set_channel_from_byte_array`). Стартовая
  самокалибровка сверяет snorm16-кодировку/порядок памяти с `VoxelBuffer`
  (эталон `set_voxel_f`); при несовпадении — тихий per-voxel fallback.
  Никакой панорамной проекции → нет polar pinch / шва долготы; спавн на
  полюсе легален (`_away_from_pole` только для legacy fallback).
  **Известные дельты script-генератора** (нет series generation, в отличие от
  graph): detail normalmaps дальних LOD выключены; у boulder-инстансера
  выключен `snap_to_generator_sdf` (посадка по mesh-поверхности).
- **Fallback play:** прежний `VoxelGeneratorGraph`
  (`NODE_SDF_SPHERE_HEIGHTMAP` + EXR bake) — только если нативный класс
  недоступен; несёт polar pinch по построению.
- Digs: `VoxelStreamSQLite` modified-only (`save_generator_output=false`);
  DB path `gen_v{N}/moon.sqlite` via `MoonTerrainParams.stream_database_path()`.
  Durable persist: debounce carve → `save_modified_blocks` → wait
  `VoxelSaveCompletionTracker` → `flush` once (no flush-per-bite; avoids
  SQLite lock races that can leave cave walls incomplete after reload).
  Quit waits for dig flush (`auto_accept_quit=false`). Editor Stop still
  kills without drain — prefer window close after big digs.
  После копки — `separate_floating_chunks` (INDUSTRY-V1 § Floating; LOD only).
- **Декор (камни):** `VoxelInstancer` child of terrain, `up_mode=Sphere`,
  library `resources/moon_boulder_instance_library.tres` (7 persistent MultiMesh
  tiers). Стримится с чанками; удаления после копок сохраняются в SQLite.
  **Плотность per-chunk** (на LOD0-чанк), **не** per km² планеты — при росте
  диаметра **не** делить density на `(D_ref/D)²`. Bootstrap дублирует library
  в runtime: `boulder_density_scale` (default **−1** → auto **0.65** через
  `MoonGeometry.boulder_density_scale_for_decor()`), LOD-ярусы
  (`pebble_a/b`→LOD0; `pebble_c`/`rock_*`→LOD1; `boulder*`→LOD1), native SDF
  path выключает `snap_to_generator_sdf`. Tunables: `enable_boulder_instancer`,
  `boulder_density_scale` на Main (`bootstrap.gd`).
  См. [Instancing](https://voxel-tools.readthedocs.io/en/latest/instancing/).
- **Нельзя:** live GDScript 565-кратеров; неполный RegionFiles-bake + plain fallback
  (дырявые дальние LOD, исчезающие при приближении). `VoxelStreamRegionFiles`
  не сохраняет instance data — только SQLite.
- Mesher: `VoxelMesherTransvoxel`.
- Material: `transvoxel_terrain` / moon albedo (как main).
- `transform.basis` uniform scale **1.0**.
- Collisions: on; streaming вокруг viewer (**не** `full_load` с SQLite —
  плагин отвергает).
- **Дальняя видимость (планета):** конечные `voxel_bounds` +
  `lod_count=10` (`MoonGeometry.DEFAULT_LOD_COUNT`; coarsest block 8192 ≤
  bounds ~±11875 at scale 1.0; **не** 11 — block 16384 > bounds → cubic cuts).
  `view_distance` **динамический**
  (`MoonGeometry.view_distance_voxels_for_camera_distance`): на поверхности
  ≥2048 вокселей, с высотой растёт. `VoxelViewer` синхронизируется в
  bootstrap. Орбита — camera-relative impostor (не раздувать `Camera.far`:
  ломает light culler / `create_frustum_points`). Туман выключен (вакуум).
- Spawn: SDF gate → short physics probe (~1.5s) → temp landing pad if
  collider lag; pad retires when voxel floor appears. Spawn-focus
  `view_distance` (512) + `collision_lod_count=2` until world_ready.
- Смена рельефа → bump `GENERATOR_VERSION` + повторный bake.
- **Heightmap bake (display-only):** terrain и map globe панораму не читают
  (оба берут analytic H(n) / `MoonReliefSampler`). `crust_heightmap.exr`
  остаётся для cinematic-тулов; bootstrap может печь его фоном 2048×1024
  после `world_ready` (`MAP_HEIGHTMAP_SIZE`). Bump `GENERATOR_VERSION`
  on relief change (соглашение прежнее).
- Мир-сейв сборок: `gen_v{N}/world_save.json` (отдельно от flat_moon).

Типизация в коде: **тонкий адаптер** `TerrainCompat`
(`VoxelTerrain` | `VoxelLodTerrain`).

Известные call sites (не исчерпывающе): `bootstrap.gd`, `flat_moon_bootstrap.gd`,
`world_command_gateway.gd`, `interaction_query.gd`, `terrain_anchor_probe.gd`,
`impact_resolver*.gd`, `rover_*`, `world_loot_projection.gd`.

## Гравитация и «up»

Два потребителя:

1. **Динамика RigidBody (машины, loot, assemblies)** — `Area3D` point gravity
   вокруг луны; project/scene default gravity = 0 или полностью перекрыт Area
   (`gravity_space_override`), чтобы не двойнить −Y.
На поверхности: `gravity = 1.62`, **`gravity_point_unit_distance = 0.0`**
(оф. семантика Area3D: при 0 — **константная** величина силы на любой
дистанции; положительное значение даёт falloff 1/r²). Для геймплея у
поверхности v0 использует константу 1.62 без falloff.
2. **Игрок / camera / construction seat** — явный
   `up = (global_pos - moon_center).normalized()`; движение в касательной
   плоскости; jump вдоль up.

Горячие места с зашитым +Y / −Y (править за flag / GravityField, не ломая main):

- `scripts/character_motor.gd`
- construction seat / `grid_pose_util.gd` («gravity-up face»)
- `world_command_gateway.gd` (ground seat)
- piston gravity compensation в projection (читает project gravity vector)
- spawn settle probes

## Фазы реализации

### Фаза 0 — контракт (этот документ)

- Зафиксировать геометрию, scale, паритет, ссылки на доки.
- **DoD:** спека в `docs/specs/`, согласована с R1.

### Фаза 1 — сцена-оболочка

- `main.tscn`: LodTerrain sphere + wiring из flat_moon.
- Spawn на «северном полюсе»; пока достаточно project −Y.
- **DoD:** mesh + collider; стоять/ходить у полюса;
  `./run.sh --headless res://scenes/main.tscn --quit-after 300`
  без ошибок компиляции шейдеров/скриптов.

### Фаза 2 — Terrain API / адаптер

- Абстракция для `VoxelTerrain` | `VoxelLodTerrain`.
- Aim, ручной бур, impact carve на луне (локально у полюса).
- **DoD:** hit не «к игроку»; SDF edit в local; physics aim при scale 1.0.

### Фаза 3 — радиальная гравитация для RigidBody

- Area3D point gravity; сцена без конкурирующего −Y для динамических тел.
- Тележка / ровер / joint-сборка на склоне *вдали от полюса*.
- **DoD:** тела падают к центру луны; hinge/slider не взрываются (Jolt).

### Фаза 4 — игрок local up

- Motor + camera + floor_max_angle от radial up.
- **DoD:** пройти от полюса к экватору и обратно без «падения вбок».

### Фаза 5 — стройка / ground seat

- Preview, place, attach, anchor probe → local up + physics normal.
- **DoD:** рама/якорь на склоне и у экватора стабильны.

### Фаза 6 — колёса / шарниры / actuators (паритет)

- Rover compose + drive по дуге.
- Suspension / wheel contact.
- Piston/hinge под радиальной g.
- Kinetic carve от удара машины.
- **DoD:** чеклист ниже зелёный в **запущенной** moon-сцене (скрин/логи).

### Фаза 7 — persistence

- Stream + save modified blocks; reload сцены → ямы на месте.
- Snapshot построек (если уже есть save path) — иначе явно пометить gap.
- **DoD:** dig persistence подтверждён рестартом сцены.

## Паритет-чеклист (Definition of Done эксперимента)

| Фича | Критерий на луне |
|---|---|
| Spawn / settle | SDF gate + physics collider; без телепорта на y=0 |
| Walk / jump / sprint | local up; склоны в текущем floor angle |
| Aim + ручной бур | world raycast; edit local; непрерывный канал |
| Impact carve | удар машины режет SDF |
| Construction preview / place | seat по нормали / local up |
| Anchor / frozen assembly | держится на поверхности |
| Rover N-wheels | едет по дуге, не улетает к −Y |
| Joints (hinge / slider / piston) | стабильны под point gravity |
| Loot / projection write-back | падает к центру луны |
| Dig persistence | переживает рестарт main-сцены |
| Scale 1.0 | контракт шпаргалки соблюдён |

## Риски

1. **«Up = +Y» расползся по геймплею** — главный объём (motor, seat, camera,
   probes, piston g-comp). Без фаз 4–5 паритета нет.
2. **Type-lock на `VoxelTerrain`** — без адаптера Lod не подставить.
3. **Collider lag LOD / scale ≠ 1** — aim = physics; spawn = settle (VT issues).
4. **Area gravity ≠ CharacterBody** — легко получить «машины ок / игрок нет».
5. **Память `VoxelLodTerrain`** — по доке нет дефолтного cache как у
   `VoxelTerrain`; у конечной Ø1 км оболочки объём ограничен `voxel_bounds`.
6. **Precision / clip** — `Camera.far` остаётся ~20 км; дальше — impostor,
   не экстремальный far (light culler). Origin shifting — позже.

Регрессии `flat_moon`: **низкие** — отдельный legacy entrypoint;
правки player/projection за `GravityField` / moon_center.

## Анти-цели v0

- Не делать мульти-тело solar system / orbital flight.
  Презентационное небо (Земля + atmospheric limb с поверхности) — ок;
  это не симуляция орбит и не жизненная атмосфера на Луне.
- Не вводить новую GDExtension-зависимость (R6).
- Не писать headless геймплей-тесты сцены луны (R2).

## Верификация

| Что | Как |
|---|---|
| Логика ядра после правок адаптера | `./tests/run_tests.sh` один раз перед «готово» ветки |
| Шейдеры / скрипты main-сцены | headless `--quit-after` |
| Геймплейный паритет | play main: settle → screenshot / remote tree / logs |
| Voxel / Jolt семантика | сверка с доками выше + issues; не выводить из старого кода |

## Ветвление

- Promoted в `main` (planetoid default).
- Один коммит ≈ одна фаза / одно проверяемое изменение.
- Спека и код фазы — вместе, если меняют контракт.

## Статус

**Promoted** — planetoid = `scenes/main.tscn`, flat yard = `flat_moon` (legacy).

| Фаза | Статус |
|---|---|
| 0 Контракт | **done** |
| 1 Сцена-оболочка | **done** |
| 2 Terrain API | **done** |
| 3 Radial gravity (RB) | **done** (Area3D point, unit_distance=0) |
| 4 Player local up | **done** |
| 5 Construction seat | **done** |
| 6 Wheels / joints parity | **done** (rover spawn + field-aware wheels) |
| 7 Dig persistence | **done** (bake RegionFiles + play modified-only digs) |
| Lunar relief H(n) | **done** (HQ `MoonTerrainGenerator` — bake only) |
| Landscape bake | **done** (`moon_bake_stream.tscn`; MT heightmap via `WorkerThreadPool`) |
| Native analytic SDF play | **done** (gen_v25: `MoonNativeSdfGenerator`, полюс без pinch, dig persistence подтверждён рестартом) |
