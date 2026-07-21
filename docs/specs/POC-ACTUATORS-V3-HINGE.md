# Actuators v3 — Hinge (ServoHinge) PoC

Статус: implementation contract третьего post-slice actuator.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md`;
- `docs/specs/POC-ACTUATORS-V1.md` (Piston — базовая механика driven joints);
- `docs/specs/POC-ACTUATORS-V2-ROTOR.md` (Rotor — угловой driven joint);
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/CONSTRUCTION-V1.md`;
- `docs/specs/INDUSTRY-V1.md`.

## Цель

Добавить `Hinge` — приводной joint сгибания с угловыми упорами (аналог
hinge Space Engineers, `ServoHinge` из `PHYSICAL-LANGUAGE.md`) в языке
Assembly:

- игрок ставит один hinge construction item;
- к hinge top крепятся обычные элементы и rigid-конструкции;
- top и всё прикреплённое к нему сгибается вокруг оси, **перпендикулярной**
  направлению установки (в отличие от rotor, который крутится вокруг неё);
- ход ограничен угловыми упорами (authored bounds ±90°, настраиваемые
  min/max в их пределах);
- мотор достигает целевой угловой скорости/угла только через ограниченный
  момент; упоры — жёсткие constraint-limits в Jolt;
- масса, инерция груза, контакты, препятствия и упоры реально влияют на
  движение; `joint_limit`, stall и overload наблюдаемы в authoritative
  state и HUD.

Это реализация приводного вида `ServoHinge` из `PHYSICAL-LANGUAGE.md` на
механике driven joints Actuators v1/v2. Новая параллельная модель не
вводится.

## Нормативные решения

1. Hinge повторяет все нормативные решения Rotor v2 (multi-body Assembly,
   body groups по `Rigid`-подграфу, атомарный placement, Jolt владеет
   динамикой, torque-limited velocity tracker). Ниже — только отличия.
2. Hinge construction item материализуется как `hinge_base` + `hinge_top`,
   соединённые `Hinge` joint. Home pose: top в соседней cell вдоль authored
   `axis_face` base (mount-направление), `orientation_index` общий.
3. Ось вращения — authored `bend_axis_face` base (обязана быть
   перпендикулярна `axis_face`); world axis выводится из orientation base.
   Positive angle — правый винт вокруг bend axis.
4. Pivot вращения — **центр клетки `hinge_top`**: hub top вращается на
   месте (постоянный клиренс с base hub), навешенная конструкция качается
   вокруг оси. Это отличается от rotor (pivot на стыке): у hinge стык не
   лежит на оси вращения.
5. Вращение НЕ непрерывно (`continuous = false`): travel limits активны,
   observed angle клампится в `[lower, upper]`, wrap отсутствует. Статус
   `joint_limit` достижим (механика Piston v1).
6. `MotorState` переиспользуется с `angular = true`, `continuous = false`;
   `lower/upper_limit_m` читаются как min/max angle rad. Остальные angular
   поля — как у Rotor v2.
7. Topology хранит hinge в home angle `0`. Сгибание не меняет
   `origin_cell`, occupancy или `GridTransform`; это continuous joint
   state.

## Границы

### Входит

- один новый тип driven joint: `Hinge`;
- velocity (bend+ / bend−), position (целевой угол в пределах limits)
  и stop control modes;
- настраиваемые min/max angle limits в пределах authored bounds;
- жёсткие constraint-упоры в Jolt + статус `joint_limit`;
- torque/speed limits, electric on/off budget;
- `stuck`, `overloaded`, `no_power`, `element_incomplete`;
- overload policy `stop`;
- snapshot/restore (schema v8);
- damage, dismantle и split вокруг hinge;
- блоки и платформы на hinge top; смешанные цепи piston+rotor+hinge в
  общем acyclic-лимите (4).

### Не входит

- lock/brake сверх stop mode;
- FreeHinge (пассивная дверь без мотора);
- gear ratio, передача mechanical_power через Network;
- merge двух Assembly через Hinge;
- overload policies `fuse` и `break`;
- programmable bindings, автоматика.

