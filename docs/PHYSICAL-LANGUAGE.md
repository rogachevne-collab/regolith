# Physical Language v0

Статус: контракт standalone Godot-проекта **Regolith**. Это не схема Erebus и не
ADR. Интеграция в Erebus — через Erebus Lite addon, когда контент станет data-driven.

## Индекс (для агентов: не читай файл целиком — найди термин и читай его раздел)

| Термин / вопрос | Раздел |
|---|---|
| кто чем владеет: симуляция vs Jolt, поток данных | «Граница владения» |
| единицы измерения | «Единицы» |
| Assembly, Element | «Примитивы» → «Assembly», «Element» |
| Port (типы портов, совместимость) | «Примитивы» → «Port» |
| Joint (соединения, прочность связи) | «Примитивы» → «Joint» |
| Piston, Motor, overload | «Примитивы» → «Joint»; `specs/POC-ACTUATORS-V1.md` |
| Rotor (непрерывное вращение) | «Примитивы» → «Joint»; `specs/POC-ACTUATORS-V2-ROTOR.md` |
| Hinge / ServoHinge (сгибание с упорами) | «Примитивы» → «Joint»; `specs/POC-ACTUATORS-V3-HINGE.md` |
| Machine compose (буровой манипулятор по фразе) | `specs/MACHINE-COMPOSE-V0.md`; cheatsheet `machine-compose` |
| Body, Field, Surface | «Примитивы» → одноимённые разделы |
| Actuator, Wheel | «Примитивы» → «Actuator», «Wheel»; `specs/ROVER-MODULES-V1.md` |
| Cable / Tether, Sensor | «Примитивы» → одноимённые разделы |
| ControlSeat, Binding (управление) | «Примитивы» → «ControlSeat и Binding» |
| Network, Flow, Store (сети и потоки) | «Примитивы» → «Network, Flow и Store» |
| Resource, Recipe, производство | «Примитивы» → «Resource, Recipe и производство» |
| Volume, Atmosphere (герметичность) | «Примитивы» → «Volume и Atmosphere» |
| Blueprint (чертежи, baked) | «Примитивы» → «Blueprint» |
| id элементов, топология, structural commands | «Identity и topology (Kernel v0)» |
| строительство, прочность, ремонт | «Строительство, прочность и ремонт» |
| кинетический удар, разрушение, упор актуатора | «Кинетический удар (Impact Destruction v0)» |
| логи, инспекция, отладка симуляции | «Диагностируемость» |
| скафандр (кислород, энергия) | «Состояние скафандра (SuitState)» |
| бюджеты производительности | «Производительность» |
| мультиплеер (задел) | «Сетевой контракт на будущее» |
| порядок PoC, что вне скоупа v0 | «Лестница PoC», «Не входит в v0» |

## Цель

Один язык должен описывать ровер, карьерный бур, лифт, кран, корабль, стационарную
базу и их сети. Разница между ними должна следовать из композиции элементов, а не из
отдельного кода для каждого класса техники.

Базовая фраза языка:

> Сборка состоит из элементов, соединённых joints и сетями. Она взаимодействует с
> полями и поверхностями мира, воспринимает мир датчиками и изменяет его приводами
> и инструментами.

Язык проектируется на весь домен сразу. Реализуется он ступенями: сначала машины,
затем перестройка конструкций, пассажиры, потоки и герметичные объёмы.

## Граница владения

### Симуляция владеет смыслом

Структура сборки, элементы, joints, порты, сети, ресурсы, прочность, повреждения,
команды и чертежи являются авторитетными данными симуляции.

Команды делятся на два потока с разными требованиями к доставке:

- *Структурные* (редкие, обязаны быть надёжными и упорядоченными): `place`,
  `attach`, `detach`, `weld`, `damage`, `break`, `repair`, `dismantle`,
  `connect_network`, `disconnect_network`. Industry v1: `connect_network` создаёт
  **electric** cable edge между compatible output/input ports; cable может
  связывать разные Assembly и не создаёт mechanical merge.
  **Cargo** — placeable `cargo_pipe` modules + auto-link on topology, без
  `connect_network`; см. `docs/specs/INDUSTRY-V1.md`.
