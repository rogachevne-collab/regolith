# Control Actions v0 — слоты быстрых действий на сиденьях и пультах

Статус: design contract (спека до кода). Реализуется после стабилизации Industry /
Actuators command surface, параллельно и **до** визуального Control Graph.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` («ControlSeat и Binding», «Actuator», «Sensor»,
  «Blueprint», «Граница владения», «Диагностируемость»);
- `docs/specs/CONTROL-GRAPH-V0.md` (автоматическая половина того же слоя);
- `docs/specs/POC-ACTUATORS-V1.md`, `POC-ACTUATORS-V2-ROTOR.md`,
  `POC-ACTUATORS-V3-HINGE.md`;
- `docs/specs/INDUSTRY-V1.md` (machine enable, stores);
- `docs/specs/HUD-UI-01.md` (тулбар, терминал).

## Цель

Дать игроку **ручной** язык управления конструкцией в стиле Space Engineers:
поставил кокпит или пульт → на его тулбаре слоты быстрых действий («выдвинуть
поршень», «реверс ротора», «включить бур»), которые срабатывают по хоткею, когда
игрок сидит/у пульта.

Это **ручная половина примитива `Binding`** из Physical Language. Автоматическая
половина — `Control Graph` (сенсоры → логика → те же команды, без игрока). Обе
половины бьют в **один** командный сток Actuator / `machine_enabled`
(last-write-wins). Новой параллельной модели управления не вводится.

```text
   ручной ввод (сиденье/пульт, хоткей 1-9)      автоматика (Control Graph)
                    |                                      |
                    v                                      v
        ┌───────────────────────────────────────────────────────────┐
        │   Action catalog (глаголы) + Target/Group + command sink   │  ← ОБЩЕЕ ЯДРО
        └───────────────────────────────────────────────────────────┘
                    |
                    v
        set_actuator_target / configure_actuator / set_machine_enabled
                    |
                    v
             Actuator / machine_enabled  (Jolt-моторы, actuator solver)
