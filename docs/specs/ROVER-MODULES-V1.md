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

- рама (`rover_frame`) как шасси;
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
   `WheelPair` (подвеска + прикреплённое колесо). Она компилируется в dynamic
   `RigidBody3D`, даже если topology содержит terrain anchor: anchor
   игнорируется для locomotive assembly (см. § «Проекция физики»).
6. Строительство ровера ведётся на земле в anchored состоянии. Расширение
   assembly после того, как она стала locomotive/движется, вне скоупа v1
   (сохраняется kernel-инвариант `mobile_construction_not_supported`).
7. Управление в v1 — hardcoded mapping «кокпит владеет всеми колёсами своей
   assembly» (SE-подобный control block). Programmable `Binding` UI вне v1.

## Границы

### Входит

- 6 archetypes: `rover_frame`, `wheel_suspension`, `drive_wheel`, `cockpit`,
  `power_battery_small`, `power_distributor_small`;
- typed socket `wheel_socket`/`wheel_plug` и placement-валидация;
- `WheelPair` discovery, drive/brake/steer, raycast suspension;
- per-instance настройки подвески и колеса (`configure_suspension`,
  `configure_wheel`), включая переключаемый `steerable`;
- locomotive compile override (dynamic body при anchor);
- electric on/off budget: `drive_wheel` — consumer, без питания torque = 0;
- cockpit `ControlSeat`: enter/exit, WASD routing, passenger support;
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
- миграция baked `cart_rover` на новые модули (остаётся на legacy
  `CartLocomotion`);
- строительство/расширение движущегося ровера.

## Archetypes

Все новые модули — footprint `1×1×1` в общей grid 0.5 m, кладутся в
`resources/archetypes/slice01/` (ограничение
`WorldCommandGateway._get_archetype()` — player construction грузит только
`Slice01Archetypes`).

| `archetype_id` | Роли | Definition | Настраивается игроком |
|---|---|---|---|
| `rover_frame` | `Frame` | — | — |
| `wheel_suspension` | `Support` | `SuspensionDefinition` | ход, жёсткость, демпфер |
| `drive_wheel` | `Support`, `Actuator` | `WheelDefinition` | момент, тормоз, grip, `steerable` |
| `cockpit` | `ControlSeat`, `Frame` | seat offset | — |
| `power_battery_small` | `Tank` | — (electric fixture) | — |
| `power_distributor_small` | `Hub` | — (electric fixture) | — |

`rover_frame` совпадает по смыслу с существующим
`resources/archetypes/rover/rover_frame.tres`, но материализуется как
slice01-fixture, чтобы попасть в player construction path; baked blueprint
продолжает ссылаться на свою копию.

### SuspensionDefinition

```text
SuspensionDefinition {
  wheel_socket_face          # default NEG_Y (гнездо смотрит вниз)
  suspension_travel_m        # длина хода (rest length)
  spring_stiffness_n_per_m
  spring_damping_n_s_per_m
  min_travel_m / max_travel_m  # допустимый диапазон configure
  max_wheels_per_socket = 1
}
```

- `wheel_socket_face` проходит через `OrientationUtil`; мировая грань берётся из
  orientation элемента, а не из presentation node.
- Начальные fixture-значения наследуют текущий `CartLocomotion`:
  `suspension_travel_m = 0.6`, `spring_stiffness = 1600`, `spring_damping = 400`.
  Это initial tuning, а не kernel-константы.

### WheelDefinition

```text
WheelDefinition {
  radius_m
  drive_torque_n_m
  brake_torque_n_m
  longitudinal_grip
  lateral_grip
  slip_stiffness
  lateral_stiffness
  wheel_inertia
  max_steering_angle_rad
  steering_response
  steerable_default (bool)
  forward_axis_face          # ось качения по умолчанию (tread → assembly forward)
  power_draw_w
  idle_w
  requires_socket_tag = "wheel_socket"
}
```

- Fixture-значения наследуют `CartLocomotion`: `radius 0.4`, `drive_torque 65`,
  `brake_torque 180`, `longitudinal_grip 1.2`, `lateral_grip 0.9`,
  `slip_stiffness 800`, `lateral_stiffness 1000`, `wheel_inertia 0.65`,
  `max_steering_angle 0.4887` rad, `steering_response 2.5`.
- `power_draw_w` fixture — **300 W** под нагрузкой, `idle_w` — **20 W**.
- `steerable_default = false`; игрок включает поворот на нужных колёсах.

Validator отклоняет WheelDefinition/SuspensionDefinition, если:

- `radius_m <= 0`, `suspension_travel_m <= 0` или травел вне
  `min_travel_m..max_travel_m`;
- любой из grip/stiffness/inertia/torque/power отрицателен;
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
- если locomotive: компилировать корень как **`RigidBody3D`**, `motion.frozen =
  false`, `custom_integrator` **выключен**, даже если `assembly_has_anchor`
  вернул true (anchor-joint не создаёт `StaticBody3D` и не морозит motion для
  locomotive assembly);
- если не locomotive: поведение без изменений (anchored → `StaticBody3D`).

### Wheel tick

`_tick_wheel_pairs(delta)` вызывается в
`SimulationPhysicsProjection._physics_process`, тем же образом и порядком, что
`_tick_piston_actuators` (после compile, до/наряду с actuator tick). Для каждой
locomotive assembly и каждой complete `WheelPair`:

1. вычислить мировую точку и ось raycast из pose подвески (socket face pose),
   не из отдельного Marker3D;
2. `PhysicsRayQueryParameters3D`: длина = `travel_m + radius_m`,
   `collision_mask = 1 | 2` (terrain + machinery/assembly),
   `exclude = [body.get_rid()]`, `collide_with_areas = false`. Игрока (его
   layer) в маску не включать (POC-3);
3. при отсутствии hit — колесо в воздухе, силы 0, только free-spin decay
   `wheel_speed`;
4. при hit: пружина `F = max(spring·compression + damping·v_along_down, 0)`,
   приложить `apply_force(F·up, point − body_origin)`;
5. steer: `forward.rotated(hit_normal, steering_angle_rad)` (поворот в плоскости
   контакта, не euler body); `steering_angle_rad = 0`, если колесо не steerable;
6. traction/lateral через friction ellipse (перенос математики
   `CartLocomotion`): при превышении grip — скольжение;
7. drive/brake torque шкалируется питанием: если
   `IndustryElementRuntime.powered == false` для элемента колеса — drive torque
   = 0, тормоз доступен (пассивное трение остаётся);
8. приложить traction+lateral как `apply_force` в точке контакта;
9. при первом ненулевом drive/steer/brake командном входе — разбудить body
   (`sleeping = false`), иначе `apply_force` на спящем теле игнорируется.

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
`brake_command`, `steering_command` (last-write-wins, frequent). Когда игрок
seated и vehicle — locomotive assembly:

- input actions из `project.godot` (`move_forward`/`move_backward`,
  поворот влево/вправо) → `set_drive_command` / `set_steering_command`;
- обычный player locomotion выключается (`set_gameplay_input_enabled(false)`);
- команды не идут через structural transaction — это frequent runtime state,
  читаемый `_tick_wheel_pairs`.

Кокпит владеет **всеми** complete `WheelPair` своей assembly. Steer применяется
только к колёсам с `steerable = true`; остальные получают лишь drive/brake.

### Passenger

Стоящий на палубе игрок наследует движение через существующий `SupportFrame` +
layer 2 (POC-3). Wheel raycasts исключают собственный body RID; контакты внутри
одной assembly не наносят impact/carve (subgrid immunity,
KINETIC-INTERACTION).

## Электропитание

Наследует Industry v1 (INDUSTRY-V1.md § Electric Flow), новых сетевых правил
нет:

- `drive_wheel` — consumer (`IndustryElectricProfile`): `idle_w` всегда,
  `power_draw_w` под тягой; без питания drive torque = 0;
- `power_distributor_small` — distributor с `supply_radius_m = 6` (меньше
  большого 12 м);
- `power_battery_small` — `max_kwh = 2.5`, charge/discharge fixture **250 W**;
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
  brake_torque_n_m         # опционально, clamp
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

Кубическая форма остаётся только у `rover_frame` и малых энергоблоков.

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
  пропорционально `wheel_speed`, hub визуально смещается по compression
  (visual lerp к raycast hit; отставание ≤1 кадра допустимо и не является
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

## Тесты

Чистая kernel/projection логика — headless-сцена
`scenes/test_simulation_wheel.tscn`, добавляется в `tests/run_tests.sh` (R2:
только логика симуляции, не геймплей).

Обязательные cases:

1. `drive_wheel` без соседней подвески — placement отклоняется
   (`wheel_socket_required`);
2. второе колесо на занятый socket — отклоняется (`socket_occupied`);
3. подвеска + колесо создают complete `WheelPair` и один socket `Rigid` joint;
4. assembly с complete `WheelPair` компилируется как dynamic `RigidBody3D`
   несмотря на terrain anchor;
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