- *Управляющие* (частые, допускают перезапись последним значением):
  `set_actuator_target`, `set_binding_state`.
- *Мировые* (voxel-edit, идут журналом операций): `terrain_carve`, `voxel_remove`.

Мутации структуры происходят только структурными командами. Terrain мутируется
только мировыми операциями, не structural commands.

### Jolt владеет динамикой

Физический движок авторитетно вычисляет:

- позу;
- линейную и угловую скорость;
- контакты и импульсы;
- constraint-состояние;
- сон физического тела.

Симуляция не дублирует solver твёрдых тел. После физического шага позы и скорости
публикуются как производный snapshot. Правила могут читать snapshot, но не изменяют
его напрямую.

Topology и physics pose используют разные пространства. `origin_cell` и
`GridTransform` описывают только integer assembly-local topology и явно snapped
relative alignment структурной команды. Произвольная мировая поза движущейся
Assembly хранится как continuous `Transform3D` вместе с linear/angular velocity и
sleep/frozen state на physics boundary; она никогда не округляется обратно в grid.
Physics pose является rigid transform: finite orthonormal right-handed Basis
проверяется с epsilon `1e-4`; scale, shear и reflection недопустимы.

Обе истины авторитетны и обе сохраняются в snapshot: discrete topology truth
мутируется только structural commands и версионируется `topology_revision`;
continuous kinematic truth (`AssemblyMotionState`) продвигается физикой. Motion —
не presentation. **`Assembly.motion` — поза/скорость root body group.** Child
groups (поршень/carriage) синхронизируются в `body_group_motions` или
реконструируются из root + piston `observed_position_m`. Мировая поза элемента —
`SimulationWorld.element_world_transform(element_id)` (group motion × topology
local), не `assembly.motion * local`. Инвариант: topology-логика не читает motion
нигде, кроме единственного validated merge alignment gate. Continuous kinematic
truth пишется через `sync_assembly_motion` (root) и
`sync_assembly_body_group_motion(s)` (child groups); projection — единственный
live-body caller.

**World loot pile** — упрощённый тот же контракт: симуляция владеет
`WorldLootPile` (id, resource, mass, despawn); `WorldLootProjection` строит
`RigidBody3D`, Jolt интегрирует позу, write-back — `sync_world_loot_position`.
Merge-by-proximity читает симуляционную позицию после write-back.

### Поток данных

```text
Blueprint / Commands
        |
        v
Simulation structure
        |
        v
Physics build/rebuild ---> Jolt step
                              |
                              v
                     pose/contact snapshot
                              |
                              v
                    Simulation + presentation
```

Такая граница совместима с будущим коопом: сервер владеет структурой и физикой,
клиенты отправляют команды и получают snapshots.

## Единицы

Используется СИ:

- длина — метр;
- масса — килограмм;
- время — секунда;
- сила — ньютон;
- момент — ньютон-метр;
- давление — паскаль;
- энергия — джоуль;
- мощность — ватт;
- температура — кельвин.

Гравитация задаётся `Field`, а не локальным `gravity_scale`. Для лунного PoC:
`1.62 m/s²`.

## Примитивы

### Assembly

Экземпляр конструкции. Содержит элементы и графы связей. Связная жёсткая компонента
компилируется в одно физическое тело.

База — Assembly с `Anchor`. Машина — Assembly без якоря. Лифт — Assembly на `Rail`
или `Piston`.

### Element

Минимальная авторимая часть конструкции:

```text
Element {
  id
  archetype
  local_pose
  build_progress
  integrity
  condition
  state_revision
  installed_materials{resource_id: amount}
}

ElementArchetype {
  id
  roles[]
  mass
  colliders[]
  max_integrity
  ports[]
  build_requirements[]
}
```

Роли элементов:

