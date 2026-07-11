# Regolith — lunar engineering sandbox

> Standalone Godot project. Доменный контракт: `docs/PHYSICAL-LANGUAGE.md`.
> PoC acceptance: `docs/specs/POC-*.md`.

## Питч

First-person sandbox на луне: бурить реголит, собирать и перестраивать технику из
модульных элементов, ездить на честной физике (Jolt), ходить по движущимся платформам.
Один **Physical Language** описывает ровер, бур, базу, кран и сети — различия из
композиции, не из отдельного кода на каждый вид машины.

**Формула: Space Engineers (машины + voxel) + immersive sim (системное устройство)
+ лунная инженерная фантазия.**

| Референс | Что берём | Что НЕ берём |
|---|---|---|
| Space Engineers | voxel terrain, modular grids, driving, structural rebuild | multiplayer MMO, block spam at scale |
| Kerbal / lunar sim | честная гравитация 1.62, инженерный loop | орбитальная механика как ядро v0 |
| System Shock / immersive sim | объекты = граф элементов и сетей | хоррор, FPS-бой как фокус |

## Сеттинг

Лунная поверхность, industrial outpost yard. Лор минимален: ты инженер на
реголитной площадке, инструменты и техника собираются из элементов.

## Столпы

1. **Voxel world** — SDF/transvoxel terrain, edit через бур и placement.
2. **Physical assemblies** — structure commands, live rebuild, Jolt bodies.
3. **First-person presence** — walk, drill in hand, ride moving machines (PoC-3).
4. **Modular machines** — rover first; crane, base, networks — позже по лестнице
   `docs/PHYSICAL-LANGUAGE.md`.

## Roadmap песочницы

| Этап | Содержание | Критерий |
|------|------------|----------|
| PoC 1a ✓ | подвеска на 1.62 m/s² | `test_cart_flat.tscn` |
| PoC 1b ✓ | привод и тормоз | `test_cart_drive.tscn` |
| PoC 1c ✓ | руль и занос | `test_cart_steering.tscn` |
| PoC 2 ✓ | live structural rebuild | `test_assembly.tscn`, `test_cart_rebuild.tscn`, `test_wheel_detach.tscn` |
| PoC 3 ✓ | пассажир на moving grid | `test_passenger.tscn` |
| PoC 4 | актuators, electric network | TBD |
| PoC 5 | cargo flow | TBD |
| PoC 6 | герметичность / atmospheres | TBD |

Все PoC 1–3 закрыты headless-тестами: `tests/run_tests.sh`.

## Запуск

```bash
cd ~/Desktop/regolith
./run.sh res://scenes/main.tscn
```

Редактор:

```bash
./run.sh --editor
```

## Erebus

Замороженный порт R0/R1 живёт в [Erebus](https://github.com/) (`games/regolith/`).
Целевая интеграция — **Erebus Lite addon** (flecs GDExtension + validator + mirror),
когда контент станет data-driven. До тех пор основная разработка — в этом репо.

## Связанные документы

- `docs/PHYSICAL-LANGUAGE.md`
- `docs/specs/POC-*.md`
- `docs/cheatsheets/godot-shaders.md` — синтаксис `.gdshader` для агентов
- `docs/cheatsheets/vfx-design.md` — ритм, силуэт, бюджеты эффектов
- `docs/cheatsheets/vfx-authoring.md` — декларативные VFX-сцены
