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

Три оси независимы:

- `build_progress` — установленная доля BOM, `0.0..1.0`;
- `integrity` — прочность, `0.0..max_integrity`;
- `condition` — долговременный износ, зарезервирован и равен `1.0` в v1.

Состояния вычисляются, а не хранятся отдельным enum:

| Состояние | Предикат | `status/reason` |
|---|---|---|
| `frame` | `build_progress < 1.0`, `integrity > 0` | `blocked/element_incomplete` |
| `operational` | `build_progress = 1.0`, `integrity = max_integrity` | `ok/ok` |
| `damaged` | `build_progress = 1.0`, `0 < integrity < max_integrity` | `ok/damaged` |

`integrity <= 0` не является устойчивым runtime-состоянием: lethal `damage`
удаляет элемент из topology. Предикат `broken` (`integrity <= 0`) остаётся только
как transient guard во время применения команды.

Незавершённый элемент сохраняет массу, collider и structural ports, но
functional ports/roles считаются неактивными до `build_progress = 1.0`.

## BOM и Store

`ElementArchetype.build_requirements` является единственным BOM. Runtime-элемент
хранит фактически установленные количества по `resource_id`.

- `place` устанавливает одну единицу первого требования
  (`min(1.0, required_amount)`);
- `weld` переносит до запрошенного количества в порядке BOM;
- `build_progress = installed_total / required_total`;
- команда атомарно отклоняется до мутации при нехватке материала;
- `dismantle` возвращает `50%` каждого установленного количества;
- lethal `damage` (`integrity → 0`) возвращает `0%` и удаляет элемент из topology;
- `repair` расходует `construction_component`; одна единица восстанавливает
  `25% max_integrity`.

Construction v1 вводит simulation-owned keyed `SimulationResourceStore`.
Стартовый store `player` заменяется cargo/inventory adapter в Industry v1 без
изменения формата construction-команд.

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
4. новый элемент имеет хотя бы один совместимый rigid edge;
5. первый блок на грунте (`assembly_id = 0`) требует подтверждённого terrain-contact
   (любая грань collider) и создаёт anchor на canonical ground port; continuous root
   pose сохраняется на hit-точке, integer `GridTransform` — только topology;
6. explicit anchor-archetype не добавляется к существующей Assembly;
7. store содержит placement-компонент.

Успех создаёт `frame` (каркас), rigid/anchor joints, увеличивает topology revision и
публикует `assembly_changed` либо `assembly_spawned`. К соседним `frame`-элементам
можно крепить другие блоки без заварки; functional roles активны только после
`build_progress = 1.0` (`is_operational()`).

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

Поля: `element_id`, expected state revision, положительный damage. Уменьшает только
`integrity`; BOM и `build_progress` не меняются.

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
2. **Face scan** — structural faces anchored Assembly в cone/corridor луча;
   scoring: ray deviation, distance от `ray_origin`, screen deviation, compatibility,
   authoritative validity.
3. **Voxel fallback** — валидный `KIND_VOXEL` direct hit получает
   `VOXEL_FALLBACK_SCORE` **ниже** magnetic faces; если magnetic candidates нет,
   voxel работает как раньше.
4. **Hysteresis** — sticky candidate удерживается, пока новый луч не даёт явно
   лучший score.
5. **Manual cycle** — `T` (`construction_cycle_snap`) →
   `ConstructionSnapResolver.cycle_candidate()` через `ConstructionPreview`;
   удерживается до изменения aim/selection.

Resolver не мутирует simulation и не обходит validation.

**Performance:** `ConstructionSnapFaceCache` хранит lightweight world-space
descriptors structural faces для anchored assemblies. Cache rebuild только при
изменении topology revision / motion transform / assembly set (через
`SimulationWorld.structural_event`). Каждый resolve делает дешёвый geometric
corridor pass по cache, затем `ConstructionPlacement.plan()` только для top-K
(`TOP_K_VALIDATE=12`) кандидатов. `WorldCommandGateway` и `ConstructionPreview`
дополнительно reuse result при неизменном quantized aim/selection/cache
generation.

### Preview parity

Preview ghost повторяет projection path:

- root pose = `assembly_world_transform` / `preview_root_transform` (motion Assembly
  или ground spawn transform);
- collider children = `GridPoseUtil.collider_local_transform(origin_cell,
  orientation_index, collider)` — orientation **не** дублируется в root.

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
- `ПКМ` или клавиша `F` — context action: placement/repair в режиме блока,
  сварка каркаса в режиме сварочного пистолета;
- `X` — dismantle выбранного элемента;
- `ЛКМ` сохраняет ручной voxel drill.

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
4. повредить элемент через доменную команду и восстановить repair;
5. демонтировать элемент с возвратом части установленных материалов.

## Acceptance

1. Все пять construction-команд применяют состояние только через
   `SimulationWorld`.
2. Placement/weld/repair атомарно учитывают simulation-owned Store.
3. Frame, operational и damaged однозначно вычисляются и отображаются; lethal
   damage удаляет элемент из topology.
4. Dismantle и lethal damage корректно удаляют пустую Assembly и разделяют
   disconnected graph; dismantle возвращает материалы, destruction — нет.
5. Stable `ElementId` приходит из physics projection в `InteractionQuery`.
6. Preview и visual projection не мутируют simulation; preview collider poses
   совпадают с projection для multi-cell archetypes (`test_construction_preview`).
7. Snapshot сохраняет stores, installed BOM и state revision.
8. Anchored base и mobile rover продолжают использовать один kernel.

## Не входит

- Industry Flow, cargo ports и производство ресурсов;
- inventory/hotbar UI сверх выбора archetype и счётчика;
- fatigue/load graph и автоматический физический `break`;
- симуляция `condition`;
- строительство на движущейся Assembly;
- финальные модели, weld VFX/SFX и баланс vertical slice.
