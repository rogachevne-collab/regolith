# Machine Compose v0

Статус: implementation contract для агентской сборки actuator-rig по фразе.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md`;
- `docs/specs/POC-ACTUATORS-V1.md` (Piston);
- `docs/specs/POC-ACTUATORS-V2-ROTOR.md` (Rotor);
- `docs/specs/POC-ACTUATORS-V3-HINGE.md` (Hinge / ServoHinge);
- `docs/specs/INDUSTRY-V1.md`;
- `docs/cheatsheets/rover-compose.md` (паттерн Intent/Composer/Validator).

## Цель

Агент собирает named machine (rig) по короткой фразе за ~60s без ручного
подбора клеток — тем же контрактом, что RoverCompose:

- фраза / dict → `MachineIntent`;
- `MachineComposer` владеет клетками и topology;
- `MachineValidator` — machine-readable oracles;
- `AssemblyBuildHelper` — place/weld/connect.

## Нормативные решения

1. Intent — **каталог рецептов** + лёгкие ручки, не свободный граф actuators.
2. Driven chain на path к root ≤ 4 (общий лимит actuators).
3. Клетки и orientation_index пишет только composer.
4. Failures чинятся через intent, не через `Vector3i`.
5. Новые рецепты добавляются спекой + веткой `_place_<recipe>`, не ad-hoc
   place в skill.

## Границы v0

### Входит

- рецепт `drill_arm`: foundation + power + rotor → hinge → piston →
  stationary_drill (+ optional wrist hinge);
- ручки `reach` (short/normal/long) и `wrist` (bool);
- `compose` / `compose_from_phrase` / `spawn_on_terrain*`;
- headless `test_machine_compose`;
- cheatsheet + skill для агентов;
- optional bootstrap `@export demo_machine_phrase` (default off).

### Не входит

- свободный DSL клеток / произвольный actuator graph;
- programmable bindings / авто-цикл бурения;
- каталог из многих рецептов (карусель, кран, двери) — следующие PoC;
- merge двух Assembly через joint.

## MachineIntent

```text
recipe   drill_arm          (v0: единственный)
reach    short|normal|long  (число boom frames: 0|1|2)
wrist    bool               (второй hinge на tip; chain ровно 4)
```

Phrase tags (RU/EN): «буровой манипулятор», «буровая стрела», «бур»,
«длинн»/long, «коротк»/short, «запясть»/wrist.

`unsupported_reason()` отвергает неизвестный recipe и невалидные enum.

## Рецепт drill_arm

Home pose — yaw-турель и **горизонтальная** стрела вдоль −X (питание на +X).

`stationary_drill` — напольный 2×2×2 / 180 kg; на tip вешать нельзя (отрыв +
kinetic). В v0 бур стоит на pad, tip — лёгкий frame.

```text
foundation (anchor)
power_source + distributor  # +X
stationary_drill            # на pad (+Z), не на стреле
rotor → mast → hinge → boom×reach → piston → [wrist] → tip frame
```

После compose все actuators в STOP; soft demo tuning (piston ~800 N /
0.05 m/s, angular ~500 N·m / 0.25 rad/s) — stock 30 kN на лёгком tip
даёт осцилляцию и kinetic crater. `spawn_demo_machine` в bootstrap
default off.

Electric: `power_source.power_out` → `power_in` ротора, hinge, piston, drill
(и wrist hinge при наличии).

## API

```gdscript
MachineComposer.compose(world, intent, grid_frame?, store_id?) -> Dictionary
MachineComposer.compose_from_phrase(world, phrase, ...) -> Dictionary
MachineComposer.spawn_on_terrain(session, world_position, intent, ...) -> Dictionary
MachineComposer.spawn_on_terrain_from_phrase(session, pos, phrase, ...) -> Dictionary
MachineValidator.validate(world, assembly_id, intent?) -> Dictionary
```

Успех: `{ok:true, assembly_id, element_ids, intent, validate}`.  
Провал: `{ok:false, error, failures?}`.

Spawn на terrain **не** снимает foundation anchor (в отличие от ровера).

## Validator oracles

- есть foundation, power_source, stationary_drill;
- ровно 1 rotor + 1 boom-hinge + 1 piston;
- wrist ⇒ ровно 2 hinge total, иначе 1;
- driven joints ≤ 4, все `is_driven()` на assembly;
- drill на tip branch (не в root body group с foundation).

## Тесты

`scenes/test_machine_compose.tscn` в ядровом гейте:

1. phrase defaults / long / wrist;
2. compose normal drill_arm;
3. compose long reach → больше frames, 3 driven;
4. compose wrist → 4 driven;
5. unsupported recipe;
6. validator negative (сборка без drill).

## Acceptance

1. `./tests/run_one.sh test_machine_compose` зелёный.
2. Полный `./tests/run_tests.sh` зелёный.
3. Фраза «буровой манипулятор» собирает working topology в headless.
4. Gameplay (опционально): `spawn_demo_machine=true` в bootstrap — человек
   крутит rotor/hinge/piston у BaseSpawn.
