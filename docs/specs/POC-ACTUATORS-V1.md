# Actuators v1 — Piston PoC

Статус: implementation contract для первого post-slice actuator.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md`;
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/CONSTRUCTION-V1.md`;
- `docs/specs/INDUSTRY-V1.md`;
- `docs/specs/PLAYER-INTERACTION-V1.md`.

## Цель

Добавить универсальный силовой `Piston` в языке Assembly:

- игрок ставит один piston construction item;
- к piston head крепятся обычные элементы и rigid-конструкции;
- head и всё прикреплённое к нему движутся как отдельное Jolt body;
- мотор достигает target extension только через ограниченную силу, а не через
  прямую запись transform;
- масса, гравитация, контакты и препятствия реально влияют на движение;
- limit, stall и overload наблюдаемы в authoritative state и HUD;
- игрок может стоять и ходить на движущейся piston platform.

Это реализация уже определённых в `PHYSICAL-LANGUAGE.md` понятий `Piston`,
`Motor`, `Actuator`, `Body` и `set_actuator_target`. Новая параллельная модель
механики не вводится.

## Нормативные решения

1. `Assembly` может содержать несколько rigid body groups. Каждая связная
   компонента подграфа `Rigid` компилируется в одно physics body.
2. `Piston` соединяет две разные rigid body groups внутри одной `Assembly`.
3. Полный mechanical graph (`Rigid` + driven joints) определяет membership
   `Assembly`; только `Rigid`-подграф определяет body groups.
4. Piston construction item материализуется как два обычных элемента:
   `piston_base` и `piston_head`, соединённых `Piston` joint.
5. Их создание и первоначальная установка атомарны для игрока: частично
   созданного поршня после rejected command не существует.
6. Topology хранит piston в полностью втянутой home pose. Выдвижение не меняет
   `origin_cell`, occupancy или `GridTransform`; это continuous joint state.
7. Jolt владеет позами, скоростями, контактами и constraint dynamics.
   Симуляция владеет topology, motor command, limits, policy и status.
8. В v1 поддерживается только силовой dynamic solver. Kinematic transform
   fallback не является допустимой реализацией acceptance.

## Границы

### Входит

- один тип driven joint: `Piston`;
- anchored и полностью dynamic Assembly;
- до четырёх driven joints на одном acyclic body-group path;
- блоки и платформы на piston head;
- position, velocity и stop control modes;
- force/speed/travel limits;
- electric on/off budget;
- `joint_limit`, `stuck`, `overloaded`, `no_power`;
- overload policy `stop`;
- snapshot/restore;
- damage, dismantle и split вокруг piston;
- passenger support на движущемся head body.

### Не входит

- `Rotor`, `ServoHinge`, `Rail`, `Suspension`;
- циклы driven joints и замкнутые constraint-механизмы;
- цепи длиннее четырёх driven joints;
- строительство на выдвинутом или движущемся body group;
- merge двух существующих Assembly через driven joint;
- programmable bindings, sequencing и automation UI;
- fatigue и постепенное накопление joint damage;
- overload policies `fuse` и `break`;
- физически точная электрическая энергия: Industry v1 остаётся on/off power
  budget, без преобразования каждого джоуля в mechanical work;
- сетевой prediction/rollback.

## Authoring

### Piston definition

`ElementArchetype` с ролью `Actuator` может иметь typed
`PistonDefinition`. Для v1 определение существует только у `piston_base`:

```text
PistonDefinition {
  head_archetype_id
  axis_face
  retracted_offset_m
  lower_limit_m
  upper_limit_m
  default_speed_limit_mps
  extend_velocity_mps
  retract_velocity_mps
  force_limit_n
  stiffness_n_per_m
  damping_n_s_per_m
  power_draw_w
  overload_policy
}
```

Все значения используют SI. `axis_face` проходит через стабильную таблицу
`OrientationUtil`; world axis получается из orientation `piston_base`, а не
задаётся presentation node.

Validator отклоняет definition, если:

