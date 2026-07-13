# Industry v1

Статус: production milestone после Construction v1.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md`;
- `docs/specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md`;
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/CONSTRUCTION-V1.md`;
- `docs/specs/PLAYER-INTERACTION-V1.md`;
- `docs/specs/HUD-UI-01.md`.

## Цель

Замкнуть industrial core loop vertical slice: добыча реголита, переработка по
**ветвящейся лунной ISRU-цепочке**, распределение **электричества** и **груза**,
получение `construction_component` для расширения базы.

Industry v1 вводит authoritative simulation tick для Flow, Store, Recipe и
functional status. Presentation (HUD, wire mesh, VFX) только отображает state и
инициирует команды через `WorldCommandGateway` / `ToolController`.

```text
Input / tick
  → IndustrySimulation (Flow, Recipe, mining)
  → SimulationWorld (stores, element state)
  → ActionResult / status_reason
  → HUD / wire projection / VFX
```

## Границы

### Входит

- keyed `SimulationResourceStore` с **capacity** и **per-archetype** лимитами;
- internal buffers на элементах + отдельные stores у `cargo_store`;
- cargo: **модули `cargo_pipe`** (Construction v1) + **auto-link** face-adjacent cargo-портов;
- hybrid logistics: auto-transfer по cargo-графу + **ручной** pickup/deposit (player ↔ machine/store);
- electric: **ручные** `connect_network` wires + **3D wire mesh**;
- `power_source`, **power_distributor**, **power_battery** archetypes;
- power budget (SE on/off): supply vs draw, без замедления;
- `stationary_drill` contact-gated mining + voxel carve + `raw_regolith` credit;
- hand drill **world loot pile** (как Space Engineers), сбор в store;
- data-driven `Recipe` (5 рецептов, dual-path ISRU);
- Processor/Fabricator: одна активная job + **очередь**;
- machine **enabled/disabled** toggle;
- functional `status` / `reason` для HUD;
- mass element += содержимое internal buffer (v1);
- headless acceptance `test_industry_v1.tscn`.

### Не входит

- ветряки, солнечные панели, Satisfactory-столбы (после slice);
- split после crush (концентрат/хвосты), кислород, volatiles;
- tier машин (Mk2) и duplicate «efficiency recipes»;
- крафт кабеля/трубы как inventory item (link = edge + mesh; без расходуемого предмета);
- conveyors с физическими предметами;
- автоматическая доставка в player store с fabricator;
- строительство/Industry на движущейся Assembly;
- fluid/gas/thermal/data Flow;
- scripted tutorial для `no_power` / `storage_full`;
- финальный art pass и полный баланс экономики.

## Ресурсы slice

| `resource_id` | Роль |
|---|---|
| `raw_regolith` | Добытый реголит |
| `regolith_fines` | Дроблёный реголит (общий промежуточный) |
| `sintered_basalt` | Короткая ветка — дешёвый строй-материал |
| `calcined_oxide` | Обожжённый концентрат (металл-ветка) |
| `metal_ingot` | Восстановленный металл |
| `construction_component` | Precision-деталь (стройка, сварка, industry BOM) |

`ResourceType` в v1 — fixture `resources/industry/resource_catalog.gd` (или `.tres`
array) с полями:

```text
ResourceCatalogEntry {
  resource_id
  display_name_key
  mass_per_unit_kg    # authoritative для capacity и mass coupling
}
```

Placeholder `mass_per_unit_kg` (калибровка в playtest):

| `resource_id` | `mass_per_unit_kg` |
|---|---:|
| `raw_regolith` | 2.0 |
| `regolith_fines` | 1.5 |
| `sintered_basalt` | 3.0 |
| `calcined_oxide` | 1.2 |
| `metal_ingot` | 4.0 |
| `construction_component` | 2.5 |

**Capacity и mass coupling** считают только через catalog:

```text
store_mass_kg = Σ (amount[resource_id] × mass_per_unit_kg)
element_content_mass_kg = Σ buffer/store amounts × mass_per_unit_kg
```

Recipe I/O остаётся в **штуках** (amount); mass — derived для лимитов и projection.
Отдельный `.tres` catalog может появиться позже без смены команд.

