# Rover Modules v1 — Suspension, Wheel, Cockpit, Small Power

Статус: implementation contract для строительных модулей ровера и первого
полностью player-built управляемого шасси.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` («Примитивы» → «Wheel», «Actuator», «ControlSeat
  и Binding», «Network, Flow и Store»; «Граница владения»);
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/CONSTRUCTION-V1.md`;
- `docs/specs/INDUSTRY-V1.md` (electric budget, distributor radius);
- `docs/specs/POC-ACTUATORS-V1.md` (паттерн actuator: command → motor state →
  projection tick → power gate → presentation);
- `docs/specs/KINETIC-INTERACTION-V1.md` (Jolt force-application без
  `custom_integrator`, subgrid immunity);
- `docs/specs/POC-3-PASSENGER.md` (collision layers, moving-platform passenger).

## Цель

Дать игроку построить управляемый ровер из отдельных placeable блоков, не из
baked blueprint:

- рама (`frame`, стандартный 0.5 m каркас) как шасси;
- подвеска (`wheel_suspension`) крепится к раме и несёт raycast-модель хода;
- колесо (`drive_wheel`) крепится **только** к подвеске и даёт drive/brake/steer;
- кокпит (`cockpit`, роль `ControlSeat`) — точка управления;
- малые энергоблоки (`power_battery_small`, `power_distributor_small`) под
  габарит ровера;
- полный цикл: построить на земле → сесть в кокпит (`E`) → ехать WASD → выйти.

Это композиция уже определённых в `PHYSICAL-LANGUAGE.md` понятий `Wheel`,
`Support`, `Actuator`, `ControlSeat`, `Network`. Новая параллельная модель
техники не вводится: тот же kernel, те же structural/frequent команды, тот же
electric budget, что у Industry v1.

## Нормативные решения

1. **Колесо и подвеска — два отдельных элемента**, не monolithic `motor_wheel`.
   Соответствует `PHYSICAL-LANGUAGE.md` § Wheel: «отдельный Suspension нужен,
   когда колесо — отдельный физический блок».
2. **Связь подвеска↔колесо — обычный `Rigid` joint** через typed socket, а не
   driven joint. `Rotor`/`Suspension`/`ServoHinge` остаются отложенными
   (POC-ACTUATORS v1 § «Не входит»).
3. **Подвеска — raycast-модель**, а не отдельное Jolt-тело: ход, пружина и
   демпфер вычисляются силами на assembly body в точке крепления. Колесо не
   является катящимся `CylinderShape3D`.
4. Symulation владеет topology, per-instance настройками, drive/steer командой и
   status. Jolt владеет позами, скоростями, контактами.
5. **Locomotive assembly** — та, что содержит хотя бы одну complete
   `WheelPair` (подвеска + прикреплённое колесо). Пока игрок строит её на
   terrain/static якоре, assembly `frozen` (подпорка). Установка первого
   колеса не отпускает недостроенное шасси с якорем. После отпила якоря
   floating locomotive — всегда dynamic `RigidBody3D` (без freeze); держит
   `parking_brake` (лок колёс). `ControlSeat` включает routing / drive, не
   «отпускает freeze».
6. Строительство ровера ведётся на земле. Floating locomotive можно расширять
   при почти нулевой скорости (`|v|` / `|ω|` ниже порога). На ходу attach
   запрещён (`mobile_construction_not_supported`).
7. Управление в v1 — hardcoded mapping «кокпит владеет всеми колёсами своей
   assembly» (SE-подобный control block). Programmable `Binding` UI вне v1.
8. Число `WheelPair` не ограничено и не кодируется в типе машины. Четыре колеса
   demo-ровера — fixture, а не контракт. Physics tick обязан быть
   детерминированным `O(N)` по отсортированным `suspension_element_id`.
9. Каждая `WheelPair` принадлежит body group своей подвески. В single-body
   assembly это корневой body; в assembly с `Piston` это может быть base или
   carriage body. Raycast, силы и presentation используют один и тот же body,
   полученный через element projection.
10. Physics boundary публикует один `WheelRuntimeSnapshot` на пару. Jolt tick —
    единственный писатель; presentation, HUD и диагностика только читают
    snapshot и не пересчитывают геометрию колеса.

## Границы

### Входит

- шасси на стандартном `frame` + modules: `wheel_suspension`, `drive_wheel`, `cockpit`,
  `power_battery_small`, `power_distributor_small`;
