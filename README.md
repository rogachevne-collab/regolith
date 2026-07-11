# Regolith

First-person lunar engineering sandbox on **stock Godot 4.5+** + [Voxel Tools 1.6 GDExtension](https://github.com/Zylann/godot_voxel/releases/tag/v1.6x) + **Jolt Physics** (gravity 1.62 m/s²).

Бурить SDF-реголит, собирать роверы из модулей, перестраивать их на ходу, ездить стоя на платформе. PoC 1–3 закрыты headless-тестами.

Питч и roadmap: [`docs/CONCEPT.md`](docs/CONCEPT.md). Доменный контракт: [`docs/PHYSICAL-LANGUAGE.md`](docs/PHYSICAL-LANGUAGE.md). Шпаргалки для шейдеров и VFX: [`docs/cheatsheets/`](docs/cheatsheets/).

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
./tests/run_tests.sh
```

Прогоняет все `scenes/test_*.tscn` headless (PoC 1a–1c, 2, 3). Exit 0 только если все PASS.

## Bootstrap GDExtension (не-macOS)

macOS binaries уже в репо. На других платформах — один раз:

```bash
mkdir -p bin
curl -L -o bin/GodotVoxelExtension.zip \
  https://github.com/Zylann/godot_voxel/releases/download/v1.6x/GodotVoxelExtension.zip
unzip -o bin/GodotVoxelExtension.zip -d .
```

Распаковывает `addons/zylann.voxel/` в корень проекта.

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
| `scenes/main.tscn` | yard: terrain, player, cart, rover, launch vehicle |
| `scripts/bootstrap.gd` | spawn gate (SDF + physics collider + settle) |
| `scripts/drill.gd` | SDF `MODE_REMOVE do_sphere()` |
| `addons/zylann.voxel/` | Voxel Tools GDExtension (macOS in git) |
| `docs/specs/POC-*.md` | acceptance criteria PoC 1–3 |
| `tests/run_tests.sh` | headless gate |

## Erebus

Замороженный порт R0/R1 в репозитории Erebus (`games/regolith/`). Основная разработка демо — здесь; возврат в движок — через addon, когда контент data-driven.
