# Regolith

First-person lunar engineering sandbox on **stock Godot 4.5+** + [Voxel Tools 1.6 GDExtension](https://github.com/Zylann/godot_voxel/releases/tag/v1.6x) + **Jolt Physics** (gravity 1.62 m/s²).

Бурить SDF-реголит, собирать роверы из модулей, перестраивать их на ходу, ездить стоя на платформе. PoC 1–3 закрыты headless-тестами.

Питч и roadmap: [`docs/CONCEPT.md`](docs/CONCEPT.md). Доменный контракт: [`docs/PHYSICAL-LANGUAGE.md`](docs/PHYSICAL-LANGUAGE.md). Правила для агентов: [`AGENTS.md`](AGENTS.md). Шпаргалки: [`docs/cheatsheets/`](docs/cheatsheets/).

## Запуск

```bash
cd ~/Desktop/regolith
chmod +x run.sh tests/run_tests.sh
./run.sh res://scenes/main.tscn
```

Редактор:

```bash
./run.sh --editor
```

`run.sh` ищет stock Godot в `/Applications/Godot.app`, `$GODOT` или `PATH`.

После клонирования (один раз, пока нет `.godot/`):

```bash
./run.sh --headless --import
```

## Тесты

```bash
./tests/run_tests.sh                 # ядровый гейт (чистая логика симуляции)
./tests/run_one.sh test_<name>       # один тест, движковый шум отфильтрован
./tests/run_tests.sh --all           # + legacy геймплей/физика-сцены (медленно)
```

Гейт покрывает только симуляционное ядро; геймплей/HUD/презентация
верифицируются в запущенной игре (см. `AGENTS.md`, раздел «Верификация»).
Exit 0 только если все PASS.

## Bootstrap GDExtension (не-macOS)

macOS binaries уже в репо. На других платформах — один раз:

```bash
mkdir -p bin
curl -L -o bin/GodotVoxelExtension.zip \
  https://github.com/Zylann/godot_voxel/releases/download/v1.6x/GodotVoxelExtension.zip
unzip -o bin/GodotVoxelExtension.zip -d .
```

Распаковывает `addons/zylann.voxel/` в корень проекта.

### Moon heightmap bake (`regolith_moon_bake`)

C++ GDExtension для быстрого бейка `crust_heightmap.exr` (MIT FastNoiseLite +
godot-cpp). macOS `template_debug` binary в `addons/regolith_moon_bake/bin/`.

Пересборка (нужен слинкованный `native/godot-cpp` → Erebus `thirdparty/godot-cpp`
с готовым `.a`):

```bash
./native/build_moon_bake.sh
```

После клона, если Godot не видит класс `MoonHeightmapBake`:

```bash
./run.sh --headless --import
```

## Управление

| Клавиша | Действие |
|---------|----------|
| WASD | ходьба |
| Shift | бег |
| Space | прыжок |
| ЛКМ (зажать) | бурить |
| ПКМ | поставить блок |
| E у корабля | кокпит |
| В кокпите: Space | тяга |
| В кокпите: WASD | баланс |
| В кокпите: E | выйти |
| Тележка: ↑ | привод |
| Тележка: ↓ | тормоз |
| Тележка: ←/→ | руль |
| K | толкнуть тележку |
| B / N | снять / вернуть центр ровера |
| V | сломать мост |
| M | снять колесо |
| J / H | оторвать / приварить блок сборки |
| Esc | отпустить мышь |
| R | снова захватить мышь |

## Структура

| Путь | Назначение |
|------|------------|
| `scenes/main.tscn` | planetoid Ø1 km: LodTerrain, radial gravity, dig persistence |
| `scenes/flat_moon.tscn` | legacy flat yard (infinite noise terrain) |
| `scripts/bootstrap.gd` | planetoid spawn gate (SDF + physics collider + settle) |
| `scripts/flat_moon_bootstrap.gd` | legacy flat yard bootstrap |
| `scripts/drill.gd` | SDF `MODE_REMOVE do_sphere()` |
| `addons/zylann.voxel/` | Voxel Tools GDExtension (macOS in git) |
| `docs/specs/POC-*.md` | acceptance criteria PoC 1–3 |
| `docs/cheatsheets/` | Godot shaders, VFX design, `.tscn` authoring |
| `tests/run_tests.sh` | headless gate |

## Erebus

Замороженный порт R0/R1 в репозитории Erebus (`games/regolith/`). Основная разработка демо — здесь; возврат в движок — через addon, когда контент data-driven.