## Dual-path ISRU

Одна добыча — **две ветки** с разным игровым смыслом. Разная эффективность одного
и того же преобразования — **tier машины** (Mk2+), не отдельные рецепты.

```text
raw_regolith
     │  crush_regolith (Processor)
regolith_fines
     ├─ sinter_basalt (Processor) ──→ sintered_basalt  ★ ~2 min win
     │
     └─ calcine_fines (Processor) ──→ calcined_oxide
              │ reduce_oxide (Fabricator)
         metal_ingot
              │ sinter_component (Fabricator)
    construction_component  ★ slice goal
```

### Рецепты (fixtures v1)

| `recipe_id` | Machine | Inputs | Outputs | `duration_s` (placeholder) | `power_w` (placeholder) |
|---|---|---|---|---:|---:|
| `crush_regolith` | Processor | 1 raw | 1 fines | 6 | 200 |
| `sinter_basalt` | Processor | 2 fines | 1 basalt | 8 | 250 |
| `calcine_fines` | Processor | 2 fines | 1 oxide | 10 | 400 |
| `reduce_oxide` | Fabricator | 1 oxide | 1 ingot | 12 | 600 |
| `sinter_component` | Fabricator | 1 ingot | 1 component | 10 | 500 |

Числа калибруются под **~3 min** до первого `construction_component` и **~2 min**
до первого `sintered_basalt` при минимальной базе; headless fixture допускает
stub durations до playtest.

### `sintered_basalt` как строй-материал

- хранится в Store как resource;
- placement archetype `frame_basalt` (PoC fixture) расходует `sintered_basalt` из
  store вместо/вместе с `construction_component` по BOM archetype;
- weld/BOM для basalt-frame — отдельный lighter BOM в archetype fixture.

## Store model

### Типы хранилищ

| Владелец | Назначение |
|---|---|
| `store_id = "player"` | Карман скафандра: construction + ручной pickup; **лимит по mass_kg** |
| `store_id = "element:{id}"` | `cargo_store` — основной склад базы |
| Internal buffer | `stationary_drill`, `processor`, `fabricator` — малые in/out буферы на `SimulationElement` |

Internal buffer сериализуется в snapshot element state; keyed store — в
`resource_stores[]`; world loot — в `world_loot_piles[]` (см. § Snapshot).

### Cargo-порты (archetype fixtures)

Каждый industry-блок с логистикой обязан иметь ≥1 `PortDefinition.Kind.CARGO`.
Имена (`cargo_in`, `cargo_out`, `cargo_io`) — authoring labels; граф **undirected**.

| `archetype_id` | Cargo port(s) | Примечание |
|---|---|---|
| `stationary_drill` | `cargo_out` | **добавить** в fixture |
| `cargo_store` | `cargo_io` | ≥1 порт на гранях |
| `cargo_pipe` | `cargo_through` ×6 | **новый** placeable модуль (§ Pipe modules) |
| `processor` | `cargo_io` | |
| `fabricator` | `cargo_io` | |

Routing (push/pull) решает tick, не имя порта. **Соединение** — только
auto-adjacency (§ Cargo Flow); distant — цепочка **`cargo_pipe`** блоков.

### Capacity

- каждый archetype с Store/buffer задаёт `storage_capacity_kg` (fixture);
- смешанные resource_id в одном store **разрешены**;
- `storage_full` когда Σ mass contents ≥ capacity;
- player store: `player_carry_capacity_kg` (bootstrap fixture, placeholder **80 kg**).

### Mass coupling (v1)

`element.mass_kg` для projection = `archetype.mass_kg` + Σ content mass internal
buffer (+ keyed store для `cargo_store` role). Важно для mobile Assembly.

## Cargo Flow

### Pipe modules (Space Engineers model)

**`cargo_pipe`** — обычный construction-элемент (place → weld → operational), как
`frame` или `cargo_store`. Не abstract span mesh и не connect-tool.

- archetype fixture: lightweight BOM (`sintered_basalt` или `construction_component`);
- 1×1 footprint; **cargo-порт на каждой грани** (`cargo_through`), undirected pass-through;
- visual = mesh блока (element projection); **отдельный pipe mesh между distant портами
  не создаётся**;
