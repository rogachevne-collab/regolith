# Спека — Moon Experiment v0 (отдельная сцена)

Эксперимент в отдельной ветке/сцене: небольшая редактируемая луна
Ø **1 км** как основной ландшафт сцены, с **полным геймплейным паритетом**
текущего `main` (стройка, физика, шарниры, колёса, бур, impact carve) и
**persistence копок**. `scenes/main.tscn` не подменять.

Родительские контракты: `docs/PHYSICAL-LANGUAGE.md` («Граница владения»,
`Field`), `docs/cheatsheets/voxel-tools.md`, `docs/specs/INDUSTRY-V1.md`
§ *Voxel scale (v1)*.

## Проект

- Godot 4.5+, Voxel Tools 1.6x (`addons/zylann.voxel/`), физика Jolt
  (встроенный модуль, не legacy `godot-jolt`).
- Гравитация PoC: **1.62 m/s²** (`Field`, не `gravity_scale` на телах).
- Запуск эксперимента: `./run.sh res://scenes/moon_experiment.tscn`
  (сцена появится в фазе 1; до этого документ — контракт).
- Kernel-тесты / `main` не ломать. Headless `test_*.tscn` не плодить под
  геймплей луны (R2) — верификация в запущенной moon-сцене.

## Зачем

Текущий `main`: бесконечный процедурный `VoxelTerrain` + `VoxelGeneratorNoise2D`
без `VoxelStream` → копки не переживают рестарт; неудобно якорить транспорт и
структуры на «бесконечном» шуме.

Цель эксперимента: конечная луна + сохранение SDF-правок + тот же геймплейный
стек, что на плоском террейне.

## Геометрия и scale

| Параметр | Значение |
|---|---|
| Диаметр | 1000 м |
| Радиус поверхности (целевой) | 500 м |
| Voxel node scale | **0.65** (как `main`, INDUSTRY-V1) |
| Радиус в local voxel | ≈ 500 / 0.65 ≈ **769** voxel |
| Bounds (local, с запасом) | ≈ ± radius_voxels × 1.1 |
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

Новая сцена: `scenes/moon_experiment.tscn` (+ bootstrap, например
`scripts/moon_experiment_bootstrap.gd`).

Минимальный паритет wiring с `main.tscn`:

- terrain node (Lod, см. ниже);
- `Player` (+ drill / interaction);
- `WorldCommandGateway`;
- `SimulationSession`;
- `PlacedBlocks` (если используется main-path);
- light / environment;
- `VoxelViewer` (под камерой / игроком) с view distance, согласованным с
  `max_view_distance` terrain;
- `Area3D` радиальной гравитации (фаза 3).

**Не** менять default run-scene проекта на moon без явного решения после
паритет-чеклиста.

## Terrain

- Узел: **`VoxelLodTerrain`** (планеты / большие smooth volumes — путь доки).
- Generator: `VoxelGeneratorGraph` с `SdfSphere` (+ лёгкий noise/craters).
- Mesher: `VoxelMesherTransvoxel`.
- Material: можно временно тот же `transvoxel_terrain` / moon albedo, что main.
- `transform.basis` uniform scale **0.65**.
- Collisions: on; streaming вокруг viewer.
- Persistence: `VoxelStreamRegionFiles` или `VoxelStreamSQLite` → `user://moon_experiment/`
  (или аналог); после carve — `save_modified_blocks`; на quit — дождаться flush.

Типизация в коде сегодня: много `VoxelTerrain`. Для Lod нужен **тонкий адаптер**
(интерфейс/`Node` contract: `get_voxel_tool()`, collider check, ground probe),
чтобы moon-сцена не кастила к `VoxelTerrain`, а `main` не ломался.

Известные call sites (не исчерпывающе): `bootstrap.gd`,
`world_command_gateway.gd`, `interaction_query.gd`, `terrain_anchor_probe.gd`,
`impact_resolver*.gd`, `rover_*`, `world_loot_projection.gd`.

## Гравитация и «up»

Два потребителя:

1. **Динамика RigidBody (машины, loot, assemblies)** — `Area3D` point gravity
   вокруг луны; project/scene default gravity = 0 или полностью перекрыт Area
   (`gravity_space_override`), чтобы не двойнить −Y.
   На поверхности: `gravity = 1.62`, `gravity_point_unit_distance = 500`
   (оф. семантика Area3D: сила = gravity на unit distance, дальше falloff
   1/r² — зафиксировать в реализации, нужен ли falloff или константа на
   оболочке; для геймплея у поверхности предпочтительна ≈константа 1.62).
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

### Фаза 1 — сцена-оболочка (ещё без смены up)

- `moon_experiment.tscn`: LodTerrain sphere + wiring из main.
- Spawn на «северном полюсе»; пока достаточно project −Y.
- **DoD:** mesh + collider; стоять/ходить у полюса;
  `./run.sh --headless res://scenes/moon_experiment.tscn --quit-after 300`
  без ошибок компиляции шейдеров/скриптов.

### Фаза 2 — Terrain API / адаптер

- Абстракция для `VoxelTerrain` | `VoxelLodTerrain`.
- Aim, ручной бур, impact carve на луне (локально у полюса).
- **DoD:** hit не «к игроку»; SDF edit в local; physics aim при scale 0.65.

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
| Dig persistence | переживает рестарт moon-сцены |
| Scale 0.65 | контракт шпаргалки соблюдён |

## Риски

1. **«Up = +Y» расползся по геймплею** — главный объём (motor, seat, camera,
   probes, piston g-comp). Без фаз 4–5 паритета нет.
2. **Type-lock на `VoxelTerrain`** — без адаптера Lod не подставить.
3. **Collider lag LOD / scale ≠ 1** — aim = physics; spawn = settle (VT issues).
4. **Area gravity ≠ CharacterBody** — легко получить «машины ок / игрок нет».
5. **Память `VoxelLodTerrain`** — по доке нет дефолтного cache как у
   `VoxelTerrain`; тюнить view distance / stream.
6. **Precision Ø 1 км** — на v0 центр в origin; origin shifting не нужен, пока
   игрок не уходит на десятки км от origin.

Регрессии `main`: **низкие**, пока moon — отдельный entrypoint, а правки
player/projection за feature-flag / «если задан GravityField / moon_center».

## Анти-цели v0

- Не заменять `main` луной.
- Не делать мульти-тело solar system / atmosphere / orbital flight.
- Не вводить новую GDExtension-зависимость (R6).
- Не писать headless геймплей-тесты сцены луны (R2).

## Верификация

| Что | Как |
|---|---|
| Логика ядра после правок адаптера | `./tests/run_tests.sh` один раз перед «готово» ветки |
| Шейдеры / скрипты moon-сцены | headless `--quit-after` |
| Геймплейный паритет | play moon-сцены: settle → screenshot / remote tree / logs |
| Voxel / Jolt семантика | сверка с доками выше + issues; не выводить из старого кода |

## Ветвление

- Ветка эксперимента: `cursor/moon-experiment-3dc6`.
- Один коммит ≈ одна фаза / одно проверяемое изменение.
- Спека и код фазы — вместе, если меняют контракт.

## Статус

| Фаза | Статус |
|---|---|
| 0 Контракт | **done** |
| 1 Сцена-оболочка | **in progress** |
| 2 Terrain API | **in progress** |
| 3 Radial gravity (RB) | pending |
| 4 Player local up | pending |
| 5 Construction seat | pending |
| 6 Wheels / joints parity | pending |
| 7 Dig persistence | pending |