- косметика композера из существующих 0.5 m Frame-блоков (`frame_basalt` бамперы/юбки,
  короткая мачта `frame` + `cargo_pipe`) — без новых element types;
- typed socket `wheel_socket`/`wheel_plug` и placement-валидация;
- `WheelPair` discovery, drive/brake/steer, raycast suspension;
- per-instance настройки подвески и колеса (`configure_suspension`,
  `configure_wheel`), включая переключаемый `steerable`;
- locomotive compile override (dynamic body при anchor);
- electric on/off budget: `drive_wheel` — consumer, без питания torque = 0;
- cockpit `ControlSeat`: enter/exit, WASD routing, `parking_brake` (P),
  passenger support;
- читаемый визуал ориентации (preview gizmos + асимметричные меши + runtime
  вращение колеса);
- snapshot/restore per-instance настроек и `steerable`;
- dismantle колеса/подвески с корректным пересчётом locomotive-состояния;
- headless-тесты чистой логики + in-game верификация вождения и визуала.

### Не входит

- driven `Suspension`/`Rotor` joint, hinge-body рулевого управления;
- отдельный `RigidBody3D` на каждое колесо;
- Godot `VehicleBody3D`;
- mechanical power shafts / gearbox (Network `mechanical_power` абстрактен и не
  используется колёсами в v1);
- physically-accurate электрическая энергия (Industry остаётся on/off budget);
- suspension damage-animation, отрыв колеса на ходу как отдельный эффект
  (dismantle — да, спец-анимации — нет);
- autopilot, programmable bindings, sequencing;
- строительство/расширение ровера из активного кокпита (на ходу).

## Archetypes

Все новые модули кладутся в общую grid **0.5 m** (аналог **small grid** Space
Engineers). Footprint — multi-cell, как у production-блоков; один box-collider
может покрывать несколько cells (`CONSTRUCTION-V1` § «Масштаб production
archetypes»).

| `archetype_id` | SE-аналог (small grid) | Footprint cells | Физический габарит |
|---|---|---:|---:|
| `frame` (шасси) | Light Armor Block | 1×1×1 | 0.5×0.5×0.5 m |
| `wheel_suspension` | Suspension strut | 1×2×1 | 0.5×1×0.5 m |
| `drive_wheel` | Wheel | 1×1×1 | 0.5×0.5×0.5 m |
| `cockpit` | Cockpit / control seat | 3×2×2 | 1.5×1×1 m |
| `power_battery_small` | Battery | 2×3×2 | 1×1.5×1 m |
| `power_distributor_small` | Power hub cube | 2×2×2 | 1×1×1 m |

Кладутся в
`resources/archetypes/slice01/` (ограничение
`WorldCommandGateway._get_archetype()` — player construction грузит только
`Slice01Archetypes`).

| `archetype_id` | Роли | Definition | Настраивается игроком |
|---|---|---|---|
| `frame` (шасси) | `Frame` | — | — |
| `wheel_suspension` | `Support` | `SuspensionDefinition` | ход, жёсткость, демпфер |
| `drive_wheel` | `Support`, `Actuator` | `WheelDefinition` | момент, тормоз, grip, `steerable` |
| `cockpit` | `ControlSeat`, `Frame` | seat offset | — |
| `power_battery_small` | `Tank` | — (electric fixture) | — |
| `power_distributor_small` | `Hub` | — (electric fixture) | — |

Шасси ровера — тот же slice01 `frame`, что и строительный каркас (общий
visual / cost / mass).

### SuspensionDefinition

```text
SuspensionDefinition {
  wheel_socket_face          # default NEG_Y (гнездо смотрит вниз)
  suspension_travel_m        # длина хода (rest length)
  spring_stiffness_n_per_m
  spring_damping_n_s_per_m
  max_suspension_force_n     # конечный bump/solver guard
  min_travel_m / max_travel_m  # допустимый диапазон configure
  max_wheels_per_socket = 1
}
```

- `wheel_socket_face` проходит через `OrientationUtil`; мировая грань берётся из
  orientation элемента, а не из presentation node.
- Начальные fixture-значения:
  `suspension_travel_m = 0.6`, `spring_stiffness = 1600`, `spring_damping = 400`.
  Это initial tuning, а не kernel-константы.

### WheelDefinition

