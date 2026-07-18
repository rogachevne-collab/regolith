# Industry v1

Статус: production milestone после Construction v1.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md`;
- `docs/specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md`;
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/CONSTRUCTION-V1.md`;
- `docs/specs/PLAYER-INTERACTION-V1.md`;
- `docs/specs/HUD-UI-01.md`.

## Индекс (для агентов: не читай файл целиком — найди термин и читай его раздел)

| Термин / вопрос | Раздел |
|---|---|
| scope, что входит / не входит в v1 | «Границы» |
| ItemType, ItemCatalog, категории предметов | «Система предметов» → «ItemType catalog» |
| инструменты игрока, hotbar, instances | «Система предметов» → «Player tool instances и hotbar» |
| raw_regolith, construction_component, ресурсы slice | «Ресурсы slice» |
| ISRU цепочка, crush vs sinter, рецепты | «Dual-path ISRU» |
| SimulationResourceStore, capacity, buffers | «Store model» |
| cargo_pipe, auto-link, cargo graph, transfer | «Cargo Flow» |
| connect_network, wires, 3D mesh | «Network links (electric wires)» |
| power budget, supply/draw, SE on/off | «Electric Flow» |
| stationary drill, contact, mining tick | «Stationary drill» |
| voxel carve, excavation, hand drill, loot pile | «Terrain excavation» |
| Voxel scale, VoxelSpaceUtil, raycast, spawn Y | «Terrain excavation» → «Voxel scale (v1)» |
| Processor, Fabricator, recipe queue | «Processor / Fabricator runtime» |
| status, reason, no_power, storage_full | «Functional status» |
| player store vs machine stores | «Player store vs industry» |
| industry_tick, порядок симуляции | «Simulation tick» |
| snapshot fields для Industry | «Snapshot (Industry fields)» |
| TransferResource, SetMachineEnabled, команды | «Commands (Industry)» |
| HUD, wire projection, UX | «Presentation / UX» |
| acceptance criteria, test_industry_v1 | «Acceptance» |
| порядок реализации | «Implementation order» |

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

- keyed `SimulationResourceStore` с объёмной `capacity_l` и per-archetype
  лимитами;
- internal buffers на элементах + отдельные stores у `cargo_store`;
- cargo: **модули `cargo_pipe`** (Construction v1) + **auto-link** face-adjacent cargo-портов;
- hybrid logistics: auto-transfer по cargo-графу + **ручной** перенос через
  терминал-инвентарь (player ↔ machine/store);
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
- consumables и bottle use (аптечки, пополнение SuitState из баллонов);
- строительство/Industry на движущейся Assembly;
- fluid/gas/thermal/data Flow;
- scripted tutorial для `no_power` / `storage_full`;
- финальный art pass и полный баланс экономики.

## Система предметов

### `ItemType` catalog

Единый `ItemCatalog` — authoritative fixture всех переносимых cargo/inventory
типов. `ResourceCatalog` является временным именем реализации и не меняет
доменный контракт. Каждый entry имеет:

```text
ItemType {
  id
  category              # ore | material | ingot | component | tool | consumable | bottle
  mass_per_unit_kg
  volume_per_unit_l
  unit                  # bulk | discrete
}
```

`mass_per_unit_kg` всегда участвует в mass coupling, `volume_per_unit_l` —
в единственном ограничении вместимости. `amount` остаётся единицей recipe I/O,
а не килограммами и не литрами.

| `item_id` | category | unit | `mass_per_unit_kg` | `volume_per_unit_l` |
|---|---|---|---:|---:|
| `raw_regolith` | `ore` | `bulk` | 2.0 | 2.5 |
| `regolith_fines` | `ore` | `bulk` | 1.5 | 1.8 |
| `sintered_basalt` | `material` | `bulk` | 3.0 | 1.5 |
| `calcined_oxide` | `material` | `bulk` | 1.2 | 1.0 |
| `metal_ingot` | `ingot` | `bulk` | 4.0 | 0.6 |
| `construction_component` | `component` | `discrete` | 2.5 | 3.0 |
| `tool_hand_drill` | `tool` | `discrete` | 3.0 | 8.0 |
| `tool_welder` | `tool` | `discrete` | 2.5 | 6.0 |
| `tool_grinder` | `tool` | `discrete` | 2.8 | 7.0 |
| `tool_connector` | `tool` | `discrete` | 1.5 | 4.0 |

