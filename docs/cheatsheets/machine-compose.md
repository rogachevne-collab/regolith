# Machine compose — шпаргалка для агентов

Собрать actuator-rig по фразе за ~60с **без допросов** пользователя.

## Когда читать

Запросы вроде «собери буровой манипулятор», «длинная стрела с буром»,
«манипулятор с запястьем».

## API (не угадывай клетки)

```gdscript
var result := MachineComposer.compose_from_phrase(world, "буровой манипулятор")
# или:
var intent := MachineIntent.from_phrase(phrase)
result = MachineComposer.compose(world, intent)
```

В игре у BaseSpawn:

```gdscript
MachineComposer.spawn_on_terrain_from_phrase(
  session, ground_pos, "длинный буровой манипулятор",
  "player", terrain, tool, space_state
)
```

Foundation anchor сохраняется (в отличие от ровера). Автоспавн в `main` **нет**
— только явный `spawn_on_terrain*` или oneshot-сцена.

Успех: `result.ok == true`, есть `assembly_id`.  
Провал: `result.error` / `result.failures` — поправь **intent**, не `Vector3i`.

## Intent v0

| Поле | Значения | Дефолт |
|---|---|---|
| `recipe` | **drill_arm** | drill_arm |
| `reach` | short / normal / long | short |
| `feed` | bool (поршень на ветке) | **false** |
| `wrist` | bool | false |

Неизвестный рецепт («кран», «карусель») → `unsupported_recipe`.

**drill_arm:** foundation + power + distributor + rotor → hinge → boom×reach →
[feed: piston] → [wrist] → tip frame. `stationary_drill` на pad (не на tip).
Driven chain: **2** (rotor+hinge), +1 feed, +1 wrist. Поршень только по фразе
(«с подачей», «piston») — stock 30 kN рвёт лёгкую ветку.

## Поведение агента

1. Распарси фразу → `MachineIntent` (не спрашивай юзера).
2. `MachineComposer.compose` → `validate` внутри.
3. При fail — один retry (wrist→false / long→normal), иначе честный error.
4. Верификация: `./tests/run_one.sh test_machine_compose`.

## Файлы

- `scripts/authoring/machine_intent.gd`
- `scripts/authoring/machine_composer.gd`
- `scripts/authoring/machine_validator.gd`
- Спека: `docs/specs/MACHINE-COMPOSE-V0.md`