```text
WheelDefinition {
  radius_m
  width_m
  drive_torque_n_m
  brake_torque_n_m
  longitudinal_grip
  lateral_grip
  slip_stiffness
  lateral_stiffness
  wheel_inertia
  angular_damping
  max_angular_speed_rad_s
  max_steering_angle_rad
  steering_response
  steerable_default (bool)
  forward_axis_face          # ось качения по умолчанию (tread → assembly forward)
  power_draw_w
  idle_w
  requires_socket_tag = "wheel_socket"
}
```

- Fixture-значения: `radius 0.4`, `width 0.3`,
  `drive_torque 65`,
  `brake_torque 180`, `longitudinal_grip 1.2`, `lateral_grip 0.9`,
  `slip_stiffness 800`, `lateral_stiffness 1000`, `wheel_inertia 0.65`,
  `angular_damping 0.2`, `max_angular_speed 150 rad/s`,
  `max_steering_angle 0.4887` rad, `steering_response 2.5`.
- `power_draw_w` fixture — **300 W** под нагрузкой, `idle_w` — **20 W**.
- `steerable_default = false`; игрок включает поворот на нужных колёсах.

Validator отклоняет WheelDefinition/SuspensionDefinition, если:

- `radius_m <= 0`, `width_m <= 0`, `suspension_travel_m <= 0` или травел вне
  `min_travel_m..max_travel_m`;
- любой из grip/stiffness/inertia/torque/power отрицателен;
- `max_suspension_force_n <= 0` или `max_angular_speed_rad_s <= 0`;
- `max_steering_angle_rad < 0`;
- `wheel_socket_face`/`forward_axis_face` не разрешены `OrientationUtil`;
- у `wheel_suspension` нет ровно одной socket-грани с tag `wheel_socket`;
- у `drive_wheel` нет ровно одного mount pad с tag `wheel_plug`.

## Typed socket (крепление колеса)

Колесо крепится **только** к подвеске. Реализуется минимальным расширением
существующей structural-surface модели, не новым network-графом.

### Расширение mount pad

`StructuralMountPad` получает поле `socket_tag: String` (default `""`):

- `wheel_suspension`: mount pad на `wheel_socket_face` с `socket_tag =
  "wheel_socket"`;
- `drive_wheel`: единственный mount pad с `socket_tag = "wheel_plug"`.

### Правило совместимости

`GridSurfaceUtil`/`RuntimeConnectivity` при поиске rigid-контакта:

- pad без `socket_tag` соединяется по текущим правилам (untagged ↔ untagged);
- pad с `socket_tag` соединяется **только** с pad, чей `socket_tag` образует
  разрешённую пару. Единственная пара v1: `wheel_socket ↔ wheel_plug`;
- любой другой контакт tagged pad — **не** structural edge (эквивалент
  `disconnected` при валидации blueprint).

Так колесо физически невозможно прикрепить к раме, к другому колесу или боком к
подвеске, а обычные блоки не липнут к socket-грани подвески.

### Placement колеса

`WheelPlacementUtil` (по образцу `PistonPlacementUtil`) на placement `drive_wheel`:

1. вычисляет мировую грань `wheel_plug` из orientation превью;
2. ищет соседнюю `wheel_suspension`, чья `wheel_socket` грань смежна и свободна
   (`max_wheels_per_socket`);
3. отклоняет placement с диагностируемой причиной:
   - `wheel_socket_required` — рядом нет подвески;
   - `socket_occupied` — на подвеске уже есть колесо;
   - `wrong_orientation` — plug не обращён к socket;
4. при успехе создаёт обычный `Rigid` joint socket↔plug в общей transaction
   placement.

`wheel_suspension` ставится как обычный module по mount pads к раме; отдельной
атомарной пары (как piston base+head) нет — колесо и подвеска ставятся
раздельно и соединяются socket-правилом.

## WheelPair (simulation unit)

`WheelPair` — производная (не хранимая в topology) единица для physics tick,
пересобирается при structural event:

```text
WheelPair {
  suspension_element_id
  wheel_element_id            # 0, если колесо снято
  effective_suspension        # SuspensionDefinition + instance overrides
  effective_wheel             # WheelDefinition + instance overrides
  steering_angle_rad          # runtime; всегда 0, если wheel не steerable
  wheel_speed                 # runtime угловая скорость (для visual/traction)
}
```