- head archetype отсутствует или player-placeable;
- limits не удовлетворяют
  `0 <= lower_limit_m < upper_limit_m`;
- retracted offset лежит вне limits;
- extend/retract velocity, force, stiffness, damping или power draw отрицательны;
- overload policy отличается от `stop`;
- у base нет ровно одного internal mechanical port `piston_drive`;
- у head нет сопряжённого internal port `piston_carriage`;
- head не предоставляет structural mount pad на внешней head face;
- home footprints base и head пересекаются.

### Slice fixture

Первый fixture:

```text
construction item       piston
base archetype          piston_base
head archetype          piston_head
home footprint          2 cells вдоль local +Y: base, затем head
lower / upper limit     0.0 m / 2.0 m
speed limit             0.25 m/s
force limit             5000 N
power draw              1500 W while commanded
overload policy         stop
```

Числа являются initial tuning fixture, а не универсальными константами kernel.
`piston_head` — internal archetype: он имеет собственные `ElementId`, mass,
integrity и colliders, но не появляется отдельным item в construction toolbar.

## Topology и identity

### Atomic placement

Placement piston item выполняется одной structural transaction:

1. вычисляет grid poses base и head в retracted home pose;
2. валидирует обе footprints и все prospective rigid contacts;
3. валидирует BOM до расхода IDs;
4. выделяет два `ElementId` и один `JointId`;
5. создаёт base, head и `Piston` joint;
6. создаёт обычные `Rigid` joints между base и соседями, но не между base и head;
7. создаёт обычные `Rigid` joints между head face и соседями только там, где
   placement явно разрешает head attachment;
8. публикует один structural event/revision bump.

Любой failure оставляет allocator, Store и topology без изменений. BOM piston
item покрывает обе части; `piston_head` отдельно материалы не списывает.

### Joint endpoint contract

Для `Piston`:

```text
element_a_id / port_a_id = piston_base / piston_drive
element_b_id / port_b_id = piston_head / piston_carriage
```

Направление A → B является значимым и не канонизируется перестановкой endpoints.
Positive extension всегда направлен по authored `axis_face` base.

`SimulationJoint.Kind.PISTON` хранит `MotorState`:

```text
MotorState {
  control_mode
  target_position_m
  target_velocity_mps
  speed_limit_mps
  force_limit_n
  lower_limit_m
  upper_limit_m
  enabled
  overload_policy

  observed_position_m
  observed_velocity_mps
  applied_force_n
  status
  saturation_time_s
}
```

Authoritative authored limits копируются в runtime joint при создании. Изменение
resource после spawn не меняет существующий joint без отдельной migration.

### Body groups

Body group — derived connected component только по `Rigid` edges.
Стабильный transient `body_group_id` равен минимальному `ElementId` компоненты.
Он не сериализуется как identity.

Root group выбирается:

1. группа с `Anchor`;
2. при нескольких anchored groups snapshot invalid;
3. без anchor — группа с минимальным `ElementId`.

`Assembly.motion` остаётся pose/velocity root group. Остальные group poses
восстанавливаются из root motion и ordered joint state. Piston body graph v1
обязан быть acyclic; cycle отклоняется validator/restore.

Anchor делает static только содержащую его body group. Наличие Anchor в base
не превращает head/carriage group в `StaticBody3D`.

## Construction rules

Обычные элементы крепятся к `piston_head` через существующие structural surface
rules и создают `Rigid` edges с head element. Вся rigid-connected ветвь становится
carriage body group и движется вместе с head.

Construction target на non-root body group разрешён в v1 только если:

- все driven joints на path к root находятся в lower limit;
- observed velocity каждого такого joint меньше `0.01 m/s`;
- command отсутствовал не менее двух physics frames;
- snap использует home grid pose.

Иначе preview/command возвращает `moving_target_not_supported`. Строительство на
выдвинутой голове не округляет physical pose обратно в grid и не телепортирует
head.