- `Frame` — несущая структура;
- `ControlSeat` — место управления;
- `Source` — генератор или аккумулятор;
- `Tank` — жидкость, газ, энергия;
- `CargoHold` — твёрдый или сыпучий груз;
- `Processor` — преобразование ресурсов по Recipe;
- `Fabricator` — изготовление дискретных компонентов по Recipe;
- `Actuator` — сила или момент;
- `Tool` — воздействие на внешний мир;
- `Support` — колесо, нога, гусеница;
- `Bulkhead` — граница герметичного объёма;
- `Sensor` — измерение состояния.

Роль является возможностью, а не закрытой иерархией: один элемент может совмещать
несколько ролей.

Industry v1 stationary drill materializes `Tool` orientation as a visible working
head. Its local working face is part of the machine contract: terrain probe and
`terrain_carve` use the same oriented head transform. Mining requires voxel-terrain
contact/proximity within finite head reach. No contact means no world mutation, no
resource credit, and reason `no_terrain_contact`. A fixed-grid head can exhaust only
its reachable local volume; continued advance requires a mechanical feed/actuator.

`ElementArchetype` — data-driven определение неизменяемых параметров типа элемента.
`colliders[]` является typed compound collider: каждый multi-cell footprint cell
имеет физическое покрытие. `build_requirements[]` — typed bill of materials из
`resource_id` и положительного `amount`. Экземпляр хранит ссылку на archetype и
runtime-состояние. Первый обязательный компонент bill of materials расходуется при
placement; остальные переносятся в каркас командой `weld`.

Construction v1 использует simulation-owned `ResourceStore`: `place`, `weld` и
`repair` атомарно списывают материал, `dismantle` возвращает заданную долю.
`installed_materials` является учётом фактически внесённого BOM, а
`build_progress` — его нормализованной долей. Topology-команды меняют revision
Assembly; `weld`, `damage` и `repair` меняют отдельный `state_revision` Element.

Archetype `.tres` являются hand-authored source definitions и единственным
источником их параметров; GDScript не дублирует их factory-значения. Bake-процесс
применяется к visual Blueprint authoring, но не к archetypes.

### Port

Типизированная **функциональная** точка интерфейса (electric, cargo, anchor, …).
Порт **не** является единственным местом физического structural-крепления блока.

```text
Port {
  id
  kind
  local_pose
  direction
  capacity
  compatibility
}
```

Виды портов:

- mechanical — anchor и прочие явные mechanical-интерфейсы (не generic structural
  surface);
- electric;
- fluid;
- gas;
- data;
- thermal;
- mechanical_power — абстрактная передача вращения/мощности (вместо шестерён);
- cargo.

Порт не гарантирует связь. Соединение является отдельным ребром графа:
`Rigid` structural edges выводятся из derived surface faces; functional mechanical
(`Anchor`) и industry-порты соединяются явно; electric/cargo — рёбра Network.

### Structural surface (derived)

Физическое structural-крепление идёт через **surface cells** единой grid **0.5 m**,
а не через шесть центральных structural-портов archetype.

`DerivedSurfaceFace` — наружная грань footprint: `(local_cell, local_face)` на
границе occupancy. Грань между двумя cells одного элемента не является surface.
Каждая допустимая surface получает стабильное производное имя
`structural_<x>_<y>_<z>_<face>` (например `structural_2_0_1_px`). Имя используется
в `SimulationJoint.port_*_id` и snapshot, но не дублируется как запись `.tres`.

`ElementArchetype.structural_surface_policy`:

- `full_surface` — все наружные грани footprint (рамы, балки, foundation);
- `mount_pads` — только author-defined `(local_cell, local_face)` mount pads
  (машины);
- `none` — structural attachment запрещён.

`Rigid` валиден, когда две surface cells соседствуют, лежат в одной плоскости и
смотрят друг на друга. Multi-cell контакт даёт **один** логический joint; в
snapshot хранится детерминированная canonical pair derived IDs, остальные контакты
всегда выводятся из двух footprint.

Cargo/electric/anchor остаются явными `PortDefinition` и **не** превращаются в
generated structural surface ports.

### Joint

`Rigid` — structural связь между двумя derived surface faces (canonical ID pair).
`Anchor` — mechanical-порт элемента к миру (воксельный грунт, скала); второй конец
не порт:

```text
Joint {
  a
  b
  kind
  tensile_strength
  shear_strength
  bending_strength
  fatigue
  solver_mode
}
```

Пассивные виды:

- `Rigid` — сварка; попадает в одно физическое тело;
- `Anchor` — крепление к миру; создаётся только для construction-элементов с
  подтверждённым контактом collider с voxel terrain (любая грань). После split/dismantle
  kernel пересчитывает anchors по probe boundary adapter, не читая motion напрямую;
- `FreeHinge` — дверь или прицеп без мотора;
- `Suspension` — пружина и демпфер;
- `Rail` — каретка на направляющей;
- `MagnetDock` — командно размыкаемая стыковка.

Приводные виды:

- `Rotor` — непрерывное вращение;
- `ServoHinge` — привод на целевой угол;
- `Piston` — привод на целевое выдвижение.

Приводной joint содержит:

```text
Motor {
  target_position
  target_velocity
  force_limit
  speed_limit
  lower_limit
  upper_limit
  stiffness
  damping
  power_draw
  overload_policy
}
```

Мотор получает цель, но никогда не устанавливает transform напрямую. Политика
перегрузки: остановка, срез предохранителя или разрушение joint.

Жёсткая сборка всегда компилируется в одно тело. Физический joint создаётся только
там, где движение является частью геймплея. Цепи длиннее 3–4 приводных joints
считаются физически рискованными. Для дверей и декора допустим `kinematic` solver,
но он не участвует в честных силовых взаимодействиях.

### Body

Производное физическое тело связной жёсткой компоненты:

```text
Body {
  mass
  center_of_mass
  inertia
  pose_snapshot
  velocity_snapshot
  sleeping
}
```

Изменение состава инвалидирует массу, центр масс, инерцию и compound collider.
Пересборка обязана сохранять мировой transform и импульс без скачка.

### Field

Условие пространства:

```text
Field {
  gravity
  temperature
  external_pressure
  atmosphere
}
```

В будущем поля могут быть локальными, но v0 использует одно поле на локацию.

### Surface

Свойства контактной поверхности:

```text
Surface {
  grip
  rolling_resistance
  hardness
}
```

Обычные тела используют физическое трение Jolt. Колёса используют `grip` как
множитель своей контактной модели. В v0 весь реголит имеет один Surface.

### Actuator

Преобразует Flow и команду в физическое воздействие.

Виды:

- сила в точке — двигатель, лебёдка, привод колеса;
- чистый момент — `Gyro`;
- motor у приводного Joint.

```text
Actuator {
  command
  force_or_torque_limit
  response_rate
  efficiency
  input_port
  status
}
```

`Gyro` ограничен моментом и энергией. SAS — не особая система: Sensor угловой
скорости управляет Gyro через правило.

### Wheel

Колесо v0 — raycast-contact, а не физический цилиндр:

```text
Wheel {
  radius
  suspension_travel
  spring
  damper
  drive_torque
  brake_torque
  longitudinal_grip
  lateral_grip
  steering_angle
}
```

Suspension создаёт силу по нормали. Продольная сила разгоняет и тормозит, поперечная
гасит боковое скольжение в пределах grip. После превышения grip колесо скользит.
Продольная и боковая силы совместно расходуют friction ellipse; ни steering command,
ни control layer не изменяют drive torque скрытым образом.

Wheel — составная роль: `Support` (контакт с поверхностью) + `Suspension`
(встроенная, не отдельный Joint в v0) + `Actuator` (drive/brake torque). Отдельный
Suspension-joint нужен только когда колесо — отдельный физический блок.

Player-built ровер (отдельные placeable подвеска + колесо, socket-крепление,
кокпит `ControlSeat`, малые энергоблоки, simulation-owned raycast locomotion) —
`specs/ROVER-MODULES-V1.md`. Колесо и подвеска — два элемента: подвеска несёт
raycast-модель хода, колесо крепится к её `wheel_socket` обычным `Rigid` joint,
а assembly с готовой парой колесо+подвеска компилируется в dynamic body group.
Цельные baked-машины (`cart_rover` / mount locomotion) сняты: техника собирается
из кирпичиков, как construction.