Physics tick публикует производный, не сохраняемый snapshot:

```text
WheelRuntimeSnapshot {
  wheel_element_id
  suspension_element_id
  body_group_id
  status                      # ok | airborne | no_power | invalid_body
  powered
  grounded
  wheel_speed_rad_s
  steering_angle_rad
  suspension_length_m
  compression_m
  socket_body_local
  wheel_center_body_local
  contact_world
  contact_normal_world
  normal_force_n
  longitudinal_force_n
  lateral_force_n
  slip_speed_mps
  lateral_speed_mps
  drive_command
  brake_command
}
```

`wheel_center_body_local` — каноническая pose-точка runtime-визуала. Она
вычисляется physics tick из того же raycast, что создаёт силы:
`socket + suspension_direction * suspension_length`. Presentation не двигает
колесо формулой от `compression` и не хранит собственную rest pose.

Discovery (`WheelSimulationService`): для каждого элемента-`wheel_suspension` в
assembly найти соседний `drive_wheel` по socket-joint. Пара **complete**, если
`wheel_element_id != 0` и оба элемента `is_operational()`.

Per-instance настройки хранятся отдельно от archetype (archetype immutable):

```text
WheelInstanceState {   # ключ: element_id колеса
  steerable
  drive_torque_scale     # 0..1 множитель к archetype (или абсолют в пределах limits)
  brake_torque_n_m
}
SuspensionInstanceState {  # ключ: element_id подвески
  travel_m
  spring_stiffness_n_per_m
  spring_damping_n_s_per_m
}
```

## Проекция физики (Jolt / Godot contract)

Все пункты — обязательные; они кодируют уже усвоенные в проекте уроки Jolt.

### Locomotive compile override

`SimulationPhysicsProjection` при (пере)сборке assembly:

- `_is_locomotive_assembly(assembly_id)` — есть ≥1 complete `WheelPair`;
- assembly **на terrain/static якоре** (ещё не released) → `frozen` /
  `StaticBody3D`, чтобы достроить на подпорке;
- **floating** locomotive (якорь снят / released) → всегда dynamic
  `RigidBody3D`, `motion.frozen = false` — **без** freeze «до кокпита»;
- `ControlSeat.activate` при ещё живом якоре: release + clearance lift, dynamic
  даже если `assembly_has_anchor` ещё true;
- если не locomotive: поведение без изменений (anchored → `StaticBody3D`).

### Wheel tick

`_tick_wheel_pairs(delta)` вызывается в
`SimulationPhysicsProjection._physics_process`, тем же образом и порядком, что
`_tick_piston_actuators` (после compile, до/наряду с actuator tick). Для каждой
**floating** locomotive (`RigidBody3D`, не freeze) и каждой complete
`WheelPair`:

1. вычислить мировую точку и ось raycast из pose подвески (socket face pose),
   не из отдельного Marker3D;
2. `PhysicsRayQueryParameters3D`: длина = `travel_m + radius_m`,
   `collision_mask = 1 | 2` (terrain + machinery/assembly),
   `exclude = [body.get_rid()]`, `collide_with_areas = false`. Игрока (его
   layer) в маску не включать (POC-3);
3. при отсутствии hit — колесо в воздухе, силы 0, только free-spin decay
   `wheel_speed`;
4. скорость socket/contact считать относительно **custom COM** body:
   `v_point = linear_velocity + angular_velocity × (point − center_of_mass_world)`;
   body origin не является допустимой заменой COM;
5. при hit: пружина `F = max(spring·compression + damping·v_along_down, 0)`,
   приложить `apply_force(F·up, point − body_origin)`;
6. neutral forward получить из `WheelDefinition.forward_axis_face` с учётом
   orientation элемента; hardcoded `±body.basis.z` запрещён;
7. steer: `forward.rotated(hit_normal, steering_angle_rad)` (поворот в плоскости
   контакта, не euler body); `steering_angle_rad = 0`, если колесо не steerable;
8. traction/lateral через friction ellipse: при превышении grip — скольжение;
9. drive/brake torque шкалируется питанием: если
   `IndustryElementRuntime.powered == false` для элемента колеса — drive torque
   = 0, тормоз доступен (пассивное трение остаётся);
