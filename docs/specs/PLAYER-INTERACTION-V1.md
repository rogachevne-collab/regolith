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
  источником** (position + basis из одного `global_transform`): yaw
  применяется сразу в input, а смешение interpolated position с raw basis
  давало rotation jitter на неровном voxel ground; при
  `physics_interpolation_mode = OFF` у игрока используется
  `global_transform`, не `get_global_transform_interpolated()`;
- mouse delta применяется без зависимости от render FPS;
- pitch ограничен, roll отсутствует без отдельного эффекта;
- procedural bob/sway воздействует только на visual rig и имеет малую амплитуду;
- interaction ray использует согласованную aim pose и не дрожит из-за camera bob;
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
  metadata
}
```

Правила:

- origin и direction задаются aim pose камеры;
- player RID исключается;
- physics collider проверяется первым, voxel SDF — fallback;
- query хранит hit независимо от активного инструмента;
- инструмент применяет собственный `max_range` к готовому hit;
- пустой результат представлен явно, не `null`-словарём;
- presentation может читать hit, но не менять его.

Минимальные `target_kind`: `none`, `voxel`, `body`, `placed_block`,
`control_seat`.

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
- `release_mouse`.

Gameplay-код не читает физические keycode или mouse button напрямую.

### Paged toolbar

- Toolbar — 9 слотов на страницу; `1`–`9` выбирают слот **текущей** страницы.
- Стартовая страница 1: слот 1 — бур, 2 — сварка, 3 — болгарка, 4–9 — Slice 01
  construction archetypes (`frame` … `fabricator`).
- Слот **блока** включает placement (`active_tool = build`, preview виден).
- Слоты **бура**, **сварки** и **болгарки** выходят из placement; preview скрыт.
- `tool_primary` (ЛКМ): бур/болгарка — воздействие по цели; блок — установка;
  сварка — сварка каркаса и ремонт повреждённого элемента.
- `tool_secondary` (ПКМ/F): в v1 не используется для строительства.

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
- `max_range = 3.2` (`IndustryArchetypeProfile.hand_drill_reach_m`): луч прицела
  стартует от глаз (~1.6–1.65 м над стопами), поэтому земля прямо под игроком
  уже ~1.66 м, а под естественным взглядом вниз — дальше; reach перекрывает
  eye-to-floor плюс рабочую глубину, чтобы бурение под ногами срабатывало
  надёжно и продолжало доставать по мере углубления ямы (болгарка остаётся 2.2);
- урон по блоку за tick: `DRILL_DPS * interval` (настраиваемая константа, v0: 5 integrity/s).

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
- single press на валидный preview (`interval = 0.22`, `max_range = 4.0`);
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