### Cable / Tether

Односторонняя связь, которая тянет, но не толкает:

```text
Cable {
  length
  max_tension
  reel_speed
  endpoints
}
```

Не моделируется как честная непрерывная верёвка. Допустима расчётная связь или малое
число сегментов. Использования: буксир, крановый подвес, страховочный трос.

### Sensor

Публикует измерение:

- угол/ход/нагрузка joint;
- контакт и нормаль;
- скорость и высота;
- заряд, Flow и температура;
- давление Volume;
- целостность элемента.

Sensor не принимает решений.

### ControlSeat и Binding

`Binding` переводит входную ось или команду автоматики в команду Actuator:

```text
Binding {
  source
  target_actuator
  scale
  curve
  condition
}
```

Игрок, автопилот и декларативное правило используют один командный интерфейс. Не
существует отдельных «кода ровера» и «кода корабля».

### Network, Flow и Store

`Network` — граф совместимых портов одного типа. Узлы производят, потребляют,
накапливают или преобразуют Flow:

- electric power;
- fluid;
- gas;
- data;
- thermal;
- abstract mechanical power;
- cargo.

Физические шестерни, валы и ремни не входят в v0. Механическая мощность передаётся
абстрактным Network. Тепло также является Flow: двигатель производит, радиатор
сбрасывает, поле мира задаёт теплообмен.

`Tank/Store` хранит непрерывный ресурс. `CargoHold` хранит дискретный или сыпучий
груз. Ковш → бункер → самосвал выражается cargo Flow.

### Resource, Recipe и производство

`ItemType` задаёт тип груза в `CargoHold` или inventory Store. Количество
предмета находится в Store, а не в presentation-node. Энергия и прочие
непрерывные Flow не являются `ItemType`.

```text
ItemType {
  id
  category
  mass_per_unit_kg
  volume_per_unit_l
  unit                 # bulk | discrete
}
```

`unit = bulk` допускает дробное количество; `unit = discrete` допускает только
целое неотрицательное количество. Store не округляет discrete amount молча:
попытка add/remove/set с дробной частью отклоняется. UI выбирает целое
количество до отправки команды (например, Shift-перенос — `floor(stack / 2)`,
но не менее одного предмета).

`volume_per_unit_l` определяет вместимость: Store/buffer полон, когда
`Σ(amount × volume_per_unit_l) >= capacity_l`. Число visual slots не является
лимитом. `mass_per_unit_kg` обязателен независимо от объёма и используется
только для `mass_coupling`/физики:

```text
store_volume_l = Σ(amount[item_id] × volume_per_unit_l)
store_mass_kg  = Σ(amount[item_id] × mass_per_unit_kg)
```

`ore`, `ingot` и `material` — bulk-категории; `component`, `tool`,
`consumable` и `bottle` — discrete. Player tools — unique instances (не stack
count); hotbar ссылается на `instance_id`. См. `docs/specs/INDUSTRY-V1.md`
§ Player tool instances и hotbar. Полный fixture-каталог и ёмкости Industry
v1 определены в `docs/specs/INDUSTRY-V1.md` § Система предметов.

`ResourceType` — устаревшее имя для ItemType в старых командах и fixtures;
новые доменные контракты используют `item_id` и `ItemType`. Рецепт по-прежнему
декларативно перечисляет идентификаторы и количества входов/выходов.

`Recipe` декларативно описывает преобразование ресурсов:

```text
Recipe {
  id
  inputs[]
  outputs[]
  duration
  power
  allowed_processor_tags[]
}
```

`Processor` выполняет Recipe во времени. `Fabricator` — Processor, чьи результаты
являются дискретными строительными компонентами или предметами. Рецепт не содержит
сценовой логики.

Входы одной операции резервируются атомарно. Остановка или отмена не должна
дублировать либо **молча уничтожать** ресурс: политика возврата/частичного результата
задаётся Recipe. Выход помещается только в совместимый Store; заполненный выход
останавливает операцию с диагностируемой причиной. **Industry v1:** при
`storage_full` producer **останавливается** (drill, cargo push) — без silent discard;
см. `docs/specs/INDUSTRY-V1.md`.