10. приложить traction+lateral как `apply_force` в точке контакта;
11. записать полный `WheelRuntimeSnapshot`; visual/HUD читают только его;
12. при первом ненулевом drive/steer/brake командном входе — разбудить body
   (`sleeping = false`), иначе `apply_force` на спящем теле игнорируется.

### Body groups и композиция

- `SimulationPhysicsProjection.get_element_projection(suspension_element_id)`
  определяет `RigidBody3D`, на котором тикает пара;
- все complete pairs одной assembly получают общую control-команду, но силы
  прикладываются к body своей подвески;
- piston base, carriage и установленный на carriage бур остаются отдельными
  body groups Jolt; колёса на base не меняют piston solver;
- колесо на carriage допустимо: raycast, силы и visual обязаны следовать
  carriage body, а не motion root assembly;
- один невалидный body/pair даёт `status = invalid_body` только этой паре и не
  отменяет tick остальных колёс;
- переход anchored construction → locomotive выполняет один явный
  release-seat: до создания live `RigidBody3D` motion поднимается вдоль
  assembly-up на максимальный `travel + radius` среди complete pairs, после
  чего Jolt сам осаживает подвеску; live body не телепортируется и скрытый
  downforce не применяется;
- техника собирается из placeable модулей; цельный mounted cart не определяет
  семантику модульного ровера.

### Запреты

- не использовать `custom_integrator` на locomotive body (конфликт с
  `apply_force`, урок KINETIC-INTERACTION);
- не создавать `Generic6DOFJoint3D`/`HingeJoint3D` на колесо;
- не создавать отдельный `RigidBody3D` на колесо (взрыв тел при merge/split);
- не писать transform колеса напрямую — только силы.

### Масса, COM, гравитация

- масса элементов уже суммируется `ColliderProjectionUtil.assembly_dry_mass`;
  COM — `assembly_center_of_mass_local`;
- пружинные fixture-значения оттюнингованы под лунную гравитацию мира
  **1.62 m/s²**, не под 9.81;
- высоко расположенные кокпит/батарея повышают опрокидываемость — это
  ожидаемое поведение (SE-like), скрытым downforce не компенсируется.
- spring/damper задаются на модуль: добавление колёс физически увеличивает
  суммарную несущую способность, а drive torque и electric demand растут
  линейно с числом powered wheels; скрытого деления на «стандартные 4 колеса»
  нет.

## Управление и кокпит (ControlSeat)

### Interaction

`InteractionQuery`: если archetype наведённого элемента имеет роль
`ControlSeat`, kind = `KIND_CONTROL_SEAT`; в metadata — `assembly_id`,
`element_id`, локальный seat offset.

`WorldCommandGateway._toggle_control_seat` получает ветку для simulation
element:

- найти `RigidBody3D` assembly через projection;
- `player.enter_vehicle(body, seat_world_transform)` (существующий механизм,
  используемый launch vehicle);
- включить input routing на `AssemblyLocomotionController` этой assembly;
- exit → `player.exit_vehicle(world_position)`, снять routing.

### Input routing

`AssemblyLocomotionController` (per assembly) хранит `drive_command`,
`brake_command`, `steering_command`, `parking_brake` (default `true`).
Когда игрок seated и vehicle — locomotive assembly:

- input actions из `project.godot` (`move_forward`/`move_back`,
  поворот влево/вправо) → `set_drive_command` / `set_steering_command`;
- `jump` (Space) → рабочий `brake_command` (service brake);
- `toggle_parking_brake` (P) → toggle `parking_brake`; engage только при
  почти нулевой скорости body, иначе отказ;
- при `parking_brake`: gateway выставляет `drive=0`, `steer=0`, `brake=1`;
  wheel tick на grounded паре держит колесо **bristle-моделью** статического
  трения: жёсткая пружина, привязывающая контактный патч к якорю на грунте
  (`park_anchor_world`, персистится per-wheel в wheel runtime) + демпфер,
  clamp по фрикционному эллипсу μ·N. Держащая сила берётся из деформации
  (позиционный член), а не из скорости → **нет creep** ни на ровном, ни на
  склоне. Когда спрос превышает μ·N (сильный толчок) — bristle насыщается,
  якорь съезжает вместе с контактом: транспорт сдвигается и заново
  захватывается на новом месте (SE-style). Space/service brake не меняется;
  body остаётся dynamic.
  После construction place/dismantle (mass/COM change) или recreate physics
  body якоря **сбрасываются** (`park_anchor_valid=false`) — иначе bristle
  тянет к устаревшим world-точкам и на powered rover поднимает physics spiral;