Значения — v1 fixtures, калибруемые playtest; менять их можно только вместе с
балансом ёмкостей. Категории `consumable` и `bottle` зарезервированы, но их
предметы и использование не входят в этот slice.

### Player tool instances и hotbar

Инструменты игрока — **уникальные discrete instances**, не stack count в
`SimulationResourceStore`. Bulk-компоненты и руда остаются amount-based stacks;
tools живут в `PlayerInventoryRegistry` (authoritative fixture рядом с player
store) и участвуют в общем лимите `capacity_l` игрока через derived volume/mass.

```text
InventoryItemInstance {
  instance_id            # stable string, e.g. starter_tool_drill
  item_id                # tool_* из ItemCatalog
}

HotbarSlotRef {
  page, slot             # toolbar page/slot index
  instance_id              # ссылка на InventoryItemInstance; не дублирует item_id
}
```

Контракт:

- hotbar tool-слот хранит **только** `instance_id`; выбор слота резолвит
  `item_id → active_tool` и отклоняется, если instance отсутствует у игрока;
- удаление instance (terminal transfer out, authoritative remove) **очищает**
  все hotbar refs на этот id; слот становится пустым, tool action блокируется;
- один `instance_id` не может быть привязан к двум слотам одновременно; повтор
  того же `item_id` требует отдельного instance (не stack);
- transfer tool **из** player: команда несёт `instance_id`, instance удаляется,
  destination получает stack `+1` того же `item_id` (cargo store model);
- transfer tool **в** player: stack `-1` у source, создаётся **новый**
  `instance_id` (не восстанавливает старый hotbar ref автоматически); один
  terminal transfer создаёт ровно один instance, даже если source stack больше;
- starter migration (fresh world / legacy snapshot без registry): детерминированные
  ids `starter_tool_drill|welder|grinder|connector` и default hotbar bindings
  page 0 slots `0,1,2,8` — см. `PlayerInventoryRegistry` fixture. Snapshot с
  duplicate/stale refs нормализуется deterministically: slot keys сортируются,
  первый валидный ref сохраняется, остальные очищаются;
- terminal grid передаёт `instance_id` в drag payload только для player-owned
  tool instance. Его можно перетащить на matching fixed tool-slot toolbar;
  rebind очищает старый slot этого instance. Новые instance остаются unbound до
  такого явного действия.

Presentation (`ToolController`, terminal grid) не fabricates instances: toolbar
binding идёт через authoritative `assign_player_hotbar_instance`. Consumables /
bottle use — вне scope; см. § Границы.


### Количество и квантование

- `bulk` хранится и передаётся как finite `float >= 0`; добыча и recipes могут
  выдавать дробное количество без округления.
- `discrete` хранится и передаётся только как `int >= 0`. Любая попытка
  authoritative add/remove/set с дробной частью отклоняется, без частичной
  мутации.
- Результат переноса всегда ограничивается доступным количеством и свободным
  объёмом получателя; для `discrete` результат квантуется вниз до целого.
- Нулевой результат — отказ команды (`storage_full` либо insufficient amount),
  а не успешный пустой transfer.

### Объём, масса и вместимость

```text
used_l       = Σ(amount[item_id] × volume_per_unit_l)
mass_kg      = Σ(amount[item_id] × mass_per_unit_kg)
max_addable  = (capacity_l - used_l) / volume_per_unit_l
```

`capacity_l` — единственный лимит Store/buffer. Масса не ограничивает перенос,
но продолжает влиять на `element.mass_kg`. Все capacity checks выполняются
атомарно до mutation; mixed item types допустимы, число visual slots не
ограничено.

| Владелец | `capacity_l` v1 |
|---|---:|
| player store | 100 |
| `cargo_store` | 2,000 |
| `stationary_drill` internal buffer | 200 |
| `processor` internal buffer | 100 |
| `fabricator` internal buffer | 100 |

## Ресурсы slice

| `resource_id` | Роль |
|---|---|
| `raw_regolith` | Добытый реголит |
| `regolith_fines` | Дроблёный реголит (общий промежуточный) |
| `sintered_basalt` | Короткая ветка — дешёвый строй-материал |
| `calcined_oxide` | Обожжённый концентрат (металл-ветка) |
| `metal_ingot` | Восстановленный металл |
| `construction_component` | Precision-деталь (стройка, сварка, industry BOM) |

