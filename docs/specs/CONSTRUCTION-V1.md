# Construction v1

Статус: production milestone после Simulation Kernel v0.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md`;
- `docs/specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md`;
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/PLAYER-INTERACTION-V1.md`.

## Цель

Игрок строит закреплённую базу тем же authoritative языком, которым уже
описываются мобильные `Assembly`:

```text
preview → frame → operational → damaged → destroyed
              │          │          │
              └──────────┴──────────┴→ dismantled
                              ↑
                            repair
```

`preview` существует только в presentation. После принятого `place` элемент
появляется в `SimulationWorld`; physics и visual projection читают это состояние,
но не владеют им.

Lethal `damage` (`integrity` достигает `0`) — **destructive topology mutation**:
элемент удаляется из topology без возврата материалов; оставшаяся Assembly
перестраивается, делится или исчезает по той же survivor policy, что и
`dismantle`. Persistent `broken` элемента в topology нет.

## Состояние элемента

Единая **структурная целостность** (`integrity`, `0..max_integrity`):

- при `place` элемент появляется с `1%` целостности;
- сварка повышает целостность (BOM + компоненты) до `100%` — полностью готовый объект;
- бур и болгарка уменьшают целостность через `DamageElementCommand`;
- `build_progress` — derived-представление `integrity / max_integrity` для UI/сериализации.

| Состояние | Предикат | `status/reason` |
|---|---|---|
| `frame` | `0 < integrity < max_integrity` | `blocked/element_incomplete` |
| `operational` | `integrity = max_integrity` | `ok/ok` |

`integrity <= 0` не является устойчивым runtime-состоянием: lethal `damage`
удаляет элемент из topology.

Functional ports/roles активны только при `integrity = max_integrity`.

## BOM и Store

`ElementArchetype.build_requirements` является единственным BOM. Runtime-элемент
хранит фактически установленные количества по `resource_id`.

- `place` устанавливает одну единицу первого требования и `1%` целостности;
- `weld` переносит BOM и/или восстанавливает целостность до `100%`;
- команда атомарно отклоняется до мутации при нехватке материала;
- `dismantle` возвращает `50%` каждого установленного количества;
- lethal `damage` (`integrity → 0`) возвращает `0%` и удаляет элемент из topology;
- `repair` расходует `construction_component`; одна единица восстанавливает
  `25% max_integrity`.

Construction v1 вводит simulation-owned keyed `SimulationResourceStore`.
Industry v1 расширяет stores/cargo без смены формата construction-комmand;
контракт — `docs/specs/INDUSTRY-V1.md`.

## Команды

Все команды — typed `StructuralCommand`, выполняются последовательно
`SimulationWorld`.

### `PlaceElementCommand`

Поля: target `assembly_id` (`0` для новой Assembly на грунте), expected topology revision,
archetype, grid pose, grid frame новой Assembly и `store_id`.

Проверки до расхода ID и материалов:

1. archetype и orientation валидны;
2. target Assembly существует и revision актуален;
3. footprint не пересекает occupancy target Assembly;
4. новый элемент имеет хотя бы один валидный structural surface contact с уже
   стоящим элементом (derived face pair на соседних cells, policy archetype
   соблюдена);
5. первый блок на грунте (`assembly_id = 0`) требует подтверждённого terrain-contact
   (любая грань collider) и создаёт anchor на canonical ground face/port; continuous
   root pose сохраняется на hit-точке, integer `GridTransform` — только topology;
6. explicit anchor-archetype не добавляется к существующей Assembly;
7. store содержит placement-компонент.

Успех создаёт `frame` (каркас), rigid/anchor joints, увеличивает topology revision и
публикует `assembly_changed` либо `assembly_spawned`. К соседним `frame`-элементам
можно крепить другие блоки без заварки; functional roles активны только после
`build_progress = 1.0` (`is_operational()`).

### Масштаб production archetypes

