# Player & Interaction v1

Статус: первый production milestone после PoC 1–3.

Родительские документы:

- `docs/CONCEPT.md`;
- `docs/PHYSICAL-LANGUAGE.md`;
- `docs/specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md`.

## Цель

Игрок должен уверенно перемещаться и воздействовать на мир от первого лица на
неровном voxel terrain и движущихся физических конструкциях. Контроллер ощущается
тяжёлым, но отзывчивым: ввод читается сразу, остановка предсказуема, а лунная
баллистика не подменяется земной гравитацией.

Milestone также вводит единственный путь взаимодействия:

```text
Input
  → InteractionQuery
  → ToolAction
  → CommandGateway
  → authoritative handler
  → ActionResult
  → UI / audiovisual feedback
```

Инструмент не выполняет world mutation и не делает собственный camera raycast.

## Reference policy

R6 остаётся неизменным: controller addon и vendored third-party source не
добавляются.

До production-реализации проводится собственный benchmark. В качестве референсов
алгоритма, но не источника копируемого кода, используются:

- Godot `CharacterBody3D`, `PhysicsServer3D.body_test_motion()` и manual camera
  interpolation;
- up-forward-down step handling из публичных Godot proposals;
- открытые реализации stair stepping для выявления известных failure modes.

Реализация должна объясняться собственными инвариантами и тестами.

## Locomotion contract

### Physical body

- `CharacterBody3D`, `MOTION_MODE_GROUNDED`, единицы СИ;
- высота стоящего игрока — 1.8 м, ширина — 0.7 м;
- `CapsuleShape3D`, radius `0.30 m`, full height `1.8 m` (Godot `height`
  includes both hemispheres);
- step solver uses a minimum `0.12 m` raised forward probe so the rounded foot
  clears a stair lip without relaxing the `0.30 m` height or wall guards;
- collision margin фиксируется тестом и не используется для сокрытия penetration.

### Ground movement

Целевой профиль для первой настройки:

- walk speed: 5.0 м/с;
- sprint speed: 7.5 м/с;
- достижение 90% walk speed: не более 0.30 с;
- остановка с walk speed: не более 0.25 с;
- мгновенная смена input direction не создаёт скорость выше sprint speed;
- без ввода на горизонтальной поверхности игрок остаётся на месте;
- диагональный input не быстрее осевого.

Параметры могут измениться после ручной feel-сессии, но acceptance-метрики и тесты
обновляются одновременно.

### Gravity и jump

- в воздухе используется gravity Field проекта: 1.62 м/с² вниз;
- ground adhesion применяется только при подтверждённой опоре и не меняет
  воздушную траекторию;
- jump задаётся физически осмысленной начальной скоростью;
- целевая высота обычного прыжка: 1.2–1.4 м над точкой отрыва, чтобы с запасом
  запрыгивать на метровый блок без отдельного mantle;
- отпускание кнопки не включает скрытую дополнительную гравитацию в v1;
- inherited platform velocity сохраняется при прыжке и сходе.

### Slopes, steps и edges

- walkable slope: до 45° включительно;
- более крутая поверхность не становится floor;
- максимальная высота автоматического шага: 0.30 м;
- step-up выполняется только при вводе в препятствие, свободном объёме тела и
  walkable landing normal;
- step-down не приклеивает игрока во время прыжка;
- алгоритм не позволяет взбираться по стене серией step-up;
- край платформы не вызывает ложный step или вертикальный импульс;
- low ceiling отменяет step-up без penetration.

Step solver использует motion tests `up → forward → down`; camera smoothing не
изменяет physics pose.

### Moving bodies

- `platform_floor_layers` и
  `PLATFORM_ON_LEAVE_ADD_VELOCITY` остаются основным механизмом;
- `SupportFrame` публикует carrier и velocity точки опоры;
- attachment fallback не вводится, пока честная капсула/цилиндр проходит тест;
- допустимый локальный drift задаётся существующим PoC-3:
  0.5 м при разгоне, 0.8 м в повороте, 1.0 м при прыжке.