Каждый `resource_id` в recipes — `item_id` из § Система предметов. Recipe I/O
остаётся в amount; volume и mass derived через ItemCatalog. Authoritative
fixture-значения ItemCatalog / Recipe / capacities / drill tuning вынесены в
`resources/balance/game_balance.json` (`docs/specs/GAME-BALANCE-V0.md`) без
смены команд.

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
| `store_id = "player"` | Единый карман скафандра: 100 L; предметы всех категорий
  конкурируют за общий объём |
| `store_id = "element:{id}"` | `cargo_store` — основной склад базы; **без лимита
  на число типов items**, только `capacity_l` (2,000 L) |
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

- каждый archetype с Store/buffer задаёт `capacity_l` (§ Система предметов);
- смешанные `item_id` в одном store **разрешены**;
- `storage_full` когда `used_l >= capacity_l`;
- player store имеет один общий объём, без раздельных category pockets;
- keyed store и buffer serialise `capacity_l`; старые snapshot поля
  `capacity_kg` мигрируются в fixture capacity и далее не записываются.

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
operational элементов (включая соседние блоки из **разных** Assembly, если
порты стыкуются):

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

- pickup: machine buffer / `cargo_store` → `player` (до volume limit);
- deposit: `player` → `cargo_store` / drill buffer;
- атомарная проверка source amount, item quantization и destination volume до
  мутации.

Команда принимает `{from_store_id, to_store_id, item_id, requested_amount}` и
возвращает фактически перенесённое `amount`; source и destination могут быть
player store, keyed store или internal buffer. При full destination команда не
удаляет source amount.

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
3. лимит **999 m** (`max_cable_length_m`, placeholder v1) применяется к
   **каждому пролёту** polyline port anchor → `waypoints[]` → port anchor:
   суммарная длина не ограничена, но скоба нужна минимум каждые 999 m;
   кабель без waypoints (межгридовая «пуповина») — один пролёт, т.е.
   обычные 999 m;
3a. оба endpoint — **энергоинфраструктура** (source / distributor / battery),
   иначе `endpoint_not_wireable`; consumers к проводам не подключаются —
   их питает distributor radius;
4. face adjacency и взаимная ориентация портов **не требуются**;
5. endpoints могут принадлежать разным Assembly; electric link не создаёт Joint,
   не объединяет topology и не вызывает mechanical merge;
6. duplicate pair rejected.

`disconnect_network` удаляет wire по `link_id` или паре портов.
Player UX: wire рендерится с interaction-only коллайдером
(`KIND_ELECTRIC_CABLE`); **grinder** по кабелю → `disconnect_network`
(«срезать кабель»).

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
может продолжать supply graph. Consumers в cable-chain не включаются
(`endpoint_not_wireable`).

### Anti-garland (cargo)

Несколько `cargo_store` соединяются **pipe-модулями**; к `processor` достаточно **одной**
ветки pipe от кластера — не обязательно от каждого склада отдельный коридор, если
граф connected.

### Wire presentation

- `IndustryNetworkProjection`: **wire mesh** только для `electric_links[]`;
- cargo: визуал = **geometry placed blocks** (`cargo_pipe`, machines); optional joint
  decal на auto-adjacent стыке (presentation-only, R4).

### Player UX (connect tool — electric only)

1. Mode **connect**; первый клик — энергоблок (source/distributor/battery);
   финальный клик — второй энергоблок → wire. Клик по машине/consumer —
   не endpoint, а обычная поверхность для скобы.
2. **Свободная протяжка (скобы):** между первым и финальным кликом клики по
   поверхностям (terrain, любые блоки без wireable-портов) добавляют
   world-space **waypoints** — кабель идёт по полу/стенам/потолку как
   проложил игрок. Лимит 999 m — **на пролёт**: длинная трасса требует скобу
   минимум каждые 999 m. ПКМ — убрать последнюю скобу; ПКМ без скоб —
   отменить протяжку. Waypoints прибиты к миру и не следуют за движущимися
   Assembly (межгридовый кабель — прямая «пуповина» без скоб, один пролёт).
3. **Преграды:** каждый новый пролёт проверяется raycast'ом при клике —
   скоба или финальное подключение сквозь terrain/объекты отклоняются
   (toast «Провод упирается в препятствие»). Проверка выполняется на
   клике (presentation-слой); ядро line-of-sight не хранит.