- цепочка pipe блоков = физическая «труба» игрока через застройку.

### Topology (auto-link only)

Cargo graph **не** использует `connect_network`. При изменении `topology_revision`
runtime строит undirected edges между **face-adjacent** cargo-портами любых
operational элементов одной Assembly:

- machine ↔ machine (drill вплотную к store);
- machine ↔ `cargo_pipe`;
- `cargo_pipe` ↔ `cargo_pipe` (коридор/лестница труб).

**На расстоянии:** игрок **ставит** сегменты `cargo_pipe` (Construction v1) между
машинами; каждый стык adjacent → auto edge. Разобрал pipe → edge пропал.

Duplicate adjacent pair — одно ребро. Cargo edges **не** в snapshot как `electric_links[]`
— только derived graph из topology.

### Auto-transfer (1 Hz tick)

- push/pull вдоль connected components;
- drill internal buffer → nearest **`cargo_store` по cargo-графу** (fewest hops); tie-break
  lower `element_id`; requires **pipe path** drill port → … → store;
- processor/fabricator: pull inputs from connected stores into internal input buffer;
  push outputs to connected stores;
- backpressure: `storage_full` на получателе останавливает отправителя;
- player store **не** в cargo graph.

### Manual transfer

Команда `TransferResourceCommand` через `WorldCommandGateway`:

- pickup: machine buffer / `cargo_store` → `player` (до mass limit);
- deposit: `player` → `cargo_store` / drill buffer;
- атомарная проверка capacity и mass до мутации.

Interaction: target panel prompt + hold/press на operational store/drill.

## Network links (electric wires)

`connect_network` / `disconnect_network` — **только `Kind.ELECTRIC`**. Cargo — pipe
modules + auto-link (§ Cargo Flow); `connect_network` для cargo **не используется**.

Bump `industry_network_revision`. Snapshot: `electric_links[]`.

```text
ElectricLink {
  link_id
  element_a, port_a
  element_b, port_b
}
```

### Валидация `connect_network` (electric)

1. оба parent elements **operational**;
2. оба порта `Kind.ELECTRIC`, direction-compatible output → input
   (bidirectional допускается явно);
3. world-space distance между port anchors ≤ **12 m** (`max_cable_length_m`,
   placeholder v1);
4. face adjacency и взаимная ориентация портов **не требуются**;
5. endpoints могут принадлежать разным Assembly; electric link не создаёт Joint,
   не объединяет topology и не вызывает mechanical merge;
6. duplicate pair rejected.

`disconnect_network` удаляет wire по `link_id` или паре портов.

### Link dormancy (electric)

Временные условия НЕ удаляют link из `electric_links[]`:

- endpoint не operational (повреждён, недостроен) → link **dormant**;
- world-space длина кабеля превысила `max_cable_length_m`
  (endpoint на другой Assembly уехал) → link **dormant**;
- dormant link выпадает из electric graph (не проводит) и **оживает
  автоматически**, когда условие снято (ремонт endpoint, возврат в радиус
  длины) — повторный `connect_network` не требуется;
- presentation: dormant wire рендерится приглушённым (без emission);
- удаление из state — только `disconnect_network` или исчезновение endpoint
  element из мира (destroy/dismantle).

### Anti-garland (electric)

Generator cluster состоит только из direction-compatible supply links: generator
outputs могут сходиться на distributor/battery input, а battery/distributor output
может продолжать supply graph. Consumers в эту cable-chain не включаются.

### Anti-garland (cargo)

Несколько `cargo_store` соединяются **pipe-модулями**; к `processor` достаточно **одной**
ветки pipe от кластера — не обязательно от каждого склада отдельный коридор, если
граф connected.

### Wire presentation

- `IndustryNetworkProjection`: **wire mesh** только для `electric_links[]`;
- cargo: визуал = **geometry placed blocks** (`cargo_pipe`, machines); optional joint
  decal на auto-adjacent стыке (presentation-only, R4).

### Player UX (connect tool — electric only)

1. Mode **connect**; click compatible electric output/input ports в пределах 12 m
   → wire.