Все размеры заданы в общей grid 0.5 m. Footprint определяет occupancy; один
collider (`BOX` или `CYLINDER`) может покрывать несколько cells. Для
`CYLINDER`: `size.x` = diameter, `size.y` = height, `size.z` = diameter.

| Archetype | Footprint cells | Физический габарит |
|---|---:|---:|
| `frame`, `frame_basalt`, `cargo_pipe`, `rover_frame`, `drive_wheel` | 1×1×1 | 0.5×0.5×0.5 m envelope |
| `wheel_suspension` | 1×2×1 | 0.5×1×0.5 m (см. `specs/ROVER-MODULES-V1.md`) |
| `cockpit` | 3×2×2 | 1.5×1×1 m (см. `specs/ROVER-MODULES-V1.md`) |
| `power_battery_small` | 2×3×2 | 1×1.5×1 m |
| `power_distributor_small` | 2×2×2 | 1×1×1 m |
| `frame_beam` | 4×1×1 | 2×0.5×0.5 m |
| `foundation` | 4×1×4 | 2×0.5×2 m |
| `power_distributor` | 2×2×2 | 1×1×1 m |
| `power_battery` | 2×3×2 | 1×1.5×1 m |
| `stationary_drill` | 2×2×2 | 1×1×1 m body + working head |
| `power_source`, `cargo_store` | 3×3×3 | 1.5×1.5×1.5 m |
| `processor`, `fabricator` | 4×3×3 | 2×1.5×1.5 m |
| `large_frame` | 5×5×5 | 2.5×2.5×2.5 m test cube |
| `rotor_base_large` + `rotor_top_large` | 5×4×5 + 5×1×5 | cylinder Ø2.5×2.0 m + head 2.5×0.5×2.5 m (stack 2.5 m) |

### Unified grid structural surface

Единственная topology grid — **0.5 m** (`GridMetric`, `origin_cell`,
`footprint_cells`, 24 orthogonal orientations без изменений). Физическое крепление
блоков идёт через **derived structural surface faces**, а не через центральные
authored structural ports.

| Policy | Кто | Structural attachment |
|---|---|---|
| `full_surface` | `Frame`, beam, foundation, pipe | любая наружная грань footprint |
| `mount_pads` | machines/modules | только author-defined mount pads |
| `none` | — | запрещён |

- `DerivedSurfaceFace` = `(local_cell, local_face)` на boundary footprint; ID
  `structural_<x>_<y>_<z>_<face>`.
- Placement требует ≥1 валидный surface contact; multi-cell контакт создаёт **один**
  `SimulationJoint` с детерминированной canonical derived ID pair.
- Cargo/electric/anchor остаются явными `PortDefinition`; surface contact сам по
  себе не создаёт resource/network edge.
- Snap/preview читают те же derived faces (см. magnetic snap policy); world-grid
  snapping на terrain **не** вводится.

**Terrain-contact per block.** Каждый construction-элемент хранит устойчивый факт
контакта с terrain (`SimulationElement.terrain_contact`, сериализуется в snapshot).
Флаг ставится в момент постановки: первый блок (`assembly_id = 0`) — `true` по
построению (ground-seat), последующие блоки пробятся probe'ом на месте и при
подтверждённом контакте сразу получают `Anchor`. Так каждый стоящий на грунте блок
заякорен, а не только первый: отсоединение одного блока больше не «освобождает» всю
постройку. Terrain разрушаем, поэтому на split/dismantle факт **перепроверяется**
probe'ом и флаг/якоря приводятся в соответствие (см. `DismantleElementCommand`).

### `WeldElementCommand`

Поля: `element_id`, expected state revision, `store_id`, максимальный material
transfer. Команда переносит только недостающий BOM, пересчитывает
`build_progress`, увеличивает state revision и публикует `element_state_changed`.
Topology revision не меняется.

### `DamageElementCommand`