## Camera contract

- body владеет yaw, head target — pitch, camera visual rig не владеет gameplay
  transform;
- physics target обновляется в `_physics_process`;
- top-level camera в `_process` следует за target transform **одним
  источником** (position + basis из одного transform): yaw
  применяется сразу в input, а смешение interpolated position с raw basis
  давало rotation jitter на неровном voxel ground; пешком у игрока
  `physics_interpolation_mode = OFF` → `global_transform`; в `ControlSeat`
  (child of locomotive `RigidBody3D`) interpolation **ON** и камера берёт
  `get_global_transform_interpolated()`, иначе judder на частоте физики;
- mouse delta применяется без зависимости от render FPS;
- pitch ограничен, roll отсутствует без отдельного эффекта;
- в `ControlSeat` допустим toggle FP ↔ free orbit 3P (`toggle_vehicle_camera`,
  клавиша V): орбита крутит собственные yaw/pitch вокруг vehicle pivot и
  **не** владеет gameplay yaw игрока; WASD остаётся locomotion InputMap;
  `toggle_parking_brake` (P) — стояночный (лок колёс) только после полной
  остановки; `exit_vehicle` сбрасывает orbit в FP и не freeze’ит шасси;
- procedural bob/sway воздействует только на visual rig и имеет малую амплитуду;
- interaction ray использует согласованную aim pose и не дрожит из-за camera bob;
- FP tool meshes (hand drill / welder) — children world Camera (`rest_offset`);
  large-world shimmer решается custom Godot `precision=double` (см. README),
  не отдельным viewmodel SubViewport;
- sensitivity и FOV доступны игроку и сохраняются в `user://`.

## InteractionQuery

Один query вычисляется за physics tick и возвращает типизированный результат:

```text
InteractionHit {
  valid
  point
  normal
  distance
  target_kind
  collider
  target_id
  metadata   # for KIND_SIMULATION_ELEMENT: filled from Interaction Read-Model
}
```

Правила:

- origin и direction задаются aim pose камеры;
- player RID исключается;
- physics collider проверяется первым, voxel SDF — fallback;
- query хранит hit независимо от активного инструмента;
- reach луча: `max_distance = 4.0` по умолчанию; в build tool —
  `build_max_distance = 10.0` (preview ghost);
- инструмент применяет собственный `max_range` к готовому hit;
  build place обязан использовать тот же reach, что и `build_max_distance`;
- пустой результат представлен явно, не `null`-словарём;
- presentation может читать hit, но не менять его;
- для `KIND_SIMULATION_ELEMENT` Query **не** строит карточку цели сам:
  берёт `element_id` из shape meta, читает
  `SimulationWorld.get_interaction_card(element_id)` (см. § Interaction
  Read-Model), склеивает с hit geometry. Aim path не вызывает
  `list_joints()`, enrich-сканы placement util и cargo graph walks.

Минимальные `target_kind`: `none`, `voxel`, `body`, `placed_block`,
`control_seat`, `simulation_element`, `electric_cable`, `world_loot`,
`granular`, `terrain_debris`.

Player-built ровер расширяет `control_seat` на simulation element с ролью
`ControlSeat` (кокпит): наведение даёт enter/exit vehicle и WASD-управление,
`configure_wheel`/`configure_suspension` открываются на `drive_wheel` и
`wheel_suspension`. Полный контракт — `specs/ROVER-MODULES-V1.md`.

## Interaction Read-Model

Статус: контракт внедрения. Phase 1–3 в коде (index, thin Query/card,
industry `display_*`, actuator DisplayPose push+Hz, HUD/terminal
dirty-signature). Phase 4 — cleanup/docs. Этот раздел — единственный
источник правды по ownership и bans.

### Зачем

Прицел не должен каждый physics-кадр заново узнавать состав сборки
(скан всех joints, cargo graph). Сборка уже знает свою топологию.
Interaction Read-Model — derived read-model у `SimulationWorld`: структура
патчит/инвалидирует его на structural events; actuators и industry пушат
display-поля сами; Query/HUD/tools только читают.