2. **Cargo:** connect tool **не используется** — только placement `cargo_pipe` blocks.
3. Overlength: HUD toast «Кабель длиннее 12 м». Preview ghost wire optional.

## Electric Flow

### Архетипы v1

| `archetype_id` | Role | Назначение |
|---|---|---|
| `power_source` | Source | Простой генератор slice (не ветер/солнце) |
| `power_distributor` | Hub | Распределяет питание в **радиусе** |
| `power_battery` | Tank | Накопитель энергии (kWh), заряд/разряд в budget |

Новые fixtures: `resources/archetypes/slice01/power_distributor.tres`,
`power_battery.tres`.

- `power_source.output_w`: fixture placeholder **2000 W**;
- `power_distributor.supply_radius_m`: fixture placeholder **12 m**;
- `max_cable_length_m`: fixture/runtime placeholder **12 m**;
- manual electric wires соединяют только source/generator cluster,
  `power_distributor` и optional `power_battery`;
- stationary drill / processor / fabricator не являются wire pass-through:
  supplied distributor питает их **пространственно в радиусе**, без individual
  wire и без включения consumer в `electric_links[]`.

### Electric graph

Electric subgraph = `electric_links[]` (manual wires между supply nodes). Consumers
не обязаны входить в graph: supplied distributor создаёт wireless/radius
distribution внутри `supply_radius_m`. См. § Network links.

### Power budget (SE on/off)

Каждый tick для electric component с enabled operational distributor и подключённым
source/battery:

1. `supply_w` = Σ `power_source.output_w` (enabled, operational) + battery discharge
   (если подключена);
2. `demand_w` = Σ `idle_w` + active recipe `power_w` для enabled operational consumers
   **в радиусе distributor**;
3. если `supply_w >= demand_w` → consumers ON; иначе OFF → `no_power`;
4. consumer **вне `supply_radius_m`** distributor → `outside_power_radius` (не
   `no_power`);
5. **без** partial slowdown; **без** priority queue в v1;
6. battery: charge surplus, discharge deficit до `max_kwh`; `charge_w`/`discharge_w`
   caps per fixture.

### Distributor radius

- `power_distributor` задаёт `supply_radius_m` (fixture placeholder **12 m**);
- consumer внутри радиуса supplied distributor получает питание spatially, даже
  если сам consumer не имеет electric link;
- consumer вне радиуса от **любого supplied** operational enabled distributor →
  `outside_power_radius` (HUD → «ВНЕ ЗОНЫ»);
- если supplied distributor network отсутствует → `port_disconnected`;
- consumer в радиусе, но `supply_w < demand_w` → `no_power`.

### Machine enable

- `SimulationElement.machine_enabled: bool` (default `true` when operational);
- toggle через `SetMachineEnabledCommand` или interaction;
- disabled: standby draw = 0, не стартует recipe, не mines.

## Stationary drill

Role `Tool`, archetype `stationary_drill`.

### Behavior (tick, enabled, operational, powered)

1. probe physical voxel-terrain contact/proximity from the visible working head
   along its oriented local `+X` working face;
2. without contact: no carve, no credit, reason `no_terrain_contact`;
3. before mutation, atomically check buffer/outbound capacity against the maximum
   carve budget; `storage_full` stops before voxel edit (no loss);
4. voxel carve in front of that head (reuse `VoxelTool.MODE_REMOVE` sphere/stamp);
5. measure removed SDF voxel volume from the actual edit and credit
   `raw_regolith` mass ∝ measured volume (`kg_per_m3`); production never substitutes
   a default production volume;
6. deposit into the internal buffer and auto-push into the cargo graph;
7. a fixed-grid drill excavates only terrain within head reach. Once that reachable
   local volume is empty it reports `no_terrain_contact`; continuous advance needs a
   future mechanical feed/piston and is outside v1;
8. buffer full **или** нет outbound cargo capacity → **stop mining**, reason
   `storage_full` (без silent loss; согласовано с cargo backpressure);
9. без power / disabled / incomplete → stop + reason.

Headless acceptance may inject deterministic contact-probe and carve-result hooks;
those hooks do not define production yield semantics.