Поля: `element_id`, expected state revision, положительный damage. Уменьшает
структурную целостность (`integrity`).

- если `integrity` остаётся `> 0` — state-only мутация: `state_revision`,
  `element_state_changed`, без topology rebuild;
- если `integrity` достигает `0` — destructive topology removal через общий путь
  dismantle/split без material refund (`refund_fraction = 0`); публикует
  `assembly_removed`, `assembly_changed` или `assembly_split` и увеличивает
  topology revision.

### `RepairElementCommand`

Поля: `element_id`, expected state revision, `store_id`, максимальный расход.
Атомарно расходует материал и восстанавливает только `integrity`.

### `DismantleElementCommand`

Поля: `element_id`, expected topology revision и `store_id` для возврата.
Команда удаляет все joints и сам элемент, возвращает материалы и:

- удаляет пустую Assembly;
- перестраивает одну оставшуюся компоненту;
- при разрыве графа применяет kernel survivor policy и создаёт отдельные Assembly;
- перепроверяет и пересчитывает terrain anchors для оставшихся construction-компонент:
  probe заново определяет контакт (terrain разрушаем), обновляет
  `terrain_contact` каждого блока; элемент с подтверждённым контактом получает
  `Anchor`, потерявший — теряет его. Компонента без единого якоря становится
  свободным телом и падает; компонента с якорем остаётся статичной на месте.

## Revision policy

- topology revision: `place`, `dismantle`, lethal `damage`;
- element state revision: `weld`, non-lethal `damage`, `repair`;
- state-команды не вызывают physics rebuild;
- structural events несут command ID и актуальные revision.

## Player flow

```text
Input Map
  → InteractionQuery (voxel или stable ElementId)
  → ConstructionSnapResolver (direct hit + magnetic face candidates)
  → ToolController
  → WorldCommandGateway
  → typed construction command
  → SimulationWorld
  → physics + visual projection
  → ActionResult
```

### Toolbar и ориентация

Construction v1 использует **universal paged toolbar** с `9` слотами на страницу
(`1..9`) и paging `[` / `]`:

- **Страница 1 — essentials:** бур, сварка, frame, beam, power, drill, store + empty;
- **Страница 2 — modules:** processor, fabricator + повторы archetypes + empty.

Пустые слоты безопасны. При смене страницы восстанавливается slot per page;
если он пуст — выбирается первый non-empty slot.

**24 orthogonal orientations** — единственный допустимый набор поворотов элемента
(`OrientationUtil.ORIENTATION_COUNT = 24`): все оси локального basis — integer unit
vectors, determinant = 1. Произвольные углы и произвольный Euler в placement
запрещены. Цикл ориентации v1: `C` — шаг вокруг локальной оси Y; полный
3-axis cycle — через resolver/tool hook без изменения topology contract.

### Magnetic snap policy

Наводка placement не ограничена прямым physics-ray hit по совместимой грани:

1. **Direct compatible element hit** — physics-ray попал в `simulation_element`,
   `ConstructionPlacement.plan()` валиден для attach (`assembly_id != 0`); score
   `DIRECT_ELEMENT_SCORE`.
2. **Face scan** — derived structural surface faces anchored Assembly в
   cone/corridor луча;
   scoring: ray deviation, distance от `ray_origin`, screen deviation, compatibility,
   authoritative validity.
3. **Voxel fallback** — валидный `KIND_VOXEL` direct hit получает
   `VOXEL_FALLBACK_SCORE` **ниже** magnetic faces; если magnetic candidates нет,
   voxel работает как раньше. Direct voxel hit **не** обрывает face scan:
   наводка на грунт рядом со структурой всё равно предлагает magnetic faces
   (общий пул кандидатов, отбор по score).
4. **Hysteresis** — sticky candidate удерживается, пока новый луч не даёт явно
   лучший score.
5. **Manual cycle** — `T` (`construction_cycle_snap`) →
   `ConstructionSnapResolver.cycle_candidate()` через `ConstructionPreview`;
   удерживается до изменения aim/selection.