Нельзя создать обычный `Rigid` edge, который соединит две уже разные body groups
в обход существующего Piston и образует mechanical cycle. Причина:
`driven_joint_cycle`.

## Control command

`set_actuator_target` — frequent last-write-wins command, не structural command:

```text
SetActuatorTargetCommand {
  joint_id
  mode                 # position | velocity | stop
  target_position_m
  target_velocity_mps
  speed_limit_mps
  enabled
}
```

Семантика:

- `position`: target clamp в `[lower_limit, upper_limit]`; движение с
  постоянной скоростью `extend_velocity_mps` / `retract_velocity_mps` по знаку
  error до arrive epsilon;
- `velocity`: target velocity clamp в
  `[-retract_velocity_mps, +extend_velocity_mps]`; primary gameplay mode
  (клик `+` / `-` задаёт signed velocity как в Space Engineers); останавливается
  на travel limit или по `Y`;
- `stop`: target velocity 0, усиленное торможение по оси;
- `enabled = false`: motor force 0, constraint и limits остаются;
- неизвестный, broken или неоперационный joint возвращает typed failure и не
  меняет state.

`configure_actuator` — frequent last-write-wins command для runtime tuning
поршня (как terminal в Space Engineers):

```text
ConfigureActuatorCommand {
  joint_id
  extend_velocity_mps    # optional, -1 = unchanged
  retract_velocity_mps   # optional
  force_limit_n          # optional
  lower_limit_m          # optional, snap 0.1 m
  upper_limit_m          # optional, snap 0.1 m
}
```

Семантика:

- каждое поле опционально; непереданные значения (`< 0`) не меняются;
- velocity clamp в `[0, max_velocity_mps]` из `PistonDefinition`;
- force clamp в `[1, max_force_limit_n]`;
- travel limits clamp в authored `[lower_limit_m, upper_limit_m]` archetype;
- `upper_limit_m <= lower_limit_m` → `invalid_reference`;
- physics projection пересинхронизирует `Generic6DOFJoint3D` limits каждый tick;
- **E** на прицеленном поршне открывает центральную панель настроек с видимым
  курсором; угловая панель цели — только readout;
- HUD target panel показывает текущие значения и подсказку `E — настройки`.

Motor никогда не пишет body transform, linear velocity или joint position
напрямую.

## Power

`piston_base` имеет electric `power_in`. Actuator участвует в существующем
Industry v1 budget как consumer:

- demand = `power_draw_w`, пока motor enabled и joint не broken, включая
  удержание позиции в mode `stop`;
- demand = 0 при disabled или broken;
- powered consumer получает полный motor budget;
- `no_power` даёт motor force 0, но slider constraint и travel limits остаются;
- partial torque/force scaling при brownout не вводится.

Dynamic head position не меняет topology electric graph. Electric wire
подключается к base; питание attached carriage через piston автоматически не
передаётся.

## Physics projection

### Compilation

`SimulationPhysicsProjection` компилирует каждую active Assembly так:

1. строит body groups из `Rigid` subgraph;
2. создаёт `StaticBody3D` только для anchored group, остальные —
   `RigidBody3D`;
3. маршрутизирует каждый collider в body своего element group;
4. создаёт один `Generic6DOFJoint3D` на `Piston`;
5. блокирует три angular DOF и две linear DOF;
6. оставляет translation только вдоль piston axis с authored limits;
7. base/head body groups **сталкиваются** (нет group-wide collision
   exception); clearance стыка — authored меньший box collider у
   `piston_base` / `piston_head` (чуть ниже cell);
8. сохраняет lookup `AssemblyId + body_group_id → PhysicsBody3D` и
   `ElementId → body/collider`.

Никакой presentation mesh не участвует в constraint anchors или limits.

### Motor

Motor — force-limited velocity tracker вдоль свободной оси (модель Space Engineers:
signed velocity, без пружины):