```

## Нормативные решения

1. **Ручная половина Binding.** Слот резолвится в **уже существующую**
   управляющую команду (`set_actuator_target`, `configure_actuator`,
   `set_machine_enabled`) через `WorldCommandGateway`. Нового пути авторитета
   не появляется; клампы лимитами Actuator / power / operational — как есть.
2. **Хост слотов — роль `ControlSeat`.** В MVP это `cockpit` (сидя, через
   существующий `toggle_control_seat`) и стационарный `control_terminal`
   (стоя, через interaction). Оба несут `ActionBar`.
3. **ActionBar принадлежит хосту, а не игроку.** Слоты хранятся в `Blueprint`
   сборки и в runtime snapshot (instance overrides) — как `bindings` в Blueprint
   и как правило Control Graph §4. Разные сиденья на одной сборке имеют разные
   бары.
4. **Единый виджет тулбара, разные источники данных.** Строительный тулбар
   остаётся **player-owned** (`ToolController`, глобальный). Управляющие вкладки
   — **seat-owned**, приходят от занятого хоста. Пока игрок в
   сиденье/у пульта, тулбар показывает **только** управляющие вкладки; строй-бар
   скрыт. Вышел — вернулся строй-бар.
5. **Адресация целей — доменными id** (`ElementId` / `joint_id` / `group_id`),
   не `NodePath`/`instance_id` (как Control Graph §6).
6. **Скоуп цели:** элементы Assembly своего хоста; чужая сборка — только через
   явный `data`-link (см. «Кросс-сборка»). Данные link-кабеля — общий
   пререквизит с Control Graph P1.
7. **Вид ввода задаётся на слот** (`momentary` / `toggle` / `trigger`), дефолт
   выводится из глагола. Игрок может сменить вид в терминале.
8. **Диагностика на слоте:** недоступная цель (нет питания / сломана / удалена) —
   слот серый; рантайм-отказ команды — слот мигает `reason`
   (`no_power`, `overloaded`, `actuator_broken`, `element_broken`, …).
9. **Тик — не нужен.** Слот — событие ввода, не периодический evaluate (в отличие
   от графа). Живое состояние слота читается из SensorChannel по refresh HUD.

## Границы

### Входит в MVP (v0)

- роль `ControlSeat` как host `ActionBar` на `cockpit` и новом `control_terminal`;
- `ActionCatalog` — data-driven глаголы per-role (таблица ниже);
- `ActionBar`: **9 слотов × 9 страниц** на хост, фиксированный бюджет;
- бинд глагола на слот **через терминал drag-drop** (список элементов сборки →
  тащишь глагол в слот);
- исполнение: хоткей слота → resolve → существующая gateway-команда;
- живое состояние слота через SensorChannel (позиция поршня, мотор ON, machine
  enabled);
- persistence бара в Blueprint + snapshot;
- диагностика слота (серый / мигание reason);
- headless-тест: resolve слота → корректная команда; отказ по питанию.

### Не входит в MVP (позже)

- **Группы** элементов (один слот → все поршни) — P1;
- быстрый бинд по прицелу (навёл → «повесить на слот N») — P1;
- **оси вождения** (WASD/мышь → колёса/трастеры/ротор как непрерывная ось,
  `SeatAxis`/`Binding.source`) — отдельная спека `CONTROL-AXES-V0`;
- именование вкладок и переименование элементов — P1;
- произвольный код, structural/terrain команды из слота (как и в графе);
- cross-assembly без data-link; remote control по радио.

## Модель

### ControllableTarget

```text
ControllableTarget {
  ref_kind        # element | joint | group
  element_id      # для element/joint-целей
  joint_id        # для актуаторов (piston/rotor/hinge)
  group_id        # для group-целей (P1)
  assembly_id     # хост-сборка; чужая — только через data-link (см. ниже)
}
```

Резолв цели в момент срабатывания читает authoritative simulation state (как граф
читает world state, а не HUD-метаданные).

### Action (глагол)

Глагол объявляется **ролью архетипа**, data-driven, а не хардкодом на класс
техники:

```text
Action {
  action_id       # stable string, e.g. piston.extend, machine.toggle
  role            # Actuator(piston|rotor|hinge) | Processor | Support | ...
  input_kind      # momentary | toggle | trigger  (дефолт вида ввода)
  args_schema     # e.g. {target_position_m: float} для set-position
  emits           # какую gateway-команду строит (см. каталог)
}
```

Виды ввода:

- **momentary** (держать): нажал → команда A, отпустил → команда B.
  Пример: держу «extend» → `set_actuator_target(mode=position, target=upper)`,
  отпустил → `set_actuator_target(mode=STOP)`.
- **toggle**: флип булева. Пример: «мотор» → `configure_actuator(motor_enabled=!)`.
- **trigger**: разовый set. Пример: «на позицию 0.8» →
  `set_actuator_target(mode=position, target_position_m=0.8)`.

### ActionSlot

```text
ActionSlot {
  page            # 0..8
  index           # 0..8
  target          # ControllableTarget
  action_id       # из ActionCatalog
  input_kind      # override дефолта (опц.)
  args            # e.g. {target_position_m: 0.8}
  label           # авто из archetype + глагол, редактируемо (P1)
  icon            # из archetype
}
```

### ControlSeat host

```text
ControlSeatHost {
  element_id      # cockpit | control_terminal
  bar: ActionBar { pages: 9, slots_per_page: 9, slots: ActionSlot[] }
  occupied_by     # player_id | none (кокпит) / interaction range (пульт)
  power_gate      # без питания host бар не шлёт команды (safe freeze)
}
```

## ActionCatalog MVP (глаголы → команды)

Глаголы — тонкие обёртки над существующим API гейтвея. Ничего нового в стоке.

### Актуаторы (piston / rotor / hinge)

| action_id | input_kind | emits (WorldCommandGateway) |
|---|---|---|
| `piston.extend` | momentary | `set_actuator_target{mode=position, target_position_m=upper}` ⇄ `mode=STOP` |
| `piston.retract` | momentary | `set_actuator_target{mode=position, target_position_m=lower}` ⇄ `mode=STOP` |
| `actuator.stop` | trigger | `set_actuator_target{mode=STOP}` |
| `actuator.reverse` | trigger | `set_actuator_target` с инвертированной текущей целью/скоростью |
| `actuator.motor_toggle` | toggle | `configure_actuator{motor_enabled=!current}` |
| `actuator.set_target` | trigger | `set_actuator_target{mode=position\|velocity, target_*=args}` |
| `rotor.spin_cw` / `rotor.spin_ccw` | momentary/toggle | `set_actuator_target{mode=velocity, target_velocity_mps=±v}` ⇄ `STOP` |

`joint_id` берётся из `ControllableTarget.joint_id`. `reverse` читает текущий
`mode`/target из SensorChannel и шлёт зеркальный. Для ротора «скорость», для
поршня/шарнира — «позиция/скорость» по args.

### Машины (Processor / Fabricator / drill)

| action_id | input_kind | emits |
|---|---|---|
| `machine.enable` | trigger | `set_machine_enabled{element_id, enabled=true}` |
| `machine.disable` | trigger | `set_machine_enabled{element_id, enabled=false}` |
| `machine.toggle` | toggle | `set_machine_enabled{element_id, enabled=!current}` |

### Прочие приводы (wheel / thruster / gyro)

Дискретные глаголы только если у элемента **уже есть** command sink
(`configure_wheel`, `configure_suspension` есть в гейтвее). Непрерывное вождение
(ось) — вне этого слоя (`CONTROL-AXES-V0`). MVP-глаголы, если нужны:
`support.brake_toggle`, `thruster.enable/disable/toggle` — по факту наличия
sink; иначе откладываются.

## Кросс-сборка (data-link)

Слот может целить в элемент **чужой** Assembly только когда между host-сборкой и
целевой сборкой есть явный `data`-link (Network kind `data`). Без link резолв
даёт `port_disconnected`, слот серый. Сам link-кабель (`data` cable element) —
общий пререквизит с Control Graph P1; до его появления кросс-сборка недоступна, а
адресация (`assembly_id` в `ControllableTarget`) уже заложена под него.

## Хосты и посадка

- **cockpit** (`ControlSeat`, уже есть): вход/выход — существующий
  `toggle_control_seat` (`world_command_gateway.gd`). Сел → внизу компактный
  ActionBar HUD; хоткеи 1–9 бьют по слотам; листание страниц — существующие
  `toolbar_page_prev/next`; выход — освобождает бар.
- **control_terminal** (новый архетип, роль `ControlSeat` + `Frame`): стоя в
  interaction-range, `E` открывает полное окно (не «садит»). Иначе идентичен.

Пока хост занят, gameplay-инпут строительства подавляется (как сейчас
`set_gameplay_input_enabled(false)` в actuator-панели); ввод идёт в ActionBar.

## Терминал управления (UI v0)

Две поверхности одного бара, чтобы игра и настройка не мешали друг другу:

1. **Компактный ActionBar HUD** — всегда внизу, пока игрок в хосте. Только
   активная страница (9 слотов) + номер страницы. Для игры «в потоке».
2. **Полное окно «Пульт управления»** — открывается **и из кокпита, и из
   терминала**. Три колонки; здесь настраивают всё, не только хоткеи.

Мокап окна:
`https://claude.ai/code/artifact/c2edde27-e99c-4212-a3d9-a886c78e68f1`.