## Authoring

### Hinge definition

`ElementArchetype` с ролью `Actuator` может иметь typed `HingeDefinition`
(только у `hinge_base`):

```text
HingeDefinition {
  top_archetype_id
  axis_face                # mount-направление: top origin = base origin + axis_face * N cells
  top_offset_cells
  bend_axis_face           # ось сгибания, перпендикулярна axis_face
  min_angle_rad            # authored hard bound (fixture −π/2)
  max_angle_rad            # authored hard bound (fixture +π/2)
  default_speed_limit_rad_s
  forward_velocity_rad_s
  reverse_velocity_rad_s
  torque_limit_nm
  max_velocity_rad_s
  max_torque_limit_nm
  damping_nm_s_per_rad     # STOP braking (N·m·s/rad)
  power_draw_w
  overload_policy
}
```

Validator отклоняет definition, если:

- top archetype отсутствует или player-placeable (не internal);
- `bend_axis_face` не перпендикулярна `axis_face`;
- `min_angle_rad >= max_angle_rad`, либо bounds выходят за `(−π, π)`,
  либо home angle `0` вне `[min, max]`;
- velocity/torque/damping/power draw отрицательны либо torque limit
  или max-значения не положительны;
- overload policy отличается от `stop`;
- у base нет ровно одного internal mechanical port `hinge_drive`;
- у top нет ровно одного сопряжённого internal port `hinge_top`;
- top не предоставляет structural mount pads;
- home footprints base и top пересекаются.

### Slice fixture

```text
construction item       hinge
base archetype          hinge_base
top archetype           hinge_top
home footprint          2 cells вдоль local +Y: base, затем top
bend axis               local +X
angle bounds            −π/2 … +π/2 (±90°)
default speed limit     0.5 rad/s
forward / reverse       1.0 rad/s / 1.0 rad/s
torque limit            3000 N·m
max velocity            2.0 rad/s
max torque limit        20000 N·m
damping                 50 N·m·s/rad
power draw              800 W while commanded
overload policy         stop
```

Числа — initial tuning fixture. `hinge_top` — internal archetype (как
`rotor_top`). Hub-коллайдеры: base BOX 0.4, top BOX 0.35 — top hub,
вращаясь на месте вокруг своего центра, не задевает base hub во всём
диапазоне ±90° (полудиагональ 0.247 < зазор 0.30 между центром top и
верхней гранью base hub).

## Topology и identity

Atomic placement идентичен Rotor v2 (одна structural transaction, общий
BOM на base+top, никаких `Rigid` между base и top в home pose).

Joint endpoint contract:

```text
element_a_id / port_a_id = hinge_base / hinge_drive
element_b_id / port_b_id = hinge_top  / hinge_top
```

`SimulationJoint.Kind.HINGE` хранит тот же `MotorState`, что Piston/Rotor,
с `angular = true`, `continuous = false`. Angular поля MotorState:

```text
target_position_m      → target_angle_rad (кламп в [lower, upper])
target_velocity_mps    → target_velocity_rad_s
extend/retract_velocity → bend+ / bend− velocity rad/s
force_limit_n          → torque_limit_nm
lower/upper_limit_m    → min/max angle rad (настраиваемые)
observed_position_m    → observed_angle_rad, clamp [lower, upper]
observed_velocity_mps  → observed_velocity_rad_s
applied_force_n        → applied_torque_nm
```

Body groups, root policy, acyclic-валидация — Piston v1 без изменений;
`Hinge` входит в общий driven-joint граф и `driven_joint_cycle`.

## Construction rules

Обычные элементы крепятся к `hinge_top` через существующие structural
surface rules и становятся частью top body group.

Construction target на hinge top branch разрешён в idle: observed velocity
ниже `0.01 rad/s`. Home angle не требуется — preview/weld используют live
body-group frame. Пока шарнир движется — `moving_target_not_supported`.

Нельзя создать `Rigid` edge, замыкающий mechanical cycle через Hinge:
`driven_joint_cycle` (общая проверка с Piston/Rotor).