- **parking settle-freeze**: bristle-модель держит транспорт per-frame силами,
  поэтому припаркованный body никогда не засыпает (raycast'ы колёс, пружины,
  terrain-контакты — каждый кадр, навсегда). Когда PB включён, driver input
  нулевой (`brake_command` не считается — seat-exit держит его в 1.0) и
  скорость < `PARKING_BRAKE_SPEED_EPS` подряд `PARK_FREEZE_SETTLE_FRAMES`
  (~0.5 s) — projection **замораживает** body (static pose, ноль per-frame
  стоимости, wheel tick пропускается). Разморозка: любой driver input /
  снятие PB (`_update_parking_freeze`), вход в seat (`_wake_rover_body`),
  terrain-копка рядом (`wake_frozen_near` — иначе замороженный ровер висит
  над вырытой ямой). После structural change транспорт свободен пару секунд
  (settle) и замерзает снова;
- exit (E): снять routing / driver input; **не** мгновенный freeze и не
  zero-vel — freeze только по settle-правилу выше; без PB машина катится,
  с PB колёса держат до заморозки;
- обычный player locomotion выключается (`set_gameplay_input_enabled(false)`);
- команды не идут через structural transaction — это frequent runtime state,
  читаемый `_tick_wheel_pairs`.

Кокпит владеет **всеми** complete `WheelPair` своей assembly. Steer применяется
только к колёсам с `steerable = true`; остальные получают лишь drive/brake.

### Cabin power HUD

Пока игрок сидит в кокпите, presentation-виджет `VehiclePower`
(`scripts/ui/hud_vehicle_power.gd`, контракт `HUD-UI-01.md`) показывает:

- суммарный заряд батарей assembly (`battery_kwh` / `max_kwh`);
- текущую электрическую нагрузку consumers (колёса / thruster / gyro /
  actuators — `dynamic_power_w` + idle);
- предикт длительности поездки при текущем `net_drain_w`.

Батарея **не** пополняется при повторной посадке: `seed_battery_if_needed`
заряжает только неинициализированную батарею один раз; пустая после разряда
остаётся пустой, пока её не зарядит `power_source`.

### Passenger