### Визуальный язык — инженерный SCADA/HMI

Не игровой HUD, а промышленный пульт (принципы high-performance HMI / ISA-101):

- **светло-серая приборная панель**, тёмный текст, тонкие линии; данные в
  **таблицах**, высокая плотность;
- **цвет — только на авариях** (янтарь = предупреждение, красный = отказ);
  никакого акцентного цвета ради красоты, никаких пилюль/скруглений/свечения;
- **нейтральный гротеск** (не caps-condensed), обычный регистр, `tabular-nums`;
- иконки — минимально (Lucide, мелкие, серые), в списке узлов иконок нет.

Палитра этого окна **отдельная** от `HudTokens` (тот — тёмный игровой HUD);
светлый приборный экран — сознательный контраст «встроенного монитора».

### Зоны полного окна

| Зона | Содержимое |
|---|---|
| **Верхняя строка** | тег сборки (`МАНИПУЛЯТОР‑01 · MNP‑01`), питание, счётчик узлов, счётчик аварий |
| **Список узлов** (лев.) | сегмент-фильтр по роли + `Аварии`; поиск; **таблица** `маркер состояния · узел (+ тег) · значение+ед.`; аварийные строки — цветом |
| **Фейсплейт** (центр) | настройка выбранного узла (см. ниже) |
| **Лента аварий** (прав.) | активные аварии `время · тег · описание · приоритет`; ниже — Группы (P1) |
| **Пульт (soft-keys)** (низ) | вкладки страниц 1–9 + ряд **функц-клавиш 1–9**; клавиша = иконка + команда + узел/состояние; drop-цель для команд из фейсплейта |
| **Статус-бар** (низ) | оператор · режим · связь · подсказки хоткеев |