6. **Red ghost** — если ни один кандидат не валиден, но direct hit есть,
   resolver возвращает его невалидный plan (`valid=false`) как selected —
   preview рисует красную проекцию с причиной вместо пустоты.

Единственный short-circuit: валидный direct hit по совместимой грани
`simulation_element` (§1) — face scan не нужен, кандидат один. Все остальные
кейсы (грунт, промах, невалидный direct) идут одним merge-путём: face scan +
voxel fallback + red-ghost fallback.

Resolver не мутирует simulation и не обходит validation.

**Performance:** `ConstructionSnapFaceCache` хранит structural surface faces для
attach-allowed assemblies в local space (+ cached world_point). Full/incremental
rebuild face topology — при смене assembly set / topology revision / structural
events; attach permission динамическая (velocity rule для floating locomotives),
поэтому `ensure_current()` дополнительно сверяет `construction_attach_allowed`
на каждый resolve: припаркованный ровер становится magnetic без structural
event, уехавший — выпадает из cache (нет stale faces и rebucket-thrash).
Continuous pose sync **пропускается** для frozen/terrain-anchored assemblies
(иначе walk+miss-aim → десятки ms/frame на rebucket). Mobile assemblies
обновляют world_point из local pose при сдвиге > half-cell, без bump `generation`.
Miss-aim quantize грубее (preview). Каждый resolve: corridor pass + plan
validation с ранним стопом (`VALID_FACE_STOP` валидных кандидатов достаточно;
верхняя граница попыток — top-K). Reuse результата — один слой: quantized
context key в `ConstructionPreview` (gateway-слой result cache удалён — deep
copy каждый кадр стоил дороже, чем экономил). Preview mesh nodes строятся один
раз на (archetype, orientation, valid) в origin ZERO и переносятся transform'ом
контейнера на origin_cell — sweep по attach-целям не пересоздаёт ноды.

### Preview parity

Preview ghost повторяет projection path:

- root pose = `assembly_world_transform` / `preview_root_transform` (motion Assembly
  или ground spawn transform);
- для нового Assembly этот exact continuous root pose передаётся в
  `PlaceElementCommand.initial_motion` и становится `assembly.motion` до создания
  physics body; gateway не выполняет отдельный post-place transform repair;
- collider children = `GridPoseUtil.collider_local_transform(origin_cell,
  orientation_index, collider)` — orientation **не** дублируется в root;
- поворот collider и port visual выполняется вокруг центра его grid cell:
  `origin_cell + rotate_cell(local_cell) + (0.5, 0.5, 0.5)`. `origin_cell`
  остаётся целочисленной topology-координатой и не является pivot mesh;
- port decals = `IndustryPortUtil.port_marker_local_transform` как children
  assembly physics body (тот же element basis, что у collider ghost);
- attach snap face = hit `point` + `normal` в assembly space (`floor − snap_dir`),
  не `collider_local_cell`;
- attach rotate (C/V/B) остаётся face-locked: `snap_origin_without_pivot` строится
  только от текущей наведённой грани. Нельзя искать valid origin в соседних cells
  assembly, потому что такая клетка может соединиться с другим element длинной
  конструкции и визуально увести блок от aim;
- первый valid attach-resolve фиксирует `target_port_cell` и `snap_dir` на время
  rotate/re-aim того же contact. Следующие ориентации используют этот grid contact,
  а не повторно вычисленный floating ray point, который может перескочить через
  cell boundary;
- ground rotate держит baseline footprint center (`ConstructionPlacement.baseline_ground_pivot`)
  через `held_ground_pivot` в preview/gateway.

