# Actuators v2 — Rotor PoC

Статус: implementation contract второго post-slice actuator.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md`;
- `docs/specs/POC-ACTUATORS-V1.md` (Piston — базовая механика driven joints);
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/CONSTRUCTION-V1.md`;
- `docs/specs/INDUSTRY-V1.md`.

## Цель

Добавить `Rotor` — приводной joint непрерывного вращения (аналог ротора
Space Engineers) — в языке Assembly:

- игрок ставит один rotor construction item;
- к rotor top крепятся обычные элементы и rigid-конструкции;
- top и всё прикреплённое к нему вращаются как отдельное Jolt body;
- мотор достигает целевой угловой скорости только через ограниченный момент,
  а не через прямую запись transform;
- масса, инерция груза, контакты и препятствия реально влияют на вращение;
- stall и overload наблюдаемы в authoritative state и HUD.

Это реализация уже определённого в `PHYSICAL-LANGUAGE.md` приводного вида
`Rotor` («непрерывное вращение») на механике driven joints Actuators v1.
Новая параллельная модель не вводится.

## Нормативные решения

1. Rotor повторяет все нормативные решения Piston v1 (multi-body Assembly,
   body groups по `Rigid`-подграфу, атомарный placement, Jolt владеет
   динамикой, только силовой dynamic solver). Ниже — только отличия.
2. Rotor construction item материализуется как `rotor_base` + `rotor_top`,
   соединённые `Rotor` joint. Home pose: top в соседней cell вдоль authored
   `axis_face` base, `orientation_index` общий.
3. Единицы мотора — угловые СИ: угол в радианах, скорость в рад/с, момент
   в Н·м. `MotorState` переиспользуется с `angular = true`; поля
   `*_m`/`*_mps`/`*_n` читаются как rad/rad·s⁻¹/N·m.
4. Вращение непрерывно (`continuous = true`): travel limits отсутствуют,
   observed angle публикуется wrapped в `(-π, π]`. Статус `joint_limit`
   недостижим в v1.
5. Полный mechanical graph (`Rigid` + `Piston` + `Rotor`) определяет
   membership Assembly; driven-graph body groups обязан быть acyclic,
   piston и rotor считаются в одном графе и одном лимите цепи (4).
6. Topology хранит rotor в home angle `0`. Вращение не меняет `origin_cell`,
   occupancy или `GridTransform`; это continuous joint state.

## Границы

### Входит

- один новый тип driven joint: `Rotor`;
- velocity (primary), position (кратчайший путь к углу) и stop control modes;
- torque/speed limits, electric on/off budget;
- `stuck`, `overloaded`, `no_power`, `element_incomplete`;
- overload policy `stop`;
- snapshot/restore (schema v7);
- damage, dismantle и split вокруг rotor;
- блоки и платформы на rotor top; смешанные цепи piston+rotor в общем
  acyclic-лимите.

### Не входит

- angle limits и lock/brake сверх stop mode (ServoHinge — отдельный PoC);
- rotor displacement/offset;
- gear ratio, передача mechanical_power через Network;
- merge двух Assembly через Rotor;
- overload policies `fuse` и `break`;
- programmable bindings, автоматика.

## Authoring

### Rotor definition

`ElementArchetype` с ролью `Actuator` может иметь typed `RotorDefinition`
(только у `rotor_base`):

```text
RotorDefinition {
  top_archetype_id
  axis_face
  top_offset_cells         # home pose: top origin = base origin + axis_face * N cells
  default_speed_limit_rad_s
  forward_velocity_rad_s
  reverse_velocity_rad_s
  torque_limit_nm
  max_velocity_rad_s
  max_torque_limit_nm
  damping_nm_s_per_rad   # STOP braking (N·m·s/rad), not cruise feedforward
  power_draw_w
  overload_policy
}
```

Validator отклоняет definition, если:

- top archetype отсутствует или player-placeable (не internal);
- velocity/torque/damping/power draw отрицательны либо torque limit
  или max-значения не положительны;
- overload policy отличается от `stop`;
- у base нет ровно одного internal mechanical port `rotor_drive`;
- у top нет ровно одного сопряжённого internal port `rotor_top`;
- top не предоставляет structural mount pads;
- home footprints base и top пересекаются.

### Slice fixture

```text
construction item       rotor
base archetype          rotor_base
top archetype           rotor_top
home footprint          2 cells вдоль local +Y: base, затем top
default speed limit     0.5 rad/s
forward / reverse       1.0 rad/s / 1.0 rad/s
torque limit            3000 N·m
max velocity            3.14 rad/s
max torque limit        20000 N·m
power draw              800 W while commanded
overload policy         stop
```

Числа — initial tuning fixture. `rotor_top` — internal archetype
(как `piston_head`): свой `ElementId`, mass, integrity, colliders, но не
отдельный toolbar item.