### Ports

- `power_in` (electric);
- `cargo_out` (cargo) — добавить в archetype fixture.

## Hand drill loot

Hand drill (`ToolController` → `voxel_remove`) **не** credits player store напрямую.

- carved volume spawns **world loot pile** (`WorldLootPile` authoritative, presentation
  mesh/decal) at carve site with `raw_regolith` mass;
- pickup через `TransferResourceCommand` или dedicated collect action в радиусе;
- pile без pickup — persists в snapshot до collect или despawn timer (fixture);
- aligns с IMPACT-DESTRUCTION «regolith не в void» без industry machine.

## Processor / Fabricator runtime

Per element state:

```text
IndustryMachineState {
  enabled
  active_recipe_id
  progress_s
  queue[]        # recipe_id FIFO, max depth fixture (default 4)
  reserved_inputs{}
}
```

Rules:

- старт job: atomic reserve inputs from internal buffer + connected cargo pull;
- tick: `progress_s += dt` if powered; freeze progress if `no_power`;
- cancel before completion: **full refund** reserved inputs to source stores/buffers;
- completion: emit outputs to output buffer → cargo push;
- одна active job; queue processed FIFO;
- default recipe per machine from archetype fixture if queue empty and inputs available.

## Functional status

Construction reasons (`element_incomplete`, …) сохраняются. Industry добавляет
functional layer; HUD показывает functional reason если machine operational но не
работает.

| `reason` | Условие | HUD (placeholder) |
|---|---|---|
| `ok` | Работает или idle без ошибки | РАБОТА |
| `no_power` | В радиусе, но budget fail (`supply_w < demand_w`) | НЕТ ПИТАНИЯ |
| `outside_power_radius` | Нет distributor в `supply_radius_m` | ВНЕ ЗОНЫ |
| `port_disconnected` | Нет нужного network path (electric **или** cargo) | НЕТ СВЯЗИ |
| `no_input` | Нет входного ресурса | НЕТ СЫРЬЯ |
| `no_terrain_contact` | У рабочей головки нет voxel terrain в пределах reach | НЕТ ГРУНТА |
| `storage_full` | Некуда выгрузить / буфер полон | СКЛАД ПОЛОН |
| `disabled` | `machine_enabled = false` | ВЫКЛ |
| `queue_full` | Очередь переполнена | ОЧЕРЕДЬ ПОЛНА |

Construction-blocked (`element_incomplete`) имеет приоритет над industry.

HUD локализация — `docs/specs/HUD-UI-01.md` (расширить `hud_tokens.gd`).

## Player store vs industry

- `store_id = "player"` остаётся для Construction commands (place/weld/repair);
- industry cargo **не** смешивается автоматически с player store;
- fabricator output → connected `cargo_store`; игрок **deposit** в player для стройки;
- bootstrap: **`STARTER_CONSTRUCTION_COMPONENTS = 35`** (placeholder; сейчас в коде
  `120` — меняется при реализации Industry v1), не 120.

## Simulation tick

- `IndustrySimulation.tick(dt)` вызывается из `SimulationSession` с фиксированным
  **1 Hz** accumulator (не per-frame logic);
- **cargo graph:** derived rebuild on `topology_revision` only (auto-adjacent ports);
- **electric graph:** rebuild on `topology_revision` **or** `industry_network_revision`;
- `connect_network` / `disconnect_network` (electric only) increment
  `industry_network_revision`;
- topology change increments `topology_revision`, recomputes cargo graph, prunes dangling
  `electric_links`, bumps `industry_network_revision`;
- mutations только через `SimulationWorld` APIs / typed commands.

## Snapshot (Industry fields)

Дополнение к snapshot v3+:

| Field | Содержание |
|---|---|
| `resource_stores[]` | keyed stores + amounts |
| `electric_links[]` | `{ link_id, element_a, port_a, element_b, port_b }` |
| `industry_network_revision` | int |
| element `industry_buffer` | internal buffer amounts per element |
| element `industry_machine` | queue, progress, enabled |
| `world_loot_piles[]` | `{ pile_id, position, resource_id, amount_kg, despawn_at_s }` |