### Фейсплейт — настройка узла (per-role)

Иерархия: **показания** (read-only) подчинены **уставкам** (editable).

- **Шапка**: имя (редактируемо, per-instance в snapshot) + технический тег
  (`MNP‑01‑CY1`, dim) + переключатель режима **Авто/Ручн** + слово статуса.
  Латинских 3-буквенных кодов роли в UI нет.
- **Показания** (read-only, из SensorChannel): скорость/цель/питание/мотор +
  **мини-тренд** (sparkline) главной величины (ход/угол). Термин «Показания»,
  без слова «вживую».
- **Уставки** (editable setpoints, `configure_*`). Контрол на строку: **слайдер
  (грубо) + числовое поле (точно/крупные значения) + −/+ нудж**. Только `+/−`
  недостаточно.
  - актуатор: скорость, усилие, верх./ниж. предел, мотор;
  - машина (`Processor`/`Fabricator`): enable + **очередь рецептов**
    (`HudProductionQueue` / `enqueue_recipe`);
  - датчик: **пороги/уставки** (нужны и графу — общий publish path).
- **Команды** — глаголы роли как командные кнопки (иконка Lucide + тег вида ввода
  `удерж / тумблер / раз`); перетаскиваются на функц-клавишу пульта.

Навигация — **таблица + сегмент-фильтр + поиск** (без 3D-пикера); подсветка узла
в мире — P1.

Полное окно — модальное (как текущий терминал/actuator-панель): курсор видим,
gameplay-инпут подавлен; закрытие возвращает управление.

## Persistence и кооп

- Слоты бара пекутся в `Blueprint` (там уже перечислены `bindings`) и
  сохраняются как instance-override в snapshot (`capture_snapshot`), тем же
  механизмом, что остальное состояние сборки. Baked Blueprint — deterministic
  Resource.
- Кооп: управляющие команды — «частые, last-write-wins» (Physical Language →
  «Граница владения»). Право бить по слотам бара имеет только **текущий
  occupant** хоста; редактирование бара (drag-drop) — тоже occupant. Отдельного
  пути репликации не нужно: команды идут host-authoritative, snapshot несёт бар.

## Диагностика

Слот отвечает «почему не сработало» без логов (контракт Physical Language →
«Диагностируемость»):

- цель отсутствует / `element_broken` / `element_incomplete` → слот **серый**;
- host `no_power` / `disabled` → весь бар в safe-freeze, команды не шлются;
- рантайм-отказ команды (`no_power`, `overloaded`, `actuator_broken`,
  `storage_full`, `joint_limit`, `port_disconnected`) → слот **мигает** этим
  `reason` (значение приходит в `command_completed.result.reason`).

