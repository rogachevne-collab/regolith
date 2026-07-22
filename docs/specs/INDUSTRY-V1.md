# Industry v1

Статус: production milestone после Construction v1.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md`;
- `docs/specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md`;
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/CONSTRUCTION-V1.md`;
- `docs/specs/PLAYER-INTERACTION-V1.md`;
- `docs/specs/HUD-UI-01.md`;
- `docs/specs/TERRAIN-MATERIALS-V1.md` — **канон** рудных зон, typed ores,
  стройкомпонентов, O₂/H₂ и машины `electrolyzer` (замещает dual-path каталог ниже).

## Индекс (для агентов: не читай файл целиком — найди термин и читай его раздел)

| Термин / вопрос | Раздел |
|---|---|
| scope, что входит / не входит в v1 | «Границы» |
| ItemType, ItemCatalog, категории предметов | «Система предметов» → «ItemType catalog»; **актуальный каталог руд/газов/компонентов** — `TERRAIN-MATERIALS-V1.md` |
| инструменты игрока, hotbar, instances | «Система предметов» → «Player tool instances и hotbar» |
| рудные зоны, typed ores, O₂/H₂, electrolyzer | `TERRAIN-MATERIALS-V1.md` |
| ~~raw_regolith, dual-path slice~~ (устарело) | замещено `TERRAIN-MATERIALS-V1.md` |
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

Замкнуть industrial core loop: добыча **typed** руд из зон террейна,
переработка по лунной ISRU-цепочке (стройка + O₂/H₂), распределение
**электричества** и **груза**. Номенклатура предметов и рецептов — канон
`TERRAIN-MATERIALS-V1.md`; ниже оставлены исторические таблицы dual-path до
миграции кода (не использовать как источник истины для новых фич).

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
- `stationary_drill` contact-gated mining + voxel carve + credit по
  `TerrainMaterial` (канон yield — `TERRAIN-MATERIALS-V1.md`);
- hand drill **world loot pile** (как Space Engineers), сбор в store;
- data-driven `Recipe` (канон — `TERRAIN-MATERIALS-V1.md`, включая `electrolyzer`);
- Processor/Fabricator: одна активная job + **очередь**;
- machine **enabled/disabled** toggle;
- functional `status` / `reason` для HUD;
- mass element += содержимое internal buffer (v1);
- headless acceptance `test_industry_v1.tscn`.

### Не входит

- ветряки, солнечные панели, Satisfactory-столбы (после slice);
- fluid/gas/thermal Flow и Atmosphere (баллонный bulk O₂/H₂/water — в
  `TERRAIN-MATERIALS-V1.md`, не как трубы; SuitState refill — later);
- tier машин (Mk2) и duplicate «efficiency recipes»;
- крафт кабеля/трубы как inventory item (link = edge + mesh; без расходуемого предмета);
- conveyors с физическими предметами;
- автоматическая доставка в player store с fabricator;
- строительство/Industry на движущейся Assembly;
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

Актуальная таблица руд / материалов / слитков / газов / стройкомпонентов —
[`TERRAIN-MATERIALS-V1.md`](TERRAIN-MATERIALS-V1.md) § «Каталог предметов».

Инструменты (без смены смысла):

| `item_id` | category | unit | `mass_per_unit_kg` | `volume_per_unit_l` |
|---|---|---|---:|---:|
| `tool_hand_drill` | `tool` | `discrete` | 3.0 | 8.0 |
| `tool_welder` | `tool` | `discrete` | 2.5 | 6.0 |
| `tool_grinder` | `tool` | `discrete` | 2.8 | 7.0 |
| `tool_connector` | `tool` | `discrete` | 1.5 | 4.0 |

Категории `consumable` / `bottle` используются для bulk `water` / `oxygen` /
`hydrogen` (см. TERRAIN-MATERIALS-V1); refill SuitState — later.

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
| `electrolyzer` internal buffer | 80 |

## Ресурсы и ISRU (канон перенесён)

**Канон каталога предметов, рудных зон, рецептов, O₂/H₂ и `electrolyzer`:**
[`TERRAIN-MATERIALS-V1.md`](TERRAIN-MATERIALS-V1.md).

Каждый `resource_id` в recipes — `item_id` из § Система предметов. Recipe I/O
остаётся в amount; volume и mass derived через ItemCatalog. Authoritative
fixture-значения ItemCatalog / Recipe / capacities / drill tuning вынесены в
`resources/balance/game_balance.json` (`docs/specs/GAME-BALANCE-V0.md`) без
смены команд.

Ниже — **устаревший** dual-path Industry v1 (для чтения старых тестов/сейвов до
миграции кода). Новые фичи и fixtures **не** расширяют эту таблицу.

