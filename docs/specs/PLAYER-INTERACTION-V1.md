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
- capsule и cylinder сравниваются на Jolt в одинаковом benchmark;
- итоговая shape выбирается по snagging, floor stability, step handling, head
  clearance и regression PoC-3;
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
- top-level camera в `_process` следует за
  `get_global_transform_interpolated()` target;
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
- `release_mouse`.

Gameplay-код не читает физические keycode или mouse button напрямую.

## Feedback

Игрок всегда может определить:

- текущую цель;
- доступное действие;
- допустимо ли оно;
- progress удерживаемого действия;
- успех, отмену или причину отказа.

Reticle, prompt и progress читают interaction/action state. Drill pose, spin, sparks
и audio читают execution state и не запускаются от одного наличия hit.

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
11. запрет прямой world mutation из tool/presentation scripts.

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