4. Ghost polyline (`CableRoutingPreview`) рисует протяжку от **ближайшего
   электропорта** pending блока через скобы до прицела.
5. **Cargo:** connect tool **не используется** — только placement `cargo_pipe` blocks.
6. Overlength (по пролёту): HUD toast «Пролёт кабеля длиннее 999 м — нужна скоба».
7. Wire presentation: тонкий чёрный кабель (spline tube — изгибы гладкие),
   лёгкое провисание на span; grinder по любому сегменту срезает кабель.
8. **Радиус распределителя:** при прицеле на `power_distributor` удерживай **`/`**
   — `PowerRadiusPreview` рисует горизонтальное кольцо `supply_radius_m` и
   тонкие линии к consumers внутри радиуса (зелёные = сейчас powered,
   бледные = в радиусе, но без питания).

### Player UX (power radius inspect)

1. Прицел на operational `power_distributor` (≤ 4 m).
2. Удерживай **`/`** (`show_power_radius`).
3. Кольцо: голубое, если distributor на supplied electric network; янтарное —
   если сеть без source/battery.
4. Линии к machines в радиусе; маркер ярче, если consumer сейчас `powered`.

## Electric Flow

### Архетипы v1

| `archetype_id` | Role | Назначение |
|---|---|---|
| `power_source` | Source | Простой генератор slice (не ветер/солнце) |
| `power_distributor` | Hub | Распределяет питание в **радиусе** |
| `power_battery` | Tank | Накопитель энергии (kWh), заряд/разряд в budget |
| `power_distributor_small` | Hub | Компактный distributor ровера, радиус **6 m** |
| `power_battery_small` | Tank | Компактная батарея ровера, **2.5 kWh** |

Новые fixtures: `resources/archetypes/slice01/power_distributor.tres`,
`power_battery.tres`. Малые варианты для ровера
(`power_distributor_small`, `power_battery_small`) — `specs/ROVER-MODULES-V1.md`;
`drive_wheel` — новый consumer (idle **20 W**, под тягой **300 W**), питается
радиусом distributor, к проводам не подключается.

- `power_source.output_w`: fixture placeholder **2000 W**;
- `power_distributor.supply_radius_m`: fixture placeholder **12 m**;
- `max_cable_length_m`: fixture/runtime placeholder **999 m**;
- manual electric wires соединяют **только** энергоинфраструктуру:
  source/generator cluster, `power_distributor`, optional `power_battery`;
- stationary drill / processor / fabricator к проводам не подключаются
  (`endpoint_not_wireable`): consumers питает supplied distributor
  **пространственно в радиусе** — одна модель питания машин.

### Electric graph

Electric subgraph = `electric_links[]` (manual wires между supply nodes).
Component **supplied**, если содержит enabled operational source или battery
(component без distributor может, например, заряжать свои батареи).
Consumers в graph не входят: их питает supplied distributor wireless/radius
distribution внутри `supply_radius_m`. См. § Network links.

### Power budget (SE on/off)

Каждый tick для каждого supplied electric component (enabled source или battery):

1. `supply_w` = Σ `power_source.output_w` (enabled, operational) + battery discharge
   (если подключена);
2. `demand_w` = Σ `idle_w` + active recipe `power_w` для enabled operational consumers
   **в радиусе distributor** компонента;
3. если `supply_w >= demand_w` → consumers ON; иначе OFF → `no_power`;
4. consumer **вне `supply_radius_m`** distributor → `outside_power_radius` (не
   `no_power`);
5. **без** partial slowdown; **без** priority queue в v1;
6. battery: charge surplus, discharge deficit до `max_kwh`; `charge_w`/`discharge_w`
   caps per fixture;
7. first-time seed (`battery_initialized`): пустая неинициализированная батарея
   может быть заряжена до `max_kwh` один раз (spawn / первая посадка);
   **повторный refill при seat enter запрещён** — иначе транспорт едет
   бесконечно. Заряд от `power_source` по-прежнему пишет `battery_kwh` и
   ставит `battery_initialized`.

### Distributor radius

- `power_distributor` задаёт `supply_radius_m` (fixture placeholder **12 m**);
- consumer внутри радиуса supplied distributor получает питание spatially —
  это **единственный** путь питания машин (провода к consumers запрещены);
- consumer вне радиуса от **любого supplied** operational enabled
  distributor → `outside_power_radius` (HUD → «ВНЕ ЗОНЫ»);