После rotate и повторного aim к неизменному target resolver обязан детерминированно
дать тот же candidate для выбранного `orientation_index`: orientation применяется
ровно один раз в element-local transform. Поворот не может оставить cache с
предыдущей world geometry, перенести snap на далёкую грань, внутрь occupied cells
или под terrain. Если допустимого соседнего placement нет, plan invalid.
Ключ cache включает quantized held ground/attach pivot; захват attach pivot
обязательно вызывает повторный resolve, поэтому plan без pivot hold не может
пережить rotate/re-aim и быть повторно использован.

`ConstructionPlacement.plan()` возвращает явные поля `preview_root_transform`,
`origin_cell`, `orientation_index` наряду с legacy `world_transform`
(element-origin world pose). Presentation не является источником collision.

### Action feedback

Construction tools **не** показывают action progress bars (hold-to-complete).
Доменный `build_progress` (BOM weld fraction) остаётся в simulation state и
visual projection (`frame` vs `operational`), но не смешивается с input feedback.

Управление v1:

- `1..9` — слоты текущей toolbar-страницы;
- `[` / `]` — предыдущая/следующая страница;
- `T` — cycle magnetic snap candidate (build mode);
- `C` / `V` / `B` — поворот выбранного блока (только в build mode);
- `ЛКМ` — бур, болгарка, сварка, установка блока (по активному слоту);
- болгарка при полном сносе возвращает `50%` материалов; бур — без возврата.

Preview не выделяет ID и не изменяет world. Он использует ту же authoritative
placement validation, что и команда, и те же pose helpers, что physics/visual
projection (`GridPoseUtil`).

## Player flow (runtime)

```text
InteractionQuery (direct hit)
  → ConstructionPreview (aim ray + gateway.resolve_construction_placement)
  → preview ghost + resolved_target/plan
  → ToolController (placement lock берёт resolved target/plan)
  → WorldCommandGateway (authoritative apply / placement_plan)
  → SimulationWorld
```

Resolver не мутирует simulation. Preview и click используют один resolved plan.

## Presentation

Процедурная visual projection показывает:

- matte orange scaffold — `frame` (opaque, pre-weld);
- steel blue — `operational`;
- amber — `damaged`;
- cyan/red translucent ghost — valid/invalid preview.

Lethal damage удаляет visual вместе с topology; persistent red `broken` блока нет.

Presentation не является источником collision, mass, occupancy или состояния.

## Сценарий

После R5 terrain settle игрок получает стартовый запас
`construction_component`. Существующая compatibility-модель `PlacedBlocks`
не используется construction tools. Игрок может:

1. поставить любой Slice-01 блок на voxel terrain как первый якорь;
2. поставить любой Slice-01 frame/module рядом по совместимому structural face
   (включая крепление к каркасу);
3. опционально заварить frame до operational;
4. повредить элемент буром (без refund) или болгаркой (с refund при сносе);
5. восстановить целостность сваркой.

## Acceptance

1. Все пять construction-команд применяют состояние только через
   `SimulationWorld`.
2. Placement/weld/repair атомарно учитывают simulation-owned Store.
3. Frame, operational и damaged однозначно вычисляются и отображаются; lethal
   damage удаляет элемент из topology.
4. Dismantle (API) и lethal damage корректно удаляют пустую Assembly и разделяют
   disconnected graph; lethal damage с refund (болгарка) возвращает материалы,
   без refund (бур) — нет.
5. Stable `ElementId` приходит из physics projection в `InteractionQuery`.
6. Preview и visual projection не мутируют simulation; preview collider poses
   совпадают с projection для multi-cell archetypes (`test_construction_preview`).
7. Snapshot сохраняет stores, installed BOM и state revision.
8. Anchored base и mobile rover продолжают использовать один kernel.

## Не входит

- Industry Flow и производство — см. `docs/specs/INDUSTRY-V1.md`;
- inventory/hotbar UI сверх выбора archetype и счётчика;
- fatigue/load graph и автоматический физический `break`;
- симуляция `condition`;
- строительство на движущейся Assembly;
- финальные модели, weld VFX/SFX и баланс vertical slice.