## Производительность (бюджеты v0)

| Budget | Значение |
|---|---|
| страниц на хост | 9 |
| слотов на страницу | 9 (= текущий `TOOLBAR_SLOTS_PER_PAGE`) |
| слотов на хост | 81 |
| SensorChannel reads на refresh HUD | только видимая страница (≤ 9) |
| частота refresh состояния слота | HUD refresh, не physics frame |

Слот — событие, не тик; периодической нагрузки на симуляцию бар не создаёт (в
отличие от Control Graph `tick_hz`).

## MVP-срез и acceptance

Играбельный вертикальный срез (проверяется в игре, не только headless):

1. `ActionCatalog` для piston/rotor/hinge + machine enable.
2. `control_terminal` архетип (роль `ControlSeat`); cockpit получает бар.
3. Компактный ActionBar HUD (9 слотов активной страницы) — виден в хосте.
4. Полное окно «Пульт управления» (3 колонки) — открывается **и из кокпита, и из
   терминала**: навигатор (список+категории+поиск+живое состояние), полный
   инспектор (имя + параметры роли + очередь рецептов машины), пульт 9×9.
5. Бинд: drag глагола из инспектора в слот; сохранение в snapshot.
6. Сел в кокпит / встал у пульта → бар виден, 1–9 стреляют.
7. Живое состояние (навигатор, инспектор, слоты) через SensorChannel.

**Acceptance (игрок):**

- сел в кокпит → жму 3 (hold `piston.extend`) → поршень едет, отпустил → стоп;
- слот `rotor.reverse` → тап флипает вращение;
- слот `machine.toggle` на бур → бур вкл/выкл, слот отражает `machine_enabled`;
- обесточил сборку → бар серый/мигает `no_power`.

## Headless verification (R2)

Тестируется чистое исполнение, не UI (как Control Graph §R2):

- resolve `ActionSlot` valid/invalid → корректная gateway-команда;
- `piston.extend` momentary press/release → position-target затем STOP;
- `machine.toggle` → `set_machine_enabled` с инверсией;
- host `no_power` → команда не уходит (safe-freeze);
- snapshot save/restore бара сохраняет слоты и их args.

Не создавать `test_*.tscn` для самого бара/терминала (геймплей/HUD — в игре).

## Связь с Control Graph

Этот документ и `CONTROL-GRAPH-V0` — две половины одного слоя `Binding`:

| | Control Actions (этот док) | Control Graph |
|---|---|---|
| Триггер | ручной ввод (хоткей слота) | периодический tick + сенсоры |
| Хост | `ControlSeat` (cockpit/terminal) | `control_unit` |
| Общее | Action catalog, ControllableTarget/group, command sink, SensorChannel | ← то же ядро |

Строя Control Actions первым, мы выкладываем общий фундамент (каталог глаголов,
адресацию целей, SensorChannel publish), который Control Graph переиспользует —
без выброшенной работы.

## Лестница внедрения

1. Спека (этот документ) + якорь в Physical Language «ControlSeat и Binding».
2. `ActionCatalog` — вынести глаголы из `hud_actuator_panel` в data-driven per-role.
3. `ControllableTarget` resolve + слот→команда bridge (headless).
4. `control_terminal` архетип + host `ActionBar` + persistence.
5. Компактный ActionBar HUD: seat-owned вкладки, скрытие строй-бара при посадке.
6. Полное окно «Пульт управления»: навигатор + полный инспектор + пульт;
   drag-drop бинда + SensorChannel live-состояние.
7. P1: группы, подсветка узла в мире, быстрый бинд по прицелу, имена вкладок,
   data-link кросс-сборка.
8. Позже: `CONTROL-AXES-V0` (оси вождения), затем Control Graph поверх ядра.