- если supplied networks отсутствуют вовсе → `port_disconnected`;
- consumer в радиусе, но `supply_w < demand_w` → `no_power`.

### Machine enable

- `SimulationElement.machine_enabled: bool` (default `true` when operational);
- toggle через `SetMachineEnabledCommand` или interaction;
- disabled: standby draw = 0, не стартует recipe, не mines.

## Stationary drill

Role `Tool`, archetype `stationary_drill`.

### Behavior (tick, enabled, operational, powered)

1. probe voxel-terrain contact from the visible working tip (`+X`, offset
   `drill_head_offset_m` = 1.45 m from footprint pivot, matching
   `stationary_drill_visual.tscn`) along the oriented working face; tip pose
   uses the element's projected physics body (required for piston carriage);
   contact ray reach `drill_contact_reach_m` = 1.4 m beyond the tip;
   **physics terrain collider first**, SDF samples along the working axis,
   backward physics ray at the tip, then SDF raycast fallback;
2. without contact: no carve, no credit, reason `no_terrain_contact` (rotor spin
   may continue while enabled, powered, and operational — see below);
3. carve runs even when the internal buffer or outbound cargo path cannot accept
   more output; excess yield is discarded, status reports `storage_full` while
   mining continues;
4. voxel carve at the working tip (reuse `VoxelTool.MODE_REMOVE` sphere/stamp;
   radius `drill_carve_radius_m` = 1.25 m; center offset factor 0.2 along +X
   from contact so the bite stays at the tip face);
5. measure removed SDF voxel volume from the actual edit and credit
   `raw_regolith` mass ∝ measured volume (`kg_per_m3`); production never substitutes
   a default production volume; credit only what fits in the buffer;
6. deposit into the internal buffer and auto-push into the cargo graph;
7. a fixed-grid drill excavates only terrain within head reach. Once that reachable
   local volume is empty it reports `no_terrain_contact`; continuous advance needs a
   future mechanical feed/piston and is outside v1;
8. buffer full or blocked outbound → status `storage_full`, carving continues;
9. без power / disabled / incomplete → stop mining + reason; rotor spin and
   operation VFX follow **enabled ∧ powered ∧ operational**, independent of
   `no_terrain_contact`;
10. `SetMachineEnabledCommand` applies to `stationary_drill` (terminal toggle and
    HUD readout); disabled drills do not mine or spin.

Headless acceptance may inject deterministic contact-probe and carve-result hooks;
those hooks do not define production yield semantics.

### Ports

- `power_in` (electric);
- `cargo_out` (cargo) — добавить в archetype fixture.

## Terrain excavation

`TerrainExcavationService` — единственный владелец terrain edit для ручного,
стационарного и будущих динамических буров. Каждый инструмент передаёт
`ExcavationRequest` в **мировых метрах**; сервис конвертирует геометрию в
локальные координаты `VoxelTerrain` через `VoxelSpaceUtil` (uniform scale узла
= размер вокселя в метрах). Измеренный occupancy-delta умножается на
`voxel_size³`, поэтому `ExcavationResult.removed_volume_m3` остаётся в
**мировых** м³.

### Voxel scale (v1)

- `VoxelTerrain` в `main.tscn`: uniform scale **0.65** (официальный workaround
  плагина; свойства `voxel_size` у узла нет).
- `max_view_distance` terrain ≈ **200** локальных вокселей (≈128 м мира /
  0.65); иначе плагин клампит `VoxelViewer` и блоки вокруг игрока не грузятся.
- `VoxelViewer` игрока: `view_distance` ≈ **197** (128 м / 0.65).
- **VoxelSpaceUtil:** `VoxelTool.raycast` — **Godot world-space**
  origin/direction/max_distance (плагин сам учитывает transform terrain);
  world hit = `origin + direction * hit.distance`. Редактирование SDF
  (`do_sphere`, …) — через `world_to_local`. При scale ≠ 1 SDF-Y может быть
  выше mesh/collider; **якорь посадки** (spawn, base, ground placement) берёт Y
  из physics collider, SDF — fallback до готовности коллизии.
  `generate_collisions = true` на terrain обязателен. Прицел/бур/проекция на
  terrain — physics raycast (collider); SDF-raycast — fallback без collider.