```text
velocity mode (primary gameplay):
  desired_velocity = clamp(target_velocity, -retract_velocity, +extend_velocity)

position mode (API / MoveToPosition):
  desired_velocity = sign(error) * velocity_limit_for_sign(error)
  stop when |error| <= arrive_epsilon

stop mode:
  desired_velocity = 0

force =
  clamp(
    carriage_mass * (desired_velocity - observed_velocity) / response_time
    + axial_load_hold(carriage_mass, axis, gravity)
    + damping_n_s_per_m * observed_velocity,
    -force_limit,
    +force_limit
  )
```

`desired_velocity` предварительно ограничивается бюджетом силы:
`(force_limit - hold) / (damping + mass / response_time)`.

`carriage_mass` — сумма `total_mass_kg` всех элементов head body group (бур,
каркас на голове). `axial_load_hold` компенсирует вес каретки вдоль оси при
включённом motor (SE: piston не пассивный). Без питания hold не применяется.
При `applied_force >= 0.6 * force_limit` без движения статус `overloaded`, не
`stuck`.

`stiffness_n_per_m` остаётся в схеме для совместимости сейвов, но в projection
не участвует. Положительная velocity выдвигает, отрицательная втягивает,
ноль — стоп с усиленным торможением.

Для dynamic base сила применяется к base и head равными противоположными
значениями в joint anchors. Для static base — только к head. Constraint solver
удерживает остальные пять DOF. Controller не компенсирует гравитацию скрытым
образом.

Если backend предоставляет надёжную reaction force, projection публикует её как
`applied_force_n`. Иначе публикуется фактически запрошенная после clamp motor
force; overload в любом случае определяется через saturation + tracking error,
а не через недоступный private Jolt state.

### Observation

После physics step projection публикует:

- signed extension вдоль axis;
- relative axial velocity;
- applied/clamped motor force;
- saturation flag;
- body sleeping state.

Position допускает solver tolerance за limits, но state для UI clamp-ится в
authored interval. Выход дальше tolerance `0.01 m` — projection fault и test
failure, не новая topology pose.

## Status и overload

Status precedence:

1. `element_incomplete`;
2. `no_power`;
3. `overloaded`;
4. `stuck`;
5. `joint_limit`;
6. `moving`;
7. `idle`.

Definitions:

- `joint_limit`: command продолжает вести наружу, position находится в пределах
  `0.005 m` от соответствующего limit;
- `stuck`: tracking, нет осевого прогресса (speed и delta position ниже порога),
  applied force ниже `10%` force limit, в течение `0.5 s`;
- `overloaded`: tracking, нет осевого прогресса, motor force насыщена или выше
  `60%` force limit не менее `0.5 s`;
- `moving`: осевой speed выше `0.003 m/s` **или** заметный прогресс position
  между тиками;
- saturation timer сбрасывается при stop, reverse, power loss или когда error /
  velocity выходят из overload predicates.

Overload policy `stop`: motor переходит в stop/hold и выставляет status
`overloaded`; новая валидная target command снимает состояние. `fuse` и `break`
остаются допустимыми доменными policies, но не реализуются этим PoC.

## Damage, dismantle, split и rebuild

Mechanical connectivity для Assembly membership считается по всем неbroken
`Rigid` и `Piston` edges.

- удаление base или head удаляет incident Piston joint;
- разрыв Piston пересчитывает connected components полного mechanical graph;
- каждая disconnected component становится отдельной Assembly по существующей
  survivor policy;
- разрыв обычного Rigid edge может только изменить body-group partition, не
  обязательно разделить Assembly, если остаётся путь через Piston;
- если head rigid branch меняется, projection rebuild сохраняет root pose и
  observed extension без телепорта;
- новая/отделившаяся carriage Assembly получает world pose и velocity своего
  Jolt body до structural mutation;
- collider ownership остаётся по `ElementId`.

Merge двух Assembly существующей `MergeAssembliesCommand` остаётся только rigid.
Она отклоняется, если prospective rigid edge создаст driven-joint cycle.

## Snapshot v6