### Large rotor fixture

```text
construction item       rotor (large)
base archetype          rotor_base_large
top archetype           rotor_top_large
base collider           CYLINDER Ø2.5 × H2.0 m (axis local +Y)
top collider            BOX 2.5 × 0.5 × 2.5 m
stack height            2.5 m (base 2.0 + head 0.5)
top_offset_cells        4 (base footprint 5×4×5, top 5×1×5)
default speed limit     2.5 rad/s
forward / reverse       5.0 rad/s / 5.0 rad/s
torque limit            15000 N·m
max velocity            15.7 rad/s
max torque limit        100000 N·m
damping                 250 N·m·s/rad
power draw              4000 W while commanded
overload policy         stop
```

`ColliderDefinition.ShapeKind.CYLINDER`: `size.x` = diameter, `size.y` = height,
`size.z` = diameter (authoring symmetry). Ось цилиндра — local +Y (Godot default).

## Topology и identity

Atomic placement идентичен Piston v1 (одна structural transaction, общий BOM
на base+top, никаких `Rigid` между base и top в home pose).

Joint endpoint contract:

```text
element_a_id / port_a_id = rotor_base / rotor_drive
element_b_id / port_b_id = rotor_top  / rotor_top
```

Направление A → B значимо. Positive angular velocity — правый винт вокруг
authored `axis_face` base (world axis выводится из orientation base).

`SimulationJoint.Kind.ROTOR` хранит тот же `MotorState`, что и Piston, с
`angular = true`, `continuous = true`. Angular поля MotorState читаются как:

```text
target_position_m      → target_angle_rad
target_velocity_mps    → target_velocity_rad_s
extend/retract_velocity → forward/reverse velocity rad/s
force_limit_n          → torque_limit_nm
lower/upper_limit_m    → не используются (continuous)
observed_position_m    → observed_angle_rad, wrapped (-π, π]
observed_velocity_mps  → observed_velocity_rad_s
applied_force_n        → applied_torque_nm
```

Body groups, root policy, acyclic-валидация — Piston v1 без изменений;
`Rotor` входит в тот же driven-joint граф и `driven_joint_cycle`.

## Construction rules

Обычные элементы крепятся к `rotor_top` через существующие structural
surface rules и становятся частью top body group.

Construction target на rotor top branch разрешён только когда rotor в home
angle: `|wrap(observed_angle)| ≤ 0.02 rad`, observed velocity ниже
`0.01 rad/s`, snap использует home grid pose. Иначе
`moving_target_not_supported`. Повёрнутый top не округляется обратно в grid.

Нельзя создать `Rigid` edge, замыкающий mechanical cycle через Rotor:
`driven_joint_cycle` (общая проверка с Piston).

## Control command

`set_actuator_target` — тот же command, что у Piston:

- `velocity`: target clamp в `[-reverse_velocity, +forward_velocity]`;
  primary gameplay mode (spin+ / spin− как у ротора Space Engineers);
- `position`: целевой угол; error — кратчайший путь
  `wrap(target - observed)`, движение с authored velocity по знаку error до
  arrive epsilon `0.005 rad`;
- `stop`: target velocity 0, усиленное торможение вокруг оси;
- `enabled = false`: момент 0, constraint остаётся.

`configure_actuator` для rotor меняет forward/reverse velocity
(clamp `[0, max_velocity_rad_s]`) и torque limit
(clamp `[1, max_torque_limit_nm]`); поля travel limits для continuous rotor
игнорируются как «unchanged».

## Power

`rotor_base` имеет electric `power_in` и участвует в Industry v1 budget как
consumer по правилам Piston v1: demand = `power_draw_w`, пока motor enabled
и mode ≠ stop; `no_power` даёт момент 0, constraint остаётся.

## Physics projection

### Compilation

Дополнение к multibody-компиляции Piston v1: на каждый `Rotor` создаётся
`Generic6DOFJoint3D` в anchor `rotor_drive`:

- все три linear DOF заблокированы;
- angular X/Z заблокированы;
- angular Y (ось ротора) свободен — непрерывное вращение без limits;
- base и top **body groups сталкиваются** в Jolt (нет group-wide exception);
  clearance стыка — authored меньший box collider у `rotor_base` /
  `rotor_top` (0.4 m при cell 0.5);
  kinetic ignore только для пары hub endpoints (см. KINETIC-INTERACTION);
  навешенные фреймы бьют корпус на общих правах.

### Motor

Torque-limited velocity tracker вокруг свободной оси (модель ротора SE:
signed velocity, без пружины). Канал — `RigidBody3D.apply_torque` (world
space); joint `angular_motor_*` не используется. Jolt владеет интеграцией
позы/ω; `custom_integrator` на actuator bodies запрещён (иначе torque
молча дропается).