- **Bootstrap spawn:** gate только по SDF-raycast игрока и корабля; высота
  спавна — `resolve_ground_surface_y` (physics если есть, иначе SDF), без
  ожидания готовности collider. Physics floor — через `begin_spawn_settle`.
  (`BaseSpawn`, 5 SDF-проб) — **async после** посадки игрока, не блокирует
  старт мира.
- Генератор height/noise задан в мировых метрах; вертикальный масштаб рельефа
  не сжимается вместе с узлом.

### Collectible fraction

Явный параметр `IndustryArchetypeProfile.terrain_collectible_fraction`
(дефолт **0.01**): доля **измеренной** вырезанной массы, которая становится
`raw_regolith`; остальное — «пыль». Это игровой контракт темпа добычи, не
post-factum cap. При edge-bite ~0.01–0.1 м³/тик, плотности 1500 кг/м³ и
интервале 0.08 с ручной бур даёт целевой темп **~1–2 кг/с**. Стационарный бур
использует тот же коэффициент.

- Пустота, цель вне рабочей дальности и недоступный terrain возвращают пустой
  результат: edit, yield и feedback отсутствуют.
- Результат не зависит от числа кадров или повторного попадания в уже пустую
  область. Инструменты не начисляют объём по геометрической формуле и не
  ограничивают post-factum yield после более крупного edit.
- В v1 `TerrainMaterialSource` преобразует подтверждённый объём ×
  `terrain_collectible_fraction` в `raw_regolith`. Это отдельный интерфейс, а не
  вывод из terrain shader; semantic material layers с voxel data, генерацией,
  rendering и persistence — следующая работа.
- `InteractionQuery` получает terrain contact из SDF, поэтому удерживаемый бур
  продолжает работать без движения курсора, даже пока physics collider
  перестраивается.

### Hand drill carving recipe

Ручной бур (радиус **0.65 м**, bite **0.18 м**, `sdf_scale` **0.8**):

1. Каждый принятый тик: `do_sphere` с центром, сдвинутым **вглубь** на
   `radius - bite`, чтобы врезалась только кромка (upstream VoxelTool Note 4).
2. Между тиками при смещении прицела: `do_path` sweep от предыдущего bite-center
   к текущему (непрерывный канал).
3. `grow_sphere` не используется.

Yield из результата сначала передаётся в player resource store; остаток
создаёт world loot pile в **точке контакта на поверхности** (aim hit), не в
центре carve. Презентация — `RigidBody3D` (Jolt): pile падает и скатывается
по terrain под лунной гравитацией; осевшая поза **write-back** в
`WorldLootPile.position` через `WorldLootProjection` →
`SimulationWorld.sync_world_loot_position`. Коллайдер pile — **layer 8**;
`collision_mask` pile = terrain (1) + loot (8). Игрок **не** коллайдится с
лутом (`collision_mask` игрока = terrain + bodies, без layer 8); прицел
(`InteractionQuery`, mask 13) и pickup по-прежнему бьют layer 8. Terrain
принимает контакт с loot (`VoxelTerrain.collision_mask |= 8` при bind
проекции). Merge когда **collision-сферы касаются** (радиус от массы pile,
`hand_drill_loot_collision_radius_m`, + contact epsilon); cap
`hand_drill_loot_pile_max_mass_kg`. При spawn — overlap-check; после
скатывания — `RigidBody3D.body_entered` → `try_merge_world_loot_piles`.
Политика pile — контракт `SimulationWorld`, не часть carve.

### Stationary drill

Stationary drill строит тот же request от своей ориентированной рабочей головки.
Перед edit он проверяет, что его buffer может принять верхнюю границу результата;
при backpressure terrain не меняется. После непустого результата yield идёт во
внутренний buffer и обычный cargo push. Пустая reachable область даёт
`no_terrain_contact`; дальнейшая проходка требует будущего механического feed.

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
| `resource_stores[]` | keyed stores + `amounts` + `capacity_l` |
| `electric_links[]` | `{ link_id, element_a, port_a, element_b, port_b }` |
| `industry_network_revision` | int |
| element `industry_buffer` | internal buffer amounts + `capacity_l` per element |
| element `industry_machine` | queue, progress, enabled |
| `world_loot_piles[]` | `{ pile_id, position, item_id, amount, despawn_at_s }` |

`WorldLootPile` authoritative (id, resource, mass, despawn); position
синхронизируется из физической проекции. Presentation spawns/updates/removes
`RigidBody3D` at pile add/merge/remove.

