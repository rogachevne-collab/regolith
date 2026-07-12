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
preview → frame → operational → damaged → broken
              │          │          │
              └──────────┴──────────┴→ dismantled
                              ↑
                            repair
```

`preview` существует только в presentation. После принятого `place` элемент
появляется в `SimulationWorld`; physics и visual projection читают это состояние,
но не владеют им.

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
| `broken` | `integrity <= 0` | `blocked/element_broken` |

`broken` имеет приоритет над `element_incomplete`. Незавершённый или сломанный
элемент сохраняет массу, collider и structural ports, но functional ports/roles
считаются неактивными.

## BOM и Store

`ElementArchetype.build_requirements` является единственным BOM. Runtime-элемент
хранит фактически установленные количества по `resource_id`.

- `place` устанавливает одну единицу первого требования
  (`min(1.0, required_amount)`);
- `weld` переносит до запрошенного количества в порядке BOM;
- `build_progress = installed_total / required_total`;
- команда атомарно отклоняется до мутации при нехватке материала;
- `dismantle` возвращает `50%` каждого установленного количества;
- `repair` расходует `construction_component`; одна единица восстанавливает
  `25% max_integrity`.

Construction v1 вводит simulation-owned keyed `SimulationResourceStore`.
Стартовый store `player` заменяется cargo/inventory adapter в Industry v1 без
изменения формата construction-команд.

## Команды

Все команды — typed `StructuralCommand`, выполняются последовательно
`SimulationWorld`.

### `PlaceElementCommand`

Поля: target `assembly_id` (`0` для новой foundation), expected topology revision,
archetype, grid pose, grid frame новой Assembly и `store_id`.

Проверки до расхода ID и материалов:

1. archetype и orientation валидны;
2. target Assembly существует и revision актуален;
3. footprint не пересекает occupancy target Assembly;
4. новый элемент имеет хотя бы один совместимый rigid edge;
5. foundation начинает новую Assembly и имеет `anchor` port;
6. anchor-элемент не добавляется к существующей Assembly;
7. store содержит placement-компонент.

Успех создаёт `frame`, rigid/anchor joints, увеличивает topology revision и
публикует `assembly_changed` либо `assembly_spawned`.

### `WeldElementCommand`

Поля: `element_id`, expected state revision, `store_id`, максимальный material
transfer. Команда переносит только недостающий BOM, пересчитывает
`build_progress`, увеличивает state revision и публикует `element_state_changed`.
Topology revision не меняется.

### `DamageElementCommand`

Поля: `element_id`, expected state revision, положительный damage. Уменьшает только
`integrity`; BOM и `build_progress` не меняются.

### `RepairElementCommand`

Поля: `element_id`, expected state revision, `store_id`, максимальный расход.
Атомарно расходует материал и восстанавливает только `integrity`.

### `DismantleElementCommand`

Поля: `element_id`, expected topology revision и `store_id` для возврата.
Команда удаляет все joints и сам элемент, возвращает материалы и:

- удаляет пустую Assembly;
- перестраивает одну оставшуюся компоненту;
- при разрыве графа применяет kernel survivor policy и создаёт отдельные Assembly.

## Revision policy

- topology revision: `place`, `dismantle`;
- element state revision: `weld`, `damage`, `repair`;
- state-команды не вызывают physics rebuild;
- structural events несут command ID и актуальные revision.

## Player flow

```text
Input Map
  → InteractionQuery (voxel или stable ElementId)
  → ToolController
  → WorldCommandGateway
  → typed construction command
  → SimulationWorld
  → physics + visual projection
  → ActionResult
```

Управление v1:

- `1..8` — foundation/frame/beam/power/drill/store/processor/fabricator;
- `C` — поворот выбранного элемента вокруг локальной оси Y;
- `ПКМ` или клавиша `F` — context action: foundation на terrain, placement рядом с готовым
  элементом, weld незавершённого, repair повреждённого;
- `X` — dismantle выбранного элемента;
- `ЛКМ` сохраняет ручной voxel drill.

Preview не выделяет ID и не изменяет world. Он использует ту же authoritative
placement validation, что и команда.

## Presentation

Процедурная visual projection показывает:

- orange translucent — `frame`;
- steel blue — `operational`;
- amber — `damaged`;
- red — `broken`;
- cyan/red translucent ghost — valid/invalid preview.

Presentation не является источником collision, mass, occupancy или состояния.

## Сценарий

После R5 terrain settle игрок получает стартовый запас
`construction_component`. Существующая compatibility-модель `PlacedBlocks`
не используется construction tools. Игрок может:

1. поставить foundation на voxel terrain;
2. поставить любой Slice-01 frame/module рядом по совместимому structural face;
3. заварить frame до operational;
4. повредить элемент через доменную команду и восстановить repair;
5. демонтировать элемент с возвратом части установленных материалов.

## Acceptance

1. Все пять construction-команд применяют состояние только через
   `SimulationWorld`.
2. Placement/weld/repair атомарно учитывают simulation-owned Store.
3. Frame, operational, damaged и broken однозначно вычисляются и отображаются.
4. Dismantle корректно удаляет пустую Assembly и разделяет disconnected graph.
5. Stable `ElementId` приходит из physics projection в `InteractionQuery`.
6. Preview и visual projection не мутируют simulation.
7. Snapshot сохраняет stores, installed BOM и state revision.
8. Anchored base и mobile rover продолжают использовать один kernel.

## Не входит

- Industry Flow, cargo ports и производство ресурсов;
- inventory/hotbar UI сверх выбора archetype и счётчика;
- fatigue/load graph и автоматический физический `break`;
- симуляция `condition`;
- строительство на движущейся Assembly;
- финальные модели, weld VFX/SFX и баланс vertical slice.
