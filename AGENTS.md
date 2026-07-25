# Regolith — AI-first lunar sandbox (Godot)

Standalone Godot 4.8 проект: voxel terrain (Voxel Tools 1.6x), Jolt 5.6
(гравитация 1.62 m/s²), GDScript. Код в `scripts/`, сцены в `scenes/`,
ресурсы в `resources/`. Концепт: `docs/CONCEPT.md`.
Этот файл — единственный источник процессных правил для агентов.

Rule 1 - отвечай коротко, по делу и понятным языком

## Доменный контракт

`docs/PHYSICAL-LANGUAGE.md` — большой. НЕ читай его целиком: в начале файла
есть индекс терминов — найди нужный раздел и читай только его.

Сборка ровера по фразе («N колёс», длинный/короткий/…): сначала
`docs/cheatsheets/rover-compose.md` и skill `rover-compose` — не угадывать
клетки вручную.

Сборка actuator-rig по фразе («буровой манипулятор», reach/wrist): сначала
`docs/cheatsheets/machine-compose.md` и skill `machine-compose` — не угадывать
клетки вручную.

Задачи на kernel/runtime/`SimulationWorld`: сначала
`docs/cheatsheets/simulation-world.md` — не читать монолит целиком.

Баланс (стоимость/масса блоков, items, recipes, буры, актуаторы, electric):
`resources/balance/game_balance.json` + `docs/cheatsheets/game-balance.md` —
не размазывать числа по GDScript-константам.