## Commands (Industry)

Доменные имена — `docs/PHYSICAL-LANGUAGE.md` § Граница владения (структурные).
Typed GDScript classes:

| Domain / GDScript | Назначение |
|---|---|
| `connect_network` / `ConnectNetworkCommand` | **electric cable only**, output/input |
| `disconnect_network` / `DisconnectNetworkCommand` | remove electric wire |
| `transfer_resource` / `TransferResourceCommand` | manual pickup/deposit (не structural) |
| `set_machine_enabled` / `SetMachineEnabledCommand` | toggle machine |
| `enqueue_recipe` / `EnqueueRecipeCommand` | optional explicit queue |
| `dequeue_recipe` / `DequeueRecipeCommand` | remove queued recipe |

`connect_network` / `disconnect_network` — structural queue через `SimulationWorld`
(как place/weld); increment `industry_network_revision` on success.

Voxel carve от stationary drill — `WorldCommandGateway` internal op (как
`voxel_remove`), не player tool.

## Presentation / UX

- **Target info:** functional + construction reasons;
- **StoreView:** terminal-инвентарь на targeted store/buffer (§ Terminal inventory);
- **VehiclePower HUD:** cabin charge bar + trip ETA while seated
  (`vehicle_power_snapshot`, см. `HUD-UI-01.md` / `ROVER-MODULES-V1.md`);
- **Connect tool:** electric wires only;
- **Port markers:** electric (gold) and cargo (cyan) face decals in build/connect
  modes and on targeted industry blocks; compatible in-range electric endpoints
  highlight green when the second block is aimed (port facing is irrelevant);
- **Cargo pipes:** place `cargo_pipe` via Construction toolbar;
- **Wire mesh:** visible for `electric_links[]` only;
- **VFX/SFX:** minimal operational feedback (drill spin, processor hum) — declarative
  `.tscn` in `scenes/vfx/` where applicable (R4).

### Terminal inventory

Terminal — единственный presentation слой ручного cargo transfer. Он читает
authoritative snapshot и отправляет только typed gateway commands; виджет не
владеет amounts и не рассчитывает итоговую вместимость.

```text
StoreSnapshot {
  store_id, title
  entries: [{ item_id, amount, category, discrete, instance_id? }]
  used_l, capacity_l, mass_kg
  is_machine
  machine: { enabled, recipe_id, recipes[], progress, status } | null
}
```

- Окно, открытое на target, показывает player store слева и target
  store/internal buffer справа. `toggle_inventory` (`I`) открывает solo-вариант
  только с player store.
- `interact` (`E`) на operational element с Store/buffer открывает terminal;
  повторный `E`, `I` или release mouse закрывает его. Пока terminal открыт,
  gameplay input paused/handled. Loot-pile `E` collect сохраняется; мировые
  E-toggle machine и R-enqueue отсутствуют.
- Каждая ненулевая item запись отображается одной растущей visual grid-cell:
  item icon/code и badge количества. Нет slot limit, stack limit или второго
  стека того же `item_id`.
- Панель всегда показывает `Volume used_l / capacity_l` и derived `Mass
  mass_kg`. Volume bar отражает лимит, mass — информационное значение.
- Drag переносит весь стек. Shift-drag переносит половину: для `bulk` —
  половину amount; для `discrete` — `max(1, floor(amount / 2))`. Double-click
  отправляет перенос всего стека в другую открытую панель.
- Drop строит `TransferResourceCommand`; UI обновляется только по completion /
  новому snapshot. Нулевой transfer показывает feedback и не меняет grid.
- Для machine target правая панель дополнительно показывает `enabled`, рецепт,
  очередь, progress и status. Кнопки вызывают `set_machine_enabled`,
  `enqueue_recipe` и dequeue counterpart; они не используют world controls.

Первый набор item icons — цветная плашка с коротким кодом. Его API привязан к
`item_id`, чтобы будущая PNG-графика не меняла terminal или transfer contract.

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
5. Player store and every industry buffer/store are volume-limited; bulk amount
   remains fractional, discrete amount remains integral, and deposit/pickup is
   atomic.
6. Element mass reflects buffer contents (headless assert on drill fill).
7. Machine toggle, queue, freeze on power loss, full refund on cancel.
8. Terminal shows player/target grids, Volume and Mass; drag, Shift-drag and
   double-click obey transfer rules, and machine controls work from the terminal.
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
