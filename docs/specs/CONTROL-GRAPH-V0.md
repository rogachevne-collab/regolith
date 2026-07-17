# Control Graph v0 — визуальное программирование assembly

Статус: design contract (спека до кода). Реализация — после Industrial Base Slice
и стабилизации Industry / Actuators command surface.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` («Sensor», «ControlSeat и Binding», «Actuator»,
  «Network, Flow и Store», «Blueprint», «Граница владения»);
- `docs/specs/INDUSTRY-V1.md`;
- `docs/specs/POC-ACTUATORS-V1.md`, `POC-ACTUATORS-V2-ROTOR.md`;
- `docs/specs/ROVER-MODULES-V1.md`;
- `docs/specs/SIMULATION-KERNEL-V0.md`.

## Цель

Дать игроку **визуальный** язык поведения конструкций (как UE Blueprints / PLC),
без скриптов уровня Space Engineers Programmable Block.

Один и тот же слой обслуживает:

- таймер → открыть дверь / выдвинуть поршень;
- порог склада → выключить бур / включить процессор;
- feedback → держать позицию / угол;
- позже: guidance loop на тех же примитивах (когда появятся thrust / seeker).

Новая параллельная модель «кода машины» не вводится. Граф компилируется в
`Binding` и управляющие команды симуляции (`set_actuator_target`,
`set_machine_enabled`, `set_binding_state`).

## Нормативные решения

1. **Control Graph** — declarative dataflow + ограниченный state machine на
   `Assembly`. Не Turing-complete скрипт, не произвольный GDScript/Lua.
2. **Sensor публикует, граф решает, Actuator исполняет.** Sensor не принимает
   решений; граф не пишет позу/скорость и не вызывает structural commands.
3. Игрок в `ControlSeat`, автопилот и Control Graph бьют в **один** командный
   интерфейс Actuator / machine enable (см. Physical Language → Binding).
4. Граф хранится в `Blueprint` (authoring) и в runtime snapshot assembly
   (instance overrides). Baked Blueprint остаётся deterministic Resource.
5. Тик графа — simulation-owned, фиксированный budget (см. «Производительность»).
   Чтение идёт из authoritative state / sensor channels; запись — только
   управляющими командами с last-write-wins.
6. Адресация целей — через `ElementId` / port id / joint id внутри assembly
   (и явно разрешённые data-link к другим assembly). Не `NodePath`, не Godot
   `instance_id`.
7. UX редактора — in-game / terminal graph UI на элементе `control_unit`.
   Headless kernel тестирует **исполнение** скомпилированного графа, не UI.

## Границы

### Входит в MVP (v0)

- элемент `control_unit` (роль Control / Logic host);
- typed **SensorChannel** на существующих industry/actuator элементах;
- минимальный набор нод (ниже);
- compile → `Binding[]` + periodic evaluate;
- команды-стоки: `set_machine_enabled`, `set_actuator_target` (velocity /
  position / stop), `set_binding_state`;
- data Network port `signal` (или reuse `data` Flow) для связи unit ↔ каналы;
- диагностика: `status` / `reason` на unit и на рёбрах («почему не сработало»);
- сохранение графа в Blueprint / snapshot.

### Не входит в MVP

- произвольный код, FFI, файловый I/O, HTTP;
- structural commands из графа (`place`, `weld`, `dismantle`, …);
- terrain carve / voxel edit из графа;
- `transfer_resource` как свободный сток (только через machine enable / будущие
  sorter-модули с узким API);
- cross-assembly remote control без data-link;
- autopilot pathfinding, GPS waypoints UI;
- оружие, thruster, seeker, guidance (tier C ниже);
- VisualShader / отдельный Godot VisualScript runtime.

## Модель

```text
SensorChannel (на Element)
        |
        v
  Control Graph (на control_unit)
        |
        v
   Binding / command
        |
        v
 Actuator / machine_enabled
