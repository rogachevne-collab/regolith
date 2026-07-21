# Спека — Day / Night v0 (presentation)

Видимое Солнце на небосводе и цикл дня/ночи для лунных сцен.
**Presentation only** — не симуляционное ядро, не питание/солнечные панели.

Родитель: [`MOON-EXPERIMENT-V0.md`](MOON-EXPERIMENT-V0.md) (light / environment parity).

## Зачем

Сцены держали статичный `DirectionalLight3D` + soft fill + starfield +
`LunarSkyDecor` (Земля). Не было диска Солнца и движения терминатора.

## Контракт

| Параметр | Значение |
|---|---|
| Длительность цикла (default) | **600 s** полный оборот (`cycle_duration_sec`) |
| Старт | bootstrap зовёт `align_noon_above(spawn)` → локальный полдень |
| Контроллер | `DayNightCycle` (`scripts/day_night_cycle.gd`) |
| Диск Солнца | sky shader `lunar_starfield.gdshader` via `LIGHT0_DIRECTION` |
| Угловой размер диска | ~2° (читаемость; реальный ~0.5°) |
| Направление на Солнце | Godot `+basis.z` (= scene L = sky `LIGHT0_DIRECTION`) |
| Mesh fallback | `SolarSkyDecor` disabled in play scenes (kept for cinematics) |
| Сцены | `main.tscn`, `flat_moon.tscn`, `granular_corridor_test.tscn` |

### Что модулируется

- Ориентация `DirectionalLight3D` (parallel rays; `+basis.z` = направление на Солнце = sky `LIGHT0`).
- Energy солнца: на **flat** — fade у горизонта; на **planetoid (radial)** — постоянная (ночь геометрическая на тёмной стороне).
- Soft lift: **sky ambient** (`Environment.ambient_light_source = SKY`) + dim
  **`Earthshine`** directional from `LunarSkyDecor.earth_direction` (no shadows,
  low specular). Not an anti-sun fill — that inverted crater relief in shadow.
- `Environment.ambient_light_energy` — чуть ниже ночью на flat; на planetoid
  держит базовую читаемость тёмной стороны.

### Что не трогаем (v0)

- Орбитальная механика, реальные ~29.5 земных суток.
- Starfield shader (`lunar_starfield.gdshader` остаётся static / no `TIME`).
- Solar power / electric от солнца.
- HUD-часы (можно позже читать `DayNightCycle.phase`).

## Верификация

- Headless: `./run.sh --headless res://scenes/main.tscn` — шейдер без ошибок.
- В игре: диск Солнца, движение теней, ночь темнее (flat) / терминатор (planetoid), Земля и звёзды на месте.