Минимальная production-цепочка, dual-path ISRU, electric/cargo Flow и границы первой
реализации — `docs/specs/INDUSTRY-V1.md`. Vertical slice summary —
`docs/specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md`.

### Volume и Atmosphere

`Volume` — замкнутое пространство, граница которого образована Bulkhead-элементами.
`Atmosphere` хранит давление, состав и температуру.

Пробоина создаёт соединение Volume с внешним Field. v0 не симулирует CFD: потоки
между объёмами считаются по графу отверстий.

### Blueprint

Отделён от экземпляра и содержит:

- элементы и локальные позы;
- порты;
- joints;
- network-связи;
- bindings;
- начальные настройки.

Blueprint является форматом сохранения, обмена и пересборки. Runtime-состояние
(повреждение, ресурсы, позы тел) хранится отдельно.

В Kernel v0 Blueprint — typed `Resource` с sorted `BlueprintElementPlacement[]`.
Visual authoring scene выпекает deterministic `.tres`; runtime не читает
authoring nodes. Подробности — `docs/specs/SIMULATION-KERNEL-V0.md`.

`BlueprintElementPlacement.local_id` уникален только внутри Blueprint и служит
ссылкой authoring/bake. Каждый spawn Blueprint в `SimulationWorld` выделяет новые
глобально уникальные persistent `ElementId` и сохраняет mapping
`local_id → ElementId`. Два экземпляра одного Blueprint не разделяют `ElementId`.

### Identity и topology (Kernel v0)

Доменные ссылки не используют Godot `NodePath`, `RID` или `instance_id`.

| ID | Постоянство | Назначение |
|---|---|---|
| `ElementId` | persistent | элемент внутри Assembly |
| `AssemblyId` | persistent | владеет элементами, joints, revision |
| Body/projection id | transient | Jolt compound body; пересоздаётся из snapshot |

Placement использует единую integer grid **0.5 m** и `orientation_index` из **24**
ортогональных кубических ориентаций. Один элемент может занимать несколько cells
через `footprint_cells` archetype. Вторая несовместимая grid не вводится:
малые rover/frame/pipe элементы и крупные машины разделяют одну topology.

`orientation_index = 0` — точный identity. Остальные индексы следуют стабильной
канонической таблице right-handed integer Basis с determinant `+1`.

Жёсткая связь (`Rigid`) возникает только между совместимыми derived structural
surface faces на соседних cells (см. «Structural surface (derived)»). В v0 runtime
компилирует только `Rigid` и `Anchor`; остальные joint kinds — schema placeholders.
Multi-cell контакт — один joint на пару элементов; canonical derived ID pair в
`port_a_id`/`port_b_id`.

Unified grid относится к assembly topology и attach placement. Continuous root pose
на terrain и terrain-contact **не** навязывают мировую 0.5 m сетку на неровном
грунте.

При split disconnected component становится отдельной Assembly. Автоматический
survivor выбирается как `Anchor → element count → dry mass → lowest ElementId
в компоненте`. Компоненты split происходят из одной Assembly, поэтому
`AssemblyId` не различает финальную ничью.

Merge использует `Anchor → element count → dry mass → lowest AssemblyId`; loser
получает tombstone/redirect. Projection/gateway валидирует и передаёт явно snapped
`B relative to A` grid transform; A/B command endpoints и transform не зависят от
того, какая сторона станет survivor. При B-survivor используется inverse того же
transform, поэтому survivor policy не меняет физическое alignment. При merge двух
anchored Assembly Anchor проигравшей стороны автоматически удаляется, а итог
остаётся anchored.

Snapped merge разрешён только в пределах `0.125 m` Euclidean positional error и
`7.5°` angular error до ближайшей 24-orientation pose. Gateway может отклонить
команду раньше, но authority всегда повторно сверяет current continuous A/B poses
и supplied snapped transform перед topology mutation.

