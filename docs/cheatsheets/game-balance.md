# Game Balance — куда править числа

Единый файл: **`resources/balance/game_balance.json`**.

Спека: `docs/specs/GAME-BALANCE-V0.md`. Загрузчик: `GameBalance`.

## Быстрый индекс

| Хочу изменить | Секция JSON |
|---|---|
| массу / стоимость блока (BOM) | `elements.<archetype_id>.mass_kg` / `build_requirements` |
| силу/скорость поршня, ротора, шарнира | `elements.<id>.piston` / `rotor` / `hinge` |
| колесо / подвеску / thruster / gyro | `elements.<id>.wheel` / `suspension` / `thruster` / `gyro` |
| массу/объём предмета | `items.<item_id>` |
| рецепт (время, мощность, I/O) | `recipes.<recipe_id>` |
| stationary / hand drill carve | `industry.stationary_drill` / `industry.hand_drill` |
| ёмкости store/buffer / player | `industry.*_capacity_l` |
| power output / battery / idle | `electric.archetypes` / `electric.defaults` |
| weld / dismantle / grinder refund | `construction` |
| стартовый / playtest cargo | `starter` |

## Не трогать в balance

- Footprint, ports, colliders, roles → `resources/archetypes/slice01/*.tres`
- Toolbar layout → `ToolController.TOOLBAR_PAGES`
- Voxel SDF API / scale → `docs/cheatsheets/voxel-tools.md`

## После правки

1. Перезапуск игры (JSON грузится при первом обращении; apply — на load/register).
2. Если менялась kernel-логика/инварианты каталога — `./tests/run_one.sh test_game_balance`.
3. Геймплейный feel (бур, поршень) — проверка в запущенной игре.