`WorldLootPile` authoritative; presentation spawns/decspawn visual at pile add/remove.

## Commands (Industry)

Доменные имена — `docs/PHYSICAL-LANGUAGE.md` § Граница владения (структурные).
Typed GDScript classes:

| Domain / GDScript | Назначение |
|---|---|
| `connect_network` / `ConnectNetworkCommand` | **electric cable only**, output/input, ≤12 m |
| `disconnect_network` / `DisconnectNetworkCommand` | remove electric wire |
| `transfer_resource` / `TransferResourceCommand` | manual pickup/deposit (не structural) |
| `set_machine_enabled` / `SetMachineEnabledCommand` | toggle machine |
| `enqueue_recipe` / `EnqueueRecipeCommand` | optional explicit queue |

`connect_network` / `disconnect_network` — structural queue через `SimulationWorld`
(как place/weld); increment `industry_network_revision` on success.

Voxel carve от stationary drill — `WorldCommandGateway` internal op (как
`voxel_remove`), не player tool.

## Presentation / UX

- **Target info:** functional + construction reasons;
- **StoreView:** отдельное окно на targeted `cargo_store` (HUD-UI-01);
- **Connect tool:** electric wires only;
- **Port markers:** electric (gold) and cargo (cyan) face decals in build/connect
  modes and on targeted industry blocks; compatible in-range electric endpoints
  highlight green when the second block is aimed (port facing is irrelevant);
- **Cargo pipes:** place `cargo_pipe` via Construction toolbar;
- **Wire mesh:** visible for `electric_links[]` only;
- **VFX/SFX:** minimal operational feedback (drill spin, processor hum) — declarative
  `.tscn` in `scenes/vfx/` where applicable (R4).

## Acceptance

Industry v1 закрыт, когда:

1. Dual-path: `crush` → `sinter_basalt` и полная ветка до `construction_component`
   работают через stores/cargo без dup/loss on stop/restart.
2. Generator cluster → one wire → distributor; unwired consumers внутри 12 m
   powered spatially; **cargo_pipe** chain drill → store → processor; electric
   **wire mesh** visible только для supply links.
3. Stationary drill requires voxel contact at its oriented visible head, carves only
   reachable terrain, credits raw from measured removed volume, stops before carve
   on `storage_full`, auto-pushes **по pipe graph** when connected; manual pickup works.
4. Hand drill spawns loot pile; collect → player or store.
5. Player store weight-limited; deposit/pickup atomic.
6. Element mass reflects buffer contents (headless assert on drill fill).
7. Machine toggle, queue, freeze on power loss, full refund on cancel.
8. HUD shows industry reasons without debug overlay.
9. `scenes/test_industry_v1.tscn` prints `INDUSTRY-V1: PASS`; строка в
   `tests/run_tests.sh`.
10. Existing PoC + construction tests green.

```bash
./run.sh --headless res://scenes/test_industry_v1.tscn
```

### Headless scenario (minimum)

1. Spawn slice base + **`cargo_pipe`** chain; connect electric wires; enable machines.
2. Simulate N ticks with injected deterministic contact + carve hooks.
3. Assert: ISRU path; cargo connectivity via placed pipes + auto-link; wire projection;
   `storage_full` stop on drill.

## Связь с vertical slice

Supersedes краткое описание Industry в
`VERTICAL-SLICE-01-INDUSTRIAL-BASE.md` § Industry v1: dual-path ресурсы, distributor,
wire mesh, hand loot. Stationary drill contact is authoritative: its visible,
oriented working head must have voxel terrain within reach.

## Implementation order

1. Store capacity + internal buffers + snapshot fields
2. **`cargo_pipe` archetype** + cargo auto-graph + auto-transfer + transfer command
3. Electric wires + budget + distributor radius + battery
4. Wire projection mesh (electric only)
5. Recipe runner + queue + machine state
6. Stationary drill + voxel/loot integration
7. Hand drill loot piles
8. HUD reasons + store window on target
9. Archetype fixtures (`power_distributor`, `power_battery`, `cargo_pipe`, `frame_basalt`, drill `cargo_out`)
10. `test_industry_v1.tscn`
