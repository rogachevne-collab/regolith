# Oxygen Survival v0

Статус: доменный контракт (спека). Код ещё не обязан совпадать — при реализации
сначала эта спека, потом fixtures/runtime (инвариант R1).

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` — SuitState, Field, Network/Store;
- `docs/specs/HUD-UI-01.md` — Vitals, TargetInfo, предупреждения;
- `docs/specs/INDUSTRY-V1.md` — cargo graph, electric consumer, mass coupling;
- `docs/specs/TERRAIN-MATERIALS-V1.md` — bulk `oxygen` item (ISRU), 2 L/unit;
- `docs/specs/PLAYER-INTERACTION-V1.md` — hold `interact`, InteractionCard;
- `docs/specs/CONTROL-ACTIONS-V0.md` — `machine.toggle` на control terminal;
- `docs/authoring_parts.md` — Part Wizard для `OxygenModule`.

## Цель

Минимальное выживание на безвоздушной луне: расход O₂ из скафандра, пополнение
из размещённого **OxygenModule**, атмосферный фактор планеты без герметичных
объёмов и газовых труб. Bulk `oxygen` из ISRU остаётся отдельным cargo-предметом;
прямой auto-transfer bulk → модуль / скафандр в v0 **заблокирован**.

## Граница владения

```text
SimulationEnvironmentProfile (world config, immutable)
        |
        v
SimulationWorld.tick_suits()  →  SimulationSuitState (per player_id, snapshot)
        ^
        |  manual hold-E / seated auto-refill
        v
OxygenModule element state  (oxygen-only keyed store, snapshot, mass coupling)
        |
        +-- cargo graph (seated auto-refill: cockpit ↔ module reachability)
        +-- electric budget (idle_w / active_w when dispensing)