Projection transient: `AssemblyId` отображается в `StaticBody3D` для anchored
Assembly или Jolt `RigidBody3D` для dynamic Assembly; `ElementId` отображается в
его collider owner metadata. Node/RID/instance ID не попадают в topology или
snapshot. Split наследует скорость каждой новой COM как
`v + omega × (com_child - com_parent)`. Merge сохраняет linear momentum и angular
momentum относительно merged COM, включая orbital component; diagonal inertia
compound body оценивается на projection boundary из-за ограничения high-level
Godot API.

## Строительство, прочность и ремонт

Placement создаёт элемент с **1% структурной целостности** (`integrity`).
Сварка повышает целостность до `100%` — полностью готовый объект. Бур и болгарка
уменьшают целостность. `build_progress` — derived `integrity / max_integrity` для
UI и snapshot.

- `integrity` — единая структурная целостность, `0..max_integrity`;
- `condition` — долговременный износ (зарезервирован, v1 = `1.0`).

`weld` повышает `integrity` (BOM + компоненты), `damage` уменьшает `integrity`.
Элемент функционален только при `integrity = max_integrity`.

```text
preview -> frame (1%..99%) -> operational (100%)
                |                    |
                +------- damage -----+
                |                    v
                +------------> destroyed (topology removal)
```

Вместо FEM используется игровая модель графа нагрузок:

1. Внешние силы и массы создают нагрузки в точках.
2. Нагрузки распределяются по structural joints к опорам/центру связности.
3. Joint сравнивает растяжение, сдвиг и изгиб с пределами.
4. Усталость накапливается от повторных перегрузок.
5. Разорванное ребро запускает поиск связных компонент.
6. Каждая отсоединённая компонента становится отдельным Body.

- `damaged` ухудшает параметры;
- lethal `damage` (`integrity → 0`) удаляет элемент из topology без material
  refund; survivor/split policy совпадает с `dismantle`, но `refund_fraction = 0`;
- persistent `broken` элемента в topology нет;
- `detached` становится обломком (вне scope v1);
- `dismantle` управляемо удаляет элемент и возвращает заданную правилами долю
  ресурсов;
- ремонт, сварка и демонтаж инициируются Tool, но применяются simulation-командами.

### Кинетический удар (Impact Destruction v0)

Динамическая `RigidBody3D` Assembly может удариться о мир или другую Assembly.
Jolt авторитетен за импульс контакта; правила на physics boundary:

- удар о voxel terrain → `terrain_carve` (форма collider, сила от импульса) плюс
  `damage` ударяющего элемента;
- удар assembly ↔ assembly → `damage` обоим элементам по импульсу на каждой стороне;
- anchored `StaticBody3D` не источник удара; placement и расширение базы carve не
  вызывают.

Вырезанная порода:

- Terrain мутируется только общей мировой операцией excavation. Она измеряет
  SDF до и после edit и публикует только реально удалённый объём; форма stamp,
  частота вызовов или аналитический объём инструмента не являются yield.
- **Hand drill:** результат сначала передаётся в player resource store; остаток
  → world loot pile у точки выброса. Пустота и повторное бурение уже удалённой
  области не дают ресурс.
- **Stationary drill:** перед terrain edit проверяет storage/backpressure,
  затем передаёт подтверждённый результат во внутренний buffer. При отсутствии
  capacity terrain не меняется.
- **Impact:** использует тот же measured carve path; политика material yield
  задаётся явно для каждого impact type и не может обходить мировую операцию.

Kinetic Interaction v1 расширяет удар на **приводимые актуаторы**: единый скаляр
`J = max(collision_impulse, m_eff·v_rel, applied_force·Δt)` даёт carve/damage не
только от падения и тарана, но и от упора пистона/бура в грунт. Carriage пистона
получает impact-мониторинг (`MONITOR_ONLY`, без `custom_integrator`), sustained
carve идёт в окне насыщения до `OVERLOADED`. Subgrid immunity: контакты внутри
одной assembly (base ↔ head) не наносят урон. Кинетически вырезанный грунт
исчезает (лут — только у буров).

PoC-спеки impact: `docs/specs/IMPACT-DESTRUCTION-V0.md` (база),
`docs/specs/KINETIC-INTERACTION-V1.md` (актуаторы, carriage, sustained).

## Диагностируемость

