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
4. **Строительство и промышленность** — мобильные и стационарные конструкции,
   переработка ресурсов, крафт, повреждение и ремонт используют один язык.

## Core loop

```text
добыть → доставить → переработать → изготовить → построить/починить
                                                            |
                                                            └→ расширить производство
```

Игрок начинает с ручных инструментов и небольшой площадки, строит закреплённые
`Assembly`, запускает добычу и переработку, а затем расширяет производство машинами
и автоматикой. Ровер — один из способов транспортировки; стационарный бур, база,
кран и мобильная техника состоят из тех же элементов, портов и сетей.

Первая production-цель — не максимальное число систем, а короткий законченный цикл:
поставить каркасы базовых блоков, заварить их, запитать стационарную добычу,
переработать сырьё, изготовить компонент и использовать его для расширения или
ремонта базы.

## Закрытые PoC

| Этап | Содержание | Критерий |
|------|------------|----------|
| PoC 1a ✓ | подвеска на 1.62 m/s² | `test_cart_flat.tscn` |
| PoC 1b ✓ | привод и тормоз | `test_cart_drive.tscn` |
| PoC 1c ✓ | руль и занос | `test_cart_steering.tscn` |
| PoC 2 ✓ | live structural rebuild | `test_assembly.tscn`, `test_cart_rebuild.tscn`, `test_wheel_detach.tscn` |
| PoC 3 ✓ | пассажир на moving grid | `test_passenger.tscn` |

Все PoC 1–3 закрыты headless-тестами: `tests/run_tests.sh`.

## Production roadmap

Дальнейшая разработка идёт вертикальными milestone, а не изолированными PoC.
Критерии первого slice описаны в
[`specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md`](specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md).

1. **Player & Interaction v1.** Приятный first-person controller, движущиеся
   платформы, единый interaction query, удерживаемые действия инструментов и
   читаемая обратная связь. Критерии:
   [`specs/PLAYER-INTERACTION-V1.md`](specs/PLAYER-INTERACTION-V1.md).
2. **Simulation Kernel v0.** Общие `Assembly`, `Element`, `Anchor`, `Blueprint` и
   physics projection для базы и машин; без отдельных правил для каждого класса
   конструкции.
3. **Construction v1.** Placement каркаса, расход компонентов, сварка, повреждение,
   ремонт и демонтаж через структурные команды.
4. **Industry v1.** Минимальные electric/cargo networks, стационарная добыча,
   хранилище, переработка и одна производственная цепочка.
5. **Industrial Base Slice.** Законченный core loop в игровом окружении с
   production-качеством управления, взаимодействия и диагностики.
6. **После slice.** Логистика, новые рецепты и материалы, краны и actuators,
   автоматизация, более сложные машины, герметичность и атмосферы.

Production-качество вводится по границам slice: входящие в него системы получают
финальные UX, audiovisual feedback, диагностику и regression-проверки; системы за
границей не полируются заранее.

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
