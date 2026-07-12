# Regolith — AI-first lunar sandbox (Godot)

Standalone Godot-проект: voxel terrain, Jolt physics, modular machines.
Концепт: `docs/CONCEPT.md`. Доменный контракт: `docs/PHYSICAL-LANGUAGE.md`.
Этот файл — единственный источник процессных правил для агентов.

## Стек

- **Godot 4.5+** — stock editor/runtime, без форка.
- **Jolt Physics** — гравитация 1.62 m/s² (`project.godot`).
- **Voxel Tools 1.6x** (zylann GDExtension) — SDF terrain, Transvoxel.
- **GDScript** — геймплей в `scripts/`, сцены в `scenes/`, ресурсы в `resources/`.

## Инварианты (нарушать НЕЛЬЗЯ)

- **R1** — `docs/PHYSICAL-LANGUAGE.md` описывает домен; новые типы машин/элементов
  сначала в контракте или PoC-спеке, потом код.
- **R2** — PoC закрывается headless-тестом в `scenes/test_*.tscn` + строка в
  `tests/run_tests.sh` (если новый тест).
- **R3** — шейдеры только текстом (`.gdshader`); VisualShader-графы не создавать.
  Шпаргалка: `docs/cheatsheets/godot-shaders.md`.
- **R4** — VFX-композиции декларативные (`.tscn` без логики в `scenes/vfx/`).
  Шпаргалки: `docs/cheatsheets/vfx-design.md`, `vfx-authoring.md`.
- **R5** — spawn на voxel terrain: SDF + physics collider + settle (см. `bootstrap.gd`);
  не телепортировать игрока на y=0 до готовности коллизии.
- **R6** — внешние зависимости: только Voxel Tools (MIT); macOS binaries в git,
  остальные платформы — bootstrap из README.

Если задача «удобнее» решается нарушением инварианта — остановись и спроси человека.

## Definition of Done

**Дисциплина тестов:** во время итераций гоняй только релевантный `test_*.tscn`
(`./run.sh --headless res://scenes/test_*.tscn`). Полный `./tests/run_tests.sh` —
один раз перед «готово»/коммитом, а не после каждой мелкой правки.

| Тип изменения | Обязательные действия |
|---|---|
| новый PoC / изменение поведения | обновить `docs/specs/POC-*.md` или `PHYSICAL-LANGUAGE.md` |
| новый/изменённый `test_*.tscn` | релевантный тест зелёный в процессе; полный `./tests/run_tests.sh` один раз перед готово |
| правка `.gdshader` | `./run.sh --headless res://scenes/main.tscn` без ошибок компиляции |
| правка VFX `.tscn` | проверка в игре + соответствие `docs/cheatsheets/vfx-*.md` |
| новая GDExtension-зависимость | строка в README (bootstrap) + лицензия |
| правка spawn/drill/cart/assembly | релевантный `test_*` в процессе; полный `./tests/run_tests.sh` + smoke `main.tscn` один раз перед готово |

## Дисциплина коммитов

- Один коммит = одно проверяемое изменение.
- PoC-спека и код — в одном PR/коммите, если меняют контракт.
- Коммиты только по запросу человека.

## Делегирование субагентам

Дешёвому субагенту: шейдеры по спеке, headless-тесты, доки по шаблону, мелкие правки
параметров (бур, cart) с готовым критерием PASS.

Дорогому агенту: Physical Language, structural commands, новые PoC, spawn/physics,
архитектурные решения, финальная проверка субагентов.

Результат субагента перечитывается; во время работы — фокусный `test_*`, полный
`./tests/run_tests.sh` один раз перед «готово». Не гоняй полный набор на каждую итерацию.

## Соглашения

- **Терминология:** element, assembly, structural command, platform velocity — см.
  `PHYSICAL-LANGUAGE.md`.
- **Шейдеры:** `docs/cheatsheets/godot-shaders.md`.
- **VFX:** anticipation → burst → dissipate; бюджеты в `vfx-design.md`.
- **Input actions:** `move_forward`, `jump` и т.д. — в `project.godot`, не хардкод
  без причины.

## Команды

```bash
./run.sh res://scenes/main.tscn          # игра
./run.sh --editor                        # редактор
./run.sh --headless --import             # первый запуск / reimport
./tests/run_tests.sh                     # все PoC-тесты headless
```

## Раскладка

```
scenes/           main.tscn, test_*.tscn, vfx/ (будущее)
scripts/          gameplay, bootstrap, motor, drill, cart, assembly
resources/        terrain, textures, shaders, audio
addons/zylann.voxel/   GDExtension (macOS in git)
docs/             CONCEPT, PHYSICAL-LANGUAGE, specs/, cheatsheets/
tests/            run_tests.sh
```

## Текущее состояние

**PoC 1–3 ✓** — cart 1a–1c, structural rebuild, passenger. Все 7 headless-тестов зелёные.
**PoC 4+** — actuators, electric network, cargo, atmospheres (см. CONCEPT roadmap).

Erebus-порт R0/R1 заморожен в репозитории Erebus; целевая интеграция — Erebus Lite addon.