### Legacy dual-path (deprecated)

```text
raw_regolith → crush → fines → sinter_basalt
                            → calcine → metal_ingot → construction_component
```

Удаляются при миграции: `raw_regolith`, `calcined_oxide`, `metal_ingot`,
`construction_component`, рецепты `crush_regolith` / `calcine_fines` /
`reduce_oxide` / `sinter_component`.

## Store model

### Типы хранилищ

| Владелец | Назначение |
|---|---|
| `store_id = "player"` | Единый карман скафандра: 100 L; предметы всех категорий
  конкурируют за общий объём |
| `store_id = "element:{id}"` | `cargo_store` — основной склад базы; **без лимита
  на число типов items**, только `capacity_l` (2,000 L) |
| Internal buffer | `stationary_drill`, `processor`, `fabricator`, `electrolyzer` — малые in/out буферы на `SimulationElement` |

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
  waypoints[]         # скобы, порядок a→b
  waypoint_anchors[]  # параллельно waypoints: element_id крепления, 0 = мир.
                      # anchor > 0 → точка хранится в body-group фрейме блока,
                      # anchor = 0 → world-space. Геометрия читается только
                      # через IndustryElectricPortUtil.resolved_waypoints().
}
```

### CABLE-ROPE-V0: провод — это канат

Провод перестал быть инфраструктурным объектом с правилами и стал **канатом,
проводящим ток**. Требований к установке нет: тянешь от чего угодно к чему
угодно, промежуточные крепления не нужны — канат сам идёт кратчайшим пролётом.

```text
Rope endpoint {
  element_id  # 0 → конец вбит в мир (terrain, валун)
  port_id     # "" на канате; непустой только у legacy port-wire
  attach      # element_id > 0 → точка в body-group фрейме блока (едет с ним),
              # element_id == 0 → мировая точка
}
rest_length_m     # длина каната; слабина = rest_length − прямой пролёт
break_impulse_ns  # порог обрыва
```

Правила ровно три:

1. хотя бы один конец — элемент (канат между двумя точками мира держать
   нечего, `invalid_target`);
2. элемент, если указан, существует (состояние, роль, порты — **не важны**);
3. пролёт не короче `CableAnchorUtil.MIN_SPAN_M`.

**Якорь в землю.** Мировой конец — это точка, прибитая к миру, и она обязана
опираться на грунт: `SimulationPhysicsProjection._tick_cable_anchors` три раза
в секунду щупает сферой (`CABLE_ANCHOR_PROBE_RADIUS`) слой 1 вокруг якоря и,
если земли не осталось (выкопали, взорвали), рвёт канат через
`disconnect_network`. Якорь **не** судится, пока у машинного конца нет живого
RigidBody: незастримленный чанк — это не выкопанная яма.

Ни длины, ни direction-compat, ни `endpoint_not_wireable`, ни проверки
преград, ни дедупликации: сколько угодно канатов между теми же двумя блоками.
Legacy port-wire (оба `port_id` непустые) остаётся валидным и продолжает жить
по старым правилам дальности.

**Форма (`CableRopeSolver`).** Канат — verlet-верёвка: частицы через ~0.45 м,
жёсткие сегменты, `get_rest_info` по слоям terrain+assembly выталкивает каждую
свободную частицу из того, во что она попала. Отсюда всё, чего не могла дать
аналитическая цепная линия: канат **огибает препятствия**, слабина **лежит на
земле, а не проваливается**, и на разном натяге он висит по-разному. Коллизии
идут по бюджету частиц на тик (`CABLE_ROPE_COLLISION_BUDGET`) с вращающимся
стартом, так что лес канатов деградирует в «через тик», а не в просадку кадра.
Состояние частиц — presentation/physics, в снапшот не пишется: при загрузке
верёвка отстраивается из двух якорей и `rest_length_m`.

**Физика (`CableTensionUtil`).** Пока верёвка короче `rest_length_m` — канат не
делает ничего. На натяге — max-distance constraint одним импульсом за тик.
Меряется **длина по фактической трассе** (`solve_routed`), а тянет каждый конец
вдоль **своего первого сегмента**: канат, наброшенный на валун, выбирает слабину
раньше и дёргает к валуну, а не сквозь него. Неподвижный конец (мировой якорь,
frozen body, StaticBody) импульса не получает.

**Обрыв — вместо рывка, а не после него.** Сила считается до применения: если
она выше `break_force_n`, канат рвётся и импульс **не применяется**. Прежний
порядок (применить → сравнить → порвать) означал, что тик обрыва бил сильнее
всех остальных — именно так распиленный со статики ровер улетал в небо с
оборванными кабелями.

Две страховки на плечо импульса: конец, оказавшийся дальше `MAX_LEVER_ARM_M`
от своего тела, игнорируется целиком (у только что отделившейся сборки
трансформ момент невалиден и якорь резолвится у начала координат, за километры;
`ω × r` на таком плече даёт сотни м/с), а `arrest_speed` ограничен
`MAX_ARREST_SPEED`. Скачок якоря дальше `ANCHOR_TELEPORT_M` за тик — это не
движение, а топологическое событие: верёвка пересевается заново, чтобы натяжение
не тянуло вдоль устаревшего сегмента.

**Канат ловит, а не швыряет.** Импульс за тик ограничен ровно тем, что гасит
расхождение, плюс мягкая выборка провиса (`MAX_RECOVERY_SPEED`, 1 м/с). Любая
добавка сверх этого возвращает грузу больше энергии, чем он принёс: лёгкий
предмет на мачте не ловился, а разбивался о собственный рывок. Порог обрыва —
**сила в ньютонах** (`break_force_n`), а не импульс: импульс за тик
пропорционален `delta`, то есть импульсный порог означал бы разную прочность
на разной частоте кадров.

**Вес.** Массу частиц крутить бесполезно: при жёстких дистанционных
констрейнтах и равных массах она сокращается и из формы висящей цепи, и из
динамики — как масса из периода маятника. «Тяжёлый бронированный кабель»
складывается из трёх других величин: `GRAVITY_SCALE` (кабелю ×3 к локальной
гравитации — под 1.62 м/с² любая верёвка читается как тряпка), `DAMPING` и
`SEGMENT_FRICTION` — внутреннее трение, которое тянет скорость частицы к
средней скорости соседей. Трение применяется **к скорости, не к позиции**:
позиционный вариант дрался бы с констрейнтом длины и вернул бы дрожь. Итог:
рябь короткой длины волны гаснет быстро, а качание каната как целого остаётся.

**Покой.** У verlet-верёвки нет точного состояния покоя — каждый проход
оставляет доли миллиметра, и без явного сна она дрожит до конца сессии.
Скорость ниже `VELOCITY_EPSILON_M` обнуляется, а после `SLEEP_AFTER_TICKS`
спокойных тиков верёвка перестаёт симулироваться совсем. Замер движения и сам
сон стоят **до** интегрирования: сон после него означал бы «гравитация есть,
констрейнтов нет» — верёвка тихо проваливалась бы вниз по 0.45 мм за тик.
Движение якорей считается движением, поэтому машина, тронувшись с места,
будит канат в тот же тик.

Почему не Jolt-joint: в Godot/Jolt нет joint-а «максимальное расстояние» —
Pin даёт 0, Slider ось, Generic6DOF коробку в фиксированном фрейме. Столбик,
вбитый в землю, этого не меняет (хотя как объект-якорь он полезен по другим
причинам — см. TODO про `cable_stake`).

**Ток.** Проводит любой канат между двумя operational элементами, у которых
есть электропорт — провод в дрель питает дрель. Distributor radius остался
беспроводным удобством, а не единственным путём. Конец в земле не проводит
ничего: рендерится как верёвка (`ROPE_COLOR`), а не как погасший провод.

### Валидация `connect_network` (legacy port form)

1. оба parent elements **operational**;
2. оба порта `Kind.ELECTRIC` (direction-compat больше не гейт);
3. лимит **999 m** (`max_cable_length_m`, placeholder v1) применяется к
   **каждому пролёту** polyline port anchor → `waypoints[]` → port anchor;
4. face adjacency и взаимная ориентация портов **не требуются**;
5. endpoints могут принадлежать разным Assembly; electric link не создаёт Joint,
   не объединяет topology и не вызывает mechanical merge;
6. duplicate pair rejected (у канатов пары нет — дедупликации нет).

`disconnect_network` удаляет wire по `link_id` или паре портов.
Player UX: wire рендерится с interaction-only коллайдером
(`KIND_ELECTRIC_CABLE`); **grinder** по кабелю → `disconnect_network`
(«срезать кабель»).

### Link dormancy (electric)

Временные условия НЕ удаляют link из `electric_links[]`:

- endpoint не operational (повреждён, недостроен) → link **dormant**;
- у endpoint нет электропорта (канат к раме, к земле) → link **не проводит**
  никогда, но живёт как механический канат;
- legacy port-wire: world-space длина превысила `max_cable_length_m` → link
  **dormant**. У каната лимита нет: он либо держит, либо рвётся физически;
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

### Player UX (connect tool — канат)

1. Mode **connect**. Первый ЛКМ — конец каната крепится к тому, во что ткнули:
   блок (любой, роль и порты не важны) или точка terrain. С этого момента
   канат **живой**: не гост-лучик, а настоящий провод, который тянется за
   курсором и меняет длину в реальном времени (`CableRoutingPreview` рисует
   тем же мешем, что и построенный кабель).
2. Второй ЛКМ — второй конец **броском**: `CONNECT_THROW_RANGE` (18 м) против
   4 м на первый конец, `InteractionQuery` растягивает прицельный луч на время
   протяжки. Это и есть «прикрепить машину на ходу к земле»: цепляешь конец за
   блок машины и бросаешь якорь в грунт, мимо которого едешь. Промежуточные
   крепления не нужны — пролёт идёт напрямую; канат длиннее броска делается
   ногами.
3. **Колесо мыши** — слабина: вверх слабее (болтается), вниз туже (внатяг).
   Шаг мелкий (`SLACK_STEP` 1%), с Shift — грубый (×8). Крутится во время
   протяжки, HUD показывает «натяг N%». Значение хранится как отношение
   `rest_length_m` к пролёту, поэтому переживает сейв. Протяжка в руках — та же
   verlet-верёвка, что и построенная: она лежит на земле, пока ты идёшь.
4. **ПКМ** — отмена **только текущей протяжки**; уже построенные канаты и сам
   инструмент остаются. Смена блока/инструмента тоже отменяет протяжку.
5. Конец на блоке едет вместе с блоком (Assembly двигается, режется на части,
   крутится на роторе/поршне); конец в земле вбит в мир и держится, пока под
   ним есть грунт. Скобы старых кабелей продолжают работать и рендерятся как
   раньше.
5a. **Якорение на ходу разрешено намеренно.** Мировой якорь импульса не
   получает — весь рывок уходит в машину, поэтому тяжёлая машина на скорости
   рвёт канат (порог `break_impulse_ns`), а на малой — виснет и разворачивается.
   Ограничение механики — сам обрыв, а не запрет.
6. **Cargo:** connect tool **не используется** — только placement `cargo_pipe`.
7. Presentation: провод — тонкий чёрный кабель с провисанием по `rest_length_m`
   (провис считается по локальной гравитации, не по мировому −Y); канат без
   электрики — верёвочный материал; grinder по любому сегменту срезает.
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
5. measure removed SDF voxel volume from the actual edit and credit **typed ores**
   from material weights × volume (`TERRAIN-MATERIALS-V1`); production never
   substitutes a default production volume; credit only what fits in the buffer;
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

- `VoxelTerrain` / `VoxelLodTerrain`: uniform scale **1.0** (= 1 м на воксель;
  нативный unit Voxel Tools; свойства `voxel_size` у узла нет). Канон —
  `MoonGeometry.VOXEL_SCALE`. Раньше держали 0.65 как scale-workaround под
  более мелкую копку; отказ из‑за ~3.6× вокселей на м³ при слабом линейном
  выигрыше.
- Flat yard (`flat_moon`): `max_view_distance` / `VoxelViewer.view_distance`
  в локальных вокселях ≈ мировые метры при scale 1.0 (раньше ≈128 м /
  0.65). Иначе плагин клампит viewer и блоки вокруг игрока не грузятся.
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
(дефолт **0.01**) — **fallback**, если у `TerrainMaterialDef` не задан свой
`collectible_fraction`. Канон yield по материалам вокселя —
[`TERRAIN-MATERIALS-V1.md`](TERRAIN-MATERIALS-V1.md) § «Добыча и yield».

- Пустота, цель вне рабочей дальности и недоступный terrain возвращают пустой
  результат: edit, yield и feedback отсутствуют.
- Результат не зависит от числа кадров или повторного попадания в уже пустую
  область. Инструменты не начисляют объём по геометрической формуле и не
  ограничивают post-factum yield после более крупного edit.
- `TerrainMaterialSource` принимает измеренный объём и веса материалов из
  `CHANNEL_INDICES` (не из terrain shader). Запись индексов генератором,
  визуал зон и persistence — часть реализации `TERRAIN-MATERIALS-V1`.
- `InteractionQuery` получает terrain contact из SDF, поэтому удерживаемый бур
  продолжает работать без движения курсора, даже пока physics collider
  перестраивается.

### Floating terrain chunks (post-dig)

После успешной копки (`WorldCommandGateway`: hand drill, stationary drill,
`apply_terrain_carve` / impact / meteorite) вызывается
`VoxelToolLodTerrain.separate_floating_chunks` через
`TerrainFloatingDebrisService` (только `VoxelLodTerrain`; на plain
`VoxelTerrain` — no-op).

- Box ~**30** local voxels (VT docs; balance `industry.floating_chunks`).
- Оторванные острова → ephemeral `RigidBody3D` (convex), kinematic→rigid
  (плагин), despawn / cap тел — balance; **не** world loot piles.
- Материал: `terrain_debris_material.tres` (object-local triplanar) — не
  Transvoxel/VT шейдер коры (ломается на detached mesh).
- Коллизии: layer debris (2) + mask terrain|debris|player (4), чтобы толкать.
- Копка: `KIND_TERRAIN_DEBRIS` → `dig_terrain_debris` (HP от массы, yield как
  hand drill, scale↓ / destroy). Aim mask включает layer 2.
- Separation снова правит SDF → повторный `terrain_modified` для dig persist.
- Троттлинг: `min_removed_m3` + `cooldown_ms` (бур тикает чаще, чем scan).

### Hand drill carving recipe

Ручной бур (радиус **1.0 м**, bite **0.18 м**, `sdf_scale` **0.8**):

1. Каждый принятый тик: `do_sphere` с центром, сдвинутым **вглубь** на
   `radius - bite`, чтобы врезалась только кромка (upstream VoxelTool Note 4).
2. Между тиками при смещении прицела: `do_path` sweep от предыдущего bite-center
   к текущему (непрерывный канал).
3. `grow_sphere` не используется.

Yield **никогда** не идёт в player resource store: что добыто руками — то и
поднимается руками. Масса копится в буфере по `resource_id` и покидает его
квантами `hand_drill_loot_emit_volume_l` (объём, не масса — кванты разных руд
выглядят на земле одинаково; конверсия по `mass_per_unit_kg /
volume_per_unit_l`). Один тик — ~0.1 м³ каждые 0.15 с, поэтому pile за тик
оставлял дорожку обмылков вдоль забоя; буфер это и лечит. Буфер не
персистится: quit теряет меньше одного кванта. Pile создаётся в **точке
контакта на поверхности** (aim hit), не в центре carve. Презентация — `RigidBody3D` (Jolt): pile падает и скатывается
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
  queue[]        # recipe_id FIFO, max depth fixture (queue_max_depth, 200)
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
| `enqueue_recipe` / `EnqueueRecipeCommand` | append `count` copies (default 1; capped by remaining depth) |
| `dequeue_recipe` / `DequeueRecipeCommand` | remove `count` queued slots from `index` (default index 0, count 1) |

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

- Окно — фиксированный прямоугольник по центру экрана (не растёт от содержимого):
  player store слева, target store/internal buffer справа, обе колонки
  тянутся, гриды скроллятся внутри. `toggle_inventory` (`I`) открывает
  solo-вариант только с player store. Пока окно открыто, панель ЦЕЛЬ,
  E-подсказка и прицел скрыты — окно уже показывает то же самое.
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
- Для **recipe machine** (`processor` / `fabricator` / `electrolyzer`) terminal
  раскрывается в **factory window** (SE-style): слева во всю высоту инвентарь
  игрока, справа сверху каталог рецептов карточками (иконка результата + сырьё,
  ЛКМ +1 · Ctrl +10 · Shift +100) и визуальная очередь производства (активная
  job с progress + pending-карточки, сгруппированные в `×N`, ЛКМ по карточке —
  отмена run), справа снизу инвентарь машины; drag&drop между инвентарями. Виджеты шлют `enqueue_recipe` (`count`) /
  `dequeue_recipe` (`index`,`count`) / `set_machine_enabled`; окно поллит snapshot
  ~5 Гц для живого progress. Для non-recipe machine (`stationary_drill`) правая
  панель показывает inline `enabled` + status как прежде.

Первый набор item icons — цветная плашка с коротким кодом. Его API привязан к
`item_id`, чтобы будущая PNG-графика не меняла terminal или transfer contract.

## Acceptance

Industry v1 закрыт, когда:

1. ISRU по `TERRAIN-MATERIALS-V1`: crush/sinter и ветка до typed component, плюс
   вода → `electrolyzer` → O₂/H₂, через stores/cargo без dup/loss on stop/restart.
2. Generator cluster → one wire → distributor; unwired consumers внутри 12 m
   powered spatially; **cargo_pipe** chain drill → store → processor; electric
   **wire mesh** visible только для supply links.
3. Stationary drill requires voxel contact at its oriented visible head, carves only
   reachable terrain, credits **typed ores** from measured removed volume × material
   weights, stops before carve on `storage_full`, auto-pushes **по pipe graph** when
   connected; manual pickup works.
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