Стоящий на палубе игрок наследует движение через существующий `SupportFrame` +
layer 2 (POC-3). Wheel raycasts исключают собственный body RID; контакты внутри
одного body group не наносят impact/carve (subgrid immunity,
KINETIC-INTERACTION); разные groups одной assembly бьют друг друга.
**Locomotive assembly ↔ terrain:** carve и damage
отключены в `ImpactResolverService` — грунт обрабатывают только wheel
raycasts; piston/frame kinetic carve не затрагивается. После правки
террейна будят locomotive `RigidBody3D`, иначе sleeping Jolt-тело не
замечает исчезнувшую опору.
**Physics:** wheel-locomotive body на layer assembly, `collision_mask`
= terrain|assembly (шасси — safety net при tip-over; без terrain body
проваливается сквозь кору). Смягчение контакта: `continuous_cd=false`,
`bounce=0`. Solid-коллайдеры `drive_wheel` / `wheel_suspension` на
locomotive disabled (ход через raycast). Flight/landing-leg — тот же
mask с terrain. Demo/debug spawn (`bootstrap._spawn_rover_at_hint`)
ждёт cooked physics ground под точкой посадки — SDF-only seating при
отстающем voxel collider (VT #677) даёт freefall сквозь кору.

## Электропитание

Наследует Industry v1 (INDUSTRY-V1.md § Electric Flow), новых сетевых правил
нет:

- `drive_wheel` — consumer (`IndustryElectricProfile`): `idle_w` всегда,
  `power_draw_w` под тягой; без питания drive torque = 0;
- `power_distributor_small` — distributor с `supply_radius_m = 6` (меньше
  большого 12 м);
- `power_battery_small` — `max_kwh = 2.5`, charge **250 W**, discharge
  **1500 W**: одна батарея питает fixture из 4 колёс, дополнительные
  колёса/пистоны/бур требуют дополнительных батарей или source;
- провода соединяют только энергоинфраструктуру (source/distributor/battery);
  колёса и кокпит к проводам не подключаются, питаются радиусом distributor;
- подвеска и кокпит — не consumers.

Fixture-значения живут в `IndustryElectricProfile` (как у больших энергоблоков)
до переноса на `.tres` export-поля; это осознанный технический долг v1.

## Configure команды

Две frequent-команды (last-write-wins), маршрутизируются через
`WorldCommandGateway`, применяются `WheelSimulationService`:

```text
ConfigureWheelCommand {
  wheel_element_id
  steerable                # опционально
  drive_torque_scale       # опционально, clamp к limits
  brake_torque_n_m         # опционально, clamp ≤ authored
  grip_scale               # опционально, 0..1 от authored grip
  max_steering_angle_rad   # опционально, clamp ≤ authored
}
ConfigureSuspensionCommand {
  suspension_element_id
  travel_m                 # clamp к min/max_travel_m
  spring_stiffness_n_per_m # clamp к неотрицательному
  spring_damping_n_s_per_m # clamp
}
```

Значения вне допустимого диапазона отклоняются с диагностируемой причиной, не
обрезаются молча (аналог `configure_actuator` inverted-limit reject).

## Визуал и читаемость ориентации

Цель: при прицеливании сразу понятно, **что** ставишь, **какой стороной** и
**куда оно крепится**. Эталон — `PistonVisual` (одни `.tscn` для preview и
runtime, axis arrow, travel ghost). Шейдеры не нужны: StandardMaterial3D +
emission (R3 — VisualShader не создавать).

### Меши (`.tscn`, без логики — R4)

| Файл | Форма и семантика граней |
|---|---|
| `scenes/presentation/wheel_suspension_visual.tscn` | L-образный knuckle; **синяя** emissive грань — крепление к раме; **жёлтый** stub — `wheel_socket`; корпус серый |
| `scenes/presentation/drive_wheel_visual.tscn` | hub + шина; **оранжевый** plug сверху; светлая полоса протектора = `forward_axis` (направление качения) |
| `scenes/presentation/cockpit_visual.tscn` | остекление спереди, спинка сиденья сзади — виден «перёд» |

Кубическая форма остаётся у шасси (`frame`) и малых энергоблоков.

### Preview gizmos (`ConstructionPreview`)

Для suspension/wheel/cockpit — special-case, как для piston/drill:

- стрелка оси подвески (raycast вниз);
- **travel ghost** — полупрозрачный цилиндр хода подвески;
- **socket halo** — кольцо на `wheel_socket`; при наведении колеса — подсветка
  целевого socket на соседней подвеске (valid snap);
- **steering arc** — дуга ±`max_steering_angle`, если превью колеса steerable;
- invalid → красный ghost + HUD toast с причиной (`wheel_socket_required`,
  `socket_occupied`, `wrong_orientation`);
- HUD build-hint: краткая подпись ориентации (например `↑ рама  ↓ гнездо`,
  `↔ протектор = ход`), токены в `hud_tokens.gd`.

### Runtime

- `WheelVisualProjection` (по образцу `PistonVisualProjection`): шина крутится
  пропорционально `wheel_speed`, steering-root получает
  `steering_angle_rad`, а hub+tire ставятся в `wheel_center_body_local`
  из `WheelRuntimeSnapshot` (отставание ≤1 кадра допустимо и не является
  authoritative);
- `ElementVisualProjection` маршрутизирует cockpit/suspension/wheel на `.tscn`
  вместо box-mesh; палитра совместима с существующим rover tint.

## Snapshot

Расширяет текущую schema: per-instance строки для колёс и подвесок.

Хранит:

- `WheelInstanceState` (steerable, torque overrides) по `element_id` колеса;
- `SuspensionInstanceState` (travel, spring, damping) по `element_id` подвески;
- socket-joint как обычный `Rigid` joint (без нового joint kind).

Не хранит:

- `WheelPair` (производная, пересобирается при restore);
- `wheel_speed`/`steering_angle` (runtime presentation/physics);
- drive/steer command (frequent, сбрасывается при загрузке);
- Godot nodes/RIDs, raycast результаты.

Restore: восстановить элементы и socket-joints, применить per-instance
настройки, пересобрать `WheelPair`, не выдавать колёсные силы до завершения
projection rebuild.

## Диагностика

Runtime inspector/log для `WheelPair` (на transition, не каждый кадр):

```text
assembly_id
suspension_element_id
wheel_element_id
grounded (bool)
compression_m
steering_angle_rad
drive_command / brake_command
powered
status            # ok | airborne | no_power | no_wheel
```

Эти поля берутся из `WheelRuntimeSnapshot`; отдельный диагностический расчёт
запрещён. Snapshot обязан содержать только finite числа. Невалидная геометрия
изолируется в одной pair со статусом `invalid_body`, без NaN в Jolt.

## Тесты

Чистая kernel/projection логика — headless-сцена
`scenes/test_simulation_wheel.tscn`, добавляется в `tests/run_tests.sh` (R2:
только логика симуляции, не геймплей).

Обязательные cases:

1. `drive_wheel` без соседней подвески — placement отклоняется
   (`wheel_socket_required`);
2. второе колесо на занятый socket — отклоняется (`socket_occupied`);
3. подвеска + колесо создают complete `WheelPair` и один socket `Rigid` joint;
4. assembly с complete `WheelPair` остаётся anchored при строительстве на
   якоре и становится dynamic `RigidBody3D` после release якоря /
   `ControlSeat.activate`;
5. при `powered` и drive-команде body набирает поступательную скорость за N
   ticks; при `no_power` — не набирает (torque = 0);
6. steerable front pair меняет heading при steer-команде; fixed rear — нет;
7. `configure_wheel` меняет `steerable`; `configure_suspension` меняет travel в
   пределах limits, за limits — reject;
8. dismantle колеса → пара становится incomplete; assembly без complete пар
   перестаёт быть locomotive;
9. snapshot roundtrip сохраняет per-instance настройки и socket topology;
10. non-locomotive assembly (только рама+подвески без колёс) остаётся anchored
    `StaticBody3D` — регресс не ломает статические постройки.
11. 4-wheel fixture на flat collider реально набирает скорость и steering
    меняет heading; это projection/core test, не gameplay test;
12. 10 complete pairs discover/tick детерминированно, публикуют 10 finite
    snapshots и не содержат fixed-four branches;
13. custom COM: point velocity, damping и slip используют offset от COM;
14. multibody assembly: pair на base получает base body, pair на piston
    carriage получает carriage body; stationary drill на carriage не меняет
    wheel body ownership;
15. electric demand равен сумме idle+traction всех wheels; недостаток мощности
    выключает весь supplied component симметрично, без частичного torque.
16. cabin power snapshot: `VehiclePowerSnapshotBuilder` даёт finite ETA под
    тягой; `seed_battery_if_needed` не рефилит initialized empty battery
    (`scenes/test_vehicle_power.tscn`).

Геймплей/HUD/презентация/визуал headless-тестом не подтверждаются. В запущенной
игре (Beckett):

1. построить раму, 4 подвески, 4 колеса (передние — configure `steerable`),
   кокпит, distributor+battery, провод source→distributor;
2. скриншот preview: видно ориентацию подвески к раме и protector-направление
   колеса, socket halo;
3. `E` → сесть, WASD → ехать; `/` → power radius; развернуться на передних
   колёсах;
4. отключить питание (вне радиуса) → колёса не тянут;
5. проверить screenshot, remote tree и чистые game logs;
6. финальное подтверждение человека в игре.

## Acceptance

PoC принят, когда:

1. игрок строит ровер из отдельных placeable модулей (рама, подвеска, колесо,
   кокпит, малые энергоблоки) без baked blueprint;
2. колесо крепится только к подвеске; неверная попытка placement отклоняется с
   понятной причиной и красным preview;
3. подвеска и колесо настраиваются независимо (`configure_suspension`,
   `configure_wheel`), включая переключаемый `steerable`;
4. locomotive assembly едет как dynamic `RigidBody3D` на raycast-подвеске,
   реагирует на массу, гравитацию 1.62 и рельеф;
5. без питания колёса не тянут (`no_power`), тормоз/трение сохраняются;
6. игрок садится в кокпит и управляет WASD; steer работает только на steerable
   колёсах; passenger устойчив на палубе;
7. визуал в preview и runtime однозначно показывает стороны и точки крепления
   (подтверждено скриншотом);
8. snapshot/restore сохраняет настройки, socket-топологию и locomotive-статус;
9. `./tests/run_one.sh test_simulation_wheel` зелёный;
10. полный `./tests/run_tests.sh` зелёный;
11. gameplay/визуал-проверка в запущенной игре и подтверждение человека
    выполнены.