Операция анти-godobject (механическая нарезка монолитов): контракт заморозки —
`docs/plans/ANTIGOD-CONTRACT-FREEZE.md`. Cheatsheet'ы волны —
`docs/cheatsheets/world-command-gateway.md`, `physics-projection.md`,
`control-terminal.md`, `bootstrap.md` (появятся по мере extract'ов).
Поведение не менять.

Задачи на bootstrap / spawn / terrain streaming / coop persistence: сначала
`docs/cheatsheets/bootstrap.md` — не читать монолит целиком.

## Инварианты (нарушать НЕЛЬЗЯ)

- **R1** — новые типы машин/элементов сначала в `PHYSICAL-LANGUAGE.md` или
  PoC-спеке (`docs/specs/`), потом код.
- **R2** — headless-тесты (`scenes/test_*.tscn`) — ТОЛЬКО для чистой логики
  симуляции: kernel, топология, графы, ресурсы, проекция. НЕ создавать
  тест-сцены для геймплея, интеракций, HUD, презентации — этот слой
  верифицируется в запущенной игре (см. «Верификация»).
- **R3** — шейдеры только текстом (`.gdshader`), VisualShader-графы не создавать.
  Шпаргалка: `docs/cheatsheets/godot-shaders.md`.
- **R4** — VFX-композиции декларативные (`.tscn` без логики в `scenes/vfx/`).
  Шпаргалки: `docs/cheatsheets/vfx-design.md`, `vfx-authoring.md`.
- **R5** — spawn на voxel terrain: SDF + physics collider + settle (см.
  `bootstrap.gd`); не телепортировать игрока на y=0 до готовности коллизии.
- **R6** — внешние зависимости: Voxel Tools (MIT) и Ropes! (см. R10); macOS
  binaries в git, остальные платформы — bootstrap из README.
- **R10** — `addons/ropes/` — **чужой код, заходить нельзя.** Плагин Ropes!
  живёт в отдельном репозитории `Y:\ropes` и смонтирован сюда junction'ом:
  гит Regolith его не видит, правка «по-быстрому здесь» молча уедет в чужой
  репозиторий и не покажется в `git status`. Не читать, не править, не
  коммитить. Баг в верёвках — задача в `Y:\ropes`. Со стороны игры трогать
  можно только фасад `scripts/simulation/projection/xpbd_cable_rope_solver.gd`
  и адаптеры бенча; их API — `docs/cheatsheets/ropes-seam.md`, открывать
  плагин для этого не нужно.
- **R7** — задачи с voxel terrain / SDF / `VoxelTool` / scale / collider /
  streaming: сначала `docs/cheatsheets/voxel-tools.md` и § *Voxel scale* в
  `docs/specs/INDUSTRY-V1.md`, затем **официальная дока** и **GitHub issues**
  плагина (Zylann). Не выводить API координат из кода проекта; верифицировать
  aim/spawn/бур в запущенной игре.
- **R8** — задачи с физикой / Jolt / `RigidBody3D` / joints / constraints /
  physics projection / simulation boundary: сначала `docs/PHYSICAL-LANGUAGE.md`
  («Граница владения») и релевантная PoC-спека (`docs/specs/`), затем
  **официальная дока Godot** ([Using Jolt Physics](https://docs.godotengine.org/en/stable/tutorials/physics/using_jolt_physics.html),
  [Physics introduction](https://docs.godotengine.org/en/stable/tutorials/physics/physics_introduction.html))
  и **веб-поиск** по конкретному поведению (встроенный Jolt 5.6 в Godot 4.8,
  не legacy extension `godot-jolt`; при необходимости — [JoltPhysics](https://jrouwe.github.io/JoltPhysics/),
  GitHub issues Godot/Jolt). Не выводить семантику движка из кода проекта.

- **R9** — перф в `_process`/`_physics_process`. GDScript медленный и тик
  ничем не ограничен, поэтому дефолтная ошибка — тяжёлая работа каждый кадр.
  Три правила: (а) реагируй на изменения сигналом/событием, не опросом каждый
  тик; (б) производное держи в кэше и инвалидируй по dirty-флагу/ревизии
  (`topology_revision` и т.п.), не пересчитывай; (в) UI-действие трогает свой
  объект, а не пересчёт по всему миру (см. регресс «сел в кабину 200→30»).
  Длинные проходы — бюджет/стаггер. **Без перегиба:** не оптимизируй холодный
  код и не усложняй ради гипотез — сначала замерь (perf-монитор / профайлер),
  оптимизируй только горячее.

Если задача «удобнее» решается нарушением инварианта — остановись и спроси человека.

## Верификация

Главный верификатор — запущенная игра, не зелёный тест.

- **Логика ядра** — `./tests/run_one.sh test_<name>` (вывод уже отфильтрован
  от движкового шума). Итерируйся на одном релевантном тесте. Не ждать
  зависший Godot: `run_one.sh` убивает сцену через 20s и сразу при
  `SCRIPT ERROR` / `Parse Error`; сцены сами вызывают
  `_HeadlessTestHarness.arm_watchdog` (`scripts/testing/headless_test_harness.gd`).
- **Геймплей / HUD / презентация / VFX** — перед проверкой через Beckett:
  `load_skill name=regolith-loop`. Затем `play_scene` → wait settle
  (`is_world_ready`) → `screenshot`, `get_remote_tree`, `game_logs`;
  убедись что видно и в логах чисто. Финальное подтверждение — человек
  в игре; «тест зелёный» не считается доказательством, что фича работает.
- **Полный гейт** — `./tests/run_tests.sh` (ядровый набор) ОДИН раз перед
  «готово»/коммитом **только если** менялась логика симуляционного ядра
  (или тест/инвариант ядра). Иначе не гонять. Не на каждую правку.

## Definition of Done

| Тип изменения | Обязательные действия |
|---|---|
| логика симуляционного ядра | релевантный `run_one.sh` зелёный; новый инвариант ядра → новый тест + строка в `run_tests.sh` |
| геймплей / интеракции / HUD / презентация | проверка в запущенной игре (скриншот/логи), человек подтверждает |
| изменение поведения / новый PoC | обновить спеку в `docs/specs/` или `PHYSICAL-LANGUAGE.md` |
| правка `.gdshader` | `./run.sh --headless res://scenes/main.tscn` без ошибок компиляции |
| правка VFX `.tscn` | проверка в игре + соответствие `docs/cheatsheets/vfx-*.md` |
| voxel terrain / SDF / raycast / scale | `docs/cheatsheets/voxel-tools.md` + сверка с докой плагина; проверка в игре (spawn, aim, drill) |
| физика / Jolt / projection / constraints | `PHYSICAL-LANGUAGE.md` («Граница владения») + релевантная спека; сверка с [докой Godot Jolt](https://docs.godotengine.org/en/stable/tutorials/physics/using_jolt_physics.html) и веб-поиском |
| новая GDExtension-зависимость | строка в README (bootstrap) + лицензия |
| поведение верёвок/кабелей изменилось со стороны плагина | правка и её проверка — в репозитории `Y:\ropes` (`bash addons/ropes/tests/run_tests.sh`); здесь — сверить фасад по `docs/cheatsheets/ropes-seam.md` и посмотреть кабель в игре |
| перед «готово»/коммитом | полный `./tests/run_tests.sh` — только если трогали ядро (см. «Верификация»); иначе по типу изменения выше |

## Субагенты и экономия токенов

- Механические подзадачи — разведка кодовой базы, поиск, чтение/суммаризация
  логов и вывода тестов, массовые однотипные правки — выноси в субагентов,
  и если среда позволяет выбрать модель, запускай их на дешёвой быстрой
  модели (в Cursor — `composer-2.5-fast`).
- НЕ отдавать дешёвой модели: проектные решения, правки симуляционного ядра,
  нетривиальный дебаг, финальное ревью — переделка съедает экономию.
- Результат субагента проверяй по существу, как любой внешний ввод.

## Дисциплина коммитов

- Один коммит = одно проверяемое изменение. Не копи гигантские diff'ы:
  большой незакоммиченный контекст — главный убийца качества агентских сессий.
- Спека и код — в одном коммите, если меняют контракт.
- Коммиты только по запросу человека.

## Соглашения

- Терминология (element, assembly, structural command, …) — индекс в
  `PHYSICAL-LANGUAGE.md`.
- Input actions (`move_forward`, `jump`, …) — в `project.godot`, не хардкод.
- Минимальный diff, без over-engineering.

## Команды

```bash
./run.sh res://scenes/main.tscn      # игра (planetoid Ø1 km, default)
./run.sh res://scenes/flat_moon.tscn # legacy flat yard
./run.sh --editor                    # редактор
./run.sh --headless --import         # первый запуск / reimport
./tests/run_one.sh test_<name>       # один тест, шум отфильтрован
./tests/run_tests.sh                 # ядровый гейт (только если трогали ядро)
./tests/run_tests.sh --all           # + legacy геймплей-сцены (медленно)
```

## Cursor Cloud / headless VM

Нюансы облачного окружения (нет GPU/звука, дисплей :1, quit-after для smoke,
ограничения computer-use) — `docs/AGENTS-CLOUD.md`. Читай только при работе
в облачной VM.
