# Physical Language v0

Статус: контракт standalone Godot-проекта **Regolith**. Это не схема Erebus и не
ADR. Интеграция в Erebus — через Erebus Lite addon, когда контент станет data-driven.

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
  `connect_network`, `disconnect_network`.
- *Управляющие* (частые, допускают перезапись последним значением):
  `set_actuator_target`, `set_binding_state`.

Мутации структуры происходят только структурными командами.

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
не presentation. Инвариант: topology-логика не читает motion нигде, кроме
единственного validated merge alignment gate. Continuous kinematic truth пишется
через единственную точку `SimulationWorld.sync_assembly_motion(...)`, которая
валидирует rigid transform и отклоняет невалидный вход; projection — единственный
live-body caller и не присваивает motion напрямую.

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

`ElementArchetype` — data-driven определение неизменяемых параметров типа элемента.
`colliders[]` является typed compound collider: каждый multi-cell footprint cell
имеет физическое покрытие. `build_requirements[]` — typed bill of materials из
`resource_id` и положительного `amount`. Экземпляр хранит ссылку на archetype и
runtime-состояние. Первый обязательный компонент bill of materials расходуется при
placement; остальные переносятся в каркас командой `weld`.

Archetype `.tres` являются hand-authored source definitions и единственным
источником их параметров; GDScript не дублирует их factory-значения. Bake-процесс
применяется к visual Blueprint authoring, но не к archetypes.

### Port

Типизированная точка интерфейса:

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

- mechanical — точка крепления Joint;
- electric;
- fluid;
- gas;
- data;
- thermal;
- mechanical_power — абстрактная передача вращения/мощности (вместо шестерён);
- cargo.

Порт не гарантирует связь. Соединение является отдельным ребром графа:
mechanical-порты соединяет Joint, остальные — рёбра Network.

### Joint

Механическая связь между двумя mechanical-портами. Исключение — `Anchor`: его второй
конец не порт, а мир (воксельный грунт, скала):

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
- `Anchor` — крепление к миру;
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
Suspension-joint нужен только когда колесо — отдельный физический блок; в v0 колесо
принадлежит Body и вся подвеска живёт в raycast-модели.

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

`ResourceType` задаёт идентичность хранимого вещества, энергии или дискретного
компонента. Количество ресурса находится в `Store`, а не в presentation-node.

```text
ResourceType {
  id
  unit
  cargo_compatibility
}
```

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
дублировать либо молча уничтожать ресурс: политика возврата/частичного результата
задаётся Recipe. Выход помещается только в совместимый Store; заполненный выход
останавливает операцию с диагностируемой причиной.

Минимальная production-цепочка и границы первой реализации заданы в
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

Placement использует integer grid **1 m** и `orientation_index` из **24**
ортогональных кубических ориентаций. Один элемент может занимать несколько cells
через `footprint_cells` archetype.

`orientation_index = 0` — точный identity. Остальные индексы следуют стабильной
канонической таблице right-handed integer Basis с determinant `+1`.

Жёсткая связь (`Rigid`) возникает только между совместимыми mechanical
structural faces на соседних cells. В v0 runtime компилирует только `Rigid` и
`Anchor`; остальные joint kinds — schema placeholders.

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

Placement создаёт элемент в состоянии `frame`, но не делает его автоматически
рабочим. Строительство и повреждение — независимые оси состояния:

- `build_progress` — завершённость строительства;
- `integrity` — текущая прочность готовой конструкции;
- `condition` — долговременный износ и эффективность.

`weld` повышает `build_progress`, `damage` уменьшает `integrity`, `repair`
восстанавливает `integrity`. Эти команды могут потреблять ресурс. Элемент становится
функциональным только после достижения порога строительства; незавершённый каркас
может иметь массу и коллайдер по правилам archetype, но не скрытую полную функцию.

Базовый жизненный цикл:

```text
preview -> frame -> healthy -> damaged -> broken
              ^         ^          |
              |         +-- repair-+
              +--------- dismantle
```

Вместо FEM используется игровая модель графа нагрузок:

1. Внешние силы и массы создают нагрузки в точках.
2. Нагрузки распределяются по structural joints к опорам/центру связности.
3. Joint сравнивает растяжение, сдвиг и изгиб с пределами.
4. Усталость накапливается от повторных перегрузок.
5. Разорванное ребро запускает поиск связных компонент.
6. Каждая отсоединённая компонента становится отдельным Body.

- `damaged` ухудшает параметры;
- `broken` остаётся частью массы и структуры, но теряет функцию;
- `detached` становится обломком;
- `dismantle` управляемо удаляет элемент и возвращает заданную правилами долю
  ресурсов;
- ремонт, сварка и демонтаж инициируются Tool, но применяются simulation-командами.

## Диагностируемость

Каждая функциональная система публикует `status` и `reason`:

- `no_power`;
- `port_disconnected`;
- `overloaded`;
- `joint_limit`;
- `no_contact`;
- `no_grip`;
- `no_input`;
- `storage_full`;
- `element_incomplete`;
- `element_broken`;
- `volume_leaking`;
- `actuator_broken`.

Игрок и отладчик должны отвечать «почему не работает» без чтения логов.

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
4. Industry v1: electric и cargo Flow, стационарная добыча, Recipe.
5. Интеграция и production-полировка законченного core loop.

После первого slice лестница доменных возможностей продолжается:

1. Piston/ServoHinge с нагрузкой и overload.
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