```

### SensorChannel

Каждый публикуемый канал:

```text
SensorChannel {
  element_id
  channel_id          # e.g. battery_fraction, store_fill, piston_position_m
  value_type          # bool | float | int | enum_token
  unit                # optional, for HUD
  stamp_tick          # simulation tick of last sample
}
```

Sensor (роль или канал на элементе) **только публикует**. Нет side effects.

### Control Graph

```text
ControlGraph {
  graph_id
  host_element_id     # control_unit
  nodes[]
  edges[]
  tick_hz             # default 10
  enabled
}
```

Evaluate на фиксированном `tick_hz` (не every physics frame по умолчанию).
Выходы за тик — набор желаемых команд; симуляция клампит лимитами Actuator /
power / operational.

### Binding (compiled)

Простые рёбра графа (ось/bool → actuator) выпекаются в `Binding` Physical
Language. Сложные ноды (Sequence, Latch) остаются в graph evaluator, но всё
равно вызывают тот же command API.

## Ноды MVP

| Класс | Ноды | Назначение |
|---|---|---|
| Source | `SensorRead`, `Const`, `Timer`, `Pulse`, `SeatAxis` | входы |
| Logic | `Compare`, `And`, `Or`, `Not`, `Latch`, `Select` | условия |
| Time | `Delay`, `Sequence` (линейные шаги, без произвольных циклов) | ритм |
| Math | `Add`, `Sub`, `Mul`, `Clamp`, `Remap`, `Deadzone` | масштабы |
| Sink | `SetMachineEnabled`, `SetActuatorTarget`, `SetBinding` | выходы |
| Debug | `Probe` (пишет status для HUD) | диагностика |

Ограничения MVP:

- нет циклов обратной связи через «память графа» кроме явного `Latch` /
  `Sequence` state;
- нет динамического создания нод в runtime из других нод;
- максимум нод / рёбер на unit — жёсткий budget (см. ниже);
- `Sequence` — конечный список шагов с условиями перехода, не while-true.

## Требования к элементам (жизненно для MVP)

Без этих контрактов визуальный редактор бесполезен: ноды не к чему подключать.

### A. Общий контракт публикации (все relevant elements)

Каждый элемент, участвующий в автоматизации, обязан:

1. Публиковать **stable** `channel_id` (строковые id в спеке/archetype metadata,
   не UI-лейблы).
2. Обновлять каналы в authoritative simulation state (не только в
   `InteractionQuery` HUD metadata).
3. Сохранять каналы в snapshot, если они влияют на поведение после load
   (иначе graph restart должен перечитать live state).
4. При `element_broken` / incomplete — каналы либо `NaN`/invalid с reason, либо
   последний sample + `signal_invalid`.
5. Не требовать aim/терминала для чтения: Control Graph читает world state.

### B. Минимальные каналы на существующих archetype (P0 — до/вместе с UI)

| Archetype | Обязательные каналы MVP | Стоки команд (уже есть → оставить) |
|---|---|---|
| `power_battery`, `power_battery_small` | `battery_fraction` (0..1), `battery_kwh` | — |
| `power_distributor`, `power_distributor_small` | `powered` (bool), `supply_w`, `demand_w` | — |
| `cargo_store` | `store_fill_fraction`, `store_amount` (по `resource_id` или total mass) | — (transfer не сток MVP) |
| `stationary_drill` | `machine_enabled`, `operational`, `powered`, `status_reason`, `storage_full`, `no_terrain_contact` | `set_machine_enabled` |
| `processor`, `fabricator` | `machine_enabled`, `operational`, `powered`, `status_reason`, `recipe_progress_01`, `queue_length`, `storage_full` / blocked flags | `set_machine_enabled` |
| `piston_base` | `position_m`, `target_m`/`velocity_mps`, `at_lower`, `at_upper`, `powered`, `motor_enabled`, `actuator_status` | `set_actuator_target` |
| `rotor_base`, `rotor_base_large` | `angle_rad`, `velocity_rad_s`, `powered`, `motor_enabled`, `actuator_status` | `set_actuator_target` |
| `drive_wheel` | `grounded`, `slip_speed_mps`, `powered` | (lokomotion через seat/bindings — post-MVP) |
| `cockpit` | `occupied` (bool) | seat axes как Source `SeatAxis` post-MVP или soft-MVP |
| любой элемент | `integrity_01`, `build_progress_01`, `machine_enabled` (если applicable) | — |

**Gap сегодня:** часть величин живёт в runtime/HUD, но не как typed SensorChannel
для автоматики (`battery_kwh`, fill склада, supply/demand). MVP требует
выровнять publish path.

### C. Новый элемент MVP: `control_unit`

```text
control_unit {
  roles: LogicHost (Control)
  ports: power_in (electric), signal_io (data) × N
  holds: ControlGraph
  draw: standby_w + per_node budget
  status: no_power | disabled | graph_invalid | budget_exceeded | ok
}
```

Правила:

- без power → граф не evaluate (или freeze outputs в safe defaults);
- один primary graph на unit (v0);
- редактирование графа — interaction/terminal; validate перед enable;
- invalid graph → `graph_invalid`, выходы не шлют команды.

### D. Чего недостаточно «как есть»

| Проблема | Требование MVP |
|---|---|
| Нет роли Sensor / Binding в коде | ввести SensorChannel registry + Binding runtime |
| Cockpit hardcoded locomotion | MVP может **не** автоматизировать ровер; только machines + actuators |
| `transfer_resource` UI-only | не сток MVP; логистика через enable drill/processor |
| Нет data-link между assembly | MVP: каналы только **внутри assembly** host unit (проще accept) |
| Actuator UX в основном velocity | Sink обязан уметь `mode=position` для поршня (API уже в actuator spec) |

## Приоритет модулей на добавление

Порядок — что разблокирует gameplay-ценность визуального программирования.
Не путать с «красивым редактором»: сначала каналы и `control_unit`.

### P0 — разблокировка MVP (обязательно)

1. **SensorChannel publish** на battery / cargo_store / drill / processor /
   fabricator / piston / rotor (таблица B) — можно без новых placeable моделей.
2. **`control_unit`** — host графа + power gate + save/load.
3. **Graph evaluator + compile to commands** (headless-тестируемо).
4. **Minimal in-game graph editor** (добавить ноду, соединить, Probe, enable).

Acceptance MVP (игрок):

- таймер → выдвинуть `piston` / крутить `rotor` N секунд → stop;
- `cargo_store` fill ≥ threshold → `set_machine_enabled(drill, false)`;
- `battery_fraction` < threshold → выключить processor/fabricator;
- поршень: `SensorRead(position)` → `Compare` → stop at limit (без seat).

### P1 — читаемая база-автоматика (сразу после MVP)

| Модуль | Зачем |
|---|---|
| `signal_lamp` / `indicator` | визуальный сток (bool → свет), отладка без HUD |
| `button` / `switch` | ручной Source на стене базы |
| `door` или recipe «поршень + панель» как пресет Blueprint | таймер-дверь без кастомной возни |
| `cargo_sensor` (dedicated) | порог на трубе/хранилище с clear UX, если channel-on-store неудобен |
| data-link cable (`connect_network` data) | сигналы между соседними assembly |

### P2 — логистика и машины (расширенная автоматизация)

| Модуль | Зачем |
|---|---|
| sorter / valve на cargo | граф выбирает маршрут, не только enable |
| conveyor / feeder enable | ритм линии |
| `ServoHinge` | двери, крышки, aim-платформы (угол) |
| recipe enqueue sink (узкий) | `EnqueueRecipe` только для whitelist machine |
| drill-on-piston feed presets | непрерывная добыча = механика + простой graph |

### P3 — мобильные / «умные» системы (не MVP)

| Модуль | Зачем |
|---|---|
| Binding-based cockpit (замена hardcoded locomotion) | один стек с графом |
| `Gyro` + angular-rate Sensor | SAS как graph, не особая система |
| path / waypoint follower (ограниченный) | автопилот ровера |
| thruster / RCS | полёт/ховер — отдельная спека |
| seeker / IMU / lock-on Sensor | guidance; баллистика остаётся у Jolt |
| weapon fire authority | вне Control Graph v0; отдельный combat contract |

**Важно:** «самонаводящаяся ракета» = P3 железо + тот же Control Graph, а не
отдельный язык скриптов. Без thruster/seeker ноды guidance не появляются.

## Производительность (бюджеты v0)

Черновые лимиты (уточнить замером после прототипа):

| Budget | Значение |
|---|---|
| `control_unit` на загруженном yard | ≤ 32 |
| нод на unit | ≤ 64 |
| рёбер на unit | ≤ 96 |
| default `tick_hz` | 10 (max 20) |
| SensorChannel samples / tick / unit | ≤ 32 reads |

Превышение → `budget_exceeded`, граф disabled до упрощения.

## Диагностика

Unit и Probe обязаны отвечать «почему не работает» без логов:

- `no_power`, `disabled`, `graph_invalid`, `budget_exceeded`;
- `signal_invalid` (битый/incomplete source element);
- `target_rejected` (actuator `no_power` / `overloaded` / broken);
- `sink_noop` (команда = текущему состоянию).

## Headless verification (R2)

Тестируется только чистое исполнение:

- compile valid/invalid graph;
- timer → actuator command sequence;
- threshold on fake SensorChannel → `set_machine_enabled`;
- power loss freezes outputs safely;
- snapshot restore graph + latches.

Не создавать `test_*.tscn` для самого graph editor UI (геймплей/HUD — в игре).

## Лестница внедрения

1. Спека (этот документ) + якорь в Physical Language.
2. SensorChannel registry + publish path для P0 элементов.
3. Runtime Binding / command bridge (без UI).
4. `control_unit` archetype + evaluator.
5. In-game editor MVP.
6. P1 modules (lamp, switch, data-link).
7. P2/P3 по отдельным спекам элементов (R1).

## Связь с закрытыми «не входит»

Строки `programmable bindings, sequencing и automation UI` в
`ROVER-MODULES-V1` / `POC-ACTUATORS-*` остаются верными для **тех** v1: этот
документ — следующий контракт, который их снимает осознанно, не молчаливым
feature-creep внутри actuator PoC.