## Control command

`set_actuator_target` — тот же command, что у Piston/Rotor:

- `velocity`: target clamp в `[-reverse_velocity, +forward_velocity]`
  (bend+ / bend−); у упора момент продолжает давить в constraint,
  статус — `joint_limit`;
- `position`: целевой угол clamp в `[lower, upper]`; error — простая
  разность (без wrap), движение с authored velocity по знаку error до
  arrive epsilon `0.005 rad`;
- `stop`: target velocity 0, усиленное торможение вокруг оси;
- `enabled = false`: момент 0, constraint и упоры остаются.

`configure_actuator` для hinge меняет forward/reverse velocity
(clamp `[0, max_velocity_rad_s]`), torque limit
(clamp `[1, max_torque_limit_nm]`) и min/max angle limits:

- значения снапятся к 1° и клампятся в authored
  `[min_angle_rad, max_angle_rad]`;
- `upper ≤ lower` отклоняется;
- angle limits могут быть отрицательными, поэтому команда несёт явные
  флаги `lower_limit_set` / `upper_limit_set` (сентинел `-1` Piston v1
  для углов непригоден);
- после изменения limits target и observed переклампываются.

## Power

`hinge_base` имеет electric `power_in` и участвует в Industry v1 budget
как consumer по правилам Rotor v2: demand = `power_draw_w`, пока motor
enabled и mode ≠ stop; `no_power` даёт момент 0, constraint и упоры
остаются.

## Physics projection

### Compilation

На каждый `Hinge` создаётся `Generic6DOFJoint3D` с origin в pivot (центр
клетки `hinge_top`) и **local X вдоль bend axis** (twist-ось Jolt —
асимметричные limits поддерживаются):

- все три linear DOF заблокированы;
- angular Y/Z заблокированы;
- angular X ограничен motor limits, **сдвинутыми на `angle_offset`** и
  записанными в Godot CW API: sim/motor angles — правый винт (CCW), а
  `Generic6DOFJoint3D` angular limits/motor — CW (движок снова flip'ает
  в Jolt CCW). Поэтому в joint пишется
  `godot_limit = (−(rh_upper−offset), −(rh_lower−offset))`, а
  `angular_motor` target velocity = `−rh_velocity`. Offset — RH measured
  angle at create; хранится в projection record на lifetime constraint;
  при recreate (snapshot restore / bent reproject) пересчитывается.
  На тике обновляются только twist lower/upper (не полный reset DOF);
- soft stop params на twist (`softness` / `damping`) — fixture против
  solver explosion при упоре; статус `joint_limit` сохраняется;
- base и top body groups сталкиваются в Jolt (нет group-wide exception);
  kinetic ignore только для пары hub endpoints (см. KINETIC-INTERACTION);
  навешенные фреймы бьют корпус на общих правах.

### Motor

Torque-limited velocity tracker через Jolt `Generic6DOFJoint3D`
`angular_motor` на twist (local X). Для non-continuous hinge
`RotorProjectionUtil.solver_angular_drive` применяет near-limit taper:
в `LIMIT_TAPER_RAD` к упору в направлении команды `force_limit` мотора
плавно гасится до 0 (и target velocity обнуляется на самом упоре), чтобы
не драться с жёстким Jolt-stop на полном `torque_limit`. Taper считает
home-relative measured angle текущего тика. Position mode использует
некруговой position_error (clamp, не wrap). Гравитационная компенсация
не применяется: несбалансированный груз честно провисает в пределах
torque limit и упоров.

Nested chains: ось/сила piston на тике берётся из **base body group**
(не из root assembly transform), иначе после сгиба hinge сила орёт в
slider constraint. Реконструкция child group motions — parent-before-child
по driven graph (не по `joint_id`).

### Observation

После physics step projection публикует:

- signed angle base↔top вокруг bend axis (из relative rotation,
  clamp `[lower, upper]` при синке);
- relative angular velocity вокруг оси;
- applied/clamped torque и saturation flag.

