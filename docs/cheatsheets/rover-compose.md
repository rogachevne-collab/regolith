# Rover compose — шпаргалка для агентов

Собрать ровер по фразе за ~60с **без допросов** пользователя.

## Когда читать

Запросы вроде «собери ровер на 6 колёс, длинный, низкий».

## API (не угадывай клетки)

```gdscript
var world: SimulationWorld = ... # с rover archetypes
var result := RoverComposer.compose_from_phrase(world, "ровер на 6 колёс, длинный")
# или:
var intent := RoverIntent.from_phrase(phrase)  # дыры = дефолты
result = RoverComposer.compose(world, intent)
```

В игре у BaseSpawn (через session + terrain):

```gdscript
RoverComposer.spawn_on_terrain_from_phrase(
  session, ground_pos, "низкий длинный ровер с 6 колесами, кокпит спереди",
  "player", terrain, tool, space_state
)
```

Bootstrap: `@export demo_rover_phrase` — пустая строка = старый hardcoded demo.

Успех: `result.ok == true`, есть `assembly_id`.  
Провал: `result.error` / `result.failures` — поправь **intent**, не `Vector3i`.

Проверка отдельно: `RoverValidator.validate(world, assembly_id, intent)`.

## Intent v0

| Поле | Значения | Дефолт |
|---|---|---|
| `wheel_count` | **4, 6, 8, 10, 12** (чётное) | 4 |
| `length` | short / normal / long | normal |
| `width` | narrow / normal / wide | normal |
| `height` | low / normal / tall | normal |
| `cockpit` | front / center | front |
| `power` | rear / side | rear |
| `suspension_archetype_id` | любой архетип-подвеска | `wheel_suspension` |
| `wheel_archetype_id` | любой архетип-колесо | `drive_wheel` |

«на новых / авторских колёсах» в фразе → пара, испечённая визардом
(`Slice01Archetypes.authored_wheel_pair()`, берётся из
`resources/archetypes/authored/`). Нет такой пары — остаётся стоковая.

Клетки и повороты пары композер **выводит** из самих архетипов: площадка «рама»
смотрит на шасси, ось хода (`default_orientation_index`) — вверх, колесо садится
своей `wheel_plug` на `wheel_socket` стойки. Поэтому деталь с боковым гнездом
встаёт сбоку, а не «на клетку ниже», и футпринт со смещением работает сам.

Иное N колёс → `unsupported_wheel_count` (не изобретай layout).

**Питание:** composer считает `battery_count = ceil(wheels × power_draw_w /
battery_discharge_w)` из актуальных `drive_wheel.power_draw_w` и профиля
`power_battery_small` (сейчас 300 W / 1500 W → 4 кол.=1 батарея, 6=2, 12=3).
Иначе electric budget гасит все колёса (`no_power`).

«Колбаса» в фразе → `length=long` + равномерные оси по длине шасси.

«Огромный / huge / гигант» → `long` + `wide` + `tall`; без явного N колёс → **12**.

«Бур / drill» → два `stationary_drill` на морде (tip −Z). Длина шасси
растёт под `2·wheel.radius` + зазор, чтобы колёса не клипились.

Декор (всегда): силуэт на `frame_slope_45` — каскад носа, скошенные борта/кормы,
угловые «клыки»; `frame_antenna` на палубе; `frame_lamp` фары на морде;
basalt только точечно.

**Load oracle (ТТХ):** после compose смотри `ROVER-LOAD-*` из
`res://scenes/compose_rover_oneshot.tscn` или overlay в
`res://scenes/demo_rover_load.tscn` (`RoverLoadReport`: mass/CoM, static axle
loads, 0.5g/1.0g wheelie/nose-dive flags).

**Визуал (обязателен при смене декора/силуэта):** та же демосцена, ракурсы
**1–5** / **[ ]** (side / ¾ / front / rear / top). Оценивать силуэт и композицию,
не только цифры. Зелёный тест / чистый load report ≠ «выглядит ок».

## Поведение агента

1. Распарси фразу → `RoverIntent` (не спрашивай юзера).
2. `RoverComposer.compose` → `validate` внутри.
3. При fail — один retry с ослаблением (tall→normal / wide→normal), иначе честный error.
4. Верификация ТТХ: `./tests/run_one.sh test_rover_compose` + `ROVER-LOAD-*`.
5. Верификация визуала: `demo_rover_load.tscn` по ракурсам 1–5 (или скрины /
   человек). Не заявлять «красиво» только по ТТХ.

Не использовать legacy `PlacedBlocks` / PoC `assembly.gd`.  
Не писать ручной `PlaceElementCommand` для ровера, если есть composer.

## Файлы

- `scripts/authoring/rover_intent.gd`
- `scripts/authoring/rover_composer.gd`
- `scripts/authoring/rover_validator.gd`
- `scripts/authoring/assembly_build_helper.gd`
- Спека модулей: `docs/specs/ROVER-MODULES-V1.md`