```

- **Симуляция** владеет `SimulationSuitState`, состоянием каждого OxygenModule
  и tick расхода/пополнения/гипоксии.
- **World config** задаёт `oxygen_saturation` планеты; не сериализуется в snapshot.
- **HUD** только читает SuitState и InteractionCard; hold-E инициирует команду
  через `WorldCommandGateway` (см. `HUD-UI-01.md`).
- Герметичные `Volume` / `Atmosphere`, давление, утечки, gas Flow — **вне v0**
  (см. «Не входит»).

## SimulationEnvironmentProfile

Статическая конфигурация локации/planetoid. Не часть `SimulationSnapshot`.

```text
SimulationEnvironmentProfile {
  oxygen_saturation    # float 0..1, immutable для данной сцены/world
}
```

| Локация | `oxygen_saturation` |
|---|---:|
| Moon (`main.tscn`, planetoid) | `0.0` |
| Будущие атмосферные миры | `> 0` (fixture per scene) |

- v0: **нет** региональных зон, терраформинга и runtime-изменения насыщенности.
- Значение читается при tick SuitState и гипоксии; не кэшируется в SuitState.

## SuitState — кислород

`SimulationSuitState.oxygen` — **литры**, не нормализованная доля:

```text
oxygen {
  current_l
  capacity_l
}
```

HUD Vitals показывает долю `current_l / capacity_l` (см. `HUD-UI-01.md`).

### Расход

Каждый tick (тот же вызов `tick_suits`, что и прочие каналы SuitState):

```text
drain_l = base_drain_lps × dt × (1 − oxygen_saturation) × activity_mul
```

| Параметр | v0 |
|---|---|
| `base_drain_lps` | tunable fixture (ориентир ~0.02 L/s) |
| `oxygen_saturation` | из `SimulationEnvironmentProfile` |
| `activity_mul` | **1** (ходьба/бег/работа не меняют расход) |

При `oxygen_saturation = 1` drain = 0: игрок **дышит атмосферой**, но tank
**не пополняется** (нет пассивного refill).

### Атмосферный фактор и гипоксия

Тот же `(1 − oxygen_saturation)` масштабирует **урон гипоксии** при пустом tank.

Когда `current_l ≤ 0`:

1. **Grace period** — configurable `hypoxia_grace_s`; урон **не** наносится.
2. После grace — **periodic** hypoxia damage (`hypoxia_damage_hp`, интервал
   `hypoxia_tick_s`), через `apply_suit_damage` / существующий health channel.

Состояние grace/hypoxia timer **сохраняется** в snapshot SuitState.

`hydrogen` channel, смерть и respawn — **вне v0** (health может падать до 0,
но respawn/death flow не специфицируется здесь).

## OxygenModule

Placeable industry-элемент с ролью **oxygen dispenser**. Один модуль = один
конечный резервуар O₂ (не gas network node).

### OxygenModuleDefinition (authored / baked)

```text
OxygenModuleDefinition {
  capacity_l       # max stored liters
  initial_l        # free fill on each new element creation
  dispense_lps     # max transfer rate to suit (manual + seated)
  idle_w           # electric draw when enabled, not dispensing
  active_w         # additional draw while dispensing (idle + active)
}
```

Part Wizard (`part_kind = OxygenModule`) экспортирует эти поля в archetype
fixture; см. `docs/authoring_parts.md`.

### Element state

- **Keyed store**, ключ `oxygen` only; `capacity_l` из definition.
- `current_l` сериализуется в element snapshot; участвует в **mass coupling**
  через fixture bulk `oxygen`: 0.2 kg на 2 L, то есть 0.1 kg/L.
- Содержимое **не** участвует в cargo auto-transfer (push/pull Industry tick).

### Bootstrap / restore

| Событие | Поведение |
|---|---|
| Новое создание элемента (`place`, blueprint spawn/duplicate — новый `element_id`) | `current_l = initial_l` (accepted v0 bootstrap) |
| Snapshot restore / resync / reload / re-projection существующего | только сохранённый `current_l`; **не** `initial_l` |
| Ремонт / завершение weld **существующего** элемента | **не** даёт `initial_l` |

**Пополнение модуля** из bulk `oxygen`, electrolyzer output, cargo push — **v0
deferred / blocked** (см. «Не входит»).

### Electric

- Обычный **electric consumer** (как processor): `idle_w` постоянно при
  `enabled`, `+ active_w` на время dispense.
- Вкл/выкл — `set_machine_enabled` / `machine.toggle` с control terminal или
  привязанного cockpit ActionBar (`CONTROL-ACTIONS-V0.md`).
- **Dedicated `power_in` port не обязателен** — питание через spatial electric
  graph Industry v1 (как у других машин без явного порта в fixture).

### Cargo ports — seated connectivity

Модуль имеет ≥1 `PortDefinition.Kind.CARGO` (как `cargo_io` / `cargo_through`).

- Порты нужны **только** для **seated auto-refill**: cockpit / seat assembly и
  модуль должны быть в одной **cargo connected component** (direct face-adjacent
  или цепочка `cargo_pipe`). Standing manual refill cargo graph **не** использует.
- **Gas / fluid Flow по cargo graph не идёт.** Auto-transfer Industry **не**
  кладёт bulk `oxygen` в модуль и **не** выкачивает из него.

## Пополнение скафандра

### Ручное (hold E)

- Input: `interact`, **hold** (см. `PLAYER-INTERACTION-V1.md` hold progress).
- **Короткий tap E** — **no-op** для O₂ (не триггерит dispense).
- Условия: игрок **aim** на OxygenModule (`InteractionQuery.current_hit`) в
  обычном interaction range; модуль `enabled`, `current_l > 0`, electric budget OK.
  Cargo connectivity **не** требуется.
- Rate: до `dispense_lps`, bounded модулем и свободным `capacity_l − current_l`
  suit tank.
- **Atomic contention:** одновременный dispense на один модуль сериализуется;
  второй consumer ждёт или получает `blocked` на tick.

### Seated auto-refill

Пока игрок в `ControlSeat` (cockpit / vehicle):

- Per-**player** seat context (не глобальный флаг машины).
- **Hysteresis:** старт когда suit `current_l / capacity_l < 0.95`; стоп при
  `≥ 1.0` (100%).
- Выбор модуля: **nearest** в cargo component seat assembly по **fewest hops**,
  tie-break **lower `element_id`**; один модуль за раз, sequential dispense.
- Те же `dispense_lps`, electric и atomic rules, что и manual.

### Manual vs ISRU bulk

Bulk item `oxygen` (2 L/unit, `TERRAIN-MATERIALS-V1.md`) живёт в cargo stores
и **не** конвертируется автоматически в suit liters или module `current_l` в v0.

## Presentation (HUD / feedback)

См. `HUD-UI-01.md`:

- **TargetInfo** на OxygenModule: `current_l / capacity_l`, electric status
  (`enabled`, `no_power`), operational reason.
- **Vitals** O₂ bar — из `SuitState.oxygen` liters.
- **Low O₂ warning:** визуальный overlay (vignette / tint) + **rate-limited**
  audio cue при низкой доле (пороги — fixture в HUD spec); presentation-only,
  не дублирует simulation tick.

## Part Wizard

`part_kind = OxygenModule` в `PartAuthoringRoot`:

- поля definition: `capacity_l`, `initial_l`, `dispense_lps`, `idle_w`, `active_w`;
- bake → archetype с `OxygenModuleDefinition` sub-resource + cargo port(s);
- headless gate расширить при реализации (`test_part_authoring`).

## Snapshot

| Данные | Где |
|---|---|
| `SimulationSuitState` (вкл. O₂ liters, hypoxia timer) | `SimulationWorld`, per `player_id` |
| Module `current_l`, `enabled` | element state |
| `oxygen_saturation` | **не** в snapshot — world/scene profile |

## Не входит

- Sealed `Volume` / `Atmosphere`, давление, пробоины, leaks;
- Gas / fluid pipes и Flow для O₂;
- **Module replenishment** из bulk `oxygen`, electrolyzer, cargo auto-transfer;
- H₂ integration (SuitState hydrogen drain/refill);
- Death / respawn flow;
- Regional / terraformable `oxygen_saturation`;
- Activity-based drain multipliers (sprint, drill, …);
- Passive suit refill при `oxygen_saturation = 1`;
- Required dedicated electric port on module.

## Acceptance (реализация)

1. Спека в репо; перекрёстные ссылки в `PHYSICAL-LANGUAGE`, `HUD-UI-01`,
   `TERRAIN-MATERIALS-V1`, `authoring_parts`.
2. Moon `oxygen_saturation = 0`; drain и hypoxia работают headless в `tick_suits`.
3. OxygenModule: новый `element_id` → `initial_l`; restore/resync/re-projection → без refill; mass coupling.
4. Cargo graph — только seated auto-refill; inbound bulk refill blocked.
5. Aim + hold E dispense (no cargo graph); tap E no-op; seated hysteresis 95%/100%.
6. Electric idle/active; toggle via terminal.
7. HUD target + low-O₂ feedback — verified in game (R2: не headless test scene).