Реконструкция top group (split/restore/element_world_transform) — поворот
вокруг pivot-оси на observed angle (механика Rotor v2 с другой осью и
pivot).

## Status и overload

Полный precedence Piston v1, включая `joint_limit`:
`element_incomplete → no_power → overloaded → stuck → joint_limit → moving → idle`.

Пороговые константы MotorState в угловых единицах (0.02 rad error,
0.003 rad/s velocity, 0.5 s saturation, limit epsilon 0.005 rad).
Overload policy `stop` — как в v1.

## Snapshot v8

Schema v7 повышается до v8: joint row `Kind.HINGE` обязана содержать
`motor` (angular, не continuous, лимиты активны); формат
`Rigid`/`Anchor`/`Piston`/`Rotor` rows не меняется. Restore клампит
observed angle в limits и реконструирует top group pose поворотом вокруг
pivot-оси на observed angle.

## Presentation и interaction

Hinge top — отдельное physics body: element-визуалы top branch
поворачиваются вместе с телом. Placement preview показывает base+top.
Target panel: observed angle (градусы), min/max, статус, bend+ / bend− /
stop через те же target-interaction actions, что у rotor
(actuator_extend / actuator_retract / actuator_stop).

**E** на прицеленном hinge открывает ту же центральную панель настроек,
что у piston/rotor, с hinge-набором строк:

- ВПЕР / НАЗАД — forward/reverse velocity, шаг `0.1 rad/s`,
  clamp `[0, max_velocity_rad_s]`;
- МОМЕНТ — torque limit, шаг `1000 N·m`, clamp `[1, max_torque_limit_nm]`;
- МИН / МАКС — angle limits, шаг `5°`, clamp в authored bounds,
  `МИН ≤ МАКС − 5°`.

Панель шлёт тот же `configure_actuator`; readout — угол в градусах и
целевая скорость.

## Диагностика

Runtime snapshot Hinge повторяет Rotor (assembly/joint/base/top ids,
observed angle и velocity, target, applied torque, limits, powered,
enabled, status). Логи — на transition, не каждый frame.

## Тесты

Кейсы добавляются в headless-сцену `scenes/test_simulation_actuator.tscn`
(гейт уже включает её):

1. atomic placement создаёт base + top + один Hinge joint (angular,
   не continuous, limits ±π/2) и корректный BOM;
2. body-group compiler даёт отдельную top group; реконструкция поворачивает
   навес вокруг pivot-оси (центр top не смещается, навес на +Y качается);
3. snapshot v8 roundtrip сохраняет target, angle, limits и fault;
   piston/rotor-only snapshot остаётся семантически эквивалентным;
4. set_actuator_target (velocity/position clamp в limits) и
   configure_actuator применяются; отрицательный min angle проходит через
   `lower_limit_set`; `upper ≤ lower` отклоняется;
5. велосити-команда в сторону упора даёт статус `joint_limit`
   (не overload);
6. насыщение момента без прогресса вне упора даёт `overloaded`,
   power loss — `no_power`;
7. dismantle base/top отделяет top branch отдельной Assembly;
8. construction на движущемся top отклоняется
   `moving_target_not_supported`; idle согнутый top — разрешён.

Gameplay/HUD/презентация верифицируются в запущенной игре человеком
(построить стрелу на hinge, согнуть до упора, увидеть joint_limit;
перегрузить; отключить питание).

## Acceptance

PoC принят, когда:

1. hinge создаёт два physics bodies и torque-limited constraint с
   угловыми упорами;
2. attached rigid-конструкция качается вместе с top вокруг перпендикулярной
   оси;
3. упор физически останавливает движение со статусом `joint_limit`;
4. препятствие/перегрузка физически останавливает движение с диагнозом;
5. no power, stuck и overload наблюдаемы;
6. dismantle корректно отделяет top branch без телепорта;
7. snapshot/restore не меняет topology, target, limits и observed angle;
8. `./tests/run_one.sh test_simulation_actuator` зелёный;
9. полный `./tests/run_tests.sh` зелёный;
10. gameplay-проверка в запущенной игре и подтверждение человека выполнены.