```text
desired_velocity = по mode (velocity/position/stop), рад/с
  # лимиты скорости — только authored forward/reverse / mode logic

I_top  = 1 / (axis · (I⁻¹_top · axis))
I_base = ∞ если base static/frozen, иначе 1 / (axis · (I⁻¹_base · axis))
I_eff  = 1 / (1/I_top + 1/I_base)

tau_track = I_eff * (desired_velocity - observed_velocity) / response_time
tau_brake = -damping_nm_s_per_rad * observed_velocity
            только в ControlMode.STOP
            (response_time усилен STOP_BRAKE_DAMPING_SCALE)

torque = clamp(tau_track + tau_brake, ±torque_limit_nm)
```

`damping_nm_s_per_rad` — braking torque в STOP (аналог SE Braking Torque),
не cruise-feedforward. Гравитационная компенсация не применяется:
несбалансированный груз честно проседает в пределах torque limit.

Момент прикладывается к top (+axis·τ) и к unfrozen dynamic base (−axis·τ);
для static/frozen base — только к top. Motor никогда не пишет transform или
angular velocity.

### Observation

После physics step projection публикует:

- signed angle base↔top вокруг оси (из relative rotation, wrapped);
- relative angular velocity вокруг оси;
- applied/clamped torque и saturation flag.

## Status и overload

Precedence Piston v1 без `joint_limit`:
`element_incomplete → no_power → overloaded → stuck → moving → idle`.

Пороговые константы MotorState переиспользуются в угловых единицах
(0.02 rad error, 0.003 rad/s velocity, 0.5 s saturation). Progress статуса
считается по wrapped-разности углов. Overload policy `stop` — как в v1.

## Snapshot v7

Schema v6 повышается до v7: joint row `Kind.ROTOR` обязана содержать `motor`
(c `angular`/`continuous` флагами); формат `Rigid`/`Anchor`/`Piston` rows не
меняется. Restore клампит/wrap-ит observed angle и реконструирует top group
pose поворотом вокруг anchor оси на observed angle.

## Presentation и interaction

Rotor top — отдельное physics body: element-визуалы top branch вращаются
вместе с телом без специального visual-скрипта. Placement preview показывает
base+top. Target panel: observed angle (градусы), статус, spin+ / spin− /
stop через те же target-interaction actions, что extend/retract/stop
поршня.

**E** на прицеленном роторе открывает ту же центральную панель настроек,
что у поршня, с ротор-набором строк:

- ВПЕР / НАЗАД — forward/reverse velocity, шаг `0.1 rad/s`,
  clamp `[0, max_velocity_rad_s]`;
- МОМЕНТ — torque limit, шаг `1000 N·m`, clamp `[1, max_torque_limit_nm]`;
- строки travel limits отсутствуют (continuous).

Панель шлёт тот же `configure_actuator` (поля extend/retract/force читаются
kernel'ом как angular); readout — угол в градусах и целевая скорость.

## Диагностика

Runtime snapshot Rotor повторяет Piston (assembly/joint/base/top ids,
observed angle и velocity, target, applied torque, powered, enabled,
status). Логи — на transition, не каждый frame.

## Тесты

Кейсы добавляются в headless-сцену `scenes/test_simulation_actuator.tscn`
(гейт уже включает её):

1. atomic placement создаёт base + top + один Rotor joint и корректный BOM;
2. body-group compiler даёт отдельную top group и переносит rigid branch
   top в неё; piston+rotor цепь остаётся валидной, цикл отклоняется;
3. snapshot v7 roundtrip сохраняет target, angle и fault; rigid/piston-only
   snapshot остаётся семантически эквивалентным;
4. set_actuator_target (velocity/position) и configure_actuator применяются,
   travel-поля игнорируются;
5. wrapped angle: observed за π корректно wrap-ится, progress статуса не
   ломается на переходе через ±π;
6. насыщение момента без прогресса даёт `overloaded`, power loss —
   `no_power`;
7. dismantle base/top отделяет top branch отдельной Assembly;
8. construction на повёрнутом top отклоняется
   `moving_target_not_supported`.

Gameplay/HUD/презентация верифицируются в запущенной игре человеком
(построить башню на роторе, раскрутить, остановить препятствием, увидеть
overload; отключить питание).

## Acceptance

PoC принят, когда:

1. rotor создаёт два physics bodies и torque-limited hinge constraint;
2. attached rigid-конструкция вращается вместе с top;
3. препятствие/перегрузка физически останавливает вращение с диагнозом;
4. no power, stuck и overload наблюдаемы;
5. dismantle корректно отделяет top branch без телепорта;
6. snapshot/restore не меняет topology, target и observed angle;
7. `./tests/run_one.sh test_simulation_actuator` зелёный;
8. полный `./tests/run_tests.sh` зелёный;
9. gameplay-проверка в запущенной игре и подтверждение человека выполнены.