Текущая schema v5 повышается до v6. В joint row добавляется поле `motor`: оно
обязательно для `Kind.PISTON` и отсутствует у `Rigid`/`Anchor`. Формат остальных
полей `Rigid` и `Anchor` rows не меняется.

Snapshot хранит:

- command target/mode и enabled state;
- authored runtime limits/policy;
- observed position и axial velocity;
- status.

Не хранит:

- `body_group_id`;
- Godot nodes/RIDs;
- constraint impulses;
- saturation timer меньше одного simulation tick;
- presentation shaft transform.

Restore:

1. валидирует full mechanical connectivity и acyclic driven body graph;
2. восстанавливает root `Assembly.motion`;
3. clamp-ит observed position в limits;
4. реконструирует child body poses вдоль ordered piston paths;
5. создаёт constraints до первого physics step;
6. не выдаёт motor force до завершения projection rebuild.

## Presentation и interaction

Piston visual состоит из base, telescoping shaft и head. Shaft length и head
offset читают observed extension; visual не интегрирует собственное движение.

Target panel для piston показывает:

- current / target extension;
- speed limit;
- Extend, Retract, Stop;
- powered/enabled state;
- localized status reason.

Минимальные input actions объявляются в `project.godot`, не хардкодятся.
Управление доступно через target interaction; programmable bindings вне v1.

Каждый projected body group публикует carrier linear/angular velocity через тот
же support-frame boundary, что и другие moving `RigidBody3D`. Character controller
не содержит piston-specific ветки.

## Диагностика

Runtime inspector/log snapshot для Piston включает:

```text
assembly_id
joint_id
base_element_id
head_element_id
base_body_group_id
head_body_group_id
observed_position_m
observed_velocity_mps
target
applied_force_n
powered
enabled
status
```

Логи пишутся на transition status/fault, не каждый physics frame.

## Тесты

Чистая kernel/projection логика проверяется headless-сценой
`scenes/test_simulation_actuator.tscn`, добавленной в `tests/run_tests.sh`.

Обязательные cases:

1. atomic placement создаёт base + head + один Piston joint и корректный BOM;
2. body-group compiler даёт две группы для base/head и переносит rigid branch
   головы в carriage group;
3. snapshot v6 roundtrip сохраняет target, extension и fault;
4. position target движет нагруженную голову без прямой записи transform;
5. travel limits физически удерживаются;
6. тяжёлый/заблокированный груз приводит к `overloaded`, а не teleport;
7. power loss снимает force и даёт `no_power`;
8. dismantle base/head отделяет carriage с корректной world velocity;
9. rebuild при добавлении/удалении head branch сохраняет world pose;
10. cycle и пятый driven joint на path отклоняются;
11. rigid-only snapshot v6 и projection остаются семантически эквивалентны
    поведению до добавления Piston.

Gameplay/HUD/presentation не подтверждаются headless-тестом. В запущенной игре:

1. построить anchored base → piston → platform;
2. поднять platform с грузом;
3. заблокировать ход препятствием и увидеть overload;
4. отключить питание и увидеть остановку/no_power;
5. встать на platform и выполнить полный extend/retract;
6. проверить screenshot, remote tree и отсутствие ошибок в game logs;
7. получить финальное подтверждение человека в игре.

## Acceptance

PoC принят, когда:

1. поршень создаёт два реальных physics bodies и force-limited constraint;
2. attached rigid-конструкция движется вместе с head и сохраняет collision/mass;
3. препятствие может физически остановить поршень;
4. limits, no power, stuck и overload наблюдаемы и детерминированно
   диагностируются;
5. damage/dismantle корректно отделяет carriage без teleport или stale colliders;
6. snapshot/restore не меняет topology, target и observed extension;
7. игрок устойчиво стоит на moving piston platform;
8. `./tests/run_one.sh test_simulation_actuator` зелёный;
9. полный `./tests/run_tests.sh` зелёный;
10. gameplay-проверка в запущенной игре и подтверждение человека выполнены.