Не путать с **ConstructionPreview** (призрак place/snap). Preview в
`ControlSeat` уже выключен. Лаг «сижу в ровере, навёл на блок → FPS падает»
при неактивном build — симптом Read-Model / Query metadata, не construction
snap. Шпаргалка: `docs/cheatsheets/interaction-read-model.md`.

### Ownership

| Писатель | Что пишет |
|---|---|
| Structural mutate (place/dismantle/split/merge/joint) | `InteractionIndex` StructuralEntry, `element_id → driven_joint_id` (оба endpoint'а) |
| `_notify_topology_changed` | invalidate assembly / clear all (как occupancy); **не** точечный patch (нет `element_id`) |
| `restore_from` / `world_restored` | `clear_interaction_index()`; lazy rebuild on demand |
| `ActuatorSimulationService` (driven joint) | `ActuatorDisplayPose` на своей entry |
| Industry / electric / recipe tick | `display_*` на `IndustryElementRuntime` (status, cargo HUD, missing input) |
| InteractionQuery / HUD / tools | **только читают** |

Hit geometry (`point`, `normal`, `distance`, `aim_direction`,
`collider_local_cell`) — из ray / projection shape meta, **не** из index.

### Слои

1. **StructuralEntry** — identity, roles, `driven_joint_id`+kind, authored
   caps, wheel/suspension markers, `control_seat`. Stamp =
   `assembly.topology_revision`.
2. **ActuatorDisplayPose** — observed extension/angle, `actuator_status`,
   at-rest. Display stamp, не topology bump.
3. **Live overlay** — O(1) из element / industry runtime / motor-by-joint-id /
   DisplayPose при сборке `InteractionCard`.

Публичный API `SimulationWorld` (без fat Dictionary / dual legacy API):

```text
get_interaction_structure(element_id) -> InteractionStructure   # RefCounted
get_interaction_card(element_id) -> InteractionCard             # RefCounted, in-place
driven_joint_for_element(element_id) -> SimulationJoint|null
interaction_roles_for_element(element_id) -> PackedStringArray
clear_interaction_index()
```

`InteractionCard` — единственный read API для aim/HUD. Commands на click
берут `element_id` / `joint_id` и делают authoritative lookup, не доверяют
устаревшему fat dict.

### ActuatorDisplayPose

Писатель — сам driven joint / `ActuatorSimulationService` на **своём** изменении
(не глобальный опрос всех motors).

- idle / pose не изменилась → silence;
- pose изменилась meaningfully → write, не чаще `DISPLAY_POSE_HZ = 10`;
- status изменился → write status сразу;
- STOP / IDLE / fault-stop → flush pose+status сразу;
- place / restore → seed один раз;
- index: и `element_a`, и `element_b` → один `driven_joint_id`.

Физика / visuals / construction snap **не** читают DisplayPose — только
RigidBody / projection.

### Aim path bans

На пути InteractionQuery → card для sim-element **запрещено**:

- `world.list_joints()`;
- `Piston/Rotor/HingePlacementUtil.find_*_joint_for_element` linear scans;
- `RecipeRunnerService.connected_supply_amount` /
  `connected_cargo_has_path` / `preview_idle_reason_for_recipe`;
- cargo graph walks внутри `IndustryStatusUtil` disambiguation
  (reason берётся из `display_status_reason` на runtime).

Единственный joint lookup на aim/HUD/terminal hot path —
`driven_joint_for_element` (InteractionIndex). `compile_body_groups` /
`driven_specs` остаются для physics multibody, не для aim.

### Structural / Live / Drop (ключи card)

**Structural** (index; патч на topology):

`element_id`, `assembly_id`, `archetype_id`, `control_seat`,
`piston_joint_id` / `rotor_joint_id` / `hinge_joint_id`,
`wheel_element_id`, `suspension_element_id`,
authored/max clamps (`piston_authored_*`, `piston_max_*`, `rotor_max_*`,
`hinge_authored_*`, `hinge_max_*`, `wheel_max_*`, `wheel_authored_max_steering_angle_rad`,
`suspension_min_travel_m`, `suspension_max_travel_m`).

**Live** (O(1) runtime / DisplayPose / industry `display_*`):

`integrity`, `status_reason` (из `display_status_reason` или O(1) structural/disabled),
`machine_enabled`, `actuator_status`, observed/target pose & velocities,
powered/enabled/tune scalars, recipe progress/queue/`active_recipe_id`,
`missing_input_resource_id`, `cargo_network_*` (только из `display_*`),
`wheel_powered`, `wheel_status`, wheel/suspension tune scalars,
`aim_direction` (hit geometry).

**Drop** (не входят в card; не писать с aim):

`shape_index`, `collider_index`, `build_progress`, `state_revision`,
`pending_recipe_id`, `*_base_element_id` / `*_head_element_id` /
`*_top_element_id`, `piston_speed_limit_mps`,
`rotor_observed_velocity_rad_s`, `hinge_observed_velocity_rad_s`,
`wheel_grounded`, `wheel_compression_m`, `wheel_normal_force_n`,
`wheel_slip_speed_mps`, `wheel_authored_drive_torque_n_m`,
`seat_offset_local`, `locomotive`, `flight`, `mobile`
(gateway при enter пересчитывает mobile сам).

Non-sim bypass (loot / electric cable / granular) по-прежнему через
collider `interaction_metadata` — вне InteractionIndex.

### Invalidate / patch / restore

| Событие | Index |
|---|---|
| `_notify_topology_changed(assembly_id > 0)` | invalidate entries этой сборки |
| `_notify_topology_changed(0)` | clear all |
| place / dismantle (mutation site) | точечный patch, если известны ids; иначе lazy rebuild |
| split / merge | invalidate затронутых (часто global clear) + lazy |
| restore / `world_restored` | `clear_interaction_index()` обязателен |
| configure_* / set_machine_enabled | structural index не трогать |
| actuator pose/status change | patch `ActuatorDisplayPose` only |

Lazy rebuild on `get_*`, если stamp ≠ `topology_revision` или entry нет
(как occupancy cache).

### Acceptance (внедрение)

1. Обесточенный стоящий ровер: FPS при прицеле в небо ≈ FPS при прицеле в
   обычный frame (порядок величины; verify в игре).
2. Aim в piston/rotor/hinge **base и head/top** → один и тот же driven joint.
3. Actuator в движении: DisplayPose обновляется ≤ 10 Hz; на STOP — flush;
   idle actuator не пишет pose.
4. place / dismantle / split / restore: joint map и seed позы корректны
   (headless `test_interaction_index`).
5. Construction preview attach к роверу не использует actuator
   `status_reason` как structural deny (существующий фильтр preview).
6. Aim на processor/fabricator без cargo graph на aim path (industry
   `display_*`).

## ToolAction и commands

Состояния action:

```text
idle → pressed → holding → completed
                   |
                   └→ cancelled
```

- tap завершается один раз на press;
- hold публикует progress 0..1;
- удержание ЛКМ буром/болгаркой/сваркой следует live aim: цель в радиусе
  обрабатывается каждый tick, без отдельного клика на блок; потеря цели
  паузит ticks, но не отменяет hold;
- потеря цели, release, spawn lock и vehicle transition отменяют action;
- completed action отправляет ровно одну command;
- непрерывный drill состоит из явно ограниченных command ticks;
- command содержит kind, source, target snapshot и параметры;
- `CommandGateway` применяет команды deferred и возвращает `ActionResult`;
- результат имеет `status` и `reason`.

Минимальные причины: `ok`, `not_ready`, `no_target`, `out_of_range`,
`invalid_target`, `blocked`.

До Simulation Kernel текущие voxel remove и block placement подключаются
compatibility handlers за `CommandGateway`. Это не закрывает Construction v1 и не
делает `PlacedBlocks` авторитетной production-моделью.

## Input

Все gameplay controls находятся в Input Map:

- `move_forward`, `move_back`, `move_left`, `move_right`;
- `jump`, `sprint`;
- `interact`;
- `tool_primary`, `tool_secondary`;
- `toolbar_slot_1` … `toolbar_slot_9` — слот текущей страницы;
- `toolbar_page_prev`, `toolbar_page_next` — переключение страниц (`[` / `]` на macOS);
- `construction_rotate_yaw`, `construction_rotate_pitch`, `construction_rotate_roll`
  — ортогональный поворот preview (`C` / `V` / `B`);
- `release_mouse`;
- `toggle_map` — карта луны (`M`, см. `docs/specs/MAP-UI-01.md`).

Gameplay-код не читает физические keycode или mouse button напрямую.

### Paged toolbar

- Toolbar — 9 слотов на страницу; `1`–`9` выбирают слот **текущей** страницы.
- Стартовая страница 1: слот 1 — бур, 2 — сварка, 3 — болгарка, 4–9 — Slice 01
  construction archetypes (`frame` … `fabricator`).
- Слот **блока** включает placement (`active_tool = build`, preview виден).
- Слоты **бура**, **сварки** и **болгарки** выходят из placement; preview скрыт.
- `tool_primary` (ЛКМ): бур/болгарка — воздействие по цели; блок — установка;
  сварка — сварка каркаса и ремонт повреждённого элемента.
- `tool_secondary` (ПКМ/F): для строительства не используется; у бура включает
  режим выемки породы (см. «Drill excavation routing»), у совка — высыпает груз.

### Orientation

- Поворот preview выполняет `ToolController` шагами ±90° вокруг локальных осей
  yaw/pitch/roll.
- Итоговый `orientation_index` всегда один из 24 `OrientationUtil` ориентаций;
  topology-контракт не меняется.

### Drill command routing

При удержании ЛКМ с выбранным буром:

- цель `voxel` → `voxel_remove` через `CommandGateway`;
- цель `simulation_element` → `DamageElementCommand` (меньший DPS, чем у болгарки);
- terrain request обрабатывает единый `TerrainExcavationService`; звук и VFX
  подтверждают только непустой результат операции;
- cadence continuous action сохраняется (`interval = 0.08`);
- `max_range = 2.5` (`IndustryArchetypeProfile.hand_drill_reach_m`): луч прицела
  стартует от глаз (~1.6–1.65 м над стопами), поэтому земля прямо под игроком
  уже ~1.66 м, а под естественным взглядом вниз — дальше; reach перекрывает
  eye-to-floor плюс рабочую глубину, чтобы бурение под ногами срабатывало
  надёжно и продолжало доставать по мере углубления ямы (болгарка остаётся 2.2);
- урон по блоку за tick: `DRILL_DPS * interval` (настраиваемая константа, v0: 5 integrity/s).

### Drill excavation routing (ПКМ)

При удержании **ПКМ** с выбранным буром — режим выемки породы: убираем материал
активнее, но ничего не добываем (как grind-mode в Space Engineers).

- цель `voxel` / `granular` → `voxel_remove` с параметром `discard_yield = true`;
  порода убирается, но `_route_hand_drill_yield` не вызывается — в стор/лут ничего
  не попадает;
- цель `simulation_element` и прочие — action не выполняется (выемка не ломает
  построенные элементы; это остаётся работой ЛКМ бура/болгарки);
- быстрее mining-tick: `interval = hand_drill.extract_interval_s` (v0: 0.09 против
  0.15 у ЛКМ) и чуть шире bite: `radius = hand_drill.extract_carve_radius_m`
  (v0: 1.35 против 1.0);
- `max_range = 2.5` — тот же `hand_drill_reach_m`, что и у mining-режима;
- continuous, следует live aim, как и удержание ЛКМ буром;
- бит крутится и impact-VFX/звук играют так же, как при ЛКМ.

### Grinder command routing

При удержании ЛКМ с выбранной болгаркой (слот 3):

- цель `simulation_element` → `DamageElementCommand` через `CommandGateway`
  (без прямой мутации projection);
- cadence continuous action (`interval = 0.05`, `max_range = 2.2`);
- урон за tick: `GRINDER_DPS * interval` (настраиваемая константа, v0: 200 integrity/s);
- lethal destruction возвращает `50%` установленных материалов (`GRINDER_REFUND_FRACTION`);
- бур при lethal destruction материалы не возвращает;
- voxel и прочие цели отменяют action.

### Build placement routing

При нажатии ЛКМ с выбранным слотом блока:

- `construction_apply` в режиме `place` через `CommandGateway`;
- single press на валидный preview (`interval = 0.22`,
  `max_range = InteractionQuery.build_max_distance` = 10.0);
- ПКМ/F при выбранном блоке не выполняет действий.

### Welder command routing

При удержании ЛКМ со сварочным пистолетом (слот 2):

- целостность `< 100%` → `weld_element` (continuous, `interval = 0.18`, `max_range = 4.0`);
- `100%` и прочие цели отменяют action.

## Feedback

Игрок всегда может определить:

- текущую страницу и слот toolbar;
- выбранный инструмент или блок (display name archetype);
- запас `construction_component` («компонентов»);
- доступное действие (prompt), кроме режима бура;
- успех, отмену или причину отказа.

Reticle и prompt читают interaction/action state. Continuous drill/weld не
показывают progress bar и не спамят «Готово» на каждый tick; meaningful failure
feedback сохраняется.

Drill pose, spin, sparks и audio читают execution state и не запускаются от одного
наличия hit.

## Benchmark

Отдельная сцена содержит:

- flat run и stop lane;
- slopes 15°, 30°, 45° и 50°;
- steps 0.10, 0.20, 0.30 и 0.40 м;
- low ceiling над допустимым step;
- узкий проход и острый внешний угол;
- край платформы;
- неровный voxel patch;
- линейно и вращательно движущийся `RigidBody3D`.

Benchmark служит ручным полигоном и источником deterministic headless fixtures.

## Automated acceptance

Headless-тесты обязаны проверить:

1. acceleration, speed cap, diagonal normalization и stop time;
2. jump apex и воздушное ускорение при gravity 1.62;
3. прохождение steps до 0.30 м и отказ на 0.40 м;
4. walkable 45° и отказ считать 50° floor;
5. отсутствие wall climb и penetration под low ceiling;
6. отсутствие NaN и неконтролируемой скорости;
7. moving-platform regression PoC-3;
8. query для physics, voxel и empty target;
9. cancel/complete hold action;
10. ровно одну command на completion;
11. запрет прямой world mutation из tool/presentation scripts;
12. paged toolbar: drill/grinder gate demolition primary, block slot gates placement
    on primary;
13. yaw/pitch/roll rotation остаётся в `OrientationUtil` диапазоне.

Новый production test печатает `PLAYER1: PASS`; test runner принимает этот token
наряду с существующими `POC*: PASS`.

## Manual acceptance

Обязательная совместная feel-сессия не менее 15 минут:

- benchmark и main yard при 30, 60 и 144 render FPS;
- voxel terrain, slopes, steps и края;
- стояние, ходьба и прыжок на cart во время разгона и поворота;
- drill, placement и cockpit interaction;
- изменение sensitivity и FOV.

Блокирующие дефекты: camera jitter, snagging, непреднамеренное скольжение, wall
climb, потеря aim target, двойное выполнение action или необходимость бороться с
разгоном/остановкой.

## Не входит

- crouch, prone и mantle;
- inventory, hotbar и смена экипировки;
- production-сварка и ремонт;
- frame placement и bill of materials;
- stamina;
- лестницы и zero-g locomotion;
- gamepad aim assist;
- финальные анимации рук.