Каждая функциональная система публикует `status` и `reason`:

- `no_power`;
- `outside_power_radius`;
- `port_disconnected`;
- `overloaded`;
- `joint_limit`;
- `no_contact`;
- `no_terrain_contact`;
- `no_grip`;
- `no_input`;
- `storage_full`;
- `disabled`;
- `queue_full`;
- `element_incomplete`;
- `element_broken`;
- `volume_leaking`;
- `actuator_broken`.

Игрок и отладчик должны отвечать «почему не работает» без чтения логов.

## Состояние скафандра (SuitState)

`SuitState` — минимальное authoritative состояние выживания игрока: `health`
(hp), `oxygen` (O₂) и `hydrogen` (H₂), каждое как `current` + `max` с
нормализованной долей, плюс сигнал изменения. Это самодостаточное survival-state,
а **не** полная система атмосфер/жизнеобеспечения (герметичные объёмы, давление,
утечки `volume_leaking`, газообмен) — они остаются вне scope. HUD (`Vitals`)
только читает `SuitState`; контракт HUD — `docs/specs/HUD-UI-01.md`.

## Производительность

- Спящие тела не тикают actuator/suspension без причины.
- Далёкие неактивные сборки замораживаются.
- Compound collider пересобирается пакетно после структурных команд.
- Network и structural graph пересчитываются только после изменения топологии.
- Кинематические декоративные механизмы не входят в solver.

## Сетевой контракт на будущее

Single-player реализуется первым, но API готовится к host-authoritative коопу:

- структура изменяется дискретными командами;
- физика выполняется только авторитетной стороной;
- клиенты получают snapshots поз и состояния;
- voxel-edit передаётся операцией, а не полным объёмом;
- late join получает Blueprint + runtime state + журнал/снимок voxel-edit.

## Лестница PoC

### PoC-1 — Rover (три ступени)

Ровер разрезан на изолированные проверки, чтобы отказ был диагностируем:

- **1a — тележка.** Честное поле 1.62 м/с² (без `gravity_scale`), ящик на четырёх
  raycast-пружинах без привода. Критерий: встаёт на подвеску, катится от толчка,
  сползает и опрокидывается на склоне. Проверяет гравитацию и подвеску.
- **1b — привод.** Крутящий момент и тормоз через продольное сцепление.
  Критерий: разгон, торможение, буксование при превышении grip.
- **1c — руль.** Поворот передних колёс и поперечное сцепление.
  Критерий: управляемость на неровном грунте, занос на скорости, подъём на уклон.

### PoC-2 — Rebuild

Удаление/добавление элемента через структурную команду. Масса, центр, compound
collider и связность пересчитываются без телепорта. Оторванная компонента получает
собственный Body.

### PoC-3 — Passenger

Игрок стоит и ходит на движущемся Body: наследует скорость опоры, не проваливается
и не скользит произвольно. Если честный character controller нестабилен, допустим
явно описанный fallback attachment.

### После физического ядра

Изолированные PoC завершены. Дальнейшие системы собираются в production vertical
slice по `docs/specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md`:

1. Player & Interaction v1.
2. Simulation Kernel v0.
3. Construction v1.
4. Impact Destruction v0: кинетический удар → terrain carve и assembly damage.
5. Industry v1: electric/cargo Flow, distributor, wire mesh, ISRU Recipe —
   `docs/specs/INDUSTRY-V1.md`.
6. Интеграция и production-полировка законченного core loop.

После первого slice лестница доменных возможностей продолжается:

1. Piston с нагрузкой и overload —
   `docs/specs/POC-ACTUATORS-V1.md`; затем ServoHinge —
   `docs/specs/POC-ACTUATORS-V3-HINGE.md`.
2. Расширенная логистика и автоматизация.
3. Volume/Atmosphere: герметичная кабина → пробоина.
4. Host-authoritative сетевой PoC.

## Не входит в v0

- физические шестерни, ремни и валы;
- CFD жидкостей и газов;
- FEM;
- честная непрерывная верёвка;
- послойный material query вокселя под колесом;
- универсальные цепи из десятков физических joints.
